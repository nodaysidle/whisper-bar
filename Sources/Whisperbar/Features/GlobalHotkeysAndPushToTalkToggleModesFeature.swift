import Carbon
import Foundation

// MARK: - Roles, modes, and key events

/// The two configured dictation shortcuts.
enum HotkeyRole: String, Codable, CaseIterable, Sendable {
    case pushToTalk
    case toggle

    var displayName: String {
        switch self {
        case .pushToTalk: return "Push-to-talk"
        case .toggle: return "Toggle"
        }
    }
}

/// The active dictation mode a hotkey session runs in.
enum HotkeyMode: String, Equatable, Sendable {
    case pushToTalk
    case toggle

    var role: HotkeyRole {
        switch self {
        case .pushToTalk: return .pushToTalk
        case .toggle: return .toggle
        }
    }
}

/// A registered shortcut press or release. The event deliberately carries no
/// focus requirement: Carbon hotkeys fire while any application is focused.
struct HotkeyKeyEvent: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case keyDown
        case keyUp
    }

    let role: HotkeyRole
    let identifier: HotkeyIdentifier
    let phase: Phase
    let isRepeat: Bool
    let sourceBundleIdentifier: String?

    init(
        role: HotkeyRole,
        identifier: HotkeyIdentifier,
        phase: Phase,
        isRepeat: Bool = false,
        sourceBundleIdentifier: String? = nil
    ) {
        self.role = role
        self.identifier = identifier
        self.phase = phase
        self.isRepeat = isRepeat
        self.sourceBundleIdentifier = sourceBundleIdentifier
    }
}

extension HotkeyIdentifier: Hashable {
    /// Explicit synthesis: the conformance lives outside the declaring file,
    /// so the compiler cannot derive `hash(into:)` automatically.
    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers)
    }

    /// A global shortcut without a modifier would capture normal typing, so it
    /// is rejected before any registration is attempted.
    var hasModifiers: Bool { modifiers != 0 }
}

// MARK: - Registration seam

enum HotkeyRegistrationError: Error, Equatable, Sendable {
    case conflict
    case unavailable
    case failed
}

/// Injectable global-shortcut boundary so tests never claim a real system
/// hotkey and never depend on the frontmost application.
protocol HotkeyRegistering: Sendable {
    func register(_ identifier: HotkeyIdentifier, role: HotkeyRole) throws
    func unregister(role: HotkeyRole)
    func setEventSink(_ sink: (@Sendable (HotkeyKeyEvent) -> Void)?)
}

// MARK: - Live Carbon registrar (CON-PERMISSION-GLOBAL-INPUT)

/// Carbon `RegisterEventHotKey` adapter. Registration is inherently
/// system-wide, claims only the exact configured key combination, and sends no
/// event for anything else, so unclaimed system shortcuts remain functional.
final class CarbonHotkeyRegistrar: HotkeyRegistering, @unchecked Sendable {

    /// Four-character signature for this application's hotkeys ('WBR1').
    private static let signature: OSType = 0x5742_5231

    private let lock = NSLock()
    private var registrations: [HotkeyRole: (identifier: HotkeyIdentifier, reference: EventHotKeyRef)] = [:]
    private var handlerReference: EventHandlerRef?
    private var sink: (@Sendable (HotkeyKeyEvent) -> Void)?

    func register(_ identifier: HotkeyIdentifier, role: HotkeyRole) throws {
        installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.identifierID(for: role))
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            identifier.keyCode,
            identifier.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        switch status {
        case noErr:
            guard let reference else { throw HotkeyRegistrationError.failed }
            lock.withLock { registrations[role] = (identifier, reference) }
        case OSStatus(eventHotKeyExistsErr):
            throw HotkeyRegistrationError.conflict
        default:
            throw HotkeyRegistrationError.failed
        }
    }

    func unregister(role: HotkeyRole) {
        let registration = lock.withLock { registrations.removeValue(forKey: role) }
        if let registration {
            UnregisterEventHotKey(registration.reference)
        }
    }

    func setEventSink(_ sink: (@Sendable (HotkeyKeyEvent) -> Void)?) {
        lock.withLock { self.sink = sink }
    }

    func releaseAll() {
        let pending = lock.withLock { () -> [EventHotKeyRef] in
            let references = registrations.values.map(\.reference)
            registrations.removeAll()
            return references
        }
        for reference in pending {
            UnregisterEventHotKey(reference)
        }
    }

    fileprivate func dispatch(hotKeyID: EventHotKeyID, isKeyDown: Bool) -> OSStatus {
        guard hotKeyID.signature == Self.signature,
              let role = Self.role(forID: hotKeyID.id),
              let registration = lock.withLock({ registrations[role] }) else {
            return OSStatus(eventNotHandledErr)
        }
        let sink = lock.withLock { self.sink }
        sink?(
            HotkeyKeyEvent(
                role: role,
                identifier: registration.identifier,
                phase: isKeyDown ? .keyDown : .keyUp
            )
        )
        return noErr
    }

    private func installHandlerIfNeeded() {
        guard lock.withLock({ handlerReference == nil }) else { return }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        var reference: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            whisperBarCarbonHotkeyHandler,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &reference
        )
        if status == noErr {
            lock.withLock { handlerReference = reference }
        }
    }

    private static func identifierID(for role: HotkeyRole) -> UInt32 {
        switch role {
        case .pushToTalk: return 1
        case .toggle: return 2
        }
    }

    private static func role(forID id: UInt32) -> HotkeyRole? {
        switch id {
        case 1: return .pushToTalk
        case 2: return .toggle
        default: return nil
        }
    }
}

/// C-compatible Carbon event callback; forwards to the owning registrar.
private func whisperBarCarbonHotkeyHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return OSStatus(eventNotHandledErr) }
    let isKeyDown = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    let registrar = Unmanaged<CarbonHotkeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
    return registrar.dispatch(hotKeyID: hotKeyID, isKeyDown: isKeyDown)
}

// MARK: - GlobalHotkeysAndPushToTalkToggleModesFeature

/// OWN-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES.
///
/// Owns CON-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES-INTERFACE and
/// CON-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES-RECOVERY: registers the
/// configured shortcuts safely, detects conflicts instead of failing silently,
/// handles smooth release, and drives push-to-talk or toggle recording through
/// one explicit state machine. Every state is idle, active (recording),
/// succeeded, failed, or cancelled; the last valid configuration is preserved
/// on every failure and recovery is an explicit user retry.
@MainActor
final class GlobalHotkeysAndPushToTalkToggleModesFeature: TerminationReleasing {

    // MARK: States

    enum State: Equatable, Sendable {
        case idle
        case recording(HotkeyMode)
        case succeeded(HotkeyMode)
        case failed(Failure)
        case cancelled(HotkeyMode)
    }

    enum StopReason: Equatable, Sendable {
        case userRelease
        case userToggledOff
        case cancelled
        case providerFailure
    }

    enum Action: Equatable, Sendable {
        case startRecording(mode: HotkeyMode)
        case stopRecording(mode: HotkeyMode, reason: StopReason)
    }

    struct Failure: Equatable, Sendable {
        enum Category: Equatable, Sendable {
            case conflict
            case duplicateConfiguration
            case invalidConfiguration
            case inputUnavailable
            case registrationFailed
            case providerFailure
        }

        let category: Category
        let role: HotkeyRole?
        let message: String
    }

    /// The active registration set. A rejected configuration never changes it.
    enum RegistrationState: Equatable, Sendable {
        case unregistered
        case registered(HotkeyConfiguration)
    }

    /// Outcome of one explicit configure or retry attempt.
    enum RegistrationOutcome: Equatable, Sendable {
        case registered(HotkeyConfiguration)
        case rejected(Failure)
    }

    // MARK: Observable state

    private(set) var state: State = .idle
    private(set) var registrationState: RegistrationState = .unregistered
    private(set) var lastValidConfiguration: HotkeyConfiguration = .empty
    private(set) var lastAttemptedConfiguration: HotkeyConfiguration?
    private(set) var lastFailure: Failure?
    private(set) var lastAction: Action?

    /// Presentation hook; the composition root forwards these to capture.
    var onAction: (@MainActor (Action) -> Void)?

    /// In-app record and stop controls stay available in every state, which is
    /// the documented denied path for CON-PERMISSION-GLOBAL-INPUT.
    var inAppControlsAvailable: Bool { true }

    // MARK: Dependencies

    private let registrar: HotkeyRegistering
    private let globalInputAvailability: @MainActor () -> PermissionState

    init(
        registrar: HotkeyRegistering = CarbonHotkeyRegistrar(),
        globalInputAvailability: @escaping @MainActor () -> PermissionState = { .authorized }
    ) {
        self.registrar = registrar
        self.globalInputAvailability = globalInputAvailability
        registrar.setEventSink { [weak self] event in
            Task { @MainActor in
                _ = self?.handleKeyEvent(event)
            }
        }
    }

    // MARK: Configuration and conflict detection

    /// Registers the requested configuration. On any conflict, duplicate, or
    /// invalid value the previously working configuration stays registered,
    /// no recording starts, and the failure is reported with an actionable
    /// message. Recovery is an explicit `retryRegistration()`.
    @discardableResult
    func configure(_ configuration: HotkeyConfiguration) -> RegistrationOutcome {
        lastAttemptedConfiguration = configuration

        if let failure = Self.validationFailure(for: configuration) {
            return reject(failure)
        }

        let availability = globalInputAvailability()
        if availability == .denied || availability == .restricted {
            return reject(
                Failure(
                    category: .inputUnavailable,
                    role: nil,
                    message: "Global shortcuts cannot be registered. Enable Input Monitoring for WhisperBar in System Settings → Privacy & Security, or keep using the in-app controls. Recording did not start."
                )
            )
        }

        unregisterAll()
        var registeredRoles: [HotkeyRole] = []
        for role in HotkeyRole.allCases {
            guard let identifier = Self.identifier(for: role, in: configuration) else { continue }
            do {
                try registrar.register(identifier, role: role)
                registeredRoles.append(role)
            } catch {
                for registered in registeredRoles {
                    registrar.unregister(role: registered)
                }
                // Preserve the last valid state: restore the previously
                // working shortcuts so dictation keeps functioning.
                restoreLastValidConfiguration()

                let category: Failure.Category
                if let registrationError = error as? HotkeyRegistrationError,
                   registrationError == .conflict {
                    category = .conflict
                } else {
                    category = .registrationFailed
                }
                return reject(
                    Failure(
                        category: category,
                        role: role,
                        message: "The \(role.displayName) shortcut is already used by another application or could not be registered. Choose another shortcut; recording did not start."
                    )
                )
            }
        }

        lastValidConfiguration = configuration
        lastFailure = nil
        registrationState = .registered(configuration)
        return .registered(configuration)
    }

    /// Explicit user retry of the last attempted configuration
    /// (CON-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES-RECOVERY).
    @discardableResult
    func retryRegistration() -> RegistrationOutcome {
        configure(lastAttemptedConfiguration ?? lastValidConfiguration)
    }

    private func reject(_ failure: Failure) -> RegistrationOutcome {
        lastFailure = failure
        return .rejected(failure)
    }

    private func unregisterAll() {
        for role in HotkeyRole.allCases {
            registrar.unregister(role: role)
        }
        registrationState = .unregistered
    }

    private func restoreLastValidConfiguration() {
        guard !lastValidConfiguration.isEmpty else { return }
        for role in HotkeyRole.allCases {
            guard let identifier = Self.identifier(for: role, in: lastValidConfiguration) else { continue }
            try? registrar.register(identifier, role: role)
        }
    }

    // MARK: Key event handling

    /// Handles one delivered shortcut event. Returns whether the combination
    /// belongs to WhisperBar; unregistered combinations are returned to the
    /// system untouched so other shortcuts keep working.
    @discardableResult
    func handleKeyEvent(_ event: HotkeyKeyEvent) -> Bool {
        guard let activeIdentifier = activeIdentifier(for: event.role),
              activeIdentifier == event.identifier else {
            return false
        }

        // The focused application is deliberately ignored: registered global
        // shortcuts work from any app.
        switch (event.role, event.phase) {
        case (.pushToTalk, .keyDown):
            guard !event.isRepeat, !isRecording else { return true }
            beginRecording(mode: .pushToTalk)
        case (.pushToTalk, .keyUp):
            guard case .recording(.pushToTalk) = state else { return true }
            finishRecording(mode: .pushToTalk, reason: .userRelease)
        case (.toggle, .keyDown):
            guard !event.isRepeat else { return true }
            switch state {
            case .recording(.toggle):
                finishRecording(mode: .toggle, reason: .userToggledOff)
            case .recording(.pushToTalk):
                // Exactly one active recording state machine: the toggle press
                // adds nothing while push-to-talk owns the session.
                break
            default:
                beginRecording(mode: .toggle)
            }
        case (.toggle, .keyUp):
            break
        }
        return true
    }

    private var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    private func beginRecording(mode: HotkeyMode) {
        state = .recording(mode)
        emit(.startRecording(mode: mode))
    }

    private func finishRecording(mode: HotkeyMode, reason: StopReason) {
        switch reason {
        case .cancelled:
            state = .cancelled(mode)
        case .providerFailure:
            state = .failed(
                Failure(
                    category: .providerFailure,
                    role: mode.role,
                    message: "The selected provider failed. Retry or cancel the recording explicitly."
                )
            )
        case .userRelease, .userToggledOff:
            state = .succeeded(mode)
        }
        emit(.stopRecording(mode: mode, reason: reason))
    }

    private func emit(_ action: Action) {
        lastAction = action
        onAction?(action)
    }

    // MARK: Explicit session control (in-app controls)

    /// The explicit in-app record control (the documented denied path of
    /// CON-PERMISSION-GLOBAL-INPUT). It drives the same single recording state
    /// machine as the global shortcut, so an in-app start and a shortcut press
    /// can never own two sessions at once, and it emits exactly the one start
    /// action the composition root runs.
    @discardableResult
    func beginInAppRecording(mode: HotkeyMode) -> Bool {
        guard !isRecording else { return false }
        beginRecording(mode: mode)
        return true
    }

    /// The explicit in-app stop control. It finishes the same session exactly
    /// like the matching shortcut: push-to-talk ends on release, toggle ends on
    /// toggle-off.
    @discardableResult
    func finishInAppRecording() -> Bool {
        guard case .recording(let mode) = state else { return false }
        switch mode {
        case .pushToTalk: finishRecording(mode: mode, reason: .userRelease)
        case .toggle: finishRecording(mode: mode, reason: .userToggledOff)
        }
        return true
    }

    func cancelRecording() {
        guard case .recording(let mode) = state else { return }
        finishRecording(mode: mode, reason: .cancelled)
    }

    /// The session that never started (a blocked gate, missing temporary
    /// storage, an unavailable route, or capture that failed) releases the
    /// recording state machine so neither the shortcut nor the in-app controls
    /// stay stuck in a recording state. Nothing is recorded and no stop signal
    /// reaches a session that does not exist.
    func reportStartFailure() {
        reportProviderFailure()
    }

    func reportProviderFailure() {
        guard case .recording(let mode) = state else { return }
        finishRecording(mode: mode, reason: .providerFailure)
    }

    // MARK: Termination

    /// CON-LIFECYCLE-APPLICATION-TERMINATION: release every registered hotkey
    /// so no shortcut outlives the process.
    func releaseForTermination() async {
        unregisterAll()
        registrar.setEventSink(nil)
        if let registrar = registrar as? CarbonHotkeyRegistrar {
            registrar.releaseAll()
        }
        state = .idle
    }

    // MARK: Helpers

    private func activeIdentifier(for role: HotkeyRole) -> HotkeyIdentifier? {
        guard case .registered(let configuration) = registrationState else { return nil }
        return Self.identifier(for: role, in: configuration)
    }

    private static func identifier(for role: HotkeyRole, in configuration: HotkeyConfiguration) -> HotkeyIdentifier? {
        switch role {
        case .pushToTalk: return configuration.pushToTalk
        case .toggle: return configuration.toggle
        }
    }

    private static func validationFailure(for configuration: HotkeyConfiguration) -> Failure? {
        for role in HotkeyRole.allCases {
            guard let identifier = identifier(for: role, in: configuration) else { continue }
            guard identifier.hasModifiers else {
                return Failure(
                    category: .invalidConfiguration,
                    role: role,
                    message: "The \(role.displayName) shortcut needs at least one modifier key so it cannot capture normal typing. The previous shortcuts are unchanged."
                )
            }
        }
        if let pushToTalk = configuration.pushToTalk,
           let toggle = configuration.toggle,
           pushToTalk == toggle {
            return Failure(
                category: .duplicateConfiguration,
                role: nil,
                message: "Push-to-talk and Toggle must use different shortcuts. The previous shortcuts are unchanged."
            )
        }
        return nil
    }
}
