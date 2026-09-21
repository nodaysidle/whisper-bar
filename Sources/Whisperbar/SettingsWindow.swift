import SwiftUI

/// Dedicated Settings scene content (CON-LIFECYCLE-PRESET: open a dedicated
/// settings window without changing the default activation policy).
///
/// Refactored for low-noise, intuitive native macOS aesthetics and provides the
/// TypeSafe Jev Intelligence controls.
struct SettingsWindow: View {
    let controller: MenuBarController

    var body: some View {
        controller.settingsView()
            .frame(minWidth: 680, minHeight: 540)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("WhisperBar settings")
    }
}

// MARK: - TypeSafe Jev Intelligence View

/// Sleek, calm, low-noise settings view for TypeSafe Jev smart decision engine.
struct JevIntelligenceSettingsView: View {
    @Bindable var controller: MenuBarController
    @State private var apiKeyDraft: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Header
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("TypeSafe Jev Intelligence")
                            .font(.title3.bold())
                        Text("Real-time speech evaluation, instant paste fast-path, and hallucination filtering.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 4)

                // Master Toggle Card
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Enable Smart Decision Engine (TypeSafe Jev)", isOn: Binding(
                            get: { controller.jevEnabled },
                            set: { enabled in
                                Task { await controller.setJevEnabled(enabled) }
                            }
                        ))
                        .font(.body.weight(.medium))

                        Text("Evaluates speech intent in parallel with minimal latency, intelligently routing to instant paste or writing modes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                // API Key & Status Card
                GroupBox("TypeSafe API Key") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            keyStatusIndicator
                            Spacer()
                            Text(controller.typesafeKeyStatus.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 8) {
                            SecureField("Enter TypeSafe API key (or set TYPESAFE_API_KEY)", text: $apiKeyDraft)
                                .textFieldStyle(.roundedBorder)

                            Button("Save") {
                                let key = apiKeyDraft
                                Task {
                                    if await controller.saveCredential(key, for: .typesafe) {
                                        apiKeyDraft = ""
                                    }
                                }
                            }
                            .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                            if controller.typesafeKeyStatus == .saved {
                                Button("Delete") {
                                    Task {
                                        _ = await controller.deleteCredential(for: .typesafe)
                                    }
                                }
                            }
                        }

                        Text("Keys are stored securely in the macOS Keychain. Environment variable TYPESAFE_API_KEY is used as fallback.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(6)
                }

                // Sub-Toggles Card
                GroupBox("Smart Decision Rules") {
                    VStack(alignment: .leading, spacing: 14) {
                        // Sub-toggle 1: Smart Refinement Gate
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Smart Refinement Gate", isOn: Binding(
                                get: { controller.jevSmartRefinementGateEnabled },
                                set: { enabled in
                                    Task { await controller.setJevSmartRefinementGateEnabled(enabled) }
                                }
                            ))
                            .font(.body.weight(.medium))
                            .disabled(!controller.jevEnabled)

                            Text("Bypasses refinement and pastes immediately when speech is fluent and clear, reducing latency and API usage.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 20)
                        }

                        Divider()

                        // Sub-toggle 2: Auto Writing Mode
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Context-Aware Writing Mode", isOn: Binding(
                                get: { controller.jevAutoWritingModeEnabled },
                                set: { enabled in
                                    Task { await controller.setJevAutoWritingModeEnabled(enabled) }
                                }
                            ))
                            .font(.body.weight(.medium))
                            .disabled(!controller.jevEnabled)

                            Text("Adapts formatting instructions based on the active target application.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 20)
                        }

                        Divider()

                        // Sub-toggle 3: Hallucination Guardrail
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Hallucination Guardrail", isOn: Binding(
                                get: { controller.jevHallucinationGuardrailEnabled },
                                set: { enabled in
                                    Task { await controller.setJevHallucinationGuardrailEnabled(enabled) }
                                }
                            ))
                            .font(.body.weight(.medium))
                            .disabled(!controller.jevEnabled)

                            Text("Silences repetitive transcription loops and background noise artifacts before insertion.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 20)
                        }
                    }
                    .padding(6)
                }
            }
            .padding(20)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("TypeSafe Jev Intelligence Settings")
    }

    @ViewBuilder
    private var keyStatusIndicator: some View {
        HStack(spacing: 6) {
            switch controller.typesafeKeyStatus {
            case .saved:
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("Saved in Keychain").font(.caption.weight(.medium))
            case .configuredViaEnvironment:
                Circle().fill(.blue).frame(width: 8, height: 8)
                Text("Environment Variable").font(.caption.weight(.medium))
            case .missing:
                Circle().fill(.orange).frame(width: 8, height: 8)
                Text("Missing API Key").font(.caption.weight(.medium))
            }
        }
    }
}
