import SwiftUI
import AppKit

// MARK: - Shortcuts Tab

/// The editable shortcut setup: a safe default in one action, per-role key and
/// modifier editors, and an explicit conflict-retry path. A rejected
/// configuration leaves the previous shortcuts and the stored configuration
/// untouched.
struct HotkeysSettingsView: View {
    @Bindable var controller: MenuBarController

    @State private var pushToTalkKeyCode: UInt32 = 2
    @State private var pushToTalkModifiers: UInt32 = MenuBarController.controlModifier | MenuBarController.optionModifier
    @State private var toggleKeyCode: UInt32 = 17
    @State private var toggleModifiers: UInt32 = MenuBarController.controlModifier | MenuBarController.optionModifier
    @State private var didLoad = false
    @State private var armedRole: HotkeyRole?

    enum HotkeyRole: Hashable {
        case pushToTalk
        case toggle
    }

    var body: some View {
        Form {
            Section("Active shortcuts") {
                Text(controller.hotkeyRegistrationSummary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("Push-to-talk", value: MenuBarController.describeHotkey(controller.hotkeyConfiguration.pushToTalk))
                LabeledContent("Toggle", value: MenuBarController.describeHotkey(controller.hotkeyConfiguration.toggle))
                HStack {
                    Button("Retry registration") {
                        Task { _ = await controller.retryHotkeyRegistration() }
                    }
                    .accessibilityIdentifier(MenuControlID.hotkeyRetry)
                    .accessibilityLabel("Retry shortcut registration")

                    Button("Reload stored shortcuts") {
                        Task { await controller.loadHotkeyConfiguration() }
                    }
                    .accessibilityLabel("Reload the stored shortcuts")
                }
                if let feedback = controller.hotkeyFeedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Presets") {
                HStack(spacing: 12) {
                    Button("Safe defaults (⌃⌥D / ⌃⌥T)") {
                        Task { _ = await controller.useSafeDefaultHotkeys() }
                    }
                    .accessibilityIdentifier(MenuControlID.hotkeySafeDefault)
                    .accessibilityLabel("Use the safe default shortcuts")

                    Button("Karabiner Hyperkey (⌃⌥⇧⌘T / ⌃⌥⇧⌘D)") {
                        Task { _ = await controller.useKarabinerHyperkeyPreset() }
                    }
                    .accessibilityLabel("Use Karabiner Hyperkey shortcuts")
                }
                Text("Hyperkey preset sets ⌃⌥⇧⌘T for toggle mode and ⌃⌥⇧⌘D for push-to-talk (standard Karabiner ⌃⌥⇧⌘ mapping).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Fn (Globe) Key Push-to-Talk") {
                Toggle("Use Fn (Globe) key for Push-to-Talk", isOn: Binding(
                    get: { controller.useFnKeyForPushToTalk },
                    set: { newValue in
                        Task { await controller.setUseFnKeyForPushToTalk(newValue) }
                    }
                ))
                Text("Press and hold the Fn (Globe) key to speak, release to finish and paste. Works alongside global hotkeys.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Push-to-talk shortcut") {
                HotkeyEditorRow(
                    keyCode: $pushToTalkKeyCode,
                    modifiers: $pushToTalkModifiers,
                    label: "Push-to-talk shortcut",
                    isRecording: Binding(
                        get: { armedRole == .pushToTalk },
                        set: { if $0 { armedRole = .pushToTalk } else if armedRole == .pushToTalk { armedRole = nil } }
                    )
                )
                .accessibilityIdentifier(MenuControlID.hotkeyPushToTalk)
            }

            Section("Toggle shortcut") {
                HotkeyEditorRow(
                    keyCode: $toggleKeyCode,
                    modifiers: $toggleModifiers,
                    label: "Toggle shortcut",
                    isRecording: Binding(
                        get: { armedRole == .toggle },
                        set: { if $0 { armedRole = .toggle } else if armedRole == .toggle { armedRole = nil } }
                    )
                )
                .accessibilityIdentifier(MenuControlID.hotkeyToggle)
            }

            Section("Apply") {
                HStack {
                    Button("Apply shortcuts") {
                        Task {
                            _ = await controller.applyHotkeyConfiguration(editedConfiguration)
                        }
                    }
                    .accessibilityIdentifier(MenuControlID.hotkeyApply)
                    .accessibilityLabel("Apply the edited shortcuts")

                    Button("Disable global shortcuts") {
                        Task { _ = await controller.applyHotkeyConfiguration(.empty) }
                    }
                    .accessibilityLabel("Disable global shortcuts")
                }
                Text("A shortcut needs at least one modifier and the two roles must differ. If a combination is already used by another application it is rejected with an explanation, the previous shortcuts stay active, and you can choose another combination and apply again. The in-app controls keep working either way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            syncEditorFromController()
        }
        .onChange(of: controller.hotkeyConfiguration) { _, _ in
            syncEditorFromController()
        }
    }

    private var editedConfiguration: HotkeyConfiguration {
        HotkeyConfiguration(
            pushToTalk: HotkeyIdentifier(keyCode: pushToTalkKeyCode, modifiers: pushToTalkModifiers),
            toggle: HotkeyIdentifier(keyCode: toggleKeyCode, modifiers: toggleModifiers)
        )
    }

    private func syncEditorFromController() {
        if let pushToTalk = controller.hotkeyConfiguration.pushToTalk {
            pushToTalkKeyCode = pushToTalk.keyCode
            pushToTalkModifiers = pushToTalk.modifiers
        }
        if let toggle = controller.hotkeyConfiguration.toggle {
            toggleKeyCode = toggle.keyCode
            toggleModifiers = toggle.modifiers
        }
    }
}

// MARK: - Shortcut Recorder View Representable

/// Non-intrusive local event monitor that captures keystrokes when in recording mode.
struct ShortcutCaptureView: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onCapture: (UInt32, UInt32) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if isRecording && context.coordinator.monitor == nil {
            context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 { // Escape cancels recording without changing the shortcut
                    onCancel()
                    return nil
                }
                let carbonMods = MenuBarController.carbonModifiers(from: event.modifierFlags)
                guard carbonMods != 0 else {
                    // Ignore bare keystroke without modifiers; never invent synthetic modifiers
                    return nil
                }
                let keyCode = UInt32(event.keyCode)
                onCapture(keyCode, carbonMods)
                return nil // consume the keystroke so it does not trigger other shortcuts
            }
        } else if !isRecording && context.coordinator.monitor != nil {
            if let monitor = context.coordinator.monitor {
                NSEvent.removeMonitor(monitor)
                context.coordinator.monitor = nil
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var monitor: Any?
        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}

// MARK: - Hotkey Editor Row

/// One shortcut editor: interactive keyboard combination recorder with modifier checkboxes & key picker fallback.
struct HotkeyEditorRow: View {
    @Binding var keyCode: UInt32
    @Binding var modifiers: UInt32
    let label: String
    @Binding var isRecording: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button(isRecording ? "Press combination (Esc to cancel)…" : "Record Combination") {
                    isRecording.toggle()
                }
                .buttonStyle(.borderedProminent)
                .tint(isRecording ? .red : .accentColor)
                .accessibilityLabel(isRecording ? "Listening for keystroke" : "Record combination for \(label)")

                Text(MenuBarController.describeHotkey(HotkeyIdentifier(keyCode: keyCode, modifiers: modifiers)))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
            .background(
                ShortcutCaptureView(
                    isRecording: $isRecording,
                    onCapture: { newKeyCode, newModifiers in
                        self.keyCode = newKeyCode
                        self.modifiers = newModifiers
                        self.isRecording = false
                    },
                    onCancel: {
                        self.isRecording = false
                    }
                )
            )

            DisclosureGroup("Manual Key & Modifier Selection") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        modifierToggle("⌃", flag: MenuBarController.controlModifier, name: "Control")
                        modifierToggle("⌥", flag: MenuBarController.optionModifier, name: "Option")
                        modifierToggle("⇧", flag: MenuBarController.shiftModifier, name: "Shift")
                        modifierToggle("⌘", flag: MenuBarController.commandModifier, name: "Command")
                        Button("Set Hyper (⌃⌥⇧⌘)") {
                            modifiers = MenuBarController.hyperModifier
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }

                    Picker("Key", selection: $keyCode) {
                        ForEach(MenuBarController.editableHotkeyKeys, id: \.keyCode) { entry in
                            Text(entry.name).tag(entry.keyCode)
                        }
                    }
                    .accessibilityLabel("\(label) key")
                }
                .padding(.top, 4)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func modifierToggle(_ symbol: String, flag: UInt32, name: String) -> some View {
        Toggle(symbol, isOn: Binding(
            get: { modifiers & flag != 0 },
            set: { isOn in
                if isOn {
                    modifiers |= flag
                } else {
                    modifiers &= ~flag
                }
            }
        ))
        .toggleStyle(.checkbox)
        .accessibilityLabel("\(label) \(name) modifier")
    }
}
