import Foundation
import Testing
@testable import Whisperbar

/// TASK-11-CUSTOM-WRITING-MODES-AND-VOCABULARY focused checks.
///
/// Covers FEAT-CUSTOM-WRITING-MODES-AND-VOCABULARY and contracts
/// CON-CUSTOM-WRITING-MODES-AND-VOCABULARY-INTERFACE and
/// CON-CUSTOM-WRITING-MODES-AND-VOCABULARY-RECOVERY through an injected
/// DataStore sandbox, an in-memory Keychain seam, and a fake HTTP transport.
/// No live Keychain item, network request, TCC prompt, or microphone is
/// touched by these tests.
@Suite("CustomWritingModesAndVocabularyFeature — deterministic modes and vocabulary")
@MainActor
struct CustomWritingModesAndVocabularyFeatureTests {

    typealias Sandbox = DataStoreTests.Sandbox
    typealias FakeKeychainStore = CredentialVaultTests.InMemoryKeychainStore
    typealias FakeHTTPTransport = OpenrouterRefinementIntegrationTests.FakeHTTPTransport

    // MARK: - Helpers

    private func makeFeature(sandbox: Sandbox, now: Date = Date(timeIntervalSince1970: 1_767_225_600)) -> CustomWritingModesAndVocabularyFeature {
        CustomWritingModesAndVocabularyFeature(dataStore: sandbox.makeStore(), now: { now })
    }

    private func makeMode(
        id: String = UUID().uuidString,
        name: String,
        instructions: String,
        isDefault: Bool = false
    ) -> WritingMode {
        WritingMode(id: id, name: name, instructions: instructions, isDefault: isDefault)
    }

    private func seedMode(_ mode: WritingMode, in sandbox: Sandbox) async {
        let store = sandbox.makeStore()
        try? await store.upsertWritingMode(mode)
    }

    private func seedTerm(_ term: String, in sandbox: Sandbox) async {
        let store = sandbox.makeStore()
        try? await store.upsertVocabularyTerm(
            VocabularyTerm(id: UUID().uuidString, term: term, createdAt: Date(timeIntervalSince1970: 1_767_225_600))
        )
    }

    private func makeVault() -> CredentialVault {
        let store = FakeKeychainStore()
        try? store.store(
            value: "or-test-key",
            account: CredentialKey.openRouter.account,
            service: "com.whisperbar.app.credentials"
        )
        return CredentialVault(store: store, service: "com.whisperbar.app.credentials")
    }

    private func refinementSuccessBody(content: String = "Refined transcript.") -> Data {
        Data(
            """
            {"id":"gen-cw-1","model":"google/gemini-2.5-flash-lite","created":1767225600,\
            "choices":[{"index":0,"message":{"role":"assistant","content":"\(content)"},"finish_reason":"stop"}],\
            "usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15,"cost":0.0001}}
            """.utf8
        )
    }

    // MARK: - ACC-CUSTOM-WRITING-MODES-AND-VOCABULARY-01
    // Changes are deterministic and reproducible.

    @Test("Loading stored configuration is reproducible and produces identical parameters")
    func deterministicParameters() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }
        let mode = makeMode(id: "mode-polish", name: "Polish", instructions: "Fix spelling; keep the tone.")
        await seedMode(mode, in: sandbox)
        await seedTerm("Postgres", in: sandbox)
        await seedTerm("SwiftUI", in: sandbox)

        let feature = makeFeature(sandbox: sandbox)
        #expect(await feature.load())
        #expect(feature.state == .succeeded)
        #expect(feature.lastAction == .configurationLoaded)
        #expect(feature.modes.count == 1)
        #expect(feature.vocabularyTerms.count == 2)

        let first = feature.parameters
        let second = feature.parameters
        #expect(first == second)
        #expect(first.keyterms == ["Postgres", "SwiftUI"])
        // Void of any custom selection the locked default behavior applies.
        #expect(first.usesDefaultBehavior)

        // A repeated explicit load reproduces the same state exactly.
        #expect(await feature.load())
        #expect(feature.parameters == first)
    }

    @Test("Vocabulary expansion is order-independent and stable across storage reloads")
    func vocabularyExpansionIsOrderIndependent() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }
        await seedTerm("zeta", in: sandbox)
        await seedTerm("Alpha", in: sandbox)
        await seedTerm("beta", in: sandbox)

        let feature = makeFeature(sandbox: sandbox)
        #expect(await feature.load())
        #expect(feature.parameters.keyterms == ["Alpha", "beta", "zeta"])

        // The pure normalization is identical for the same set inserted in a
        // different order, and duplicate casing collapses deterministically.
        let shuffled = CustomWritingModesAndVocabularyFeature.normalizedKeyterms(
            fromWords: ["ZETA", "beta", "alpha", "   ", "Alpha"]
        )
        #expect(shuffled == ["Alpha", "beta", "ZETA"])
        #expect(feature.parameters.keyterms == CustomWritingModesAndVocabularyFeature.normalizedKeyterms(fromWords: ["zeta", "beta", "Alpha"]))
    }

    // MARK: - ACC-CUSTOM-WRITING-MODES-AND-VOCABULARY-02
    // Custom modes affect refinement output.

    @Test("A selected custom mode reaches the refinement request and its output")
    func customModeAffectsRefinementOutput() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }
        let mode = makeMode(id: "mode-polish", name: "Polish", instructions: "Fix spelling; keep the tone.")
        await seedMode(mode, in: sandbox)

        let feature = makeFeature(sandbox: sandbox)
        #expect(await feature.load())
        #expect(feature.selectMode(id: "mode-polish"))
        #expect(feature.state == .succeeded)
        #expect(feature.lastAction == .modeSelected("mode-polish"))

        let parameters = feature.parameters
        #expect(parameters.modeID == "mode-polish")
        #expect(parameters.modeName == "Polish")
        #expect(parameters.modeInstructions == "Fix spelling; keep the tone.")
        #expect(!parameters.usesDefaultBehavior)

        // The locked payload builder receives exactly the selected mode.
        let payload = feature.refinementPayload(rawTranscript: "hello world")
        #expect(payload.contains("Selected mode: Polish"))
        #expect(payload.contains("Mode instructions: Fix spelling; keep the tone."))
        #expect(payload.contains("Transcript:\nhello world"))

        // End to end: the same parameters produce the refinement request and
        // its refined output through the shared integration.
        let transport = FakeHTTPTransport()
        transport.configure(body: refinementSuccessBody(content: "Hello, world."))
        let integration = OpenrouterRefinementIntegration(
            credentialVault: makeVault(),
            transport: transport,
            isEnabled: true
        )
        let result = await integration.refine(
            rawTranscript: "hello world",
            modeName: parameters.modeName,
            modeInstructions: parameters.modeInstructions
        )
        #expect(result == .refined("Hello, world."))

        let requestBody = transport.requests.first?.body ?? Data()
        let bodyText = String(data: requestBody, encoding: .utf8) ?? ""
        #expect(bodyText.contains("Polish"))
        #expect(bodyText.contains("Fix spelling; keep the tone."))
    }

    @Test("Changing a mode's instructions deterministically changes later requests")
    func updatedModeChangesRequests() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }
        await seedMode(makeMode(id: "mode-1", name: "Formal", instructions: "First instructions."), in: sandbox)

        let feature = makeFeature(sandbox: sandbox)
        #expect(await feature.load())
        #expect(feature.selectMode(id: "mode-1"))
        let before = feature.refinementPayload(rawTranscript: "text")
        #expect(before.contains("First instructions."))

        #expect(await feature.saveMode(makeMode(id: "mode-1", name: "Formal", instructions: "Second instructions.")))
        // The explicit selection survives a same-id update.
        #expect(feature.parameters.modeID == "mode-1")
        let after = feature.refinementPayload(rawTranscript: "text")
        #expect(after.contains("Second instructions."))
        #expect(!after.contains("First instructions."))
        #expect(feature.lastAction == .modeSaved("mode-1"))
    }

    // MARK: - ACC-CUSTOM-WRITING-MODES-AND-VOCABULARY-03
    // Defaults are used when custom settings are invalid.

    @Test("An invalid mode is rejected, the user is notified, and defaults stay in effect")
    func invalidModeRejectedAndDefaultsUsed() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }
        await seedMode(makeMode(id: "mode-valid", name: "Valid", instructions: "Keep it short."), in: sandbox)

        let feature = makeFeature(sandbox: sandbox)
        #expect(await feature.load())
        #expect(feature.selectMode(id: "mode-valid"))
        let validParameters = feature.parameters

        // An empty instruction set is invalid: rejected before any write.
        let rejected = await feature.saveMode(makeMode(id: "mode-broken", name: "Broken", instructions: "   "))
        #expect(rejected == false)
        #expect(feature.state == .failed(feature.lastFailure ?? CustomWritingModesAndVocabularyFeature.Failure(category: .invalidMode, message: "")))
        #expect(feature.lastFailure?.category == .invalidMode)
        #expect(feature.lastFailure?.message.contains("default") == true)
        #expect(feature.modes.count == 1)

        // The last valid selection is unchanged; the invalid mode is absent.
        #expect(feature.parameters == validParameters)
        #expect(!feature.modes.contains { $0.id == "mode-broken" })

        // Explicit retry with a corrected mode recovers.
        #expect(await feature.saveMode(makeMode(id: "mode-broken", name: "Broken fixed", instructions: "Now valid.")))
        #expect(feature.lastFailure == nil)
        #expect(feature.state == .succeeded)
        #expect(feature.parameters == validParameters)
    }

    @Test("Deleting the active mode falls back to the default behavior with a notice")
    func deletingActiveModeFallsBackToDefaults() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }
        await seedMode(makeMode(id: "mode-temp", name: "Temporary", instructions: "Temporary instructions."), in: sandbox)

        let feature = makeFeature(sandbox: sandbox)
        #expect(await feature.load())
        #expect(feature.selectMode(id: "mode-temp"))
        #expect(!feature.parameters.usesDefaultBehavior)

        #expect(await feature.deleteMode(id: "mode-temp"))
        #expect(feature.modes.isEmpty)
        #expect(feature.parameters.usesDefaultBehavior)
        #expect(feature.parameters.modeID == nil)
        #expect(feature.lastNotice?.contains("default") == true)
        #expect(feature.lastAction == .modeDeleted("mode-temp"))
    }

    @Test("Invalid stored settings are ignored and the default behavior is used")
    func invalidStoredSettingsUseDefaults() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }
        // Stored outside the feature: a flagged default mode with no usable
        // instructions and an oversized vocabulary term.
        await seedMode(makeMode(id: "mode-default", name: "Default-ish", instructions: "  ", isDefault: true), in: sandbox)
        await seedTerm(String(repeating: "x", count: 120), in: sandbox)
        await seedTerm("Valid", in: sandbox)

        let feature = makeFeature(sandbox: sandbox)
        #expect(await feature.load())
        // The invalid default mode is not applied: the locked default
        // behavior is used and only the valid vocabulary terms expand.
        #expect(feature.parameters.usesDefaultBehavior)
        #expect(feature.parameters.keyterms == ["Valid"])
        #expect(feature.lastNotice != nil)
        #expect(feature.lastNotice?.contains("invalid") == true)
    }

    @Test("Selecting an unknown mode is rejected without changing the last valid selection")
    func unknownSelectionRejected() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }
        await seedMode(makeMode(id: "mode-real", name: "Real", instructions: "Real instructions."), in: sandbox)

        let feature = makeFeature(sandbox: sandbox)
        #expect(await feature.load())
        #expect(feature.selectMode(id: "mode-real"))
        let before = feature.parameters

        #expect(feature.selectMode(id: "mode-missing") == false)
        #expect(feature.lastFailure?.category == .unknownModeSelection)
        #expect(feature.parameters == before)

        // Clearing the selection explicitly restores the default behavior.
        #expect(feature.selectMode(id: nil))
        #expect(feature.parameters.usesDefaultBehavior)
        #expect(feature.lastAction == .modeSelected(nil))
    }

    @Test("A stored mode flagged as default is applied when nothing is selected")
    func storedDefaultModeIsApplied() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }
        await seedMode(makeMode(id: "mode-standard", name: "Standard", instructions: "Standard instructions.", isDefault: true), in: sandbox)
        await seedMode(makeMode(id: "mode-extra", name: "Extra", instructions: "Extra instructions."), in: sandbox)

        let feature = makeFeature(sandbox: sandbox)
        #expect(await feature.load())
        #expect(feature.parameters.modeID == "mode-standard")

        #expect(feature.selectMode(id: "mode-extra"))
        #expect(feature.parameters.modeID == "mode-extra")

        // Clearing goes back to the stored default, not to an empty selection.
        #expect(feature.selectMode(id: nil))
        #expect(feature.parameters.modeID == "mode-standard")
    }

    // MARK: - ACC-CUSTOM-WRITING-MODES-AND-VOCABULARY-04
    // Vocabulary expansion is applied consistently.

    @Test("Vocabulary validation rejects invalid and duplicate terms with a notice")
    func vocabularyValidation() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }
        let feature = makeFeature(sandbox: sandbox)
        #expect(await feature.load())

        #expect(await feature.addVocabularyTerm("Postgres"))
        #expect(feature.lastAction == .vocabularyTermAdded("Postgres"))
        #expect(feature.parameters.keyterms == ["Postgres"])

        // Empty and whitespace-only values are rejected before any write.
        #expect(await feature.addVocabularyTerm("   ") == false)
        #expect(feature.lastFailure?.category == .invalidTerm)

        // Terms longer than the locked 100-character keyterm limit are invalid.
        #expect(await feature.addVocabularyTerm(String(repeating: "y", count: 101)) == false)
        #expect(feature.lastFailure?.category == .invalidTerm)

        // Control characters are invalid.
        #expect(await feature.addVocabularyTerm("bad\u{07}term") == false)
        #expect(feature.lastFailure?.category == .invalidTerm)

        // Case-insensitive duplicates are rejected and the list is unchanged.
        #expect(await feature.addVocabularyTerm("postgres") == false)
        #expect(feature.lastFailure?.category == .duplicateTerm)
        #expect(feature.parameters.keyterms == ["Postgres"])

        // A valid retry recovers.
        #expect(await feature.addVocabularyTerm("TimescaleDB"))
        #expect(feature.lastFailure == nil)
        #expect(feature.parameters.keyterms == ["Postgres", "TimescaleDB"])
        #expect(await feature.removeVocabularyTerm(id: feature.vocabularyTerms.first?.id ?? ""))
    }

    @Test("Validated vocabulary feeds the Deepgram streaming listen URL deterministically")
    func keytermsFeedStreamingRequest() async throws {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }
        await seedTerm("TimescaleDB", in: sandbox)
        await seedTerm("deepgram", in: sandbox)
        await seedTerm(String(repeating: "z", count: 101), in: sandbox)

        let feature = makeFeature(sandbox: sandbox)
        #expect(await feature.load())

        let keyterms = feature.parameters.keyterms
        #expect(keyterms == ["deepgram", "TimescaleDB"])

        let url = try DeepgramNovaStreamingTranscriptionIntegration.listenURL(language: "en", keyterms: keyterms)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = components.queryItems ?? []
        let sentKeyterms = items.filter { $0.name == "keyterm" }.compactMap(\.value)
        #expect(sentKeyterms == keyterms)

        // Identical parameters build an identical request every time.
        let repeatURL = try DeepgramNovaStreamingTranscriptionIntegration.listenURL(language: "en", keyterms: feature.parameters.keyterms)
        #expect(repeatURL == url)
    }

    // MARK: - Recovery (CON-CUSTOM-WRITING-MODES-AND-VOCABULARY-RECOVERY)

    @Test("Unavailable storage keeps the last valid state and recovers on explicit retry")
    func storageUnavailableRecovers() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }
        await seedMode(makeMode(id: "mode-keep", name: "Keep", instructions: "Keep instructions."), in: sandbox)

        let store = sandbox.makeStore()
        let feature = CustomWritingModesAndVocabularyFeature(dataStore: store)
        #expect(await feature.load())
        #expect(feature.selectMode(id: "mode-keep"))
        let lastValid = feature.parameters

        // Storage goes away: history of failure is honest, defaults are used,
        // and nothing pretends to have loaded.
        await store.close()
        #expect(await feature.load() == false)
        if case .failed(let failure) = feature.state {
            #expect(failure.category == .storageUnavailable)
            #expect(failure.message.contains("default"))
        } else {
            Issue.record("expected a storage failure, got \(feature.state)")
        }
        // The last valid in-memory state is preserved for the default path.
        #expect(feature.parameters == lastValid)

        // An explicit retry against the same unavailable storage stays honest.
        #expect(await feature.retry() == false)

        // Once storage is reachable again the explicit retry converges.
        let recoveredFeature = CustomWritingModesAndVocabularyFeature(dataStore: sandbox.makeStore())
        #expect(await recoveredFeature.retry())
        #expect(recoveredFeature.state == .succeeded)
        #expect(recoveredFeature.modes.count == 1)
    }
}
