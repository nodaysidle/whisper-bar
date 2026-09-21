import SwiftUI

// MARK: - Setup Tab

/// The deterministic first-run path: one ordered list of the required steps,
/// each with a reachable in-app control, plus the in-app dictation controls so a
/// fresh install can dictate before any shortcut exists.
struct SetupSettingsView: View {
    @Bindable var controller: MenuBarController

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("Application", value: AppIdentity.appName)
                LabeledContent("Status", value: controller.statusText)
                LabeledContent("Local history", value: controller.storageSummary)
                Button("Refresh status") {
                    Task {
                        await controller.refreshStorageSummary()
                        await controller.refreshPermissionStates()
                    }
                }
                .accessibilityIdentifier(MenuControlID.permissionRefresh)
                .accessibilityLabel("Refresh status")
            }

            Section("Setup steps") {
                SetupStepRow(
                    step: 1,
                    title: "Choose a transcription provider",
                    detail: controller.providerSummary,
                    actionTitle: "Open Providers & Keys"
                ) {
                    controller.selectedSettingsTab = .providers
                }

                SetupStepRow(
                    step: 2,
                    title: "Add the API key for the selected provider",
                    detail: credentialDetail,
                    actionTitle: "Enter the API key"
                ) {
                    controller.selectedSettingsTab = .providers
                }

                SetupStepRow(
                    step: 3,
                    title: "Grant Microphone access for dictation",
                    detail: "Microphone: \(permissionText(.microphone))",
                    actionTitle: "Request Microphone access"
                ) {
                    Task { _ = await controller.requestPermission(.microphone) }
                }

                SetupStepRow(
                    step: 4,
                    title: "Set up the global shortcuts (optional — the in-app controls always work)",
                    detail: controller.hotkeyRegistrationSummary,
                    actionTitle: "Use safe defaults"
                ) {
                    Task { _ = await controller.useSafeDefaultHotkeys() }
                }

                SetupStepRow(
                    step: 5,
                    title: "Try dictation from here",
                    detail: "Start, stop, or cancel a recording with the in-app controls.",
                    actionTitle: nil,
                    action: nil
                )
                DictationControls(controller: controller)
            }

            Section("Startup") {
                Toggle("Launch WhisperBar at login", isOn: Binding(
                    get: { controller.launchAtLoginStatus == .enabled },
                    set: { enabled in Task { _ = await controller.setLaunchAtLogin(enabled) } }
                ))
                .accessibilityIdentifier(MenuControlID.launchAtLoginToggle)
                .accessibilityLabel("Launch WhisperBar at login")

                Text("Launch at login: \(MenuBarController.describe(loginItemStatus: controller.launchAtLoginStatus))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let feedback = controller.launchAtLoginFeedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let guidance = controller.permissionGuidance(for: .backgroundStartup) {
                    Text(guidance)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let message = controller.lastErrorMessage {
                Section("Attention") {
                    Text(message)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Privacy") {
                Text("WhisperBar keeps transcripts, credentials, and audio inside their declared local boundaries. Credentials live only in the macOS Keychain; audio exists only for the active request.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var credentialDetail: String {
        guard let provider = controller.selectedProvider else {
            return "Select a provider first; recording stays blocked until you do."
        }
        let key: CredentialKey = switch provider {
        case .deepgramStreaming: .deepgramNovaStreamingTranscription
        case .openRouterBatch: .openRouter
        }
        switch controller.credentialStatuses[key] ?? .missing {
        case .configured: return "A \(key.displayName) key is stored in the Keychain."
        case .missing: return "No \(key.displayName) key is stored yet."
        case .unavailable: return "The \(key.displayName) key could not be read from the Keychain."
        }
    }

    private func permissionText(_ domain: PermissionDomain) -> String {
        guard let state = controller.permissionStates[domain] else {
            return "not checked yet — use Refresh status"
        }
        return MenuBarController.describe(permissionState: state)
    }
}

// MARK: - Setup Step Row

/// One numbered setup step with a single deterministic action.
struct SetupStepRow: View {
    let step: Int
    let title: String
    let detail: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(step).")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.callout)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .accessibilityLabel(actionTitle)
            }
        }
        .padding(.vertical, 2)
    }
}
