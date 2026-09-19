import Foundation
import Testing
@testable import Whisperbar

/// TASK-17-TEMPORARY-AUDIO-CLEANUP focused checks.
///
/// Covers FEAT-TEMPORARY-AUDIO-CLEANUP and contracts
/// CON-TEMPORARY-AUDIO-CLEANUP-INTERFACE and CON-TEMPORARY-AUDIO-CLEANUP-RECOVERY
/// through fully injected filesystem seams: no test touches a real recording,
/// a live provider, or a shared temporary directory. The canonical placement
/// round-trip runs against an isolated DataStore sandbox in the system
/// temporary directory.
///
/// Contract anchors:
/// - ACC-TEMPORARY-AUDIO-CLEANUP-01: audio files are deleted after success or cancellation.
/// - ACC-TEMPORARY-AUDIO-CLEANUP-02: cleanup is guaranteed, retried on failure, and never
///   claims removal without verified absence.
/// - ACC-TEMPORARY-AUDIO-CLEANUP-03: no audio persists across sessions.
/// - ACC-TEMPORARY-AUDIO-CLEANUP-04: temporary storage stays in the sandboxed temporary base.
@Suite("TemporaryAudioCleanupFeature — temporary audio lifecycle and verified cleanup")
@MainActor
struct TemporaryAudioCleanupFeatureTests {

    // MARK: - Fakes

    enum FakeStoreError: Error, Equatable {
        case discardFailed
        case prepareFailed
        case purgeFailed
        case saveFailed
    }

    /// Scripted temporary-audio store. Records every call and can fail, lie,
    /// or leave audio behind so the feature's verification logic is exercised
    /// without touching a real filesystem.
    final class FakeTemporaryAudioStore: @unchecked Sendable {
        private let lock = NSLock()

        private var present: Set<UUID> = []
        private var stale: Set<UUID> = []
        private var leftovers: Set<UUID> = []
        private var saved: Set<UUID> = []
        private var events: [String] = []

        private(set) var prepareCalls: [UUID] = []
        private(set) var discardCalls: [UUID] = []
        private(set) var existsChecks: [UUID] = []
        private(set) var saveCalls: [UUID] = []
        private(set) var saveDestinations: [URL?] = []
        private(set) var purgeCallCount = 0

        /// Fail the next N `discard` calls; `Int.max` fails every call.
        var discardFailuresRemaining = 0
        /// Claim success on the next N `discard` calls while leaving audio in
        /// place; `Int.max` always lies.
        var discardLiesRemaining = 0
        /// Throw from `prepare` / `purge` / `save` when set.
        var prepareError: Error?
        var purgeError: Error?
        var saveError: Error?
        /// When set, a successful save still leaves a temporary directory
        /// behind so post-save verified absence must catch it.
        var saveLeavesTemporaryLeftover = false

        var presentIDs: Set<UUID> { lock.withLock { present } }
        var staleIDs: Set<UUID> { lock.withLock { stale } }
        var savedIDs: Set<UUID> { lock.withLock { saved } }
        var recordedEvents: [String] { lock.withLock { events } }

        func seedStaleAudio(_ id: UUID) {
            lock.withLock { stale.insert(id) }
        }

        func prepare(_ id: UUID, _ fileExtension: String) throws -> URL {
            try lock.withLock {
                prepareCalls.append(id)
                events.append("prepare")
                if let prepareError { throw prepareError }
                present.insert(id)
                return URL(fileURLWithPath: "/fake-temporary-base/\(id.uuidString)/audio.\(fileExtension)")
            }
        }

        func exists(_ id: UUID) -> Bool {
            lock.withLock {
                existsChecks.append(id)
                return present.contains(id) || leftovers.contains(id)
            }
        }

        func discard(_ id: UUID) throws -> Bool {
            try lock.withLock {
                discardCalls.append(id)
                events.append("discard")
                if discardFailuresRemaining > 0 {
                    if discardFailuresRemaining != Int.max { discardFailuresRemaining -= 1 }
                    throw FakeStoreError.discardFailed
                }
                if discardLiesRemaining > 0 {
                    if discardLiesRemaining != Int.max { discardLiesRemaining -= 1 }
                    return true
                }
                let existed = present.remove(id) != nil
                let removedLeftover = leftovers.remove(id) != nil
                stale.remove(id)
                return existed || removedLeftover
            }
        }

        func save(_ id: UUID, _ fileExtension: String, _ destination: URL?) throws -> URL {
            try lock.withLock {
                saveCalls.append(id)
                saveDestinations.append(destination)
                events.append("save")
                if let saveError { throw saveError }
                guard present.contains(id) else { throw FakeStoreError.saveFailed }
                present.remove(id)
                if saveLeavesTemporaryLeftover { leftovers.insert(id) }
                saved.insert(id)
                if let destination {
                    return destination
                }
                return URL(fileURLWithPath: "/fake-recordings/\(id.uuidString).\(fileExtension)")
            }
        }

        func purge() throws -> Int {
            try lock.withLock {
                purgeCallCount += 1
                events.append("purge")
                if let purgeError { throw purgeError }
                let removed = present.union(stale).union(leftovers).count
                present.removeAll()
                stale.removeAll()
                leftovers.removeAll()
                return removed
            }
        }
    }

    /// Receives the cleanup outcomes reported to the lifecycle owner.
    final class FakeTerminationReports: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [(reason: CaptureTerminationReason, cleanup: AudioCaptureCleanupOutcome)] = []

        var reports: [(reason: CaptureTerminationReason, cleanup: AudioCaptureCleanupOutcome)] {
            lock.withLock { storage }
        }

        func record(_ reason: CaptureTerminationReason, _ cleanup: AudioCaptureCleanupOutcome) {
            lock.withLock { storage.append((reason, cleanup)) }
        }
    }

    /// Scripted destination chooser: records the value-free suggested file
    /// name and returns the scripted decision, so the interactive save seam
    /// is exercised without ever opening a panel. An empty script answers
    /// with the inert `.storeDefault` decision.
    final class FakeSaveDestinationChooser: @unchecked Sendable {
        private let lock = NSLock()
        private var decisions: [TemporaryAudioCleanupFeature.SaveDestinationDecision] = []
        private var names: [String] = []

        var suggestedFileNames: [String] { lock.withLock { names } }

        func scriptNext(_ decision: TemporaryAudioCleanupFeature.SaveDestinationDecision) {
            lock.withLock { decisions.append(decision) }
        }

        func choose(_ suggestedFileName: String) -> TemporaryAudioCleanupFeature.SaveDestinationDecision {
            lock.withLock {
                names.append(suggestedFileName)
                return decisions.isEmpty ? .storeDefault : decisions.removeFirst()
            }
        }
    }

    // MARK: - Room

    struct Room {
        let feature: TemporaryAudioCleanupFeature
        let store: FakeTemporaryAudioStore
        let reports: FakeTerminationReports
    }

    private func makeRoom(
        store: FakeTemporaryAudioStore? = nil,
        chooser: FakeSaveDestinationChooser? = nil
    ) -> Room {
        let fake = store ?? FakeTemporaryAudioStore()
        let reports = FakeTerminationReports()
        let feature = TemporaryAudioCleanupFeature(
            prepareTemporaryRecording: { id, ext in try fake.prepare(id, ext) },
            temporaryRecordingExists: { id in fake.exists(id) },
            discardTemporaryRecording: { id in try fake.discard(id) },
            saveRecording: { id, ext, destination in try fake.save(id, ext, destination) },
            chooseSaveDestination: { suggestedFileName in chooser?.choose(suggestedFileName) ?? .storeDefault },
            purgeStaleTemporaryRecordings: { try fake.purge() },
            reportCaptureTermination: { reason, cleanup in reports.record(reason, cleanup) }
        )
        return Room(feature: feature, store: fake, reports: reports)
    }

    // MARK: - Helpers

    private func isFailed(_ feature: TemporaryAudioCleanupFeature) -> Bool {
        if case .failed = feature.state { return true }
        return false
    }

    private func failedMessage(_ outcome: AudioCaptureCleanupOutcome) -> String? {
        if case .failed(let message) = outcome { return message }
        return nil
    }

    // MARK: - ACC-01: success deletes the audio with verified absence

    @Test("Successful transcription deletes the temporary audio and verifies absence before claiming cleanup")
    func successDeletesAndVerifiesAbsenceBeforeClaimingCleanup() async {
        let room = makeRoom()
        let recordingID = UUID()
        #expect(await room.feature.beginSession(recordingID: recordingID))
        #expect(room.feature.activeRecordingID == recordingID)
        #expect(room.feature.activeTemporaryAudioURL != nil)
        #expect(room.store.presentIDs == [recordingID])

        let outcome = await room.feature.acceptSuccess(recordingID: recordingID)

        #expect(outcome == .verifiedAbsence)
        // The audio is gone and its absence was checked, never assumed.
        #expect(room.store.presentIDs.isEmpty)
        #expect(room.store.discardCalls == [recordingID])
        #expect(room.store.existsChecks == [recordingID])
        #expect(room.feature.audioRemovalVerified)
        #expect(room.feature.state == .succeeded)
        #expect(room.feature.isAudioLifecycleClear)
        #expect(room.feature.lastFailure == nil)
    }

    @Test("Cancellation deletes the temporary audio, verifies absence, and reports the outcome to the lifecycle owner")
    func cancellationDeletesVerifiesAndReportsToTheLifecycleOwner() async {
        let room = makeRoom()
        let recordingID = UUID()
        #expect(await room.feature.beginSession(recordingID: recordingID))

        let outcome = await room.feature.cancelSession(recordingID: recordingID)

        #expect(outcome == .verifiedAbsence)
        #expect(room.store.presentIDs.isEmpty)
        #expect(room.feature.state == .cancelled)
        #expect(room.feature.audioRemovalVerified)
        #expect(room.feature.isAudioLifecycleClear)
        #expect(room.reports.reports.count == 1)
        #expect(room.reports.reports.first?.reason == .cancelled)
        #expect(room.reports.reports.first?.cleanup == .verifiedAbsence)
    }

    @Test("An explicit discard deletes and verifies without starting or saving anything else")
    func explicitDiscardDeletesAndVerifies() async {
        let room = makeRoom()
        let recordingID = UUID()
        #expect(await room.feature.beginSession(recordingID: recordingID))

        let outcome = await room.feature.discardExplicitly(recordingID: recordingID)

        #expect(outcome == .verifiedAbsence)
        #expect(room.store.presentIDs.isEmpty)
        #expect(room.store.saveCalls.isEmpty)
        #expect(room.feature.state == .cancelled)
        #expect(room.feature.audioRemovalVerified)
        #expect(room.feature.isAudioLifecycleClear)
    }

    // MARK: - ACC-02: cleanup is guaranteed, retried, and honest

    @Test("Cleanup retries are bounded and exhausted attempts are reported honestly")
    func cleanupRetriesAreBoundedAndReportedHonestly() async {
        let room = makeRoom()
        let recordingID = UUID()
        #expect(await room.feature.beginSession(recordingID: recordingID))
        room.store.discardFailuresRemaining = .max

        let outcome = await room.feature.acceptSuccess(recordingID: recordingID)

        // Attempts are bounded by the documented limit.
        #expect(room.store.discardCalls.count == TemporaryAudioCleanupFeature.cleanupAttemptLimit)
        #expect(room.store.existsChecks.count == TemporaryAudioCleanupFeature.cleanupAttemptLimit)
        // The failure is honest: no removal is claimed and the audio is still there.
        #expect(failedMessage(outcome) != nil)
        #expect(room.feature.audioRemovalVerified == false)
        #expect(room.store.presentIDs == [recordingID])
        #expect(room.feature.lastFailure?.category == .cleanupFailed(attempts: TemporaryAudioCleanupFeature.cleanupAttemptLimit))
        #expect(room.feature.pendingCleanupRecordingID == recordingID)
        // The message is privacy-safe: no paths, identifiers, or content.
        let message = failedMessage(outcome) ?? ""
        #expect(message.contains("could not be removed"))
        #expect(message.contains("retry"))
        #expect(!message.contains("/"))
        #expect(!message.contains(recordingID.uuidString))
    }

    @Test("An early cleanup failure is retried until absence is verified")
    func earlyCleanupFailureIsRetriedUntilAbsenceIsVerified() async {
        let room = makeRoom()
        let recordingID = UUID()
        #expect(await room.feature.beginSession(recordingID: recordingID))
        room.store.discardFailuresRemaining = TemporaryAudioCleanupFeature.cleanupAttemptLimit - 1

        let outcome = await room.feature.acceptSuccess(recordingID: recordingID)

        #expect(outcome == .verifiedAbsence)
        #expect(room.store.discardCalls.count == TemporaryAudioCleanupFeature.cleanupAttemptLimit)
        #expect(room.store.presentIDs.isEmpty)
        #expect(room.feature.audioRemovalVerified)
        #expect(room.feature.pendingCleanupRecordingID == nil)
        #expect(room.feature.state == .succeeded)
    }

    @Test("A delete that reports success but leaves the audio behind is never claimed as cleanup")
    func aLyingDeleteIsNeverClaimedAsCleanup() async {
        let room = makeRoom()
        let recordingID = UUID()
        #expect(await room.feature.beginSession(recordingID: recordingID))
        room.store.discardLiesRemaining = .max

        let outcome = await room.feature.cancelSession(recordingID: recordingID)

        // Verification caught every lie; nothing was claimed.
        #expect(room.store.discardCalls.count == TemporaryAudioCleanupFeature.cleanupAttemptLimit)
        #expect(room.store.existsChecks.count == TemporaryAudioCleanupFeature.cleanupAttemptLimit)
        #expect(failedMessage(outcome) != nil)
        #expect(room.feature.audioRemovalVerified == false)
        #expect(room.store.presentIDs == [recordingID])
        #expect(room.feature.pendingCleanupRecordingID == recordingID)

        // Once the store stops lying, the explicit retry completes the cleanup.
        room.store.discardLiesRemaining = 0
        let retry = await room.feature.retryPendingCleanup()
        #expect(retry == .verifiedAbsence)
        #expect(room.store.presentIDs.isEmpty)
        #expect(room.feature.pendingCleanupRecordingID == nil)
        #expect(room.feature.audioRemovalVerified)
        #expect(room.feature.state == .cancelled)
    }

    @Test("An explicit cleanup retry finishes a cleanup that was still failing after exhaustion")
    func explicitCleanupRetryFinishesAfterExhaustion() async {
        let room = makeRoom()
        let recordingID = UUID()
        #expect(await room.feature.beginSession(recordingID: recordingID))
        room.store.discardFailuresRemaining = .max
        let first = await room.feature.acceptSuccess(recordingID: recordingID)
        #expect(failedMessage(first) != nil)
        #expect(isFailed(room.feature))

        // The explicit user retry reruns the same bounded cleanup.
        room.store.discardFailuresRemaining = 0
        let retry = await room.feature.retryPendingCleanup()

        #expect(retry == .verifiedAbsence)
        #expect(room.feature.state == .succeeded)
        #expect(room.feature.audioRemovalVerified)
        #expect(room.feature.pendingCleanupRecordingID == nil)
        #expect(room.store.presentIDs.isEmpty)

        // Nothing is pending anymore; a further retry is an explicit rejection.
        let again = await room.feature.retryPendingCleanup()
        #expect(failedMessage(again) != nil)
        #expect(room.feature.lastFailure?.category == .noPendingCleanup)
    }

    // MARK: - Recovery window: retention only while awaiting explicit retry or provider switch

    @Test("A recoverable provider failure opens the recovery window and retains audio without deletion")
    func recoverableProviderFailureOpensTheRecoveryWindow() async {
        let room = makeRoom()
        let recordingID = UUID()
        #expect(await room.feature.beginSession(recordingID: recordingID))

        let outcome = room.feature.retainAfterRecoverableProviderFailure(recordingID: recordingID)

        #expect(outcome == .retainedAwaitingExplicitRetry)
        #expect(room.feature.retainsTemporaryAudioForExplicitRecovery)
        #expect(room.feature.retainedRecordingID == recordingID)
        #expect(room.feature.activeRecordingID == nil)
        // The retained audio is exactly what the window is for: nothing is deleted.
        #expect(room.store.discardCalls.isEmpty)
        #expect(room.store.presentIDs == [recordingID])
        #expect(isFailed(room.feature))
        #expect(room.feature.lastFailure?.category == .recoverableProviderFailure)
        #expect(room.reports.reports.count == 1)
        #expect(room.reports.reports.first?.reason == .providerFailure)
        #expect(room.reports.reports.first?.cleanup == .retainedAwaitingExplicitRetry)
    }

    @Test("The recovery window closes with verified deletion when recovery is exhausted")
    func exhaustedRecoveryDeletesWithVerifiedAbsence() async {
        let room = makeRoom()
        let recordingID = UUID()
        #expect(await room.feature.beginSession(recordingID: recordingID))
        _ = room.feature.retainAfterRecoverableProviderFailure(recordingID: recordingID)

        let outcome = await room.feature.resolveExhaustedRecovery()

        #expect(outcome == .verifiedAbsence)
        #expect(room.feature.retainsTemporaryAudioForExplicitRecovery == false)
        #expect(room.feature.retainedRecordingID == nil)
        #expect(room.feature.audioRemovalVerified)
        #expect(room.store.presentIDs.isEmpty)
        #expect(room.store.discardCalls == [recordingID])
        #expect(room.feature.isAudioLifecycleClear)

        // With no window open, a second resolution is an explicit rejection.
        let again = await room.feature.resolveExhaustedRecovery()
        #expect(failedMessage(again) != nil)
        #expect(room.feature.lastFailure?.category == .recoveryWindowNotOpen)
    }

    @Test("An explicit retry resumes the retained session without deleting the audio")
    func explicitRetryResumesRetainedSessionWithoutDeletion() async {
        let room = makeRoom()
        let recordingID = UUID()
        #expect(await room.feature.beginSession(recordingID: recordingID))
        _ = room.feature.retainAfterRecoverableProviderFailure(recordingID: recordingID)

        #expect(room.feature.resumeRetainedSessionForExplicitRetry())

        // The retry needs the audio: it stays and the session is active again.
        #expect(room.feature.activeRecordingID == recordingID)
        #expect(room.feature.retainedRecordingID == nil)
        #expect(room.feature.retainsTemporaryAudioForExplicitRecovery == false)
        #expect(room.store.presentIDs == [recordingID])
        #expect(room.store.discardCalls.isEmpty)
        #expect(room.feature.state == .active(recordingID))

        // The retry's own terminal outcome now deletes with verified absence.
        let outcome = await room.feature.acceptSuccess(recordingID: recordingID)
        #expect(outcome == .verifiedAbsence)
        #expect(room.store.presentIDs.isEmpty)
    }

    @Test("Unrecoverable malformed audio deletes immediately and reports the malformed reason")
    func unrecoverableMalformedAudioDeletesImmediately() async {
        let room = makeRoom()
        let recordingID = UUID()
        #expect(await room.feature.beginSession(recordingID: recordingID))

        let outcome = await room.feature.discardUnrecoverableMalformedAudio(recordingID: recordingID)

        #expect(outcome == .verifiedAbsence)
        #expect(room.store.presentIDs.isEmpty)
        #expect(room.feature.audioRemovalVerified)
        #expect(room.feature.retainsTemporaryAudioForExplicitRecovery == false)
        #expect(room.reports.reports.count == 1)
        #expect(room.reports.reports.first?.reason == .malformedAudio)
        #expect(room.reports.reports.first?.cleanup == .verifiedAbsence)
        // The recording failed as malformed; the cleanup itself was verified.
        #expect(room.feature.lastFailure?.category == .unrecoverableMalformedAudio)
        #expect(room.feature.isAudioLifecycleClear)
    }

    @Test("A new recording session supersedes the retained recovery window with verified deletion")
    func newSessionSupersedesTheRecoveryWindow() async {
        let room = makeRoom()
        let firstID = UUID()
        #expect(await room.feature.beginSession(recordingID: firstID))
        _ = room.feature.retainAfterRecoverableProviderFailure(recordingID: firstID)

        let secondID = UUID()
        #expect(await room.feature.beginSession(recordingID: secondID))

        // The superseded audio was deleted and verified before the new session
        // prepared its own storage; the purge ran before the new prepare.
        #expect(room.store.discardCalls == [firstID])
        #expect(room.store.presentIDs == [secondID])
        // First session: purge then prepare. Supersede: discard before the
        // second session's purge and prepare, in that exact order.
        #expect(room.store.recordedEvents == ["purge", "prepare", "discard", "purge", "prepare"])
        #expect(room.feature.retainsTemporaryAudioForExplicitRecovery == false)
        #expect(room.feature.activeRecordingID == secondID)
        #expect(room.feature.state == .active(secondID))
    }

    @Test("When the superseding cleanup fails, the new session does not start and stays retryable")
    func supersedingCleanupFailureBlocksTheNewSession() async {
        let room = makeRoom()
        let firstID = UUID()
        #expect(await room.feature.beginSession(recordingID: firstID))
        _ = room.feature.retainAfterRecoverableProviderFailure(recordingID: firstID)
        room.store.discardFailuresRemaining = .max

        let started = await room.feature.beginSession(recordingID: UUID())

        #expect(started == false)
        #expect(room.store.prepareCalls == [firstID])
        #expect(room.feature.activeRecordingID == nil)
        #expect(room.feature.pendingCleanupRecordingID == firstID)
        #expect(room.feature.retainsTemporaryAudioForExplicitRecovery == false)
        #expect(room.feature.lastFailure?.category == .cleanupFailed(attempts: TemporaryAudioCleanupFeature.cleanupAttemptLimit))

        // The audio is still present and honestly reported; the explicit retry
        // finishes the cleanup and then the new session can start.
        #expect(room.store.presentIDs == [firstID])
        room.store.discardFailuresRemaining = 0
        let newID = UUID()
        #expect(await room.feature.beginSession(recordingID: newID))
        #expect(room.store.presentIDs == [newID])
        #expect(room.feature.state == .active(newID))
    }

    // MARK: - Save: explicit user action only

    @Test("Saving is an explicit action that moves the recording into the Recordings folder and verifies temporary absence")
    func savingIsExplicitAndMovesAudioToRecordings() async {
        let room = makeRoom()
        let recordingID = UUID()
        #expect(await room.feature.beginSession(recordingID: recordingID))

        let saved = await room.feature.saveRecordingExplicitly(recordingID: recordingID, fileExtension: "caf")

        #expect(saved)
        #expect(room.store.saveCalls == [recordingID])
        #expect(room.store.savedIDs == [recordingID])
        #expect(room.store.presentIDs.isEmpty)
        #expect(room.feature.savedRecordingURL != nil)
        #expect(room.feature.audioRemovalVerified)
        #expect(room.feature.state == .succeeded)
        #expect(room.feature.isAudioLifecycleClear)
    }

    @Test("A failed save leaves the temporary audio untouched, is reported honestly, and never claims removal")
    func failedSaveLeavesAudioUntouched() async {
        let room = makeRoom()
        let recordingID = UUID()
        #expect(await room.feature.beginSession(recordingID: recordingID))
        room.store.saveError = FakeStoreError.saveFailed

        let saved = await room.feature.saveRecordingExplicitly(recordingID: recordingID, fileExtension: "caf")

        #expect(saved == false)
        #expect(room.feature.lastFailure?.category == .saveFailed)
        #expect(room.feature.savedRecordingURL == nil)
        // The session is restored: the audio is untouched and still active.
        #expect(room.feature.activeRecordingID == recordingID)
        #expect(room.store.presentIDs == [recordingID])
        #expect(room.store.discardCalls.isEmpty)
        #expect(room.feature.audioRemovalVerified == false)
        let message = room.feature.lastFailure?.message ?? ""
        #expect(message.contains("could not be saved"))
        #expect(message.contains("retry"))
        #expect(!message.contains("/"))
    }

    @Test("A successful save that leaves temporary storage behind never claims verified removal")
    func saveWithLeftoverTemporaryStorageNeverClaimsVerifiedRemoval() async {
        let room = makeRoom()
        let recordingID = UUID()
        #expect(await room.feature.beginSession(recordingID: recordingID))
        room.store.saveLeavesTemporaryLeftover = true
        room.store.discardFailuresRemaining = .max

        let saved = await room.feature.saveRecordingExplicitly(recordingID: recordingID, fileExtension: "caf")

        // The recording is saved, but absence is not verified and no removal
        // is claimed; the explicit retry path is open.
        #expect(saved)
        #expect(room.feature.savedRecordingURL != nil)
        #expect(room.feature.audioRemovalVerified == false)
        #expect(room.feature.pendingCleanupRecordingID == recordingID)
        #expect(room.feature.lastFailure?.category == .cleanupFailed(attempts: TemporaryAudioCleanupFeature.cleanupAttemptLimit))
        #expect(room.store.existsChecks.count == TemporaryAudioCleanupFeature.cleanupAttemptLimit)

        // The explicit retry finishes the cleanup with verified absence.
        room.store.discardFailuresRemaining = 0
        let retry = await room.feature.retryPendingCleanup()
        #expect(retry == .verifiedAbsence)
        #expect(room.feature.audioRemovalVerified)
        #expect(room.feature.pendingCleanupRecordingID == nil)
        #expect(room.feature.state == .succeeded)
        #expect(room.feature.isAudioLifecycleClear)
    }

    @Test("No path deletes or saves the audio without the matching explicit operation")
    func noUnexpectedDeletionOrSaveHappensOnOtherPaths() async {
        let room = makeRoom()
        let recordingID = UUID()
        #expect(await room.feature.beginSession(recordingID: recordingID))
        // Retention and resume never delete and never save.
        _ = room.feature.retainAfterRecoverableProviderFailure(recordingID: recordingID)
        #expect(room.feature.resumeRetainedSessionForExplicitRetry())
        #expect(room.store.discardCalls.isEmpty)
        #expect(room.store.saveCalls.isEmpty)
        #expect(room.store.presentIDs == [recordingID])

        // Cancellation deletes but never saves.
        _ = await room.feature.cancelSession(recordingID: recordingID)
        #expect(room.store.saveCalls.isEmpty)
    }

    // MARK: - Save destination seam (interactive chooser)

    @Test("The explicit save asks the injected chooser with the value-free suggested name and honors the chosen destination")
    func saveUsesInjectedDestinationChooser() async {
        let chooser = FakeSaveDestinationChooser()
        let room = makeRoom(chooser: chooser)
        let recordingID = UUID()
        #expect(await room.feature.beginSession(recordingID: recordingID, fileExtension: "wav"))
        let destination = URL(fileURLWithPath: "/fake-chosen/\(recordingID.uuidString).wav")
        chooser.scriptNext(.chosen(destination))

        let saved = await room.feature.saveRecordingExplicitly(recordingID: recordingID, fileExtension: "wav")

        // The chooser saw the locked deterministic suggested name, and the
        // chosen destination — and only it — reached the store.
        #expect(saved)
        #expect(chooser.suggestedFileNames == [
            TemporaryAudioCleanupFeature.suggestedSaveFileName(recordingID: recordingID, fileExtension: "wav")
        ])
        #expect(room.store.saveCalls == [recordingID])
        #expect(room.store.saveDestinations == [destination])
        #expect(room.feature.savedRecordingURL == destination)
        #expect(room.feature.audioRemovalVerified)
        #expect(room.feature.isAudioLifecycleClear)
    }

    @Test("A cancelled destination selection is neutral: nothing moves, nothing is claimed, and the session is untouched")
    func cancelledDestinationSelectionIsNeutral() async {
        let chooser = FakeSaveDestinationChooser()
        let room = makeRoom(chooser: chooser)
        let recordingID = UUID()
        #expect(await room.feature.beginSession(recordingID: recordingID))
        chooser.scriptNext(.cancelled)

        let saved = await room.feature.saveRecordingExplicitly(recordingID: recordingID, fileExtension: "caf")

        #expect(saved == false)
        #expect(room.store.saveCalls.isEmpty)
        #expect(room.store.saveDestinations.isEmpty)
        #expect(room.store.discardCalls.isEmpty)
        #expect(room.store.presentIDs == [recordingID])
        #expect(room.feature.activeRecordingID == recordingID)
        #expect(room.feature.savedRecordingURL == nil)
        #expect(room.feature.audioRemovalVerified == false)
        // The cancellation is a notice, never a failure, and the last valid
        // user state is unchanged.
        #expect(room.feature.lastFailure == nil)
        #expect(room.feature.lastNotice?.contains("cancelled") == true)
    }

    @Test("The store-default decision saves without an interactive destination")
    func storeDefaultDecisionSavesWithoutDestination() async {
        let chooser = FakeSaveDestinationChooser()
        let room = makeRoom(chooser: chooser)
        let recordingID = UUID()
        #expect(await room.feature.beginSession(recordingID: recordingID))

        #expect(await room.feature.saveRecordingExplicitly(recordingID: recordingID, fileExtension: "caf"))

        #expect(chooser.suggestedFileNames.count == 1)
        #expect(room.store.saveDestinations == [nil])
        #expect(room.feature.savedRecordingURL != nil)
        #expect(room.feature.audioRemovalVerified)
    }

    @Test("A cancelled save during the recovery window keeps the retained audio and the window open, and the next recording still starts")
    func cancelledSaveKeepsRecoveryWindowAndUnblocksRecording() async {
        let chooser = FakeSaveDestinationChooser()
        let room = makeRoom(chooser: chooser)
        let recordingID = UUID()
        #expect(await room.feature.beginSession(recordingID: recordingID))
        _ = room.feature.retainAfterRecoverableProviderFailure(recordingID: recordingID)
        chooser.scriptNext(.cancelled)

        let saved = await room.feature.saveRecordingExplicitly(recordingID: recordingID, fileExtension: "caf")

        // Neutral: the retained audio, the window, and every claim are
        // exactly as they were.
        #expect(saved == false)
        #expect(room.feature.retainedRecordingID == recordingID)
        #expect(room.feature.retainsTemporaryAudioForExplicitRecovery)
        #expect(room.store.presentIDs == [recordingID])
        #expect(room.store.discardCalls.isEmpty)
        #expect(room.feature.audioRemovalVerified == false)

        // Recovery unblocks recording: a new session supersedes the retained
        // audio with verified deletion and becomes active.
        let nextID = UUID()
        #expect(await room.feature.beginSession(recordingID: nextID))
        #expect(room.feature.activeRecordingID == nextID)
        #expect(room.feature.retainedRecordingID == nil)
        #expect(room.feature.retainsTemporaryAudioForExplicitRecovery == false)
        #expect(room.store.presentIDs == [nextID])
    }

    // MARK: - ACC-03: no audio persists across sessions

    @Test("Stale session audio is removed before the new session starts, and nothing is deleted before that boundary")
    func staleAudioIsPurgedBeforeTheNewSessionStarts() async {
        let room = makeRoom()
        let staleID = UUID()
        room.store.seedStaleAudio(staleID)
        let recordingID = UUID()

        #expect(await room.feature.beginSession(recordingID: recordingID))

        // The purge ran (once, before the new storage was prepared) and the
        // fresh session's own storage was not its victim.
        #expect(room.store.purgeCallCount == 1)
        #expect(room.store.recordedEvents == ["purge", "prepare"])
        #expect(room.store.staleIDs.isEmpty)
        #expect(room.store.presentIDs == [recordingID])
        #expect(room.feature.activeRecordingID == recordingID)
    }

    @Test("A purge failure blocks the new session honestly and prepares nothing")
    func purgeFailureBlocksTheNewSession() async {
        let room = makeRoom()
        room.store.purgeError = FakeStoreError.purgeFailed

        let started = await room.feature.beginSession(recordingID: UUID())

        #expect(started == false)
        #expect(room.feature.lastFailure?.category == .staleCleanupFailed)
        #expect(room.feature.activeRecordingID == nil)
        #expect(room.store.prepareCalls.isEmpty)
        #expect(room.store.recordedEvents == ["purge"])
        let message = room.feature.lastFailure?.message ?? ""
        #expect(message.contains("could not be removed"))
        #expect(message.contains("new recording was not started") || message.contains("not started"))
    }

    @Test("Beginning another session while one is active is rejected without touching anything")
    func beginWhileActiveIsRejectedUntouched() async {
        let room = makeRoom()
        let firstID = UUID()
        #expect(await room.feature.beginSession(recordingID: firstID))
        let eventsBefore = room.store.recordedEvents

        let started = await room.feature.beginSession(recordingID: UUID())

        #expect(started == false)
        #expect(room.feature.lastFailure?.category == .sessionInFlight)
        #expect(room.feature.activeRecordingID == firstID)
        #expect(room.feature.state == .active(firstID))
        #expect(room.store.recordedEvents == eventsBefore)
        #expect(room.store.presentIDs == [firstID])
    }

    // MARK: - Race safety: stale identifiers and concurrent terminal operations

    @Test("Operations with a stale recording identifier are rejected and never delete active audio")
    func staleRecordingIdentifierNeverDeletesActiveAudio() async {
        let room = makeRoom()
        let firstID = UUID()
        #expect(await room.feature.beginSession(recordingID: firstID))
        #expect(await room.feature.acceptSuccess(recordingID: firstID) == .verifiedAbsence)

        let secondID = UUID()
        #expect(await room.feature.beginSession(recordingID: secondID))
        let discardCountBefore = room.store.discardCalls.count

        // Late results addressed to the finished recording are rejected and
        // must not touch the active session's audio.
        let cancel = await room.feature.cancelSession(recordingID: firstID)
        let accept = await room.feature.acceptSuccess(recordingID: firstID)
        let discard = await room.feature.discardExplicitly(recordingID: firstID)

        #expect(failedMessage(cancel) != nil)
        #expect(failedMessage(accept) != nil)
        #expect(failedMessage(discard) != nil)
        #expect(room.feature.lastFailure?.category == .noActiveSession)
        #expect(room.store.discardCalls.count == discardCountBefore)
        #expect(room.store.presentIDs == [secondID])
        #expect(room.feature.activeRecordingID == secondID)
        #expect(room.feature.state == .active(secondID))
    }

    @Test("Concurrent terminal operations resolve exactly once with a single verified deletion")
    func concurrentTerminalOperationsResolveExactlyOnce() async {
        let room = makeRoom()
        let recordingID = UUID()
        #expect(await room.feature.beginSession(recordingID: recordingID))

        async let first = room.feature.cancelSession(recordingID: recordingID)
        async let second = room.feature.cancelSession(recordingID: recordingID)
        let outcomes = await [first, second]

        // Exactly one deletion happened; the loser saw no matching session and
        // left the result alone.
        #expect(room.store.discardCalls == [recordingID])
        #expect(outcomes.contains(.verifiedAbsence))
        #expect(outcomes.compactMap { failedMessage($0) }.count == 1)
        #expect(room.store.presentIDs.isEmpty)
        #expect(room.feature.state == .cancelled)
        #expect(room.feature.isAudioLifecycleClear)
    }

    // MARK: - Termination

    @Test("Termination deletes outstanding audio with verified absence and reports the app-termination outcome")
    func terminationDeletesOutstandingAudioAndReports() async {
        let room = makeRoom()
        let recordingID = UUID()
        #expect(await room.feature.beginSession(recordingID: recordingID))
        _ = room.feature.retainAfterRecoverableProviderFailure(recordingID: recordingID)

        await room.feature.releaseForTermination()

        #expect(room.store.presentIDs.isEmpty)
        #expect(room.feature.lastTerminationOutcome == .verifiedAbsence)
        #expect(room.feature.state == .idle)
        #expect(room.feature.activeRecordingID == nil)
        #expect(room.feature.retainedRecordingID == nil)
        #expect(room.feature.pendingCleanupRecordingID == nil)
        #expect(room.feature.retainsTemporaryAudioForExplicitRecovery == false)
        #expect(room.feature.lastFailure == nil)
        #expect(room.reports.reports.count == 2)
        #expect(room.reports.reports.last?.reason == .appTermination)
        #expect(room.reports.reports.last?.cleanup == .verifiedAbsence)
    }

    @Test("Termination with a failing cleanup reports honestly and never claims removal")
    func terminationWithFailingCleanupReportsHonestly() async {
        let room = makeRoom()
        let recordingID = UUID()
        #expect(await room.feature.beginSession(recordingID: recordingID))
        room.store.discardFailuresRemaining = .max

        await room.feature.releaseForTermination()

        guard case .failed(let message)? = room.feature.lastTerminationOutcome else {
            Issue.record("expected an honest failed termination outcome, got \(String(describing: room.feature.lastTerminationOutcome))")
            return
        }
        #expect(message.contains("could not be removed"))
        #expect(!message.contains("/"))
        #expect(room.store.presentIDs == [recordingID])
        #expect(room.feature.state == .idle)
        #expect(room.reports.reports.last?.reason == .appTermination)
        if case .failed = room.reports.reports.last?.cleanup {} else {
            Issue.record("the lifecycle report must carry the honest failure, got \(String(describing: room.reports.reports.last?.cleanup))")
        }
    }

    @Test("Termination without outstanding audio releases state silently")
    func terminationWithoutOutstandingAudioIsSilent() async {
        let room = makeRoom()
        await room.feature.releaseForTermination()
        #expect(room.feature.lastTerminationOutcome == nil)
        #expect(room.reports.reports.isEmpty)
        #expect(room.feature.state == .idle)
    }

    // MARK: - ACC-04 and real filesystem seams: the canonical placement round-trip

    @Test("The canonical placement, stale purge, save, and verified deletion round-trip through the real DataStore sandbox")
    func canonicalPlacementRoundTripsThroughTheRealDataStore() async throws {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }
        let store = sandbox.makeStore()
        let fileManager = FileManager.default

        // A previous session left stale audio behind in the sandboxed base.
        let staleID = UUID()
        _ = try await store.prepareTemporaryRecording(recordingID: staleID, fileExtension: "caf")

        // A saved recording exists only because of an explicit user action.
        let savedID = UUID()
        _ = try await store.prepareTemporaryRecording(recordingID: savedID, fileExtension: "caf")
        let savedURL = try await store.saveRecording(recordingID: savedID, fileExtension: "caf")
        #expect(fileManager.fileExists(atPath: savedURL.path))

        let reports = FakeTerminationReports()
        let feature = TemporaryAudioCleanupFeature(
            prepareTemporaryRecording: { id, ext in
                try await store.prepareTemporaryRecording(recordingID: id, fileExtension: ext)
            },
            temporaryRecordingExists: { id in
                await store.temporaryRecordingExists(recordingID: id)
            },
            discardTemporaryRecording: { id in
                try await store.discardTemporaryRecording(recordingID: id)
            },
            saveRecording: { id, ext, destination in
                try await store.saveRecording(recordingID: id, fileExtension: ext, destination: destination)
            },
            purgeStaleTemporaryRecordings: {
                try await store.purgeStaleTemporaryRecordings()
            },
            reportCaptureTermination: { reason, cleanup in reports.record(reason, cleanup) }
        )

        // A new session starts: the stale audio is gone, the saved recording
        // survives, and the fresh session's storage exists under the sandbox.
        let recordingID = UUID()
        #expect(await feature.beginSession(recordingID: recordingID))
        let staleDirectory = await store.temporaryRecordingDirectory(recordingID: staleID)
        #expect(!fileManager.fileExists(atPath: staleDirectory.path))
        #expect(fileManager.fileExists(atPath: savedURL.path))
        #expect(await store.temporaryRecordingExists(recordingID: recordingID))

        // Accepted success deletes the recording with verified absence; the
        // saved recording is still untouched afterwards.
        #expect(await feature.acceptSuccess(recordingID: recordingID) == .verifiedAbsence)
        #expect(await store.temporaryRecordingExists(recordingID: recordingID) == false)
        #expect(fileManager.fileExists(atPath: savedURL.path))
        #expect(feature.isAudioLifecycleClear)
    }
}
