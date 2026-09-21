import Foundation
import Testing
@testable import Whisperbar

/// TASK-04-LIFECYCLE-COORDINATOR focused checks.
///
/// Covers CON-LIFECYCLE-APPLICATION-LAUNCH, CON-LIFECYCLE-APPLICATION-TERMINATION,
/// CON-LIFECYCLE-AUDIO-CAPTURE-TERMINATION, CON-LIFECYCLE-PRESET with injectable
/// login-item, activation-policy, and resource-release seams. No live
/// SMAppService or NSApplication mutation occurs in tests.
@Suite("LifecycleCoordinator — launch, termination, and capture lifecycle")
@MainActor
struct LifecycleCoordinatorTests {

    // MARK: - Fakes

    final class FakeLoginItemService: LoginItemServicing, @unchecked Sendable {
        var statusValue: LoginItemStatus = .notRegistered
        var registerError: Error?
        private(set) var registerCount = 0
        private(set) var unregisterCount = 0

        func register() throws {
            registerCount += 1
            if let registerError { throw registerError }
            statusValue = .enabled
        }

        func unregister() throws {
            unregisterCount += 1
            statusValue = .notRegistered
        }

        func status() -> LoginItemStatus { statusValue }
    }

    @MainActor
    final class RecordingActivationPolicy: ActivationPolicyControlling {
        private(set) var appliedPolicies: [ActivationPolicyValue] = []
        var current: ActivationPolicyValue = .regular

        func currentPolicy() -> ActivationPolicyValue { current }
        func setPolicy(_ policy: ActivationPolicyValue) {
            appliedPolicies.append(policy)
            current = policy
        }
    }

    actor ReleaseRecorder {
        private(set) var released: [String] = []
        func record(_ name: String) { released.append(name) }
        func names() -> [String] { released }
    }

    struct TestReleaser: TerminationReleasing {
        let name: String
        let recorder: ReleaseRecorder
        func releaseForTermination() async {
            await recorder.record(name)
        }
    }

    // MARK: - Launch

    @Test("Launch runs registered steps, keeps the menu-bar policy, and reaches running")
    func launchRunsSteps() async {
        let policy = RecordingActivationPolicy()
        let coordinator = LifecycleCoordinator(
            loginItemService: FakeLoginItemService(),
            activationPolicy: policy
        )
        var ran: [String] = []
        coordinator.registerLaunchStep(name: "state") { ran.append("state") }
        coordinator.registerLaunchStep(name: "history") { ran.append("history") }

        #expect(coordinator.state == .idle)
        await coordinator.applicationDidFinishLaunching()
        #expect(coordinator.state == .running)
        #expect(ran == ["state", "history"])
        #expect(policy.appliedPolicies == [.accessory])
        #expect(coordinator.acceptsNewWork)
    }

    @Test("A failing launch step rolls back partial initialization and keeps a retry path")
    func launchFailureRollsBack() async {
        let recorder = ReleaseRecorder()
        let coordinator = LifecycleCoordinator(
            loginItemService: FakeLoginItemService(),
            activationPolicy: RecordingActivationPolicy()
        )
        coordinator.registerTerminationResource(name: "opened-handle", releaser: TestReleaser(name: "opened-handle", recorder: recorder))
        var attempts = 0
        coordinator.registerLaunchStep(name: "flaky") {
            attempts += 1
            if attempts == 1 { throw LifecycleStepError.failed }
        }

        await coordinator.applicationDidFinishLaunching()
        guard case .failed = coordinator.state else {
            Issue.record("expected failed state, got \(coordinator.state)")
            return
        }
        #expect(await recorder.names() == ["opened-handle"])
        #expect(coordinator.acceptsNewWork == false)

        // Explicit retry succeeds and converges to running.
        await coordinator.applicationDidFinishLaunching()
        #expect(coordinator.state == .running)
        #expect(attempts == 2)
    }

    // MARK: - Termination

    @Test("Termination stops new work and releases every registered resource")
    func terminationReleasesResources() async {
        let recorder = ReleaseRecorder()
        let coordinator = LifecycleCoordinator(
            loginItemService: FakeLoginItemService(),
            activationPolicy: RecordingActivationPolicy()
        )
        coordinator.registerTerminationResource(name: "hotkeys", releaser: TestReleaser(name: "hotkeys", recorder: recorder))
        coordinator.registerTerminationResource(name: "hud", releaser: TestReleaser(name: "hud", recorder: recorder))
        coordinator.registerTerminationResource(name: "capture", releaser: TestReleaser(name: "capture", recorder: recorder))

        await coordinator.applicationDidFinishLaunching()
        await coordinator.applicationWillTerminate()

        #expect(coordinator.state == .terminated)
        #expect(coordinator.acceptsNewWork == false)
        #expect(await recorder.names() == ["hotkeys", "hud", "capture"])
    }

    @Test("Interrupted lifecycle transitions are never reported as complete")
    func interruptedTransitionsAreHonest() async {
        let coordinator = LifecycleCoordinator(
            loginItemService: FakeLoginItemService(),
            activationPolicy: RecordingActivationPolicy()
        )
        // Terminating before launch must not claim a completed lifecycle.
        await coordinator.applicationWillTerminate()
        #expect(coordinator.state != .terminated)
        guard case .failed = coordinator.state else {
            Issue.record("expected an explicit failed state, got \(coordinator.state)")
            return
        }
    }

    // MARK: - Login item (SMAppService contract)

    @Test("Launch at login is an explicit toggle; denial leaves manual launch available")
    func launchAtLoginToggle() async throws {
        let service = FakeLoginItemService()
        let coordinator = LifecycleCoordinator(
            loginItemService: service,
            activationPolicy: RecordingActivationPolicy()
        )
        #expect(coordinator.launchAtLoginStatus == .notRegistered)
        try coordinator.setLaunchAtLogin(enabled: true)
        #expect(service.registerCount == 1)
        #expect(coordinator.launchAtLoginStatus == .enabled)
        try coordinator.setLaunchAtLogin(enabled: false)
        #expect(service.unregisterCount == 1)
        #expect(coordinator.launchAtLoginStatus == .notRegistered)

        // Denied registration reports honestly and does not fake success.
        service.registerError = LoginItemError.requiresApproval
        #expect(throws: LoginItemError.requiresApproval) {
            try coordinator.setLaunchAtLogin(enabled: true)
        }
        #expect(coordinator.launchAtLoginStatus == .notRegistered)
    }

    // MARK: - Audio capture termination

    @Test("Capture termination maps cleanup outcomes without claiming completion")
    func captureTerminationOutcomes() async {
        let coordinator = LifecycleCoordinator(
            loginItemService: FakeLoginItemService(),
            activationPolicy: RecordingActivationPolicy()
        )

        let verified = coordinator.recordCaptureTermination(reason: .userStop, cleanup: .verifiedAbsence)
        #expect(verified.cleanup == .cleanupVerified)
        #expect(verified.reason == .userStop)

        let retained = coordinator.recordCaptureTermination(reason: .providerFailure, cleanup: .retainedAwaitingExplicitRetry)
        #expect(retained.cleanup == .awaitingExplicitRetryOrSwitch)

        let failed = coordinator.recordCaptureTermination(
            reason: .appTermination,
            cleanup: .failed(privacySafeMessage: "temporary audio could not be removed")
        )
        guard case .incomplete = failed.cleanup else {
            Issue.record("cleanup failure must stay incomplete, got \(failed.cleanup)")
            return
        }
        #expect(!failed.details.contains("audio.caf"))

        // A recoverable-retention outcome with a terminal reason still ends in
        // verified cleanup only when the caller proves absence.
        let malformed = coordinator.recordCaptureTermination(reason: .malformedAudio, cleanup: .verifiedAbsence)
        #expect(malformed.cleanup == .cleanupVerified)
    }

    // MARK: - Window Activation Policy Transitions

    @Test("Window presentation elevates activation policy to regular and closing reverts to accessory")
    func windowActivationPolicyTransitions() async {
        let policy = RecordingActivationPolicy()
        let coordinator = LifecycleCoordinator(
            loginItemService: FakeLoginItemService(),
            activationPolicy: policy
        )
        await coordinator.applicationDidFinishLaunching()
        #expect(policy.appliedPolicies == [.accessory])
        #expect(coordinator.keepsMenuBarLifecycle)
        #expect(coordinator.currentActivationPolicy == .accessory)

        // Window presentation: elevates to .regular
        coordinator.transitionToRegular()
        #expect(policy.appliedPolicies == [.accessory, .regular])
        #expect(policy.currentPolicy() == .regular)
        #expect(coordinator.currentActivationPolicy == .regular)
        #expect(!coordinator.keepsMenuBarLifecycle)

        // Window close: reverts cleanly to .accessory
        coordinator.transitionToAccessory()
        #expect(policy.appliedPolicies == [.accessory, .regular, .accessory])
        #expect(policy.currentPolicy() == .accessory)
        #expect(coordinator.currentActivationPolicy == .accessory)
        #expect(coordinator.keepsMenuBarLifecycle)
    }

    @Test("Repeated window elevations and closes preserve clean activation policy sequence")
    func repeatedWindowElevationCycles() async {
        let policy = RecordingActivationPolicy()
        let coordinator = LifecycleCoordinator(
            loginItemService: FakeLoginItemService(),
            activationPolicy: policy
        )
        await coordinator.applicationDidFinishLaunching()

        // Cycle 1: Open and close
        coordinator.transitionToRegular()
        #expect(coordinator.currentActivationPolicy == .regular)
        coordinator.transitionToAccessory()
        #expect(coordinator.currentActivationPolicy == .accessory)

        // Cycle 2: Reopen (e.g. applicationShouldHandleReopen) and close
        coordinator.transitionToRegular()
        #expect(coordinator.currentActivationPolicy == .regular)
        coordinator.transitionToAccessory()
        #expect(coordinator.currentActivationPolicy == .accessory)

        #expect(policy.appliedPolicies == [.accessory, .regular, .accessory, .regular, .accessory])
    }

    @Test("MenuBarController openMainWindow elevates policy and closeMainWindow reverts policy")
    func menuBarControllerWindowElevation() async {
        let policy = RecordingActivationPolicy()
        let coordinator = LifecycleCoordinator(
            loginItemService: FakeLoginItemService(),
            activationPolicy: policy
        )
        let controller = MenuBarController(lifecycleCoordinator: coordinator, keepDockIconVisible: false)
        await coordinator.applicationDidFinishLaunching()

        #expect(policy.appliedPolicies.contains(.accessory))

        // Open window elevates to regular
        controller.openMainWindow()
        #expect(coordinator.currentActivationPolicy == .regular)
        #expect(policy.appliedPolicies.contains(.regular))

        // Close window reverts to accessory
        controller.closeMainWindow()
        #expect(coordinator.currentActivationPolicy == .accessory)
        #expect(policy.appliedPolicies.last == .accessory)
    }

    @Test("MenuBarController status item icon updates responsively based on state")
    func menuBarControllerStatusIconUpdates() async {
        let controller = MenuBarController()
        #expect(controller.menuBarSystemImageName == "waveform")

        // Refining phase updates icon to sparkles
        controller.sessionPhase = .refining
        #expect(controller.menuBarSystemImageName == "sparkles")

        // Blocked updates icon to waveform.slash
        controller.sessionPhase = .blocked
        #expect(controller.menuBarSystemImageName == "waveform.slash")

        // Failed updates icon to waveform.slash
        controller.sessionPhase = .failed
        #expect(controller.menuBarSystemImageName == "waveform.slash")

        // Idle restores crisp waveform
        controller.sessionPhase = .idle
        #expect(controller.menuBarSystemImageName == "waveform")
    }

    @Test("MenuBarController openMainWindow handles reopen and focuses existing window")
    func menuBarControllerReopenFocusesWindow() async {
        let policy = RecordingActivationPolicy()
        let coordinator = LifecycleCoordinator(
            loginItemService: FakeLoginItemService(),
            activationPolicy: policy
        )
        let controller = MenuBarController(lifecycleCoordinator: coordinator, keepDockIconVisible: false)
        await coordinator.applicationDidFinishLaunching()

        controller.openMainWindow()
        #expect(coordinator.currentActivationPolicy == .regular)

        // Calling openMainWindow again (e.g. from applicationShouldHandleReopen)
        controller.openMainWindow()
        #expect(coordinator.currentActivationPolicy == .regular)

        controller.closeMainWindow()
        #expect(coordinator.currentActivationPolicy == .accessory)
    }
}

enum LifecycleStepError: Error, Equatable {
    case failed
}
