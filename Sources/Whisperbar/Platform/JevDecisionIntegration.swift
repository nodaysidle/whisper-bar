import Foundation
import OSLog

private let logger = Logger(subsystem: "com.whisperbar.app", category: "JevDecisionIntegration")

// MARK: - Decision Result

struct JevDecisionResult: Equatable, Sendable {
    let isHallucination: Bool
    let hallucinationProbability: Double
    let recommendedWritingMode: String?
    let needsRefinement: Bool
    let refinementProbability: Double
    let latencyMs: Double

    init(
        isHallucination: Bool,
        hallucinationProbability: Double,
        recommendedWritingMode: String?,
        needsRefinement: Bool,
        refinementProbability: Double,
        latencyMs: Double
    ) {
        self.isHallucination = isHallucination
        self.hallucinationProbability = hallucinationProbability
        self.recommendedWritingMode = recommendedWritingMode
        self.needsRefinement = needsRefinement
        self.refinementProbability = refinementProbability
        self.latencyMs = latencyMs
    }

    /// Safe fail-open default: preserves transcript, runs refinement if configured, marks no hallucination.
    static let failOpen = JevDecisionResult(
        isHallucination: false,
        hallucinationProbability: 0.0,
        recommendedWritingMode: nil,
        needsRefinement: true,
        refinementProbability: 0.5,
        latencyMs: 0.0
    )
}

// MARK: - Errors

enum JevDecisionError: Error, Equatable, Sendable {
    case missingApiKey
    case networkError(String)
    case httpError(statusCode: Int, message: String?)
    case decodingError(String)
    case timeout
}

// MARK: - Request & Response DTOs

struct SystemOneState: Encodable, Sendable {
    let transcript: String
    let frontmostApp: String?

    enum CodingKeys: String, CodingKey {
        case transcript
        case frontmostApp = "frontmost_app"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(transcript, forKey: .transcript)
        if let frontmostApp {
            try container.encode(frontmostApp, forKey: .frontmostApp)
        }
    }
}

struct SystemOneQuestion: Encodable, Sendable {
    let type: String
    let instructions: String
    let criteria: [String: String]?

    init(type: String, instructions: String, criteria: [String: String]? = nil) {
        self.type = type
        self.instructions = instructions
        self.criteria = criteria
    }

    enum CodingKeys: String, CodingKey {
        case type
        case instructions
        case criteria
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(instructions, forKey: .instructions)
        if let criteria {
            try container.encode(criteria, forKey: .criteria)
        }
    }
}

struct SystemOneRequest: Encodable, Sendable {
    let model: String
    let state: SystemOneState
    let questions: [String: SystemOneQuestion]
}

struct SystemOneUsage: Decodable, Sendable {
    let inputTokens: Int?
    let outputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

struct SystemOneAnswer: Decodable, Sendable {
    let type: String
    let noul: Double?
    let choice: String?
    let probabilities: [String: Double]?
    let confidence: Double?
    let score: Double?
    let legend: [String: String]?
}

struct SystemOneResponse: Decodable, Sendable {
    let model: String
    let answers: [String: SystemOneAnswer]
    let usage: SystemOneUsage?
}

// MARK: - Actor

actor JevDecisionIntegration {
    static let defaultEndpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    static let defaultTimeout: TimeInterval = 1.2
    static let model = "jev-latest"

    // Decision thresholds from specification
    static let hallucinationThreshold: Double = 0.85
    static let refinementThreshold: Double = 0.30

    private let session: URLSession
    private let endpoint: URL
    private let timeout: TimeInterval
    private let apiKeyProvider: @Sendable () async -> String?

    init(
        session: URLSession = .shared,
        endpoint: URL = JevDecisionIntegration.defaultEndpoint,
        timeout: TimeInterval = JevDecisionIntegration.defaultTimeout,
        apiKeyProvider: @escaping @Sendable () async -> String?
    ) {
        self.session = session
        self.endpoint = endpoint
        self.timeout = timeout
        self.apiKeyProvider = apiKeyProvider
    }

    init(
        session: URLSession = .shared,
        endpoint: URL = JevDecisionIntegration.defaultEndpoint,
        timeout: TimeInterval = JevDecisionIntegration.defaultTimeout,
        credentialVault: CredentialVault
    ) {
        self.init(
            session: session,
            endpoint: endpoint,
            timeout: timeout,
            apiKeyProvider: { await credentialVault.loadTypesafeKey() }
        )
    }

    /// Evaluates speech transcript and frontmost application context against TypeSafe Jev.
    /// Throws typed `JevDecisionError` on network, API, or decoding failures.
    func evaluate(
        transcript: String,
        frontmostApp: String?
    ) async throws -> JevDecisionResult {
        guard let apiKey = await apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            throw JevDecisionError.missingApiKey
        }

        let state = SystemOneState(
            transcript: transcript,
            frontmostApp: frontmostApp
        )

        let questions: [String: SystemOneQuestion] = [
            "is_hallucination": SystemOneQuestion(
                type: "noul",
                instructions: "Is this transcript a phantom subtitle, background noise hallucination, repeated loop, or non-speech artifact (such as 'Thank you for watching', 'Subtitles by...', or silence)?"
            ),
            "writing_mode": SystemOneQuestion(
                type: "choice",
                instructions: "Based on the transcript and frontmost application context, which writing mode format is most appropriate?",
                criteria: [
                    "code": "Code snippets, terminal/shell commands, variable names, or programming",
                    "markdown": "Hierarchical notes, lists, headers, or bullet points",
                    "prose": "Natural flowing sentences, email, essays, or web writing",
                    "prompt": "Instructions or prompts directed to an AI assistant",
                    "raw": "Exact verbatim speech without special formatting"
                ]
            ),
            "needs_refinement": SystemOneQuestion(
                type: "noul",
                instructions: "Does this spoken transcript contain grammar errors, disfluencies, stuttering, filler words, or awkward phrasing that needs cleanup and refinement?"
            )
        ]

        let payload = SystemOneRequest(
            model: Self.model,
            state: state,
            questions: questions
        )

        let bodyData: Data
        do {
            bodyData = try JSONEncoder().encode(payload)
        } catch {
            throw JevDecisionError.decodingError("Failed to encode request payload: \(error)")
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = bodyData
        urlRequest.timeoutInterval = timeout

        let clockStart = ContinuousClock.now

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw JevDecisionError.timeout
        } catch {
            throw JevDecisionError.networkError(error.localizedDescription)
        }

        let clockElapsed = ContinuousClock.now - clockStart
        let latencyMs = Double(clockElapsed.components.seconds) * 1000.0 + Double(clockElapsed.components.attoseconds) / 1_000_000_000_000_000.0

        guard let httpResponse = response as? HTTPURLResponse else {
            throw JevDecisionError.networkError("Invalid non-HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8)
            throw JevDecisionError.httpError(statusCode: httpResponse.statusCode, message: message)
        }

        let systemOneResponse: SystemOneResponse
        do {
            systemOneResponse = try JSONDecoder().decode(SystemOneResponse.self, from: data)
        } catch {
            throw JevDecisionError.decodingError("Failed to decode SystemOne response: \(error)")
        }

        let hallucinationProb = systemOneResponse.answers["is_hallucination"]?.noul ?? 0.0
        let isHallucination = hallucinationProb > Self.hallucinationThreshold

        let recommendedMode = systemOneResponse.answers["writing_mode"]?.choice

        let refinementProb = systemOneResponse.answers["needs_refinement"]?.noul ?? 0.5
        let needsRefinement = refinementProb >= Self.refinementThreshold

        return JevDecisionResult(
            isHallucination: isHallucination,
            hallucinationProbability: hallucinationProb,
            recommendedWritingMode: recommendedMode,
            needsRefinement: needsRefinement,
            refinementProbability: refinementProb,
            latencyMs: latencyMs
        )
    }

    /// Evaluates speech with automatic fail-open recovery. Never throws.
    /// If an error occurs or the API key is missing, logs a warning and returns `JevDecisionResult.failOpen`.
    func evaluateFailOpen(
        transcript: String,
        frontmostApp: String?
    ) async -> JevDecisionResult {
        do {
            return try await evaluate(transcript: transcript, frontmostApp: frontmostApp)
        } catch {
            logger.warning("Jev evaluation failed, failing open: \(error.localizedDescription, privacy: .public)")
            return .failOpen
        }
    }
}
