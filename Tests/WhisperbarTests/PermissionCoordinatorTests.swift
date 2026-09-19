import Foundation
import Testing
@testable import Whisperbar

/// TASK-05-PERMISSION-COORDINATOR focused checks.
///
/// Covers CON-PERMISSION-MICROPHONE, CON-PERMISSION-CLIPBOARD,
/// CON-PERMISSION-GLOBAL-INPUT, CON-PERMISSION-ACCESSIBILITY,
/// CON-PERMISSION-NOTIFICATIONS, CON-PERMISSION-FILESYSTEM,
/// CON-PERMISSION-NETWORK, CON-PERMISSION-BACKGROUND-STARTUP through injectable
/// probes. No TCC prompt is ever raised.
@Suite("PermissionCoordinator — permission contracts")
@MainActor
struct PermissionCoordinatorTests {

    // MARK: - Fake probe

    final class FakeProbe: PermissionProbing, @unchecked Sendable {
        private let lock = NSLock()

        var microphoneState: PermissionState = .notDetermined
        var microphoneGranted = true
        var accessibilityState: PermissionState = .authorized
        var accessibilityPromptGranted = true
        var notificationState: PermissionState = .notDetermined
        var notificationRequestGranted = true
        var globalInputState: PermissionState = .authorized

        private(set) var microRequests = 0
        private(set) var accessibilityRequests = 0
        private(set) var notificationRequests = 0
        private(set) var statusReads = 0

        func microphoneAuthorizationStatus() -> PermissionState {
            lock.lock(); defer { lock.unlock() }
            statusReads += 1
            return microphoneState
        }

        func requestMicrophoneAccess() async -> PermissionState {
            lock.withLock {
                microRequests += 1
                microphoneState = microphoneGranted ? .authorized : .denied
                return microphoneState
            }
        }

        func globalInputAvailability() -> PermissionState {
            lock.lock(); defer { lock.unlock() }
            statusReads += 1
            return globalInputState
        }

        func accessibilityTrusted() -> PermissionState {
            lock.lock(); defer { lock.unlock() }
            statusReads += 1
            return accessibilityState
        }

        func requestAccessibilityTrust() -> PermissionState {
            lock.lock(); defer { lock.unlock() }
            accessibilityRequests += 1
            accessibilityState = accessibilityPromptGranted ? .authorized : .denied
            return accessibilityState
        }

        func notificationAuthorizationStatus() async -> PermissionState {
            lock.withLock {
                statusReads += 1
                return notificationState
            }
        }

        func requestNotificationAuthorization() async -> PermissionState {
            lock.withLock {
                notificationRequests += 1
                notificationState = notificationRequestGranted ? .authorized : .denied
                return notificationState
            }
        }

        func clipboardAvailability() -> PermissionState { .authorized }
        func filesystemAvailability() -> PermissionState { .authorized }
        func networkAvailability() -> PermissionState { .authorized }
    }

    final class FakeLoginItems: LoginItemServicing, @unchecked Sendable {
        var statusValue: LoginItemStatus = .notRegistered
        func register() throws {}
        func unregister() throws {}
        func status() -> LoginItemStatus { statusValue }
    }

    private static func makeCoordinator() -> (PermissionCoordinator, FakeProbe, FakeLoginItems) {
        let probe = FakeProbe()
        let loginItems = FakeLoginItems()
        return (PermissionCoordinator(probe: probe, loginItemService: loginItems), probe, loginItems)
    }

    // MARK: - Read-only checks never prompt

    @Test("Status and refresh are read-only and never raise a prompt")
    func checksAreReadOnly() async {
        let (coordinator, probe, _) = Self.makeCoordinator()
        for domain in PermissionDomain.allCases {
            _ = await coordinator.status(of: domain)
            _ = await coordinator.refresh(domain)
        }
        #expect(probe.microRequests == 0)
        #expect(probe.accessibilityRequests == 0)
        #expect(probe.notificationRequests == 0)
        #expect(probe.statusReads > 0)
    }

    // MARK: - Microphone

    @Test("Microphone request happens only on explicit action and maps the outcome")
    func microphoneRequest() async {
        let (coordinator, probe, _) = Self.makeCoordinator()
        probe.microphoneState = .notDetermined
        #expect(await coordinator.status(of: .microphone) == .notDetermined)

        probe.microphoneGranted = false
        let deniedOutcome = await coordinator.request(.microphone)
        #expect(deniedOutcome == .denied)
        #expect(probe.microRequests == 1)
        #expect(coordinator.recoveryGuidance(for: .microphone) != nil)

        probe.microphoneGranted = true
        let grantedOutcome = await coordinator.request(.microphone)
        #expect(grantedOutcome == .authorized)
        #expect(coordinator.recoveryGuidance(for: .microphone) == nil)
    }

    @Test("Microphone usage description matches the locked packaging string")
    func microphoneUsageDescription() {
        #expect(
            PermissionCoordinator.microphoneUsageDescription
                == "WhisperBar uses the microphone only while you explicitly record dictation."
        )
    }

    // MARK: - Accessibility

    @Test("Accessibility denial keeps a manual, non-destructive path")
    func accessibilityDenialKeepsManualPath() async {
        let (coordinator, probe, _) = Self.makeCoordinator()
        probe.accessibilityState = .denied
        #expect(await coordinator.status(of: .accessibility) == .denied)
        #expect(coordinator.recoveryGuidance(for: .accessibility) != nil)
        let manual = coordinator.manualPathDescription(for: .accessibility)
        #expect(manual != nil)
        #expect(manual?.isEmpty == false)

        // Explicit action requests trust; denial leaves the manual path intact.
        probe.accessibilityPromptGranted = false
        #expect(await coordinator.request(.accessibility) == .denied)
        #expect(probe.accessibilityRequests == 1)
        #expect(coordinator.manualPathDescription(for: .accessibility) != nil)
    }

    // MARK: - Notifications

    @Test("Notification denial keeps in-app status and never repeats the prompt")
    func notificationDenialKeepsInAppStatus() async {
        let (coordinator, probe, _) = Self.makeCoordinator()
        probe.notificationState = .denied
        #expect(await coordinator.status(of: .notifications) == .denied)
        #expect(coordinator.recoveryGuidance(for: .notifications) != nil)
        #expect(probe.notificationRequests == 0)

        _ = await coordinator.refresh(.notifications)
        #expect(probe.notificationRequests == 0)
    }

    // MARK: - Global input and background startup

    @Test("Global input denial explains the recovery path without broad capture")
    func globalInputDenial() async {
        let (coordinator, probe, _) = Self.makeCoordinator()
        probe.globalInputState = .denied
        #expect(await coordinator.status(of: .globalInput) == .denied)
        #expect(coordinator.recoveryGuidance(for: .globalInput)?.contains("Input Monitoring") == true)
    }

    @Test("Background startup maps SMAppService states and leaves manual launch available")
    func backgroundStartupMapping() async {
        let (coordinator, _, loginItems) = Self.makeCoordinator()
        loginItems.statusValue = .enabled
        #expect(await coordinator.status(of: .backgroundStartup) == .authorized)
        loginItems.statusValue = .requiresApproval
        #expect(await coordinator.status(of: .backgroundStartup) == .denied)
        #expect(coordinator.manualPathDescription(for: .backgroundStartup) != nil)
        loginItems.statusValue = .notRegistered
        #expect(await coordinator.status(of: .backgroundStartup) == .notDetermined)
    }

    // MARK: - Clipboard, filesystem, network

    @Test("Clipboard, filesystem, and network domains stay usable with explicit boundaries")
    func passiveDomains() async {
        let (coordinator, _, _) = Self.makeCoordinator()
        #expect(await coordinator.status(of: .clipboard) == .authorized)
        #expect(await coordinator.status(of: .filesystem) == .authorized)
        #expect(await coordinator.status(of: .network) == .authorized)
        #expect(coordinator.preservesClipboardRepresentations)
    }
}
