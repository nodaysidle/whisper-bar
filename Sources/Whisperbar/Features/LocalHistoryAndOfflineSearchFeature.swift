import AppKit
import Foundation

// MARK: - Clipboard seam (CON-PERMISSION-CLIPBOARD)

/// The minimal clipboard seam of the local-history feature: exactly one
/// explicit write of one complete transcript. The production implementation
/// touches NSPasteboard only inside `writeString(_:)`, never during
/// construction or launch, so no clipboard content is read, snapshotted, or
/// changed until an explicit user copy action. Tests inject an in-memory fake
/// so no live clipboard is touched.
protocol HistoryClipboardWriting: Sendable {
    /// Writes one complete transcript; returns whether the write succeeded.
    func writeString(_ text: String) -> Bool
}

/// Live NSPasteboard writer for explicit copy actions only. The copy action is
/// a single, complete overwrite by explicit user intent; nothing is read back
/// and nothing is restored automatically.
struct SystemClipboardWriter: HistoryClipboardWriting {
    func writeString(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}

// MARK: - LocalHistoryAndOfflineSearchFeature

/// OWN-LOCAL-HISTORY-AND-OFFLINE-SEARCH.
///
/// Owns CON-LOCAL-HISTORY-AND-OFFLINE-SEARCH-INTERFACE and
/// CON-LOCAL-HISTORY-AND-OFFLINE-SEARCH-RECOVERY: transcripts are stored in
/// bounded local storage (the shared DataStore) with offline full-text search,
/// atomic copy, and atomic deletion. No transcript is ever uploaded or synced
/// to an external cloud; the only external surface is the explicit user copy
/// action, gated by the CON-PERMISSION-CLIPBOARD availability seam.
///
/// Failure behavior: if local storage is unavailable, history is disabled, the
/// user is notified, and the last valid list stays visible; transcription
/// still works. Recovery is an explicit user retry (`retry()`), which re-reads
/// local storage once and never falls back to a remote service.
@MainActor
final class LocalHistoryAndOfflineSearchFeature: TerminationReleasing {

    // MARK: Contract marker

    /// Contract marker: transcripts are never uploaded or synced to external
    /// clouds. Asserted by the focused tests.
    static let syncsToExternalServices = false

    // MARK: States

    enum State: Equatable, Sendable {
        case idle
        case active
        case succeeded
        case failed(Failure)
        case cancelled
    }

    struct Failure: Equatable, Sendable {
        enum Category: Equatable, Sendable {
            case storageUnavailable
            case invalidRecord
            case recordNotFound
            case copyFailed
            case clipboardUnavailable
            case deleteFailed
        }

        let category: Category
        let message: String
    }

    enum Action: Equatable, Sendable {
        case transcriptSaved(id: String)
        case transcriptCopied(id: String)
        case transcriptDeleted(id: String)
        case searched(query: String, resultCount: Int)
    }

    // MARK: Observable state

    private(set) var state: State = .idle
    /// The bounded, newest-first transcript list currently presented. On any
    /// failure the last valid list stays visible.
    private(set) var transcripts: [TranscriptRecord] = []
    private(set) var lastFailure: Failure?
    private(set) var lastNotice: String?
    private(set) var lastAction: Action?
    /// Storage-backed history is usable. Unavailable storage disables history
    /// and reports honestly instead of pretending to work.
    private(set) var isHistoryEnabled = false

    // MARK: Dependencies

    private let dataStore: DataStore
    private let clipboard: HistoryClipboardWriting
    private let clipboardAvailability: @MainActor () -> PermissionState
    private let now: @Sendable () -> Date

    init(
        dataStore: DataStore,
        clipboard: HistoryClipboardWriting,
        clipboardAvailability: @escaping @MainActor () -> PermissionState,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.dataStore = dataStore
        self.clipboard = clipboard
        self.clipboardAvailability = clipboardAvailability
        self.now = now
    }

    // MARK: Load and explicit retry

    /// Loads the bounded recent history. Preset-owned state only: nothing is
    /// uploaded, copied, or deleted here.
    @discardableResult
    func load() async -> Bool {
        state = .active
        guard await dataStore.availability.isAvailable else {
            return failStorageUnavailable()
        }
        do {
            let records = try await dataStore.recentTranscripts()
            transcripts = records
            lastFailure = nil
            lastNotice = "Local history loaded."
            isHistoryEnabled = true
            state = .succeeded
            return true
        } catch {
            return failStorageUnavailable()
        }
    }

    /// The explicit user retry required by the recovery contract. It re-reads
    /// local storage once; it never falls back to a remote service.
    @discardableResult
    func retry() async -> Bool {
        await load()
    }

    // MARK: Save (CON-DATA-TRANSCRIPT, CON-PERSISTENCE-TRANSCRIPT)

    /// Saves one complete transcript after an explicit transcription or
    /// refinement success. Empty or incomplete text is never saved, and the
    /// last valid history is preserved on every failure.
    @discardableResult
    func saveTranscript(text: String, provider: TranscriptionProviderID) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            fail(
                .invalidRecord,
                message: "Empty, blank, or incomplete text is never saved to local history; the last valid history is preserved."
            )
            return false
        }
        state = .active
        guard await dataStore.availability.isAvailable else {
            return failStorageUnavailable()
        }
        let record = TranscriptRecord(
            id: UUID().uuidString,
            text: text,
            createdAt: now(),
            provider: provider
        )
        do {
            try await dataStore.insertTranscript(record)
            transcripts = try await dataStore.recentTranscripts()
        } catch DataStoreError.invalidRecord {
            fail(
                .invalidRecord,
                message: "Empty, blank, or incomplete text is never saved to local history; the last valid history is preserved."
            )
            return false
        } catch {
            return failStorageUnavailable()
        }
        lastFailure = nil
        lastNotice = "Transcript saved to local history."
        lastAction = .transcriptSaved(id: record.id)
        isHistoryEnabled = true
        state = .succeeded
        return true
    }

    // MARK: Copy (atomic, explicit user action only)

    /// Explicit user copy: writes the complete transcript to the clipboard in
    /// one atomic action. It never touches storage, and a denied or failed
    /// write keeps the transcript visible for the documented manual path.
    @discardableResult
    func copy(id: String) -> Bool {
        guard let record = transcripts.first(where: { $0.id == id }) else {
            fail(.recordNotFound, message: "That transcript is not in local history; nothing was copied.")
            return false
        }
        guard clipboardAvailability() == .authorized else {
            fail(
                .clipboardUnavailable,
                message: "The clipboard is unavailable right now, so the transcript was not copied. It stays visible for manual copy."
            )
            return false
        }
        guard clipboard.writeString(record.text) else {
            fail(
                .copyFailed,
                message: "The clipboard write failed; the transcript stays visible for manual copy and local history is unchanged."
            )
            return false
        }
        lastFailure = nil
        lastNotice = "Copied the complete transcript to the clipboard."
        lastAction = .transcriptCopied(id: id)
        state = .succeeded
        return true
    }

    // MARK: Delete (atomic, verified)

    /// Explicit user delete: removes the record, verifies its absence against
    /// durable state, and keeps the presented list honest. A missing record is
    /// rejected without side effects; unavailable storage disables history and
    /// reports honestly.
    @discardableResult
    func delete(id: String) async -> Bool {
        state = .active
        guard await dataStore.availability.isAvailable else {
            return failStorageUnavailable()
        }
        guard transcripts.contains(where: { $0.id == id }) else {
            fail(.recordNotFound, message: "That transcript is not in local history; nothing was deleted.")
            return false
        }
        do {
            let existed = try await dataStore.deleteTranscript(id: id)
            guard existed else {
                fail(.recordNotFound, message: "That transcript is not in local history; nothing was deleted.")
                return false
            }
            // Verify absence against durable state before reporting success.
            let remaining = try await dataStore.recentTranscripts()
            guard !remaining.contains(where: { $0.id == id }) else {
                fail(
                    .deleteFailed,
                    message: "The deletion could not be confirmed, so local history is unchanged. Retry explicitly."
                )
                return false
            }
            transcripts = remaining
        } catch {
            return failStorageUnavailable()
        }
        lastFailure = nil
        lastNotice = "Deleted the transcript from local history."
        lastAction = .transcriptDeleted(id: id)
        isHistoryEnabled = true
        state = .succeeded
        return true
    }

    // MARK: Offline search

    /// Offline full-text search through local storage only. FTS operators and
    /// unmatched quotes in the query are treated as literal text (the DataStore
    /// quotes every term), and an empty query returns the bounded recent list
    /// again. A search failure preserves the last valid list.
    @discardableResult
    func search(_ query: String) async -> Bool {
        state = .active
        guard await dataStore.availability.isAvailable else {
            return failStorageUnavailable()
        }
        do {
            let results = try await dataStore.searchTranscripts(query: query)
            transcripts = results
            lastFailure = nil
            lastNotice = "Search complete."
            lastAction = .searched(query: query, resultCount: results.count)
            isHistoryEnabled = true
            state = .succeeded
            return true
        } catch {
            return failStorageUnavailable()
        }
    }

    // MARK: Termination

    /// CON-LIFECYCLE-APPLICATION-TERMINATION: nothing privileged (streams, file
    /// handles, delegates, temporary audio) is held by this feature; it only
    /// releases its presentation state so no operation stays active.
    func releaseForTermination() async {
        state = .idle
    }

    // MARK: Failure bookkeeping

    @discardableResult
    private func fail(_ category: Failure.Category, message: String? = nil) -> Bool {
        let failure = Failure(category: category, message: message ?? Self.message(for: category))
        lastFailure = failure
        state = .failed(failure)
        return false
    }

    /// Unavailable storage disables history, explains the failure, and keeps
    /// the last valid list; transcription still works.
    @discardableResult
    private func failStorageUnavailable() -> Bool {
        isHistoryEnabled = false
        return fail(.storageUnavailable)
    }

    // MARK: Privacy-safe messages

    private static func message(for category: Failure.Category) -> String {
        switch category {
        case .storageUnavailable:
            return "Local history storage is unavailable, so history is disabled, and the last valid list stays visible. Transcription still works; retry explicitly when storage is available."
        case .invalidRecord:
            return "Empty, blank, or incomplete text is never saved to local history; the last valid history is preserved."
        case .recordNotFound:
            return "That transcript is not in local history; nothing was changed."
        case .copyFailed:
            return "The clipboard write failed; the transcript stays visible for manual copy and local history is unchanged."
        case .clipboardUnavailable:
            return "The clipboard is unavailable right now, so the transcript was not copied. It stays visible for manual copy."
        case .deleteFailed:
            return "The deletion could not be confirmed, so local history is unchanged. Retry explicitly."
        }
    }
}
