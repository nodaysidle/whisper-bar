import Foundation
import Testing
@testable import Whisperbar

@Suite("JevDecisionIntegration — TypeSafe System One structured decision engine", .serialized)
struct JevDecisionIntegrationTests {

    // MARK: - URLProtocol Mock

    final class MockURLProtocol: URLProtocol, @unchecked Sendable {
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
            MockURLProtocol.lock.lock()
            MockURLProtocol._lastRequest = request
            let handler = MockURLProtocol._requestHandler
            MockURLProtocol.lock.unlock()

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

    private static func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    // MARK: - In-Memory Keychain for Vault Tests

    final class InMemoryKeychainStore: KeychainStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: String] = [:]

        func read(account: String, service: String) throws -> String? {
            lock.lock()
            defer { lock.unlock() }
            return storage["\(service):\(account)"]
        }

        func store(value: String, account: String, service: String) throws {
            lock.lock()
            defer { lock.unlock() }
            storage["\(service):\(account)"] = value
        }

        func delete(account: String, service: String) throws {
            lock.lock()
            defer { lock.unlock() }
            storage.removeValue(forKey: "\(service):\(account)")
        }
    }

    // MARK: - Tests

    @Test("Request serialization creates expected System One payload and auth header")
    func requestSerialization() async throws {
        MockURLProtocol.reset()
        let session = Self.makeMockSession()

        let responseJSON = """
        {
            "model": "jev-latest",
            "answers": {
                "is_hallucination": { "type": "noul", "noul": 0.05 },
                "writing_mode": { "type": "choice", "choice": "code", "confidence": 0.95 },
                "needs_refinement": { "type": "noul", "noul": 0.12 }
            },
            "usage": { "input_tokens": 120, "output_tokens": 30 }
        }
        """

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(responseJSON.utf8))
        }

        let integration = JevDecisionIntegration(
            session: session,
            apiKeyProvider: { "test-typesafe-api-key-xyz" }
        )

        let result = try await integration.evaluate(
            transcript: "git status --short",
            frontmostApp: "Ghostty"
        )

        let request = try #require(MockURLProtocol.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-typesafe-api-key-xyz")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.url?.absoluteString == "https://api.typesafe.ai/v1/systemone")

        guard let bodyData = request.httpBody ?? request.httpBodyStreamData() else {
            Issue.record("Request body data missing")
            return
        }

        let bodyObj = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(bodyObj["model"] as? String == "jev-latest")

        let state = try #require(bodyObj["state"] as? [String: Any])
        #expect(state["transcript"] as? String == "git status --short")
        #expect(state["frontmost_app"] as? String == "Ghostty")

        let questions = try #require(bodyObj["questions"] as? [String: Any])
        #expect(questions["is_hallucination"] != nil)
        #expect(questions["writing_mode"] != nil)
        #expect(questions["needs_refinement"] != nil)

        // Result verification
        #expect(result.isHallucination == false)
        #expect(result.hallucinationProbability == 0.05)
        #expect(result.recommendedWritingMode == "code")
        #expect(result.needsRefinement == false)
        #expect(result.refinementProbability == 0.12)
        #expect(result.latencyMs >= 0)
    }

    @Test("Response deserialization handles hallucination threshold p > 0.85")
    func hallucinationDetection() async throws {
        MockURLProtocol.reset()
        let session = Self.makeMockSession()

        let responseJSON = """
        {
            "model": "jev-latest",
            "answers": {
                "is_hallucination": { "type": "noul", "noul": 0.94 },
                "writing_mode": { "type": "choice", "choice": "prose", "confidence": 0.80 },
                "needs_refinement": { "type": "noul", "noul": 0.50 }
            }
        }
        """

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(responseJSON.utf8))
        }

        let integration = JevDecisionIntegration(
            session: session,
            apiKeyProvider: { "dummy-key" }
        )

        let result = try await integration.evaluate(
            transcript: "Thank you for watching.",
            frontmostApp: "Safari"
        )

        #expect(result.isHallucination == true)
        #expect(result.hallucinationProbability == 0.94)
        #expect(result.recommendedWritingMode == "prose")
    }

    @Test("Response deserialization handles refinement threshold p >= 0.30")
    func refinementThresholds() async throws {
        MockURLProtocol.reset()
        let session = Self.makeMockSession()

        // Clean speech (p = 0.15 < 0.30) -> needsRefinement == false
        let cleanJSON = """
        {
            "model": "jev-latest",
            "answers": {
                "is_hallucination": { "type": "noul", "noul": 0.02 },
                "writing_mode": { "type": "choice", "choice": "prose" },
                "needs_refinement": { "type": "noul", "noul": 0.15 }
            }
        }
        """

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(cleanJSON.utf8))
        }

        let integration = JevDecisionIntegration(
            session: session,
            apiKeyProvider: { "dummy-key" }
        )

        let cleanResult = try await integration.evaluate(transcript: "Hello world", frontmostApp: nil)
        #expect(cleanResult.needsRefinement == false)
        #expect(cleanResult.refinementProbability == 0.15)

        // Messy speech (p = 0.65 >= 0.30) -> needsRefinement == true
        let messyJSON = """
        {
            "model": "jev-latest",
            "answers": {
                "is_hallucination": { "type": "noul", "noul": 0.01 },
                "writing_mode": { "type": "choice", "choice": "prose" },
                "needs_refinement": { "type": "noul", "noul": 0.65 }
            }
        }
        """

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(messyJSON.utf8))
        }

        let messyResult = try await integration.evaluate(transcript: "Um like I was saying", frontmostApp: nil)
        #expect(messyResult.needsRefinement == true)
        #expect(messyResult.refinementProbability == 0.65)
    }

    @Test("Fail-open fallback on server error or missing key")
    func failOpenHandling() async throws {
        MockURLProtocol.reset()
        let session = Self.makeMockSession()

        // 1. Missing API Key throws JevDecisionError.missingApiKey
        let noKeyIntegration = JevDecisionIntegration(
            session: session,
            apiKeyProvider: { nil }
        )

        await #expect(throws: JevDecisionError.missingApiKey) {
            try await noKeyIntegration.evaluate(transcript: "Testing no key", frontmostApp: nil)
        }

        // evaluateFailOpen returns JevDecisionResult.failOpen
        let fallbackResult1 = await noKeyIntegration.evaluateFailOpen(transcript: "Testing no key", frontmostApp: nil)
        #expect(fallbackResult1.isHallucination == false)
        #expect(fallbackResult1.needsRefinement == true)
        #expect(fallbackResult1 == JevDecisionResult.failOpen)

        // 2. HTTP 500 error throws and evaluateFailOpen handles it
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("Internal server error".utf8))
        }

        let errorIntegration = JevDecisionIntegration(
            session: session,
            apiKeyProvider: { "some-key" }
        )

        await #expect(throws: JevDecisionError.self) {
            try await errorIntegration.evaluate(transcript: "Server error text", frontmostApp: nil)
        }

        let fallbackResult2 = await errorIntegration.evaluateFailOpen(transcript: "Server error text", frontmostApp: nil)
        #expect(fallbackResult2.isHallucination == false)
        #expect(fallbackResult2.needsRefinement == true)
        #expect(fallbackResult2 == JevDecisionResult.failOpen)
    }

    final class TestEnvBox: @unchecked Sendable {
        private let lock = NSLock()
        private var dict: [String: String] = [:]

        func set(_ key: String, value: String?) {
            lock.lock()
            defer { lock.unlock() }
            dict[key] = value
        }

        func get(_ key: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return dict[key]
        }
    }

    @Test("CredentialVault stores, loads, and deletes TypeSafe key with environment fallback")
    func credentialVaultTypesafeKeySupport() async throws {
        let store = InMemoryKeychainStore()
        let envBox = TestEnvBox()

        let vault = CredentialVault(
            store: store,
            environmentProvider: { envBox.get($0) }
        )

        // Initial state: no key in Keychain, no key in env
        #expect(await vault.loadTypesafeKey() == nil)

        // Fallback to TYPESAFE_API_KEY environment variable
        envBox.set("TYPESAFE_API_KEY", value: "sk-typesafe-env-secret-42")
        #expect(await vault.loadTypesafeKey() == "sk-typesafe-env-secret-42")

        // Storing in Keychain overrides env var
        try await vault.storeTypesafeKey("sk-typesafe-keychain-secret-99")
        #expect(await vault.loadTypesafeKey() == "sk-typesafe-keychain-secret-99")

        // Deleting from Keychain falls back to env var
        try await vault.deleteTypesafeKey()
        #expect(await vault.loadTypesafeKey() == "sk-typesafe-env-secret-42")

        // Removing env var leaves loadTypesafeKey as nil
        envBox.set("TYPESAFE_API_KEY", value: nil)
        #expect(await vault.loadTypesafeKey() == nil)

        // Storing whitespace/empty key is rejected
        await #expect(throws: CredentialVaultError.self) {
            try await vault.storeTypesafeKey("   \n")
        }
    }
}

// MARK: - Test Helpers

extension URLRequest {
    func httpBodyStreamData() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data
    }
}
