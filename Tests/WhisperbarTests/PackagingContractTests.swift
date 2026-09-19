import Foundation
import Testing

/// TASK-18-PACKAGING contract checks (TRD "Security Contract" +
/// "Packaging Contract").
///
/// These checks pin the packaging authority (Scripts/package_app.sh) and the
/// reviewed packaging inputs (Resources/Info.plist, Resources/App.entitlements,
/// Resources/AppIcon.icns) to CON-PACKAGING-RELEASE and CON-SECURITY-BOUNDARY.
/// They fail on identity drift, on any packaging input that is not the reviewed
/// artifact, and on an unguarded /Applications install path.
@Suite("Packaging — CON-PACKAGING-RELEASE / CON-SECURITY-BOUNDARY")
struct PackagingContractTests {

    // MARK: - Helpers

    static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)          // …/Tests/WhisperbarTests/PackagingContractTests.swift
            .deletingLastPathComponent()          // …/Tests/WhisperbarTests
            .deletingLastPathComponent()          // …/Tests
            .deletingLastPathComponent()          // …/
    }

    static func packagingFile(_ relativePath: String) -> URL {
        repoRoot().appendingPathComponent(relativePath)
    }

    static func text(at relativePath: String) throws -> String {
        try String(contentsOf: packagingFile(relativePath), encoding: .utf8)
    }

    static func plistDictionary(at relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: packagingFile(relativePath))
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dictionary = object as? [String: Any] else {
            struct NotADictionary: Error {}
            throw NotADictionary()
        }
        return dictionary
    }

    static func string(_ dictionary: [String: Any], _ key: String) -> String? {
        dictionary[key] as? String
    }

    static func bool(_ dictionary: [String: Any], _ key: String) -> Bool? {
        (dictionary[key] as? NSNumber)?.boolValue
    }

    /// True only when `first` and `second` both appear and `first` comes first.
    /// A missing token also fails, so presence is covered by the same check.
    static func precedes(_ first: String, _ second: String, in text: String) -> Bool {
        guard let firstRange = text.range(of: first),
              let secondRange = text.range(of: second) else { return false }
        return firstRange.lowerBound < secondRange.lowerBound
    }

    // MARK: - Declared packaging files

    @Test("Packaging files exist at the exact declared paths")
    func packagingFilesExist() {
        let expected = [
            "Scripts/package_app.sh",
            "Tests/WhisperbarTests/PackagingContractTests.swift",
            "Resources/Info.plist",
            "Resources/App.entitlements",
            "Resources/AppIcon.icns"
        ]
        for relative in expected {
            #expect(
                FileManager.default.fileExists(atPath: Self.packagingFile(relative).path),
                "missing \(relative)"
            )
        }
    }

    @Test("package_app.sh is executable and fail-closed")
    func scriptIsExecutableAndFailClosed() throws {
        let scriptURL = Self.packagingFile("Scripts/package_app.sh")
        #expect(
            FileManager.default.isExecutableFile(atPath: scriptURL.path),
            "Scripts/package_app.sh must carry the executable bit"
        )
        let script = try Self.text(at: "Scripts/package_app.sh")
        #expect(script.hasPrefix("#!/bin/bash"), "missing bash shebang")
        #expect(script.contains("set -euo pipefail"), "missing fail-closed shell options")
        #expect(script.contains("exit 1"), "missing non-zero exit path")
        #expect(script.contains("Package.swift"), "must resolve and guard the repository root")
        #expect(script.contains("Swift Package Manager"), "must document the SPM release build authority")
    }

    @Test("Script builds the arm64 release and rejects a non-arm64 executable")
    func scriptBuildsArm64Release() throws {
        let script = try Self.text(at: "Scripts/package_app.sh")
        #expect(script.contains("swift build -c release --arch arm64"))
        // Canonical SPM product location plus the current build-system layout.
        #expect(script.contains(".build/arm64-apple-macosx/release/Whisperbar"))
        #expect(script.contains(".build/release/Whisperbar"))
        #expect(script.contains("lipo -archs"))
        #expect(script.contains("arm64"), "must assert the arm64 architecture")
        #expect(script.contains("otool"), "must read the Mach-O build version")
        #expect(script.contains("minos"), "must compare the binary deployment target")
        #expect(script.contains("LSMinimumSystemVersion"), "must keep plist/binary deployment targets consistent")
    }

    @Test("Script assembles the locked bundle layout and signs once with entitlements")
    func scriptAssemblesAndSigns() throws {
        let script = try Self.text(at: "Scripts/package_app.sh")
        for token in [
            "dist/WhisperBar.app",
            "Contents/MacOS",
            "Contents/Resources",
            "Contents/Info.plist",
            "AppIcon.icns",
            "codesign --force --sign",
            "Resources/App.entitlements",
            "codesign --verify --deep --strict"
        ] {
            #expect(script.contains(token), "missing \(token)")
        }
        // Ad-hoc local default with an explicit distribution identity override.
        #expect(script.contains("${WHISPERBAR_SIGN_IDENTITY:--}"), "ad-hoc identity must be the default")
        #expect(script.contains("security find-identity"), "distribution identities must be validated")
        // Strict verification must precede DMG creation.
        #expect(Self.precedes("codesign --verify --deep --strict", "hdiutil create", in: script))
    }

    @Test("Script creates the DMG after verification")
    func scriptCreatesDMG() throws {
        let script = try Self.text(at: "Scripts/package_app.sh")
        #expect(script.contains("dist/WhisperBar.dmg"), "the DMG is the second declared output artifact")
        #expect(script.contains("hdiutil create"))
        #expect(script.contains("hdiutil verify"), "the produced DMG must be verified")
        #expect(Self.precedes("dist/WhisperBar.app", "dist/WhisperBar.dmg", in: script))
    }

    @Test("Script never installs to /Applications without explicit approval")
    func scriptInstallRequiresApproval() throws {
        let script = try Self.text(at: "Scripts/package_app.sh")
        #expect(script.contains("--install"), "install must be an explicit opt-in flag")
        let branchMarker = "if [ \"$INSTALL\" -eq 1 ]"
        #expect(script.contains(branchMarker), "install must sit behind its own branch")
        #expect(script.contains("/Applications/WhisperBar.app"))
        // LaunchServices registration and identity-verified launch.
        #expect(script.contains("BUNDLE_ID=\"com.whisperbar.app\""))
        #expect(script.contains("lsregister"))
        #expect(script.contains("open -b \"$BUNDLE_ID\""))
        #expect(script.contains("lsappinfo"), "must verify the running bundle identity")
        // Inside the install branch only: approval must gate the install copy.
        if let branchRange = script.range(of: branchMarker) {
            let branch = String(script[branchRange.lowerBound...])
            #expect(branch.contains("WHISPERBAR_ALLOW_APPLICATIONS_INSTALL"), "install branch must check the approval gate")
            #expect(Self.precedes("WHISPERBAR_ALLOW_APPLICATIONS_INSTALL", "ditto \"$APP_BUNDLE\" \"$INSTALL_TARGET\"", in: branch))
        } else {
            Issue.record("install branch marker not found")
        }
    }

    // MARK: - Info.plist

    @Test("Info.plist carries exactly the locked bundle identity")
    func infoPlistIdentity() throws {
        let plist = try Self.plistDictionary(at: "Resources/Info.plist")
        let expectedKeys = Set([
            "CFBundleIdentifier",
            "CFBundleName",
            "CFBundleExecutable",
            "CFBundleIconFile",
            "CFBundlePackageType",
            "CFBundleShortVersionString",
            "CFBundleVersion",
            "LSMinimumSystemVersion",
            "NSHighResolutionCapable",
            "NSMicrophoneUsageDescription",
            "LSUIElement"
        ])
        #expect(Set(plist.keys) == expectedKeys, "unexpected Info.plist keys: \(Set(plist.keys).symmetricDifference(expectedKeys))")
        #expect(Self.string(plist, "CFBundleIdentifier") == "com.whisperbar.app")
        #expect(Self.string(plist, "CFBundleName") == "WhisperBar")
        #expect(Self.string(plist, "CFBundleExecutable") == "Whisperbar")
        #expect(Self.string(plist, "CFBundleIconFile") == "AppIcon")
        #expect(Self.string(plist, "CFBundlePackageType") == "APPL")
        #expect(Self.string(plist, "CFBundleShortVersionString") == "1.0.0")
        #expect(Self.string(plist, "CFBundleVersion") == "1")
        #expect(Self.bool(plist, "NSHighResolutionCapable") == true)
        #expect(Self.bool(plist, "LSUIElement") == true, "menu-bar lifecycle requires LSUIElement")
        #expect(
            Self.string(plist, "NSMicrophoneUsageDescription")
                == "WhisperBar uses the microphone only while you explicitly record dictation."
        )
    }

    @Test("Info.plist deployment target matches the real binary deployment target")
    func infoPlistDeploymentTargetConsistency() throws {
        // The packaged plist must stay internally consistent with the binary
        // that Package.swift actually builds (@Observable requires macOS 14).
        let manifest = try Self.text(at: "Package.swift")
        let expected: String
        if manifest.contains(".macOS(.v14)") {
            expected = "14.0"
        } else if manifest.contains(".macOS(.v13)") {
            expected = "13.0"
        } else {
            Issue.record("Package.swift declares an unsupported macOS platform literal")
            return
        }
        let plist = try Self.plistDictionary(at: "Resources/Info.plist")
        #expect(Self.string(plist, "LSMinimumSystemVersion") == expected)
    }

    // MARK: - Entitlements

    @Test("Entitlements file is the reviewed empty dictionary")
    func entitlementsAreEmpty() throws {
        let data = try Data(contentsOf: Self.packagingFile("Resources/App.entitlements"))
        #expect(data.starts(with: Array("<?xml".utf8)), "entitlements must be an XML plist")
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        let dictionary = object as? [String: Any]
        #expect(dictionary != nil, "entitlements root must be a dictionary")
        #expect(dictionary?.isEmpty == true, "the local unsandboxed build ships an empty entitlements dictionary")
        let raw = try Self.text(at: "Resources/App.entitlements")
        #expect(!raw.contains("com.apple.security"), "sandbox or broad entitlements must stay absent")
        #expect(!raw.contains("get-task-allow"))
    }

    // MARK: - Icon

    @Test("AppIcon.icns is a valid, non-placeholder icon")
    func appIconIsValid() throws {
        let data = try Data(contentsOf: Self.packagingFile("Resources/AppIcon.icns"))
        #expect(data.count > 15_000, "a real icon container is larger than a placeholder stub")
        #expect(data.count > 8)
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "icns", "missing ICNS magic")
        let declaredLength = UInt32(data[4]) << 24 | UInt32(data[5]) << 16 | UInt32(data[6]) << 8 | UInt32(data[7])
        #expect(Int(declaredLength) == data.count, "ICNS header length must match the file size")

        // Walk the icon table of contents and collect typed elements.
        var elements: [String: Data] = [:]
        var offset = 8
        while offset + 8 <= data.count {
            let type = String(decoding: data[offset ..< offset + 4], as: UTF8.self)
            let size = Int(UInt32(data[offset + 4]) << 24 | UInt32(data[offset + 5]) << 16
                | UInt32(data[offset + 6]) << 8 | UInt32(data[offset + 7]))
            #expect(size >= 8, "ICNS element \(type) has an invalid size")
            #expect(offset + size <= data.count, "ICNS element \(type) overruns the file")
            elements[type] = data.subdata(in: (offset + 8) ..< (offset + size))
            offset += size
        }
        #expect(offset == data.count, "ICNS elements must tile the whole file")

        let pngDimensions: [String: Int] = [
            "ic07": 128, "ic08": 256, "ic09": 512, "ic10": 1024,
            "ic11": 32, "ic12": 64, "ic13": 256, "ic14": 512,
            "icp4": 16, "icp5": 32, "icp6": 64
        ]
        let pngTypes = elements.keys.filter { pngDimensions[$0] != nil }
        #expect(pngTypes.count >= 5, "icon must carry the full rendered size ladder, found \(pngTypes.sorted())")
        #expect(elements["ic10"] != nil, "icon must include the 1024pt representation")

        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        for (type, payload) in elements where pngDimensions[type] != nil {
            #expect(payload.starts(with: pngSignature), "\(type) must embed a PNG")
            guard payload.count >= 24 else { continue }
            let width = Int(UInt32(payload[16]) << 24 | UInt32(payload[17]) << 16 | UInt32(payload[18]) << 8 | UInt32(payload[19]))
            let height = Int(UInt32(payload[20]) << 24 | UInt32(payload[21]) << 16 | UInt32(payload[22]) << 8 | UInt32(payload[23]))
            #expect(width == pngDimensions[type] && width == height, "\(type) must be a \(pngDimensions[type] ?? 0)px square")
        }
        // Non-placeholder: real rendered pixels carry a wide byte-value spread.
        #expect(Set(data).count > 64, "icon data looks synthetic")
    }

    // MARK: - Security boundary

    @Test("Packaging artifacts carry no secret material and no competing packaging code")
    func noSecretsOrCompetingPackaging() throws {
        let secretPrefixes = ["sk-", "sk_", "dg_", "Bearer ey", "Token ey", "api_key"]
        for relative in ["Scripts/package_app.sh", "Resources/Info.plist", "Resources/App.entitlements"] {
            let text = try Self.text(at: relative)
            for prefix in secretPrefixes {
                #expect(!text.contains(prefix), "possible secret material \(prefix) in \(relative)")
            }
        }
        let sources = Self.repoRoot().appendingPathComponent("Sources/Whisperbar")
        if let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator {
                #expect(url.lastPathComponent != "Packaging.swift", "no competing Swift packaging implementation")
            }
        }
    }
}
