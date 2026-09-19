import Foundation
import Testing
@testable import Whisperbar

/// TASK-16-PROVIDER-SELECTION-AND-COST-PROTECTION focused checks.
///
/// Covers FEAT-PROVIDER-SELECTION-AND-COST-PROTECTION and contracts
/// CON-PROVIDER-SELECTION-AND-COST-PROTECTION-INTERFACE and
/// CON-PROVIDER-SELECTION-AND-COST-PROTECTION-RECOVERY through fully injected
/// seams: no live provider request, no network access, no TCC prompt, no
/// Keychain item, and no real provider is touched by these tests. The one
/// settings round-trip uses the isolated DataStore sandbox.
@Suite("ProviderSelectionAndCostProtectionFeature — explicit selection and cost protection")
@MainActor
struct ProviderSelectionAndCostProtectionFeatureTests {

    // MARK: - Fakes

    /// Persisted-selection seam; value-free and write-counted.
    final class FakePreferenceStore: @unchecked Sendable {
        private let lock = NSLock()
        private var _stored: TranscriptionProviderID?
        private var _writes: [TranscriptionProviderID?] = []

        var persistedValue: TranscriptionProviderID? { lock.withLock { _stored } }
        var writes: [TranscriptionProviderID?] { lock.withLock { _writes } }

        func load() async -> TranscriptionProviderID? {
            lock.withLock { _stored }
        }

        func store(_ provider: TranscriptionProviderID?) async {
            lock.withLock {
                _stored = provider
                _writes.append(provider)
            }
        }
    }

    /// Credential-availability seam; never touches the Keychain.
    final class FakeCredentialAvailability: @unchecked Sendable {
        private let lock = NSLock()
        private var _configured: Set<TranscriptionProviderID> = [.deepgramStreaming, .openRouterBatch]
        private var _checks: [TranscriptionProviderID] = []

        var configured: Set<TranscriptionProviderID> {
            get { lock.withLock { _configured } }
            set { lock.withLock { _configured = newValue } }
        }

        var checks: [TranscriptionProviderID] { lock.withLock { _checks } }

        func isConfigured(_ provider: TranscriptionProviderID) async -> Bool {
            lock.withLock {
                _checks.append(provider)
                return _configured.contains(provider)
            }
        }
    }

    /// Shared network permission state; the recheck seam is the only prompt
    /// path and is counted so automatic polling cannot hide.
    final class FakeNetworkPermission: @unchecked Sendable {
        private let lock = NSLock()
        private var _state: PermissionState = .authorized
        private var _recheckResult: PermissionState = .authorized
        private var _reads = 0
        private var _rechecks = 0

        var state: PermissionState {
            get { lock.withLock { _state } }
            set { lock.withLock { _state = newValue } }
        }

        var recheckResult: PermissionState {
            get { lock.withLock { _recheckResult } }
            set { lock.withLock { _recheckResult = newValue } }
        }

        var reads: Int { lock.withLock { _reads } }
        var rechecks: Int { lock.withLock { _rechecks } }

        func read() -> PermissionState {
            lock.withLock {
                _reads += 1
                return _state
            }
        }

        func recheck() async -> PermissionState {
            lock.withLock {
                _rechecks += 1
                return _recheckResult
            }
        }
    }

    // MARK: - Room

    struct Room {
        let feature: ProviderSelectionAndCostProtectionFeature
        let preferences: FakePreferenceStore
        let credentials: FakeCredentialAvailability
        let network: FakeNetworkPermission
    }

    private func makeRoom(store: FakePreferenceStore? = nil) -> Room {
        let preferences = store ?? FakePreferenceStore()
        let credentials = FakeCredentialAvailability()
        let network = FakeNetworkPermission()
        let feature = ProviderSelectionAndCostProtectionFeature(
            loadStoredSelection: { await preferences.load() },
            storeSelection: { await preferences.store($0) },
            credentialAvailability: { await credentials.isConfigured($0) },
            networkAvailability: { network.read() },
            requestNetworkAccess: { await network.recheck() }
        )
        return Room(
            feature: feature,
            preferences: preferences,
            credentials: credentials,
            network: network
        )
    }

    // MARK: - Helpers

    private func blockedCategory(
        _ decision: ProviderSelectionAndCostProtectionFeature.Decision
    ) -> ProviderSelectionAndCostProtectionFeature.Failure.Category? {
        if case .blocked(let failure) = decision { return failure.category }
        return nil
    }

    private func allowedProvider(
        _ decision: ProviderSelectionAndCostProtectionFeature.Decision
    ) -> TranscriptionProviderID? {
        if case .allowed(let provider) = decision { return provider }
        return nil
    }

    private func isFailed(_ feature: ProviderSelectionAndCostProtectionFeature) -> Bool {
        if case .failed = feature.state { return true }
        return false
    }

    // MARK: - Fixtures (provider-reported values only)

    /// OpenRouter-style batch usage: the provider returns usage.cost.
    static let openRouterUsage = ProviderReportedUsage(
        provider: .openRouterBatch,
        requestReference: "gen-abc-123",
        providerReportedDurationSeconds: 12.5,
        inputTokens: 120,
        outputTokens: 40,
        totalTokens: 160,
        providerReportedCostUSD: Decimal(string: "0.0123")!
    )

    /// Deepgram-style streaming usage: request evidence and provider
    /// duration, and no monetary usage object exists on the socket.
    static let deepgramUsage = ProviderReportedUsage(
        provider: .deepgramStreaming,
        requestReference: "dg-request-1",
        providerReportedDurationSeconds: 4.2,
        inputTokens: nil,
        outputTokens: nil,
        totalTokens: nil,
        providerReportedCostUSD: nil
    )

    // MARK: - ACC-03: provider must be selected before recording

    @Test("Recording stays blocked until the provider is explicitly selected, and the block prompts the user")
    func recordingIsBlockedUntilTheProviderIsExplicitlySelected() async {
        let room = makeRoom()
        #expect(room.feature.requiresProviderSelection)

        let decision = await room.feature.requestPaidRecording(origin: .explicitStart)

        #expect(blockedCategory(decision) == .providerNotSelected)
        #expect(room.feature.requiresProviderSelection)
        #expect(isFailed(room.feature))
        let message = room.feature.lastFailure?.message ?? ""
        #expect(message.contains("Select a transcription provider"))
        #expect(message.contains("no cost was incurred"))
        #expect(room.feature.lastUsageDisplay == nil)
        // A block makes no provider call and reads no seam.
        #expect(room.credentials.checks.isEmpty)
        #expect(room.network.reads == 0)
        #expect(room.network.rechecks == 0)
        #expect(room.preferences.writes.isEmpty)

        #expect(await room.feature.selectProvider(.deepgramStreaming))
        #expect(room.feature.requiresProviderSelection == false)
        #expect(room.preferences.persistedValue == .deepgramStreaming)

        let allowed = await room.feature.requestPaidRecording(origin: .explicitStart)
        #expect(allowed == .allowed(.deepgramStreaming))
        #expect(room.feature.state == .active(.deepgramStreaming))
        #expect(room.feature.isPaidRequestActive)
    }

    // MARK: - Selection persistence and ACC-04: change between recordings

    @Test("The explicit selection is persisted and restored, and clearing it re-blocks recording")
    func theExplicitSelectionIsPersistedAndRestoredAcrossInstances() async {
        let room = makeRoom()
        #expect(await room.feature.selectProvider(.openRouterBatch))
        #expect(room.preferences.writes == [.openRouterBatch])
        #expect(room.preferences.persistedValue == .openRouterBatch)

        // A restarted feature instance restores the same explicit selection
        // and can record without re-selecting.
        let restarted = makeRoom(store: room.preferences)
        #expect(restarted.feature.requiresProviderSelection)
        await restarted.feature.loadProviderSelection()
        #expect(restarted.feature.selectedProvider == .openRouterBatch)
        #expect(restarted.feature.requiresProviderSelection == false)
        #expect(await restarted.feature.requestPaidRecording(origin: .explicitStart) == .allowed(.openRouterBatch))
        #expect(await restarted.feature.cancelActivePaidRequest())

        // Clearing the explicit selection is legal between recordings and
        // re-blocks recording until a new explicit choice exists.
        #expect(await restarted.feature.selectProvider(nil))
        #expect(restarted.preferences.persistedValue == nil)
        #expect(restarted.preferences.writes == [.openRouterBatch, nil])
        #expect(restarted.feature.requiresProviderSelection)
        let blockedAgain = await restarted.feature.requestPaidRecording(origin: .explicitStart)
        #expect(blockedCategory(blockedAgain) == .providerNotSelected)
    }

    @Test("The explicit selection round-trips through the shared local settings store")
    func theExplicitSelectionRoundTripsThroughTheSharedLocalSettingsStore() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }
        let store = sandbox.makeStore()

        let fresh = ProviderSelectionAndCostProtectionFeature(
            loadStoredSelection: { await store.providerPreference() },
            storeSelection: { await store.setProviderPreference($0) }
        )
        await fresh.loadProviderSelection()
        #expect(fresh.requiresProviderSelection)

        #expect(await fresh.selectProvider(.openRouterBatch))
        #expect(await store.providerPreference() == .openRouterBatch)

        let restarted = ProviderSelectionAndCostProtectionFeature(
            loadStoredSelection: { await store.providerPreference() },
            storeSelection: { await store.setProviderPreference($0) }
        )
        await restarted.loadProviderSelection()
        #expect(restarted.selectedProvider == .openRouterBatch)
        #expect(await restarted.requestPaidRecording(origin: .explicitStart) == .allowed(.openRouterBatch))
    }

    @Test("The provider can only change between recordings")
    func theProviderCanOnlyChangeBetweenRecordings() async {
        let room = makeRoom()
        #expect(await room.feature.selectProvider(.deepgramStreaming))
        #expect(await room.feature.requestPaidRecording(origin: .explicitStart) == .allowed(.deepgramStreaming))

        // Locked while a recording request is active: nothing changes and
        // nothing is persisted.
        let locked = await room.feature.selectProvider(.openRouterBatch)
        #expect(locked == false)
        #expect(room.feature.selectedProvider == .deepgramStreaming)
        #expect(room.feature.lastFailure?.category == .selectionLockedWhileRecording)
        #expect(room.feature.state == .active(.deepgramStreaming))
        #expect(room.preferences.writes == [.deepgramStreaming])
        #expect(room.preferences.persistedValue == .deepgramStreaming)

        // Between recordings the change is an explicit, persisted user action.
        #expect(await room.feature.cancelActivePaidRequest())
        #expect(await room.feature.selectProvider(.openRouterBatch))
        #expect(room.feature.selectedProvider == .openRouterBatch)
        #expect(room.preferences.persistedValue == .openRouterBatch)
        #expect(room.preferences.writes == [.deepgramStreaming, .openRouterBatch])

        // The next recording uses exactly the new explicit selection; the old
        // provider is a mismatch, never an automatic switch.
        let misdirected = await room.feature.requestPaidRecording(for: .deepgramStreaming, origin: .explicitStart)
        #expect(blockedCategory(misdirected) == .providerMismatch(expected: .openRouterBatch))
        #expect(await room.feature.requestPaidRecording(for: .openRouterBatch, origin: .explicitStart) == .allowed(.openRouterBatch))
    }

    // MARK: - ACC-02: no automatic provider switching

    @Test("A request for another provider is rejected without an automatic switch and without any provider call")
    func aRequestForAnotherProviderIsRejectedWithoutAnyAutomaticSwitch() async {
        let room = makeRoom()
        #expect(await room.feature.selectProvider(.deepgramStreaming))

        let decision = await room.feature.requestPaidRecording(for: .openRouterBatch, origin: .explicitStart)

        #expect(blockedCategory(decision) == .providerMismatch(expected: .deepgramStreaming))
        #expect(room.feature.selectedProvider == .deepgramStreaming)
        #expect(room.preferences.writes == [.deepgramStreaming])
        #expect(isFailed(room.feature))
        #expect((room.feature.lastFailure?.message ?? "").contains("automatic provider switch"))
        // No credential check, no network access, and no cost happen here.
        #expect(room.credentials.checks.isEmpty)
        #expect(room.network.reads == 0)
        #expect(room.network.rechecks == 0)

        // The explicitly selected provider still works after the rejection.
        #expect(await room.feature.requestPaidRecording(origin: .explicitStart) == .allowed(.deepgramStreaming))
    }

    // MARK: - ACC-01: cost-related actions are explicit

    @Test("Automatic paid retries and fallbacks are always denied and never disturb the last valid state")
    func automaticPaidRetriesAndFallbacksAreAlwaysDenied() async {
        let room = makeRoom()
        #expect(await room.feature.selectProvider(.deepgramStreaming))

        // From idle: denied, state preserved, nothing touched.
        let fromIdle = await room.feature.requestPaidRecording(origin: .automatic)
        #expect(blockedCategory(fromIdle) == .automaticPaidRequestForbidden)
        #expect(room.feature.state == .idle)
        #expect(room.credentials.checks.isEmpty)
        #expect(room.network.reads == 0)
        #expect(room.feature.selectedProvider == .deepgramStreaming)

        // After a completed request: denied, the succeeded state and the
        // authoritative usage display are both preserved.
        #expect(await room.feature.requestPaidRecording(origin: .explicitStart) == .allowed(.deepgramStreaming))
        #expect(room.feature.completePaidRequest(withProviderReportedUsage: Self.deepgramUsage))
        let displayBefore = room.feature.lastUsageDisplay
        #expect(displayBefore != nil)

        let fromSucceeded = await room.feature.requestPaidRecording(origin: .automatic)
        #expect(blockedCategory(fromSucceeded) == .automaticPaidRequestForbidden)
        #expect(room.feature.state == .succeeded)
        #expect(room.feature.lastUsageDisplay == displayBefore)
        #expect((room.feature.lastFailure?.message ?? "").contains("no cost was incurred"))

        // No automatic attempt ever reaches a seam: one credential check for
        // the one explicit start remains the complete story.
        #expect(room.credentials.checks == [.deepgramStreaming])
        #expect(room.network.rechecks == 0)
    }

    @Test("Missing credentials block provider use with a clear message, and adding them enables only an explicit retry")
    func missingCredentialsBlockProviderUseAndEnableOnlyAnExplicitRetry() async {
        let room = makeRoom()
        room.credentials.configured = [.openRouterBatch]
        #expect(await room.feature.selectProvider(.deepgramStreaming))

        let decision = await room.feature.requestPaidRecording(origin: .explicitStart)

        #expect(blockedCategory(decision) == .credentialMissing(.deepgramStreaming))
        let message = room.feature.lastFailure?.message ?? ""
        #expect(message.contains("credential"))
        #expect(message.contains("no cost was incurred"))
        #expect(room.feature.lastUsageDisplay == nil)
        #expect(room.credentials.checks == [.deepgramStreaming])
        // The network gate is never reached for a credential block.
        #expect(room.network.reads == 0)
        #expect(room.network.rechecks == 0)
        #expect(isFailed(room.feature))
        // The explicit selection is preserved so recovery stays possible.
        #expect(room.feature.selectedProvider == .deepgramStreaming)

        // Recovery is the user's explicit action after the credential exists.
        room.credentials.configured = [.deepgramStreaming, .openRouterBatch]
        let retry = await room.feature.retryPaidRecordingExplicitly()
        #expect(allowedProvider(retry) == .deepgramStreaming)
        #expect(room.credentials.checks == [.deepgramStreaming, .deepgramStreaming])
    }

    @Test("An unavailable network blocks the paid request, keeps state usable, and rechecks only on an explicit retry")
    func anUnavailableNetworkBlocksThePaidRequestAndRetriesExplicitly() async {
        let room = makeRoom()
        room.network.state = .denied
        #expect(await room.feature.selectProvider(.deepgramStreaming))

        let decision = await room.feature.requestPaidRecording(origin: .explicitStart)

        #expect(blockedCategory(decision) == .networkDenied(.deepgramStreaming))
        #expect((room.feature.lastFailure?.message ?? "").contains("network"))
        #expect(room.network.reads == 1)
        #expect(room.network.rechecks == 0)
        // Local state stays usable: the explicit selection stays and no cost
        // is recorded.
        #expect(room.feature.selectedProvider == .deepgramStreaming)
        #expect(room.feature.lastUsageDisplay == nil)
        #expect(isFailed(room.feature))

        // The bounded explicit retry rechecks the permission after this
        // explicit user action; a still-denied recheck keeps the denied path.
        room.network.recheckResult = .denied
        let deniedRetry = await room.feature.retryPaidRecordingExplicitly()
        #expect(blockedCategory(deniedRetry) == .networkDenied(.deepgramStreaming))
        #expect(room.network.rechecks == 1)

        // Once the recheck is authorized, the same explicit retry proceeds.
        room.network.recheckResult = .authorized
        let allowedRetry = await room.feature.retryPaidRecordingExplicitly()
        #expect(allowedRetry == .allowed(.deepgramStreaming))
        #expect(room.network.rechecks == 2)
        #expect(room.feature.state == .active(.deepgramStreaming))
    }

    @Test("A never-determined network state is resolved exactly once from the explicit action")
    func aNeverDeterminedNetworkStateIsResolvedOnceFromTheExplicitAction() async {
        let room = makeRoom()
        room.network.state = .notDetermined
        room.network.recheckResult = .authorized
        #expect(await room.feature.selectProvider(.deepgramStreaming))

        let allowed = await room.feature.requestPaidRecording(origin: .explicitStart)

        #expect(allowed == .allowed(.deepgramStreaming))
        #expect(room.network.reads == 1)
        #expect(room.network.rechecks == 1)

        // A never-determined state that resolves to denied keeps the denied path.
        let deniedRoom = makeRoom()
        deniedRoom.network.state = .notDetermined
        deniedRoom.network.recheckResult = .denied
        #expect(await deniedRoom.feature.selectProvider(.deepgramStreaming))

        let denied = await deniedRoom.feature.requestPaidRecording(origin: .explicitStart)
        #expect(blockedCategory(denied) == .networkDenied(.deepgramStreaming))
        #expect(deniedRoom.network.rechecks == 1)
        #expect(deniedRoom.feature.selectedProvider == .deepgramStreaming)
    }

    // MARK: - One in-flight paid request per recording

    @Test("Exactly one paid request can be in flight for the active recording")
    func exactlyOnePaidRequestCanBeInFlightPerRecording() async {
        let room = makeRoom()
        #expect(await room.feature.selectProvider(.deepgramStreaming))
        #expect(await room.feature.requestPaidRecording(origin: .explicitStart) == .allowed(.deepgramStreaming))

        let duplicate = await room.feature.requestPaidRecording(origin: .explicitStart)

        #expect(blockedCategory(duplicate) == .inFlight)
        // The active session is the last valid state and is never disturbed.
        #expect(room.feature.state == .active(.deepgramStreaming))
        #expect(room.feature.isPaidRequestActive)
        #expect(room.feature.lastFailure?.category == .inFlight)
        // The in-flight check short-circuits before any seam is consulted again.
        #expect(room.credentials.checks == [.deepgramStreaming])
        #expect(room.network.rechecks == 0)

        // After the request completes, a new recording passes the gate again.
        #expect(room.feature.completePaidRequest(withProviderReportedUsage: Self.deepgramUsage))
        #expect(await room.feature.requestPaidRecording(origin: .explicitStart) == .allowed(.deepgramStreaming))
        #expect(room.credentials.checks == [.deepgramStreaming, .deepgramStreaming])
    }

    // MARK: - Authoritative provider usage and cost display

    @Test("The cost display reproduces the provider-reported cost exactly")
    func completionRecordsOnlyProviderReportedUsage() async {
        let room = makeRoom()
        #expect(await room.feature.selectProvider(.openRouterBatch))
        #expect(await room.feature.requestPaidRecording(origin: .explicitStart) == .allowed(.openRouterBatch))

        #expect(room.feature.completePaidRequest(withProviderReportedUsage: Self.openRouterUsage))

        #expect(room.feature.state == .succeeded)
        #expect(room.feature.lastFailure == nil)
        let display = room.feature.lastUsageDisplay
        #expect(display?.provider == .openRouterBatch)
        #expect(display?.requestReference == "gen-abc-123")
        #expect(display?.providerReportedDurationSeconds == 12.5)
        #expect(display?.totalTokens == 160)
        #expect(display?.providerReportedCostUSD == Decimal(string: "0.0123"))
        #expect(display?.isCostAuthoritative == true)
        #expect(display?.costText == "Provider-reported cost: US$0.0123")
    }

    @Test("A provider without monetary fields marks cost unavailable instead of estimating one")
    func aProviderWithoutMonetaryFieldsMarksCostUnavailable() async {
        let room = makeRoom()
        #expect(await room.feature.selectProvider(.deepgramStreaming))
        #expect(await room.feature.requestPaidRecording(origin: .explicitStart) == .allowed(.deepgramStreaming))

        // The streaming socket reports request evidence and no monetary usage.
        #expect(room.feature.completePaidRequest(withProviderReportedUsage: Self.deepgramUsage))

        let streamingDisplay = room.feature.lastUsageDisplay
        #expect(streamingDisplay?.providerReportedCostUSD == nil)
        #expect(streamingDisplay?.isCostAuthoritative == false)
        #expect(streamingDisplay?.costText == "Cost unavailable — the provider did not report monetary usage.")
        #expect(streamingDisplay?.requestReference == "dg-request-1")

        // Token counts alone are never converted into a cost client-side.
        #expect(await room.feature.requestPaidRecording(origin: .explicitStart) == .allowed(.deepgramStreaming))
        let tokensOnlyUsage = ProviderReportedUsage(
            provider: .deepgramStreaming,
            requestReference: "dg-request-2",
            providerReportedDurationSeconds: nil,
            inputTokens: 100,
            outputTokens: 50,
            totalTokens: 150,
            providerReportedCostUSD: nil
        )
        #expect(room.feature.completePaidRequest(withProviderReportedUsage: tokensOnlyUsage))

        let tokensOnlyDisplay = room.feature.lastUsageDisplay
        #expect(tokensOnlyDisplay?.totalTokens == 150)
        #expect(tokensOnlyDisplay?.isCostAuthoritative == false)
        #expect(tokensOnlyDisplay?.costText == "Cost unavailable — the provider did not report monetary usage.")
        #expect(tokensOnlyDisplay?.costText.contains("US$") == false)
    }

    @Test("Usage evidence is accepted only for the matching in-flight paid request")
    func usageEvidenceIsAcceptedOnlyForTheMatchingInFlightRequest() async {
        let room = makeRoom()
        #expect(await room.feature.selectProvider(.deepgramStreaming))

        // Nothing in flight: the evidence is rejected and nothing is displayed.
        #expect(room.feature.completePaidRequest(withProviderReportedUsage: Self.deepgramUsage) == false)
        #expect(room.feature.lastFailure?.category == .noActiveRequest)
        #expect(room.feature.lastUsageDisplay == nil)

        // Evidence for a different provider than the in-flight one is not
        // accepted, and the active session is preserved.
        #expect(await room.feature.requestPaidRecording(origin: .explicitStart) == .allowed(.deepgramStreaming))
        #expect(room.feature.completePaidRequest(withProviderReportedUsage: Self.openRouterUsage) == false)
        #expect(room.feature.lastFailure?.category == .unexpectedUsageEvidence)
        #expect(room.feature.lastUsageDisplay == nil)
        #expect(room.feature.state == .active(.deepgramStreaming))

        // The matching provider-reported usage is accepted exactly once.
        #expect(room.feature.completePaidRequest(withProviderReportedUsage: Self.deepgramUsage))
        #expect(room.feature.state == .succeeded)
        #expect(room.feature.lastUsageDisplay?.provider == .deepgramStreaming)
    }

    // MARK: - Recovery contract: terminal states and explicit-only recovery

    @Test("A paid request failure is terminal, and only an explicit retry starts another paid request")
    func aPaidRequestFailureIsTerminalAndRecoveryIsExplicitOnly() async {
        let room = makeRoom()
        #expect(await room.feature.selectProvider(.deepgramStreaming))
        #expect(await room.feature.requestPaidRecording(origin: .explicitStart) == .allowed(.deepgramStreaming))

        #expect(room.feature.reportPaidRequestFailure())

        #expect(isFailed(room.feature))
        #expect(room.feature.lastFailure?.category == .paidRequestFailed(.deepgramStreaming))
        let message = room.feature.lastFailure?.message ?? ""
        #expect(message.contains("No automatic retry"))
        #expect(message.contains("fallback"))
        #expect(room.feature.awaitingExplicitRecovery)
        #expect(room.feature.isPaidRequestActive == false)
        #expect(room.feature.selectedProvider == .deepgramStreaming)
        // Nothing happens automatically after the failure.
        #expect(room.credentials.checks == [.deepgramStreaming])
        #expect(room.network.rechecks == 0)
        #expect(room.preferences.writes == [.deepgramStreaming])

        // The explicit retry passes the same gate and starts exactly one new
        // paid request.
        let retry = await room.feature.retryPaidRecordingExplicitly()
        #expect(retry == .allowed(.deepgramStreaming))
        #expect(room.feature.state == .active(.deepgramStreaming))
        #expect(room.credentials.checks == [.deepgramStreaming, .deepgramStreaming])
        #expect(room.network.rechecks == 1)
    }

    @Test("Completing, failing, or cancelling without an in-flight request is a rejected attempt")
    func reportsWithoutAnInFlightRequestAreRejected() async {
        let room = makeRoom()
        #expect(await room.feature.selectProvider(.deepgramStreaming))

        #expect(room.feature.reportPaidRequestFailure() == false)
        #expect(room.feature.lastFailure?.category == .noActiveRequest)
        #expect(isFailed(room.feature))

        #expect(room.feature.cancelActivePaidRequest() == false)
        #expect(room.feature.lastFailure?.category == .noActiveRequest)
        #expect(room.feature.isPaidRequestActive == false)
    }

    @Test("An explicit cancel ends the paid-request bookkeeping and nothing restarts on its own")
    func anExplicitCancelEndsTheBookkeeping() async {
        let room = makeRoom()
        #expect(await room.feature.selectProvider(.deepgramStreaming))
        #expect(await room.feature.requestPaidRecording(origin: .explicitStart) == .allowed(.deepgramStreaming))

        #expect(room.feature.cancelActivePaidRequest())

        #expect(room.feature.state == .cancelled)
        #expect(room.feature.isPaidRequestActive == false)
        #expect(room.feature.lastFailure == nil)
        #expect(room.feature.awaitingExplicitRecovery)
        #expect(room.feature.lastUsageDisplay == nil)
        #expect(room.credentials.checks == [.deepgramStreaming])

        // Recovery from cancellation is another explicit user start.
        #expect(await room.feature.requestPaidRecording(origin: .explicitStart) == .allowed(.deepgramStreaming))
    }

    // MARK: - Termination

    @Test("Termination releases all runtime request state and keeps only the explicit selection")
    func terminationReleasesRuntimeRequestState() async {
        let room = makeRoom()
        #expect(await room.feature.selectProvider(.openRouterBatch))
        #expect(await room.feature.requestPaidRecording(origin: .explicitStart) == .allowed(.openRouterBatch))
        #expect(room.feature.isPaidRequestActive)

        await room.feature.releaseForTermination()

        #expect(room.feature.state == .idle)
        #expect(room.feature.isPaidRequestActive == false)
        #expect(room.feature.lastFailure == nil)
        #expect(room.feature.lastNotice == nil)
        #expect(room.feature.awaitingExplicitRecovery == false)
        // The explicitly selected provider is preset-owned state and survives.
        #expect(room.feature.selectedProvider == .openRouterBatch)
        #expect(room.preferences.persistedValue == .openRouterBatch)
        // A later explicit start passes the gate again.
        #expect(await room.feature.requestPaidRecording(origin: .explicitStart) == .allowed(.openRouterBatch))
    }
}
