import AVFoundation
import Foundation

// MARK: - Imported audio inspection

struct ImportedAudioFile: Equatable, Sendable {
    let url: URL
    let format: String
    let sizeBytes: Int
    let durationSeconds: Double
}

enum ImportedAudioInspectionError: Error, Equatable, Sendable {
    case unreadable
}

/// Local preflight seam: extension, media duration, and file size are read
/// before any audio byte, base64 encoding, URLRequest, or URLSessionTask is
/// created.
protocol ImportedAudioInspecting: Sendable {
    func inspect(url: URL) async throws -> ImportedAudioFile
}

/// Reads the finalized audio input only after the local preflight passed.
protocol AudioFileReading: Sendable {
    func readBytes(at url: URL) throws -> Data
}

struct AVFoundationAudioFileInspector: ImportedAudioInspecting {
    func inspect(url: URL) async throws -> ImportedAudioFile {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw ImportedAudioInspectionError.unreadable
        }
        guard let size = attributes[.size] as? Int else {
            throw ImportedAudioInspectionError.unreadable
        }
        let asset = AVURLAsset(url: url)
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            throw ImportedAudioInspectionError.unreadable
        }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds >= 0 else {
            throw ImportedAudioInspectionError.unreadable
        }
        return ImportedAudioFile(
            url: url,
            format: url.pathExtension.lowercased(),
            sizeBytes: size,
            durationSeconds: seconds
        )
    }
}

struct FileSystemAudioFileReader: AudioFileReading {
    func readBytes(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }
}

// MARK: - Batch transcription DTOs

struct OpenRouterAudioInput: Codable, Equatable, Sendable {
    let data: String
    let format: String
}

struct OpenRouterProviderRouting: Codable, Equatable, Sendable {
    let order: [String]
}

struct OpenRouterTranscriptionRequestBody: Codable, Equatable, Sendable {
    let model: String
    let inputAudio: OpenRouterAudioInput
    let language: String?
    let temperature: Double
    let provider: OpenRouterProviderRouting?

    enum CodingKeys: String, CodingKey {
        case model
        case inputAudio = "input_audio"
        case language
        case temperature
        case provider
    }
}

struct OpenRouterTranscriptionUsage: Codable, Equatable, Sendable {
    let seconds: Double?
    let totalTokens: Int?
    let inputTokens: Int?
    let outputTokens: Int?
    let cost: Double?

    enum CodingKeys: String, CodingKey {
        case seconds
        case totalTokens = "total_tokens"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cost
    }
}

struct OpenRouterTranscriptionResponseBody: Codable, Equatable, Sendable {
    let text: String?
    let model: String?
    let id: String?
    let usage: OpenRouterTranscriptionUsage?
}

// MARK: - Batch failures and states

/// Distinct privacy-safe batch-transcription failures. None carries raw
/// provider content, and none may create history, insertion, or persistence.
enum BatchTranscriptionFailure: Equatable, Sendable {
    case unsupportedFormat
    case fileTooLarge
    case durationTooLong
    case fileUnreadable
    case invalidRequest
    case missingCredential
    case inFlight
    case unauthenticated
    case creditsExhausted
    case permission
    case requestTimeout
    case payloadTooLarge
    case rateLimited
    case providerFailure(status: Int)
    case timedOut
    case malformedResponse
    case emptyOutput
    case transport
    case cancelled

    var allowsExplicitRetry: Bool {
        switch self {
        case .cancelled, .inFlight, .unsupportedFormat, .fileTooLarge, .durationTooLong, .missingCredential, .invalidRequest:
            return false
        default:
            return true
        }
    }

    var userFacingMessage: String {
        switch self {
        case .unsupportedFormat:
            return "That file type is not supported. Import one of wav, mp3, flac, m4a, ogg, webm, or aac."
        case .fileTooLarge:
            return "That file is larger than the 25 MB limit for one transcription."
        case .durationTooLong:
            return "That file is longer than the 60-second limit for one transcription."
        case .fileUnreadable:
            return "The selected audio file could not be read."
        case .invalidRequest:
            return "The transcription request parameters were rejected locally."
        case .missingCredential:
            return "Add an OpenRouter API key in Settings before transcribing files."
        case .inFlight:
            return "A transcription is already running for this recording."
        case .unauthenticated:
            return "OpenRouter rejected the stored API key. Replace it in Settings and retry."
        case .creditsExhausted:
            return "OpenRouter reported insufficient credits. Top up and retry explicitly."
        case .permission:
            return "OpenRouter denied this request for the account."
        case .requestTimeout:
            return "OpenRouter took too long to answer."
        case .payloadTooLarge:
            return "OpenRouter rejected the upload as too large."
        case .rateLimited:
            return "OpenRouter is rate limiting this account. Wait and retry explicitly."
        case .providerFailure:
            return "OpenRouter reported a provider failure. Retry explicitly."
        case .timedOut:
            return "The transcription request timed out. No transcript was produced."
        case .malformedResponse:
            return "OpenRouter returned an unreadable response. No transcript was produced."
        case .emptyOutput:
            return "OpenRouter returned no transcript text for this file."
        case .transport:
            return "The request could not reach OpenRouter. Check the network and retry."
        case .cancelled:
            return "Transcription was cancelled. No partial text was kept."
        }
    }
}

enum BatchTranscriptionState: Equatable, Sendable {
    case idle
    case active
    case succeeded(text: String)
    case failed(BatchTranscriptionFailure)
    case cancelled
}

enum BatchTranscriptionResult: Equatable, Sendable {
    case transcribed(String)
    case failed(BatchTranscriptionFailure)
}

// MARK: - OpenrouterTranscriptionIntegration

/// OWN-INTEGRATION-OPENROUTER-TRANSCRIPTION.
///
/// Owns CON-INTEGRATION-OPENROUTER-TRANSCRIPTION: finalized imported-audio
/// batch transcription through
/// `POST https://openrouter.ai/api/v1/audio/transcriptions` with the default
/// `openai/gpt-4o-transcribe` model. This is never live transcription: it
/// produces no partial results, performs a local preflight before any paid
/// upload, decodes provider usage, honors rate limits explicitly, and never
/// yields partial, cancelled, failed, or empty text.
actor OpenrouterTranscriptionIntegration {

    static let endpoint = URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!
    static let defaultModel = "openai/gpt-4o-transcribe"
    static let requestTimeout: TimeInterval = 65
    static let supportedFormats: Set<String> = ["wav", "mp3", "flac", "m4a", "ogg", "webm", "aac"]
    static let maxDurationSeconds: Double = 60
    static let maxPayloadBytes: Int = 25_000_000

    // MARK: Observable state

    private(set) var state: BatchTranscriptionState = .idle
    private(set) var lastFailure: BatchTranscriptionFailure?
    private(set) var lastTranscribedText: String?
    private(set) var lastUsage: OpenRouterTranscriptionUsage?
    private(set) var lastReportedCost: Double?
    private(set) var lastGenerationID: String?
    private(set) var lastRateLimitInfo: OpenRouterRateLimitInfo?

    // MARK: Dependencies

    private let credentialVault: CredentialVault
    private let transport: any HTTPTransporting
    private let inspector: any ImportedAudioInspecting
    private let reader: any AudioFileReading

    private var activeTask: Task<HTTPResponse, any Error>?
    private var operationGeneration = 0

    init(
        credentialVault: CredentialVault = CredentialVault(),
        transport: any HTTPTransporting = URLSessionHTTPTransport(),
        inspector: any ImportedAudioInspecting = AVFoundationAudioFileInspector(),
        reader: any AudioFileReading = FileSystemAudioFileReader()
    ) {
        self.credentialVault = credentialVault
        self.transport = transport
        self.inspector = inspector
        self.reader = reader
    }

    // MARK: Preflight

    /// Local validation before any paid upload. Unsupported files and files
    /// exceeding 60 seconds or 25,000,000 bytes create no provider request and
    /// release their local inspection resources.
    static func preflightFailure(for file: ImportedAudioFile) -> BatchTranscriptionFailure? {
        guard supportedFormats.contains(file.format) else { return .unsupportedFormat }
        guard file.sizeBytes <= maxPayloadBytes else { return .fileTooLarge }
        guard file.durationSeconds <= maxDurationSeconds else { return .durationTooLong }
        return nil
    }

    /// One optional ISO-639-1 language value.
    static func isValidLanguage(_ language: String) -> Bool {
        language.count == 2 && language.allSatisfy { $0.isLowercase && $0.isLetter }
    }

    // MARK: Transcription

    /// Transcribes one finalized imported audio file. The audio input is used
    /// only for this request; nothing is split, chunked, transcoded, or
    /// stitched, and no automatic paid fallback follows a failure.
    func transcribeFile(
        at url: URL,
        language: String?,
        providerOrder: [String]?
    ) async -> BatchTranscriptionResult {
        switch state {
        case .active:
            // One in-flight request per recording and role.
            return .failed(.inFlight)
        default:
            break
        }

        // Preflight the file locally before reading bytes or building a request.
        let inspected: ImportedAudioFile
        do {
            inspected = try await inspector.inspect(url: url)
        } catch {
            return finish(.failed(.fileUnreadable))
        }
        if let failure = Self.preflightFailure(for: inspected) {
            return finish(.failed(failure))
        }

        if let language, !Self.isValidLanguage(language) {
            return finish(.failed(.invalidRequest))
        }
        var providerRouting: OpenRouterProviderRouting?
        if let providerOrder {
            let trimmed = providerOrder.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !trimmed.isEmpty, trimmed.allSatisfy({ !$0.isEmpty }) else {
                return finish(.failed(.invalidRequest))
            }
            // Provider routing is sent only when the user explicitly configured it.
            providerRouting = OpenRouterProviderRouting(order: trimmed)
        }

        let credential = (try? await credentialVault.value(for: .openRouter)) ?? nil
        guard let key = credential?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return finish(.failed(.missingCredential))
        }

        // Only now read the raw audio bytes and encode them as ordinary
        // base64 (never a data URI).
        let rawBytes: Data
        do {
            rawBytes = try reader.readBytes(at: inspected.url)
        } catch {
            return finish(.failed(.fileUnreadable))
        }
        guard rawBytes.count <= Self.maxPayloadBytes else {
            return finish(.failed(.fileTooLarge))
        }

        let body: Data
        do {
            body = try JSONEncoder().encode(
                OpenRouterTranscriptionRequestBody(
                    model: Self.defaultModel,
                    inputAudio: OpenRouterAudioInput(
                        data: rawBytes.base64EncodedString(),
                        format: inspected.format
                    ),
                    language: language,
                    temperature: 0.0,
                    provider: providerRouting
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

        // Late responses are discarded: cancellation invalidated this generation.
        guard generation == operationGeneration else {
            return .failed(.cancelled)
        }

        return process(response)
    }

    /// Explicit cancellation: invalidate the generation first, cancel the
    /// retained task, and discard every late response. No recoverable audio is
    /// deleted prematurely here.
    func cancelTranscription() {
        operationGeneration += 1
        activeTask?.cancel()
        activeTask = nil
        if state == .active {
            state = .cancelled
        }
    }

    // MARK: Response processing

    private func process(_ response: HTTPResponse) -> BatchTranscriptionResult {
        let status = response.statusCode
        if status == 429 {
            lastRateLimitInfo = OpenRouterRateLimitInfo.decode(from: response)
            return finish(.failed(.rateLimited))
        }
        guard status == 200 else {
            _ = OpenRouterErrorEnvelope.decode(from: response.body)
            return finish(.failed(Self.mapStatus(status)))
        }

        // A top-level error envelope inside HTTP 200 is a failure, not output.
        if let envelope = OpenRouterErrorEnvelope.decode(from: response.body),
           envelope.error.code != nil || envelope.error.message != nil {
            return finish(.failed(Self.mapStatus(envelope.error.code ?? 500)))
        }

        guard let decoded = try? JSONDecoder().decode(OpenRouterTranscriptionResponseBody.self, from: response.body) else {
            return finish(.failed(.malformedResponse))
        }
        guard let text = decoded.text else {
            return finish(.failed(.malformedResponse))
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return finish(.failed(.emptyOutput))
        }

        // Request correlation without transcript content.
        lastGenerationID = response.headerValue("X-Generation-Id")
        lastUsage = decoded.usage
        // The provider-returned cost is authoritative; never estimated.
        lastReportedCost = decoded.usage?.cost
        lastTranscribedText = text
        state = .succeeded(text: text)
        lastFailure = nil
        return .transcribed(text)
    }

    static func mapStatus(_ status: Int) -> BatchTranscriptionFailure {
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
    private func finish(_ result: BatchTranscriptionResult) -> BatchTranscriptionResult {
        switch result {
        case .transcribed:
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
