import Foundation
import Testing
@testable import Whisperbar

/// TASK-12-DUAL-PROVIDER-ROUTING focused checks.
///
/// Covers FEAT-DUAL-PROVIDER-ROUTING and contracts
/// CON-DUAL-PROVIDER-ROUTING-INTERFACE and CON-DUAL-PROVIDER-ROUTING-RECOVERY
/// through injected socket, HTTP, audio-inspection, Keychain, and DataStore
/// sandboxes. No live socket, network request, TCC prompt, microphone, or
/// Keychain item is touched by these tests.
@Suite("DualProviderRoutingFeature — explicit routing and recovery", .serialized)
@MainActor
struct DualProviderRoutingFeatureTests {

    typealias Sandbox = DataStoreTests.Sandbox
    typealias FakeSocketFactory = DeepgramNovaStreamingTranscriptionIntegrationTests.FakeSocketFactory
    typealias FakeSocketSession = DeepgramNovaStreamingTranscriptionIntegrationTests.FakeSocketSession
    typealias FakeHTTPTransport = OpenrouterRefinementIntegrationTests.FakeHTTPTransport
    typealias InMemoryKeychainStore = OpenrouterRefinementIntegrationTests.InMemoryKeychainStore
    typealias FakeAudioInspector = OpenrouterTranscriptionIntegrationTests.FakeAudioInspector
    typealias FakeAudioReader = OpenrouterTranscriptionIntegrationTests.FakeAudioReader

    // MARK: - Room (feature + injected seams)

    struct Room {
        let router: DualProviderRoutingFeature
        let factory: FakeSocketFactory
        let batchTransport: FakeHTTPTransport
        let refinementTransport: FakeHTTPTransport
        let inspector: FakeAudioInspector
        let sandbox: Sandbox
    }

    private func makeVault() -> CredentialVault {
        let store = InMemoryKeychainStore()
        try? store.store(
            value: "dg-route-key",
            account: CredentialKey.deepgramNovaStreamingTranscription.account,
            service: "com.whisperbar.app.credentials"
        )
        try? store.store(
            value: "or-route-key",
            account: CredentialKey.openRouter.account,
            service: "com.whisperbar.app.credentials"
        )
        return CredentialVault(store: store, service: "com.whisperbar.app.credentials")
    }

    private func importedFile(named: String = "meeting.m4a", size: Int = 1_000, duration: Double = 12.5) -> ImportedAudioFile {
        ImportedAudioFile(
            url: URL(fileURLWithPath: "/tmp/imported/\(named)"),
            format: (named as NSString).pathExtension.lowercased(),
            sizeBytes: size,
            durationSeconds: duration
        )
    }

    private func makeRoom(
        sandbox: Sandbox,
        refinementEnabled: Bool = false,
        jevIntegration: JevDecisionIntegration? = nil,
        frontmostApp: String? = nil
    ) -> Room {
        let factory = FakeSocketFactory()
        let batchTransport = FakeHTTPTransport()
        let refinementTransport = FakeHTTPTransport()
        let inspector = FakeAudioInspector()
        inspector.configure(file: importedFile())
        let reader = FakeAudioReader()
        reader.configure(data: Data("imported-audio-bytes".utf8))
        let vault = makeVault()

        let deepgram = DeepgramNovaStreamingTranscriptionIntegration(
            credentialVault: vault,
            socketFactory: factory
        )
        let batch = OpenrouterTranscriptionIntegration(
            credentialVault: vault,
            transport: batchTransport,
            inspector: inspector,
            reader: reader
        )
        let refinement = OpenrouterRefinementIntegration(
            credentialVault: vault,
            transport: refinementTransport,
            isEnabled: refinementEnabled
        )
        let appProvider: (@MainActor @Sendable () -> String?)?
        if let frontmostApp {
            appProvider = { frontmostApp }
        } else {
            appProvider = nil
        }

        let router = DualProviderRoutingFeature(
            dataStore: sandbox.makeStore(),
            deepgramIntegration: deepgram,
            refinementIntegration: refinement,
            batchIntegration: batch,
            jevIntegration: jevIntegration,
            frontmostAppProvider: appProvider
        )
        return Room(
            router: router,
            factory: factory,
            batchTransport: batchTransport,
            refinementTransport: refinementTransport,
            inspector: inspector,
            sandbox: sandbox
        )
    }

    // MARK: - Payload helpers

    private func resultJSON(
        transcript: String,
        isFinal: Bool,
        speechFinal: Bool = false,
        fromFinalize: Bool = false
    ) -> String {
        let finalFlag = isFinal ? "true" : "false"
        let speechFlag = speechFinal ? "true" : "false"
        let fromFlag = fromFinalize ? "true" : "false"
        return """
        {"type":"Results","channel_index":[0,1],"duration":1.25,"start":0.0,\
        "channel":{"alternatives":[{"transcript":"\(transcript)","confidence":0.99,\
        "words":[{"word":"\(transcript)","start":0.0,"end":0.9,"confidence":0.99}]}]},\
        "is_final":\(finalFlag),"speech_final":\(speechFlag),"from_finalize":\(fromFlag)}
        """
    }

    private let metadataJSON = """
    {"type":"Metadata","request_id":"dg-route-1","sha256":"abc","created":"2026-01-01T00:00:00Z",\
    "duration":1.5,"channels":1,"transaction_key":"deprecated"}
    """

    private func batchSuccessBody(text: String = "Batch transcript.") -> Data {
        Data(
            """
            {"text":"\(text)","model":"openai/gpt-4o-transcribe","id":"gen-batch-1",\
            "usage":{"seconds":12.5,"total_tokens":210,"input_tokens":200,"output_tokens":10,"cost":0.00075}}
            """.utf8
        )
    }

    private func refinementSuccessBody(content: String = "Hello, world.") -> Data {
        Data(
            """
            {"id":"gen-route-refine-1","model":"google/gemini-2.5-flash-lite","created":1767225600,\
            "choices":[{"index":0,"message":{"role":"assistant","content":"\(content)"},"finish_reason":"stop"}],\
            "usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15,"cost":0.0001}}
            """.utf8
        )
    }

    // MARK: - Session helpers

    private func beginStreaming(_ room: Room) async -> Bool {
        await room.router.selectProvider(.deepgramStreaming)
        return await room.router.startLiveStreaming(language: "en", keyterms: ["WhisperBar"])
    }

    /// Drives one complete live streaming session: stop → final boundary →
    /// metadata → completion (including optional refinement).
    private func finishStreaming(
        _ room: Room,
        transcript: String = "hello world",
        modeName: String? = nil,
        modeInstructions: String? = nil
    ) async -> DualProviderRoutingFeature.Outcome? {
        await room.router.stopAndFinalize()
        room.factory.session.enqueue(text: resultJSON(transcript: transcript, isFinal: true, speechFinal: true))
        room.factory.session.enqueue(text: metadataJSON)
        return await room.router.completeLiveStream(modeName: modeName, modeInstructions: modeInstructions)
    }

    // MARK: - ACC-DUAL-PROVIDER-ROUTING-01
    // Deepgram streaming shows interim results and finalizes automatically.

    @Test("Streaming shows interim results and finalizes automatically")
    func streamingInterimAndAutomaticFinalization() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }
        let room = makeRoom(sandbox: sandbox)

        #expect(await beginStreaming(room))
        #expect(room.router.state == .active(.deepgramStreaming))
        #expect(room.factory.connectCount == 1)
        #expect(room.factory.lastAuthorization == "Token dg-route-key")
        #expect(room.factory.lastURL?.absoluteString.contains("model=nova-3") == true)

        // A real audio frame becomes exactly one binary frame.
        #expect(await room.router.sendAudio(Data([0x01, 0x02, 0x03, 0x04])))
        #expect(room.factory.session.sentBinaries == [Data([0x01, 0x02, 0x03, 0x04])])

        // Interim results are visible while recording.
        room.factory.session.enqueue(text: resultJSON(transcript: "hel", isFinal: false))
        await room.router.pump()
        #expect(room.router.interimTranscript == "hel")

        // Stop → Finalize; the final boundary triggers CloseStream
        // automatically; completion accepts only the final text.
        let outcome = await finishStreaming(room, transcript: "hello world")
        #expect(outcome?.provider == .deepgramStreaming)
        #expect(outcome?.rawTranscript == "hello world")
        #expect(outcome?.refinement == .notConfigured)
        #expect(outcome?.candidateText == "hello world")
        #expect(room.router.state == .succeeded(outcome ?? DualProviderRoutingFeature.Outcome(provider: .openRouterBatch, rawTranscript: "", refinement: .notConfigured)))
        #expect(room.factory.session.sentTexts == [#"{"type":"Finalize"}"#, #"{"type":"CloseStream"}"#])
        // Exactly one stream was opened for the whole session.
        #expect(room.factory.connectCount == 1)
        // The batch provider was never touched.
        #expect(room.batchTransport.requests.isEmpty)
    }

    // MARK: - ACC-DUAL-PROVIDER-ROUTING-02
    // OpenRouter batch transcription returns finalized text.

    @Test("Batch transcription returns finalized text without opening the streaming route")
    func batchTranscriptionReturnsFinalizedText() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }
        let room = makeRoom(sandbox: sandbox)
        room.batchTransport.configure(body: batchSuccessBody())

        await room.router.selectProvider(.openRouterBatch)
        let outcome = await room.router.transcribeImportedFile(at: importedFile().url, language: "en", providerOrder: nil)

        #expect(outcome?.provider == .openRouterBatch)
        #expect(outcome?.rawTranscript == "Batch transcript.")
        #expect(outcome?.candidateText == "Batch transcript.")
        #expect(room.router.state == .succeeded(outcome ?? DualProviderRoutingFeature.Outcome(provider: .deepgramStreaming, rawTranscript: "", refinement: .notConfigured)))
        #expect(room.router.interimTranscript.isEmpty)
        #expect(room.batchTransport.requests.count == 1)
        #expect(room.batchTransport.requests.first?.body.containsSequence("gpt-4o-transcribe") == true)
        // Batch finalization never opens a live stream.
        #expect(room.factory.connectCount == 0)
    }

    // MARK: - ACC-DUAL-PROVIDER-ROUTING-03
    // Optional refinement applies only when configured.

    @Test("Refinement is skipped with zero requests when not configured")
    func refinementSkippedWhenNotConfigured() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }
        let room = makeRoom(sandbox: sandbox, refinementEnabled: false)
        // Even a perfect refinement response must never be requested.
        room.refinementTransport.configure(body: refinementSuccessBody())

        #expect(await beginStreaming(room))
        let outcome = await finishStreaming(room, transcript: "hello world", modeName: "Polish")

        #expect(outcome?.refinement == .notConfigured)
        #expect(outcome?.candidateText == "hello world")
        #expect(room.refinementTransport.requests.isEmpty)
        #expect(room.router.state == .succeeded(outcome ?? DualProviderRoutingFeature.Outcome(provider: .deepgramStreaming, rawTranscript: "", refinement: .notConfigured)))
    }

    @Test("Configured refinement applies to the finalized transcript")
    func refinementAppliesWhenConfigured() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }
        let room = makeRoom(sandbox: sandbox, refinementEnabled: true)
        room.refinementTransport.configure(body: refinementSuccessBody(content: "Hello, world."))

        #expect(await beginStreaming(room))
        let outcome = await finishStreaming(
            room,
            transcript: "hello world",
            modeName: "Polish",
            modeInstructions: "Fix spelling; keep the tone."
        )

        #expect(outcome?.refinement == .applied(text: "Hello, world."))
        #expect(outcome?.candidateText == "Hello, world.")
        #expect(room.refinementTransport.requests.count == 1)
        let bodyText = room.refinementTransport.requests.first.map { String(data: $0.body, encoding: .utf8) ?? "" } ?? ""
        #expect(bodyText.contains("hello world"))
        #expect(bodyText.contains("Polish"))
        #expect(bodyText.contains("gemini-2.5-flash-lite"))
    }

    @Test("A failed refinement never replaces the accepted raw transcript")
    func refinementFailureKeepsRawTranscript() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }
        let room = makeRoom(sandbox: sandbox, refinementEnabled: true)
        room.refinementTransport.configure(status: 500, body: Data(#"{"error":{"code":500,"message":"upstream failure"}}"#.utf8))

        #expect(await beginStreaming(room))
        let outcome = await finishStreaming(room, transcript: "hello world")

        #expect(outcome?.refinement == .failed(.providerFailure(status: 500)))
        #expect(outcome?.rawTranscript == "hello world")
        #expect(outcome?.candidateText == "hello world")
        // The completed transcript stays accepted; only an explicit user retry may follow.
        #expect(room.router.state == .succeeded(outcome ?? DualProviderRoutingFeature.Outcome(provider: .deepgramStreaming, rawTranscript: "", refinement: .notConfigured)))
        #expect(room.refinementTransport.requests.count == 1)
    }

    // MARK: - ACC-DUAL-PROVIDER-ROUTING-04
    // Provider selection is explicit and respected.

    @Test("Recording and batch routes refuse to run without an explicit selection")
    func selectionMustBeExplicit() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }
        let room = makeRoom(sandbox: sandbox)

        // Nothing is selected: no request reaches any provider.
        #expect(await room.router.startLiveStreaming(language: nil, keyterms: []) == false)
        #expect(room.router.lastFailure?.category == .providerNotSelected)
        #expect(room.router.state == .failed(room.router.lastFailure ?? DualProviderRoutingFeature.Failure(category: .providerNotSelected, message: "")))
        let batchOutcome = await room.router.transcribeImportedFile(at: importedFile().url)
        #expect(batchOutcome == nil)
        #expect(room.router.lastFailure?.category == .providerNotSelected)
        #expect(room.factory.connectCount == 0)
        #expect(room.batchTransport.requests.isEmpty)
        #expect(room.inspector.inspectCount == 0)
    }

    @Test("A route that does not match the explicit selection is rejected before any provider call")
    func providerMismatchIsRejected() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }
        let room = makeRoom(sandbox: sandbox)

        await room.router.selectProvider(.openRouterBatch)
        #expect(await room.router.startLiveStreaming(language: nil, keyterms: []) == false)
        #expect(room.router.lastFailure?.category == .providerMismatch(expected: .deepgramStreaming))
        #expect(room.factory.connectCount == 0)

        await room.router.selectProvider(.deepgramStreaming)
        #expect(await room.router.transcribeImportedFile(at: importedFile().url) == nil)
        #expect(room.router.lastFailure?.category == .providerMismatch(expected: .openRouterBatch))
        #expect(room.batchTransport.requests.isEmpty)
        #expect(room.inspector.inspectCount == 0)
        // The explicit selection itself is unchanged by a rejected route.
        #expect(room.router.selectedProvider == .deepgramStreaming)
    }

    @Test("An explicit selection is persisted and honored across sessions")
    func explicitSelectionPersistsThroughDataStore() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }
        let room = makeRoom(sandbox: sandbox)

        #expect(await room.router.selectProvider(.openRouterBatch))
        #expect(await sandbox.makeStore().providerPreference() == .openRouterBatch)

        // A restarted composition root reads the same explicit choice.
        let restarted = makeRoom(sandbox: sandbox)
        await restarted.router.loadProviderPreference()
        #expect(restarted.router.selectedProvider == .openRouterBatch)

        // Clearing is also explicit and reaches storage.
        #expect(await room.router.selectProvider(nil))
        #expect(await sandbox.makeStore().providerPreference() == nil)
        await restarted.router.loadProviderPreference()
        #expect(restarted.router.selectedProvider == nil)
    }

    // MARK: - Recovery (CON-DUAL-PROVIDER-ROUTING-RECOVERY)

    @Test("A provider failure maps to a privacy-safe state with no automatic fallback and an explicit retry")
    func providerFailureNoAutomaticFallback() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }
        let room = makeRoom(sandbox: sandbox)
        room.factory.connectError = .upgradeFailed(status: 503)

        await room.router.selectProvider(.deepgramStreaming)
        #expect(await room.router.startLiveStreaming(language: nil, keyterms: []) == false)
        #expect(room.router.state == .failed(room.router.lastFailure ?? DualProviderRoutingFeature.Failure(category: .providerNotSelected, message: "")))
        #expect(room.router.lastFailure?.category == .streaming(.providerFailure(status: 503)))
        let message = room.router.lastFailure?.message ?? ""
        #expect(!message.isEmpty)
        #expect(!message.lowercased().contains("token"))
        // Recoverable provider failures may retain audio only for an explicit
        // retry or explicit provider switch.
        #expect(room.router.retainsTemporaryAudioForExplicitRecovery)
        // No automatic fallback: the batch route was never touched and the
        // selection is unchanged.
        #expect(room.batchTransport.requests.isEmpty)
        #expect(room.router.selectedProvider == .deepgramStreaming)
        #expect(room.factory.connectCount == 1)

        // Authentication failures are terminal for the retained-audio policy.
        let terminalRoom = makeRoom(sandbox: DataStoreTests.makeSandbox())
        terminalRoom.factory.connectError = .upgradeFailed(status: 401)
        await terminalRoom.router.selectProvider(.deepgramStreaming)
        _ = await terminalRoom.router.startLiveStreaming(language: nil, keyterms: [])
        #expect(terminalRoom.router.retainsTemporaryAudioForExplicitRecovery == false)

        // Explicit retry opens a fresh stream; nothing is automatic.
        room.factory.connectError = nil
        #expect(await room.router.retryLastOperation())
        #expect(room.router.state == .active(.deepgramStreaming))
        #expect(room.factory.connectCount == 2)
        #expect(room.router.lastFailure == nil)
    }

    @Test("Cancellation discards late events and never reports partial text as complete")
    func cancellationDiscardsLateResults() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }
        let room = makeRoom(sandbox: sandbox)

        #expect(await beginStreaming(room))
        room.factory.session.enqueue(text: resultJSON(transcript: "late final words", isFinal: true))
        await room.router.cancelCurrentOperation()

        #expect(room.router.state == .cancelled)
        #expect(room.router.interimTranscript.isEmpty)
        #expect(room.router.completedCandidateText == nil)
        #expect(room.factory.session.closeRequested)
        // Audio and provider sends stop on the cancelled session.
        #expect(await room.router.sendAudio(Data([0x01, 0x02])) == false)
        // A cancelled operation has no completed outcome to insert.
        #expect(await room.router.completeLiveStream() == nil)
        #expect(room.factory.connectCount == 1)
    }

    @Test("A batch failure maps to an explicit state and recovers only through an explicit retry")
    func batchFailureAndExplicitRetry() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }
        let room = makeRoom(sandbox: sandbox)
        room.batchTransport.configure(status: 429, headers: ["Retry-After": "2"], body: Data())

        await room.router.selectProvider(.openRouterBatch)
        #expect(await room.router.transcribeImportedFile(at: importedFile().url) == nil)
        #expect(room.router.lastFailure?.category == .batch(.rateLimited))
        #expect(room.router.state == .failed(room.router.lastFailure ?? DualProviderRoutingFeature.Failure(category: .providerNotSelected, message: "")))
        #expect(room.batchTransport.requests.count == 1)
        // No automatic paid fallback to the streaming provider.
        #expect(room.factory.connectCount == 0)

        // An explicit retry re-runs the same route once and succeeds.
        room.batchTransport.configure(body: batchSuccessBody(text: "Recovered batch text."))
        #expect(await room.router.retryLastOperation())
        #expect(room.router.state == .succeeded(room.router.lastOutcome ?? DualProviderRoutingFeature.Outcome(provider: .deepgramStreaming, rawTranscript: "", refinement: .notConfigured)))
        #expect(room.router.lastOutcome?.rawTranscript == "Recovered batch text.")
        #expect(room.batchTransport.requests.count == 2)
    }

    @Test("One in-flight operation per recording is enforced")
    func inFlightGuard() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }
        let room = makeRoom(sandbox: sandbox)

        #expect(await beginStreaming(room))
        #expect(await room.router.startLiveStreaming(language: nil, keyterms: []) == false)
        #expect(room.router.lastFailure?.category == .inFlight)
        #expect(room.factory.connectCount == 1)
        #expect(room.router.state == .active(.deepgramStreaming))
    }

    @Test("Termination cancels the in-flight stream and releases the session")
    func terminationReleasesInFlightStream() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }
        let room = makeRoom(sandbox: sandbox)

        #expect(await beginStreaming(room))
        await room.router.releaseForTermination()
        #expect(room.router.state == .idle)
        #expect(room.router.interimTranscript.isEmpty)
        #expect(room.factory.session.closeRequested)
    }

    // MARK: - Jev Decision Engine Pipeline Routing Tests

    final class JevMockURLProtocol: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var _requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
        nonisolated(unsafe) private static var _lastRequest: URLRequest?

        static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return _requestHandler
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                _requestHandler = newValue
            }
        }

        static var lastRequest: URLRequest? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return _lastRequest
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                _lastRequest = newValue
            }
        }

        static func reset() {
            lock.lock()
            defer { lock.unlock() }
            _requestHandler = nil
            _lastRequest = nil
        }

        override class func canInit(with request: URLRequest) -> Bool {
            true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            JevMockURLProtocol.lock.lock()
            JevMockURLProtocol._lastRequest = request
            let handler = JevMockURLProtocol._requestHandler
            JevMockURLProtocol.lock.unlock()

            guard let handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }

            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private static func makeMockJevSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [JevMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private static func makeJevIntegration(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> JevDecisionIntegration {
        JevMockURLProtocol.reset()
        JevMockURLProtocol.requestHandler = handler
        return JevDecisionIntegration(
            session: makeMockJevSession(),
            apiKeyProvider: { "typesafe-test-key" }
        )
    }

    private static func jevResponseData(
        isHallucination: Double = 0.0,
        writingMode: String? = nil,
        needsRefinement: Double = 0.5
    ) -> Data {
        var answers: [String: Any] = [
            "is_hallucination": ["type": "noul", "noul": isHallucination],
            "needs_refinement": ["type": "noul", "noul": needsRefinement]
        ]
        if let writingMode {
            answers["writing_mode"] = ["type": "choice", "choice": writingMode]
        }
        let dict: [String: Any] = [
            "model": "jev-latest",
            "answers": answers
        ]
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
    }

    @Test("Hallucination detection skips paste and triggers HUD notice")
    func hallucinationDetectionDropsPasteAndNotifiesHud() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }

        let jev = Self.makeJevIntegration { _ in
            let response = HTTPURLResponse(url: JevDecisionIntegration.defaultEndpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = Self.jevResponseData(isHallucination: 0.96, writingMode: "raw", needsRefinement: 0.1)
            return (response, data)
        }

        let room = makeRoom(sandbox: sandbox, refinementEnabled: true, jevIntegration: jev)

        #expect(await beginStreaming(room))
        let outcome = await finishStreaming(room, transcript: "Thank you for watching.")

        #expect(outcome != nil)
        #expect(outcome?.isHallucination == true)
        #expect(outcome?.candidateText == nil)
        #expect(outcome?.hudNotice == "🛡️ Ignored phantom audio")
        #expect(room.router.lastHudNotice == "🛡️ Ignored phantom audio")
        #expect(room.router.completedCandidateText == nil)
        // Refinement should never be called for hallucinations
        #expect(room.refinementTransport.requests.isEmpty)
    }

    @Test("Clean speech (needsRefinement == false) fast-paths directly to paste bypassing refinement")
    func cleanSpeechFastPathsToPasteBypassingRefinement() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }

        let jev = Self.makeJevIntegration { _ in
            let response = HTTPURLResponse(url: JevDecisionIntegration.defaultEndpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = Self.jevResponseData(isHallucination: 0.05, writingMode: "prose", needsRefinement: 0.15)
            return (response, data)
        }

        let room = makeRoom(sandbox: sandbox, refinementEnabled: true, jevIntegration: jev)

        #expect(await beginStreaming(room))
        let outcome = await finishStreaming(room, transcript: "This is completely clean speech.")

        #expect(outcome != nil)
        #expect(outcome?.isHallucination == false)
        #expect(outcome?.refinement == .bypassedCleanSpeech)
        #expect(outcome?.candidateText == "This is completely clean speech.")
        #expect(outcome?.rawTranscript == "This is completely clean speech.")
        #expect(room.router.completedCandidateText == "This is completely clean speech.")
        // OpenRouter refinement MUST be bypassed entirely
        #expect(room.refinementTransport.requests.isEmpty)
    }

    @Test("Target app context propagates writing mode parameters into refinement")
    func targetAppContextPropagatesWritingModeParameters() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }

        // Test with Ghostty target application context
        let jev = Self.makeJevIntegration { _ in
            let response = HTTPURLResponse(url: JevDecisionIntegration.defaultEndpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = Self.jevResponseData(isHallucination: 0.05, writingMode: "code", needsRefinement: 0.85)
            return (response, data)
        }

        let room = makeRoom(
            sandbox: sandbox,
            refinementEnabled: true,
            jevIntegration: jev,
            frontmostApp: "Ghostty"
        )
        room.refinementTransport.configure(body: refinementSuccessBody(content: "git commit -m 'fix: issue'"))

        #expect(await beginStreaming(room))
        let outcome = await finishStreaming(room, transcript: "git commit message fix issue")

        #expect(outcome != nil)
        #expect(outcome?.refinement == .applied(text: "git commit -m 'fix: issue'"))
        #expect(room.refinementTransport.requests.count == 1)

        let bodyText = room.refinementTransport.requests.first.map { String(data: $0.body, encoding: .utf8) ?? "" } ?? ""
        #expect(bodyText.contains("Selected mode: Code"))
        #expect(bodyText.contains("git commit message fix issue"))

        // Now verify that an explicit user mode takes precedence over Jev recommendation
        let customRoom = makeRoom(
            sandbox: sandbox,
            refinementEnabled: true,
            jevIntegration: jev,
            frontmostApp: "Ghostty"
        )
        customRoom.refinementTransport.configure(body: refinementSuccessBody(content: "Customized"))

        #expect(await beginStreaming(customRoom))
        _ = await finishStreaming(
            customRoom,
            transcript: "hello",
            modeName: "CustomForced",
            modeInstructions: "Force this mode"
        )

        let customBody = customRoom.refinementTransport.requests.first.map { String(data: $0.body, encoding: .utf8) ?? "" } ?? ""
        #expect(customBody.contains("Selected mode: CustomForced"))
        #expect(customBody.contains("Force this mode"))
    }

    @Test("Fail-open fallback on Jev error proceeds with standard refinement")
    func failOpenOnJevFailureProceedsWithStandardRefinement() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }

        // Jev returns HTTP 500 error
        let jev = Self.makeJevIntegration { _ in
            let response = HTTPURLResponse(url: JevDecisionIntegration.defaultEndpoint, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data("Internal Error".utf8))
        }

        let room = makeRoom(sandbox: sandbox, refinementEnabled: true, jevIntegration: jev)
        room.refinementTransport.configure(body: refinementSuccessBody(content: "Refined safely."))

        #expect(await beginStreaming(room))
        let outcome = await finishStreaming(room, transcript: "hello fail open")

        #expect(outcome != nil)
        #expect(outcome?.isHallucination == false)
        #expect(outcome?.refinement == .applied(text: "Refined safely."))
        #expect(outcome?.candidateText == "Refined safely.")
        #expect(room.refinementTransport.requests.count == 1)
    }
}

// MARK: - Test-only utilities

private extension Data {
    func containsSequence(_ needle: String) -> Bool {
        String(data: self, encoding: .utf8)?.contains(needle) == true
    }
}
