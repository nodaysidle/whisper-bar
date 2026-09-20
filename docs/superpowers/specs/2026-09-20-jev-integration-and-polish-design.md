# Specification: WhisperBar Jev Integration, Menu Bar Polish & Custom Vocabulary

**Date:** 2026-09-20  
**Status:** Approved  
**Target Application:** WhisperBar (`com.whisperbar.app`)

---

## 1. Overview & Goals

WhisperBar is an ultra-fast, local-first macOS menu bar dictation app. This specification defines a three-stage upgrade:
1. **Stage 1: TypeSafe Jev Integration (System One API)** — Sub-150ms structured decision pipeline providing:
   - **Smart Refinement Gate**: Skips the slow and costly OpenRouter LLM refinement step for clean, grammatical speech, delivering instant auto-paste while preserving refinement for messy or complex thoughts.
   - **Target Context & Writing Mode Routing**: Inspects the frontmost application (tuned for **Ghostty** / fish shell / Herdr, **Bear**, **Safari**, **ChatGPT**, and **Antinote**) and speech content to automatically format text without manual mode toggling.
   - **Hallucination Guardrail**: Detects and drops phantom subtitle hallucinations (e.g., *"Thank you for watching"*, repeated hallucinated loops) caused by Whisper processing ambient noise or silence.
2. **Stage 2: Menu Bar Polish & Clean Window Lifecycle**:
   - Status item stability, notch margin compatibility, seamless activation policy transitions (`.accessory` to `.regular`), and focused window elevation.
   - Simplified, intuitive, low-noise GUI with clean Apple Human Interface Guidelines aesthetic.
3. **Stage 3: Custom Vocabulary & Exact Identifier Mapping**:
   - Injects domain terms into transcription provider prompts and applies deterministic word-boundary normalization for exact casing and acronyms (e.g., `nodaysidle`, `NDI`, `AUDIT`).

---

## 2. Architecture & Components

### 2.1 Platform Actor: `JevDecisionIntegration`
* **File:** `Sources/Whisperbar/Platform/JevDecisionIntegration.swift`
* **Interface:**
  ```swift
  actor JevDecisionIntegration {
      init(session: URLSession = .shared, apiKeyProvider: @escaping @Sendable () async -> String?)
      
      func evaluate(
          transcript: String,
          frontmostApp: String?
      ) async throws -> JevDecisionResult
  }
  
  struct JevDecisionResult: Equatable, Sendable {
      let isHallucination: Bool
      let hallucinationProbability: Double
      let recommendedWritingMode: String? // "code", "markdown", "prose", "prompt", "raw"
      let needsRefinement: Bool
      let refinementProbability: Double
      let latencyMs: Double
  }
  ```
* **Endpoint:** `POST https://api.typesafe.ai/v1/systemone`
* **Authentication:** `Bearer <TYPESAFE_API_KEY>`
* **Model:** `"jev-latest"`
* **Batch Payload:** Evaluates `is_hallucination` (noul), `writing_mode` (choice), and `needs_refinement` (noul) in a single request.

### 2.2 Security & Credentials: `CredentialVault`
* **File:** `Sources/Whisperbar/Platform/CredentialVault.swift`
* Add support for `typesafe-api-key` in macOS Keychain (`com.whisperbar.app.credentials`).
* Fallback to `ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"]` for zero-configuration local development and test suite execution.

### 2.3 Pipeline Wiring: `DualProviderRoutingFeature`
* **File:** `Sources/Whisperbar/Features/DualProviderRoutingFeature.swift`
* On receiving raw transcript $T$:
  1. Capture frontmost application name (e.g., `"Ghostty"`, `"Bear"`, `"Safari"`, `"ChatGPT"`, `"Antinote"`).
  2. If Jev is enabled:
     - Execute `evaluate(transcript: T, frontmostApp: app)`.
     - **Hallucination Branch:** If `isHallucination` ($p > 0.85$), abort paste and send HUD notice (*"Filtered background hallucination"*).
     - **Fast Path (Clean Speech):** If `needsRefinement` is false ($p < 0.30$), immediately forward raw text $T$ to `PasteCoordinator`. Bypasses LLM refinement, saving 1.5–2.5s of latency.
     - **Refinement Branch:** If `needsRefinement` is true ($p \ge 0.30$), pass transcript with detected mode parameters to `OpenrouterRefinementIntegration`.
  3. **Fail-Open Policy:** If Jev times out ($>1.2$s) or errors, log warning and gracefully proceed using standard WhisperBar settings.

---

## 3. UI/UX: Intuitive, Low-Noise Settings & HUD

* **Less Is More:** Eliminate visual noise, cluttered tables, and redundant borders.
* **Unified Control:** A single master card in Settings:
  - Header: **TypeSafe Jev Intelligence** (Status pill: *Active / Fast Mode*).
  - Toggle: *Smart Decision Engine* (Enables automated refinement gating and hallucination filtering).
  - Clean API key status indicator showing connection health.
* **Non-Intrusive HUD:**
  - Brief, elegant icon badge during dictation:
    - ⚡ *Instant Paste* (when Jev bypasses refinement).
    - ✨ *Refining...* (when Jev determines cleanup is needed).
    - 🛡️ *Ignored phantom audio* (when hallucination is intercepted).

---

## 4. User App & Vocabulary Calibration

### 4.1 Target App Contexts
* **Ghostty / fish / herdr**: Shell commands, flag syntax, snake_case/camelCase code identifiers.
* **Bear**: Markdown hierarchy, bullet points, task lists (`- [ ]`).
* **Safari**: Web text, prose, email composition.
* **ChatGPT**: Structured prompt directives.
* **Antinote**: Clean thought notes and scratchpad entries.

### 4.2 Custom Vocabulary & Replacements (Stage 3 Seeded from SuperWhisper)
* **Discovered Source:** `/Volumes/omarchyuser/projekti/nodaysidle-voice/UserData/superwhisper-dictionary.json`
* **Imported Assets:**
  - **290+ Technical Vocabulary Terms:** Injected into Deepgram `keywords` / OpenRouter Whisper prompt hints (e.g. `nodaysidle`, `NODAYSIDLE`, `omarchyuser`, `projekti`, `Ghostty`, `fish shell`, `Antinote`, `PRD.md`, `ARD.md`, `TRD.md`, `TASKS.md`, `tldraw`, etc.).
  - **130+ Deterministic Replacement Rules:** Case-insensitive word boundary substitutions post-transcription:
    - `"no days idle"`, `"no day idle"`, `"no day cider"`, `"no day cycle"`, `"no decider"` $\rightarrow$ `nodaysidle`
    - `"no days idle architect"` $\rightarrow$ `nodaysidle-architect`
    - `"no days idle builder"` $\rightarrow$ `nodaysidle-builder`
    - `"no days idle scout"` $\rightarrow$ `nodaysidle-scout`
    - `"super whisper"` $\rightarrow$ `Superwhisper`
    - `"type whisper"` $\rightarrow$ `TypeWhisper`
    - `"hermes agent"` $\rightarrow$ `Hermes Agent`
    - `"clod"`, `"clod code"`, `"cloud code"`, `"clawed code"` $\rightarrow$ `Claude` / `Claude Code`
    - `"anti note"` $\rightarrow$ `Antinote`
    - `"ghosty"` $\rightarrow$ `Ghostty`
    - `"post grass"`, `"postgress"` $\rightarrow$ `PostgreSQL`
    - `"swift ui"` $\rightarrow$ `SwiftUI`
    - `"agents md"` $\rightarrow$ `AGENTS.md`
    - `"tasks md"`, `"task md"` $\rightarrow$ `TASKS.md`
    - `"pee ar dee"`, `"P R D"` $\rightarrow$ `PRD`
    - `"pull request"`, `"P R"` $\rightarrow$ `PR`
    - `"audit"` $\rightarrow$ `AUDIT`

---

## 5. Verification & Testing Gates

1. **Mocked Unit Tests (`JevDecisionIntegrationTests.swift`):**
   - Verify request serialization against TypeSafe specification.
   - Verify deserialization of `noul` and `choice` response shapes.
   - Verify fail-open fallback on HTTP 500 or timeout.
2. **Feature Integration Tests (`DualProviderRoutingFeatureTests.swift`):**
   - Test fast-path bypass when `needs_refinement == false`.
   - Test paste cancellation when `is_hallucination == true`.
   - Test app context propagation into mode parameters.
3. **Build Gates:**
   - `swift test` exit status 0.
   - `swift build -c release` exit status 0.
