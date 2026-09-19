// swift-tools-version: 6.0
// WhisperBar — locked SwiftPM manifest (TRD "Locked Stack" + "Project Layout").
// No package-wide default isolation: concurrency is expressed with explicit
// @MainActor / actor boundaries per Captain decision 4.
import PackageDescription

let package = Package(
    name: "WhisperBar",
    platforms: [
        // @Observable (locked stack) requires the macOS 14 SDK availability, and
        // the reconciled runtime identity is macOS 14.0 everywhere: this
        // manifest, the packaged Info.plist, the release binary deployment
        // target, AppIdentity, and the contract tests all read 14.0, and
        // Scripts/package_app.sh fails closed if the plist and the binary
        // disagree. It never reads the TRD-locked 13.0 literal.
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Whisperbar", targets: ["Whisperbar"])
    ],
    targets: [
        .executableTarget(
            name: "Whisperbar",
            path: "Sources/Whisperbar",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "WhisperbarTests",
            dependencies: ["Whisperbar"],
            path: "Tests/WhisperbarTests"
        )
    ]
)
