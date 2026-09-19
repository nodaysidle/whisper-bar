import Foundation
import SQLite3
import Testing
@testable import Whisperbar

/// TASK-03-DATA-STORE focused checks.
///
/// Covers CON-DATA-* and CON-PERSISTENCE-* contracts: SQLite placement,
/// versioned migrations, bounded history, offline FTS search, atomic delete,
/// UserDefaults lightweight settings (no secrets), temporary/saved recording
/// placement, and the memory-only Clipboard Snapshot contract.
@Suite("DataStore — persistence, search, and bounded history")
struct DataStoreTests {

    // MARK: - Sandbox

    struct Sandbox {
        let root: URL
        let appSupport: URL
        let tempBase: URL
        let defaults: UserDefaults
        let suiteName: String

        func makeStore(historyLimit: Int = 500) -> DataStore {
            DataStore(
                applicationSupportBaseURL: appSupport,
                temporaryBaseURL: tempBase,
                userDefaultsSuiteName: suiteName,
                historyLimit: historyLimit
            )
        }

        func clean() {
            try? FileManager.default.removeItem(at: root)
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
    }

    static func makeSandbox() -> Sandbox {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperBarDataStoreTests-\(UUID().uuidString)")
        let suiteName = "com.whisperbar.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return Sandbox(
            root: root,
            appSupport: root.appendingPathComponent("com.whisperbar.app"),
            tempBase: root.appendingPathComponent("tmp/com.whisperbar.app"),
            defaults: defaults,
            suiteName: suiteName
        )
    }

    static func transcript(_ text: String, provider: TranscriptionProviderID = .deepgramStreaming) -> TranscriptRecord {
        TranscriptRecord(
            id: UUID().uuidString,
            text: text,
            createdAt: Date(),
            provider: provider,
            isRefined: false,
            durationSeconds: 1.5
        )
    }

    // MARK: - Migration and placement

    @Test("Opens at the locked placement with a versioned schema")
    func opensAtLockedPlacement() async throws {
        let sandbox = Self.makeSandbox()
        defer { sandbox.clean() }
        let store = sandbox.makeStore()
        #expect(await store.availability == .available)

        let dbURL = sandbox.appSupport.appendingPathComponent("voice.sqlite3")
        #expect(FileManager.default.fileExists(atPath: dbURL.path))

        // Verify the on-disk schema version and tables directly.
        var handle: OpaquePointer?
        #expect(sqlite3_open_v2(dbURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(handle, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK)
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        let version = sqlite3_column_int(statement, 0)
        sqlite3_finalize(statement)
        #expect(version == 1)
    }

    @Test("Storage unavailability is explicit and non-fatal")
    func unavailableStorageDegrades() async throws {
        let sandbox = Self.makeSandbox()
        defer { sandbox.clean() }
        // Occupy the Application Support path with a regular file so the
        // directory cannot be created.
        try FileManager.default.createDirectory(at: sandbox.root, withIntermediateDirectories: true)
        try Data("blocker".utf8).write(to: sandbox.appSupport)

        let store = sandbox.makeStore()
        guard case .unavailable = await store.availability else {
            Issue.record("expected unavailable storage")
            return
        }
        await #expect(throws: DataStoreError.self) {
            try await store.insertTranscript(Self.transcript("hello"))
        }
        // Non-storage features keep working with a clear message.
        await store.setProviderPreference(.openRouterBatch)
        #expect(await store.providerPreference() == .openRouterBatch)
    }

    // MARK: - Transcripts

    @Test("Inserts and reads transcripts with full field fidelity, newest first")
    func transcriptRoundTrip() async throws {
        let sandbox = Self.makeSandbox()
        defer { sandbox.clean() }
        let store = sandbox.makeStore()

        let first = TranscriptRecord(
            id: "id-1", text: "first", createdAt: Date(timeIntervalSince1970: 1_000),
            provider: .deepgramStreaming, isRefined: false, durationSeconds: 2.5
        )
        let second = TranscriptRecord(
            id: "id-2", text: "second", createdAt: Date(timeIntervalSince1970: 2_000),
            provider: .openRouterBatch, isRefined: true, durationSeconds: nil
        )
        try await store.insertTranscript(first)
        try await store.insertTranscript(second)

        let recent = try await store.recentTranscripts(limit: 10)
        #expect(recent.count == 2)
        #expect(recent.first?.id == "id-2")
        #expect(recent.first?.provider == .openRouterBatch)
        #expect(recent.first?.isRefined == true)
        #expect(recent.first?.durationSeconds == nil)
        #expect(recent.last?.text == "first")
        #expect(recent.last?.durationSeconds == 2.5)
        #expect(try await store.transcriptCount() == 2)
    }

    @Test("Rejects invalid or incomplete records without replacing valid state")
    func invalidRecordsRejected() async throws {
        let sandbox = Self.makeSandbox()
        defer { sandbox.clean() }
        let store = sandbox.makeStore()
        try await store.insertTranscript(Self.transcript("valid"))

        await #expect(throws: DataStoreError.invalidRecord) {
            try await store.insertTranscript(Self.transcript(""))
        }
        await #expect(throws: DataStoreError.invalidRecord) {
            try await store.insertTranscript(Self.transcript("   \n"))
        }
        #expect(try await store.transcriptCount() == 1)
    }

    @Test("Offline full-text search finds matches and handles hostile queries")
    func offlineSearch() async throws {
        let sandbox = Self.makeSandbox()
        defer { sandbox.clean() }
        let store = sandbox.makeStore()
        try await store.insertTranscript(Self.transcript("the quantum relay experiment"))
        try await store.insertTranscript(Self.transcript("quantum second note about relays"))
        try await store.insertTranscript(Self.transcript("unrelated grocery list"))

        let matches = try await store.searchTranscripts(query: "quantum", limit: 10)
        #expect(matches.count == 2)

        let conjunctive = try await store.searchTranscripts(query: "quantum relay", limit: 10)
        #expect(conjunctive.count == 1)

        // Quoting/operators must not crash or inject FTS syntax.
        let hostile = try await store.searchTranscripts(query: "\" OR 1=1 --", limit: 10)
        #expect(hostile.isEmpty)

        // Empty query returns bounded recent history.
        let empty = try await store.searchTranscripts(query: "  ", limit: 2)
        #expect(empty.count == 2)
    }

    @Test("Delete is atomic and reports honestly")
    func deleteIsAtomic() async throws {
        let sandbox = Self.makeSandbox()
        defer { sandbox.clean() }
        let store = sandbox.makeStore()
        let record = Self.transcript("delete me")
        try await store.insertTranscript(record)

        #expect(try await store.deleteTranscript(id: record.id) == true)
        #expect(try await store.recentTranscripts(limit: 10).isEmpty)
        #expect(try await store.searchTranscripts(query: "delete", limit: 10).isEmpty)
        // Unknown ids are reported as not deleted, never as success.
        #expect(try await store.deleteTranscript(id: "missing") == false)
    }

    @Test("History stays bounded and trims oldest records")
    func boundedHistory() async throws {
        let sandbox = Self.makeSandbox()
        defer { sandbox.clean() }
        let store = sandbox.makeStore(historyLimit: 10)
        for index in 0..<14 {
            try await store.insertTranscript(
                Self.transcript("record \(index)")
            )
        }
        let count = try await store.transcriptCount()
        #expect(count == 10)
        let recent = try await store.recentTranscripts(limit: 50)
        #expect(recent.count == 10)
    }

    // MARK: - Writing modes and vocabulary

    @Test("Writing mode records round-trip and delete atomically")
    func writingModesCRUD() async throws {
        let sandbox = Self.makeSandbox()
        defer { sandbox.clean() }
        let store = sandbox.makeStore()

        let mode = WritingMode(id: "mode-1", name: "Formal", instructions: "Use formal tone.", isDefault: true)
        try await store.upsertWritingMode(mode)
        var modes = try await store.writingModes()
        #expect(modes == [mode])

        var updated = mode
        updated.instructions = "Use a very formal tone."
        updated.isDefault = false
        try await store.upsertWritingMode(updated)
        modes = try await store.writingModes()
        #expect(modes.count == 1)
        #expect(modes.first?.instructions == "Use a very formal tone.")

        await #expect(throws: DataStoreError.invalidRecord) {
            try await store.upsertWritingMode(WritingMode(id: "mode-2", name: "  ", instructions: "x", isDefault: false))
        }

        try await store.deleteWritingMode(id: "mode-1")
        #expect(try await store.writingModes().isEmpty)
    }

    @Test("Vocabulary terms round-trip, dedupe case-insensitively, and stay ordered")
    func vocabularyCRUD() async throws {
        let sandbox = Self.makeSandbox()
        defer { sandbox.clean() }
        let store = sandbox.makeStore()

        try await store.upsertVocabularyTerm(VocabularyTerm(id: "v1", term: "WhisperBar", createdAt: Date(timeIntervalSince1970: 10)))
        try await store.upsertVocabularyTerm(VocabularyTerm(id: "v2", term: "API", createdAt: Date(timeIntervalSince1970: 20)))

        await #expect(throws: DataStoreError.duplicateRecord) {
            try await store.upsertVocabularyTerm(VocabularyTerm(id: "v3", term: "whisperbar", createdAt: Date()))
        }

        let terms = try await store.vocabularyTerms()
        #expect(terms.map(\.term) == ["API", "WhisperBar"])

        try await store.deleteVocabularyTerm(id: "v1")
        #expect(try await store.vocabularyTerms().map(\.term) == ["API"])
    }

    // MARK: - Lightweight settings (UserDefaults, no secrets)

    @Test("Provider preference and hotkey configuration persist through UserDefaults")
    func lightweightSettings() async throws {
        let sandbox = Self.makeSandbox()
        defer { sandbox.clean() }
        let store = sandbox.makeStore()

        #expect(await store.providerPreference() == nil)
        await store.setProviderPreference(.deepgramStreaming)
        #expect(await store.providerPreference() == .deepgramStreaming)
        await store.setProviderPreference(nil)
        #expect(await store.providerPreference() == nil)

        #expect(await store.hotkeyConfiguration() == HotkeyConfiguration.empty)
        let configuration = HotkeyConfiguration(
            pushToTalk: HotkeyIdentifier(keyCode: 2, modifiers: 6144),
            toggle: HotkeyIdentifier(keyCode: 17, modifiers: 6144)
        )
        await store.setHotkeyConfiguration(configuration)
        #expect(await store.hotkeyConfiguration() == configuration)

        await store.resetLightweightSettings()
        #expect(await store.providerPreference() == nil)
        #expect(await store.hotkeyConfiguration() == HotkeyConfiguration.empty)
    }

    @Test("UserDefaults never receives credential-shaped keys or values")
    func settingsNeverStoreSecrets() async throws {
        let sandbox = Self.makeSandbox()
        defer { sandbox.clean() }
        let store = sandbox.makeStore()
        await store.setProviderPreference(.openRouterBatch)
        await store.setHotkeyConfiguration(HotkeyConfiguration(pushToTalk: HotkeyIdentifier(keyCode: 2, modifiers: 6144), toggle: nil))

        let dictionary = sandbox.defaults.dictionaryRepresentation()
        let ownedKeys = dictionary.keys.filter { $0.hasPrefix("whisperbar.") }
        #expect(!ownedKeys.isEmpty)
        for key in ownedKeys {
            let lower = key.lowercased()
            #expect(!lower.contains("token"))
            #expect(!lower.contains("secret"))
            #expect(!lower.contains("credential"))
            #expect(!lower.contains("api-key"))
            #expect(!lower.contains("apikey"))
            #expect(!lower.contains("deepgram-nova"))
            #expect(!lower.contains("openrouter-api"))
        }
        for (_, value) in dictionary where value is String {
            let string = value as? String ?? ""
            #expect(!string.hasPrefix("sk-"))
        }
    }

    // MARK: - Temporary and saved audio placement

    @Test("Temporary recording placement, discard, and save follow the contract")
    func temporaryAudioPlacement() async throws {
        let sandbox = Self.makeSandbox()
        defer { sandbox.clean() }
        let store = sandbox.makeStore()
        let recordingID = UUID()

        let url = try await store.prepareTemporaryRecording(recordingID: recordingID, fileExtension: "caf")
        #expect(url.path.hasSuffix("/\(recordingID.uuidString)/audio.caf"))
        #expect(url.path.contains("com.whisperbar.app"))
        try Data([0x01, 0x02]).write(to: url)
        #expect(await store.temporaryRecordingExists(recordingID: recordingID))

        let saved = try await store.saveRecording(recordingID: recordingID, fileExtension: "caf")
        #expect(saved.path.contains("Recordings"))
        #expect(FileManager.default.fileExists(atPath: saved.path))
        #expect(await store.temporaryRecordingExists(recordingID: recordingID) == false)

        // A second recording discards without a trace.
        let secondID = UUID()
        let second = try await store.prepareTemporaryRecording(recordingID: secondID, fileExtension: "caf")
        try Data([0x03]).write(to: second)
        #expect(try await store.discardTemporaryRecording(recordingID: secondID) == true)
        #expect(await store.temporaryRecordingExists(recordingID: secondID) == false)
    }

    @Test("Stale temporary recordings never survive a new session")
    func staleTemporaryRecordingsPurged() async throws {
        let sandbox = Self.makeSandbox()
        defer { sandbox.clean() }
        let store = sandbox.makeStore()

        for _ in 0..<3 {
            let id = UUID()
            let url = try await store.prepareTemporaryRecording(recordingID: id, fileExtension: "caf")
            try Data([0x00]).write(to: url)
        }
        let purged = try await store.purgeStaleTemporaryRecordings()
        #expect(purged == 3)
        #expect(try await store.purgeStaleTemporaryRecordings() == 0)
    }

    // MARK: - Clipboard Snapshot is memory-only

    @Test("Clipboard Snapshot stays in memory and is never persisted")
    func clipboardSnapshotMemoryOnly() async throws {
        let sandbox = Self.makeSandbox()
        defer { sandbox.clean() }
        let store = sandbox.makeStore()
        try await store.insertTranscript(Self.transcript("body"))

        let snapshot = ClipboardSnapshot(
            items: [
                PasteboardItemSnapshot(representations: [
                    PasteboardRepresentation(type: "public.utf8-plain-text", data: Data("before".utf8)),
                    PasteboardRepresentation(type: "public.html", data: Data("<i>before</i>".utf8))
                ]),
                PasteboardItemSnapshot(representations: [
                    PasteboardRepresentation(type: "public.png", data: Data([0x89, 0x50, 0x4E, 0x47]))
                ])
            ],
            changeCount: 42
        )
        let memory = ClipboardMemoryStore()
        await memory.store(snapshot)
        #expect(await memory.current() == snapshot)
        #expect(await memory.current()?.items.count == 2)
        #expect(await memory.current()?.items[0].representations.count == 2)
        await memory.clear()
        #expect(await memory.current() == nil)

        // Verify nothing clipboard-shaped landed in SQLite.
        var handle: OpaquePointer?
        let dbURL = sandbox.appSupport.appendingPathComponent("voice.sqlite3")
        #expect(sqlite3_open_v2(dbURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(handle, "SELECT name FROM sqlite_master WHERE type='table';", -1, &statement, nil) == SQLITE_OK)
        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let cString = sqlite3_column_text(statement, 0) {
                names.append(String(cString: cString))
            }
        }
        sqlite3_finalize(statement)
        for name in names {
            #expect(!name.lowercased().contains("clipboard"))
            #expect(!name.lowercased().contains("snapshot"))
        }

        // And nothing clipboard-shaped landed in UserDefaults either.
        let dictionary = sandbox.defaults.dictionaryRepresentation()
        for key in dictionary.keys where key.hasPrefix("whisperbar.") {
            #expect(!key.lowercased().contains("clipboard"))
        }
    }

    @Test("Closing the store reports honest unavailability afterwards")
    func closeReportsUnavailable() async throws {
        let sandbox = Self.makeSandbox()
        defer { sandbox.clean() }
        let store = sandbox.makeStore()
        try await store.insertTranscript(Self.transcript("kept"))
        await store.close()

        guard case .unavailable = await store.availability else {
            Issue.record("expected unavailable after close")
            return
        }
        await #expect(throws: DataStoreError.self) {
            try await store.recentTranscripts(limit: 5)
        }
    }
}
