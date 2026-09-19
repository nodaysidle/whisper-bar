import Foundation

// MARK: - Paid request vocabulary

/// The origin of one paid provider request.
///
/// Cost-related actions are explicit (ACC-PROVIDER-SELECTION-AND-COST-PROTECTION-01):
/// only `explicitStart` and `explicitRetry` — both of which require a user
/// action — can ever be authorized. `automatic` exists so a would-be
/// automatic retry or paid fallback is always recognized and denied; no
/// production flow constructs it, and it is denied before any other state or
/// seam is touched.
enum PaidRequestOrigin: Equatable, Sendable {
    case explicitStart
    case explicitRetry
    case automatic
}

// MARK: - Authoritative provider usage

/// One usage report exactly as a paid provider returned it.
///
/// Every field is a value the provider itself reported; the feature never
/// computes, estimates, or infers monetary usage and holds no local price
/// table. `providerReportedCostUSD == nil` means the provider returned no
/// monetary usage (for example the streaming socket has no documented usage
/// object) and the cost is marked unavailable rather than invented.
struct ProviderReportedUsage: Equatable, Sendable {

    let provider: TranscriptionProviderID
    /// Provider correlation id (for example a Deepgram request id or an
    /// OpenRouter generation id); request evidence only, never transcript
    /// content.
    let requestReference: String?
    /// Provider-reported duration when the provider returns one.
    let providerReportedDurationSeconds: Double?
    let inputTokens: Int?
    let outputTokens: Int?
    let totalTokens: Int?
    /// Provider-reported monetary cost; the authoritative value.
    let providerReportedCostUSD: Decimal?
}

/// The authoritative usage/cost display for the last completed paid request.
///
/// `costText` reproduces the provider-reported value exactly or states that
/// cost is unavailable; a number is never invented client-side.
struct ProviderUsageDisplay: Equatable, Sendable {

    let provider: TranscriptionProviderID
    let requestReference: String?
    let providerReportedDurationSeconds: Double?
    let totalTokens: Int?
    let providerReportedCostUSD: Decimal?

    /// True only when the provider returned an authoritative monetary cost.
    var isCostAuthoritative: Bool { providerReportedCostUSD != nil }

    /// Deterministic display text. The unavailable wording is fixed so a
    /// missing monetary field can never render as a computed number.
    var costText: String {
        guard let cost = providerReportedCostUSD else {
            return "Cost unavailable — the provider did not report monetary usage."
        }
        return "Provider-reported cost: US$\(NSDecimalNumber(decimal: cost).stringValue)"
    }

    init(usage: ProviderReportedUsage) {
        self.provider = usage.provider
        self.requestReference = usage.requestReference
        self.providerReportedDurationSeconds = usage.providerReportedDurationSeconds
        self.totalTokens = usage.totalTokens
        self.providerReportedCostUSD = usage.providerReportedCostUSD
    }
}

// MARK: - ProviderSelectionAndCostProtectionFeature

/// OWN-PROVIDER-SELECTION-AND-COST-PROTECTION.
///
/// Owns CON-PROVIDER-SELECTION-AND-COST-PROTECTION-INTERFACE and
/// CON-PROVIDER-SELECTION-AND-COST-PROTECTION-RECOVERY: recording stays
/// blocked until the user explicitly selects a provider, the explicit
/// selection is persisted through the injected preset-storage seam, the
/// selection can only change between recordings, and no automatic provider
/// switch, fallback, or paid retry ever exists. Provider usage and cost are
/// displayed exactly as the provider reported them — the feature holds no
/// price table and never estimates monetary usage.
///
/// Every operation is idle, active, succeeded, failed, or cancelled. A
/// blocked user-initiated attempt is represented as its own terminal failed
/// state; a rejection that must not disturb an active session or a non-user
/// automatic attempt records the failure without touching the last valid
/// state. Recovery is an explicit user retry or an explicit selection change
/// and nothing else — this feature has no timer, no retry loop, and no
/// fallback of its own.
///
/// All provider, credential, network, and persistence boundaries are
/// injected seams; the default seams are deliberately inert so construction
/// and launch touch no live provider, no Keychain item, and no TCC prompt.
@MainActor
final class ProviderSelectionAndCostProtectionFeature: TerminationReleasing {

    // MARK: States

    enum State: Equatable, Sendable {
        case idle
        case active(TranscriptionProviderID)
        case succeeded
        case failed(Failure)
        case cancelled
    }

    struct Failure: Equatable, Sendable {
        /// Privacy-safe categories: no case carries secret material,
        /// transcript content, or provider response bodies.
        enum Category: Equatable, Sendable {
            case providerNotSelected
            case providerMismatch(expected: TranscriptionProviderID)
            case selectionLockedWhileRecording
            case credentialMissing(TranscriptionProviderID)
            case networkDenied(TranscriptionProviderID)
            case inFlight
            case automaticPaidRequestForbidden
            case noActiveRequest
            case unexpectedUsageEvidence
            case paidRequestFailed(TranscriptionProviderID)
        }

        let category: Category
        let message: String
    }

    enum Decision: Equatable, Sendable {
        case allowed(TranscriptionProviderID)
        case blocked(Failure)
    }

    // MARK: Observable state

    private(set) var state: State = .idle
    /// The explicitly selected provider (CON-DATA-PROVIDER-PREFERENCE values
    /// read and written through the injected preset-storage seam). Only the
    /// explicit `selectProvider` path ever changes it; no failure, retry, or
    /// fallback switches it.
    private(set) var selectedProvider: TranscriptionProviderID?
    private(set) var lastFailure: Failure?
    private(set) var lastNotice: String?
    /// Authoritative usage/cost display for the last completed paid request.
    private(set) var lastUsageDisplay: ProviderUsageDisplay?

    /// True while no provider is explicitly selected: recording is blocked
    /// until the user selects one (ACC-PROVIDER-SELECTION-AND-COST-PROTECTION-03).
    var requiresProviderSelection: Bool { selectedProvider == nil }

    /// Exactly one paid request may be in flight for the active recording.
    var isPaidRequestActive: Bool {
        if case .active = state { return true }
        return false
    }

    /// True after a terminal failure or cancellation: the next paid request
    /// is an explicit recovery action, never an automatic one.
    var awaitingExplicitRecovery: Bool {
        switch state {
        case .failed, .cancelled: return true
        case .idle, .active, .succeeded: return false
        }
    }

    // MARK: Dependencies

    private let loadStoredSelection: @MainActor () async -> TranscriptionProviderID?
    private let storeSelection: @MainActor (TranscriptionProviderID?) async -> Void
    private let credentialAvailability: @MainActor (TranscriptionProviderID) async -> Bool
    private let networkAvailability: @MainActor () -> PermissionState
    private let requestNetworkAccess: @MainActor () async -> PermissionState

    init(
        loadStoredSelection: @escaping @MainActor () async -> TranscriptionProviderID? = { nil },
        storeSelection: @escaping @MainActor (TranscriptionProviderID?) async -> Void = { _ in },
        credentialAvailability: @escaping @MainActor (TranscriptionProviderID) async -> Bool = { _ in true },
        networkAvailability: @escaping @MainActor () -> PermissionState = { .authorized },
        requestNetworkAccess: @escaping @MainActor () async -> PermissionState = { .denied }
    ) {
        self.loadStoredSelection = loadStoredSelection
        self.storeSelection = storeSelection
        self.credentialAvailability = credentialAvailability
        self.networkAvailability = networkAvailability
        self.requestNetworkAccess = requestNetworkAccess
    }

    // MARK: Selection (CON-PROVIDER-SELECTION-AND-COST-PROTECTION-INTERFACE)

    /// Launch-time restore of the stored, explicitly selected provider.
    /// Preset-owned state only: no capture, no provider request, and no
    /// prompt happens here.
    func loadProviderSelection() async {
        guard !isPaidRequestActive else { return }
        selectedProvider = await loadStoredSelection()
    }

    /// The explicit provider toggle. `nil` clears the selection, which
    /// re-blocks recording until a new explicit choice exists.
    ///
    /// The choice is persisted before it is returned, and it can only change
    /// between recordings (ACC-PROVIDER-SELECTION-AND-COST-PROTECTION-04):
    /// while a paid request is active the selection is locked, nothing is
    /// persisted, and the active session is left untouched.
    @discardableResult
    func selectProvider(_ provider: TranscriptionProviderID?) async -> Bool {
        guard !isPaidRequestActive else {
            lastFailure = Failure(
                category: .selectionLockedWhileRecording,
                message: Self.message(for: .selectionLockedWhileRecording)
            )
            return false
        }
        await storeSelection(provider)
        selectedProvider = provider
        lastFailure = nil
        if let provider {
            lastNotice = "\(provider.displayName) is now the explicitly selected provider; it is never switched automatically."
        } else {
            lastNotice = "The provider selection was cleared; recording stays blocked until you select a provider explicitly."
        }
        return true
    }

    // MARK: The paid-request gate (ACC-01, ACC-02, ACC-03)

    /// The one gate every paid provider request passes, using the explicitly
    /// selected provider. Nothing in this feature calls it automatically:
    /// there is no timer, no retry loop, and no fallback. A `.blocked`
    /// decision made no provider request and incurred no cost.
    @discardableResult
    func requestPaidRecording(origin: PaidRequestOrigin) async -> Decision {
        await evaluateGate(intendedProvider: nil, origin: origin)
    }

    /// The explicit-provider variant: the caller states which provider the
    /// request would use, and a request for any provider other than the
    /// explicitly selected one is rejected without switching anything
    /// (ACC-PROVIDER-SELECTION-AND-COST-PROTECTION-02).
    @discardableResult
    func requestPaidRecording(
        for provider: TranscriptionProviderID,
        origin: PaidRequestOrigin
    ) async -> Decision {
        await evaluateGate(intendedProvider: provider, origin: origin)
    }

    /// The explicit user retry for the explicitly selected provider. This is
    /// the only recovery path after a blocked or failed paid request; the
    /// request never retries itself, and the full gate runs again before
    /// anything may be sent.
    @discardableResult
    func retryPaidRecordingExplicitly() async -> Decision {
        await evaluateGate(intendedProvider: nil, origin: .explicitRetry)
    }

    private func evaluateGate(
        intendedProvider: TranscriptionProviderID?,
        origin: PaidRequestOrigin
    ) async -> Decision {
        // Automatic paid retries and fallbacks never exist; the attempt is
        // recognized and denied without touching any other state (ACC-01).
        if origin == .automatic {
            return .blocked(reject(.automaticPaidRequestForbidden))
        }
        // Exactly one paid request per active recording; the active session
        // is the last valid state and is never disturbed.
        if isPaidRequestActive {
            return .blocked(reject(.inFlight))
        }
        // An explicit provider selection is required before recording (ACC-03):
        // no selection means recording cannot start and the user is prompted
        // to select.
        guard let selected = selectedProvider else {
            return .blocked(fail(.providerNotSelected))
        }
        // A request for any other provider is rejected; the selection is
        // never switched automatically (ACC-02).
        if let intendedProvider, intendedProvider != selected {
            return .blocked(fail(.providerMismatch(expected: selected)))
        }
        // Missing credentials block provider use with a clear message; no
        // request is made and no cost is incurred
        // (ACC-CREDENTIAL-VAULT-04: missing credentials block provider use).
        guard await credentialAvailability(selected) else {
            return .blocked(fail(.credentialMissing(selected)))
        }
        // The network gate: a never-determined state is resolved once, and an
        // explicit retry rechecks authorization only after this explicit user
        // action. A denied path keeps local state usable and offers a bounded
        // explicit retry (CON-PERMISSION-NETWORK denied behavior).
        let network = await resolvedNetworkAvailability(origin: origin)
        guard network == .authorized else {
            return .blocked(fail(.networkDenied(selected)))
        }
        // Authorized: exactly one paid request for this recording may start.
        state = .active(selected)
        lastFailure = nil
        lastNotice = "One paid request was authorized for the explicitly selected \(selected.displayName) provider. The selection stays fixed for this recording."
        return .allowed(selected)
    }

    // MARK: Completion, failure, and cancellation

    /// The in-flight paid request completed successfully. The provider's
    /// authoritative usage report is recorded for the cost display; nothing
    /// is derived or estimated client-side, and evidence that does not match
    /// the in-flight request is never accepted.
    @discardableResult
    func completePaidRequest(withProviderReportedUsage usage: ProviderReportedUsage) -> Bool {
        guard case .active(let provider) = state else {
            _ = fail(.noActiveRequest)
            return false
        }
        guard usage.provider == provider else {
            _ = reject(.unexpectedUsageEvidence)
            return false
        }
        lastUsageDisplay = ProviderUsageDisplay(usage: usage)
        lastFailure = nil
        lastNotice = "The paid \(provider.displayName) request completed. The cost display reproduces only provider-reported values."
        state = .succeeded
        return true
    }

    /// A terminal paid-request failure reported by the selected provider's
    /// integration. No automatic retry, fallback, or second paid request
    /// follows it; recovery is an explicit retry that passes the same gate.
    @discardableResult
    func reportPaidRequestFailure() -> Bool {
        guard case .active(let provider) = state else {
            _ = fail(.noActiveRequest)
            return false
        }
        _ = fail(.paidRequestFailed(provider))
        return true
    }

    /// Explicit user cancel of the in-flight paid request: the request ends
    /// as cancelled, late results are discarded by the callers that own them,
    /// and no further paid request happens until one is started explicitly.
    @discardableResult
    func cancelActivePaidRequest() -> Bool {
        guard case .active = state else {
            _ = fail(.noActiveRequest)
            return false
        }
        lastFailure = nil
        lastNotice = "The paid request was cancelled; no further paid request occurs until you start one explicitly."
        state = .cancelled
        return true
    }

    // MARK: Termination

    /// CON-LIFECYCLE-APPLICATION-TERMINATION / CON-LIFECYCLE-AUDIO-CAPTURE-TERMINATION:
    /// release all runtime request state. The explicitly selected provider is
    /// preset-owned state and survives; nothing in flight outlives the process.
    func releaseForTermination() async {
        state = .idle
        lastFailure = nil
        lastNotice = nil
    }

    // MARK: Internals

    /// Network availability resolution. A never-determined state resolves
    /// once through the explicit request seam; an explicit retry rechecks
    /// authorization after the user action and before the retry decision.
    /// Nothing polls automatically.
    private func resolvedNetworkAvailability(origin: PaidRequestOrigin) async -> PermissionState {
        switch origin {
        case .explicitRetry:
            return await requestNetworkAccess()
        case .explicitStart:
            let current = networkAvailability()
            guard current == .notDetermined else { return current }
            return await requestNetworkAccess()
        case .automatic:
            // Unreachable: automatic attempts are denied before this point.
            return .denied
        }
    }

    /// A blocked user-initiated attempt becomes its own terminal failed state
    /// while the explicitly selected provider is always preserved.
    @discardableResult
    private func fail(_ category: Failure.Category) -> Failure {
        let failure = Failure(category: category, message: Self.message(for: category))
        lastFailure = failure
        state = .failed(failure)
        return failure
    }

    /// A rejection that must preserve the last valid user state (an active
    /// session, or a non-user automatic attempt) records the failure only.
    @discardableResult
    private func reject(_ category: Failure.Category) -> Failure {
        let failure = Failure(category: category, message: Self.message(for: category))
        lastFailure = failure
        return failure
    }

    // MARK: Privacy-safe messages

    private static func message(for category: Failure.Category) -> String {
        switch category {
        case .providerNotSelected:
            return "Select a transcription provider before recording. Recording is blocked until you choose a provider explicitly; no provider request was made and no cost was incurred."
        case .providerMismatch(let expected):
            return "That request targets a different provider than the explicitly selected \(expected.displayName) provider. Nothing was sent and the selection was not changed; no automatic provider switch occurs. Select the intended provider explicitly and retry."
        case .selectionLockedWhileRecording:
            return "The provider selection is locked while a recording request is active. Stop or cancel the current recording, then change the provider between recordings."
        case .credentialMissing(let provider):
            return "No \(provider.displayName) credential is stored, so no paid request was made and no cost was incurred. Add the API key in Settings, then retry explicitly."
        case .networkDenied(let provider):
            return "The network is unavailable right now, so no paid \(provider.displayName) request was made and no cost was incurred. Local state stays usable; retry explicitly after the network is available again."
        case .inFlight:
            return "A paid request is already active for this recording. Exactly one request is allowed at a time; stop or cancel it explicitly before starting another."
        case .automaticPaidRequestForbidden:
            return "An automatic paid request is never allowed: retries and fallbacks only ever happen from your explicit action, so nothing was sent and no cost was incurred."
        case .noActiveRequest:
            return "No matching paid request is in flight, so the request was not accepted and nothing changed."
        case .unexpectedUsageEvidence:
            return "The usage report did not match the in-flight paid request, so it was not accepted as cost evidence and nothing changed."
        case .paidRequestFailed(let provider):
            return "The paid \(provider.displayName) request failed. No automatic retry, fallback, or provider switch occurs; retry explicitly or cancel."
        }
    }
}
