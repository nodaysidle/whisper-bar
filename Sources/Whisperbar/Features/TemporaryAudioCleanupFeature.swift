import Foundation

// MARK: - TemporaryAudioCleanupFeature

/// OWN-TEMPORARY-AUDIO-CLEANUP.
///
/// Owns CON-TEMPORARY-AUDIO-CLEANUP-INTERFACE and
/// CON-TEMPORARY-AUDIO-CLEANUP-RECOVERY: microphone audio lives only in the
/// sandboxed temporary storage for the active request; accepted success,
/// explicit discard, cancellation, unrecoverable malformed audio, or
/// exhausted recovery deletes the audio and verifies absence before anything
/// is claimed. After a recoverable provider failure the audio may be retained
/// only while awaiting an explicit retry or an explicit provider switch.
/// Saved recordings survive only after an explicit user action, and stale
/// audio from earlier sessions is removed before a new session starts so no
/// audio persists across sessions.
///
/// Every operation is idle, active, succeeded, failed, or cancelled, and the
/// last valid user state is preserved on every failure: a deletion that
/// cannot be verified is never reported as cleanup, and the explicit retry
/// path re-runs the same bounded, verified cleanup.
///
/// Every filesystem boundary and the lifecycle report boundary are injected
/// seams. The default seams are deliberately inert: construction and launch
/// touch no filesystem, no temporary directory, and no live recording.
@MainActor
final class TemporaryAudioCleanupFeature: TerminationReleasing {

    /// Bounded cleanup retry: one removal operation attempts deletion and
    /// verified absence at most this many times before failing honestly.
    static let cleanupAttemptLimit = 3

    // MARK: States

    enum State: Equatable, Sendable {
        case idle
        case active(UUID)
        case succeeded
        case failed(Failure)
        case cancelled
    }

    struct Failure: Equatable, Sendable {
        /// Privacy-safe categories: no case carries audio content, file paths,
        /// recording identifiers, or provider response bodies.
        enum Category: Equatable, Sendable {
            case sessionInFlight
            case noActiveSession
            case noPendingCleanup
            case recoveryWindowNotOpen
            case recoverableProviderFailure
            case staleCleanupFailed
            case prepareFailed
            case saveFailed
            case unrecoverableMalformedAudio
            case cleanupFailed(attempts: Int)
        }

        let category: Category
        let message: String
    }

    /// The terminal intent a cleanup belongs to. It decides the state a
    /// verified cleanup converges to and which lifecycle reason is reported.
    private enum TerminalKind: Equatable {
        case acceptedSuccess
        case cancellation
        case explicitDiscard
        case unrecoverableMalformedAudio
        case exhaustedRecovery
        case postSaveVerification

        var terminalState: State {
            switch self {
            case .acceptedSuccess, .postSaveVerification:
                return .succeeded
            case .cancellation, .explicitDiscard, .exhaustedRecovery:
                return .cancelled
            case .unrecoverableMalformedAudio:
                return .failed(
                    Failure(
                        category: .unrecoverableMalformedAudio,
                        message: "The recorded audio was unrecoverable (malformed) and was deleted; absence was verified. No incomplete or partial text was kept."
                    )
                )
            }
        }

        /// Capture-termination reasons reported to the lifecycle owner; nil
        /// for paths that are not capture-termination events.
        var lifecycleReason: CaptureTerminationReason? {
            switch self {
            case .cancellation:
                return .cancelled
            case .unrecoverableMalformedAudio:
                return .malformedAudio
            case .acceptedSuccess, .explicitDiscard, .exhaustedRecovery, .postSaveVerification:
                return nil
            }
        }

        var notice: String {
            switch self {
            case .acceptedSuccess:
                return "The transcription succeeded and the temporary audio was deleted; absence was verified."
            case .cancellation:
                return "The recording was cancelled and the temporary audio was deleted; absence was verified."
            case .explicitDiscard:
                return "The recording was explicitly discarded and the temporary audio was deleted; absence was verified."
            case .unrecoverableMalformedAudio:
                return "The recorded audio was unrecoverable and was deleted; absence was verified."
            case .exhaustedRecovery:
                return "Recovery was exhausted; the retained temporary audio was deleted and absence was verified."
            case .postSaveVerification:
                return "The recording is saved and temporary storage is clear; absence was verified."
            }
        }
    }

    // MARK: Observable state

    private(set) var state: State = .idle
    private(set) var lastFailure: Failure?
    private(set) var lastNotice: String?
    /// The recording identifier of the active request, when one exists.
    private(set) var activeRecordingID: UUID?
    /// The recording identifier whose audio is retained while awaiting an
    /// explicit retry or an explicit provider switch.
    private(set) var retainedRecordingID: UUID?
    /// The recording identifier whose cleanup failed and awaits an explicit
    /// retry with verified absence.
    private(set) var pendingCleanupRecordingID: UUID?
    /// True only when the last removal operation verified absence.
    private(set) var audioRemovalVerified = false
    /// The outcome reported to the lifecycle owner by `releaseForTermination`.
    private(set) var lastTerminationOutcome: AudioCaptureCleanupOutcome?
    /// The prepared temporary location of the active session, when one exists.
    private(set) var activeTemporaryAudioURL: URL?
    /// The locked file extension prepared for the active or retained session,
    /// when one exists. The explicit save addresses the recording with it.
    private(set) var recordingFileExtension: String?
    /// Set only by an explicit user save; nothing else ever moves audio out of
    /// temporary storage.
    private(set) var savedRecordingURL: URL?
    /// True only while retained audio is permitted: after a recoverable
    /// provider failure while awaiting an explicit retry or explicit provider
    /// switch. No other path ever retains audio.
    private(set) var retainsTemporaryAudioForExplicitRecovery = false

    private var pendingCleanupKind: TerminalKind?

    /// Exactly one active recording session drives the temporary audio state.
    var isSessionActive: Bool { activeRecordingID != nil }

    /// True when no session, retention window, or pending cleanup remains:
    /// no temporary audio is tracked anywhere.
    var isAudioLifecycleClear: Bool {
        activeRecordingID == nil && retainedRecordingID == nil && pendingCleanupRecordingID == nil
    }

    // MARK: Save destination vocabulary

    /// The outcome of the explicit save-destination selection. The explicit
    /// user save never guesses a destination: production asks the native save
    /// panel through the injected chooser seam, tests inject a deterministic
    /// fake, and the inert default keeps the store's documented placement so
    /// construction and launch present nothing.
    enum SaveDestinationDecision: Equatable, Sendable {
        /// No destination chooser is wired: the store's documented saved
        /// recordings placement is used.
        case storeDefault
        /// The user chose this exact destination for the recording.
        case chosen(URL)
        /// The user cancelled the destination selection: nothing moves.
        case cancelled
    }

    /// The value-free suggested file name of one recording: the locked
    /// deterministic identifier plus its extension, exactly as the store
    /// places the file. The user may change it in the native panel.
    static func suggestedSaveFileName(recordingID: UUID, fileExtension: String) -> String {
        "\(recordingID.uuidString).\(fileExtension)"
    }

    // MARK: Dependencies (injected filesystem and lifecycle seams)

    private let prepareTemporaryRecording: @MainActor (UUID, String) async throws -> URL
    private let temporaryRecordingExists: @MainActor (UUID) async -> Bool
    private let discardTemporaryRecording: @MainActor (UUID) async throws -> Bool
    private let saveRecording: @MainActor (UUID, String, URL?) async throws -> URL
    private let chooseSaveDestination: @MainActor (String) async -> SaveDestinationDecision
    private let purgeStaleTemporaryRecordings: @MainActor () async throws -> Int
    private let reportCaptureTermination: @MainActor (CaptureTerminationReason, AudioCaptureCleanupOutcome) -> Void

    init(
        prepareTemporaryRecording: @escaping @MainActor (UUID, String) async throws -> URL = { id, _ in
            // Deliberately inert default: pure URL composition, no filesystem.
            FileManager.default.temporaryDirectory
                .appendingPathComponent(AppIdentity.temporaryDirectoryName, isDirectory: true)
                .appendingPathComponent(id.uuidString, isDirectory: true)
        },
        temporaryRecordingExists: @escaping @MainActor (UUID) async -> Bool = { _ in false },
        discardTemporaryRecording: @escaping @MainActor (UUID) async throws -> Bool = { _ in false },
        saveRecording: @escaping @MainActor (UUID, String, URL?) async throws -> URL = { _, _, _ in
            throw DataStoreError.fileOperationFailed("no recording store is wired")
        },
        chooseSaveDestination: @escaping @MainActor (String) async -> SaveDestinationDecision = { _ in .storeDefault },
        purgeStaleTemporaryRecordings: @escaping @MainActor () async throws -> Int = { 0 },
        reportCaptureTermination: @escaping @MainActor (CaptureTerminationReason, AudioCaptureCleanupOutcome) -> Void = { _, _ in }
    ) {
        self.prepareTemporaryRecording = prepareTemporaryRecording
        self.temporaryRecordingExists = temporaryRecordingExists
        self.discardTemporaryRecording = discardTemporaryRecording
        self.saveRecording = saveRecording
        self.chooseSaveDestination = chooseSaveDestination
        self.purgeStaleTemporaryRecordings = purgeStaleTemporaryRecordings
        self.reportCaptureTermination = reportCaptureTermination
    }

    // MARK: Session lifecycle (CON-TEMPORARY-AUDIO-CLEANUP-INTERFACE)

    /// Starts one user-initiated recording session: closes any outstanding
    /// lifecycle from a previous request (retention window or pending
    /// cleanup) with verified deletion, removes stale audio from earlier
    /// sessions, and prepares the sandboxed temporary storage for this
    /// recording. Nothing about a new session starts while audio from an
    /// earlier one still exists.
    @discardableResult
    func beginSession(recordingID: UUID, fileExtension: String = "caf") async -> Bool {
        guard activeRecordingID == nil else {
            reject(.sessionInFlight)
            return false
        }
        // A new explicit recording start ends the previous request's recovery
        // window or finishes its pending cleanup; either way the audio is
        // deleted and its absence verified before anything new begins.
        if let outstanding = retainedRecordingID ?? pendingCleanupRecordingID {
            let result = await attemptVerifiedRemoval(recordingID: outstanding)
            guard result.verified else {
                if retainedRecordingID == outstanding { pendingCleanupKind = .exhaustedRecovery }
                retainedRecordingID = nil
                retainsTemporaryAudioForExplicitRecovery = false
                pendingCleanupRecordingID = outstanding
                audioRemovalVerified = false
                fail(.cleanupFailed(attempts: result.attempts))
                return false
            }
            retainedRecordingID = nil
            retainsTemporaryAudioForExplicitRecovery = false
            pendingCleanupRecordingID = nil
            pendingCleanupKind = nil
            audioRemovalVerified = true
        }
        // Session-start invariant: no audio persists across sessions.
        do {
            _ = try await purgeStaleTemporaryRecordings()
        } catch {
            fail(.staleCleanupFailed)
            return false
        }
        do {
            activeTemporaryAudioURL = try await prepareTemporaryRecording(recordingID, fileExtension)
        } catch {
            fail(.prepareFailed)
            return false
        }
        activeRecordingID = recordingID
        recordingFileExtension = fileExtension
        savedRecordingURL = nil
        lastFailure = nil
        lastNotice = "Temporary audio storage for this recording is ready. The audio is deleted with verified absence after success, cancellation, explicit discard, unrecoverable failure, or exhausted recovery; it is retained only while awaiting an explicit retry or an explicit provider switch."
        state = .active(recordingID)
        return true
    }

    // MARK: Terminal paths (delete + verify absence before any claim)

    /// The transcription succeeded. The temporary audio is deleted and its
    /// absence verified before cleanup is claimed (ACC-01).
    @discardableResult
    func acceptSuccess(recordingID: UUID) async -> AudioCaptureCleanupOutcome {
        guard activeRecordingID == recordingID else {
            return rejectOutcome(.noActiveSession)
        }
        claimActiveSession()
        return await finalize(recordingID: recordingID, kind: .acceptedSuccess)
    }

    /// The recording was cancelled. The temporary audio is deleted and its
    /// absence verified (ACC-01), and the outcome is reported to the
    /// lifecycle owner.
    @discardableResult
    func cancelSession(recordingID: UUID) async -> AudioCaptureCleanupOutcome {
        guard activeRecordingID == recordingID else {
            return rejectOutcome(.noActiveSession)
        }
        claimActiveSession()
        return await finalize(recordingID: recordingID, kind: .cancellation)
    }

    /// Explicit user discard: the audio is deleted with verified absence,
    /// whether it belongs to the active session or to an open retention
    /// window.
    @discardableResult
    func discardExplicitly(recordingID: UUID) async -> AudioCaptureCleanupOutcome {
        if activeRecordingID == recordingID {
            claimActiveSession()
        } else if retainedRecordingID == recordingID {
            retainedRecordingID = nil
            retainsTemporaryAudioForExplicitRecovery = false
        } else {
            return rejectOutcome(.noActiveSession)
        }
        return await finalize(recordingID: recordingID, kind: .explicitDiscard)
    }

    /// The recorded audio is unrecoverable (malformed). It is deleted
    /// immediately with verified absence and the malformed reason is reported
    /// to the lifecycle owner; no retention window opens.
    @discardableResult
    func discardUnrecoverableMalformedAudio(recordingID: UUID) async -> AudioCaptureCleanupOutcome {
        guard activeRecordingID == recordingID else {
            return rejectOutcome(.noActiveSession)
        }
        claimActiveSession()
        return await finalize(recordingID: recordingID, kind: .unrecoverableMalformedAudio)
    }

    // MARK: Recovery window (retention only for explicit retry or provider switch)

    /// A recoverable provider failure: the temporary audio is retained — and
    /// only for this reason — while awaiting an explicit retry or an explicit
    /// provider switch. Nothing is deleted here and no other path ever
    /// retains audio.
    @discardableResult
    func retainAfterRecoverableProviderFailure(recordingID: UUID) -> AudioCaptureCleanupOutcome {
        guard activeRecordingID == recordingID else {
            return rejectOutcome(.noActiveSession)
        }
        activeRecordingID = nil
        activeTemporaryAudioURL = nil
        retainedRecordingID = recordingID
        retainsTemporaryAudioForExplicitRecovery = true
        let failure = Failure(
            category: .recoverableProviderFailure,
            message: Self.message(for: .recoverableProviderFailure)
        )
        lastFailure = failure
        state = .failed(failure)
        let outcome = AudioCaptureCleanupOutcome.retainedAwaitingExplicitRetry
        reportCaptureTermination(.providerFailure, outcome)
        return outcome
    }

    /// The explicit retry began: the retained session becomes the active
    /// request again and its audio stays exactly until the retry's own
    /// terminal outcome deletes it with verified absence.
    @discardableResult
    func resumeRetainedSessionForExplicitRetry() -> Bool {
        guard retainsTemporaryAudioForExplicitRecovery,
              let retained = retainedRecordingID,
              activeRecordingID == nil else {
            reject(.recoveryWindowNotOpen)
            return false
        }
        retainedRecordingID = nil
        retainsTemporaryAudioForExplicitRecovery = false
        activeRecordingID = retained
        lastFailure = nil
        lastNotice = "The explicit retry is running with the retained audio; the audio is deleted with verified absence on the retry's terminal outcome."
        state = .active(retained)
        return true
    }

    /// Recovery is exhausted (the user neither retried nor switched): the
    /// retained audio is deleted with verified absence and the window closes.
    @discardableResult
    func resolveExhaustedRecovery() async -> AudioCaptureCleanupOutcome {
        guard retainsTemporaryAudioForExplicitRecovery, let retained = retainedRecordingID else {
            return rejectOutcome(.recoveryWindowNotOpen)
        }
        retainedRecordingID = nil
        retainsTemporaryAudioForExplicitRecovery = false
        let result = await attemptVerifiedRemoval(recordingID: retained)
        if result.verified {
            audioRemovalVerified = true
            pendingCleanupRecordingID = nil
            pendingCleanupKind = nil
            lastFailure = nil
            lastNotice = TerminalKind.exhaustedRecovery.notice
            state = TerminalKind.exhaustedRecovery.terminalState
            return .verifiedAbsence
        }
        audioRemovalVerified = false
        pendingCleanupRecordingID = retained
        pendingCleanupKind = .exhaustedRecovery
        let failure = Failure(
            category: .cleanupFailed(attempts: result.attempts),
            message: Self.message(for: .cleanupFailed(attempts: result.attempts))
        )
        lastFailure = failure
        state = .failed(failure)
        return .failed(privacySafeMessage: failure.message)
    }

    // MARK: Explicit cleanup retry (CON-TEMPORARY-AUDIO-CLEANUP-RECOVERY)

    /// The explicit user retry of a cleanup that could not verify absence.
    /// The same bounded cleanup runs again; success is claimed only when
    /// absence is actually verified.
    @discardableResult
    func retryPendingCleanup() async -> AudioCaptureCleanupOutcome {
        guard let recordingID = pendingCleanupRecordingID, let kind = pendingCleanupKind else {
            return rejectOutcome(.noPendingCleanup)
        }
        pendingCleanupRecordingID = nil
        pendingCleanupKind = nil
        return await finalize(recordingID: recordingID, kind: kind)
    }

    // MARK: Save (explicit user action only)

    /// The explicit user save: the recording moves to the destination the user
    /// chose through the injected chooser seam (or to the store's documented
    /// placement when no chooser is wired), and temporary storage is verified
    /// clear afterwards. This is the only path that ever moves audio out of
    /// temporary storage; a cancelled destination selection and a failed save
    /// both leave the audio and the session untouched and claim nothing.
    @discardableResult
    func saveRecordingExplicitly(recordingID: UUID, fileExtension: String) async -> Bool {
        guard activeRecordingID == recordingID || retainedRecordingID == recordingID else {
            reject(.noActiveSession)
            return false
        }
        // The destination is chosen first: a cancelled selection changes
        // nothing at all and no removal is claimed.
        let decision = await chooseSaveDestination(
            Self.suggestedSaveFileName(recordingID: recordingID, fileExtension: fileExtension)
        )
        let destination: URL?
        switch decision {
        case .storeDefault:
            destination = nil
        case .chosen(let chosen):
            destination = chosen
        case .cancelled:
            lastNotice = "The save was cancelled; the temporary audio is unchanged and no removal is claimed."
            return false
        }
        // Re-verify after the suspension: a concurrent terminal operation may
        // have ended the session while the destination was being selected.
        let wasActive = activeRecordingID == recordingID
        let wasRetained = retainedRecordingID == recordingID
        guard wasActive || wasRetained else {
            reject(.noActiveSession)
            return false
        }
        if wasActive {
            claimActiveSession()
        } else {
            retainedRecordingID = nil
            retainsTemporaryAudioForExplicitRecovery = false
        }
        do {
            let url = try await saveRecording(recordingID, fileExtension, destination)
            savedRecordingURL = url
            // The explicit action must leave no recording in temporary storage.
            let result = await attemptVerifiedRemoval(recordingID: recordingID)
            if result.verified {
                audioRemovalVerified = true
                pendingCleanupRecordingID = nil
                pendingCleanupKind = nil
                lastFailure = nil
                lastNotice = TerminalKind.postSaveVerification.notice
                state = .succeeded
            } else {
                audioRemovalVerified = false
                pendingCleanupRecordingID = recordingID
                pendingCleanupKind = .postSaveVerification
                let failure = Failure(
                    category: .cleanupFailed(attempts: result.attempts),
                    message: Self.message(for: .cleanupFailed(attempts: result.attempts))
                )
                lastFailure = failure
                lastNotice = "The recording is saved to the Recordings folder, but temporary storage cleanup is still pending; no removal is claimed yet. Retry cleanup explicitly."
                state = .succeeded
            }
            return true
        } catch {
            // Restore the last valid user state: the session is unchanged and
            // the audio is untouched.
            if wasActive {
                activeRecordingID = recordingID
            } else {
                retainedRecordingID = recordingID
                retainsTemporaryAudioForExplicitRecovery = true
            }
            fail(.saveFailed)
            return false
        }
    }

    // MARK: Termination

    /// CON-LIFECYCLE-APPLICATION-TERMINATION / CON-LIFECYCLE-AUDIO-CAPTURE-TERMINATION:
    /// delete any outstanding temporary audio (active, retained, or pending)
    /// with verified absence, report the outcome to the lifecycle owner with
    /// the app-termination reason, and release every runtime field so nothing
    /// outlives the process. A failed cleanup is reported honestly and never
    /// claimed as removal.
    func releaseForTermination() async {
        let outstanding = activeRecordingID ?? retainedRecordingID ?? pendingCleanupRecordingID
        var outcome: AudioCaptureCleanupOutcome?
        if let outstanding {
            let result = await attemptVerifiedRemoval(recordingID: outstanding)
            let removalOutcome = result.verified
                ? AudioCaptureCleanupOutcome.verifiedAbsence
                : AudioCaptureCleanupOutcome.failed(
                    privacySafeMessage: Self.message(for: .cleanupFailed(attempts: result.attempts))
                )
            audioRemovalVerified = result.verified
            outcome = removalOutcome
            reportCaptureTermination(.appTermination, removalOutcome)
        }
        activeRecordingID = nil
        retainedRecordingID = nil
        pendingCleanupRecordingID = nil
        pendingCleanupKind = nil
        retainsTemporaryAudioForExplicitRecovery = false
        activeTemporaryAudioURL = nil
        recordingFileExtension = nil
        savedRecordingURL = nil
        lastFailure = nil
        lastNotice = nil
        state = .idle
        lastTerminationOutcome = outcome
    }

    // MARK: Internals

    /// Removes the recording's temporary storage and verifies absence, for
    /// at most `cleanupAttemptLimit` bounded attempts. Absence is the only
    /// proof of cleanup: a throwing or "successful" delete that leaves the
    /// audio behind never counts as removal.
    private func attemptVerifiedRemoval(recordingID: UUID) async -> (verified: Bool, attempts: Int) {
        var attempts = 0
        while attempts < Self.cleanupAttemptLimit {
            attempts += 1
            do {
                _ = try await discardTemporaryRecording(recordingID)
            } catch {
                // The verification below re-checks; a throwing delete is not
                // removal.
            }
            if await temporaryRecordingExists(recordingID) == false {
                return (true, attempts)
            }
        }
        return (false, attempts)
    }

    /// Runs one terminal cleanup: bounded, verified, and honest. Success
    /// converges to the terminal state and claims verified absence; failure
    /// keeps the operation incomplete, records the exact category, and opens
    /// the explicit cleanup-retry path without claiming anything was removed.
    private func finalize(recordingID: UUID, kind: TerminalKind) async -> AudioCaptureCleanupOutcome {
        let result = await attemptVerifiedRemoval(recordingID: recordingID)
        if result.verified {
            pendingCleanupRecordingID = nil
            pendingCleanupKind = nil
            audioRemovalVerified = true
            state = kind.terminalState
            if case .failed(let failure) = state {
                lastFailure = failure
            } else {
                lastFailure = nil
            }
            lastNotice = kind.notice
            let outcome = AudioCaptureCleanupOutcome.verifiedAbsence
            if let reason = kind.lifecycleReason {
                reportCaptureTermination(reason, outcome)
            }
            return outcome
        }
        audioRemovalVerified = false
        pendingCleanupRecordingID = recordingID
        pendingCleanupKind = kind
        let failure = Failure(
            category: .cleanupFailed(attempts: result.attempts),
            message: Self.message(for: .cleanupFailed(attempts: result.attempts))
        )
        lastFailure = failure
        state = .failed(failure)
        let outcome = AudioCaptureCleanupOutcome.failed(privacySafeMessage: failure.message)
        if let reason = kind.lifecycleReason {
            reportCaptureTermination(reason, outcome)
        }
        return outcome
    }

    /// Claims the active session synchronously, before any suspension, so a
    /// concurrent or stale terminal operation can never double-delete or
    /// delete a later session's audio.
    private func claimActiveSession() {
        activeRecordingID = nil
        activeTemporaryAudioURL = nil
        retainsTemporaryAudioForExplicitRecovery = false
    }

    /// A rejected attempt preserves the last valid state and records only the
    /// privacy-safe failure.
    @discardableResult
    private func reject(_ category: Failure.Category) -> Failure {
        let failure = Failure(category: category, message: Self.message(for: category))
        lastFailure = failure
        return failure
    }

    private func rejectOutcome(_ category: Failure.Category) -> AudioCaptureCleanupOutcome {
        let failure = reject(category)
        return .failed(privacySafeMessage: failure.message)
    }

    /// A failed user-initiated attempt becomes its own terminal failed state.
    @discardableResult
    private func fail(_ category: Failure.Category) -> Failure {
        let failure = Failure(category: category, message: Self.message(for: category))
        lastFailure = failure
        state = .failed(failure)
        return failure
    }

    // MARK: Privacy-safe messages

    private static func message(for category: Failure.Category) -> String {
        switch category {
        case .sessionInFlight:
            return "A recording session is already active; it is unchanged and a new one was not started."
        case .noActiveSession:
            return "No matching temporary recording session exists, so nothing was changed and no audio was deleted."
        case .noPendingCleanup:
            return "No temporary audio cleanup is pending, so nothing was changed."
        case .recoveryWindowNotOpen:
            return "No recoverable provider failure is awaiting an explicit retry or an explicit provider switch, so nothing was changed."
        case .recoverableProviderFailure:
            return "The provider request failed recoverably. The temporary audio is retained only while awaiting your explicit retry or an explicit provider switch; no other reason keeps it."
        case .staleCleanupFailed:
            return "Audio from an earlier session could not be removed, so a new recording was not started. No removal is claimed; retry explicitly."
        case .prepareFailed:
            return "Temporary recording storage could not be prepared, so the recording did not start. Nothing was written; retry explicitly."
        case .saveFailed:
            return "The recording could not be saved to the Recordings folder; the temporary audio is unchanged and no removal is claimed; retry explicitly."
        case .unrecoverableMalformedAudio:
            return "The recorded audio was unrecoverable (malformed) and was deleted; absence was verified. No incomplete or partial text was kept."
        case .cleanupFailed(let attempts):
            return "The temporary audio could not be removed and its absence verified after \(attempts) attempts. No removal is claimed; retry cleanup explicitly."
        }
    }
}
