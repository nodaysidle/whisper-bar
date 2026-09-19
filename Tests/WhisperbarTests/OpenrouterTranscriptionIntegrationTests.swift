import Foundation
import Testing
@testable import Whisperbar

/// TASK-09-INTEGRATION-OPENROUTER-TRANSCRIPTION focused checks.
///
/// Covers CON-INTEGRATION-OPENROUTER-TRANSCRIPTION through injectable file
/// inspection, byte reading, and HTTP seams. No live file, network, or paid
/// request is ever made; the shared fakes live in
/// `OpenrouterRefinementIntegrationTests`.
@Suite("OpenrouterTranscriptionIntegration — batch contract")
struct OpenrouterTranscriptionIntegrationTests {

    typealias FakeHTTPTransport = OpenrouterRefinementIntegrationTests.FakeHTTPTransport
    typealias InMemoryKeychainStore = OpenrouterRefinementIntegrationTests.InMemoryKeychainStore
    typealias Gate = OpenrouterRefinementIntegrationTests.Gate

    // MARK: - Fakes

    final class FakeAudioInspector: ImportedAudioInspecting, @unchecked Sendable {
        private let lock = NSLock()
        private var _file: ImportedAudioFile?
        private var _error: (any Error)?
        private var _inspectCount = 0

        var inspectCount: Int { lock.withLock { _inspectCount } }

        func configure(file: ImportedAudioFile) {
            lock.withLock {
                _file = file
                _error = nil
            }
        }

        func fail(with error: any Error) {
            lock.withLock { _error = error }
        }

        func inspect(url: URL) async throws -> ImportedAudioFile {
            try lock.withLock {
                _inspectCount += 1
                if let error = _error { throw error }
                guard let file = _file else {
                    throw ImportedAudioInspectionError.unreadable
                }
                return file
            }
        }
    }

    final class FakeAudioReader: AudioFileReading, @unchecked Sendable {
        private let lock = NSLock()
        private var _data = Data()
        private var _error: (any Error)?
        private var _readCount = 0
        private var _lastURL: URL?

        var readCount: Int { lock.withLock { _readCount } }
        var lastURL: URL? { lock.withLock { _lastURL } }

        func configure(data: Data) {
            lock.withLock {
                _data = data
                _error = nil
            }
        }

        func fail(with error: any Error) {
            lock.withLock { _error = error }
        }

        func readBytes(at url: URL) throws -> Data {
            try lock.withLock {
                _readCount += 1
                _lastURL = url
                if let error = _error { throw error }
                return _data
            }
        }
    }

    // MARK: - Helpers

    private func makeVault(key: String? = "or-secret-key") -> CredentialVault {
        let store = InMemoryKeychainStore()
        if let key {
            try? store.store(
                value: key,
                account: CredentialKey.openRouter.account,
                service: "com.whisperbar.app.credentials"
            )
        }
        return CredentialVault(store: store, service: "com.whisperbar.app.credentials")
    }

    private func file(
        named: String = "meeting.m4a",
        size: Int = 1_000,
        duration: Double = 12.5
    ) -> ImportedAudioFile {
        ImportedAudioFile(
            url: URL(fileURLWithPath: "/tmp/imported/\(named)"),
            format: (named as NSString).pathExtension.lowercased(),
            sizeBytes: size,
            durationSeconds: duration
        )
    }

    private func successBody(text: String = "Batch transcript.", includeUsage: Bool = true) -> Data {
        let usage = includeUsage
            ? #","usage":{"seconds":12.5,"total_tokens":210,"input_tokens":200,"output_tokens":10,"cost":0.00075}"#
            : ""
        return Data(
            """
            {"text":"\(text)","model":"openai/gpt-4o-transcribe","id":"gen-batch-1"\(usage)}
            """.utf8
        )
    }

    private func makeIntegration(
        transport: FakeHTTPTransport,
        inspector: FakeAudioInspector,
        reader: FakeAudioReader,
        vault: CredentialVault
    ) -> OpenrouterTranscriptionIntegration {
        OpenrouterTranscriptionIntegration(
            credentialVault: vault,
            transport: transport,
            inspector: inspector,
            reader: reader
        )
    }

    // MARK: - Local preflight

    @Test("Unsupported, oversized, and overlong files are rejected before any read or upload")
    func preflightRejectsBeforeAnyCost() async {
        let cases: [(ImportedAudioFile, BatchTranscriptionFailure)] = [
            (file(named: "clip.mp4"), .unsupportedFormat),
            (file(named: "clip"), .unsupportedFormat),
            (file(size: 25_000_001), .fileTooLarge),
            (file(duration: 60.5), .durationTooLong)
        ]
        for (candidate, expected) in cases {
            let transport = FakeHTTPTransport()
            let inspector = FakeAudioInspector()
            inspector.configure(file: candidate)
            let reader = FakeAudioReader()
            reader.configure(data: Data([0x01, 0x02]))
            let integration = makeIntegration(
                transport: transport,
                inspector: inspector,
                reader: reader,
                vault: makeVault()
            )

            let result = await integration.transcribeFile(at: candidate.url, language: nil, providerOrder: nil)
            #expect(result == .failed(expected))
            // No bytes are read and no paid request is created.
            #expect(reader.readCount == 0)
            #expect(transport.requests.isEmpty)
            let message = await integration.lastFailure?.userFacingMessage ?? ""
            #expect(!message.isEmpty)
        }
    }

    @Test("Boundary values at exactly 60 seconds and 25,000,000 bytes are accepted")
    func preflightBoundaries() async {
        let transport = FakeHTTPTransport()
        transport.configure(body: successBody())
        let inspector = FakeAudioInspector()
        let boundary = file(size: 25_000_000, duration: 60.0)
        inspector.configure(file: boundary)
        let reader = FakeAudioReader()
        reader.configure(data: Data(repeating: 0x41, count: 16))
        let integration = makeIntegration(
            transport: transport,
            inspector: inspector,
            reader: reader,
            vault: makeVault()
        )

        let result = await integration.transcribeFile(at: boundary.url, language: nil, providerOrder: nil)
        #expect(result == .transcribed("Batch transcript."))
        #expect(reader.readCount == 1)
        #expect(transport.requests.count == 1)
    }

    @Test("An unreadable file fails locally without a provider request")
    func unreadableFileFailsLocally() async {
        let transport = FakeHTTPTransport()
        let inspector = FakeAudioInspector()
        inspector.fail(with: ImportedAudioInspectionError.unreadable)
        let integration = makeIntegration(
            transport: transport,
            inspector: inspector,
            reader: FakeAudioReader(),
            vault: makeVault()
        )
        #expect(await integration.transcribeFile(at: file().url, language: nil, providerOrder: nil) == .failed(.fileUnreadable))
        #expect(transport.requests.isEmpty)
    }

    // MARK: - Request contract

    @Test("The batch request matches the locked audio-transcriptions contract")
    func requestContract() async throws {
        let transport = FakeHTTPTransport()
        transport.configure(
            status: 200,
            headers: ["X-Generation-Id": "gen-header-9"],
            body: successBody()
        )
        let inspector = FakeAudioInspector()
        let candidate = file()
        inspector.configure(file: candidate)
        let rawBytes = Data("RIFF-fake-audio".utf8)
        let reader = FakeAudioReader()
        reader.configure(data: rawBytes)
        let integration = makeIntegration(
            transport: transport,
            inspector: inspector,
            reader: reader,
            vault: makeVault()
        )

        let result = await integration.transcribeFile(at: candidate.url, language: "en", providerOrder: nil)
        #expect(result == .transcribed("Batch transcript."))

        let request = try #require(transport.requests.first)
        #expect(request.url.absoluteString == "https://openrouter.ai/api/v1/audio/transcriptions")
        #expect(request.method == "POST")
        #expect(request.timeout == 65)
        #expect(request.headers == [
            "Authorization": "Bearer or-secret-key",
            "Content-Type": "application/json"
        ])
        #expect(request.headers["X-OpenRouter-Metadata"] == nil)
        #expect(request.headers["HTTP-Referer"] == nil)
        #expect(request.headers["X-Title"] == nil)

        let json = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(json["model"] as? String == "openai/gpt-4o-transcribe")
        #expect(json["temperature"] as? Double == 0.0)
        #expect(json["language"] as? String == "en")
        #expect(json["provider"] == nil)
        let audio = try #require(json["input_audio"] as? [String: Any])
        let encoded = try #require(audio["data"] as? String)
        #expect(encoded == rawBytes.base64EncodedString())
        #expect(!encoded.hasPrefix("data:"))
        #expect(audio["format"] as? String == "m4a")
    }

    @Test("Provider routing is sent only when the user explicitly configured it")
    func providerRoutingIsExplicit() async throws {
        let transport = FakeHTTPTransport()
        transport.configure(body: successBody())
        let inspector = FakeAudioInspector()
        let candidate = file()
        inspector.configure(file: candidate)
        let reader = FakeAudioReader()
        reader.configure(data: Data([0x00, 0x01]))
        let integration = makeIntegration(
            transport: transport,
            inspector: inspector,
            reader: reader,
            vault: makeVault()
        )

        _ = await integration.transcribeFile(at: candidate.url, language: nil, providerOrder: ["groq", "openai"])
        let request = try #require(transport.requests.first)
        let json = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        let provider = try #require(json["provider"] as? [String: Any])
        #expect(provider["order"] as? [String] == ["groq", "openai"])
    }

    @Test("An invalid language or provider order is rejected before any request")
    func invalidOptionalValuesRejected() async {
        let transport = FakeHTTPTransport()
        let inspector = FakeAudioInspector()
        let candidate = file()
        inspector.configure(file: candidate)
        let reader = FakeAudioReader()
        reader.configure(data: Data([0x00, 0x01]))
        let integration = makeIntegration(
            transport: transport,
            inspector: inspector,
            reader: reader,
            vault: makeVault()
        )

        #expect(await integration.transcribeFile(at: candidate.url, language: "english", providerOrder: nil) == .failed(.invalidRequest))
        #expect(await integration.transcribeFile(at: candidate.url, language: nil, providerOrder: [""]) == .failed(.invalidRequest))
        #expect(transport.requests.isEmpty)
    }

    // MARK: - Success and response validation

    @Test("Success decodes text, usage, and the X-Generation-Id correlation header")
    func successDecodesUsageAndCorrelation() async {
        let transport = FakeHTTPTransport()
        transport.configure(
            status: 200,
            headers: ["X-Generation-Id": "gen-header-9"],
            body: successBody()
        )
        let inspector = FakeAudioInspector()
        let candidate = file()
        inspector.configure(file: candidate)
        let reader = FakeAudioReader()
        reader.configure(data: Data([0x00, 0x01]))
        let integration = makeIntegration(
            transport: transport,
            inspector: inspector,
            reader: reader,
            vault: makeVault()
        )

        let result = await integration.transcribeFile(at: candidate.url, language: nil, providerOrder: nil)
        #expect(result == .transcribed("Batch transcript."))
        #expect(await integration.state == .succeeded(text: "Batch transcript."))
        #expect(await integration.lastGenerationID == "gen-header-9")
        let usage = await integration.lastUsage
        #expect(usage?.seconds == 12.5)
        #expect(usage?.totalTokens == 210)
        #expect(usage?.inputTokens == 200)
        #expect(usage?.outputTokens == 10)
        #expect(usage?.cost == 0.00075)
        #expect(await integration.lastReportedCost == 0.00075)
    }

    @Test("Empty or missing text and malformed bodies are failures, never transcripts")
    func outputValidation() async {
        let cases: [(Data, BatchTranscriptionFailure)] = [
            (successBody(text: ""), .emptyOutput),
            (Data(#"{"model":"openai/gpt-4o-transcribe"}"#.utf8), .malformedResponse),
            (Data("{not json".utf8), .malformedResponse)
        ]
        for (body, expected) in cases {
            let transport = FakeHTTPTransport()
            transport.configure(body: body)
            let inspector = FakeAudioInspector()
            let candidate = file()
            inspector.configure(file: candidate)
            let reader = FakeAudioReader()
            reader.configure(data: Data([0x00, 0x01]))
            let integration = makeIntegration(
                transport: transport,
                inspector: inspector,
                reader: reader,
                vault: makeVault()
            )
            #expect(await integration.transcribeFile(at: candidate.url, language: nil, providerOrder: nil) == .failed(expected))
        }
    }

    // MARK: - Failures, rate limits, cancellation

    @Test("HTTP statuses and envelopes map to distinct privacy-safe categories")
    func statusMapping() async {
        let envelope = Data(#"{"error":{"code":401,"message":"No auth","metadata":{"error_type":"authentication"}}}"#.utf8)
        let cases: [(Int, BatchTranscriptionFailure)] = [
            (401, .unauthenticated),
            (402, .creditsExhausted),
            (403, .permission),
            (400, .invalidRequest),
            (422, .invalidRequest),
            (408, .requestTimeout),
            (413, .payloadTooLarge),
            (500, .providerFailure(status: 500)),
            (502, .providerFailure(status: 502)),
            (503, .providerFailure(status: 503))
        ]
        for (status, expected) in cases {
            let transport = FakeHTTPTransport()
            transport.configure(status: status, body: envelope)
            let inspector = FakeAudioInspector()
            let candidate = file()
            inspector.configure(file: candidate)
            let reader = FakeAudioReader()
            reader.configure(data: Data([0x00, 0x01]))
            let integration = makeIntegration(
                transport: transport,
                inspector: inspector,
                reader: reader,
                vault: makeVault()
            )
            #expect(await integration.transcribeFile(at: candidate.url, language: nil, providerOrder: nil) == .failed(expected))
            let message = await integration.lastFailure?.userFacingMessage ?? ""
            #expect(!message.contains("No auth"))
        }

        // A top-level error envelope inside HTTP 200 is a failure.
        let transport = FakeHTTPTransport()
        transport.configure(status: 200, body: envelope)
        let inspector = FakeAudioInspector()
        let candidate = file()
        inspector.configure(file: candidate)
        let reader = FakeAudioReader()
        reader.configure(data: Data([0x00, 0x01]))
        let integration = makeIntegration(
            transport: transport,
            inspector: inspector,
            reader: reader,
            vault: makeVault()
        )
        #expect(await integration.transcribeFile(at: candidate.url, language: nil, providerOrder: nil) == .failed(.unauthenticated))
    }

    @Test("Rate limiting is honored once with no automatic paid retry")
    func rateLimitHandling() async {
        let transport = FakeHTTPTransport()
        transport.configure(
            status: 429,
            headers: ["Retry-After": "5", "X-RateLimit-Remaining": "0"],
            body: Data(#"{"error":{"code":429,"message":"slow down"}}"#.utf8)
        )
        let inspector = FakeAudioInspector()
        let candidate = file()
        inspector.configure(file: candidate)
        let reader = FakeAudioReader()
        reader.configure(data: Data([0x00, 0x01]))
        let integration = makeIntegration(
            transport: transport,
            inspector: inspector,
            reader: reader,
            vault: makeVault()
        )

        #expect(await integration.transcribeFile(at: candidate.url, language: nil, providerOrder: nil) == .failed(.rateLimited))
        #expect(await integration.lastRateLimitInfo?.retryAfter == 5)
        #expect(await integration.lastRateLimitInfo?.remaining == 0)
        // Exactly one paid request; nothing retries itself.
        #expect(transport.requests.count == 1)

        transport.configure(body: successBody())
        #expect(await integration.transcribeFile(at: candidate.url, language: nil, providerOrder: nil) == .transcribed("Batch transcript."))
        #expect(transport.requests.count == 2)
    }

    @Test("A missing key and an in-flight guard block the request")
    func credentialAndInFlightGuards() async throws {
        let transport = FakeHTTPTransport()
        transport.configure(body: successBody())
        let inspector = FakeAudioInspector()
        let candidate = file()
        inspector.configure(file: candidate)
        let reader = FakeAudioReader()
        reader.configure(data: Data([0x00, 0x01]))

        let missing = makeIntegration(
            transport: transport,
            inspector: inspector,
            reader: reader,
            vault: makeVault(key: nil)
        )
        #expect(await missing.transcribeFile(at: candidate.url, language: nil, providerOrder: nil) == .failed(.missingCredential))
        #expect(transport.requests.isEmpty)

        let gate = Gate()
        transport.gate = gate
        let integration = makeIntegration(
            transport: transport,
            inspector: inspector,
            reader: reader,
            vault: makeVault()
        )
        let first = Task {
            await integration.transcribeFile(at: candidate.url, language: nil, providerOrder: nil)
        }
        while transport.requests.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        let second = await integration.transcribeFile(at: candidate.url, language: nil, providerOrder: nil)
        #expect(second == .failed(.inFlight))
        #expect(transport.requests.count == 1)
        gate.open()
        #expect(await first.value == .transcribed("Batch transcript."))
    }

    @Test("Cancellation discards late responses and never yields partial text")
    func cancellationDiscardsLateResponse() async throws {
        let transport = FakeHTTPTransport()
        transport.configure(body: successBody(text: "Late batch text"))
        let gate = Gate()
        transport.gate = gate
        let inspector = FakeAudioInspector()
        let candidate = file()
        inspector.configure(file: candidate)
        let reader = FakeAudioReader()
        reader.configure(data: Data([0x00, 0x01]))
        let integration = makeIntegration(
            transport: transport,
            inspector: inspector,
            reader: reader,
            vault: makeVault()
        )

        let outer = Task {
            await integration.transcribeFile(at: candidate.url, language: nil, providerOrder: nil)
        }
        while transport.requests.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }

        await integration.cancelTranscription()
        #expect(await integration.state == .cancelled)

        gate.open()
        #expect(await outer.value == .failed(.cancelled))
        #expect(await integration.lastTranscribedText == nil)
    }

    @Test("Client-side timeouts and transport failures stay failures")
    func timeoutAndTransportFailures() async {
        let transport = FakeHTTPTransport()
        transport.fail(with: URLError(.timedOut))
        let inspector = FakeAudioInspector()
        let candidate = file()
        inspector.configure(file: candidate)
        let reader = FakeAudioReader()
        reader.configure(data: Data([0x00, 0x01]))
        let integration = makeIntegration(
            transport: transport,
            inspector: inspector,
            reader: reader,
            vault: makeVault()
        )
        #expect(await integration.transcribeFile(at: candidate.url, language: nil, providerOrder: nil) == .failed(.timedOut))

        transport.fail(with: URLError(.networkConnectionLost))
        #expect(await integration.transcribeFile(at: candidate.url, language: nil, providerOrder: nil) == .failed(.transport))
    }
}
