import SwiftUI

/// Locked application entry (TRD "Runtime Architecture Contracts"):
/// one SwiftUI App with MenuBarExtra and Settings; all presentation state is
/// owned by the single @Observable @MainActor MenuBarController.
@main
struct WhisperbarApp: App {
    @State private var controller: MenuBarController
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var lifecycleDelegate

    init() {
        let controller = MenuBarController()
        AppWire.controller = controller
        _controller = State(initialValue: controller)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(controller: controller)
        } label: {
            Image(systemName: controller.menuBarSystemImageName)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsWindow(controller: controller)
        }
    }
}
