import SwiftUI

// MARK: - Providers Tab

struct ProvidersSettingsView: View {
    @Bindable var controller: MenuBarController

    var body: some View {
        Form {
            Section("Transcription provider") {
                ProviderQuickPicker(controller: controller)
                Text("The selection is explicit and stays fixed for a recording. WhisperBar never switches providers, never falls back, and never retries a paid request automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("API keys (stored only in the macOS Keychain)") {
                HStack {
                    Button("Refresh key status") {
                        Task { await controller.refreshCredentialStatuses() }
                    }
                    .accessibilityIdentifier(MenuControlID.credentialRefresh)
                    .accessibilityLabel("Refresh key status")
                    Text("Only a value-free status is shown; a stored key is never read back.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(CredentialKey.allCases, id: \.self) { key in
                    CredentialRow(controller: controller, key: key)
                }
                if let feedback = controller.credentialFeedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Optional refinement (OpenRouter)") {
                Toggle("Refine each transcript with the selected writing mode", isOn: Binding(
                    get: { controller.refinementEnabled },
                    set: { enabled in Task { _ = await controller.setRefinementEnabled(enabled) } }
                ))
                .accessibilityIdentifier(MenuControlID.refinementToggle)
                .accessibilityLabel("Enable optional refinement")

                Text("Refinement stays off until it is explicitly enabled, uses the stored OpenRouter key, and never replaces the accepted transcript when it fails.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let feedback = controller.refinementFeedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Credential Row

/// One provider credential: entry, save, delete, and test. The entered value is
/// handed to the vault once and never read back into presentation state.
struct CredentialRow: View {
    let controller: MenuBarController
    let key: CredentialKey

    @State private var draft = ""
    @State private var showingDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(key.displayName)
                    .font(.headline)
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SecureField("Paste the \(key.displayName) API key", text: $draft)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("\(MenuControlID.credentialField).\(key.rawValue)")
                .accessibilityLabel("\(key.displayName) API key entry")

            HStack {
                Button("Save key") {
                    let value = draft
                    Task {
                        if await controller.saveCredential(value, for: key) {
                            draft = ""
                        }
                    }
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("\(MenuControlID.credentialSave).\(key.rawValue)")
                .accessibilityLabel("Save \(key.displayName) API key")

                Button("Delete key") {
                    showingDeleteConfirmation = true
                }
                .disabled(!isConfigured)
                .accessibilityIdentifier("\(MenuControlID.credentialDelete).\(key.rawValue)")
                .accessibilityLabel("Delete the stored \(key.displayName) API key")
                .confirmationDialog(
                    "Delete \(key.displayName) Key?",
                    isPresented: $showingDeleteConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Delete key", role: .destructive) {
                        Task { _ = await controller.deleteCredential(for: key) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Are you sure you want to delete the stored \(key.displayName) key from macOS Keychain?")
                }

                Button("Test connection") {
                    Task { _ = await controller.testCredentialConnection(for: key) }
                }
                .disabled(!isConfigured)
                .accessibilityIdentifier("\(MenuControlID.credentialTest).\(key.rawValue)")
                .accessibilityLabel("Test the \(key.displayName) connection")
            }

            if let blocking = controller.credentialBlockingMessage(for: key) {
                Text(blocking)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private var isConfigured: Bool {
        controller.credentialStatuses[key] == .configured
    }

    private var statusText: String {
        switch controller.credentialStatuses[key] ?? .missing {
        case .configured: return "A key is stored"
        case .missing: return "No key stored"
        case .unavailable: return "Keychain unavailable"
        }
    }
}
