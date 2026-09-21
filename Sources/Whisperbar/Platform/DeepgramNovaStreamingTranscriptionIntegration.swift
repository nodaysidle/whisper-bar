import Foundation

// MARK: - Request validation

enum DeepgramRequestError: Error, Equatable, Sendable {
    case unsupportedLanguage
    case invalidKeyterm
}

// MARK: - Socket seam

/// One typed WebSocket frame received from Deepgram.
enum DeepgramSocketFrame: Equatable, Sendable {
    case text(String)
    case binary(Data)
}

/// Privacy-safe socket transport failures.
enum DeepgramSocketError: Error, Equatable, Sendable {
    case upgradeFailed(status: Int)
    case transport
    case timedOut
    case closed(code: Int, reason: String)
    /// The socket is still open and no frame arrived during this poll.
    /// This is not a connection failure.
    case pollIdle
}

/// An accepted WebSocket upgrade plus the provider request identifier when the
/// upgrade response exposed one.
struct DeepgramConnectedSocket: Sendable {
    let session: any DeepgramSocketSession
    let providerRequestID: String?
}

/// Injectable boundary around `URLSessionWebSocketTask` so tests never open a
/// real socket and never depend on Deepgram availability.
protocol DeepgramSocketSession: Sendable {
    var upgradeRequestID: String? { get async }
    func send(text: String) async throws
    func send(binary: Data) async throws
    func receive() async throws -> DeepgramSocketFrame?
    func close() async
}

protocol DeepgramSocketFactory: Sendable {
    func connect(url: URL, authorization: String) async throws -> DeepgramConnectedSocket
}

// MARK: - Live URLSessionWebSocketTask adapters

/// One actor-owned URLSession boundary (TRD "External Integration Contracts":
/// URLSessionWebSocketTask for streaming).
final class URLSessionDeepgramSocketSession: DeepgramSocketSession, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let session: URLSession
    /// One in-flight `receive` that outlives a poll. Cancelling the poll must
    /// not cancel this task, or the WebSocket read would be abandoned.
    private var inflight: Task<DeepgramSocketFrame?, Error>?

    init(task: URLSessionWebSocketTask, session: URLSession) {
        self.task = task
        self.session = session
    }

    var upgradeRequestID: String? { nil }

    func send(text: String) async throws {
        do {
            try await task.send(.string(text))
        } catch {
            throw DeepgramSocketError.transport
        }
    }

    func send(binary: Data) async throws {
        do {
            try await task.send(.data(binary))
        } catch {
            throw DeepgramSocketError.transport
        }
    }

    func receive() async throws -> DeepgramSocketFrame? {
        if inflight == nil {
            let task = self.task
            inflight = Task {
                try await Self.readFrame(from: task)
            }
        }
        guard let inflight else { throw DeepgramSocketError.transport }
        let arrived = await Self.waitForFrame(inflight, limit: .milliseconds(40))
        guard arrived else { throw DeepgramSocketError.pollIdle }
        self.inflight = nil
        return try await inflight.value
    }

    /// Waits until `read` finishes or the poll limit elapses. The read task is
    /// not a child of this wait, so a short poll does not cancel the socket.
    private static func waitForFrame(
        _ read: Task<DeepgramSocketFrame?, Error>,
        limit: Duration
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = try? await read.value
                return true
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return false
            }
            let arrived = await group.next() ?? false
            group.cancelAll()
            return arrived
        }
    }

    private static func readFrame(from task: URLSessionWebSocketTask) async throws -> DeepgramSocketFrame? {
        do {
            let message = try await task.receive()
            switch message {
            case .string(let text): return .text(text)
            case .data(let data): return .binary(data)
            @unknown default: return nil
            }
        } catch {
            let code = Int(task.closeCode.rawValue)
            let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if code == 0 {
                if (error as? URLError)?.code == .timedOut {
                    throw DeepgramSocketError.timedOut
                }
                throw DeepgramSocketError.transport
            }
            throw DeepgramSocketError.closed(code: code, reason: reason)
        }
    }

    func close() async {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

struct URLSessionDeepgramSocketFactory: DeepgramSocketFactory {
    func connect(url: URL, authorization: String) async throws -> DeepgramConnectedSocket {
        var request = URLRequest(url: url)
        // The stored API key authenticates with the documented Token scheme;
        // Bearer is reserved for a temporary JWT and is never used here.
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        // 15-second connection timeout for the WebSocket upgrade.
        request.timeoutInterval = DeepgramNovaStreamingTranscriptionIntegration.connectionTimeout

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest =
            DeepgramNovaStreamingTranscriptionIntegration.connectionTimeout
        // 30-minute resource timeout; user stop or cancellation may end sooner.
        configuration.timeoutIntervalForResource =
            DeepgramNovaStreamingTranscriptionIntegration.resourceTimeout

        let session = URLSession(configuration: configuration)
        let task = session.webSocketTask(with: request)
        task.resume()

        // The upgrade is accepted only once a task operation succeeds; a
        // rejected handshake surfaces on the first operation.
        do {
            try await Self.ping(task)
        } catch {
            let status = (task.response as? HTTPURLResponse)?.statusCode
            let code = Int(task.closeCode.rawValue)
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            if let status {
                throw DeepgramSocketError.upgradeFailed(status: status)
            }
            if code != 0 {
                throw DeepgramSocketError.closed(code: code, reason: "")
            }
            if (error as? URLError)?.code == .timedOut {
                throw DeepgramSocketError.timedOut
            }
            throw DeepgramSocketError.transport
        }

        return DeepgramConnectedSocket(
            session: URLSessionDeepgramSocketSession(task: task, session: session),
            providerRequestID: nil
        )
    }

    /// Pings the peer through the completion-handler API wrapped in a
    /// continuation: ping only succeeds after the WebSocket handshake.
    private static func ping(_ task: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

// MARK: - Typed events

struct DeepgramWord: Codable, Equatable, Sendable {
    let word: String?
    let start: Double?
    let end: Double?
    let confidence: Double?
}

struct DeepgramAlternative: Codable, Equatable, Sendable {
    let transcript: String
    let confidence: Double?
    let words: [DeepgramWord]?
}

struct DeepgramResultsChannel: Codable, Equatable, Sendable {
    let alternatives: [DeepgramAlternative]
}

struct DeepgramResultsMessage: Codable, Equatable, Sendable {
    let channelIndex: [Int]?
    let duration: Double?
    let start: Double?
    let channel: DeepgramResultsChannel
    let isFinal: Bool?
    let speechFinal: Bool?
    let fromFinalize: Bool?

    enum CodingKeys: String, CodingKey {
        case channelIndex = "channel_index"
        case duration
        case start
        case channel
        case isFinal = "is_final"
        case speechFinal = "speech_final"
        case fromFinalize = "from_finalize"
    }
}

struct DeepgramSpeechStartedMessage: Codable, Equatable, Sendable {
    let channel: [Int]?
    let timestamp: Double?
}

struct DeepgramUtteranceEndMessage: Codable, Equatable, Sendable {
    let channel: [Int]?
    let lastWordEnd: Double?

    enum CodingKeys: String, CodingKey {
        case channel
        case lastWordEnd = "last_word_end"
    }
}

struct DeepgramMetadataSummary: Codable, Equatable, Sendable {
    let requestID: String?
    let sha256: String?
    let created: String?
    let duration: Double?
    let channels: Int?
    let transactionKey: String?

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case sha256
        case created
        case duration
        case channels
        case transactionKey = "transaction_key"
    }
}

/// Typed Codable event enum decoded by `type`. Unknown typed messages are
/// surfaced explicitly so the owner can classify them instead of crashing.
enum DeepgramStreamEvent: Equatable, Sendable {
    case results(DeepgramResultsMessage)
    case speechStarted(DeepgramSpeechStartedMessage)
    case utteranceEnd(DeepgramUtteranceEndMessage)
    case metadata(DeepgramMetadataSummary)
    case unknown(type: String)

    private struct Envelope: Decodable {
        let type: String
    }

    static func decode(from data: Data) throws -> DeepgramStreamEvent {
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(Envelope.self, from: data)
        switch envelope.type {
        case "Results":
            return .results(try decoder.decode(DeepgramResultsMessage.self, from: data))
        case "SpeechStarted":
            return .speechStarted(try decoder.decode(DeepgramSpeechStartedMessage.self, from: data))
        case "UtteranceEnd":
            return .utteranceEnd(try decoder.decode(DeepgramUtteranceEndMessage.self, from: data))
        case "Metadata":
            return .metadata(try decoder.decode(DeepgramMetadataSummary.self, from: data))
        default:
            return .unknown(type: envelope.type)
        }
    }
}

// MARK: - Failures and states

/// Distinct privacy-safe terminal states. No case carries raw provider
/// content; correlation stays in the request identifier.
enum DeepgramStreamFailure: Equatable, Sendable {
    case malformedConfiguration
    case authentication
    case permission
    case rateLimited
    case providerFailure(status: Int)
    case transport
    case timedOut
    case malformedMessage
    case malformedAudio
    case insufficientAudioTimeout
    case frameTimeout
    case noAudioTimeout
    case emptyFinalOutput
    case credentialUnavailable

    /// Recoverable provider failures are the only states that may retain
    /// temporary audio, and only while awaiting an explicit retry or switch.
    var isRecoverableProviderFailure: Bool {
        switch self {
        case .providerFailure, .rateLimited, .transport, .timedOut, .insufficientAudioTimeout:
            return true
        default:
            return false
        }
    }

    var userFacingMessage: String {
        switch self {
        case .malformedConfiguration:
            return "Deepgram could not accept the stream configuration. Check the language and vocabulary and retry."
        case .authentication:
            return "Deepgram rejected the stored API key. Replace it in Settings and retry."
        case .permission:
            return "Deepgram denied access for this request."
        case .rateLimited:
            return "Deepgram is rate limiting this account or key. Wait and retry explicitly."
        case .providerFailure:
            return "Deepgram reported a provider failure. Retry or cancel explicitly."
        case .transport:
            return "The connection to Deepgram failed. Check the network and retry."
        case .timedOut:
            return "The connection to Deepgram timed out."
        case .malformedMessage:
            return "Deepgram sent a message this build does not recognize."
        case .malformedAudio:
            return "The captured audio was rejected by Deepgram."
        case .insufficientAudioTimeout:
            return "Deepgram timed out waiting for enough audio."
        case .frameTimeout:
            return "Deepgram timed out waiting for audio frames."
        case .noAudioTimeout:
            return "No audio reached Deepgram within its deadline."
        case .emptyFinalOutput:
            return "Deepgram returned no final transcript for this recording."
        case .credentialUnavailable:
            return "Add a Deepgram API key in Settings before using this provider."
        }
    }
}

enum DeepgramStreamState: Equatable, Sendable {
    case idle
    case connecting
    case streaming
    case finalizing
    case closing
    case succeeded(finalText: String)
    case failed(DeepgramStreamFailure)
    case cancelled
}

enum DeepgramConnectionTestResult: Equatable, Sendable {
    case succeeded(requestID: String?)
    case missingCredential
    case failed(DeepgramStreamFailure)
}

// MARK: - DeepgramNovaStreamingTranscriptionIntegration

/// OWN-INTEGRATION-DEEPGRAM-NOVA-STREAMING-TRANSCRIPTION.
///
/// Owns CON-INTEGRATION-DEEPGRAM-NOVA-STREAMING-TRANSCRIPTION: exactly one
/// authenticated `wss://api.deepgram.com/v1/listen` stream with the locked
/// `model=nova-3` query for each user-started live transcription, raw
/// headerless linear16 mono PCM at 16000 Hz as binary frames, typed Codable
/// events, KeepAlive/Finalize/CloseStream sequencing, privacy-safe failure
/// classification, and cancellation that discards late events. No automatic
/// retry or paid fallback ever follows a failure; recovery is an explicit
/// user retry or provider switch.
actor DeepgramNovaStreamingTranscriptionIntegration {

    // MARK: Locked constants

    static let keepAliveInterval: TimeInterval = 4
    static let connectionTimeout: TimeInterval = 15
    static let resourceTimeout: TimeInterval = 1800
    static let maxKeytermLength = 100

    private static let keepAliveFrame = #"{"type":"KeepAlive"}"#
    private static let finalizeFrame = #"{"type":"Finalize"}"#
    private static let closeStreamFrame = #"{"type":"CloseStream"}"#

    /// Validated language values accepted by the locked query model.
    static let supportedLanguages: Set<String> = [
        "en", "en-US", "en-GB", "en-AU", "en-IN", "en-NZ",
        "es", "es-419", "fr", "fr-CA", "de", "de-CH", "it", "nl", "pt", "pt-BR",
        "ru", "zh", "zh-CN", "zh-TW", "ja", "ko", "hi", "tr", "pl", "uk",
        "sv", "da", "no", "fi", "cs", "el", "id", "ms", "vi", "th", "hu",
        "ro", "bg", "hr", "sk", "sl"
    ]

    // MARK: Observable state

    private(set) var state: DeepgramStreamState = .idle
    private(set) var lastFailure: DeepgramStreamFailure?
    private(set) var interimTranscript: String = ""
    private(set) var finalTranscript: String = ""
    private(set) var providerRequestID: String?
    private(set) var lastUnknownMessageType: String?
    private(set) var lastSpeechStartedTimestamp: Double?
    private(set) var lastUtteranceEndTimestamp: Double?

    /// The one complete insertion candidate: only a succeeded final transcript.
    /// Interim, partial, failed, cancelled, or empty text is never returned.
    var completedTranscript: String? {
        guard case .succeeded(let text) = state, !text.isEmpty else { return nil }
        return text
    }

    /// Temporary audio may be retained only while awaiting an explicit retry
    /// or an explicit provider switch after a recoverable provider failure.
    var retainsTemporaryAudioForExplicitRecovery: Bool {
        guard case .failed(let failure) = state else { return false }
        return failure.isRecoverableProviderFailure
    }

    // MARK: Dependencies

    private let credentialVault: CredentialVault
    private let socketFactory: any DeepgramSocketFactory
    private let now: @Sendable () -> Date

    private var socket: (any DeepgramSocketSession)?
    private var generation = 0

    // MARK: Session bookkeeping

    private var hasSentAudioFrame = false
    private var lastOutboundFrameAt: Date?

    init(
        credentialVault: CredentialVault = CredentialVault(),
        socketFactory: any DeepgramSocketFactory = URLSessionDeepgramSocketFactory(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.credentialVault = credentialVault
        self.socketFactory = socketFactory
        self.now = now
    }

    // MARK: Request construction

    /// Builds the exact locked query model with the optional validated
    /// language value and repeated validated keyterm values.
    static func listenURL(language: String?, keyterms: [String]) throws -> URL {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "api.deepgram.com"
        components.path = "/v1/listen"

        var items: [URLQueryItem] = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "endpointing", value: "300"),
            URLQueryItem(name: "utterance_end_ms", value: "1000"),
            URLQueryItem(name: "vad_events", value: "true"),
            URLQueryItem(name: "smart_format", value: "true")
        ]

        if let language {
            let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
            guard supportedLanguages.contains(trimmed) else {
                throw DeepgramRequestError.unsupportedLanguage
            }
            items.append(URLQueryItem(name: "language", value: trimmed))
        }

        for keyterm in keyterms {
            let trimmed = keyterm.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard trimmed.count <= maxKeytermLength,
                  trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                throw DeepgramRequestError.invalidKeyterm
            }
            items.append(URLQueryItem(name: "keyterm", value: trimmed))
        }

        components.queryItems = items
        guard let url = components.url else {
            throw DeepgramRequestError.unsupportedLanguage
        }
        return url
    }

    /// Raw headerless linear16, 16-bit little-endian signed PCM at 16000 Hz,
    /// one channel. Only non-empty data aligned to two-byte samples may become
    /// a binary WebSocket frame.
    static func validatedAudioFrame(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count % 2 == 0 else { return nil }
        return data
    }

    // MARK: Streaming lifecycle

    /// Opens exactly one authenticated stream for this user-started recording.
    @discardableResult
    func beginStream(language: String? = nil, keyterms: [String] = []) async -> DeepgramStreamState {
        let url: URL
        do {
            url = try Self.listenURL(language: language, keyterms: keyterms)
        } catch {
            return await fail(.malformedConfiguration)
        }

        let credential = (try? await credentialVault.value(for: .deepgramNovaStreamingTranscription)) ?? nil
        guard let key = credential?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return await fail(.credentialUnavailable)
        }

        generation += 1
        let currentGeneration = generation
        state = .connecting
        lastFailure = nil
        interimTranscript = ""
        finalTranscript = ""
        lastUnknownMessageType = nil
        lastSpeechStartedTimestamp = nil
        lastUtteranceEndTimestamp = nil
        hasSentAudioFrame = false
        lastOutboundFrameAt = nil

        do {
            // Authorization: Token <request-local key>; never Bearer here.
            let connected = try await socketFactory.connect(url: url, authorization: "Token \(key)")
            guard generation == currentGeneration else {
                // Cancelled while connecting: discard the late socket.
                await connected.session.close()
                return state
            }
            socket = connected.session
            providerRequestID = connected.providerRequestID
            state = .streaming
            return state
        } catch let error as DeepgramSocketError {
            return await fail(Self.mapSocketError(error) ?? .transport)
        } catch {
            return await fail(.transport)
        }
    }

    /// Sends one validated audio frame. Returns whether it was transmitted.
    @discardableResult
    func sendAudio(_ pcm: Data) async -> Bool {
        guard case .streaming = state, let socket else { return false }
        guard let frame = Self.validatedAudioFrame(pcm) else { return false }
        do {
            try await socket.send(binary: frame)
        } catch {
            _ = await fail(.transport)
            return false
        }
        hasSentAudioFrame = true
        lastOutboundFrameAt = now()
        return true
    }

    /// Sends `{"type":"KeepAlive"}` every 4 seconds, only after at least one
    /// real audio frame and only while no audio frame is being sent.
    @discardableResult
    func keepAliveIfNeeded() async -> Bool {
        guard case .streaming = state, hasSentAudioFrame, let socket else { return false }
        let current = now()
        guard let last = lastOutboundFrameAt,
              current.timeIntervalSince(last) >= Self.keepAliveInterval else {
            return false
        }
        do {
            try await socket.send(text: Self.keepAliveFrame)
        } catch {
            _ = await fail(.transport)
            return false
        }
        lastOutboundFrameAt = current
        return true
    }

    /// User stop: send `{"type":"Finalize"}` and keep receiving final Results.
    func stopAndFinalize() async {
        guard case .streaming = state, let socket else { return }
        do {
            try await socket.send(text: Self.finalizeFrame)
            state = .finalizing
        } catch {
            _ = await fail(.transport)
        }
    }

    /// Drains available events. Continues until no frame is available, the
    /// session reaches a terminal state, or the socket reports a failure.
    func pump() async {
        while true {
            guard let socket else { return }
            switch state {
            case .cancelled, .succeeded, .failed, .idle:
                return
            case .connecting, .streaming, .finalizing, .closing:
                break
            }

            let frame: DeepgramSocketFrame?
            do {
                frame = try await socket.receive()
            } catch DeepgramSocketError.pollIdle {
                return
            } catch let error as DeepgramSocketError {
                if let failure = Self.mapSocketError(error) {
                    _ = await fail(failure)
                } else {
                    // Normal server close finishes the session with whatever
                    // final text was accepted.
                    await completeSession()
                }
                return
            } catch {
                _ = await fail(.transport)
                return
            }

            guard let frame else {
                switch state {
                case .finalizing, .closing:
                    // No further frames: finish honestly with what we have.
                    await completeSession()
                default:
                    break
                }
                return
            }

            await handle(frame: frame)
        }
    }

    /// Cancellation: invalidate the generation before cancelling the socket,
    /// stop audio and KeepAlive sends, and discard every late event.
    func cancel() async {
        generation += 1
        state = .cancelled
        interimTranscript = ""
        finalTranscript = ""
        if let socket {
            await socket.close()
            self.socket = nil
        }
    }

    // MARK: Test connection

    /// Verifies the authenticated endpoint without touching the microphone or
    /// any temporary recording: load configured-or-missing credential state,
    /// open the same endpoint, send CloseStream immediately, accept Metadata
    /// with zero duration, and close. No binary frame is ever sent.
    func testConnection() async -> DeepgramConnectionTestResult {
        let status = await credentialVault.status(for: .deepgramNovaStreamingTranscription)
        switch status {
        case .missing:
            return .missingCredential
        case .unavailable:
            return .failed(.credentialUnavailable)
        case .configured:
            break
        }

        guard let key = (try? await credentialVault.value(for: .deepgramNovaStreamingTranscription)) ?? nil,
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .missingCredential
        }

        let url: URL
        do {
            url = try Self.listenURL(language: nil, keyterms: [])
        } catch {
            return .failed(.malformedConfiguration)
        }

        do {
            let connected = try await socketFactory.connect(url: url, authorization: "Token \(key)")
            let session = connected.session
            var requestID = connected.providerRequestID
            try await session.send(text: Self.closeStreamFrame)
            let deadline = ContinuousClock.now.advanced(by: .seconds(8))
            var finished = false
            while ContinuousClock.now < deadline {
                let frame: DeepgramSocketFrame?
                do {
                    frame = try await session.receive()
                } catch DeepgramSocketError.pollIdle {
                    continue
                }
                guard let frame else {
                    finished = true
                    break
                }
                guard case .text(let text) = frame,
                      let data = text.data(using: .utf8),
                      let event = try? DeepgramStreamEvent.decode(from: data) else {
                    continue
                }
                if case .metadata(let summary) = event {
                    requestID = summary.requestID ?? requestID
                    finished = true
                    break
                }
            }
            await session.close()
            guard finished else { return .failed(.timedOut) }
            return .succeeded(requestID: requestID)
        } catch let error as DeepgramSocketError {
            return .failed(Self.mapSocketError(error) ?? .transport)
        } catch {
            return .failed(.transport)
        }
    }

    // MARK: Event handling

    private func handle(frame: DeepgramSocketFrame) async {
        guard !isCancelled else { return }
        switch frame {
        case .binary:
            // The streaming contract sends audio; the server never needs to
            // send binary frames back.
            break
        case .text(let text):
            guard let data = text.data(using: .utf8) else {
                _ = await fail(.malformedMessage)
                return
            }
            let event: DeepgramStreamEvent
            do {
                event = try DeepgramStreamEvent.decode(from: data)
            } catch {
                _ = await fail(.malformedMessage)
                return
            }
            await handle(event: event)
        }
    }

    private func handle(event: DeepgramStreamEvent) async {
        guard !isCancelled else { return }
        switch event {
        case .results(let message):
            let transcript = message.channel.alternatives.first?.transcript ?? ""
            let isFinal = message.isFinal ?? false
            if isFinal {
                if !transcript.isEmpty {
                    // Append every non-empty final segment exactly once, in
                    // channel order. Interim results never land here.
                    finalTranscript = finalTranscript.isEmpty
                        ? transcript
                        : finalTranscript + " " + transcript
                }
            } else if !transcript.isEmpty {
                // Interim results may update the HUD only; they are never
                // insertion or persistence candidates.
                interimTranscript = transcript
            }

            // Finalization boundary: send CloseStream once the provider marks
            // the final boundary. from_finalize is optional, so speech_final
            // also counts when the provider supplies it.
            if case .finalizing = state {
                let reachedBoundary = (message.fromFinalize ?? false) || (message.speechFinal ?? false)
                if reachedBoundary, let socket {
                    do {
                        try await socket.send(text: Self.closeStreamFrame)
                        state = .closing
                    } catch {
                        _ = await fail(.transport)
                    }
                }
            }

        case .speechStarted(let message):
            // Visible recording state only; never replaces final accumulation.
            lastSpeechStartedTimestamp = message.timestamp

        case .utteranceEnd(let message):
            lastUtteranceEndTimestamp = message.lastWordEnd

        case .metadata(let summary):
            providerRequestID = summary.requestID ?? providerRequestID
            switch state {
            case .finalizing, .closing:
                await completeSession()
            default:
                break
            }

        case .unknown(let type):
            lastUnknownMessageType = type
            _ = await fail(.malformedMessage)
        }
    }

    // MARK: Termination of a session

    private var isCancelled: Bool {
        if case .cancelled = state { return true }
        return false
    }

    private func completeSession() async {
        guard !isCancelled else { return }
        let text = finalTranscript
        if text.isEmpty {
            state = .failed(.emptyFinalOutput)
            lastFailure = .emptyFinalOutput
        } else {
            state = .succeeded(finalText: text)
        }
        if let socket {
            await socket.close()
            self.socket = nil
        }
    }

    @discardableResult
    private func fail(_ failure: DeepgramStreamFailure) async -> DeepgramStreamState {
        guard !isCancelled else { return state }
        state = .failed(failure)
        lastFailure = failure
        if let socket {
            await socket.close()
            self.socket = nil
        }
        return state
    }

    /// Maps privacy-safe socket failures. Returns nil for a normal close,
    /// which finishes the session instead of failing it.
    static func mapSocketError(_ error: DeepgramSocketError) -> DeepgramStreamFailure? {
        switch error {
        case .upgradeFailed(let status):
            switch status {
            case 400: return .malformedConfiguration
            case 401: return .authentication
            case 403: return .permission
            case 429: return .rateLimited
            default: return .providerFailure(status: status)
            }
        case .transport:
            return .transport
        case .timedOut:
            return .timedOut
        case .pollIdle:
            return nil
        case .closed(let code, let reason):
            if reason.contains("DATA-0000") { return .malformedAudio }
            if reason.contains("NET-0000") { return .insufficientAudioTimeout }
            if reason.contains("NET-0001") { return .frameTimeout }
            if reason.contains("NET-0002") { return .noAudioTimeout }
            if code == 1000 || code == 1005 { return nil }
            // Deepgram signals the malformed-or-mismatched-audio class with
            // close code 1008 (DATA-0000): the code itself is authoritative
            // when the close reason is absent or does not repeat the
            // data-error identifier, and audio in that class is never retained
            // for an automatic or paid retry.
            if code == 1008 { return .malformedAudio }
            return .transport
        }
    }
}
