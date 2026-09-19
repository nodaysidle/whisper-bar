import SwiftUI

/// Dedicated Settings scene content (CON-LIFECYCLE-PRESET: open a dedicated
/// settings window without changing the default activation policy).
///
/// This file is frozen after PHASE-01: it only forwards to
/// `MenuBarController.settingsView()`, which later phases extend in their
/// single permitted file (Sources/Whisperbar/MenuBarController.swift).
struct SettingsWindow: View {
    let controller: MenuBarController

    var body: some View {
        controller.settingsView()
            .frame(minWidth: 640, minHeight: 520)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("WhisperBar settings")
    }
}
