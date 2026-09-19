import Foundation
import Testing
@testable import Whisperbar

/// TASK-08-INTEGRATION-OPENROUTER-REFINEMENT focused checks.
///
/// Covers CON-INTEGRATION-OPENROUTER-REFINEMENT through an injectable HTTP
/// transport. No live network call and no paid request is ever made.
@Suite("OpenrouterRefinementIntegration — refinement contract")
struct OpenrouterRefinementIntegrationTests {

    // MARK: - Fakes

    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = lock.withLock {
                    if isOpen { return true }
                    self.continuation = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }

        func open() {
            let pending: CheckedContinuation<Void, Never>? = lock.withLock {
                isOpen = true
                let pending = continuation
                continuation = nil
                return pending
            }
            pending?.resume()
        }
    }

    final class FakeHTTPTransport: HTTPTransporting, @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [HTTPRequest] = []
        private var _status = 200
        private var _headers: [String: String] = [:]
        private var _body = Data()
        private var _error: (any Error)?
        var gate: Gate?

        var requests: [HTTPRequest] { lock.withLock { _requests } }

        func configure(status: Int = 200, headers: [String: String] = [:], body: Data) {
            lock.withLock {
                _status = status
                _headers = headers
                _body = body
                _error = nil
            }
        }

        func fail(with error: any Error) {
            lock.withLock { _error = error }
        }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            lock.withLock { _requests.append(request) }
            await gate?.wait()
            let error = lock.withLock { _error }
            if let error { throw error }
            return lock.withLock { HTTPResponse(statusCode: _status, headers: _headers, body: _body) }
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

    private func successBody(
        content: String = "Refined transcript.",
        finishReason: String = "stop",
        includeCost: Bool = true
    ) -> Data {
        let costLine = includeCost ? #""cost":0.00042,"cost_details":{"upstream_inference_cost":0.00042}"# : ""
        let usage = """
        {"prompt_tokens":120,"completion_tokens":80,"total_tokens":200\(costLine.isEmpty ? "" : "," + costLine)}
        """
        return Data(
            """
            {"id":"gen-refine-1","model":"google/gemini-2.5-flash-lite","created":1767225600,\
            "choices":[{"index":0,"message":{"role":"assistant","content":"\(content)"},"finish_reason":"\(finishReason)"}],\
            "usage":\(usage)}
            """.utf8
        )
    }

    private func makeIntegration(
        transport: FakeHTTPTransport,
        vault: CredentialVault,
        enabled: Bool = true
    ) -> OpenrouterRefinementIntegration {
        OpenrouterRefinementIntegration(credentialVault: vault, transport: transport, isEnabled: enabled)
    }

    // MARK: - Opt-in and input validation

    @Test("Disabled refinement makes no request and never spends")
    func disabledRefinementMakesNoRequest() async {
        let transport = FakeHTTPTransport()
        let integration = makeIntegration(transport: transport, vault: makeVault(), enabled: false)

        let result = await integration.refine(rawTranscript: "hello", modeName: nil, modeInstructions: nil)
        #expect(result == .failed(.disabled))
        #expect(transport.requests.isEmpty)
    }

    @Test("Empty or whitespace-only transcripts are rejected before any request")
    func emptyTranscriptRejected() async {
        let transport = FakeHTTPTransport()
        let integration = makeIntegration(transport: transport, vault: makeVault())
        #expect(await integration.refine(rawTranscript: "   \n", modeName: nil, modeInstructions: nil) == .failed(.invalidInput))
        #expect(transport.requests.isEmpty)
    }

    @Test("A missing OpenRouter key blocks refinement with a clear message")
    func missingCredentialBlocksRefinement() async {
        let transport = FakeHTTPTransport()
        let integration = makeIntegration(transport: transport, vault: makeVault(key: nil))
        let result = await integration.refine(rawTranscript: "hello", modeName: nil, modeInstructions: nil)
        #expect(result == .failed(.missingCredential))
        #expect(transport.requests.isEmpty)
        let message = await integration.lastFailure?.userFacingMessage ?? ""
        #expect(message.contains("OpenRouter"))
    }

    // MARK: - Request contract

    @Test("The request matches the locked chat-completions contract exactly")
    func requestContract() async throws {
        let transport = FakeHTTPTransport()
        transport.configure(body: successBody())
        let integration = makeIntegration(transport: transport, vault: makeVault())

        let result = await integration.refine(
            rawTranscript: "raw dictated text",
            modeName: "Email",
            modeInstructions: "Keep it formal."
        )
        guard case .refined(let text) = result else {
            Issue.record("expected refined text, got \(result)")
            return
        }
        #expect(text == "Refined transcript.")

        let request = try #require(transport.requests.first)
        #expect(request.url.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(request.method == "POST")
        #expect(request.timeout == 30)
        // Exactly the two required headers; no optional OpenRouter headers.
        #expect(request.headers == [
            "Authorization": "Bearer or-secret-key",
            "Content-Type": "application/json"
        ])
        #expect(request.headers["HTTP-Referer"] == nil)
        #expect(request.headers["X-Title"] == nil)
        #expect(request.headers["X-OpenRouter-Metadata"] == nil)

        let json = try #require(
            try JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        )
        #expect(json["model"] as? String == "google/gemini-2.5-flash-lite")
        #expect(json["temperature"] as? Double == 0.0)
        #expect(json["stream"] as? Bool == false)
        let reasoning = try #require(json["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == "none")

        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == OpenrouterRefinementIntegration.lockedSystemInstruction)
        #expect(messages[1]["role"] as? String == "user")
        let userPayload = try #require(messages[1]["content"] as? String)
        #expect(userPayload.contains("raw dictated text"))
        #expect(userPayload.contains("Keep it formal."))
        #expect(userPayload.contains("Email"))
    }

    @Test("The locked system instruction text is exact")
    func lockedSystemInstruction() {
        #expect(
            OpenrouterRefinementIntegration.lockedSystemInstruction
                == "Edit only the supplied transcript. Preserve meaning, names, code, and technical terms; never invent speech, facts, speakers, or omitted content; apply only the selected mode; return only the refined transcript."
        )
    }

    // MARK: - Success decoding

    @Test("Success retains provider metadata and authoritative usage cost")
    func successRetainsMetadataAndCost() async {
        let transport = FakeHTTPTransport()
        transport.configure(body: successBody())
        let integration = makeIntegration(transport: transport, vault: makeVault())

        let result = await integration.refine(rawTranscript: "hello", modeName: nil, modeInstructions: nil)
        #expect(result == .refined("Refined transcript."))

        let usage = await integration.lastUsage
        #expect(usage?.promptTokens == 120)
        #expect(usage?.completionTokens == 80)
        #expect(usage?.totalTokens == 200)
        #expect(usage?.cost == 0.00042)
        #expect(usage?.costDetails?["upstream_inference_cost"] == 0.00042)
        #expect(await integration.lastReportedCost == 0.00042)
        #expect(await integration.lastResponseMetadata?.id == "gen-refine-1")
        #expect(await integration.lastResponseMetadata?.model == "google/gemini-2.5-flash-lite")
        #expect(await integration.state == .succeeded(text: "Refined transcript."))
    }

    @Test("Cost stays explicitly unavailable when the provider omits it")
    func costUnavailableIsHonest() async {
        let transport = FakeHTTPTransport()
        transport.configure(body: successBody(includeCost: false))
        let integration = makeIntegration(transport: transport, vault: makeVault())
        _ = await integration.refine(rawTranscript: "hello", modeName: nil, modeInstructions: nil)
        #expect(await integration.lastReportedCost == nil)
    }

    // MARK: - Failure classification

    @Test("Non-stop finishes, filtered output, empty output, and malformed bodies fail")
    func outputValidationFailures() async {
        let cases: [(Data, RefinementFailure)] = [
            (successBody(finishReason: "length"), .nonStopFinish(finishReason: "length")),
            (successBody(finishReason: "content_filter"), .filtered),
            (successBody(content: ""), .emptyOutput),
            (Data("{not json".utf8), .malformedResponse),
            (Data(#"{"id":"x","choices":[]}"#.utf8), .malformedResponse)
        ]
        for (body, expected) in cases {
            let transport = FakeHTTPTransport()
            transport.configure(body: body)
            let integration = makeIntegration(transport: transport, vault: makeVault())
            let result = await integration.refine(rawTranscript: "hello", modeName: nil, modeInstructions: nil)
            #expect(result == .failed(expected))
            let message = await integration.lastFailure?.userFacingMessage ?? ""
            #expect(!message.contains("content"))
        }
    }

    @Test("HTTP status and provider error envelopes map to distinct privacy-safe categories")
    func statusAndEnvelopeFailures() async {
        let envelope = Data(#"{"error":{"code":402,"message":"Insufficient credits","metadata":{"error_type":"authentication"}}}"#.utf8)
        let cases: [(Int, RefinementFailure)] = [
            (401, .unauthenticated),
            (402, .creditsExhausted),
            (403, .permission),
            (400, .invalidRequest),
            (422, .invalidRequest),
            (413, .payloadTooLarge),
            (408, .requestTimeout),
            (500, .providerFailure(status: 500)),
            (502, .providerFailure(status: 502)),
            (503, .providerFailure(status: 503))
        ]
        for (status, expected) in cases {
            let transport = FakeHTTPTransport()
            transport.configure(status: status, body: envelope)
            let integration = makeIntegration(transport: transport, vault: makeVault())
            let result = await integration.refine(rawTranscript: "hello", modeName: nil, modeInstructions: nil)
            #expect(result == .failed(expected))
            let message = await integration.lastFailure?.userFacingMessage ?? ""
            // Raw provider error text is never surfaced.
            #expect(!message.contains("Insufficient credits"))
            #expect(!message.lowercased().contains("bearer"))
        }

        // A top-level error envelope inside HTTP 200 is a failure, not output.
        let transport = FakeHTTPTransport()
        transport.configure(status: 200, body: envelope)
        let integration = makeIntegration(transport: transport, vault: makeVault())
        #expect(await integration.refine(rawTranscript: "hello", modeName: nil, modeInstructions: nil) == .failed(.creditsExhausted))
    }

    @Test("Rate limiting honors Retry-After and rate headers without automatic retry")
    func rateLimitHandling() async {
        let transport = FakeHTTPTransport()
        transport.configure(
            status: 429,
            headers: [
                "Retry-After": "7",
                "X-RateLimit-Limit": "20",
                "X-RateLimit-Remaining": "0",
                "X-RateLimit-Reset": "30"
            ],
            body: Data(#"{"error":{"code":429,"message":"Rate limited"}}"#.utf8)
        )
        let integration = makeIntegration(transport: transport, vault: makeVault())

        let result = await integration.refine(rawTranscript: "hello", modeName: nil, modeInstructions: nil)
        #expect(result == .failed(.rateLimited))
        let info = await integration.lastRateLimitInfo
        #expect(info?.retryAfter == 7)
        #expect(info?.limit == 20)
        #expect(info?.remaining == 0)
        #expect(info?.reset == 30)
        // One in-flight request per recording and role; nothing retries itself.
        #expect(transport.requests.count == 1)

        // An explicit user retry is allowed and is the only way forward.
        transport.configure(body: successBody())
        let retry = await integration.refine(rawTranscript: "hello", modeName: nil, modeInstructions: nil)
        #expect(retry == .refined("Refined transcript."))
        #expect(transport.requests.count == 2)
    }

    @Test("Client-side timeouts and transport failures never become refined text")
    func timeoutAndTransportFailures() async {
        let transport = FakeHTTPTransport()
        transport.fail(with: URLError(.timedOut))
        let integration = makeIntegration(transport: transport, vault: makeVault())
        #expect(await integration.refine(rawTranscript: "hello", modeName: nil, modeInstructions: nil) == .failed(.timedOut))

        let transport2 = FakeHTTPTransport()
        transport2.fail(with: URLError(.cannotConnectToHost))
        let integration2 = makeIntegration(transport: transport2, vault: makeVault())
        #expect(await integration2.refine(rawTranscript: "hello", modeName: nil, modeInstructions: nil) == .failed(.transport))
    }

    // MARK: - One in-flight request per recording and role

    @Test("A second refinement cannot start while one is in flight")
    func oneInFlightRequestPerRole() async throws {
        let transport = FakeHTTPTransport()
        transport.configure(body: successBody())
        let gate = Gate()
        transport.gate = gate
        let integration = makeIntegration(transport: transport, vault: makeVault())

        let first = Task {
            await integration.refine(rawTranscript: "hello", modeName: nil, modeInstructions: nil)
        }
        while transport.requests.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }

        let second = await integration.refine(rawTranscript: "hello again", modeName: nil, modeInstructions: nil)
        #expect(second == .failed(.inFlight))
        #expect(transport.requests.count == 1)

        gate.open()
        #expect(await first.value == .refined("Refined transcript."))
    }

    // MARK: - Cancellation

    @Test("Cancellation discards late output and keeps only the raw transcript path")
    func cancellationDiscardsLateOutput() async throws {
        let transport = FakeHTTPTransport()
        transport.configure(body: successBody(content: "Late refinement"))
        let gate = Gate()
        transport.gate = gate
        let integration = makeIntegration(transport: transport, vault: makeVault())

        let outer = Task {
            await integration.refine(rawTranscript: "raw text", modeName: nil, modeInstructions: nil)
        }
        while transport.requests.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }

        await integration.cancelRefinement()
        #expect(await integration.state == .cancelled)

        // The provider response arrives late and is discarded.
        gate.open()
        let result = await outer.value
        #expect(result == .failed(.cancelled))
        #expect(await integration.lastRefinedText == nil)
    }
}
