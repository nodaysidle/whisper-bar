# WhisperBar v1.1.0 Release Notes

WhisperBar v1.1.0 introduces major performance, intelligence, and UI enhancements: **TypeSafe Jev System One decision integration** for sub-150ms smart refinement gating, **SuperWhisper custom vocabulary & replacement engine**, and a complete **Menu Bar & low-noise GUI polish**.

---

## What's New in v1.1.0

### 🧠 TypeSafe Jev System One Intelligence
- **Sub-150ms Structured Decision Engine:** Evaluates raw transcripts post-transcription using TypeSafe's `POST /v1/systemone` (`jev-latest`) model.
- **⚡ Smart Refinement Gate (Huge Latency & Token Saver):** Fast-paths clean, coherent speech ($p < 0.30$) directly to paste in under 150ms, bypassing the slower OpenRouter LLM step. Refinement is invoked only when speech contains filler words, stuttering, or structural disfluencies.
- **🎯 Context-Aware Writing Mode Routing:** Detects the active frontmost application (`Ghostty` / fish shell / Herdr $\rightarrow$ `code`, `Bear` $\rightarrow$ `markdown`, `Safari` $\rightarrow$ `prose`, `ChatGPT` $\rightarrow$ `prompt`, `Antinote` $\rightarrow$ `notes`) to automatically format output without manual mode toggling.
- **🛡️ Hallucination Guardrail:** Intercepts and silently drops phantom Whisper subtitle artifacts (e.g. *"Thank you for watching"*, repeating silence loops with $p > 0.85$), alerting the HUD without polluting your target document.
- **Fail-Open Resilience:** Network dropouts or API timeouts gracefully fall back to standard WhisperBar behavior without stalling your dictation.

### 📚 SuperWhisper Custom Vocabulary & Replacement Engine
- **Seeded from Production Dictionary:** Directly imports **288 technical vocabulary terms** and **264 exact replacement rules** from SuperWhisper (`superwhisper-dictionary.json`).
- **Deterministic Word-Boundary Normalization:** Pre-compiled regex engine normalizes text before insertion:
  - `"no days idle"`, `"no day idle"`, `"no day cider"`, `"no decider"` $\rightarrow$ `nodaysidle`
  - `"no days idle architect"` $\rightarrow$ `nodaysidle-architect`
  - `"no days idle builder"` $\rightarrow$ `nodaysidle-builder`
  - `"no days idle scout"` $\rightarrow$ `nodaysidle-scout`
  - `"P R"`, `"pee ar dee"` $\rightarrow$ `PR`, `PRD`
  - `"ghosty"` $\rightarrow$ `Ghostty`
  - `"anti note"` $\rightarrow$ `Antinote`
  - `"post grass"`, `"postgress"` $\rightarrow$ `PostgreSQL`
  - `"swift ui"` $\rightarrow$ `SwiftUI`
  - `"audit"` $\rightarrow$ `AUDIT`
- **Provider Keyterm Hints:** Seamlessly feeds vocabulary terms into Deepgram streaming query parameters and OpenRouter refinement prompts.

### 💎 Menu Bar Polish & Calm, Intuitive UI
- **Low-Noise Settings View:** Redesigned with grouped Apple HIG native hierarchy; eliminates visual noise, harsh borders, and redundant text. Includes a dedicated **TypeSafe Jev Intelligence** control panel.
- **Minimalist Floating HUD Capsule:** Modernized into a quiet `.regularMaterial` capsule with 1.8-second auto-dismissing status pills:
  - ⚡ *Instant Paste* (bypassed LLM on clean speech)
  - ✨ *Refining...* $\rightarrow$ ✨ *Refined* (in-flight & completed LLM formatting)
  - 🛡️ *Ignored phantom audio* (hallucination intercepted)
- **Robust Activation Policy Transitions:** Elevates to `.regular` (dock icon, foreground focus, standard macOS Cmd+C/V/Z menus) when Settings is open, and cleanly reverts to `.accessory` (pure background menu-bar daemon) when closed.
- **Display & Notch Resilience:** Dynamic notch margin awareness and display reconfiguration observers.

---

## Verification & Quality Gates

- **Swift Test Suite:** 299 tests in 22 suites passed (`0 failures`, 1.54s).
- **Swift 6 Strict Concurrency:** Verified across all actors, `@Observable` view models, and `Sendable` payloads.
- **Release Build:** Optimized native ARM64 release binary compiled for macOS 14.0+.
- **Code Signing:** Verified via `codesign --verify --deep --strict`.
- **Installed & Tested:** Running locally at `/Applications/WhisperBar.app`.

---

## Checksums

| File | SHA-256 Checksum |
|---|---|
| `WhisperBar.dmg` | `5e330b2a503190f18d456498ad5a81d9f4a81f2ddfb05b9903acdf12f2c4179f` |
| `WhisperBar.app` | Embedded Bundle Identifier `com.whisperbar.app` |
