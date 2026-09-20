# WhisperBar v1.0.0 Release Notes

WhisperBar is a privacy-first, lightning-fast native macOS menu bar dictation utility built with Swift 6 and SwiftUI. It bridges speech directly into your active application with zero friction, offering real-time streaming transcription, smart post-processing, and full clipboard safety.

---

## What's New in v1.0.0

### 🎙️ Dual-Provider Speech Architecture
- **Deepgram Nova-3 Streaming**: Sub-second interim transcripts streamed directly through WebSockets as you speak.
- **OpenRouter Audio Batch Fallback**: Complete batch transcription with OpenAI Whisper Large v3 for resilient processing.
- **AI Text Refinement**: Optional post-transcription LLM formatting and grammar cleanup via OpenRouter without overwriting raw transcripts.

### ⌨️ Global Hotkeys & Push-to-Talk Modes
- **Fn / Globe Key Push-to-Talk**: Hold Fn to dictate; release to automatically paste into your frontmost application.
- **Karabiner Hyperkey Preset**: Out-of-the-box support for `Hyper+Space` (`Cmd+Ctrl+Opt+Shift+Space`).
- **Flexible Trigger Modes**: Both Push-to-Talk and Toggle Recording supported with customizable shortcuts.

### 📋 Safe Auto-Paste & Clipboard Preservation
- Automatically restores prior clipboard contents after pasting dictations.
- Fallback notification and one-click copy if Accessibility / CGEvent permissions are not granted.

### 🔍 Local-First History & Search
- Bounded SQLite storage in Application Support sandbox.
- Offline full-text search across all recorded transcripts.
- Strict data privacy: no third-party telemetry, no cloud storage of audio.

### ⚙️ Native Settings & Dock Elevation
- Independent Settings window elevated to a foreground app with Dock representation and app switcher focus.
- Secure credential management backed by macOS Keychain.
- Customizable writing modes, prompt vocabulary, and input audio devices.

---

## Verification & Quality Gates

- **Swift Test Suite**: 268 tests in 19 suites passed (`0 failures`).
- **Swift 6 Strict Concurrency**: Strict concurrency checked and verified.
- **Release Build**: Compiled with release optimizations for Apple Silicon (`arm64`, macOS 14.0+).
- **Code Signing**: Validated with `codesign --verify --deep --strict`.
- **DMG Integrity**: Generated via `hdiutil` and verified for distribution.

---

## Checksums

| File | SHA-256 Checksum |
|---|---|
| `WhisperBar.dmg` | `45431bb6d934f08cedbb7aa43c373cbba6045d55b36643b35706e7225a10d0af` |
