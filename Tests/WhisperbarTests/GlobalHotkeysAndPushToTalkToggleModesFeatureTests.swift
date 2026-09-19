import Foundation
import Testing
@testable import Whisperbar

/// TASK-06-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES focused checks.
///
/// Covers FEAT-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES and contracts
/// CON-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES-INTERFACE and
/// CON-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES-RECOVERY through an
/// injectable registrar. No live hotkey is ever claimed.
@Suite("GlobalHotkeysAndPushToTalkToggleModesFeature — hotkey contracts")
@MainActor
struct GlobalHotkeysAndPushToTalkToggleModesFeatureTests {

    // MARK: - Fakes

    final class FakeHotkeyRegistrar: HotkeyRegistering, @unchecked Sendable {
        private let lock = NSLock()
        private var _conflicts: Set<HotkeyIdentifier> = []
        private var _registered: [HotkeyRole: HotkeyIdentifier] = [:]
        private var _attempts: [HotkeyIdentifier] = []
        private var _sink: (@Sendable (HotkeyKeyEvent) -> Void)?

        /// Combinations the fake system already owns. Registering them fails
        /// exactly like `RegisterEventHotKey` returning `eventHotKeyExistsErr`.
        var conflicts: Set<HotkeyIdentifier> {
            get { lock.withLock { _conflicts } }
            set { lock.withLock { _conflicts = newValue } }
        }

        var registered: [HotkeyRole: HotkeyIdentifier] { lock.withLock { _registered } }
        var attempts: [HotkeyIdentifier] { lock.withLock { _attempts } }

        func register(_ identifier: HotkeyIdentifier, role: HotkeyRole) throws {
            try lock.withLock {
                _attempts.append(identifier)
                if _conflicts.contains(identifier) {
                    throw HotkeyRegistrationError.conflict
                }
                _registered[role] = identifier
            }
        }

        func unregister(role: HotkeyRole) {
            lock.withLock { _registered.removeValue(forKey: role) }
        }

        func setEventSink(_ sink: (@Sendable (HotkeyKeyEvent) -> Void)?) {
            lock.withLock { _sink = sink }
        }
    }

    // MARK: - Helpers

    /// Carbon modifier flags used by the locked hotkey value type.
    private static let command: UInt32 = 256
    private static let shift: UInt32 = 512
    private static let control: UInt32 = 4096

    private static let pushToTalkKey = HotkeyIdentifier(keyCode: 49, modifiers: command | shift)
    private static let toggleKey = HotkeyIdentifier(keyCode: 49, modifiers: command | control)

    private static var validConfiguration: HotkeyConfiguration {
        HotkeyConfiguration(pushToTalk: pushToTalkKey, toggle: toggleKey)
    }

    private func makeFeature(
        registrar: FakeHotkeyRegistrar,
        availability: PermissionState = .authorized
    ) -> (feature: GlobalHotkeysAndPushToTalkToggleModesFeature, actions: () -> [GlobalHotkeysAndPushToTalkToggleModesFeature.Action]) {
        let feature = GlobalHotkeysAndPushToTalkToggleModesFeature(
            registrar: registrar,
            globalInputAvailability: { availability }
        )
        let box = ActionBox()
        feature.onAction = { action in box.append(action) }
        return (feature, { box.actions })
    }

    final class ActionBox {
        var actions: [GlobalHotkeysAndPushToTalkToggleModesFeature.Action] = []
        func append(_ action: GlobalHotkeysAndPushToTalkToggleModesFeature.Action) {
            actions.append(action)
        }
    }

    private func keyDown(_ role: HotkeyRole, identifier: HotkeyIdentifier, repeat isRepeat: Bool = false, from bundle: String? = nil) -> HotkeyKeyEvent {
        HotkeyKeyEvent(role: role, identifier: identifier, phase: .keyDown, isRepeat: isRepeat, sourceBundleIdentifier: bundle)
    }

    private func keyUp(_ role: HotkeyRole, identifier: HotkeyIdentifier, from bundle: String? = nil) -> HotkeyKeyEvent {
        HotkeyKeyEvent(role: role, identifier: identifier, phase: .keyUp, isRepeat: false, sourceBundleIdentifier: bundle)
    }

    // MARK: - ACC-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES-01
    // Conflict detection prevents silent failures.

    @Test("A conflicting shortcut is reported and the previous configuration stays active")
    func conflictKeepsPreviousConfiguration() {
        let registrar = FakeHotkeyRegistrar()
        let (feature, actions) = makeFeature(registrar: registrar)

        #expect(feature.configure(Self.validConfiguration) == .registered(Self.validConfiguration))
        #expect(registrar.registered[.pushToTalk] == Self.pushToTalkKey)

        // A new configuration whose toggle shortcut is taken by the system.
        let conflictingToggle = HotkeyIdentifier(keyCode: 35, modifiers: Self.command | Self.shift)
        registrar.conflicts = [conflictingToggle]
        let rejected = HotkeyConfiguration(pushToTalk: HotkeyIdentifier(keyCode: 49, modifiers: Self.command | Self.control), toggle: conflictingToggle)

        let outcome = feature.configure(rejected)
        guard case .rejected(let failure) = outcome else {
            Issue.record("expected a conflict rejection, got \(outcome)")
            return
        }
        #expect(failure.category == .conflict)
        #expect(failure.role == .toggle)
        #expect(failure.message.contains("did not start"))

        // Rollback removed the partially-registered push-to-talk shortcut and
        // restored the last valid configuration.
        #expect(registrar.registered[.pushToTalk] == Self.pushToTalkKey)
        #expect(registrar.registered[.toggle] == Self.toggleKey)

        // The conflicted combination is unregistered, so recording cannot start
        // from it and the failure is not silent.
        #expect(feature.handleKeyEvent(self.keyDown(.toggle, identifier: conflictingToggle)) == false)
        #expect(actions().isEmpty)
    }

    @Test("Push-to-talk and toggle cannot share one shortcut")
    func duplicateAcrossRolesIsRejectedBeforeRegistration() {
        let registrar = FakeHotkeyRegistrar()
        let (feature, _) = makeFeature(registrar: registrar)
        _ = feature.configure(Self.validConfiguration)
        let attemptsBefore = registrar.attempts.count

        let duplicate = HotkeyConfiguration(pushToTalk: Self.pushToTalkKey, toggle: Self.pushToTalkKey)
        let outcome = feature.configure(duplicate)
        guard case .rejected(let failure) = outcome else {
            Issue.record("expected duplicate rejection, got \(outcome)")
            return
        }
        #expect(failure.category == .duplicateConfiguration)
        #expect(registrar.attempts.count == attemptsBefore)
        #expect(feature.registrationState == .registered(Self.validConfiguration))
    }

    @Test("A missing modifier is rejected and the last valid shortcut set keeps working")
    func bareKeyConfigurationIsRejected() {
        let registrar = FakeHotkeyRegistrar()
        let (feature, actions) = makeFeature(registrar: registrar)
        _ = feature.configure(Self.validConfiguration)

        let bare = HotkeyConfiguration(pushToTalk: HotkeyIdentifier(keyCode: 49, modifiers: 0), toggle: nil)
        let outcome = feature.configure(bare)
        guard case .rejected(let failure) = outcome else {
            Issue.record("expected invalid-configuration rejection, got \(outcome)")
            return
        }
        #expect(failure.category == .invalidConfiguration)
        #expect(registrar.registered[.pushToTalk] == Self.pushToTalkKey)

        #expect(feature.handleKeyEvent(self.keyDown(.pushToTalk, identifier: Self.pushToTalkKey)))
        #expect(actions().first == .startRecording(mode: .pushToTalk))
    }

    // MARK: - ACC-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES-02
    // Hotkeys work from any focused app.

    @Test("Shortcut events are handled no matter which application is focused")
    func eventsWorkFromAnyFocusedApplication() {
        let registrar = FakeHotkeyRegistrar()
        let (feature, actions) = makeFeature(registrar: registrar)
        _ = feature.configure(Self.validConfiguration)

        let foreign = "com.example.some-other-app"
        #expect(feature.handleKeyEvent(self.keyDown(.pushToTalk, identifier: Self.pushToTalkKey, from: foreign)))
        #expect(feature.handleKeyEvent(self.keyUp(.pushToTalk, identifier: Self.pushToTalkKey, from: foreign)))
        #expect(actions() == [
            .startRecording(mode: .pushToTalk),
            .stopRecording(mode: .pushToTalk, reason: .userRelease)
        ])
    }

    @Test("Unregistered combinations pass through so system shortcuts stay functional")
    func unregisteredCombinationsAreNotConsumed() {
        let registrar = FakeHotkeyRegistrar()
        let (feature, actions) = makeFeature(registrar: registrar)
        _ = feature.configure(Self.validConfiguration)

        let systemShortcut = HotkeyIdentifier(keyCode: 48, modifiers: Self.command)
        #expect(feature.handleKeyEvent(self.keyDown(.toggle, identifier: systemShortcut)) == false)
        #expect(feature.handleKeyEvent(self.keyUp(.toggle, identifier: systemShortcut)) == false)
        #expect(actions().isEmpty)
        // Only the two configured combinations were ever claimed.
        #expect(registrar.attempts == [Self.pushToTalkKey, Self.toggleKey])
    }

    // MARK: - ACC-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES-03
    // Push-to-talk and toggle modes behave as configured.

    @Test("Push-to-talk starts on press, ignores repeats, and stops smoothly on release")
    func pushToTalkPressAndRelease() {
        let registrar = FakeHotkeyRegistrar()
        let (feature, actions) = makeFeature(registrar: registrar)
        _ = feature.configure(Self.validConfiguration)

        #expect(feature.handleKeyEvent(self.keyDown(.pushToTalk, identifier: Self.pushToTalkKey)))
        #expect(feature.state == .recording(.pushToTalk))

        // Auto-repeat must not restart or duplicate the session.
        #expect(feature.handleKeyEvent(self.keyDown(.pushToTalk, identifier: Self.pushToTalkKey, repeat: true)))
        #expect(feature.state == .recording(.pushToTalk))

        // A stray release without an active session emits nothing.
        #expect(feature.handleKeyEvent(self.keyUp(.toggle, identifier: Self.toggleKey)))

        #expect(feature.handleKeyEvent(self.keyUp(.pushToTalk, identifier: Self.pushToTalkKey)))
        #expect(feature.state == .succeeded(.pushToTalk))
        #expect(actions() == [
            .startRecording(mode: .pushToTalk),
            .stopRecording(mode: .pushToTalk, reason: .userRelease)
        ])
    }

    @Test("Toggle mode starts and stops on successive presses")
    func togglePressTogglesTheSession() {
        let registrar = FakeHotkeyRegistrar()
        let (feature, actions) = makeFeature(registrar: registrar)
        _ = feature.configure(Self.validConfiguration)

        #expect(feature.handleKeyEvent(self.keyDown(.toggle, identifier: Self.toggleKey)))
        #expect(feature.state == .recording(.toggle))
        #expect(feature.handleKeyEvent(self.keyDown(.toggle, identifier: Self.toggleKey)))
        #expect(feature.state == .succeeded(.toggle))

        #expect(actions() == [
            .startRecording(mode: .toggle),
            .stopRecording(mode: .toggle, reason: .userToggledOff)
        ])
    }

    @Test("Exactly one recording session can be active across both modes")
    func onlyOneActiveRecordingSession() {
        let registrar = FakeHotkeyRegistrar()
        let (feature, actions) = makeFeature(registrar: registrar)
        _ = feature.configure(Self.validConfiguration)

        #expect(feature.handleKeyEvent(self.keyDown(.pushToTalk, identifier: Self.pushToTalkKey)))
        // A toggle press during a push-to-talk session adds nothing.
        #expect(feature.handleKeyEvent(self.keyDown(.toggle, identifier: Self.toggleKey)))
        #expect(feature.state == .recording(.pushToTalk))

        #expect(feature.handleKeyEvent(self.keyUp(.pushToTalk, identifier: Self.pushToTalkKey)))
        // The release that follows a completed session no longer changes state.
        #expect(feature.state == .succeeded(.pushToTalk))
        #expect(actions() == [
            .startRecording(mode: .pushToTalk),
            .stopRecording(mode: .pushToTalk, reason: .userRelease)
        ])
    }

    // MARK: - ACC-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES-04
    // System shortcuts remain functional.

    @Test("Denied global-input access blocks registration and keeps in-app controls")
    func deniedGlobalInputKeepsManualControls() {
        let registrar = FakeHotkeyRegistrar()
        let (feature, _) = makeFeature(registrar: registrar, availability: .denied)

        let outcome = feature.configure(Self.validConfiguration)
        guard case .rejected(let failure) = outcome else {
            Issue.record("expected input-unavailable rejection, got \(outcome)")
            return
        }
        #expect(failure.category == .inputUnavailable)
        #expect(registrar.attempts.isEmpty)
        #expect(feature.inAppControlsAvailable)
        // No combination is claimed, so every system shortcut keeps working.
        #expect(feature.handleKeyEvent(self.keyDown(.pushToTalk, identifier: Self.pushToTalkKey)) == false)
    }

    // MARK: - CON-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES-RECOVERY

    @Test("An explicit retry re-registers after the conflict is resolved")
    func explicitRetryRecoversFromConflict() {
        let registrar = FakeHotkeyRegistrar()
        let (feature, _) = makeFeature(registrar: registrar)

        registrar.conflicts = [Self.toggleKey]
        guard case .rejected(let firstFailure) = feature.configure(Self.validConfiguration) else {
            Issue.record("expected initial conflict")
            return
        }
        #expect(firstFailure.category == .conflict)
        #expect(feature.lastValidConfiguration == .empty)
        // The partial push-to-talk claim was rolled back.
        #expect(registrar.registered.isEmpty)

        registrar.conflicts = []
        let outcome = feature.retryRegistration()
        #expect(outcome == .registered(Self.validConfiguration))
        #expect(feature.lastFailure == nil)
        #expect(registrar.registered == [.pushToTalk: Self.pushToTalkKey, .toggle: Self.toggleKey])
    }

    @Test("Cancellation and provider failure end the session without emitting a new start")
    func cancellationAndProviderFailure() {
        let registrar = FakeHotkeyRegistrar()
        let (feature, actions) = makeFeature(registrar: registrar)
        _ = feature.configure(Self.validConfiguration)

        #expect(feature.handleKeyEvent(self.keyDown(.pushToTalk, identifier: Self.pushToTalkKey)))
        #expect(feature.handleKeyEvent(self.keyDown(.toggle, identifier: Self.toggleKey)))
        feature.cancelRecording()
        #expect(feature.state == .cancelled(.pushToTalk))

        #expect(feature.handleKeyEvent(self.keyDown(.toggle, identifier: Self.toggleKey)))
        feature.reportProviderFailure()
        guard case .failed(let failure) = feature.state else {
            Issue.record("expected a failed state, got \(feature.state)")
            return
        }
        #expect(failure.category == .providerFailure)

        // The last valid shortcut set survives both terminal paths.
        #expect(feature.registrationState == .registered(Self.validConfiguration))
        #expect(actions() == [
            .startRecording(mode: .pushToTalk),
            .stopRecording(mode: .pushToTalk, reason: .cancelled),
            .startRecording(mode: .toggle),
            .stopRecording(mode: .toggle, reason: .providerFailure)
        ])
    }

    @Test("Termination releases every registered shortcut")
    func terminationReleasesShortcuts() async {
        let registrar = FakeHotkeyRegistrar()
        let (feature, _) = makeFeature(registrar: registrar)
        _ = feature.configure(Self.validConfiguration)
        #expect(feature.handleKeyEvent(self.keyDown(.pushToTalk, identifier: Self.pushToTalkKey)))

        await feature.releaseForTermination()

        #expect(registrar.registered.isEmpty)
        #expect(feature.state == .idle)
        #expect(feature.registrationState == .unregistered)
    }
}
