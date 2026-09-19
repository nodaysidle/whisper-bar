import AppKit
import AVFoundation
import ApplicationServices
import UserNotifications

// MARK: - Permission domains and states

enum PermissionDomain: String, CaseIterable, Sendable {
    case microphone
    case clipboard
    case globalInput
    case accessibility
    case notifications
    case filesystem
    case network
    case backgroundStartup

    var displayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .clipboard: return "Clipboard"
        case .globalInput: return "Global input"
        case .accessibility: return "Accessibility"
        case .notifications: return "Notifications"
        case .filesystem: return "Files and folders"
        case .network: return "Network"
        case .backgroundStartup: return "Launch at login"
        }
    }
}

/// CON-* permission state vocabulary shared with the recovery contracts.
enum PermissionState: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
    case unavailable
}

// MARK: - Probe seam

/// Injectable permission probe so tests never raise a TCC prompt or touch a
/// live permission database.
protocol PermissionProbing: Sendable {
    func microphoneAuthorizationStatus() -> PermissionState
    func requestMicrophoneAccess() async -> PermissionState
    func globalInputAvailability() -> PermissionState
    func accessibilityTrusted() -> PermissionState
    func requestAccessibilityTrust() -> PermissionState
    func notificationAuthorizationStatus() async -> PermissionState
    func requestNotificationAuthorization() async -> PermissionState
    func clipboardAvailability() -> PermissionState
    func filesystemAvailability() -> PermissionState
    func networkAvailability() -> PermissionState
}

/// Live system probe. Read-only checks never prompt; request paths run only
/// from explicit user action in the coordinator.
struct SystemPermissionProbe: PermissionProbing {


    func microphoneAuthorizationStatus() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .unavailable
        }
    }

    func requestMicrophoneAccess() async -> PermissionState {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        return granted ? .authorized : .denied
    }

    /// Carbon RegisterEventHotKey needs no TCC grant; a denial here only
    /// models the documented event-tap path, which the hotkey feature avoids
    /// whenever Carbon registration succeeds.
    func globalInputAvailability() -> PermissionState {
        .authorized
    }

    func accessibilityTrusted() -> PermissionState {
        AXIsProcessTrusted() ? .authorized : .denied
    }

    func requestAccessibilityTrust() -> PermissionState {
        // The SDK exports kAXTrustedCheckOptionPrompt as a mutable global,
        // which Swift 6 rejects from this Sendable adapter. Apple documents
        // this stable dictionary key, so construct it locally as a String.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options) ? .authorized : .denied
    }

    func notificationAuthorizationStatus() async -> PermissionState {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unavailable
        }
    }

    func requestNotificationAuthorization() async -> PermissionState {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            return granted ? .authorized : .denied
        } catch {
            return .denied
        }
    }

    /// NSPasteboard reads/writes require no standing grant; the coordinator
    /// enforces the representation-preserving usage policy instead.
    func clipboardAvailability() -> PermissionState {
        .authorized
    }

    /// NSOpenPanel grants access per explicitly selected location only.
    func filesystemAvailability() -> PermissionState {
        .authorized
    }

    /// URLSession outbound requests are always available to an unsandboxed
    /// local build; the app only contacts the declared services.
    func networkAvailability() -> PermissionState {
        .authorized
    }
}

// MARK: - PermissionCoordinator

/// OWN-PERMISSION-COORDINATOR.
///
/// Read-only status checks never prompt. Requests run only from explicit user
/// action, denials preserve the documented manual paths, and rechecks happen
/// only after explicit user action.
@MainActor
final class PermissionCoordinator {

    static let microphoneUsageDescription = "WhisperBar uses the microphone only while you explicitly record dictation."

    private let probe: PermissionProbing
    private let loginItemService: LoginItemServicing
    private(set) var lastKnownStates: [PermissionDomain: PermissionState] = [:]

    /// NSPasteboard usage is always representation-preserving (CON-PERMISSION-CLIPBOARD).
    let preservesClipboardRepresentations = true

    init(
        probe: PermissionProbing = SystemPermissionProbe(),
        loginItemService: LoginItemServicing = SMAppServiceLoginItemService()
    ) {
        self.probe = probe
        self.loginItemService = loginItemService
    }

    // MARK: Status

    func status(of domain: PermissionDomain) async -> PermissionState {
        let state = await readOnlyStatus(of: domain)
        lastKnownStates[domain] = state
        return state
    }

    /// Explicit recheck after a user action; still read-only.
    @discardableResult
    func refresh(_ domain: PermissionDomain) async -> PermissionState {
        await status(of: domain)
    }

    private func readOnlyStatus(of domain: PermissionDomain) async -> PermissionState {
        switch domain {
        case .microphone: return probe.microphoneAuthorizationStatus()
        case .clipboard: return probe.clipboardAvailability()
        case .globalInput: return probe.globalInputAvailability()
        case .accessibility: return probe.accessibilityTrusted()
        case .notifications: return await probe.notificationAuthorizationStatus()
        case .filesystem: return probe.filesystemAvailability()
        case .network: return probe.networkAvailability()
        case .backgroundStartup: return Self.map(loginItemService.status())
        }
    }

    // MARK: Explicit requests

    /// Explicit user action only. This is the single path that may raise a
    /// system prompt.
    @discardableResult
    func request(_ domain: PermissionDomain) async -> PermissionState {
        let state: PermissionState
        switch domain {
        case .microphone: state = await probe.requestMicrophoneAccess()
        case .accessibility: state = probe.requestAccessibilityTrust()
        case .notifications: state = await probe.requestNotificationAuthorization()
        case .clipboard, .globalInput, .filesystem, .network, .backgroundStartup:
            // No additional prompt exists for these domains: they are managed
            // through explicit feature toggles such as launch at login.
            state = await readOnlyStatus(of: domain)
        }
        lastKnownStates[domain] = state
        return state
    }

    // MARK: Guidance and manual paths

    func recoveryGuidance(for domain: PermissionDomain) -> String? {
        guard lastKnownStates[domain] != .authorized else { return nil }
        switch domain {
        case .microphone:
            return "Enable Microphone access for WhisperBar in System Settings → Privacy & Security → Microphone, then try again."
        case .accessibility:
            return "Enable Accessibility access for WhisperBar in System Settings → Privacy & Security → Accessibility, or keep using the manual copy path."
        case .notifications:
            return "Notifications are disabled for WhisperBar. Status stays visible in the app."
        case .globalInput:
            return "Global shortcuts could not be registered. Check Input Monitoring in System Settings → Privacy & Security, or use the in-app controls."
        case .backgroundStartup:
            return "Launch at login needs approval in System Settings → General → Login Items. You can always start WhisperBar manually."
        case .clipboard, .filesystem, .network:
            return nil
        }
    }

    /// Denied domains that still have a manual, non-destructive path.
    func manualPathDescription(for domain: PermissionDomain) -> String? {
        switch domain {
        case .accessibility:
            return "Copy-only mode keeps the transcript on the clipboard so it can be pasted manually."
        case .backgroundStartup:
            return "Manual launch from Applications remains available."
        case .globalInput:
            return "In-app record and stop controls remain available."
        case .microphone, .clipboard, .filesystem, .network, .notifications:
            return nil
        }
    }

    private static func map(_ status: LoginItemStatus) -> PermissionState {
        switch status {
        case .enabled: return .authorized
        case .requiresApproval: return .denied
        case .notRegistered: return .notDetermined
        case .notFound: return .unavailable
        }
    }
}
