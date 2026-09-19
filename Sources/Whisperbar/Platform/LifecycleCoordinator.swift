import AppKit
import ServiceManagement

// MARK: - Login item seam (SMAppService)

enum LoginItemStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

enum LoginItemError: Error, Equatable, Sendable {
    case requiresApproval
    case failed(String)
}

protocol LoginItemServicing: Sendable {
    func register() throws
    func unregister() throws
    func status() -> LoginItemStatus
}

/// CON-PERMISSION-BACKGROUND-STARTUP live adapter: SMAppService.mainApp behind
/// an explicit toggle; denial leaves manual launch available.
struct SMAppServiceLoginItemService: LoginItemServicing {
    func register() throws {
        do {
            try SMAppService.mainApp.register()
        } catch {
            // Keep the failure privacy-safe and actionable.
            if SMAppService.mainApp.status == .requiresApproval {
                throw LoginItemError.requiresApproval
            }
            throw LoginItemError.failed("login item registration failed")
        }
    }

    func unregister() throws {
        do {
            try SMAppService.mainApp.unregister()
        } catch {
            throw LoginItemError.failed("login item removal failed")
        }
    }

    func status() -> LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        case .notRegistered: return .notRegistered
        @unknown default: return .notFound
        }
    }
}

// MARK: - Activation policy seam

enum ActivationPolicyValue: String, Equatable, Sendable {
    case regular
    case accessory
    case prohibited
}

/// Main-actor bound because it touches NSApplication.
@MainActor
protocol ActivationPolicyControlling: Sendable {
    func currentPolicy() -> ActivationPolicyValue
    func setPolicy(_ policy: ActivationPolicyValue)
}

struct AppKitActivationPolicyController: ActivationPolicyControlling {
    func currentPolicy() -> ActivationPolicyValue {
        switch NSApp.activationPolicy() {
        case .regular: return .regular
        case .accessory: return .accessory
        case .prohibited: return .prohibited
        @unknown default: return .accessory
        }
    }

    func setPolicy(_ policy: ActivationPolicyValue) {
        switch policy {
        case .regular: NSApp.setActivationPolicy(.regular)
        case .accessory: NSApp.setActivationPolicy(.accessory)
        case .prohibited: NSApp.setActivationPolicy(.prohibited)
        }
    }
}

// MARK: - Termination resources

/// Anything that must be released before termination completes (hotkeys,
/// event monitors, floating panels, capture, timers, file handles).
protocol TerminationReleasing: Sendable {
    func releaseForTermination() async
}

// MARK: - Capture termination value types

enum CaptureTerminationReason: String, Equatable, Sendable {
    case userStop
    case cancelled
    case appTermination
    case providerFailure
    case malformedAudio

    var isRecoverableProviderFailure: Bool { self == .providerFailure }
}

/// Cleanup outcome reported by the audio/temporary-audio owners.
enum AudioCaptureCleanupOutcome: Equatable, Sendable {
    case verifiedAbsence
    case retainedAwaitingExplicitRetry
    case failed(privacySafeMessage: String)
}

enum CaptureCleanupState: Equatable, Sendable {
    case cleanupVerified
    case awaitingExplicitRetryOrSwitch
    case incomplete(privacySafeMessage: String)
}

struct CaptureRecoverySummary: Equatable, Sendable {
    let reason: CaptureTerminationReason
    let cleanup: CaptureCleanupState
    let details: String
}

// MARK: - LifecycleCoordinator

/// OWN-LIFECYCLE-COORDINATOR.
///
/// Owns CON-LIFECYCLE-APPLICATION-LAUNCH, CON-LIFECYCLE-APPLICATION-TERMINATION,
/// CON-LIFECYCLE-AUDIO-CAPTURE-TERMINATION, and CON-LIFECYCLE-PRESET:
/// preset-owned initialization only (no privileged capture, remote requests,
/// or destructive work), explicit rollback with a safe retry path, and full
/// resource release before termination completes.
@MainActor
final class LifecycleCoordinator {

    enum State: Equatable {
        case idle
        case launching
        case running
        case terminating
        case terminated
        case failed(reason: String)
    }

    private(set) var state: State = .idle
    private(set) var releasedResourceNames: [String] = []
    private(set) var lastCaptureTermination: CaptureRecoverySummary?

    private let loginItemService: LoginItemServicing
    private let activationPolicy: ActivationPolicyControlling
    private var launchSteps: [(name: String, operation: () async throws -> Void)] = []
    private var resources: [(name: String, releaser: TerminationReleasing)] = []

    init(
        loginItemService: LoginItemServicing = SMAppServiceLoginItemService(),
        activationPolicy: ActivationPolicyControlling = AppKitActivationPolicyController()
    ) {
        self.loginItemService = loginItemService
        self.activationPolicy = activationPolicy
    }

    /// New work (recordings, provider calls) is accepted only while running.
    var acceptsNewWork: Bool { state == .running }

    // MARK: Registration

    func registerLaunchStep(name: String, operation: @escaping () async throws -> Void) {
        launchSteps.append((name: name, operation: operation))
    }

    func registerTerminationResource(name: String, releaser: TerminationReleasing) {
        resources.append((name: name, releaser: releaser))
    }

    // MARK: Launch

    /// CON-LIFECYCLE-APPLICATION-LAUNCH. Initialize preset-owned state and
    /// services without starting privileged capture, remote requests, or
    /// destructive work. A failed step rolls back and keeps a retry path.
    func applicationDidFinishLaunching() async {
        switch state {
        case .idle, .failed:
            break
        default:
            return
        }
        state = .launching

        // Menu-bar lifecycle: LSUIElement semantics, never a Dock-first policy.
        activationPolicy.setPolicy(.accessory)

        for step in launchSteps {
            do {
                try await step.operation()
            } catch {
                await releaseAllResources()
                state = .failed(reason: "initialization failed during \(step.name)")
                return
            }
        }
        state = .running
    }

    // MARK: Termination

    /// CON-LIFECYCLE-APPLICATION-TERMINATION. Stop new work, release every
    /// registered resource, and never report an interrupted transition as
    /// complete.
    func applicationWillTerminate() async {
        switch state {
        case .running, .launching:
            state = .terminating
            await releaseAllResources()
            state = .terminated
        case .terminated:
            return
        case .failed:
            return
        case .idle, .terminating:
            state = .failed(reason: "termination attempted before a completed launch")
        }
    }

    private func releaseAllResources() async {
        let pending = resources
        resources.removeAll()
        for resource in pending {
            await resource.releaser.releaseForTermination()
            releasedResourceNames.append(resource.name)
        }
    }

    // MARK: Login item

    func setLaunchAtLogin(enabled: Bool) throws {
        if enabled {
            try loginItemService.register()
        } else {
            try loginItemService.unregister()
        }
    }

    var launchAtLoginStatus: LoginItemStatus {
        loginItemService.status()
    }

    // MARK: Audio capture termination

    /// CON-LIFECYCLE-AUDIO-CAPTURE-TERMINATION. Maps the owner-reported cleanup
    /// outcome to an explicit recovery state. A cleanup failure keeps the
    /// operation incomplete and never claims completion.
    @discardableResult
    func recordCaptureTermination(
        reason: CaptureTerminationReason,
        cleanup: AudioCaptureCleanupOutcome
    ) -> CaptureRecoverySummary {
        let cleanupState: CaptureCleanupState
        switch cleanup {
        case .verifiedAbsence:
            cleanupState = .cleanupVerified
        case .retainedAwaitingExplicitRetry:
            if reason.isRecoverableProviderFailure {
                cleanupState = .awaitingExplicitRetryOrSwitch
            } else {
                cleanupState = .incomplete(
                    privacySafeMessage: "temporary audio was retained without a declared recovery decision"
                )
            }
        case .failed(let message):
            cleanupState = .incomplete(privacySafeMessage: message)
        }

        let details: String
        switch cleanupState {
        case .cleanupVerified:
            details = "Temporary audio cleanup verified."
        case .awaitingExplicitRetryOrSwitch:
            details = "Temporary audio retained while awaiting an explicit retry or provider switch."
        case .incomplete(let message):
            details = message
        }

        let summary = CaptureRecoverySummary(reason: reason, cleanup: cleanupState, details: details)
        lastCaptureTermination = summary
        return summary
    }

    /// Preset invariant used by presentation: the menu-bar lifecycle keeps an
    /// accessory activation policy.
    var keepsMenuBarLifecycle: Bool {
        activationPolicy.currentPolicy() == .accessory
    }
}
