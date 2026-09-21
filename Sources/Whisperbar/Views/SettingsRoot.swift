import SwiftUI

// MARK: - Settings Tabs

/// The settings tabs of the dedicated settings window (CON-LIFECYCLE-PRESET).
/// A fresh install opens on `.setup`, where every required action has a visible
/// in-app control; nothing that the product requires can only be done through
/// an API.
enum SettingsTab: String, CaseIterable, Hashable, Identifiable {
    case setup
    case intelligence
    case providers
    case hotkeys
    case modes
    case history
    case paste

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .setup: return "Setup"
        case .intelligence: return "Intelligence"
        case .providers: return "Providers & Keys"
        case .hotkeys: return "Shortcuts"
        case .modes: return "Modes & Vocabulary"
        case .history: return "History"
        case .paste: return "Paste & Permissions"
        }
    }

    var systemImage: String {
        switch self {
        case .setup: return "checklist"
        case .intelligence: return "sparkles"
        case .providers: return "key"
        case .hotkeys: return "keyboard"
        case .modes: return "text.badge.plus"
        case .history: return "clock.arrow.circlepath"
        case .paste: return "doc.on.clipboard"
        }
    }
}

// MARK: - Settings Root

struct SettingsRoot: View {
    @Bindable var controller: MenuBarController

    var body: some View {
        TabView(selection: $controller.selectedSettingsTab) {
            SetupSettingsView(controller: controller)
                .tabItem { Label(SettingsTab.setup.displayName, systemImage: SettingsTab.setup.systemImage) }
                .tag(SettingsTab.setup)
            JevIntelligenceSettingsView(controller: controller)
                .tabItem { Label(SettingsTab.intelligence.displayName, systemImage: SettingsTab.intelligence.systemImage) }
                .tag(SettingsTab.intelligence)
            ProvidersSettingsView(controller: controller)
                .tabItem { Label(SettingsTab.providers.displayName, systemImage: SettingsTab.providers.systemImage) }
                .tag(SettingsTab.providers)
            HotkeysSettingsView(controller: controller)
                .tabItem { Label(SettingsTab.hotkeys.displayName, systemImage: SettingsTab.hotkeys.systemImage) }
                .tag(SettingsTab.hotkeys)
            ModesSettingsView(controller: controller)
                .tabItem { Label(SettingsTab.modes.displayName, systemImage: SettingsTab.modes.systemImage) }
                .tag(SettingsTab.modes)
            HistorySettingsView(controller: controller)
                .tabItem { Label(SettingsTab.history.displayName, systemImage: SettingsTab.history.systemImage) }
                .tag(SettingsTab.history)
            PasteSettingsView(controller: controller)
                .tabItem { Label(SettingsTab.paste.displayName, systemImage: SettingsTab.paste.systemImage) }
                .tag(SettingsTab.paste)
        }
        .padding(16)
        .accessibilityIdentifier(MenuControlID.settingsTab)
        .accessibilityLabel("WhisperBar settings tabs")
    }
}
