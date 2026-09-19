import Foundation
import SQLite3

// MARK: - Provider identity

/// The explicitly selected transcription provider (CON-DATA-PROVIDER-PREFERENCE).
enum TranscriptionProviderID: String, CaseIterable, Codable, Sendable {
    case deepgramStreaming = "deepgram"
    case openRouterBatch = "openrouter"

    var displayName: String {
        switch self {
        case .deepgramStreaming: return "Deepgram (live streaming)"
        case .openRouterBatch: return "OpenRouter (batch)"
        }
    }
}

// MARK: - Storage availability and errors

enum StorageAvailability: Equatable, Sendable {
    case available
    case unavailable(reason: String)

    var isAvailable: Bool { self == .available }
}

enum DataStoreError: Error, Equatable, Sendable {
    case storageUnavailable(String)
    case invalidRecord
    case duplicateRecord
    case writeFailed(String)
    case readFailed(String)
    case deleteFailed(String)
    case fileOperationFailed(String)
}

// MARK: - Data records

/// CON-DATA-TRANSCRIPT
struct TranscriptRecord: Identifiable, Equatable, Sendable {
    let id: String
    var text: String
    var createdAt: Date
    var provider: TranscriptionProviderID
    var isRefined: Bool
    var durationSeconds: Double?

    init(
        id: String,
        text: String,
        createdAt: Date,
        provider: TranscriptionProviderID,
        isRefined: Bool = false,
        durationSeconds: Double? = nil
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.provider = provider
        self.isRefined = isRefined
        self.durationSeconds = durationSeconds
    }
}

/// CON-DATA-WRITING-MODE-CONFIGURATION
struct WritingMode: Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var instructions: String
    var isDefault: Bool

    init(id: String, name: String, instructions: String, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.isDefault = isDefault
    }
}

/// CON-DATA-VOCABULARY-LIST
struct VocabularyTerm: Identifiable, Equatable, Sendable {
    let id: String
    var term: String
    var createdAt: Date

    init(id: String, term: String, createdAt: Date) {
        self.id = id
        self.term = term
        self.createdAt = createdAt
    }
}

/// CON-DATA-HOTKEY-CONFIGURATION — a provider-neutral hotkey value.
/// Carbon key codes/modifiers are interpreted by the hotkey feature owner.
struct HotkeyIdentifier: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
}

struct HotkeyConfiguration: Codable, Equatable, Sendable {
    var pushToTalk: HotkeyIdentifier?
    var toggle: HotkeyIdentifier?

    static let empty = HotkeyConfiguration(pushToTalk: nil, toggle: nil)

    var isEmpty: Bool { pushToTalk == nil && toggle == nil }
}

// MARK: - Clipboard Snapshot (CON-DATA-CLIPBOARD-SNAPSHOT, memory-only)

struct PasteboardRepresentation: Equatable, Sendable {
    let type: String
    let data: Data
}

struct PasteboardItemSnapshot: Equatable, Sendable {
    let representations: [PasteboardRepresentation]
}

/// Candidate 2 of the architecture: the clipboard snapshot is held only in
/// memory during insertion and restored immediately; it is never persisted.
struct ClipboardSnapshot: Equatable, Sendable {
    let items: [PasteboardItemSnapshot]
    let changeCount: Int

    var isEmpty: Bool { items.isEmpty }

    static let empty = ClipboardSnapshot(items: [], changeCount: -1)
}

/// Memory-only holder for the active insertion snapshot. It deliberately has
/// no FileManager/UserDefaults/SQLite access: persistence is impossible here.
actor ClipboardMemoryStore {
    private var snapshot: ClipboardSnapshot?

    func store(_ snapshot: ClipboardSnapshot) {
        self.snapshot = snapshot
    }

    func current() -> ClipboardSnapshot? {
        snapshot
    }

    func clear() {
        snapshot = nil
    }
}

// MARK: - SQLite plumbing

/// Thin, actor-owned SQLite3 wrapper. Never leaves its owning actor.
final class SQLiteConnection {
    private var handle: OpaquePointer?
    private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(path, &handle, flags, nil)
        guard status == SQLITE_OK, let opened = handle else {
            if let handle { sqlite3_close(handle) }
            throw DataStoreError.storageUnavailable("database open failed (\(status))")
        }
        self.handle = opened
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    @discardableResult
    func execute(_ sql: String) throws -> Int32 {
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &error)
        defer { sqlite3_free(error) }
        guard status == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "sqlite error \(status)"
            throw DataStoreError.writeFailed(message)
        }
        return status
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard status == SQLITE_OK else {
            throw DataStoreError.readFailed("prepare failed (\(status)): \(String(cString: sqlite3_errmsg(handle)))")
        }
        return SQLiteStatement(handle: statement, connection: self, destructor: transientDestructor)
    }

    func scalarInt(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        defer { statement.finalize() }
        guard try statement.step() == SQLITE_ROW else {
            throw DataStoreError.readFailed("expected a row")
        }
        return statement.columnInt(0)
    }

    var lastErrorCode: Int32 { sqlite3_extended_errcode(handle) }
    var lastErrorMessage: String { String(cString: sqlite3_errmsg(handle)) }
    var rawHandle: OpaquePointer? { handle }
}

final class SQLiteStatement {
    private var handle: OpaquePointer?
    private let connection: SQLiteConnection
    private let destructor: sqlite3_destructor_type?

    init(handle: OpaquePointer?, connection: SQLiteConnection, destructor: sqlite3_destructor_type?) {
        self.handle = handle
        self.connection = connection
        self.destructor = destructor
    }

    deinit {
        finalize()
    }

    func finalize() {
        if let handle {
            sqlite3_finalize(handle)
        }
        handle = nil
    }

    func bind(text: String, at index: Int32) throws {
        let status = sqlite3_bind_text(handle, index, text, -1, destructor)
        guard status == SQLITE_OK else {
            throw DataStoreError.writeFailed("bind text failed (\(status))")
        }
    }

    func bind(double: Double, at index: Int32) throws {
        let status = sqlite3_bind_double(handle, index, double)
        guard status == SQLITE_OK else {
            throw DataStoreError.writeFailed("bind double failed (\(status))")
        }
    }

    func bind(int: Int, at index: Int32) throws {
        let status = sqlite3_bind_int64(handle, index, Int64(int))
        guard status == SQLITE_OK else {
            throw DataStoreError.writeFailed("bind int failed (\(status))")
        }
    }

    func bindNull(at index: Int32) throws {
        let status = sqlite3_bind_null(handle, index)
        guard status == SQLITE_OK else {
            throw DataStoreError.writeFailed("bind null failed (\(status))")
        }
    }

    @discardableResult
    func step() throws -> Int32 {
        let status = sqlite3_step(handle)
        switch status {
        case SQLITE_ROW, SQLITE_DONE:
            return status
        default:
            throw DataStoreError.writeFailed("step failed (\(status)): \(connection.lastErrorMessage)")
        }
    }

    func columnText(_ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(handle, index) else { return nil }
        return String(cString: UnsafeRawPointer(pointer).assumingMemoryBound(to: CChar.self))
    }

    func columnDouble(_ index: Int32) -> Double {
        sqlite3_column_double(handle, index)
    }

    func columnInt(_ index: Int32) -> Int {
        Int(sqlite3_column_int64(handle, index))
    }

    func columnIsNull(_ index: Int32) -> Bool {
        sqlite3_column_type(handle, index) == SQLITE_NULL
    }
}

// MARK: - DataStore

/// OWN-DATA-STORE.
///
/// Owns the SQLite database at Application Support/com.whisperbar.app/voice.sqlite3
/// with schema-versioned transactional migrations, bounded history with
/// offline full-text search, non-secret lightweight settings in UserDefaults,
/// and the canonical temporary/saved recording placement. It never receives
/// secret material: credentials live exclusively in CredentialVault.
actor DataStore {

    // MARK: Configuration

    private let applicationSupportURL: URL
    private let temporaryBaseURL: URL
    private let recordingsURL: URL
    private let databaseURL: URL
    private let userDefaults: UserDefaults
    private let fileManager: FileManager
    private let historyLimit: Int

    private var connection: SQLiteConnection?
    private(set) var availability: StorageAvailability

    private enum SettingsKey {
        static let provider = "whisperbar.settings.v1.provider"
        static let hotkeys = "whisperbar.settings.v1.hotkeys"
    }

    private static let schemaVersion: Int32 = 1

    // MARK: Init

    init(
        applicationSupportBaseURL: URL? = nil,
        temporaryBaseURL: URL? = nil,
        userDefaultsSuiteName: String? = nil,
        historyLimit: Int = 500,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.applicationSupportURL = applicationSupportBaseURL ?? Self.defaultApplicationSupportBaseURL(fileManager: fileManager)
        self.temporaryBaseURL = temporaryBaseURL ?? Self.defaultTemporaryBaseURL(fileManager: fileManager)
        // Constructed inside the actor from a Sendable suite name so no
        // non-Sendable UserDefaults reference crosses an isolation boundary.
        self.userDefaults = userDefaultsSuiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        self.historyLimit = max(1, historyLimit)
        self.databaseURL = self.applicationSupportURL.appendingPathComponent(AppIdentity.databaseFileName)
        self.recordingsURL = self.applicationSupportURL.appendingPathComponent("Recordings", isDirectory: true)
        self.connection = nil
        self.availability = .available

        do {
            try fileManager.createDirectory(at: self.applicationSupportURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: self.temporaryBaseURL, withIntermediateDirectories: true)
            let connection = try SQLiteConnection(path: databaseURL.path)
            try Self.migrate(connection)
            self.connection = connection
        } catch {
            self.connection = nil
            self.availability = .unavailable(reason: Self.describe(error))
        }
    }

    // MARK: Defaults

    static func defaultApplicationSupportBaseURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(AppIdentity.applicationSupportDirectoryName, isDirectory: true)
    }

    static func defaultTemporaryBaseURL(fileManager: FileManager = .default) -> URL {
        fileManager.temporaryDirectory.appendingPathComponent(AppIdentity.temporaryDirectoryName, isDirectory: true)
    }

    // MARK: Migrations

    /// Schema-versioned transactional migrations. Each entry upgrades from the
    /// previous PRAGMA user_version; a failure rolls back that step only.
    private static let migrations: [(version: Int32, statements: [String])] = [
        (
            1,
            [
                """
                CREATE TABLE IF NOT EXISTS transcripts (
                    id TEXT PRIMARY KEY NOT NULL,
                    text TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    provider TEXT NOT NULL,
                    is_refined INTEGER NOT NULL DEFAULT 0,
                    duration_seconds REAL
                );
                """,
                """
                CREATE TABLE IF NOT EXISTS writing_modes (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    instructions TEXT NOT NULL,
                    is_default INTEGER NOT NULL DEFAULT 0
                );
                """,
                """
                CREATE TABLE IF NOT EXISTS vocabulary_terms (
                    id TEXT PRIMARY KEY NOT NULL,
                    term TEXT NOT NULL COLLATE NOCASE UNIQUE,
                    created_at REAL NOT NULL
                );
                """,
                """
                CREATE VIRTUAL TABLE IF NOT EXISTS transcript_search USING fts5(
                    text,
                    content='transcripts',
                    content_rowid='rowid'
                );
                """,
                """
                CREATE TRIGGER IF NOT EXISTS transcripts_ai AFTER INSERT ON transcripts BEGIN
                    INSERT INTO transcript_search(rowid, text) VALUES (new.rowid, new.text);
                END;
                """,
                """
                CREATE TRIGGER IF NOT EXISTS transcripts_ad AFTER DELETE ON transcripts BEGIN
                    INSERT INTO transcript_search(transcript_search, rowid, text)
                    VALUES ('delete', old.rowid, old.text);
                END;
                """,
                """
                CREATE TRIGGER IF NOT EXISTS transcripts_au AFTER UPDATE ON transcripts BEGIN
                    INSERT INTO transcript_search(transcript_search, rowid, text)
                    VALUES ('delete', old.rowid, old.text);
                    INSERT INTO transcript_search(rowid, text) VALUES (new.rowid, new.text);
                END;
                """
            ]
        )
    ]

    private static func migrate(_ connection: SQLiteConnection) throws {
        try connection.execute("PRAGMA journal_mode=WAL;")
        let current = try connection.scalarInt("PRAGMA user_version;")
        for migration in migrations where Int(migration.version) > current {
            try connection.execute("BEGIN IMMEDIATE;")
            do {
                for statement in migration.statements {
                    try connection.execute(statement)
                }
                try connection.execute("PRAGMA user_version = \(migration.version);")
                try connection.execute("COMMIT;")
            } catch {
                _ = try? connection.execute("ROLLBACK;")
                throw error
            }
        }
    }

    // MARK: Lifecycle

    /// Explicit teardown: afterwards every record operation reports honest
    /// unavailability instead of pretending to succeed.
    func close() {
        connection = nil
        availability = .unavailable(reason: "database closed")
    }

    private func requireConnection() throws -> SQLiteConnection {
        guard let connection else {
            throw DataStoreError.storageUnavailable("local storage is unavailable")
        }
        return connection
    }

    private static func describe(_ error: Error) -> String {
        "local storage could not be prepared"
    }

    // MARK: Transcripts (CON-DATA-TRANSCRIPT, CON-PERSISTENCE-TRANSCRIPT)

    func insertTranscript(_ record: TranscriptRecord) throws {
        let trimmed = record.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !record.id.isEmpty else {
            throw DataStoreError.invalidRecord
        }
        let connection = try requireConnection()
        let statement = try connection.prepare(
            """
            INSERT OR REPLACE INTO transcripts (id, text, created_at, provider, is_refined, duration_seconds)
            VALUES (?, ?, ?, ?, ?, ?);
            """
        )
        defer { statement.finalize() }
        try statement.bind(text: record.id, at: 1)
        try statement.bind(text: record.text, at: 2)
        try statement.bind(double: record.createdAt.timeIntervalSince1970, at: 3)
        try statement.bind(text: record.provider.rawValue, at: 4)
        try statement.bind(int: record.isRefined ? 1 : 0, at: 5)
        if let duration = record.durationSeconds {
            try statement.bind(double: duration, at: 6)
        } else {
            try statement.bindNull(at: 6)
        }
        guard try statement.step() == SQLITE_DONE else {
            throw DataStoreError.writeFailed("transcript insert did not complete")
        }
        try trimHistory(connection: connection)
    }

    private func trimHistory(connection: SQLiteConnection) throws {
        let statement = try connection.prepare(
            """
            DELETE FROM transcripts WHERE rowid NOT IN (
                SELECT rowid FROM transcripts ORDER BY created_at DESC, rowid DESC LIMIT ?
            );
            """
        )
        defer { statement.finalize() }
        try statement.bind(int: historyLimit, at: 1)
        guard try statement.step() == SQLITE_DONE else {
            throw DataStoreError.writeFailed("history trim did not complete")
        }
    }

    func recentTranscripts(limit: Int = 50) throws -> [TranscriptRecord] {
        let connection = try requireConnection()
        let statement = try connection.prepare(
            """
            SELECT id, text, created_at, provider, is_refined, duration_seconds
            FROM transcripts
            ORDER BY created_at DESC, rowid DESC
            LIMIT ?;
            """
        )
        defer { statement.finalize() }
        try statement.bind(int: Self.clamped(limit), at: 1)
        return try Self.readTranscripts(statement)
    }

    /// Offline-only full-text search. The user query is quoted into FTS phrases
    /// so operators and quotes cannot inject FTS syntax.
    func searchTranscripts(query: String, limit: Int = 50) throws -> [TranscriptRecord] {
        guard let ftsQuery = Self.ftsQuery(from: query) else {
            return try recentTranscripts(limit: limit)
        }
        let connection = try requireConnection()
        let statement = try connection.prepare(
            """
            SELECT t.id, t.text, t.created_at, t.provider, t.is_refined, t.duration_seconds
            FROM transcripts AS t
            WHERE t.rowid IN (
                SELECT rowid FROM transcript_search WHERE transcript_search MATCH ?
            )
            ORDER BY t.created_at DESC, t.rowid DESC
            LIMIT ?;
            """
        )
        defer { statement.finalize() }
        try statement.bind(text: ftsQuery, at: 1)
        try statement.bind(int: Self.clamped(limit), at: 2)
        return try Self.readTranscripts(statement)
    }

    @discardableResult
    func deleteTranscript(id: String) throws -> Bool {
        let connection = try requireConnection()
        let statement = try connection.prepare("DELETE FROM transcripts WHERE id = ?;")
        defer { statement.finalize() }
        try statement.bind(text: id, at: 1)
        guard try statement.step() == SQLITE_DONE else {
            throw DataStoreError.deleteFailed("transcript delete did not complete")
        }
        guard let handle = connection.rawHandle else {
            throw DataStoreError.deleteFailed("transcript delete could not be confirmed")
        }
        return sqlite3_changes(handle) > 0
    }

    func transcriptCount() throws -> Int {
        let connection = try requireConnection()
        return try connection.scalarInt("SELECT COUNT(*) FROM transcripts;")
    }

    private static func readTranscripts(_ statement: SQLiteStatement) throws -> [TranscriptRecord] {
        var records: [TranscriptRecord] = []
        while try statement.step() == SQLITE_ROW {
            let id = statement.columnText(0) ?? ""
            let text = statement.columnText(1) ?? ""
            let createdAt = Date(timeIntervalSince1970: statement.columnDouble(2))
            let providerRaw = statement.columnText(3) ?? TranscriptionProviderID.deepgramStreaming.rawValue
            let provider = TranscriptionProviderID(rawValue: providerRaw) ?? .deepgramStreaming
            let isRefined = statement.columnInt(4) != 0
            let duration = statement.columnIsNull(5) ? nil : statement.columnDouble(5)
            records.append(
                TranscriptRecord(
                    id: id,
                    text: text,
                    createdAt: createdAt,
                    provider: provider,
                    isRefined: isRefined,
                    durationSeconds: duration
                )
            )
        }
        return records
    }

    private static func clamped(_ limit: Int) -> Int {
        min(max(limit, 1), 200)
    }

    /// Quotes each whitespace-separated term as an FTS5 phrase (implicit AND).
    static func ftsQuery(from raw: String) -> String? {
        let terms = raw
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        return terms
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            .joined(separator: " ")
    }

    // MARK: Writing modes (CON-DATA-WRITING-MODE-CONFIGURATION)

    func upsertWritingMode(_ mode: WritingMode) throws {
        let name = mode.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !mode.id.isEmpty else {
            throw DataStoreError.invalidRecord
        }
        let connection = try requireConnection()
        let statement = try connection.prepare(
            """
            INSERT INTO writing_modes (id, name, instructions, is_default)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                instructions = excluded.instructions,
                is_default = excluded.is_default;
            """
        )
        defer { statement.finalize() }
        try statement.bind(text: mode.id, at: 1)
        try statement.bind(text: name, at: 2)
        try statement.bind(text: mode.instructions, at: 3)
        try statement.bind(int: mode.isDefault ? 1 : 0, at: 4)
        guard try statement.step() == SQLITE_DONE else {
            throw DataStoreError.writeFailed("writing mode upsert did not complete")
        }
    }

    func writingModes() throws -> [WritingMode] {
        let connection = try requireConnection()
        let statement = try connection.prepare(
            "SELECT id, name, instructions, is_default FROM writing_modes ORDER BY name COLLATE NOCASE, rowid;"
        )
        defer { statement.finalize() }
        var modes: [WritingMode] = []
        while try statement.step() == SQLITE_ROW {
            modes.append(
                WritingMode(
                    id: statement.columnText(0) ?? "",
                    name: statement.columnText(1) ?? "",
                    instructions: statement.columnText(2) ?? "",
                    isDefault: statement.columnInt(3) != 0
                )
            )
        }
        return modes
    }

    func deleteWritingMode(id: String) throws {
        let connection = try requireConnection()
        let statement = try connection.prepare("DELETE FROM writing_modes WHERE id = ?;")
        defer { statement.finalize() }
        try statement.bind(text: id, at: 1)
        guard try statement.step() == SQLITE_DONE else {
            throw DataStoreError.deleteFailed("writing mode delete did not complete")
        }
    }

    // MARK: Vocabulary (CON-DATA-VOCABULARY-LIST)

    func upsertVocabularyTerm(_ term: VocabularyTerm) throws {
        let value = term.term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !term.id.isEmpty else {
            throw DataStoreError.invalidRecord
        }
        let connection = try requireConnection()

        let check = try connection.prepare("SELECT COUNT(*) FROM vocabulary_terms WHERE term = ? COLLATE NOCASE;")
        defer { check.finalize() }
        try check.bind(text: value, at: 1)
        guard try check.step() == SQLITE_ROW else {
            throw DataStoreError.readFailed("vocabulary check failed")
        }
        if check.columnInt(0) > 0 {
            throw DataStoreError.duplicateRecord
        }

        let statement = try connection.prepare(
            "INSERT INTO vocabulary_terms (id, term, created_at) VALUES (?, ?, ?);"
        )
        defer { statement.finalize() }
        try statement.bind(text: term.id, at: 1)
        try statement.bind(text: value, at: 2)
        try statement.bind(double: term.createdAt.timeIntervalSince1970, at: 3)
        guard try statement.step() == SQLITE_DONE else {
            throw DataStoreError.writeFailed("vocabulary insert did not complete")
        }
    }

    func vocabularyTerms() throws -> [VocabularyTerm] {
        let connection = try requireConnection()
        let statement = try connection.prepare(
            "SELECT id, term, created_at FROM vocabulary_terms ORDER BY term COLLATE NOCASE, rowid;"
        )
        defer { statement.finalize() }
        var terms: [VocabularyTerm] = []
        while try statement.step() == SQLITE_ROW {
            terms.append(
                VocabularyTerm(
                    id: statement.columnText(0) ?? "",
                    term: statement.columnText(1) ?? "",
                    createdAt: Date(timeIntervalSince1970: statement.columnDouble(2))
                )
            )
        }
        return terms
    }

    func deleteVocabularyTerm(id: String) throws {
        let connection = try requireConnection()
        let statement = try connection.prepare("DELETE FROM vocabulary_terms WHERE id = ?;")
        defer { statement.finalize() }
        try statement.bind(text: id, at: 1)
        guard try statement.step() == SQLITE_DONE else {
            throw DataStoreError.deleteFailed("vocabulary delete did not complete")
        }
    }

    // MARK: Lightweight settings (CON-PERSISTENCE-PROVIDER-PREFERENCE / HOTKEY-CONFIGURATION)

    func providerPreference() -> TranscriptionProviderID? {
        guard let raw = userDefaults.string(forKey: SettingsKey.provider) else { return nil }
        return TranscriptionProviderID(rawValue: raw)
    }

    func setProviderPreference(_ provider: TranscriptionProviderID?) {
        if let provider {
            userDefaults.set(provider.rawValue, forKey: SettingsKey.provider)
        } else {
            userDefaults.removeObject(forKey: SettingsKey.provider)
        }
    }

    func hotkeyConfiguration() -> HotkeyConfiguration {
        guard let data = userDefaults.data(forKey: SettingsKey.hotkeys),
              let decoded = try? JSONDecoder().decode(HotkeyConfiguration.self, from: data) else {
            return .empty
        }
        return decoded
    }

    func setHotkeyConfiguration(_ configuration: HotkeyConfiguration) {
        if configuration.isEmpty {
            userDefaults.removeObject(forKey: SettingsKey.hotkeys)
            return
        }
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        userDefaults.set(data, forKey: SettingsKey.hotkeys)
    }

    /// Explicit reset behavior for versioned lightweight keys (ARD "Settings placement").
    func resetLightweightSettings() {
        userDefaults.removeObject(forKey: SettingsKey.provider)
        userDefaults.removeObject(forKey: SettingsKey.hotkeys)
    }

    // MARK: Temporary audio (CON-DATA-TEMPORARY-AUDIO-RECORDING, CON-PERSISTENCE-TEMPORARY-AUDIO-RECORDING)

    func temporaryRecordingDirectory(recordingID: UUID) -> URL {
        temporaryBaseURL.appendingPathComponent(recordingID.uuidString, isDirectory: true)
    }

    func temporaryRecordingURL(recordingID: UUID, fileExtension: String) throws -> URL {
        temporaryRecordingDirectory(recordingID: recordingID)
            .appendingPathComponent("audio.\(try Self.sanitizedExtension(fileExtension))")
    }

    @discardableResult
    func prepareTemporaryRecording(recordingID: UUID, fileExtension: String) throws -> URL {
        let url = try temporaryRecordingURL(recordingID: recordingID, fileExtension: fileExtension)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard fileManager.createFile(atPath: url.path, contents: nil) else {
            throw DataStoreError.fileOperationFailed("temporary recording could not be created")
        }
        return url
    }

    func temporaryRecordingExists(recordingID: UUID) -> Bool {
        fileManager.fileExists(atPath: temporaryRecordingDirectory(recordingID: recordingID).path)
    }

    func savedRecordingURL(recordingID: UUID, fileExtension: String) throws -> URL {
        recordingsURL.appendingPathComponent("\(recordingID.uuidString).\(try Self.sanitizedExtension(fileExtension))")
    }

    /// Explicit user action only: moves a temporary recording into the saved
    /// recordings directory. Saved recordings survive only after this call.
    @discardableResult
    func saveRecording(recordingID: UUID, fileExtension: String) throws -> URL {
        try saveRecording(recordingID: recordingID, fileExtension: fileExtension, destination: nil)
    }

    /// Explicit user action only: moves a temporary recording to the exact
    /// destination the user selected (for example through the native save
    /// panel), or into the saved recordings directory when no destination was
    /// chosen. Saved recordings survive only after this call.
    @discardableResult
    func saveRecording(recordingID: UUID, fileExtension: String, destination: URL?) throws -> URL {
        let source = try temporaryRecordingURL(recordingID: recordingID, fileExtension: fileExtension)
        guard fileManager.fileExists(atPath: source.path) else {
            throw DataStoreError.fileOperationFailed("no temporary recording exists to save")
        }
        let target: URL
        if let destination {
            guard destination.isFileURL, !destination.path.isEmpty else {
                throw DataStoreError.fileOperationFailed("the save destination is not a local file location")
            }
            target = destination
        } else {
            target = try savedRecordingURL(recordingID: recordingID, fileExtension: fileExtension)
        }
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try fileManager.moveItem(at: source, to: target)
        try? fileManager.removeItem(at: source.deletingLastPathComponent())
        return target
    }

    /// Deletes a temporary recording and verifies absence before reporting
    /// success. Returns whether a recording directory existed.
    @discardableResult
    func discardTemporaryRecording(recordingID: UUID) throws -> Bool {
        let directory = temporaryRecordingDirectory(recordingID: recordingID)
        let existed = fileManager.fileExists(atPath: directory.path)
        if existed {
            do {
                try fileManager.removeItem(at: directory)
            } catch {
                throw DataStoreError.fileOperationFailed("temporary recording could not be deleted")
            }
        }
        guard !fileManager.fileExists(atPath: directory.path) else {
            throw DataStoreError.fileOperationFailed("temporary recording still present after delete")
        }
        return existed
    }

    /// Session-start invariant: no audio persists across sessions.
    @discardableResult
    func purgeStaleTemporaryRecordings() throws -> Int {
        guard fileManager.fileExists(atPath: temporaryBaseURL.path) else { return 0 }
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: temporaryBaseURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw DataStoreError.fileOperationFailed("temporary storage could not be scanned")
        }
        var removed = 0
        for entry in entries {
            do {
                try fileManager.removeItem(at: entry)
                removed += 1
            } catch {
                throw DataStoreError.fileOperationFailed("stale temporary audio could not be removed")
            }
        }
        return removed
    }

    private static func sanitizedExtension(_ raw: String) throws -> String {
        let lowered = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !lowered.isEmpty,
              lowered.count <= 10,
              lowered.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            throw DataStoreError.fileOperationFailed("unsupported recording file extension")
        }
        return lowered
    }
}
