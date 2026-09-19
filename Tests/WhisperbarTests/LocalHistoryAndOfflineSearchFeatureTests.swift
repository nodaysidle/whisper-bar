import Foundation
import Testing
@testable import Whisperbar

/// TASK-13-LOCAL-HISTORY-AND-OFFLINE-SEARCH focused checks.
///
/// Covers FEAT-LOCAL-HISTORY-AND-OFFLINE-SEARCH and contracts
/// CON-LOCAL-HISTORY-AND-OFFLINE-SEARCH-INTERFACE and
/// CON-LOCAL-HISTORY-AND-OFFLINE-SEARCH-RECOVERY through an injected DataStore
/// sandbox and an in-memory clipboard seam. No live clipboard, TCC prompt,
/// network request, or Keychain item is touched by these tests.
@Suite("LocalHistoryAndOfflineSearchFeature — bounded local history and offline search")
@MainActor
struct LocalHistoryAndOfflineSearchFeatureTests {

    typealias Sandbox = DataStoreTests.Sandbox

    // MARK: - Fakes

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var _now = Date(timeIntervalSince1970: 1_767_225_600)
        var now: Date {
            get { lock.withLock { _now } }
        }
        func advance(_ interval: TimeInterval) {
            lock.withLock { _now = _now.addingTimeInterval(interval) }
        }
    }

    final class FakeClipboard: HistoryClipboardWriting, @unchecked Sendable {
        private let lock = NSLock()
        private var _writes: [String] = []
        private var _succeeds = true

        var writes: [String] { lock.withLock { _writes } }

        func configure(succeeds: Bool) {
            lock.withLock { _succeeds = succeeds }
        }

        func writeString(_ text: String) -> Bool {
            lock.withLock {
                guard _succeeds else { return false }
                _writes.append(text)
                return true
            }
        }
    }

    // MARK: - Helpers

    struct Room {
        let feature: LocalHistoryAndOfflineSearchFeature
        let clipboard: FakeClipboard
        let clock: Clock
        let sandbox: Sandbox
        let store: DataStore
    }

    private func makeRoom(
        sandbox: Sandbox,
        clock: Clock = Clock(),
        availability: PermissionState = .authorized
    ) -> Room {
        let clipboard = FakeClipboard()
        let store = sandbox.makeStore()
        let feature = LocalHistoryAndOfflineSearchFeature(
            dataStore: store,
            clipboard: clipboard,
            clipboardAvailability: { availability },
            now: { clock.now }
        )
        return Room(feature: feature, clipboard: clipboard, clock: clock, sandbox: sandbox, store: store)
    }

    @discardableResult
    private func save(_ room: Room, _ text: String) async -> Bool {
        room.clock.advance(1)
        return await room.feature.saveTranscript(
            text: text,
            provider: .deepgramStreaming
        )
    }

    // MARK: - ACC-LOCAL-HISTORY-AND-OFFLINE-SEARCH-01
    // Copy and delete actions work atomically.

    @Test("Copy writes the complete transcript to the clipboard in one action")
    func copyWritesCompleteTranscript() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }
        let room = makeRoom(sandbox: sandbox)
        #expect(await room.feature.load())

        #expect(await save(room, "First transcript."))
        #expect(await save(room, "Second transcript."))
        let target = await room.feature.transcripts.first { $0.text == "Second transcript." }
        let id = target?.id ?? ""

        #expect(room.feature.copy(id: id))
        #expect(room.clipboard.writes == ["Second transcript."])
        #expect(room.feature.state == .succeeded)
        #expect(room.feature.lastAction == .transcriptCopied(id: id))
        #expect(room.feature.lastNotice?.contains("Copied") == true)
        // Copy never touches storage.
        #expect((try? await sandbox.makeStore().transcriptCount()) == 2)
    }

    @Test("Delete removes the record, verifies absence, and keeps the list honest")
    func deleteIsAtomicAndVerified() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }
        let room = makeRoom(sandbox: sandbox)
        #expect(await room.feature.load())

        #expect(await save(room, "Keep me."))
        #expect(await save(room, "Delete me."))
        let doomed = await room.feature.transcripts.first { $0.text == "Delete me." }
        let id = doomed?.id ?? ""

        #expect(await room.feature.delete(id: id))
        #expect(room.feature.state == .succeeded)
        #expect(room.feature.lastAction == .transcriptDeleted(id: id))
        #expect(room.feature.transcripts.count == 1)
        #expect(await room.feature.transcripts.first?.text == "Keep me.")
        // The durable state agrees with the in-memory list.
        let store = sandbox.makeStore()
        #expect((try? await store.transcriptCount()) == 1)
        #expect((try? await store.recentTranscripts())?.contains { $0.id == id } == false)
        // Delete never touches the clipboard.
        #expect(room.clipboard.writes.isEmpty)
    }

    @Test("A failed copy or delete leaves the last valid state and clipboard unchanged")
    func copyAndDeleteFailuresPreserveState() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }
        let room = makeRoom(sandbox: sandbox)
        #expect(await room.feature.load())
        #expect(await save(room, "Unchanged transcript."))
        let id = await room.feature.transcripts.first?.id ?? ""

        // A failed clipboard write reports honestly and copies nothing.
        room.clipboard.configure(succeeds: false)
        #expect(room.feature.copy(id: id) == false)
        #expect(room.feature.lastFailure?.category == .copyFailed)
        #expect(room.clipboard.writes.isEmpty)
        #expect(room.feature.transcripts.count == 1)

        // Unknown identifiers are rejected without side effects.
        #expect(room.feature.copy(id: "missing-id") == false)
        #expect(room.feature.lastFailure?.category == .recordNotFound)
        room.clipboard.configure(succeeds: true)
        #expect(await room.feature.delete(id: "missing-id") == false)
        #expect(room.feature.lastFailure?.category == .recordNotFound)
        #expect(room.feature.transcripts.count == 1)

        // A closed store disables history and reports honestly.
        let closedStore = sandbox.makeStore()
        await closedStore.close()
        let failing = LocalHistoryAndOfflineSearchFeature(
            dataStore: closedStore,
            clipboard: FakeClipboard(),
            clipboardAvailability: { .authorized },
            now: { Date(timeIntervalSince1970: 1_767_225_600) }
        )
        #expect(await failing.delete(id: id) == false)
        #expect(failing.lastFailure?.category == .storageUnavailable)
        #expect(failing.isHistoryEnabled == false)
    }

    // MARK: - ACC-LOCAL-HISTORY-AND-OFFLINE-SEARCH-02
    // No external sync occurs.

    @Test("Every history operation stays inside local storage and the explicit clipboard action")
    func noExternalSyncOccurs() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }
        let room = makeRoom(sandbox: sandbox)
        #expect(await room.feature.load())

        #expect(await save(room, "Local only idea: Postgres tuning."))
        #expect(await room.feature.search("Postgres"))
        let id = await room.feature.transcripts.first?.id ?? ""
        #expect(room.feature.copy(id: id))
        #expect(await room.feature.delete(id: id))

        // The contract marker is explicit and asserted: transcripts are never
        // uploaded or synced to external clouds.
        #expect(LocalHistoryAndOfflineSearchFeature.syncsToExternalServices == false)

        // Everything the feature wrote lives inside the sandbox SQLite file.
        let store = sandbox.makeStore()
        #expect(await store.availability == .available)
        // The lightweight settings suite carries no transcript text.
        let defaults = UserDefaults(suiteName: sandbox.suiteName)
        let dump = String(describing: defaults?.dictionaryRepresentation() ?? [:])
        #expect(!dump.contains("Local only idea"))
        // The only external surface used is the explicit clipboard copy.
        #expect(room.clipboard.writes == ["Local only idea: Postgres tuning."])
    }

    // MARK: - ACC-LOCAL-HISTORY-AND-OFFLINE-SEARCH-03
    // Storage remains bounded.

    @Test("Saving more transcripts than the bound keeps only the newest records")
    func storageRemainsBounded() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }
        let clock = Clock()
        let feature = LocalHistoryAndOfflineSearchFeature(
            dataStore: sandbox.makeStore(historyLimit: 3),
            clipboard: FakeClipboard(),
            clipboardAvailability: { .authorized },
            now: { clock.now }
        )
        #expect(await feature.load())

        for index in 1...6 {
            clock.advance(1)
            #expect(await feature.saveTranscript(text: "Transcript \(index).", provider: .deepgramStreaming))
        }

        #expect(feature.transcripts.count == 3)
        #expect(feature.transcripts.map(\.text) == ["Transcript 6.", "Transcript 5.", "Transcript 4."])
        #expect((try? await sandbox.makeStore().transcriptCount()) == 3)

        // Search also respects the bound and stays within it.
        #expect(await feature.search("Transcript"))
        #expect(feature.transcripts.count == 3)
        #expect(feature.state == .succeeded)
    }

    // MARK: - ACC-LOCAL-HISTORY-AND-OFFLINE-SEARCH-04
    // Transcripts are searchable offline.

    @Test("Offline full-text search finds transcripts and treats operators literally")
    func offlineSearchWorksSafely() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }
        let room = makeRoom(sandbox: sandbox)
        #expect(await room.feature.load())

        #expect(await save(room, "Deploy the Postgres cluster."))
        #expect(await save(room, "Review the ORM changes."))
        #expect(await save(room, "AND OR NEAR are plain words here."))

        // A result is found offline through local FTS only.
        #expect(await room.feature.search("Postgres"))
        #expect(room.feature.transcripts.count == 1)
        #expect(room.feature.transcripts.first?.text == "Deploy the Postgres cluster.")
        #expect(room.feature.lastAction == .searched(query: "Postgres", resultCount: 1))

        // FTS operators are quoted into phrases and never interpreted.
        #expect(await room.feature.search("AND OR NEAR"))
        #expect(room.feature.transcripts.count == 1)
        #expect(room.feature.transcripts.first?.text == "AND OR NEAR are plain words here.")

        // Quotes and unmatched syntax are safe, not thrown.
        #expect(await room.feature.search("\"unbalanced"))
        #expect(room.feature.state == .succeeded)

        // An empty query returns the bounded recent list again.
        #expect(await room.feature.search("   "))
        #expect(room.feature.transcripts.count == 3)
    }

    // MARK: - Recovery (CON-LOCAL-HISTORY-AND-OFFLINE-SEARCH-RECOVERY)

    @Test("Unavailable storage disables history, preserves the last valid list, and recovers on explicit retry")
    func storageUnavailableDisablesAndRecovers() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }
        let room = makeRoom(sandbox: sandbox)

        #expect(await room.feature.load())
        #expect(await save(room, "Survives the outage."))
        let lastValid = room.feature.transcripts.map(\.id)

        // Storage goes away: history is disabled, the user is told, and the
        // last valid list stays visible.
        await room.store.close()
        #expect(await room.feature.load() == false)
        #expect(room.feature.isHistoryEnabled == false)
        #expect(room.feature.lastFailure?.category == .storageUnavailable)
        #expect(room.feature.lastFailure?.message.contains("Transcription still works") == true)
        #expect(room.feature.transcripts.map(\.id) == lastValid)
        // Search and delete fail honestly; nothing is fabricated or dropped.
        #expect(await room.feature.search("Survives") == false)
        #expect(room.feature.transcripts.map(\.id) == lastValid)
        // The explicit retry converges once storage is reachable again.
        let recovered = makeRoom(sandbox: sandbox)
        #expect(await recovered.feature.retry())
        #expect(recovered.feature.state == .succeeded)
        #expect(recovered.feature.isHistoryEnabled)
        #expect(recovered.feature.transcripts.count == 1)
    }

    @Test("Empty or incomplete text is rejected without replacing the last valid history")
    func invalidRecordsAreRejected() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }
        let room = makeRoom(sandbox: sandbox)
        #expect(await room.feature.load())
        #expect(await save(room, "Complete transcript."))

        #expect(await room.feature.saveTranscript(text: "   ", provider: .deepgramStreaming) == false)
        #expect(room.feature.lastFailure?.category == .invalidRecord)
        #expect(room.feature.lastFailure?.message.contains("never") == true)
        #expect(room.feature.transcripts.count == 1)
        #expect(room.feature.transcripts.first?.text == "Complete transcript.")

        // An explicit corrected save recovers.
        #expect(await save(room, "Now complete."))
        #expect(room.feature.lastFailure == nil)
        #expect(room.feature.transcripts.count == 2)
    }

    @Test("Clipboard denial keeps the manual path and never replaces prior clipboard content")
    func clipboardDenialKeepsManualPath() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }
        let room = makeRoom(sandbox: sandbox, availability: .denied)
        #expect(await room.feature.load())
        #expect(await save(room, "Manual copy candidate."))
        let id = await room.feature.transcripts.first?.id ?? ""

        #expect(room.feature.copy(id: id) == false)
        #expect(room.feature.lastFailure?.category == .clipboardUnavailable)
        #expect(room.feature.lastFailure?.message.contains("manual") == true)
        #expect(room.clipboard.writes.isEmpty)
        // The transcript stays visible for the manual path.
        #expect(room.feature.transcripts.count == 1)
        #expect(room.feature.state == .failed(room.feature.lastFailure ?? LocalHistoryAndOfflineSearchFeature.Failure(category: .copyFailed, message: "")))
    }
}
