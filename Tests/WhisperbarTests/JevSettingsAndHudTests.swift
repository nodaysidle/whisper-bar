import Foundation
import Testing
@testable import Whisperbar

@Suite("JevSettingsAndHudTests — TypeSafe Jev Settings & Minimalist HUD Badges")
struct JevSettingsAndHudTests {

    // MARK: - DataStore Persistence Tests

    @Test("Jev settings default to enabled and persist modifications")
    func jevSettingsPersistence() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = DataStore(
            applicationSupportBaseURL: tempDir.appendingPathComponent("Support"),
            temporaryBaseURL: tempDir.appendingPathComponent("Temp"),
            userDefaultsSuiteName: "test-jev-settings-\(UUID().uuidString)"
        )

        // Defaults should all be true
        #expect(await store.isJevEnabled() == true)
        #expect(await store.isJevSmartRefinementGateEnabled() == true)
        #expect(await store.isJevAutoWritingModeEnabled() == true)
        #expect(await store.isJevHallucinationGuardrailEnabled() == true)

        // Set to false
        await store.setJevEnabled(false)
        await store.setJevSmartRefinementGateEnabled(false)
        await store.setJevAutoWritingModeEnabled(false)
        await store.setJevHallucinationGuardrailEnabled(false)

        #expect(await store.isJevEnabled() == false)
        #expect(await store.isJevSmartRefinementGateEnabled() == false)
        #expect(await store.isJevAutoWritingModeEnabled() == false)
        #expect(await store.isJevHallucinationGuardrailEnabled() == false)

        // Reset
        await store.resetLightweightSettings()
        #expect(await store.isJevEnabled() == true)
        #expect(await store.isJevSmartRefinementGateEnabled() == true)
        #expect(await store.isJevAutoWritingModeEnabled() == true)
        #expect(await store.isJevHallucinationGuardrailEnabled() == true)
    }

    // MARK: - CredentialVault TypeSafe Status Tests

    final class TestKeychain: KeychainStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: String] = [:]
        func read(account: String, service: String) throws -> String? {
            lock.lock(); defer { lock.unlock() }
            return items[account]
        }
        func store(value: String, account: String, service: String) throws {
            lock.lock(); defer { lock.unlock() }
            items[account] = value
        }
        func delete(account: String, service: String) throws {
            lock.lock(); defer { lock.unlock() }
            items.removeValue(forKey: account)
        }
    }

    final class EnvBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: String] = [:]
        func get(_ key: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            return storage[key]
        }
        func set(_ key: String, _ value: String?) {
            lock.lock(); defer { lock.unlock() }
            if let value { storage[key] = value } else { storage.removeValue(forKey: key) }
        }
    }

    @Test("TypeSafe key status detects missing, environment, and saved keychain origin")
    func typesafeKeyStatusDetection() async throws {
        let keychain = TestKeychain()
        let env = EnvBox()
        let vault = CredentialVault(
            store: keychain,
            service: "test-service",
            environmentProvider: { env.get($0) }
        )

        // 1. Missing
        #expect(await vault.typesafeKeyStatus() == .missing)

        // 2. Configured via environment
        env.set("TYPESAFE_API_KEY", "ts-env-test-key")
        #expect(await vault.typesafeKeyStatus() == .configuredViaEnvironment)

        // 3. Saved in Keychain overrides environment
        try await vault.storeTypesafeKey("ts-keychain-test-key")
        #expect(await vault.typesafeKeyStatus() == .saved)

        // Delete from keychain falls back to environment
        try await vault.deleteTypesafeKey()
        #expect(await vault.typesafeKeyStatus() == .configuredViaEnvironment)

        // Remove environment falls back to missing
        env.set("TYPESAFE_API_KEY", nil)
        #expect(await vault.typesafeKeyStatus() == .missing)
    }

    // MARK: - HUD State & Badge Tests

    @Test("HUD displays calm status pills for fast-path, refinement, and hallucination filtering")
    @MainActor
    func hudStatusPills() async {
        let hudPresenter = FakeHudPresenter()
        let feature = MicrophoneCaptureAndFloatingHudFeature(
            capture: FakeMicrophoneCapture(),
            hudPresenter: hudPresenter
        )

        // Test Instant Paste status pill
        feature.showStatusPill("⚡ Instant Paste")
        #expect(hudPresenter.latest?.isVisible == true)
        #expect(hudPresenter.latest?.statusPill == "⚡ Instant Paste")
        #expect(feature.currentStatusPill == "⚡ Instant Paste")

        // Test Refining status pill
        feature.showStatusPill("✨ Refining...")
        #expect(hudPresenter.latest?.isVisible == true)
        #expect(hudPresenter.latest?.statusPill == "✨ Refining...")
        #expect(feature.currentStatusPill == "✨ Refining...")

        // Test Ignored phantom audio status pill
        feature.showStatusPill("🛡️ Ignored phantom audio")
        #expect(hudPresenter.latest?.isVisible == true)
        #expect(hudPresenter.latest?.statusPill == "🛡️ Ignored phantom audio")
        #expect(feature.currentStatusPill == "🛡️ Ignored phantom audio")

        // Clear status pill hides HUD when not recording
        feature.clearStatusPill()
        #expect(feature.currentStatusPill == nil)
        #expect(hudPresenter.latest?.isVisible == false)
    }

    // MARK: - DualProviderRoutingFeature Jev Sub-Toggles Tests

    @MainActor
    private static func makeRouter(
        store: DataStore,
        jevIntegration: JevDecisionIntegration?,
        frontmostApp: String?
    ) -> DualProviderRoutingFeature {
        let vault = CredentialVault(store: TestKeychain())
        let deepgram = DeepgramNovaStreamingTranscriptionIntegration(credentialVault: vault)
        let batch = OpenrouterTranscriptionIntegration(credentialVault: vault)
        let refinement = OpenrouterRefinementIntegration(credentialVault: vault, isEnabled: true)
        let appProvider: (@MainActor @Sendable () -> String?)?
        if let frontmostApp {
            appProvider = { frontmostApp }
        } else {
            appProvider = nil
        }
        return DualProviderRoutingFeature(
            dataStore: store,
            deepgramIntegration: deepgram,
            refinementIntegration: refinement,
            batchIntegration: batch,
            jevIntegration: jevIntegration,
            frontmostAppProvider: appProvider
        )
    }

    @Test("Master toggle disables Jev evaluation completely")
    @MainActor
    func masterToggleDisablesJev() async {
        let transport = MockJevTransport()
        let jevIntegration = JevDecisionIntegration(
            session: transport.session,
            apiKeyProvider: { "valid-key" }
        )

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DataStore(
            applicationSupportBaseURL: tempDir.appendingPathComponent("Support"),
            temporaryBaseURL: tempDir.appendingPathComponent("Temp"),
            userDefaultsSuiteName: "test-router-jev-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let router = Self.makeRouter(
            store: store,
            jevIntegration: jevIntegration,
            frontmostApp: "Ghostty"
        )

        // Disable Jev
        router.setJevEnabled(false)
        #expect(router.isJevEnabled == false)

        let outcome = await router.evaluateWithJevAndRefine(
            provider: .deepgramStreaming,
            rawTranscript: "ls -la",
            modeName: nil,
            modeInstructions: nil
        )

        // Outcome should have nil jevDecision and zero transport requests
        #expect(outcome.jevDecision == nil)
        #expect(transport.requestCount == 0)
    }

    @Test("Sub-toggle disables Smart Refinement Gate (clean speech is not fast-pathed)")
    @MainActor
    func smartRefinementGateSubToggle() async {
        let jsonResponse = """
        {
          "model": "jev-latest",
          "answers": [
            {"type": "noul", "noul": 0.05, "confidence": 0.95},
            {"type": "choice", "choice": "prose"},
            {"type": "noul", "noul": 0.10, "confidence": 0.90}
          ]
        }
        """
        let transport = MockJevTransport(responseBody: jsonResponse)
        let jevIntegration = JevDecisionIntegration(
            session: transport.session,
            apiKeyProvider: { "valid-key" }
        )

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DataStore(
            applicationSupportBaseURL: tempDir.appendingPathComponent("Support"),
            temporaryBaseURL: tempDir.appendingPathComponent("Temp"),
            userDefaultsSuiteName: "test-gate-jev-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let router = Self.makeRouter(
            store: store,
            jevIntegration: jevIntegration,
            frontmostApp: "Safari"
        )

        // Disable smart refinement gate
        router.setJevSmartRefinementGateEnabled(false)
        #expect(router.isJevSmartRefinementGateEnabled == false)

        let outcome = await router.evaluateWithJevAndRefine(
            provider: .deepgramStreaming,
            rawTranscript: "This is perfectly clear speech without errors.",
            modeName: nil,
            modeInstructions: nil
        )

        // Jev answered needsRefinement = false, but because gate is disabled, refinement was not bypassed
        #expect(outcome.refinement != .bypassedCleanSpeech)
    }

    @Test("Sub-toggle disables Hallucination Guardrail")
    @MainActor
    func hallucinationGuardrailSubToggle() async {
        let jsonResponse = """
        {
          "model": "jev-latest",
          "answers": [
            {"type": "noul", "noul": 0.98, "confidence": 0.99},
            {"type": "choice", "choice": "prose"},
            {"type": "noul", "noul": 0.50, "confidence": 0.50}
          ]
        }
        """
        let transport = MockJevTransport(responseBody: jsonResponse)
        let jevIntegration = JevDecisionIntegration(
            session: transport.session,
            apiKeyProvider: { "valid-key" }
        )

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DataStore(
            applicationSupportBaseURL: tempDir.appendingPathComponent("Support"),
            temporaryBaseURL: tempDir.appendingPathComponent("Temp"),
            userDefaultsSuiteName: "test-guardrail-jev-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let router = Self.makeRouter(
            store: store,
            jevIntegration: jevIntegration,
            frontmostApp: "Safari"
        )

        // Disable hallucination guardrail
        router.setJevHallucinationGuardrailEnabled(false)
        #expect(router.isJevHallucinationGuardrailEnabled == false)

        let outcome = await router.evaluateWithJevAndRefine(
            provider: .deepgramStreaming,
            rawTranscript: "Thank you for watching!",
            modeName: nil,
            modeInstructions: nil
        )

        // Jev indicated hallucination, but guardrail is disabled so it is not marked as hallucination
        #expect(outcome.isHallucination == false)
        #expect(outcome.refinement != .hallucinationIgnored)
    }

    // MARK: - MenuBarController Wiring Tests

    @Test("MenuBarController wires Jev toggles and propagates to DataStore and Router")
    @MainActor
    func menuBarControllerJevWiring() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = DataStore(
            applicationSupportBaseURL: tempDir.appendingPathComponent("Support"),
            temporaryBaseURL: tempDir.appendingPathComponent("Temp"),
            userDefaultsSuiteName: "test-controller-jev-\(UUID().uuidString)"
        )
        let controller = MenuBarController(dataStore: store)

        #expect(controller.jevEnabled == true)
        #expect(controller.jevSmartRefinementGateEnabled == true)
        #expect(controller.jevAutoWritingModeEnabled == true)
        #expect(controller.jevHallucinationGuardrailEnabled == true)

        await controller.setJevEnabled(false)
        #expect(controller.jevEnabled == false)
        #expect(controller.dualProviderRoutingFeature.isJevEnabled == false)
        #expect(await store.isJevEnabled() == false)

        await controller.setJevSmartRefinementGateEnabled(false)
        #expect(controller.jevSmartRefinementGateEnabled == false)
        #expect(controller.dualProviderRoutingFeature.isJevSmartRefinementGateEnabled == false)
        #expect(await store.isJevSmartRefinementGateEnabled() == false)

        await controller.setJevAutoWritingModeEnabled(false)
        #expect(controller.jevAutoWritingModeEnabled == false)
        #expect(controller.dualProviderRoutingFeature.isJevAutoWritingModeEnabled == false)
        #expect(await store.isJevAutoWritingModeEnabled() == false)

        await controller.setJevHallucinationGuardrailEnabled(false)
        #expect(controller.jevHallucinationGuardrailEnabled == false)
        #expect(controller.dualProviderRoutingFeature.isJevHallucinationGuardrailEnabled == false)
        #expect(await store.isJevHallucinationGuardrailEnabled() == false)
    }
}

// MARK: - Test Helpers

@MainActor
final class FakeMicrophoneCapture: MicrophoneCapturing {
    func beginCapture() async throws -> MicrophoneInputFormat {
        MicrophoneInputFormat(sampleRate: 16000, channelCount: 1)
    }
    func endCapture() async {}
    func setBufferSink(_ sink: (@Sendable (MicrophoneInputBuffer) -> Void)?) async {}
}

@MainActor
final class FakeHudPresenter: HudPresenting {
    private(set) var presentations: [CaptureHudSnapshot] = []
    private(set) var stopAction: (@MainActor () -> Void)?
    private(set) var cancelAction: (@MainActor () -> Void)?

    var latest: CaptureHudSnapshot? { presentations.last }

    func present(_ snapshot: CaptureHudSnapshot) {
        presentations.append(snapshot)
    }

    func setControlActions(
        stop: @escaping @MainActor () -> Void,
        cancel: @escaping @MainActor () -> Void
    ) {
        stopAction = stop
        cancelAction = cancel
    }
}

final class MockJevTransport: @unchecked Sendable {
    let session: URLSession
    private let lock = NSLock()
    private var _requestCount = 0
    let responseBody: String

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _requestCount
    }

    init(responseBody: String = "{}") {
        self.responseBody = responseBody
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockJevURLProtocol.self]
        self.session = URLSession(configuration: config)
        MockJevURLProtocol.handler = { [weak self] request in
            self?.lock.lock()
            self?._requestCount += 1
            self?.lock.unlock()
            let data = (self?.responseBody ?? "{}").data(using: .utf8)!
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }
    }
}

final class MockJevURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockJevURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
