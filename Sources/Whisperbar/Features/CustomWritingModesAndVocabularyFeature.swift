import Foundation

// MARK: - Deterministic request parameters

/// The deterministic, value-free parameters this feature feeds into provider
/// requests. `modeID == nil` means the locked default behavior applies (no
/// custom prompt), which is also exactly what happens when custom settings are
/// invalid. `keyterms` is the validated, normalized, order-stable vocabulary
/// expansion.
struct WritingModeParameters: Equatable, Sendable {
    let modeID: String?
    let modeName: String?
    let modeInstructions: String?
    let keyterms: [String]

    var usesDefaultBehavior: Bool { modeID == nil }

    static let defaultBehavior = WritingModeParameters(
        modeID: nil,
        modeName: nil,
        modeInstructions: nil,
        keyterms: []
    )
}

// MARK: - CustomWritingModesAndVocabularyFeature

/// OWN-CUSTOM-WRITING-MODES-AND-VOCABULARY.
///
/// Owns CON-CUSTOM-WRITING-MODES-AND-VOCABULARY-INTERFACE and
/// CON-CUSTOM-WRITING-MODES-AND-VOCABULARY-RECOVERY: stored writing modes and
/// vocabulary are validated, normalized, and fed deterministically into
/// refinement and transcription requests (the locked OpenRouter refinement
/// payload and Deepgram streaming keyterm hints). An invalid custom mode or
/// vocabulary entry is never applied: the user is notified, the default
/// behavior is used, the last valid state is preserved, and recovery is an
/// explicit retry. Provider credentials stay exclusively with the
/// CredentialVault-backed integrations; this feature never sees secret
/// material and never writes to the network itself.
@MainActor
final class CustomWritingModesAndVocabularyFeature {

    // MARK: States

    enum State: Equatable, Sendable {
        case idle
        case active
        case succeeded
        case failed(Failure)
        case cancelled
    }

    enum FailureCategory: Equatable, Sendable {
        case invalidMode
        case invalidTerm
        case duplicateTerm
        case unknownModeSelection
        case storageUnavailable
        case saveFailed
        case deleteFailed
        case loadFailed
    }

    struct Failure: Equatable, Sendable {
        let category: FailureCategory
        let message: String
    }

    enum Action: Equatable, Sendable {
        case configurationLoaded
        case modeSaved(String)
        case modeDeleted(String)
        /// `nil` clears the explicit selection: the stored default mode (if
        /// any) or the locked default behavior applies.
        case modeSelected(String?)
        case vocabularyTermAdded(String)
        case vocabularyTermRemoved(String)
    }

    // MARK: Observable state

    private(set) var state: State = .idle
    private(set) var modes: [WritingMode] = []
    private(set) var vocabularyTerms: [VocabularyTerm] = []
    /// Explicit user selection; in-memory only, preserving the last valid
    /// user state across failures.
    private(set) var activeModeID: String?
    private(set) var lastFailure: Failure?
    private(set) var lastNotice: String?
    private(set) var lastAction: Action?

    // MARK: Dependencies

    private let dataStore: DataStore
    private let now: @Sendable () -> Date

    init(dataStore: DataStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.dataStore = dataStore
        self.now = now
    }

    // MARK: Effective mode resolution

    /// The mode currently in effect: the explicit selection when valid, then
    /// a stored mode flagged `isDefault`, then the locked default behavior
    /// (`nil`). Invalid stored modes are never applied.
    var effectiveMode: WritingMode? {
        if let activeModeID,
           let selected = modes.first(where: { $0.id == activeModeID && Self.isValid($0) }) {
            return selected
        }
        return modes.first { $0.isDefault && Self.isValid($0) }
    }

    /// The deterministic request parameters every provider call site reads.
    /// Identical stored state always produces identical values.
    var parameters: WritingModeParameters {
        let mode = effectiveMode
        return WritingModeParameters(
            modeID: mode?.id,
            modeName: mode?.name,
            modeInstructions: mode?.instructions,
            keyterms: Self.normalizedKeyterms(from: vocabularyTerms)
        )
    }

    /// The locked OpenRouter refinement payload for this configuration. The
    /// mode lines are omitted entirely when the default behavior applies.
    func refinementPayload(rawTranscript: String) -> String {
        let mode = effectiveMode
        return OpenrouterRefinementIntegration.userPayload(
            rawTranscript: rawTranscript,
            modeName: mode?.name,
            modeInstructions: mode?.instructions
        )
    }

    // MARK: Load and retry

    /// Loads the stored writing modes and vocabulary. Storage unavailability
    /// keeps the last valid in-memory state, uses the default behavior, and
    /// reports honestly instead of pretending to load.
    @discardableResult
    func load() async -> Bool {
        state = .active
        let storedModes: [WritingMode]
        let storedTerms: [VocabularyTerm]
        do {
            storedModes = try await dataStore.writingModes()
            storedTerms = try await dataStore.vocabularyTerms()
        } catch {
            lastFailure = Failure(
                category: .storageUnavailable,
                message: "Writing modes and vocabulary could not be loaded from local storage. The default behavior is used; retry explicitly when storage is available."
            )
            state = .failed(lastFailure!)
            return false
        }

        modes = storedModes
        vocabularyTerms = storedTerms
        recordStoredValidationNotices()
        state = .succeeded
        lastFailure = nil
        lastAction = .configurationLoaded
        return true
    }

    /// Explicit user retry of the last load (CON-CUSTOM-WRITING-MODES-AND-VOCABULARY-RECOVERY).
    @discardableResult
    func retry() async -> Bool {
        await load()
    }

    // MARK: Writing mode management

    /// Saves or replaces one writing mode. An invalid mode is rejected before
    /// any write, the user is notified, and the previous configuration stays.
    @discardableResult
    func saveMode(_ mode: WritingMode) async -> Bool {
        state = .active
        guard Self.isValid(mode) else {
            return fail(
                .invalidMode,
                message: "That writing mode is invalid: a name and instructions are required. The previous mode stays active and the default behavior is used where no valid mode applies."
            )
        }

        do {
            try await dataStore.upsertWritingMode(mode)
        } catch {
            return fail(
                .saveFailed,
                message: "The writing mode could not be saved. The previous configuration is unchanged and the default behavior is used where no valid mode applies."
            )
        }

        do {
            modes = try await dataStore.writingModes()
        } catch {
            return fail(
                .loadFailed,
                message: "The writing mode was saved, but the stored modes could not be reloaded. The last valid state is kept; retry explicitly."
            )
        }

        state = .succeeded
        lastFailure = nil
        lastAction = .modeSaved(mode.id)
        lastNotice = "Saved the \(mode.name) writing mode."
        return true
    }

    /// Deletes one writing mode. Deleting the active mode falls back to the
    /// stored default mode or the locked default behavior, with a notice.
    @discardableResult
    func deleteMode(id: String) async -> Bool {
        state = .active
        let deletedName = modes.first { $0.id == id }?.name
        do {
            try await dataStore.deleteWritingMode(id: id)
        } catch {
            return fail(
                .deleteFailed,
                message: "The writing mode could not be deleted. The previous configuration is unchanged."
            )
        }

        modes = (try? await dataStore.writingModes()) ?? modes.filter { $0.id != id }
        if activeModeID == id {
            activeModeID = nil
            lastNotice = "Deleted the \(deletedName ?? "selected") writing mode. The default behavior is used where no other valid mode applies."
        } else {
            lastNotice = "Deleted the \(deletedName ?? "selected") writing mode."
        }
        state = .succeeded
        lastFailure = nil
        lastAction = .modeDeleted(id)
        return true
    }

    /// Explicitly selects a stored mode, or clears the selection with `nil`.
    /// An unknown or invalid mode is rejected and the last valid selection
    /// stays in effect.
    @discardableResult
    func selectMode(id: String?) -> Bool {
        guard let id else {
            activeModeID = nil
            state = .succeeded
            lastFailure = nil
            lastAction = .modeSelected(nil)
            lastNotice = "Custom writing modes are off. The stored default mode or the default behavior applies."
            return true
        }

        guard let mode = modes.first(where: { $0.id == id }), Self.isValid(mode) else {
            return fail(
                .unknownModeSelection,
                message: "That writing mode is not available or is invalid. The previous selection is unchanged and the default behavior is used where no valid mode applies."
            )
        }

        activeModeID = id
        state = .succeeded
        lastFailure = nil
        lastAction = .modeSelected(id)
        lastNotice = "Selected the \(mode.name) writing mode."
        return true
    }

    // MARK: Vocabulary management

    /// Adds one vocabulary term after validation. Invalid and duplicate
    /// entries are rejected and reported without changing the list.
    @discardableResult
    func addVocabularyTerm(_ term: String) async -> Bool {
        state = .active
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidTerm(trimmed) else {
            return fail(
                .invalidTerm,
                message: "That vocabulary term is invalid. Use 1–\(DeepgramNovaStreamingTranscriptionIntegration.maxKeytermLength) characters without control characters; the existing vocabulary is unchanged."
            )
        }

        let record = VocabularyTerm(id: UUID().uuidString, term: trimmed, createdAt: now())
        do {
            try await dataStore.upsertVocabularyTerm(record)
        } catch DataStoreError.duplicateRecord {
            return fail(
                .duplicateTerm,
                message: "That vocabulary term is already in the list. Vocabulary expansion is unchanged."
            )
        } catch {
            return fail(
                .saveFailed,
                message: "The vocabulary term could not be saved. The existing vocabulary is unchanged."
            )
        }

        vocabularyTerms = (try? await dataStore.vocabularyTerms()) ?? vocabularyTerms
        state = .succeeded
        lastFailure = nil
        lastAction = .vocabularyTermAdded(trimmed)
        lastNotice = "Added the “\(trimmed)” vocabulary term."
        return true
    }

    /// Removes one vocabulary term. The list is reloaded from storage so the
    /// deterministic expansion always reflects the durable state.
    @discardableResult
    func removeVocabularyTerm(id: String) async -> Bool {
        state = .active
        let removedTerm = vocabularyTerms.first { $0.id == id }?.term
        do {
            try await dataStore.deleteVocabularyTerm(id: id)
        } catch {
            return fail(
                .deleteFailed,
                message: "The vocabulary term could not be removed. The existing vocabulary is unchanged."
            )
        }

        vocabularyTerms = (try? await dataStore.vocabularyTerms()) ?? vocabularyTerms.filter { $0.id != id }
        state = .succeeded
        lastFailure = nil
        lastAction = .vocabularyTermRemoved(removedTerm ?? id)
        lastNotice = removedTerm.map { "Removed the “\($0)” vocabulary term." } ?? "Removed the vocabulary term."
        return true
    }

    // MARK: Deterministic normalization

    /// The one vocabulary expansion used by every provider request: trimmed,
    /// validated, case-insensitively deduplicated, and stably ordered.
    static func normalizedKeyterms(from terms: [VocabularyTerm]) -> [String] {
        normalizedKeyterms(fromWords: terms.map(\.term))
    }

    static func normalizedKeyterms(fromWords words: [String]) -> [String] {
        let valid = words
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { Self.isValidTerm($0) }

        let ordered = valid.sorted { lhs, rhs in
            let left = lhs.lowercased()
            let right = rhs.lowercased()
            return left == right ? lhs < rhs : left < right
        }

        var seen = Set<String>()
        var result: [String] = []
        for term in ordered where seen.insert(term.lowercased()).inserted {
            result.append(term)
        }
        return result
    }

    /// A mode is valid only with an id, a name, and instructions.
    static func isValid(_ mode: WritingMode) -> Bool {
        !mode.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !mode.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !mode.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A term is valid only within the locked Deepgram keyterm boundary.
    static func isValidTerm(_ term: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= DeepgramNovaStreamingTranscriptionIntegration.maxKeytermLength else {
            return false
        }
        return trimmed.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    // MARK: Failure recording

    @discardableResult
    private func fail(_ category: FailureCategory, message: String) -> Bool {
        let failure = Failure(category: category, message: message)
        lastFailure = failure
        state = .failed(failure)
        return false
    }

    /// After a load, invalid stored entries are ignored (never applied) and
    /// the user is told so; a dangling selection falls back to the default.
    private func recordStoredValidationNotices() {
        var notes: [String] = []

        if let activeModeID,
           !modes.contains(where: { $0.id == activeModeID && Self.isValid($0) }) {
            self.activeModeID = nil
            notes.append("The selected writing mode is no longer valid, so the default behavior is used.")
        }

        let invalidModes = modes.filter { !Self.isValid($0) }
        if !invalidModes.isEmpty {
            notes.append("\(invalidModes.count) stored writing mode(s) were invalid and are ignored; the last valid selection or the default behavior is used.")
        }

        let invalidTerms = vocabularyTerms.map(\.term).filter { !Self.isValidTerm($0) }
        if !invalidTerms.isEmpty {
            notes.append("\(invalidTerms.count) vocabulary term(s) were invalid and are ignored; only the valid terms are applied consistently.")
        }

        if !notes.isEmpty {
            lastNotice = notes.joined(separator: " ")
        }
    }
}
