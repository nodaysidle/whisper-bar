import Foundation
import Testing
@testable import Whisperbar

/// TASK-07-INTEGRATION-DEEPGRAM-NOVA-STREAMING-TRANSCRIPTION focused checks.
///
/// Covers CON-INTEGRATION-DEEPGRAM-NOVA-STREAMING-TRANSCRIPTION through
/// injectable socket and Keychain seams. No live network, microphone, or
/// provider call is ever made.
@Suite("DeepgramNovaStreamingTranscriptionIntegration — streaming contract")
struct DeepgramNovaStreamingTranscriptionIntegrationTests {

    // MARK: - Fakes

    final class FakeSocketSession: DeepgramSocketSession, @unchecked Sendable {
        private let lock = NSLock()
        private var inbox: [DeepgramSocketFrame] = []
        private var _sentTexts: [String] = []
        private var _sentBinaries: [Data] = []
        private var _nextReceiveError: DeepgramSocketError?
        private var _closeRequested = false

        var upgradeRequestID: String? { lock.withLock { _upgradeRequestID } }
        private var _upgradeRequestID: String?

        var sentTexts: [String] { lock.withLock { _sentTexts } }
        var sentBinaries: [Data] { lock.withLock { _sentBinaries } }
        var closeRequested: Bool { lock.withLock { _closeRequested } }

        init(upgradeRequestID: String? = nil) {
            _upgradeRequestID = upgradeRequestID
        }

        func enqueue(text: String) {
            lock.withLock { inbox.append(.text(text)) }
        }

        func failNextReceive(with error: DeepgramSocketError) {
            lock.withLock { _nextReceiveError = error }
        }

        func send(text: String) async throws {
            lock.withLock { _sentTexts.append(text) }
        }

        func send(binary: Data) async throws {
            lock.withLock { _sentBinaries.append(binary) }
        }

        func receive() async throws -> DeepgramSocketFrame? {
            try lock.withLock {
                if let error = _nextReceiveError {
                    _nextReceiveError = nil
                    throw error
                }
                if inbox.isEmpty { return nil }
                return inbox.removeFirst()
            }
        }

        func close() async {
            lock.withLock { _closeRequested = true }
        }
    }

    final class FakeSocketFactory: DeepgramSocketFactory, @unchecked Sendable {
        private let lock = NSLock()
        private var _connectError: DeepgramSocketError?
        private var _session = FakeSocketSession()
        private var _connectCount = 0
        private var _lastURL: URL?
        private var _lastAuthorization: String?

        var connectError: DeepgramSocketError? {
            get { lock.withLock { _connectError } }
            set { lock.withLock { _connectError = newValue } }
        }

        var session: FakeSocketSession {
            get { lock.withLock { _session } }
            set { lock.withLock { _session = newValue } }
        }

        var connectCount: Int { lock.withLock { _connectCount } }
        var lastURL: URL? { lock.withLock { _lastURL } }
        var lastAuthorization: String? { lock.withLock { _lastAuthorization } }

        func connect(url: URL, authorization: String) async throws -> DeepgramConnectedSocket {
            try lock.withLock {
                _connectCount += 1
                _lastURL = url
                _lastAuthorization = authorization
                if let error = _connectError { throw error }
                return DeepgramConnectedSocket(session: _session, providerRequestID: _session.upgradeRequestID)
            }
        }
    }

    final class InMemoryKeychainStore: KeychainStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]

        func read(account: String, service: String) throws -> String? {
            lock.withLock { values["\(service)/\(account)"] }
        }

        func store(value: String, account: String, service: String) throws {
            lock.withLock { values["\(service)/\(account)"] = value }
        }

        func delete(account: String, service: String) throws {
            lock.withLock { values["\(service)/\(account)"] = nil }
        }
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var _now = Date(timeIntervalSince1970: 1_700_000_000)
        var now: Date {
            get { lock.withLock { _now } }
            set { lock.withLock { _now = newValue } }
        }

        func advance(_ interval: TimeInterval) {
            lock.withLock { _now = _now.addingTimeInterval(interval) }
        }
    }

    // MARK: - Helpers

    private func makeVault(key: String? = "dg-secret-key", failing: Bool = false) -> CredentialVault {
        let store = InMemoryKeychainStore()
        if failing {
            let failingStore = FailingKeychainStore()
            return CredentialVault(store: failingStore, service: "com.whisperbar.app.credentials")
        }
        if let key {
            try? store.store(value: key, account: CredentialKey.deepgramNovaStreamingTranscription.account, service: "com.whisperbar.app.credentials")
        }
        return CredentialVault(store: store, service: "com.whisperbar.app.credentials")
    }

    final class FailingKeychainStore: KeychainStoring, @unchecked Sendable {
        func read(account: String, service: String) throws -> String? {
            throw KeychainStoreError.readFailed(-1)
        }
        func store(value: String, account: String, service: String) throws {
            throw KeychainStoreError.writeFailed(-1)
        }
        func delete(account: String, service: String) throws {
            throw KeychainStoreError.deleteFailed(-1)
        }
    }

    private func makeIntegration(
        factory: FakeSocketFactory,
        vault: CredentialVault,
        clock: Clock
    ) -> DeepgramNovaStreamingTranscriptionIntegration {
        DeepgramNovaStreamingTranscriptionIntegration(
            credentialVault: vault,
            socketFactory: factory,
            now: { clock.now }
        )
    }

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
    {"type":"Metadata","request_id":"dg-request-123","sha256":"abc","created":"2026-01-01T00:00:00Z",\
    "duration":1.5,"channels":1,"transaction_key":"deprecated"}
    """

    // MARK: - Request construction (locked query model)

    @Test("The listen URL carries exactly the locked nova-3 query model")
    func listenURLUsesLockedQueryModel() throws {
        let url = try DeepgramNovaStreamingTranscriptionIntegration.listenURL(language: nil, keyterms: [])
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "wss")
        #expect(components.host == "api.deepgram.com")
        #expect(components.path == "/v1/listen")

        let items = components.queryItems ?? []
        let map = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        #expect(map["model"] == "nova-3")
        #expect(map["encoding"] == "linear16")
        #expect(map["sample_rate"] == "16000")
        #expect(map["channels"] == "1")
        #expect(map["interim_results"] == "true")
        #expect(map["endpointing"] == "300")
        #expect(map["utterance_end_ms"] == "1000")
        #expect(map["vad_events"] == "true")
        #expect(map["smart_format"] == "true")
        #expect(map["language"] == nil)
        #expect(map["keyterm"] == nil)
    }

    @Test("One validated language and repeated validated keyterms are added only when selected")
    func languageAndKeytermsAreValidated() throws {
        let url = try DeepgramNovaStreamingTranscriptionIntegration.listenURL(
            language: "en-US",
            keyterms: ["WhisperBar", "  Nova  ", ""]
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = components.queryItems ?? []
        #expect(items.filter { $0.name == "language" }.map(\.value) == ["en-US"])
        #expect(items.filter { $0.name == "keyterm" }.compactMap(\.value) == ["WhisperBar", "Nova"])

        #expect(throws: DeepgramRequestError.unsupportedLanguage) {
            _ = try DeepgramNovaStreamingTranscriptionIntegration.listenURL(language: "klingon", keyterms: [])
        }
        #expect(throws: DeepgramRequestError.invalidKeyterm) {
            _ = try DeepgramNovaStreamingTranscriptionIntegration.listenURL(
                language: nil,
                keyterms: [String(repeating: "x", count: 200)]
            )
        }
    }

    @Test("An unsupported language blocks the stream before any socket opens")
    func unsupportedLanguageBlocksStream() async {
        let factory = FakeSocketFactory()
        let clock = Clock()
        let integration = makeIntegration(factory: factory, vault: makeVault(), clock: clock)
        #expect(await integration.beginStream(language: "klingon", keyterms: []) == .failed(.malformedConfiguration))
        #expect(factory.connectCount == 0)
    }

    @Test("Only non-empty two-byte-aligned audio becomes a binary frame")
    func audioFrameValidation() {
        #expect(DeepgramNovaStreamingTranscriptionIntegration.validatedAudioFrame(Data()) == nil)
        #expect(DeepgramNovaStreamingTranscriptionIntegration.validatedAudioFrame(Data([0x01])) == nil)
        let aligned = Data([0x01, 0x02, 0x03, 0x04])
        #expect(DeepgramNovaStreamingTranscriptionIntegration.validatedAudioFrame(aligned) == aligned)
    }

    // MARK: - Event decoding

    @Test("Typed events decode by type including interim, final, VAD, and metadata")
    func typedEventDecoding() throws {
        let interim = try DeepgramStreamEvent.decode(from: Data(resultJSON(transcript: "hello", isFinal: false).utf8))
        guard case .results(let interimResults) = interim else {
            Issue.record("expected Results, got \(interim)")
            return
        }
        #expect(interimResults.isFinal == false)
        #expect(interimResults.channel.alternatives.first?.transcript == "hello")

        let final = try DeepgramStreamEvent.decode(from: Data(resultJSON(transcript: "hello world", isFinal: true, fromFinalize: true).utf8))
        guard case .results(let finalResults) = final else {
            Issue.record("expected Results, got \(final)")
            return
        }
        #expect(finalResults.isFinal == true)
        #expect(finalResults.fromFinalize == true)

        let speechStarted = try DeepgramStreamEvent.decode(from: Data(#"{"type":"SpeechStarted","channel":[0],"timestamp":0.4}"#.utf8))
        guard case .speechStarted = speechStarted else {
            Issue.record("expected SpeechStarted, got \(speechStarted)")
            return
        }

        let utteranceEnd = try DeepgramStreamEvent.decode(from: Data(#"{"type":"UtteranceEnd","channel":[0],"last_word_end":1.1}"#.utf8))
        guard case .utteranceEnd = utteranceEnd else {
            Issue.record("expected UtteranceEnd, got \(utteranceEnd)")
            return
        }

        let metadata = try DeepgramStreamEvent.decode(from: Data(metadataJSON.utf8))
        guard case .metadata(let summary) = metadata else {
            Issue.record("expected Metadata, got \(metadata)")
            return
        }
        #expect(summary.requestID == "dg-request-123")
        #expect(summary.duration == 1.5)

        // Malformed JSON and unknown typed messages are classified, never crashed on.
        #expect(throws: (any Error).self) {
            _ = try DeepgramStreamEvent.decode(from: Data("{not json".utf8))
        }
        let unknown = try DeepgramStreamEvent.decode(from: Data(#"{"type":"BrandNewEvent"}"#.utf8))
        guard case .unknown(let type) = unknown else {
            Issue.record("expected unknown, got \(unknown)")
            return
        }
        #expect(type == "BrandNewEvent")
    }

    // MARK: - Streaming session behavior

    @Test("Streaming accumulates final segments in order and never promotes interim text")
    func streamingAccumulatesFinalsOnly() async throws {
        let factory = FakeSocketFactory()
        factory.session = FakeSocketSession(upgradeRequestID: "dg-upgrade-9")
        let clock = Clock()
        let integration = makeIntegration(factory: factory, vault: makeVault(), clock: clock)

        let state = await integration.beginStream(language: nil, keyterms: [])
        #expect(state == .streaming)
        #expect(await integration.providerRequestID == "dg-upgrade-9")
        #expect(factory.lastAuthorization == "Token dg-secret-key")
        #expect(factory.lastURL?.absoluteString.contains("model=nova-3") == true)

        #expect(await integration.sendAudio(Data([0x01, 0x02, 0x03, 0x04])))
        #expect(await integration.sendAudio(Data()) == false)
        #expect(await integration.sendAudio(Data([0x01])) == false)
        #expect(factory.session.sentBinaries == [Data([0x01, 0x02, 0x03, 0x04])])

        factory.session.enqueue(text: resultJSON(transcript: "hel", isFinal: false))
        factory.session.enqueue(text: resultJSON(transcript: "hello", isFinal: true))
        factory.session.enqueue(text: resultJSON(transcript: "", isFinal: true))
        factory.session.enqueue(text: resultJSON(transcript: "world", isFinal: true))
        await integration.pump()

        #expect(await integration.interimTranscript == "hel")
        #expect(await integration.finalTranscript == "hello world")
        // Interim text is never a completed candidate.
        #expect(await integration.completedTranscript == nil)
    }

    @Test("KeepAlive is sent every 4 seconds only after real audio and only while idle")
    func keepAliveCadence() async throws {
        let factory = FakeSocketFactory()
        let clock = Clock()
        let integration = makeIntegration(factory: factory, vault: makeVault(), clock: clock)
        _ = await integration.beginStream(language: nil, keyterms: [])

        // Before any real audio frame, KeepAlive never fires.
        clock.advance(10)
        #expect(await integration.keepAliveIfNeeded() == false)
        #expect(factory.session.sentTexts.isEmpty)

        #expect(await integration.sendAudio(Data([0x00, 0x01])))
        clock.advance(2)
        #expect(await integration.keepAliveIfNeeded() == false)
        clock.advance(2)
        #expect(await integration.keepAliveIfNeeded() == true)
        #expect(factory.session.sentTexts == [#"{"type":"KeepAlive"}"#])

        // Audio keeps the window alive again.
        clock.advance(5)
        #expect(await integration.sendAudio(Data([0x00, 0x02])))
        #expect(await integration.keepAliveIfNeeded() == false)
    }

    @Test("Stop, finalize, close, and metadata complete one clean session")
    func finalizeAndCloseSequence() async throws {
        let factory = FakeSocketFactory()
        let clock = Clock()
        let integration = makeIntegration(factory: factory, vault: makeVault(), clock: clock)
        _ = await integration.beginStream(language: nil, keyterms: [])
        _ = await integration.sendAudio(Data([0x00, 0x01]))

        await integration.stopAndFinalize()
        #expect(factory.session.sentTexts == [#"{"type":"Finalize"}"#])
        #expect(await integration.state == .finalizing)

        factory.session.enqueue(text: resultJSON(transcript: "final words", isFinal: true, speechFinal: true, fromFinalize: true))
        factory.session.enqueue(text: metadataJSON)
        await integration.pump()

        #expect(factory.session.sentTexts == [#"{"type":"Finalize"}"#, #"{"type":"CloseStream"}"#])
        #expect(await integration.state == .succeeded(finalText: "final words"))
        #expect(await integration.completedTranscript == "final words")
        #expect(await integration.finalTranscript == "final words")
        // Exactly one stream was opened for the whole session.
        #expect(factory.connectCount == 1)
    }

    @Test("Empty final output never becomes a completed transcript")
    func emptyFinalOutputFails() async throws {
        let factory = FakeSocketFactory()
        let clock = Clock()
        let integration = makeIntegration(factory: factory, vault: makeVault(), clock: clock)
        _ = await integration.beginStream(language: nil, keyterms: [])
        await integration.stopAndFinalize()
        await integration.pump()

        #expect(await integration.state == .failed(.emptyFinalOutput))
        #expect(await integration.completedTranscript == nil)
    }

    // MARK: - Failure mapping

    @Test("Upgrade and transport failures map to distinct privacy-safe categories without retry")
    func failureMappingWithoutAutomaticRetry() async {
        let cases: [(DeepgramSocketError, DeepgramStreamFailure)] = [
            (.upgradeFailed(status: 400), .malformedConfiguration),
            (.upgradeFailed(status: 401), .authentication),
            (.upgradeFailed(status: 403), .permission),
            (.upgradeFailed(status: 429), .rateLimited),
            (.upgradeFailed(status: 503), .providerFailure(status: 503)),
            (.timedOut, .timedOut),
            (.transport, .transport)
        ]
        for (socketError, expected) in cases {
            let factory = FakeSocketFactory()
            factory.connectError = socketError
            let clock = Clock()
            let integration = makeIntegration(factory: factory, vault: makeVault(), clock: clock)

            let state = await integration.beginStream(language: nil, keyterms: [])
            #expect(state == .failed(expected))
            // No automatic retry or paid fallback ever follows a failure.
            #expect(factory.connectCount == 1)
            let message = await integration.lastFailure?.userFacingMessage ?? ""
            #expect(!message.isEmpty)
            #expect(!message.lowercased().contains("token"))
        }
    }

    @Test("Close codes map to malformed audio and timeout categories without leaking provider text")
    func closeFrameMapping() async {
        let cases: [(Int, String, DeepgramStreamFailure)] = [
            (1008, "DATA-0000 malformed audio", .malformedAudio),
            // The malformed-or-mismatched-audio class is signaled by close
            // code 1008 itself: the code stays authoritative when the close
            // reason is absent or does not repeat the data-error identifier,
            // and audio in that class is never classified as recoverable.
            (1008, "", .malformedAudio),
            (1008, "invalid audio format", .malformedAudio),
            (1011, "NET-0000 provider error", .insufficientAudioTimeout),
            (1011, "NET-0001 frame timeout", .frameTimeout),
            (1011, "NET-0002 no audio", .noAudioTimeout)
        ]
        for (code, reason, expected) in cases {
            let factory = FakeSocketFactory()
            let clock = Clock()
            let integration = makeIntegration(factory: factory, vault: makeVault(), clock: clock)
            _ = await integration.beginStream(language: nil, keyterms: [])
            factory.session.failNextReceive(with: .closed(code: code, reason: reason))
            await integration.pump()

            #expect(await integration.state == .failed(expected))
            // Malformed audio is never retained for an automatic or paid retry.
            if expected == .malformedAudio {
                #expect(await integration.retainsTemporaryAudioForExplicitRecovery == false)
            }
            let message = await integration.lastFailure?.userFacingMessage ?? ""
            #expect(!message.contains("NET-"))
            #expect(!message.contains("DATA-"))
            #expect(!message.contains("malformed audio"))
        }
    }

    @Test("Missing and unreadable credentials block the stream before any socket opens")
    func credentialsBlockTheStream() async {
        let factory = FakeSocketFactory()
        let clock = Clock()
        let missing = makeIntegration(factory: factory, vault: makeVault(key: nil), clock: clock)
        #expect(await missing.beginStream(language: nil, keyterms: []) == .failed(.credentialUnavailable))
        #expect(await missing.lastFailure?.userFacingMessage.contains("Deepgram") == true)

        let failing = makeIntegration(factory: factory, vault: makeVault(failing: true), clock: clock)
        #expect(await failing.beginStream(language: nil, keyterms: []) == .failed(.credentialUnavailable))
        #expect(factory.connectCount == 0)
    }

    // MARK: - Cancellation and recovery

    @Test("Cancellation discards late events and never reports partial text as complete")
    func cancellationDiscardsLateEvents() async throws {
        let factory = FakeSocketFactory()
        let clock = Clock()
        let integration = makeIntegration(factory: factory, vault: makeVault(), clock: clock)
        _ = await integration.beginStream(language: nil, keyterms: [])
        _ = await integration.sendAudio(Data([0x00, 0x01]))

        factory.session.enqueue(text: resultJSON(transcript: "late final", isFinal: true))
        await integration.cancel()

        #expect(await integration.state == .cancelled)
        #expect(await integration.completedTranscript == nil)
        #expect(await integration.finalTranscript.isEmpty)
        #expect(factory.session.closeRequested)

        // Audio and KeepAlive sends stop on the cancelled session.
        let binariesBefore = factory.session.sentBinaries.count
        #expect(await integration.sendAudio(Data([0x00, 0x01])) == false)
        clock.advance(10)
        #expect(await integration.keepAliveIfNeeded() == false)
        #expect(factory.session.sentBinaries.count == binariesBefore)
    }

    @Test("Recoverable provider failures retain audio only for an explicit retry or switch")
    func recoveryClassification() async throws {
        let recoverableFactory = FakeSocketFactory()
        recoverableFactory.connectError = .upgradeFailed(status: 503)
        let clock = Clock()
        let recoverable = makeIntegration(factory: recoverableFactory, vault: makeVault(), clock: clock)
        _ = await recoverable.beginStream(language: nil, keyterms: [])
        #expect(await recoverable.retainsTemporaryAudioForExplicitRecovery)

        let terminalFactory = FakeSocketFactory()
        terminalFactory.connectError = .upgradeFailed(status: 401)
        let terminal = makeIntegration(factory: terminalFactory, vault: makeVault(), clock: clock)
        _ = await terminal.beginStream(language: nil, keyterms: [])
        #expect(await terminal.retainsTemporaryAudioForExplicitRecovery == false)

        // Explicit user retry opens a fresh stream; nothing is automatic.
        terminalFactory.connectError = nil
        let retried = await terminal.beginStream(language: nil, keyterms: [])
        #expect(retried == .streaming)
        #expect(terminalFactory.connectCount == 2)
    }

    // MARK: - Test connection

    @Test("Test connection verifies the upgrade and request id without audio frames")
    func testConnectionUsesNoAudio() async {
        let factory = FakeSocketFactory()
        factory.session = FakeSocketSession(upgradeRequestID: "dg-test-1")
        factory.session.enqueue(text: #"{"type":"Metadata","request_id":"dg-test-1","duration":0.0,"channels":0}"#)
        let clock = Clock()
        let integration = makeIntegration(factory: factory, vault: makeVault(), clock: clock)

        let result = await integration.testConnection()
        #expect(result == .succeeded(requestID: "dg-test-1"))
        #expect(factory.session.sentBinaries.isEmpty)
        #expect(factory.session.sentTexts == [#"{"type":"CloseStream"}"#])
        #expect(factory.connectCount == 1)

        let missingFactory = FakeSocketFactory()
        let missing = makeIntegration(factory: missingFactory, vault: makeVault(key: nil), clock: clock)
        #expect(await missing.testConnection() == .missingCredential)
        #expect(missingFactory.connectCount == 0)
    }
}
