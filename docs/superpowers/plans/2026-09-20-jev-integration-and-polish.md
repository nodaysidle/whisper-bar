# WhisperBar Jev Integration, Polish & Vocabulary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate TypeSafe Jev structured decisions into WhisperBar for sub-150ms refinement gating, automated context-aware writing modes, and hallucination filtering; polish the Menu Bar GUI to be low-noise and intuitive; and import the 290+ custom vocabulary words and 130+ replacement rules from SuperWhisper.

**Architecture:** A platform actor `JevDecisionIntegration` connects to TypeSafe's `POST /v1/systemone` endpoint. `DualProviderRoutingFeature` invokes Jev post-transcription to fast-path clean speech straight to paste, apply context-aware modes for Ghostty/Bear/Safari/ChatGPT/Antinote, or filter hallucinations. A new `VocabularyReplacementEngine` performs deterministic post-transcription regex substitution for exact casing and acronyms seeded from the user's SuperWhisper dictionary.

**Tech Stack:** Swift 6, SwiftUI, AppKit, URLSession, Keychain, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-20-jev-integration-and-polish-design.md`

## Global Constraints
- Swift 6 strict concurrency (`@Observable`, `Sendable`, actors, `@MainActor`).
- URLSession boundary: typed Codable DTOs, fail-open on network or API failures.
- No plaintext secrets in source or logs; use Keychain with env var fallback (`TYPESAFE_API_KEY`).
- Keep UI low-noise, calm, and strictly compliant with Apple Human Interface Guidelines.
- All tests must pass with `swift test` exit status 0.

---

### Task 1: TypeSafe Jev Integration & Credential Vault Support

**Files:**
- Create: `Sources/Whisperbar/Platform/JevDecisionIntegration.swift`
- Modify: `Sources/Whisperbar/Platform/CredentialVault.swift`
- Test: `Tests/WhisperbarTests/JevDecisionIntegrationTests.swift`

**Interfaces:**
- Produces: `actor JevDecisionIntegration` with `func evaluate(transcript: String, frontmostApp: String?) async throws -> JevDecisionResult`
- Produces: `JevDecisionResult(isHallucination: Bool, hallucinationProbability: Double, recommendedWritingMode: String?, needsRefinement: Bool, refinementProbability: Double, latencyMs: Double)`
- Modifies: `CredentialVault` with `storeTypesafeKey(_:)`, `loadTypesafeKey()`, `deleteTypesafeKey()`

- [ ] **Step 1: Write unit tests for JevDecisionIntegration**
  Create `Tests/WhisperbarTests/JevDecisionIntegrationTests.swift` testing request serialization, response deserialization (handling `noul` and `choice`), latency measurement, and fail-open handling.
- [ ] **Step 2: Run test to verify failure**
  Run: `swift test --filter JevDecisionIntegrationTests`
  Expected: FAIL with compilation error (types not found).
- [ ] **Step 3: Implement CredentialVault support and JevDecisionIntegration**
  Add `typesafeKeychainAccount` to `CredentialVault.swift` with Keychain and `TYPESAFE_API_KEY` fallback.
  Implement `Sources/Whisperbar/Platform/JevDecisionIntegration.swift` with typed `SystemOneRequest`, `SystemOneResponse`, and error mapping.
- [ ] **Step 4: Run test to verify it passes**
  Run: `swift test --filter JevDecisionIntegrationTests`
  Expected: PASS.
- [ ] **Step 5: Commit**
  ```bash
  git add Sources/Whisperbar/Platform/JevDecisionIntegration.swift Sources/Whisperbar/Platform/CredentialVault.swift Tests/WhisperbarTests/JevDecisionIntegrationTests.swift
  git commit -m "feat: implement JevDecisionIntegration and Typesafe credential vault support"
  ```

---

### Task 2: Pipeline Wiring in DualProviderRoutingFeature

**Files:**
- Modify: `Sources/Whisperbar/Features/DualProviderRoutingFeature.swift`
- Test: `Tests/WhisperbarTests/DualProviderRoutingFeatureTests.swift`

**Interfaces:**
- Consumes: `JevDecisionIntegration.evaluate(transcript:frontmostApp:)`
- Produces: Fast-path bypass to `PasteCoordinator` when `needsRefinement == false`
- Produces: Hallucination filter aborting paste when `isHallucination == true`
- Produces: Frontmost app context detection (supporting Ghostty, Bear, Safari, ChatGPT, Antinote)

- [ ] **Step 1: Add failing integration tests for Jev pipeline routing**
  In `Tests/WhisperbarTests/DualProviderRoutingFeatureTests.swift`, add tests asserting:
  - Hallucination detection skips paste and triggers HUD notice.
  - Clean speech (`needsRefinement == false`) bypasses OpenRouter refinement directly to paste.
  - App context ("Ghostty", "Bear", etc.) correctly populates writing mode parameters.
- [ ] **Step 2: Run tests to verify failure**
  Run: `swift test --filter DualProviderRoutingFeatureTests`
  Expected: FAIL.
- [ ] **Step 3: Wire Jev into DualProviderRoutingFeature**
  Inject `JevDecisionIntegration` into `DualProviderRoutingFeature`. Query `NSWorkspace.shared.frontmostApplication?.localizedName`. Execute parallel Jev evaluation post-transcription, branch on hallucination/fast-path/refinement, and implement fail-open fallback.
- [ ] **Step 4: Run tests to verify they pass**
  Run: `swift test --filter DualProviderRoutingFeatureTests`
  Expected: PASS.
- [ ] **Step 5: Commit**
  ```bash
  git add Sources/Whisperbar/Features/DualProviderRoutingFeature.swift Tests/WhisperbarTests/DualProviderRoutingFeatureTests.swift
  git commit -m "feat: wire Jev decision engine into DualProviderRoutingFeature"
  ```

---

### Task 3: Settings & HUD Polish (Calm, Intuitive, Low-Noise UI)

**Files:**
- Modify: `Sources/Whisperbar/SettingsWindow.swift`
- Modify: `Sources/Whisperbar/Features/MicrophoneCaptureAndFloatingHudFeature.swift`
- Modify: `Sources/Whisperbar/MenuBarController.swift`

**Interfaces:**
- Produces: Clean, low-noise TypeSafe Jev settings section with API key management and smart decision toggle.
- Produces: Minimalist HUD status pills: ⚡ *Instant Paste*, ✨ *Refining...*, 🛡️ *Ignored phantom audio*.

- [ ] **Step 1: Write UI/State tests for Jev settings and HUD badges**
  Verify settings persistence and HUD state transitions when Jev fast-paths or filters text.
- [ ] **Step 2: Run tests to verify current status**
  Run: `swift test --filter MicrophoneCaptureAndFloatingHudFeatureTests`
- [ ] **Step 3: Implement clean, low-noise Settings view and HUD badges**
  Refactor `SettingsWindow.swift` to remove visual clutter and add a sleek TypeSafe Jev card.
  Update HUD in `MicrophoneCaptureAndFloatingHudFeature.swift` with elegant, non-intrusive status indicators.
- [ ] **Step 4: Run test suite**
  Run: `swift test`
  Expected: PASS.
- [ ] **Step 5: Commit**
  ```bash
  git add Sources/Whisperbar/SettingsWindow.swift Sources/Whisperbar/Features/MicrophoneCaptureAndFloatingHudFeature.swift Sources/Whisperbar/MenuBarController.swift
  git commit -m "feat: polish Settings and HUD with low-noise UI and Jev controls"
  ```

---

### Task 4: Menu Bar Polish & Window Activation Lifecycle

**Files:**
- Modify: `Sources/Whisperbar/MenuBarController.swift`
- Test: `Tests/WhisperbarTests/LifecycleCoordinatorTests.swift`

**Interfaces:**
- Produces: Robust `NSStatusItem` initialization and notch margin handling.
- Produces: Flawless activation policy transitions between `.accessory` and `.regular` for window elevation.

- [ ] **Step 1: Write lifecycle tests for activation policy and window presentation**
  Verify transition to `.regular` on window open and revert to `.accessory` on close.
- [ ] **Step 2: Run tests**
  Run: `swift test --filter LifecycleCoordinatorTests`
- [ ] **Step 3: Implement robust MenuBarController window and status item polish**
  Ensure status item icon is crisp and always visible. Handle app reopening, window key status, and dock visibility cleanly without menu bar glitches.
- [ ] **Step 4: Run tests to verify passing**
  Run: `swift test --filter LifecycleCoordinatorTests`
  Expected: PASS.
- [ ] **Step 5: Commit**
  ```bash
  git add Sources/Whisperbar/MenuBarController.swift Tests/WhisperbarTests/LifecycleCoordinatorTests.swift
  git commit -m "fix: polish MenuBarController activation policy and status item lifecycle"
  ```

---

### Task 5: Custom Vocabulary & Replacement Engine (Stage 3 Seeded from SuperWhisper)

**Files:**
- Create: `Sources/Whisperbar/Platform/VocabularyReplacementEngine.swift`
- Modify: `Sources/Whisperbar/Features/CustomWritingModesAndVocabularyFeature.swift`
- Modify: `Sources/Whisperbar/Features/PasteCoordinator.swift`
- Test: `Tests/WhisperbarTests/VocabularyReplacementEngineTests.swift`

**Interfaces:**
- Produces: `struct VocabularyReplacementEngine` with `func replace(in text: String) -> String`
- Seeds: 290+ terms and 130+ exact replacement rules from `/Volumes/omarchyuser/projekti/nodaysidle-voice/UserData/superwhisper-dictionary.json`
- Modifies: `PasteCoordinator` to apply normalization before clipboard paste.

- [ ] **Step 1: Write tests for VocabularyReplacementEngine**
  Create `Tests/WhisperbarTests/VocabularyReplacementEngineTests.swift` asserting replacement of:
  - "no days idle" / "no day idle" / "no decider" $\rightarrow$ "nodaysidle"
  - "P R" / "pee ar dee" $\rightarrow$ "PR" / "PRD"
  - "ghosty" $\rightarrow$ "Ghostty"
  - "post grass" $\rightarrow$ "PostgreSQL"
  - "swift ui" $\rightarrow$ "SwiftUI"
  - "audit" $\rightarrow$ "AUDIT"
- [ ] **Step 2: Run tests to verify failure**
  Run: `swift test --filter VocabularyReplacementEngineTests`
  Expected: FAIL.
- [ ] **Step 3: Implement VocabularyReplacementEngine and wire into pipeline**
  Implement regex word-boundary replacement engine seeded with the SuperWhisper dictionary. Wire into `PasteCoordinator` and vocabulary hint feeding in `CustomWritingModesAndVocabularyFeature`.
- [ ] **Step 4: Run tests to verify passing**
  Run: `swift test --filter VocabularyReplacementEngineTests`
  Expected: PASS.
- [ ] **Step 5: Commit**
  ```bash
  git add Sources/Whisperbar/Platform/VocabularyReplacementEngine.swift Sources/Whisperbar/Features/CustomWritingModesAndVocabularyFeature.swift Sources/Whisperbar/Features/PasteCoordinator.swift Tests/WhisperbarTests/VocabularyReplacementEngineTests.swift
  git commit -m "feat: implement VocabularyReplacementEngine seeded from SuperWhisper dictionary"
  ```

---

### Task 6: Full Verification Gate & Release Build

**Files:**
- Test: All tests in `Tests/WhisperbarTests/`
- Build: `dist/WhisperBar.app`

- [ ] **Step 1: Run full test suite**
  Run: `swift test`
  Expected: All tests pass with exit status 0.
- [ ] **Step 2: Build release binary**
  Run: `swift build -c release`
  Expected: Build succeeds with exit status 0.
- [ ] **Step 3: Package application bundle**
  Run: `./Scripts/package_app.sh`
  Expected: `dist/WhisperBar.app` created and verified.
- [ ] **Step 4: Verify code signature**
  Run: `codesign --verify --deep --strict "dist/WhisperBar.app"`
  Expected: Valid signature, exit status 0.
