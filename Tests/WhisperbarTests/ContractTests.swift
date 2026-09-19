import Foundation
import Testing
@testable import Whisperbar

/// TASK-01-FOUNDATION contract checks.
///
/// These tests fail on locked-identity drift, stack drift, or forbidden
/// technology substitution across the packet.
@Suite("Contract — locked identity and stack")
struct ContractTests {

    // MARK: - Helpers

    static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)          // …/Tests/WhisperbarTests/ContractTests.swift
            .deletingLastPathComponent()          // …/Tests/WhisperbarTests
            .deletingLastPathComponent()          // …/Tests
            .deletingLastPathComponent()          // …/
    }

    static func sourceFiles() throws -> [URL] {
        let sources = repoRoot().appendingPathComponent("Sources/Whisperbar")
        guard let enumerator = FileManager.default.enumerator(
            at: sources,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { element -> URL? in
            guard let url = element as? URL, url.pathExtension == "swift" else { return nil }
            return url
        }
    }

    // MARK: - Locked identity

    @Test("Locked identity matches the TRD identity block")
    func lockedIdentity() {
        #expect(AppIdentity.bundleIdentifier == "com.whisperbar.app")
        #expect(AppIdentity.appName == "WhisperBar")
        #expect(AppIdentity.executableName == "Whisperbar")
        #expect(AppIdentity.artifactPath == "dist/WhisperBar.app")
        // @Observable is available from macOS 14; keep source identity aligned
        // with Package.swift, the packaged plist, and the Mach-O deployment target.
        #expect(AppIdentity.minimumSystemVersion == "14.0")
        #expect(AppIdentity.shortVersion == "1.0.0")
        #expect(AppIdentity.buildVersion == "1")
        #expect(AppIdentity.packageType == "APPL")
        #expect(AppIdentity.iconFile == "AppIcon")
    }

    @Test("Keychain service and accounts match the credential contracts")
    func credentialIdentity() {
        #expect(AppIdentity.keychainService == "com.whisperbar.app.credentials")
        #expect(AppIdentity.deepgramKeychainAccount == "deepgram-nova-streaming-transcription-api-key")
        #expect(AppIdentity.openRouterKeychainAccount == "openrouter-api-key")
    }

    @Test("Persistence identity matches the persistence contracts")
    func persistenceIdentity() {
        #expect(AppIdentity.databaseFileName == "voice.sqlite3")
        #expect(AppIdentity.applicationSupportDirectoryName == "com.whisperbar.app")
        #expect(AppIdentity.temporaryDirectoryName == "com.whisperbar.app")
    }

    // MARK: - Stack and forbidden technologies

    @Test("Package.swift declares the locked product, platform, and no default isolation")
    func packageManifest() throws {
        let manifest = try String(
            contentsOf: Self.repoRoot().appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        #expect(manifest.contains("swift-tools-version"))
        #expect(manifest.contains(".executable("))
        #expect(manifest.contains("Whisperbar"))
        #expect(manifest.contains(".macOS("))
        #expect(manifest.contains("Sources/Whisperbar"))
        #expect(manifest.contains("Tests/WhisperbarTests"))
        // Captain decision 4: no package-wide MainActor default isolation.
        #expect(!manifest.contains("defaultIsolation"))
        #expect(!manifest.contains("MainActor.self"))
    }

    @Test("Foundation files exist at the exact declared paths")
    func foundationFilesExist() {
        let root = Self.repoRoot()
        let expected = [
            "Package.swift",
            "Sources/Whisperbar/WhisperbarApp.swift",
            "Sources/Whisperbar/MenuBarController.swift",
            "Sources/Whisperbar/SettingsWindow.swift",
            "Tests/WhisperbarTests/ContractTests.swift"
        ]
        for relative in expected {
            #expect(
                FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path),
                "missing \(relative)"
            )
        }
    }

    @Test("App entry uses the locked MenuBarExtra + Settings preset")
    func appEntryMarker() throws {
        let entry = try String(
            contentsOf: Self.repoRoot().appendingPathComponent("Sources/Whisperbar/WhisperbarApp.swift"),
            encoding: .utf8
        )
        #expect(entry.contains("@main"))
        #expect(entry.contains("MenuBarExtra"))
        #expect(entry.contains("Settings"))
        #expect(!entry.contains("WindowGroup"))
        #expect(!entry.contains("NSApplication.shared.run"))
    }

    @Test("MenuBarController carries the locked concurrency markers")
    func controllerMarkers() throws {
        let controller = try String(
            contentsOf: Self.repoRoot().appendingPathComponent("Sources/Whisperbar/MenuBarController.swift"),
            encoding: .utf8
        )
        #expect(controller.contains("@Observable"))
        #expect(controller.contains("@MainActor"))
    }

    @Test("No forbidden technology appears in the package sources")
    func forbiddenTechnologies() throws {
        let forbidden = ["import UIKit", "import Flutter", "import Tauri", "Catalyst", "Electron", "appkit-dock-first"]
        for file in try Self.sourceFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for token in forbidden {
                #expect(!text.contains(token), "forbidden token \(token) in \(file.lastPathComponent)")
            }
        }
    }

    @Test("No secret material is embedded in sources")
    func noEmbeddedSecrets() throws {
        let secretPrefixes = ["sk-", "sk_", "dg_", "Bearer ey", "Token ey"]
        for file in try Self.sourceFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for prefix in secretPrefixes {
                #expect(!text.contains(prefix), "possible secret material \(prefix) in \(file.lastPathComponent)")
            }
        }
    }
}
