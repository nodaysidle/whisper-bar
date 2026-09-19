import Foundation

// MARK: - HTTP seam (shared by the OpenRouter integrations)

/// One typed HTTPS request. Actors own the URLSession boundary; tests inject a
/// fake so no live request is ever made.
struct HTTPRequest: Sendable {
    let url: URL
    let method: String
    let headers: [String: String]
    let body: Data
    let timeout: TimeInterval

    init(url: URL, method: String, headers: [String: String], body: Data, timeout: TimeInterval) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

struct HTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    /// Header lookup is case-insensitive because HTTP header names are.
    func headerValue(_ name: String) -> String? {
        if let exact = headers[name] { return exact }
        let lowered = name.lowercased()
        return headers.first { $0.key.lowercased() == lowered }?.value
    }
}

protocol HTTPTransporting: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// Live URLSession boundary. The request and resource timeouts come from the
/// contract call site; cancelling the surrounding Swift task cancels the
/// underlying URLSessionTask.
struct URLSessionHTTPTransport: HTTPTransporting {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = request.timeout
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.httpBody = request.body

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = request.timeout
        configuration.timeoutIntervalForResource = request.timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers["\(key)"] = "\(value)"
        }
        return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }
}

// MARK: - OpenRouter error envelope

/// `error.code`, `error.message`, and `error.metadata.error_type` for every
/// documented HTTP failure status. Raw messages are decoded for classification
/// only and are never surfaced in UI state or logs.
struct OpenRouterErrorEnvelope: Codable, Equatable, Sendable {
    struct ErrorBody: Codable, Equatable, Sendable {
        struct Metadata: Codable, Equatable, Sendable {
            let errorType: String?

            enum CodingKeys: String, CodingKey {
                case errorType = "error_type"
            }
        }

        let code: Int?
        let message: String?
        let metadata: Metadata?
    }

    let error: ErrorBody

    static func decode(from data: Data) -> OpenRouterErrorEnvelope? {
        try? JSONDecoder().decode(OpenRouterErrorEnvelope.self, from: data)
    }
}

// MARK: - Refinement DTOs

struct OpenRouterChatMessage: Codable, Equatable, Sendable {
    let role: String
    let content: String
}

struct OpenRouterReasoningConfiguration: Codable, Equatable, Sendable {
    let effort: String
}

struct OpenRouterChatRequestBody: Codable, Equatable, Sendable {
    let model: String
    let messages: [OpenRouterChatMessage]
    let temperature: Double
    let reasoning: OpenRouterReasoningConfiguration
    let stream: Bool
}

struct OpenRouterUsage: Codable, Equatable, Sendable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
    let cost: Double?
    let costDetails: [String: Double]?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case cost
        case costDetails = "cost_details"
    }
}

struct OpenRouterChatChoiceMessage: Codable, Equatable, Sendable {
    let role: String?
    let content: String?
}

struct OpenRouterChatChoice: Codable, Equatable, Sendable {
    let index: Int?
    let message: OpenRouterChatChoiceMessage
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case index
        case message
        case finishReason = "finish_reason"
    }
}

struct OpenRouterChatResponseBody: Codable, Equatable, Sendable {
    let id: String?
    let model: String?
    let created: Int?
    let choices: [OpenRouterChatChoice]
    let usage: OpenRouterUsage?
}

/// Provider metadata retained for the refinement role without transcript
/// logging.
struct RefinementResponseMetadata: Equatable, Sendable {
    let id: String?
    let model: String?
    let created: Int?
    let providerErrorType: String?
}

/// Rate-limit headers honored when the provider supplies them; no numeric
/// quota is ever assumed.
struct OpenRouterRateLimitInfo: Equatable, Sendable {
    let retryAfter: TimeInterval?
    let limit: Int?
    let remaining: Int?
    let reset: TimeInterval?

    static func decode(from response: HTTPResponse) -> OpenRouterRateLimitInfo? {
        let retryAfter = response.headerValue("Retry-After").flatMap { TimeInterval($0) }
        let limit = response.headerValue("X-RateLimit-Limit").flatMap { Int($0) }
        let remaining = response.headerValue("X-RateLimit-Remaining").flatMap { Int($0) }
        let reset = response.headerValue("X-RateLimit-Reset").flatMap { TimeInterval($0) }
        guard retryAfter != nil || limit != nil || remaining != nil || reset != nil else {
            return nil
        }
        return OpenRouterRateLimitInfo(
            retryAfter: retryAfter,
            limit: limit,
            remaining: remaining,
            reset: reset
        )
    }
}

// MARK: - Refinement failures and results

/// Distinct privacy-safe refinement failures. None carries raw provider text,
/// and none ever replaces the accepted raw transcript.
enum RefinementFailure: Equatable, Sendable {
    case disabled
    case invalidInput
    case missingCredential
    case inFlight
    case unauthenticated
    case creditsExhausted
    case permission
    case invalidRequest
    case payloadTooLarge
    case requestTimeout
    case rateLimited
    case providerFailure(status: Int)
    case timedOut
    case malformedResponse
    case emptyOutput
    case filtered
    case nonStopFinish(finishReason: String)
    case transport
    case cancelled

    /// A refinement retry never happens automatically; these categories are
    /// the ones where an explicit user retry is the documented next step.
    var allowsExplicitRetry: Bool {
        switch self {
        case .cancelled, .invalidInput, .disabled, .missingCredential:
            return false
        default:
            return true
        }
    }

    var userFacingMessage: String {
        switch self {
        case .disabled:
            return "Refinement is turned off. Enable it in Settings to refine transcripts."
        case .invalidInput:
            return "There is no completed transcript to refine yet."
        case .missingCredential:
            return "Add an OpenRouter API key in Settings before refining."
        case .inFlight:
            return "A refinement is already running for this recording."
        case .unauthenticated:
            return "OpenRouter rejected the stored API key. Replace it in Settings and retry."
        case .creditsExhausted:
            return "OpenRouter reported insufficient credits. Top up and retry explicitly."
        case .permission:
            return "OpenRouter denied this request for the account."
        case .invalidRequest:
            return "OpenRouter rejected the refinement request."
        case .payloadTooLarge:
            return "The refinement request was too large."
        case .requestTimeout:
            return "OpenRouter took too long to answer."
        case .rateLimited:
            return "OpenRouter is rate limiting this account. Wait and retry explicitly."
        case .providerFailure:
            return "OpenRouter reported a provider failure. Retry or use the raw transcript."
        case .timedOut:
            return "Refinement timed out. The raw transcript is unchanged."
        case .malformedResponse:
            return "OpenRouter returned an unreadable response. The raw transcript is unchanged."
        case .emptyOutput:
            return "OpenRouter returned no refined text. The raw transcript is unchanged."
        case .filtered:
            return "The provider filtered the refinement output. The raw transcript is unchanged."
        case .nonStopFinish:
            return "The refinement stopped early. The raw transcript is unchanged."
        case .transport:
            return "The refinement request could not reach OpenRouter. The raw transcript is unchanged."
        case .cancelled:
            return "Refinement was cancelled. The raw transcript is unchanged."
        }
    }
}

enum RefinementState: Equatable, Sendable {
    case idle
    case active
    case succeeded(text: String)
    case failed(RefinementFailure)
    case cancelled
}

enum RefinementResult: Equatable, Sendable {
    case refined(String)
    case failed(RefinementFailure)
}

// MARK: - OpenrouterRefinementIntegration

/// OWN-INTEGRATION-OPENROUTER-REFINEMENT.
///
/// Owns CON-INTEGRATION-OPENROUTER-REFINEMENT: optional non-live refinement
/// through `POST https://openrouter.ai/api/v1/chat/completions` with the
/// locked model, temperature, reasoning, and stream values, exactly one system
/// instruction and one user payload, authoritative provider usage, explicit
/// rate-limit handling, and cancellation that discards late output. It never
/// makes a second paid request automatically.
actor OpenrouterRefinementIntegration {

    static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    static let defaultModel = "google/gemini-2.5-flash-lite"
    static let requestTimeout: TimeInterval = 30

    static let lockedSystemInstruction =
        "Edit only the supplied transcript. Preserve meaning, names, code, and technical terms; never invent speech, facts, speakers, or omitted content; apply only the selected mode; return only the refined transcript."

    // MARK: Observable state

    private(set) var isEnabled = false
    private(set) var state: RefinementState = .idle
    private(set) var lastFailure: RefinementFailure?
    private(set) var lastRefinedText: String?
    private(set) var lastUsage: OpenRouterUsage?
    private(set) var lastReportedCost: Double?
    private(set) var lastResponseMetadata: RefinementResponseMetadata?
    private(set) var lastRateLimitInfo: OpenRouterRateLimitInfo?

    // MARK: Dependencies

    private let credentialVault: CredentialVault
    private let transport: any HTTPTransporting

    private var activeTask: Task<HTTPResponse, any Error>?
    private var operationGeneration = 0

    init(
        credentialVault: CredentialVault = CredentialVault(),
        transport: any HTTPTransporting = URLSessionHTTPTransport(),
        isEnabled: Bool = false
    ) {
        self.credentialVault = credentialVault
        self.transport = transport
        self.isEnabled = isEnabled
    }

    /// Optional refinement is enabled only by an explicit configuration.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    // MARK: Request construction

    /// The locked user payload: the raw transcript plus the selected mode.
    static func userPayload(rawTranscript: String, modeName: String?, modeInstructions: String?) -> String {
        let mode = modeName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = modeInstructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        var payload = ""
        if let mode, !mode.isEmpty {
            payload += "Selected mode: \(mode)\n"
        }
        if let instructions, !instructions.isEmpty {
            payload += "Mode instructions: \(instructions)\n"
        }
        payload += "Transcript:\n\(rawTranscript)"
        return payload
    }

    static func requestBody(
        rawTranscript: String,
        modeName: String?,
        modeInstructions: String?,
        model: String
    ) -> OpenRouterChatRequestBody {
        OpenRouterChatRequestBody(
            model: model,
            messages: [
                OpenRouterChatMessage(role: "system", content: lockedSystemInstruction),
                OpenRouterChatMessage(
                    role: "user",
                    content: userPayload(
                        rawTranscript: rawTranscript,
                        modeName: modeName,
                        modeInstructions: modeInstructions
                    )
                )
            ],
            temperature: 0.0,
            reasoning: OpenRouterReasoningConfiguration(effort: "none"),
            stream: false
        )
    }

    // MARK: Refinement

    /// One refinement attempt. The accepted raw transcript is never modified;
    /// the caller decides whether to use the refined text or the raw text.
    func refine(
        rawTranscript: String,
        modeName: String?,
        modeInstructions: String?,
        model: String? = nil
    ) async -> RefinementResult {
        guard isEnabled else { return finish(.failed(.disabled)) }
        let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return finish(.failed(.invalidInput)) }

        switch state {
        case .active:
            // One in-flight request per recording and role.
            return .failed(.inFlight)
        default:
            break
        }

        let credential = (try? await credentialVault.value(for: .openRouter)) ?? nil
        guard let key = credential?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return finish(.failed(.missingCredential))
        }

        let body: Data
        do {
            body = try JSONEncoder().encode(
                Self.requestBody(
                    rawTranscript: trimmed,
                    modeName: modeName,
                    modeInstructions: modeInstructions,
                    model: model ?? Self.defaultModel
                )
            )
        } catch {
            return finish(.failed(.invalidRequest))
        }

        operationGeneration += 1
        let generation = operationGeneration
        state = .active
        lastFailure = nil

        let request = HTTPRequest(
            url: Self.endpoint,
            method: "POST",
            headers: [
                "Authorization": "Bearer \(key)",
                "Content-Type": "application/json"
            ],
            body: body,
            timeout: Self.requestTimeout
        )

        // Retain the task so an explicit cancel can stop the paid request.
        let task = Task { try await transport.send(request) }
        activeTask = task

        let response: HTTPResponse
        do {
            response = try await task.value
        } catch is CancellationError {
            return finish(.failed(.cancelled))
        } catch let error as URLError where error.code == .timedOut {
            return finish(.failed(.timedOut))
        } catch let error as URLError where error.code == .cancelled {
            return finish(.failed(.cancelled))
        } catch {
            return finish(.failed(.transport))
        }
        activeTask = nil

        // Late output is discarded: cancellation invalidated this generation.
        guard generation == operationGeneration else {
            return .failed(.cancelled)
        }

        return process(response)
    }

    /// Explicit cancellation: invalidate the generation first, cancel the
    /// retained task, and discard every late response.
    func cancelRefinement() {
        operationGeneration += 1
        activeTask?.cancel()
        activeTask = nil
        if state == .active {
            state = .cancelled
        }
    }

    // MARK: Response processing

    private func process(_ response: HTTPResponse) -> RefinementResult {
        let status = response.statusCode
        if status == 429 {
            let info = OpenRouterRateLimitInfo.decode(from: response)
            lastRateLimitInfo = info
            return finish(.failed(.rateLimited))
        }
        guard status == 200 else {
            let envelope = OpenRouterErrorEnvelope.decode(from: response.body)
            return finish(.failed(Self.mapStatus(status, envelope: envelope)))
        }

        // A top-level error envelope inside HTTP 200 is a failure, not output.
        if let envelope = OpenRouterErrorEnvelope.decode(from: response.body),
           envelope.error.code != nil || envelope.error.message != nil {
            return finish(.failed(Self.mapStatus(envelope.error.code ?? 500, envelope: envelope)))
        }

        guard let decoded = try? JSONDecoder().decode(OpenRouterChatResponseBody.self, from: response.body),
              let choice = decoded.choices.first else {
            return finish(.failed(.malformedResponse))
        }

        let finishReason = choice.finishReason ?? ""
        if finishReason == "content_filter" {
            return finish(.failed(.filtered))
        }
        guard finishReason == "stop" else {
            return finish(.failed(.nonStopFinish(finishReason: finishReason)))
        }
        guard let content = choice.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return finish(.failed(.emptyOutput))
        }

        lastUsage = decoded.usage
        // The provider-returned cost is authoritative; never estimated.
        lastReportedCost = decoded.usage?.cost
        lastResponseMetadata = RefinementResponseMetadata(
            id: decoded.id,
            model: decoded.model,
            created: decoded.created,
            providerErrorType: nil
        )
        lastRefinedText = content
        state = .succeeded(text: content)
        lastFailure = nil
        return .refined(content)
    }

    static func mapStatus(_ status: Int, envelope: OpenRouterErrorEnvelope?) -> RefinementFailure {
        switch status {
        case 400, 422: return .invalidRequest
        case 401: return .unauthenticated
        case 402: return .creditsExhausted
        case 403: return .permission
        case 408: return .requestTimeout
        case 413: return .payloadTooLarge
        case 429: return .rateLimited
        default: return .providerFailure(status: status)
        }
    }

    @discardableResult
    private func finish(_ result: RefinementResult) -> RefinementResult {
        switch result {
        case .refined:
            break
        case .failed(let failure):
            if case .cancelled = failure {
                state = .cancelled
            } else {
                state = .failed(failure)
            }
            lastFailure = failure
        }
        return result
    }
}
