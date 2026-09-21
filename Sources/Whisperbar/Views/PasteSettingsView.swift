import SwiftUI

// MARK: - Paste and Permissions Tab

struct PasteSettingsView: View {
    @Bindable var controller: MenuBarController

    var body: some View {
        Form {
            Section("Insertion mode") {
                Picker("Insertion mode", selection: Binding(
                    get: { controller.pasteMode },
                    set: { controller.setPasteMode($0) }
                )) {
                    Text("Auto-paste").tag(PasteMode.autoPaste)
                    Text("Copy only").tag(PasteMode.copyOnly)
                    Text("Preview first").tag(PasteMode.preview)
                }
                .accessibilityLabel("Insertion mode")

                Text("Auto-paste prefers direct Accessibility insertion, snapshots the clipboard before any write, restores it only while WhisperBar still owns it, and never overwrites newer clipboard content. Copy-only leaves the transcript on the clipboard; preview inserts nothing until you approve it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let feedback = controller.pasteFeedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Clipboard behavior") {
                Toggle("Restore previous clipboard after auto-paste", isOn: Binding(
                    get: { controller.restoreClipboardAfterPaste },
                    set: { newValue in
                        Task { await controller.setRestoreClipboardAfterPaste(newValue) }
                    }
                ))
                Text("When disabled (default), the transcript remains on your clipboard so you can manually press ⌘V in apps like Antinote that reject synthetic paste events.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Preview and recovery") {
                if let preview = controller.pendingPreviewText {
                    Text("Waiting for explicit approval:")
                        .font(.callout)
                    Text(preview)
                        .font(.callout)
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Insert") {
                            Task { _ = await controller.approvePastePreview() }
                        }
                        .accessibilityIdentifier(MenuControlID.pasteApprove)
                        .accessibilityLabel("Approve preview and insert")
                        Button("Cancel preview") {
                            _ = controller.cancelPastePreview()
                        }
                        .accessibilityIdentifier(MenuControlID.pasteCancel)
                        .accessibilityLabel("Cancel preview")
                    }
                } else {
                    Text(controller.isPreviewAwaitingApproval
                        ? "A preview is waiting for approval."
                        : "No preview is waiting for approval.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let retained = controller.retainedPasteText {
                    Text("Preserved after an insertion failure:")
                        .font(.callout)
                    Text(retained)
                        .font(.callout)
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Copy the transcript") {
                            _ = controller.copyRetainedPasteText()
                        }
                        .accessibilityIdentifier(MenuControlID.pasteCopyRetained)
                        .accessibilityLabel("Copy the preserved transcript")
                        Button("Retry insertion") {
                            Task { _ = await controller.retryPasteInsertion() }
                        }
                        .accessibilityIdentifier(MenuControlID.pasteRetry)
                        .accessibilityLabel("Retry the insertion")
                    }
                }
            }

            Section("Permissions and access") {
                HStack {
                    Button("Refresh permission status") {
                        Task { await controller.refreshPermissionStates() }
                    }
                    .accessibilityIdentifier(MenuControlID.permissionRefresh)
                    .accessibilityLabel("Refresh permission status")
                    Text("Every read is read-only; nothing is prompted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(PermissionDomain.allCases, id: \.self) { domain in
                    PermissionRow(controller: controller, domain: domain)
                }

                if let feedback = controller.permissionFeedback {
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

// MARK: - Permission Row

/// One permission or access domain: its value-free state, the actionable
/// guidance, and the explicit request control where a prompt exists.
struct PermissionRow: View {
    let controller: MenuBarController
    let domain: PermissionDomain

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(domain.displayName)
                    .font(.callout)
                Spacer()
                Text(stateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if domain.supportsExplicitRequest {
                    Button("Request") {
                        Task { _ = await controller.requestPermission(domain) }
                    }
                    .accessibilityIdentifier(MenuControlID.permissionRequest)
                    .accessibilityLabel("Request \(domain.displayName) access")
                }
            }
            if let guidance = controller.permissionGuidance(for: domain) {
                Text(guidance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let manual = controller.permissionManualPath(for: domain) {
                Text(manual)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private var stateText: String {
        guard let state = controller.permissionStates[domain] else { return "not checked yet" }
        return MenuBarController.describe(permissionState: state)
    }
}

extension PermissionDomain {
    /// The domains whose system prompt can be raised from the explicit request
    /// control. Every other domain is managed entirely by its own explicit
    /// toggle or by the operating system.
    var supportsExplicitRequest: Bool {
        switch self {
        case .microphone, .accessibility, .notifications:
            return true
        case .clipboard, .globalInput, .filesystem, .network, .backgroundStartup:
            return false
        }
    }
}
