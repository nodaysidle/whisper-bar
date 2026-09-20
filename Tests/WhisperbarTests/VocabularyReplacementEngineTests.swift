import Foundation
import Testing
@testable import Whisperbar

/// TASK-05 (Stage 3 Seeded from SuperWhisper): Custom Vocabulary & Replacement Engine.
///
/// Tests case-insensitive word-boundary replacements, seeded vocabulary terms,
/// prefix-prioritization (longer matches first), and word-boundary safety.
@Suite("VocabularyReplacementEngine — seeded vocabulary and replacement rules")
struct VocabularyReplacementEngineTests {

    @Test("Replaces seeded phrases case-insensitively with exact identifiers")
    func seededPhraseReplacements() {
        let engine = VocabularyReplacementEngine()

        // "no days idle" / "no day idle" / "no decider" -> "nodaysidle"
        #expect(engine.replace(in: "I love no days idle project") == "I love nodaysidle project")
        #expect(engine.replace(in: "This is No Day Idle") == "This is nodaysidle")
        #expect(engine.replace(in: "I am a NO DECIDER on this") == "I am a nodaysidle on this")

        // "P R" / "pee ar dee" -> "PR" / "PRD"
        #expect(engine.replace(in: "Please review my P R now") == "Please review my PR now")
        #expect(engine.replace(in: "Read the pee ar dee first") == "Read the PRD first")

        // "ghosty" -> "Ghostty"
        #expect(engine.replace(in: "Open ghosty terminal") == "Open Ghostty terminal")
        #expect(engine.replace(in: "GHOSTY is fast") == "Ghostty is fast")

        // "post grass" -> "PostgreSQL"
        #expect(engine.replace(in: "Connect to post grass database") == "Connect to PostgreSQL database")

        // "swift ui" -> "SwiftUI"
        #expect(engine.replace(in: "Building with swift ui and appkit") == "Building with SwiftUI and appkit")

        // "audit" -> "AUDIT"
        #expect(engine.replace(in: "Run security audit today") == "Run security AUDIT today")
    }

    @Test("Longer phrase matches take precedence over shorter substrings")
    func longerPhrasePrecedence() {
        let engine = VocabularyReplacementEngine()

        // "no days idle architect" -> "nodaysidle-architect", not "nodaysidle architect"
        #expect(engine.replace(in: "Ask the no days idle architect") == "Ask the nodaysidle-architect")
        #expect(engine.replace(in: "Check with NO DAYS IDLE BUILDER") == "Check with nodaysidle-builder")
        #expect(engine.replace(in: "Dispatch no days idle scout") == "Dispatch nodaysidle-scout")
    }

    @Test("Respects word boundaries and avoids replacing partial words")
    func wordBoundaryIntegrity() {
        let engine = VocabularyReplacementEngine()

        // "audit" -> "AUDIT", but "auditing" or "auditor" should NOT be replaced partially
        #expect(engine.replace(in: "auditing the codebase") == "auditing the codebase")
        #expect(engine.replace(in: "the auditor arrived") == "the auditor arrived")
        #expect(engine.replace(in: "please audit the code") == "please AUDIT the code")
    }

    @Test("Replaces developer tools and agent identifiers")
    func developerIdentifiers() {
        let engine = VocabularyReplacementEngine()

        #expect(engine.replace(in: "Using clod code for pair programming") == "Using Claude Code for pair programming")
        #expect(engine.replace(in: "Use clawed code") == "Use Claude Code")
        #expect(engine.replace(in: "Running hermes agent") == "Running Hermes Agent")
        #expect(engine.replace(in: "Check super whisper settings") == "Check Superwhisper settings")
        #expect(engine.replace(in: "Logged in as omarchy user") == "Logged in as omarchyuser")
        #expect(engine.replace(in: "Review agents md and tasks md") == "Review AGENTS.md and TASKS.md")
    }

    @Test("Custom rules and JSON loading")
    func customRules() {
        let customRules = [
            ReplacementRule(original: "foo bar", with: "FooBar"),
            ReplacementRule(original: "baz qux", with: "BazQux")
        ]
        let engine = VocabularyReplacementEngine(rules: customRules, vocabulary: ["FooBar", "BazQux"])

        #expect(engine.replace(in: "Hello foo bar world") == "Hello FooBar world")
        #expect(engine.replace(in: "Testing BAZ QUX here") == "Testing BazQux here")
        #expect(engine.replace(in: "super whisper") == "super whisper") // default rules not in custom
    }

    @Test("Seeded vocabulary terms are loaded and non-empty")
    func seededVocabularyAvailable() {
        #expect(VocabularyReplacementEngine.seededVocabulary.count >= 280)
        #expect(VocabularyReplacementEngine.seededRules.count >= 130)
        #expect(VocabularyReplacementEngine.seededVocabulary.contains("PostgreSQL"))
        #expect(VocabularyReplacementEngine.seededVocabulary.contains("SwiftUI"))
        #expect(VocabularyReplacementEngine.seededVocabulary.contains("AGENTS.md"))
    }

    @Test("PasteCoordinator transforms insertion candidate with vocabulary replacement")
    @MainActor
    func pasteCoordinatorAppliesReplacement() {
        let candidate = PasteCoordinator.insertionCandidate(
            finalTranscript: "I love no days idle on ghosty with swift ui",
            refinedText: nil
        )
        #expect(candidate?.text == "I love nodaysidle on Ghostty with SwiftUI")

        let refinedCandidate = PasteCoordinator.insertionCandidate(
            finalTranscript: "original text",
            refinedText: "Please check with no days idle builder and hermes agent"
        )
        #expect(refinedCandidate?.text == "Please check with nodaysidle-builder and Hermes Agent")
    }

    @Test("CustomWritingModesAndVocabularyFeature includes seeded vocabulary in keyterms by default")
    @MainActor
    func customWritingModesIncludesSeededVocabulary() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }
        let store = sandbox.makeStore()
        let feature = CustomWritingModesAndVocabularyFeature(dataStore: store)
        #expect(await feature.load())

        let keyterms = feature.parameters.keyterms
        #expect(keyterms.contains("PostgreSQL"))
        #expect(keyterms.contains("SwiftUI"))
        #expect(keyterms.contains("NODAYSIDLE"))
        #expect(keyterms.contains("AGENTS.md"))
    }

    @Test("Engine can load from DataStore")
    func engineFromDataStore() async {
        let sandbox = DataStoreTests.makeSandbox()
        defer { sandbox.clean() }
        let store = sandbox.makeStore()
        let customTerm = VocabularyTerm(id: UUID().uuidString, term: "MyCustomSuperTerm", createdAt: Date())
        _ = try? await store.upsertVocabularyTerm(customTerm)

        let engine = await VocabularyReplacementEngine.from(dataStore: store)
        #expect(engine.vocabulary.contains("MyCustomSuperTerm"))
        #expect(engine.vocabulary.contains("PostgreSQL"))
    }
}

