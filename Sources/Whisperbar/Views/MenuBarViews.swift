import SwiftUI
import AppKit

// MARK: - Stable Control Identifiers

/// Stable identifiers of every user-facing control. The contract tests fail if
/// one of these controls disappears from the surface, so a capability can never
/// silently regress into an API-only path.
enum MenuControlID {
    static let recordStart = "whisperbar.control.recordStart"
    static let recordStop = "whisperbar.control.recordStop"
    static let recordCancel = "whisperbar.control.recordCancel"
    static let recordingMode = "whisperbar.control.recordingMode"
    static let providerPicker = "whisperbar.control.providerPicker"
    static let temporaryAudioSave = "whisperbar.control.temporaryAudioSave"
    static let temporaryAudioDiscard = "whisperbar.control.temporaryAudioDiscard"
    static let temporaryAudioRetryCleanup = "whisperbar.control.temporaryAudioRetryCleanup"
    static let credentialField = "whisperbar.control.credentialField"
    static let credentialSave = "whisperbar.control.credentialSave"
    static let credentialDelete = "whisperbar.control.credentialDelete"
    static let credentialTest = "whisperbar.control.credentialTest"
    static let credentialRefresh = "whisperbar.control.credentialRefresh"
    static let hotkeyPushToTalk = "whisperbar.control.hotkeyPushToTalk"
    static let hotkeyToggle = "whisperbar.control.hotkeyToggle"
    static let hotkeyApply = "whisperbar.control.hotkeyApply"
    static let hotkeySafeDefault = "whisperbar.control.hotkeySafeDefault"
    static let hotkeyRetry = "whisperbar.control.hotkeyRetry"
    static let modeName = "whisperbar.control.modeName"
    static let modeInstructions = "whisperbar.control.modeInstructions"
    static let modeSave = "whisperbar.control.modeSave"
    static let modeDelete = "whisperbar.control.modeDelete"
    static let vocabularyField = "whisperbar.control.vocabularyField"
    static let vocabularyAdd = "whisperbar.control.vocabularyAdd"
    static let vocabularyRemove = "whisperbar.control.vocabularyRemove"
    static let historySearch = "whisperbar.control.historySearch"
    static let historyCopy = "whisperbar.control.historyCopy"
    static let historyDelete = "whisperbar.control.historyDelete"
    static let historyReload = "whisperbar.control.historyReload"
    static let pasteApprove = "whisperbar.control.pasteApprove"
    static let pasteCancel = "whisperbar.control.pasteCancel"
    static let pasteCopyRetained = "whisperbar.control.pasteCopyRetained"
    static let pasteRetry = "whisperbar.control.pasteRetry"
    static let refinementToggle = "whisperbar.control.refinementToggle"
    static let permissionRefresh = "whisperbar.control.permissionRefresh"
    static let permissionRequest = "whisperbar.control.permissionRequest"
    static let launchAtLoginToggle = "whisperbar.control.launchAtLoginToggle"
    static let settingsTab = "whisperbar.control.settingsTab"
}

// MARK: - Menu Content

struct MenuBarContent: View {
    @Bindable var controller: MenuBarController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: controller.menuBarSystemImageName)
                Text(AppIdentity.appName)
                    .font(.headline)
                Spacer()
                Text(controller.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let message = controller.lastErrorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            DictationControls(controller: controller)

            Divider()

            ProviderQuickPicker(controller: controller)

            if controller.showsTemporaryAudioRecoveryControls {
                Divider()
                TemporaryAudioRecoveryControls(controller: controller)
            }

            if controller.isPreviewAwaitingApproval {
                Divider()
                PastePreviewControls(controller: controller)
            }

            Divider()

            HStack {
                Button("Settings…") {
                    controller.openMainWindow()
                }
                .keyboardShortcut(",", modifiers: .command)

                Spacer()

                Button("Quit WhisperBar") {
                    controller.requestTermination()
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
        .padding(16)
        .frame(width: 360)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("WhisperBar menu")
    }
}

// MARK: - Dictation Controls

/// The in-app record/stop/cancel controls, shared by the menu and the setup
/// surface. They drive the same one session state machine the global shortcuts
/// drive, so dictation is available on a fresh install without any shortcut.
struct DictationControls: View {
    @Bindable var controller: MenuBarController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dictation")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker("Recording mode", selection: $controller.inAppRecordingMode) {
                Text("Hold-to-talk").tag(HotkeyMode.pushToTalk)
                Text("Click Toggle").tag(HotkeyMode.toggle)
            }
            .pickerStyle(.segmented)
            .disabled(controller.isRecordingSessionInFlight)
            .accessibilityIdentifier(MenuControlID.recordingMode)
            .accessibilityLabel("In-app recording mode")

            if controller.inAppRecordingMode == .pushToTalk {
                HStack(spacing: 8) {
                    HoldToTalkButton(controller: controller)

                    Button("Cancel") {
                        Task { _ = await controller.cancelInAppRecording() }
                    }
                    .disabled(!controller.isRecordingSessionInFlight)
                    .accessibilityIdentifier(MenuControlID.recordCancel)
                    .accessibilityLabel("Cancel recording")
                }
            } else {
                HStack(spacing: 8) {
                    Button("Start recording") {
                        Task { _ = await controller.startInAppRecording() }
                    }
                    .disabled(controller.isRecordingSessionInFlight)
                    .accessibilityIdentifier(MenuControlID.recordStart)
                    .accessibilityLabel("Start recording")

                    Button("Stop") {
                        Task { _ = await controller.stopInAppRecording() }
                    }
                    .disabled(!controller.isRecordingSessionInFlight)
                    .accessibilityIdentifier(MenuControlID.recordStop)
                    .accessibilityLabel("Stop recording and transcribe")

                    Button("Cancel") {
                        Task { _ = await controller.cancelInAppRecording() }
                    }
                    .disabled(!controller.isRecordingSessionInFlight)
                    .accessibilityIdentifier(MenuControlID.recordCancel)
                    .accessibilityLabel("Cancel recording")
                }
            }

            if controller.isRecordingSessionInFlight, !controller.interimTranscript.isEmpty {
                Text(controller.interimTranscript)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Interim transcript")
            }
        }
    }
}

/// Dedicated in-app hold-to-talk button that tracks mouse press & release using ButtonStyle.
struct HoldToTalkButton: View {
    let controller: MenuBarController

    var body: some View {
        Button(action: {}) {
            Text(controller.isRecordingSessionActive ? "Release to Finish" : "Press & Hold to Speak")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 165, height: 26)
                .background(controller.isRecordingSessionActive ? Color.red.opacity(0.85) : Color.accentColor)
                .foregroundStyle(.white)
                .cornerRadius(5)
        }
        .buttonStyle(PressTrackingButtonStyle { isPressed in
            if isPressed {
                Task { @MainActor in
                    _ = await controller.startInAppRecording(mode: .pushToTalk)
                }
            } else {
                Task { @MainActor in
                    _ = await controller.stopInAppRecording()
                }
            }
        })
        .accessibilityIdentifier(MenuControlID.recordStart)
        .accessibilityLabel(controller.isRecordingSessionActive ? "Release to finish recording" : "Press and hold to record")
        .accessibilityAction(named: "Start recording") {
            Task { @MainActor in _ = await controller.startInAppRecording(mode: .pushToTalk) }
        }
        .accessibilityAction(named: "Stop recording") {
            Task { @MainActor in _ = await controller.stopInAppRecording() }
        }
    }
}

/// Custom button style that captures press down and release transitions without moving or cancelling the target.
struct PressTrackingButtonStyle: ButtonStyle {
    let onPressChange: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, isPressed in
                onPressChange(isPressed)
            }
    }
}

// MARK: - Provider Quick Picker

/// The compact provider picker of the menu. It writes the explicit selection to
/// both owners through the one controller action, so the two can never drift.
struct ProviderQuickPicker: View {
    let controller: MenuBarController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Transcription provider")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Picker("Provider", selection: providerSelection) {
                Text("No provider (recording stays blocked)").tag(TranscriptionProviderID?.none)
                ForEach(TranscriptionProviderID.allCases, id: \.self) { provider in
                    Text(provider.displayName).tag(TranscriptionProviderID?.some(provider))
                }
            }
            .labelsHidden()
            .disabled(controller.isProviderSelectionLocked)
            .accessibilityIdentifier(MenuControlID.providerPicker)
            .accessibilityLabel("Transcription provider")

            Text(controller.providerSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let feedback = controller.providerFeedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var providerSelection: Binding<TranscriptionProviderID?> {
        Binding(
            get: { controller.selectedProvider },
            set: { newValue in
                Task { _ = await controller.selectProvider(newValue) }
            }
        )
    }
}

// MARK: - Paste Preview Controls

/// Step 14 of CON-PASTE-WORKFLOW: a waiting preview inserts nothing until it is
/// explicitly approved, and cancelling preserves the complete transcript.
struct PastePreviewControls: View {
    let controller: MenuBarController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preview awaiting approval")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let preview = controller.pendingPreviewText {
                Text(preview)
                    .font(.callout)
                    .lineLimit(4)
                    .accessibilityLabel("Transcript preview")
            }
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
        }
    }
}

// MARK: - Temporary Audio Recovery Controls

/// Temporary-audio recovery controls (CON-TEMPORARY-AUDIO-CLEANUP-RECOVERY):
/// after a recoverable provider failure the retained recording can be saved
/// to a user-chosen destination or explicitly discarded, and a cleanup that
/// could not verify absence has its own explicit retry. Nothing here happens
/// automatically, and every control runs the authoritative owner action.
struct TemporaryAudioRecoveryControls: View {
    let controller: MenuBarController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recording recovery")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let feedback = controller.temporaryAudioFeedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if controller.canActOnRetainedTemporaryRecording {
                    Button("Save recording…") {
                        Task { _ = await controller.saveTemporaryRecordingExplicitly() }
                    }
                    .accessibilityIdentifier(MenuControlID.temporaryAudioSave)
                    .accessibilityLabel("Save the retained recording")

                    Button("Discard recording") {
                        Task { _ = await controller.discardTemporaryRecordingExplicitly() }
                    }
                    .accessibilityIdentifier(MenuControlID.temporaryAudioDiscard)
                    .accessibilityLabel("Discard the retained recording")
                }

                if controller.isTemporaryAudioCleanupPending {
                    Button("Retry cleanup") {
                        Task { _ = await controller.retryTemporaryAudioCleanupExplicitly() }
                    }
                    .accessibilityIdentifier(MenuControlID.temporaryAudioRetryCleanup)
                    .accessibilityLabel("Retry temporary audio cleanup")
                }
            }
        }
    }
}
