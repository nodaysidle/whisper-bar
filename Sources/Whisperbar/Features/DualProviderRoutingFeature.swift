import Foundation

// MARK: - Routes

/// The two explicitly selectable transcription routes of FEAT-DUAL-PROVIDER-ROUTING.
enum TranscriptionRoute: Equatable, Sendable {
    case deepgramStreaming
    case openRouterBatch

    init(provider: TranscriptionProviderID) {
        switch provider {
        case .deepgramStreaming: self = .deepgramStreaming
        case .openRouterBatch: self = .openRouterBatch
        }
    }

    var provider: TranscriptionProviderID {
        switch self {
        case .deepgramStreaming: return .deepgramStreaming
        case .openRouterBatch: return .openRouterBatch
        }
    }
}

// MARK: - DualProviderRoutingFeature

/// OWN-DUAL-PROVIDER-ROUTING.
///
/// Owns CON-DUAL-PROVIDER-ROUTING-INTERFACE and
/// CON-DUAL-PROVIDER-ROUTING-RECOVERY: each session is routed to Deepgram for
/// live WebSocket streaming with interim results and automatic finalization, or
/// to OpenRouter for finalized audio batch transcription with optional
/// text refinement, exactly according to the explicitly selected provider
/// (CON-DATA-PROVIDER-PREFERENCE). The selected provider is never switched
/// automatically: a provider failure is a distinct privacy-safe terminal state,
/// no fallback request follows it, the last valid state is preserved, and
/// recovery is an explicit user retry or an explicit provider switch.
///
/// The feature owns no credentials and no network boundary of its own; the
/// shared integration actors own Keychain reads and the URLSession boundary.
@MainActor
final class DualProviderRoutingFeature: TerminationReleasing {

    // MARK: States

    enum State: Equatable, Sendable {
        case idle
        case active(TranscriptionProviderID)
        case succeeded(Outcome)
        case failed(Failure)
        case cancelled
    }

    /// The result of one completed route. `refinement` reports whether the
    /// optional refinement role ran and what the provider returned.
    struct Outcome: Equatable, Sendable {
        let provider: TranscriptionProviderID
        let rawTranscript: String
        let refinement: RefinementOutcome

        /// Exactly one complete insertion candidate: the accepted refined text
        /// when refinement succeeded, otherwise the accepted final raw
        /// transcript. Partial, empty, failed, or cancelled text never lands
        /// here because those paths never produce an outcome.
        var candidateText: String? {
            switch refinement {
            case .applied(let text):
                return text.isEmpty ? nil : text
            case .notConfigured, .failed:
                let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : rawTranscript
            }
        }
    }

    enum RefinementOutcome: Equatable, Sendable {
        case notConfigured
        case applied(text: String)
        case failed(RefinementFailure)
    }

    struct Failure: Equatable, Sendable {
        enum Category: Equatable, Sendable {
            case providerNotSelected
            case providerMismatch(expected: TranscriptionProviderID)
            case inFlight
            case streaming(DeepgramStreamFailure)
            case batch(BatchTranscriptionFailure)
        }

        let category: Category
        let message: String
    }

    // MARK: Observable state

    private(set) var state: State = .idle
    /// The explicitly selected provider, mirroring CON-DATA-PROVIDER-PREFERENCE.
    private(set) var selectedProvider: TranscriptionProviderID?
    /// Interim streaming text for presentation only; never a candidate.
    private(set) var interimTranscript: String = ""
    private(set) var lastFailure: Failure?
    private(set) var lastOutcome: Outcome?
    /// Retained audio is permitted only while awaiting an explicit retry or
    /// explicit provider switch after a recoverable provider failure.
    private(set) var retainsTemporaryAudioForExplicitRecovery = false

    /// The one complete insertion candidate of the last successful route.
    var completedCandidateText: String? { lastOutcome?.candidateText }

    /// The route of the last explicit operation, used by explicit retries only.
    private(set) var lastRoute: TranscriptionRoute?

    // MARK: Dependencies

    private let dataStore: DataStore
    private let deepgramIntegration: DeepgramNovaStreamingTranscriptionIntegration
    private let refinementIntegration: OpenrouterRefinementIntegration
    private let batchIntegration: OpenrouterTranscriptionIntegration

    private var lastStreamingRequest: (language: String?, keyterms: [String])?
    private var lastBatchRequest: (url: URL, language: String?, providerOrder: [String]?)?

    init(
        dataStore: DataStore,
        deepgramIntegration: DeepgramNovaStreamingTranscriptionIntegration,
        refinementIntegration: OpenrouterRefinementIntegration,
        batchIntegration: OpenrouterTranscriptionIntegration
    ) {
        self.dataStore = dataStore
        self.deepgramIntegration = deepgramIntegration
        self.refinementIntegration = refinementIntegration
        self.batchIntegration = batchIntegration
    }

    // MARK: Provider selection (CON-DATA-PROVIDER-PREFERENCE)

    /// Restores the stored, explicitly selected provider. Preset-owned state
    /// only: no capture and no provider request starts here.
    func loadProviderPreference() async {
        selectedProvider = await dataStore.providerPreference()
    }

    /// Explicit user selection; `nil` clears the selection. The choice is
    /// persisted before it is returned, and an active session is never
    /// re-routed.
    @discardableResult
    func selectProvider(_ provider: TranscriptionProviderID?) async -> Bool {
        guard !isActive else { return false }
        await dataStore.setProviderPreference(provider)
        selectedProvider = provider
        return true
    }

    // MARK: Live streaming route (Deepgram)

    /// Opens exactly one live Deepgram stream for this user-started recording.
    /// The route requires the explicitly selected `deepgramStreaming` provider;
    /// any other selection is rejected before a socket is opened.
    @discardableResult
    func startLiveStreaming(language: String? = nil, keyterms: [String] = []) async -> Bool {
        guard let provider = selectedProvider else {
            fail(.providerNotSelected)
            return false
        }
        guard TranscriptionRoute(provider: provider) == .deepgramStreaming else {
            fail(.providerMismatch(expected: .deepgramStreaming))
            return false
        }
        guard !isActive else {
            // A duplicate start is rejected without touching the active
            // session: the last valid state is preserved.
            lastFailure = Failure(category: Failure.Category.inFlight, message: Self.message(for: Failure.Category.inFlight))
            return false
        }

        lastRoute = .deepgramStreaming
        lastStreamingRequest = (language, keyterms)
        interimTranscript = ""
        lastFailure = nil
        retainsTemporaryAudioForExplicitRecovery = false
        state = .active(.deepgramStreaming)

        let streamState = await deepgramIntegration.beginStream(language: language, keyterms: keyterms)
        switch streamState {
        case .streaming, .connecting:
            return true
        case .failed(let failure):
            applyStreamingFailure(failure)
            return false
        default:
            return false
        }
    }

    /// Forwards one validated audio frame. Returns whether it was transmitted.
    @discardableResult
    func sendAudio(_ pcm: Data) async -> Bool {
        guard case .active(.deepgramStreaming) = state else { return false }
        return await deepgramIntegration.sendAudio(pcm)
    }

    /// Sends KeepAlive only while a live stream is idle within its window.
    @discardableResult
    func keepAliveIfNeeded() async -> Bool {
        guard case .active(.deepgramStreaming) = state else { return false }
        return await deepgramIntegration.keepAliveIfNeeded()
    }

    /// User stop: finalize the live stream. The provider marks the final
    /// boundary and the integration sends CloseStream automatically.
    func stopAndFinalize() async {
        guard case .active(.deepgramStreaming) = state else { return }
        await deepgramIntegration.stopAndFinalize()
    }

    /// Drains available streaming events. Interim results update the exposed
    /// interim text only; failures map to the routing failure state.
    func pump() async {
        guard case .active(.deepgramStreaming) = state else { return }
        await deepgramIntegration.pump()
        interimTranscript = await deepgramIntegration.interimTranscript
        switch await deepgramIntegration.state {
        case .failed(let failure):
            applyStreamingFailure(failure)
        case .cancelled:
            interimTranscript = ""
            state = .cancelled
        default:
            break
        }
    }

    /// Completes one live streaming session. An outcome exists only when the
    /// provider produced a non-empty final transcript; refinement runs only
    /// when the refinement role is explicitly configured.
    @discardableResult
    func completeLiveStream(modeName: String? = nil, modeInstructions: String? = nil) async -> Outcome? {
        guard case .active(.deepgramStreaming) = state else { return nil }
        await pump()

        switch await deepgramIntegration.state {
        case .succeeded(let finalText):
            let outcome = Outcome(
                provider: .deepgramStreaming,
                rawTranscript: finalText,
                refinement: await refineIfConfigured(
                    rawTranscript: finalText,
                    modeName: modeName,
                    modeInstructions: modeInstructions
                )
            )
            lastOutcome = outcome
            interimTranscript = ""
            lastFailure = nil
            retainsTemporaryAudioForExplicitRecovery = false
            state = .succeeded(outcome)
            return outcome
        case .failed(let failure):
            applyStreamingFailure(failure)
            return nil
        case .cancelled:
            interimTranscript = ""
            state = .cancelled
            return nil
        default:
            // Still in progress: no outcome exists yet.
            return nil
        }
    }

    // MARK: Batch route (OpenRouter)

    /// Transcribes one finalized imported audio input. The route requires the
    /// explicitly selected `openRouterBatch` provider; any other selection is
    /// rejected before local inspection or any paid request.
    @discardableResult
    func transcribeImportedFile(
        at url: URL,
        language: String? = nil,
        providerOrder: [String]? = nil,
        modeName: String? = nil,
        modeInstructions: String? = nil
    ) async -> Outcome? {
        guard let provider = selectedProvider else {
            fail(.providerNotSelected)
            return nil
        }
        guard TranscriptionRoute(provider: provider) == .openRouterBatch else {
            fail(.providerMismatch(expected: .openRouterBatch))
            return nil
        }
        guard !isActive else {
            // A duplicate start is rejected without touching the active
            // session: the last valid state is preserved.
            lastFailure = Failure(category: Failure.Category.inFlight, message: Self.message(for: Failure.Category.inFlight))
            return nil
        }

        lastRoute = .openRouterBatch
        lastBatchRequest = (url, language, providerOrder)
        interimTranscript = ""
        lastFailure = nil
        retainsTemporaryAudioForExplicitRecovery = false
        state = .active(.openRouterBatch)

        let result = await batchIntegration.transcribeFile(at: url, language: language, providerOrder: providerOrder)
        switch result {
        case .transcribed(let text):
            let outcome = Outcome(
                provider: .openRouterBatch,
                rawTranscript: text,
                refinement: await refineIfConfigured(
                    rawTranscript: text,
                    modeName: modeName,
                    modeInstructions: modeInstructions
                )
            )
            lastOutcome = outcome
            lastFailure = nil
            state = .succeeded(outcome)
            return outcome
        case .failed(let failure):
            applyBatchFailure(failure)
            return nil
        }
    }

    // MARK: Cancellation and explicit retry

    /// Explicit cancellation: invalidate the active route and discard every
    /// late result. Nothing is persisted or inserted for a cancelled session.
    func cancelCurrentOperation() async {
        switch state {
        case .active(.deepgramStreaming):
            await deepgramIntegration.cancel()
        case .active(.openRouterBatch):
            await batchIntegration.cancelTranscription()
        default:
            return
        }
        interimTranscript = ""
        retainsTemporaryAudioForExplicitRecovery = false
        state = .cancelled
    }

    /// Explicit user retry of the last routed operation. It re-runs the same
    /// route once; it never switches providers automatically.
    @discardableResult
    func retryLastOperation() async -> Bool {
        guard !isActive else { return false }
        switch lastRoute {
        case .deepgramStreaming:
            let request = lastStreamingRequest ?? (language: nil, keyterms: [])
            return await startLiveStreaming(language: request.language, keyterms: request.keyterms)
        case .openRouterBatch:
            guard let request = lastBatchRequest else { return false }
            let outcome = await transcribeImportedFile(
                at: request.url,
                language: request.language,
                providerOrder: request.providerOrder
            )
            return outcome != nil
        case nil:
            return false
        }
    }

    // MARK: Termination

    /// CON-LIFECYCLE-APPLICATION-TERMINATION: cancel the active route and
    /// close its stream so nothing outlives the process.
    func releaseForTermination() async {
        if case .active(.deepgramStreaming) = state {
            await deepgramIntegration.cancel()
        }
        if case .active(.openRouterBatch) = state {
            await batchIntegration.cancelTranscription()
        }
        interimTranscript = ""
        retainsTemporaryAudioForExplicitRecovery = false
        state = .idle
    }

    // MARK: Refinement (only when configured)

    /// Optional refinement applies only when the refinement role was
    /// explicitly enabled. A failure never replaces, hides, or deletes the
    /// accepted raw transcript.
    private func refineIfConfigured(
        rawTranscript: String,
        modeName: String?,
        modeInstructions: String?
    ) async -> RefinementOutcome {
        guard await refinementIntegration.isEnabled else { return .notConfigured }
        let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .notConfigured }
        let result = await refinementIntegration.refine(
            rawTranscript: rawTranscript,
            modeName: modeName,
            modeInstructions: modeInstructions
        )
        switch result {
        case .refined(let text):
            return .applied(text: text)
        case .failed(let failure):
            return .failed(failure)
        }
    }

    // MARK: Failure bookkeeping

    /// True while a route is active. The composition root reads this for its
    /// selection transaction, so a selection change can be recognized as
    /// rejected by this owner instead of being silently half-applied.
    var isActive: Bool {
        if case .active = state { return true }
        return false
    }

    private func applyStreamingFailure(_ failure: DeepgramStreamFailure) {
        let routingFailure = Failure(category: .streaming(failure), message: Self.message(for: failure))
        lastFailure = routingFailure
        interimTranscript = ""
        retainsTemporaryAudioForExplicitRecovery = failure.isRecoverableProviderFailure
        state = .failed(routingFailure)
    }

    private func applyBatchFailure(_ failure: BatchTranscriptionFailure) {
        let routingFailure = Failure(category: .batch(failure), message: Self.message(for: failure))
        lastFailure = routingFailure
        retainsTemporaryAudioForExplicitRecovery = false
        state = .failed(routingFailure)
    }

    @discardableResult
    private func fail(_ category: Failure.Category) -> Failure {
        let routingFailure = Failure(category: category, message: Self.message(for: category))
        lastFailure = routingFailure
        retainsTemporaryAudioForExplicitRecovery = false
        state = .failed(routingFailure)
        return routingFailure
    }

    // MARK: Privacy-safe messages

    private static func message(for failure: DeepgramStreamFailure) -> String {
        failure.userFacingMessage + " No automatic fallback or retry occurs; retry or cancel explicitly."
    }

    private static func message(for failure: BatchTranscriptionFailure) -> String {
        failure.userFacingMessage + " No automatic fallback or retry occurs; retry or cancel explicitly."
    }

    private static func message(for category: Failure.Category) -> String {
        switch category {
        case .providerNotSelected:
            return "Select a transcription provider before recording. No request was made and no recording started."
        case .providerMismatch(let expected):
            return "That route does not match the selected provider. Select the \(expected.displayName) provider explicitly and retry; no automatic provider switch occurs."
        case .inFlight:
            return "A transcription is already running. Stop or cancel it explicitly before starting another."
        case .streaming(let failure):
            return message(for: failure)
        case .batch(let failure):
            return message(for: failure)
        }
    }
}
