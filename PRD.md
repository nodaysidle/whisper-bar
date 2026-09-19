# Product Requirements Document — WhisperBar

## Document Purpose

Define the product boundary, users, problems, goals, journeys, feature outcomes, success criteria, and explicit scope without implementation invention.

## Product Definition

A privacy-conscious native macOS menu-bar speech-to-text utility that captures speech via push-to-talk or toggle recording, transcribes through an explicitly selected cloud service, and safely inserts or preserves the result. It keeps transcripts local, protects credentials, and never silently switches providers or incurs unexpected costs.

## Problem Statement

People who dictate directly into whichever macOS application currently has focus (editors, browsers, chat, email). need a focused way to enable reliable global push-to-talk and toggle dictation from any macOS app without do not automatically switch transcription providers or incur costs without explicit user action.

## Target Users

- People who dictate directly into whichever macOS application currently has focus (editors, browsers, chat, email).
- Professionals who need fast, hands-free text entry without leaving their current app.
- Privacy-conscious users who want local transcript history and explicit control over cloud transcription.
- Writers and note-takers who use custom writing modes and vocabulary for consistent output.

## Goals

- Enable reliable global push-to-talk and toggle dictation from any macOS app.
- Provide clear visual feedback during capture with a minimal floating HUD.
- Route transcription through an explicitly selected provider without automatic switching.
- Insert transcribed text safely into the focused app while preserving the previous clipboard.
- Store transcripts locally with search, copy, and deletion, without external sync.
- Protect API credentials using secure macOS storage and never log or persist them insecurely.
- Guarantee temporary audio cleanup after successful transcription or cancellation.
- Support custom writing modes and vocabulary for deterministic refinement.

## Non-Goals

- Do not automatically switch transcription providers or incur costs without explicit user action.
- Do not upload, sync, or back up transcripts to external clouds.
- Do not store API keys in UserDefaults, files, or application logs.
- Do not retain audio files after successful transcription or cancellation.
- Do not block or override system shortcuts when registering global hotkeys.
- Do not provide a full document editor or note-taking workspace.
- Do not support non-macOS platforms.
- Do not offer offline or on-device transcription.

## Primary User Journeys

### Global Hotkeys and Push-to-Talk/Toggle Modes outcome

- Actor: People who dictate directly into whichever macOS application currently has focus (editors, browsers, chat, email).
- Steps: User presses the configured push-to-talk or toggle hotkey. → Registers global hotkeys safely, detects conflicts, handles smooth release, and supports both push-to-talk and toggle recording modes.
- Outcome: Start and stop dictation from any app using configurable global hotkeys without blocking system shortcuts.

### Microphone Capture and Floating HUD outcome

- Actor: People who dictate directly into whichever macOS application currently has focus (editors, browsers, chat, email).
- Steps: Recording starts via hotkey. → Captures microphone audio and displays a floating HUD with live input levels, elapsed duration, active mode, and instant stop/cancel controls.
- Outcome: See capture state, audio levels, elapsed time, active mode, and stop/cancel actions in a minimal floating HUD.

### Dual-Provider Routing outcome

- Actor: People who dictate directly into whichever macOS application currently has focus (editors, browsers, chat, email).
- Steps: User selects a provider before recording. → Routes audio to Deepgram for live WebSocket streaming with interim results and automatic finalization, or to OpenRouter for finalized audio batch transcription with optional text refinement using Gemini 2.5 Flash Lite.
- Outcome: Transcribe speech using live streaming or batch transcription, depending on the selected provider.

### Provider Selection and Cost Protection outcome

- Actor: People who dictate directly into whichever macOS application currently has focus (editors, browsers, chat, email).
- Steps: User opens provider selection or starts recording. → Requires an explicit provider toggle before recording; never automatically switches providers or silently incurs costs.
- Outcome: Avoid unexpected costs by explicitly choosing a provider before recording.

### Safe Auto-Paste and Clipboard Preservation outcome

- Actor: People who dictate directly into whichever macOS application currently has focus (editors, browsers, chat, email).
- Steps: Transcription completes successfully. → After one successful final transcription and optional successful refinement, choose exactly one complete insertion candidate and apply the configured auto-paste, copy-only, or preview mode through the deterministic native macOS insertion contract; never insert partial, empty, failed, cancelled, or unapproved text.
- Outcome: Insert transcribed text into the focused app while preserving the previous clipboard content.

### Local History and Offline Search outcome

- Actor: People who dictate directly into whichever macOS application currently has focus (editors, browsers, chat, email).
- Steps: User opens history or searches for a transcript. → Stores transcripts in bounded local storage with full-text search, copy, and atomic deletion; no transcripts are uploaded or synced to external clouds.
- Outcome: Search, copy, and delete past transcripts stored locally without external sync.

### Custom Writing Modes and Vocabulary outcome

- Actor: People who dictate directly into whichever macOS application currently has focus (editors, browsers, chat, email).
- Steps: User selects or edits a writing mode or vocabulary list. → Feeds configurable prompts and terminology expansion deterministically into refinement and transcription requests.
- Outcome: Apply configurable prompts and terminology expansion to refinement and transcription requests.

### Credential Vault outcome

- Actor: People who dictate directly into whichever macOS application currently has focus (editors, browsers, chat, email).
- Steps: User enters or updates API credentials. → Stores credentials in secure macOS Keychain storage; never stores keys in UserDefaults, files, or application logs.
- Outcome: Store Deepgram and OpenRouter API keys securely without exposing them in files or logs.

### Temporary Audio Cleanup outcome

- Actor: People who dictate directly into whichever macOS application currently has focus (editors, browsers, chat, email).
- Steps: Transcription succeeds or recording is cancelled. → Writes audio to temporary sandboxed storage during recording and guarantees deletion immediately upon successful transcription or cancellation.
- Outcome: Trust that recorded audio is deleted immediately after successful transcription or cancellation.

## Feature Contracts

### FEAT-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES — Global Hotkeys and Push-to-Talk/Toggle Modes

- Behavior: Registers global hotkeys safely, detects conflicts, handles smooth release, and supports both push-to-talk and toggle recording modes.
- Inputs: User presses the configured push-to-talk or toggle hotkey.
- Outputs: Start and stop dictation from any app using configurable global hotkeys without blocking system shortcuts.
- Acceptance outcomes: Conflict detection prevents silent failures.; Hotkeys work from any focused app.; Push-to-talk and toggle modes behave as configured.; System shortcuts remain functional.
- Failure behavior: If a hotkey conflicts or cannot be registered, the user is notified and can choose another shortcut; recording does not start.
- Recovery: Preserve the last valid state, explain the failure, and allow an explicit retry of Global Hotkeys and Push-to-Talk/Toggle Modes.

### FEAT-MICROPHONE-CAPTURE-AND-FLOATING-HUD — Microphone Capture and Floating HUD

- Behavior: Captures microphone audio and displays a floating HUD with live input levels, elapsed duration, active mode, and instant stop/cancel controls.
- Inputs: Recording starts via hotkey.
- Outputs: See capture state, audio levels, elapsed time, active mode, and stop/cancel actions in a minimal floating HUD.
- Acceptance outcomes: Audio levels update in real time.; HUD appears immediately on recording start.; HUD remains unobtrusive and does not steal focus.; Stop and cancel actions are responsive.
- Failure behavior: If microphone access is unavailable, the HUD shows an error and recording does not start.
- Recovery: Preserve the last valid state, explain the failure, and allow an explicit retry of Microphone Capture and Floating HUD.

### FEAT-DUAL-PROVIDER-ROUTING — Dual-Provider Routing

- Behavior: Routes audio to Deepgram for live WebSocket streaming with interim results and automatic finalization, or to OpenRouter for finalized audio batch transcription with optional text refinement using Gemini 2.5 Flash Lite.
- Inputs: User selects a provider before recording.
- Outputs: Transcribe speech using live streaming or batch transcription, depending on the selected provider.
- Acceptance outcomes: Deepgram streaming shows interim results and finalizes automatically.; OpenRouter batch transcription returns finalized text.; Optional refinement applies only when configured.; Provider selection is explicit and respected.
- Failure behavior: If the selected provider fails, the user is notified and no automatic fallback occurs; the recording can be retried or cancelled.
- Recovery: Preserve the last valid state, explain the failure, and allow an explicit retry of Dual-Provider Routing.

### FEAT-PROVIDER-SELECTION-AND-COST-PROTECTION — Provider Selection and Cost Protection

- Behavior: Requires an explicit provider toggle before recording; never automatically switches providers or silently incurs costs.
- Inputs: User opens provider selection or starts recording.
- Outputs: Avoid unexpected costs by explicitly choosing a provider before recording.
- Acceptance outcomes: Cost-related actions are explicit.; No automatic provider switching occurs.; Provider must be selected before recording.; User can change provider between recordings.
- Failure behavior: If no provider is selected, recording cannot start and the user is prompted to select.
- Recovery: Preserve the last valid state, explain the failure, and allow an explicit retry of Provider Selection and Cost Protection.

### FEAT-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION — Safe Auto-Paste and Clipboard Preservation

- Behavior: After one successful final transcription and optional successful refinement, choose exactly one complete insertion candidate and apply the configured auto-paste, copy-only, or preview mode through the deterministic native macOS insertion contract; never insert partial, empty, failed, cancelled, or unapproved text.
- Inputs: Transcription completes successfully.
- Outputs: Insert transcribed text into the focused app while preserving the previous clipboard content.
- Acceptance outcomes: Accessibility permission is requested when needed.; A newer external clipboard value is never overwritten; Command-V fallback restores the clipboard only when its app-owned changeCount is unchanged; Copy-only mode leaves the complete transcript on the clipboard without restoration; Direct Accessibility insertion writes one approved complete candidate without touching the clipboard; Insertion failure does not lose the transcript.; Original clipboard content is restored.; Partial, empty, failed, cancelled, and unapproved text is never inserted; Preview mode requires explicit approval and cancellation inserts nothing; Text is inserted into the focused app.
- Failure behavior: If insertion fails, the transcript is preserved in local history and the clipboard is restored; the user is notified.
- Recovery: Preserve the last valid state, explain the failure, and allow an explicit retry of Safe Auto-Paste and Clipboard Preservation.

### FEAT-LOCAL-HISTORY-AND-OFFLINE-SEARCH — Local History and Offline Search

- Behavior: Stores transcripts in bounded local storage with full-text search, copy, and atomic deletion; no transcripts are uploaded or synced to external clouds.
- Inputs: User opens history or searches for a transcript.
- Outputs: Search, copy, and delete past transcripts stored locally without external sync.
- Acceptance outcomes: Copy and delete actions work atomically.; No external sync occurs.; Storage remains bounded.; Transcripts are searchable offline.
- Failure behavior: If local storage is unavailable, history is disabled and the user is notified; transcription still works.
- Recovery: Preserve the last valid state, explain the failure, and allow an explicit retry of Local History and Offline Search.

### FEAT-CUSTOM-WRITING-MODES-AND-VOCABULARY — Custom Writing Modes and Vocabulary

- Behavior: Feeds configurable prompts and terminology expansion deterministically into refinement and transcription requests.
- Inputs: User selects or edits a writing mode or vocabulary list.
- Outputs: Apply configurable prompts and terminology expansion to refinement and transcription requests.
- Acceptance outcomes: Changes are deterministic and reproducible.; Custom modes affect refinement output.; Defaults are used when custom settings are invalid.; Vocabulary expansion is applied consistently.
- Failure behavior: If a custom mode or vocabulary is invalid, the user is notified and the default behavior is used.
- Recovery: Preserve the last valid state, explain the failure, and allow an explicit retry of Custom Writing Modes and Vocabulary.

### FEAT-CREDENTIAL-VAULT — Credential Vault

- Behavior: Stores credentials in secure macOS Keychain storage; never stores keys in UserDefaults, files, or application logs.
- Inputs: User enters or updates API credentials.
- Outputs: Store Deepgram and OpenRouter API keys securely without exposing them in files or logs.
- Acceptance outcomes: Credentials are stored only in Keychain.; Credential updates are atomic.; Keys are never written to logs or files.; Missing credentials block provider use with a clear message.
- Failure behavior: If Keychain access fails, the user is notified and credentials are not saved.
- Recovery: Preserve the last valid state, explain the failure, and allow an explicit retry of Credential Vault.

### FEAT-TEMPORARY-AUDIO-CLEANUP — Temporary Audio Cleanup

- Behavior: Writes audio to temporary sandboxed storage during recording and guarantees deletion immediately upon successful transcription or cancellation.
- Inputs: Transcription succeeds or recording is cancelled.
- Outputs: Trust that recorded audio is deleted immediately after successful transcription or cancellation.
- Acceptance outcomes: Audio files are deleted after success or cancellation.; Cleanup is guaranteed and retried on failure.; No audio persists across sessions.; Temporary storage is sandboxed.
- Failure behavior: Audio exists only for the active request. After a recoverable provider failure, temporary audio may be retained only while awaiting an explicit retry or explicit provider switch. Accepted success, explicit discard, cancellation, unrecoverable malformed audio, or exhausted recovery deletes temporary audio and verifies absence. Saved recordings survive only after explicit user action. Incomplete, failed, cancelled, or partial text is never pasted or persisted as completed output.
- Recovery: Preserve the last valid state, explain the failure, and allow an explicit retry of Temporary Audio Cleanup.

## Requirement Contracts

- REQ-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES — The product must Registers global hotkeys safely, detects conflicts, handles smooth release, and supports both push-to-talk and toggle recording modes. Acceptance ACC-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES-01, ACC-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES-02, ACC-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES-03, ACC-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES-04: Conflict detection prevents silent failures.; Hotkeys work from any focused app.; Push-to-talk and toggle modes behave as configured.; System shortcuts remain functional.
- REQ-MICROPHONE-CAPTURE-AND-FLOATING-HUD — The product must Captures microphone audio and displays a floating HUD with live input levels, elapsed duration, active mode, and instant stop/cancel controls. Acceptance ACC-MICROPHONE-CAPTURE-AND-FLOATING-HUD-01, ACC-MICROPHONE-CAPTURE-AND-FLOATING-HUD-02, ACC-MICROPHONE-CAPTURE-AND-FLOATING-HUD-03, ACC-MICROPHONE-CAPTURE-AND-FLOATING-HUD-04: Audio levels update in real time.; HUD appears immediately on recording start.; HUD remains unobtrusive and does not steal focus.; Stop and cancel actions are responsive.
- REQ-DUAL-PROVIDER-ROUTING — The product must Routes audio to Deepgram for live WebSocket streaming with interim results and automatic finalization, or to OpenRouter for finalized audio batch transcription with optional text refinement using Gemini 2.5 Flash Lite. Acceptance ACC-DUAL-PROVIDER-ROUTING-01, ACC-DUAL-PROVIDER-ROUTING-02, ACC-DUAL-PROVIDER-ROUTING-03, ACC-DUAL-PROVIDER-ROUTING-04: Deepgram streaming shows interim results and finalizes automatically.; OpenRouter batch transcription returns finalized text.; Optional refinement applies only when configured.; Provider selection is explicit and respected.
- REQ-PROVIDER-SELECTION-AND-COST-PROTECTION — The product must Requires an explicit provider toggle before recording; never automatically switches providers or silently incurs costs. Acceptance ACC-PROVIDER-SELECTION-AND-COST-PROTECTION-01, ACC-PROVIDER-SELECTION-AND-COST-PROTECTION-02, ACC-PROVIDER-SELECTION-AND-COST-PROTECTION-03, ACC-PROVIDER-SELECTION-AND-COST-PROTECTION-04: Cost-related actions are explicit.; No automatic provider switching occurs.; Provider must be selected before recording.; User can change provider between recordings.
- REQ-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION — The product must After one successful final transcription and optional successful refinement, choose exactly one complete insertion candidate and apply the configured auto-paste, copy-only, or preview mode through the deterministic native macOS insertion contract; never insert partial, empty, failed, cancelled, or unapproved text. Acceptance ACC-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION-01, ACC-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION-02, ACC-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION-03, ACC-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION-04, ACC-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION-05, ACC-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION-06, ACC-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION-07, ACC-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION-08, ACC-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION-09, ACC-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION-10: Accessibility permission is requested when needed.; A newer external clipboard value is never overwritten; Command-V fallback restores the clipboard only when its app-owned changeCount is unchanged; Copy-only mode leaves the complete transcript on the clipboard without restoration; Direct Accessibility insertion writes one approved complete candidate without touching the clipboard; Insertion failure does not lose the transcript.; Original clipboard content is restored.; Partial, empty, failed, cancelled, and unapproved text is never inserted; Preview mode requires explicit approval and cancellation inserts nothing; Text is inserted into the focused app.
- REQ-LOCAL-HISTORY-AND-OFFLINE-SEARCH — The product must Stores transcripts in bounded local storage with full-text search, copy, and atomic deletion; no transcripts are uploaded or synced to external clouds. Acceptance ACC-LOCAL-HISTORY-AND-OFFLINE-SEARCH-01, ACC-LOCAL-HISTORY-AND-OFFLINE-SEARCH-02, ACC-LOCAL-HISTORY-AND-OFFLINE-SEARCH-03, ACC-LOCAL-HISTORY-AND-OFFLINE-SEARCH-04: Copy and delete actions work atomically.; No external sync occurs.; Storage remains bounded.; Transcripts are searchable offline.
- REQ-CUSTOM-WRITING-MODES-AND-VOCABULARY — The product must Feeds configurable prompts and terminology expansion deterministically into refinement and transcription requests. Acceptance ACC-CUSTOM-WRITING-MODES-AND-VOCABULARY-01, ACC-CUSTOM-WRITING-MODES-AND-VOCABULARY-02, ACC-CUSTOM-WRITING-MODES-AND-VOCABULARY-03, ACC-CUSTOM-WRITING-MODES-AND-VOCABULARY-04: Changes are deterministic and reproducible.; Custom modes affect refinement output.; Defaults are used when custom settings are invalid.; Vocabulary expansion is applied consistently.
- REQ-CREDENTIAL-VAULT — The product must Stores credentials in secure macOS Keychain storage; never stores keys in UserDefaults, files, or application logs. Acceptance ACC-CREDENTIAL-VAULT-01, ACC-CREDENTIAL-VAULT-02, ACC-CREDENTIAL-VAULT-03, ACC-CREDENTIAL-VAULT-04: Credentials are stored only in Keychain.; Credential updates are atomic.; Keys are never written to logs or files.; Missing credentials block provider use with a clear message.
- REQ-TEMPORARY-AUDIO-CLEANUP — The product must Writes audio to temporary sandboxed storage during recording and guarantees deletion immediately upon successful transcription or cancellation. Acceptance ACC-TEMPORARY-AUDIO-CLEANUP-01, ACC-TEMPORARY-AUDIO-CLEANUP-02, ACC-TEMPORARY-AUDIO-CLEANUP-03, ACC-TEMPORARY-AUDIO-CLEANUP-04: Audio files are deleted after success or cancellation.; Cleanup is guaranteed and retried on failure.; No audio persists across sessions.; Temporary storage is sandboxed.

## Shared End-to-End Acceptance

- No shared acceptance criterion requires the final integration and packaging gate.

## UX Requirements

- Hotkeys must not block or override system shortcuts.
- Transcription must be reliable and responsive with clear interim feedback.
- Clipboard preservation must be atomic and restore the original content.
- Credentials must never be exposed in logs, files, or insecure storage.
- Audio exists only for the active request. After a recoverable provider failure, temporary audio may be retained only while awaiting an explicit retry or explicit provider switch. Accepted success, explicit discard, cancellation, unrecoverable malformed audio, or exhausted recovery deletes temporary audio and verifies absence. Saved recordings survive only after explicit user action. Incomplete, failed, cancelled, or partial text is never pasted or persisted as completed output.
- Local history must support fast full-text search and atomic deletion.
- Provider selection must be explicit and never switch automatically.
- The app must remain lightweight and unobtrusive as a menu-bar utility.

## Privacy and Security Requirements

- Minimize collected data and keep it inside the preset-defined owner, storage, and integration boundaries.
- Protect Transcript as personal data and never expose it through logs or diagnostics.
- Protect Temporary Audio Recording as sensitive data and never expose it through logs or diagnostics.
- Protect API Credential as sensitive data and never expose it through logs or diagnostics.
- Protect Writing Mode Configuration as internal data and never expose it through logs or diagnostics.
- Protect Vocabulary List as internal data and never expose it through logs or diagnostics.
- Protect Provider Preference as internal data and never expose it through logs or diagnostics.
- Protect Hotkey Configuration as internal data and never expose it through logs or diagnostics.
- Protect Clipboard Snapshot as personal data and never expose it through logs or diagnostics.
- Send only Microphone audio stream; Selected language or model parameters; Vocabulary or keyword hints if configured to Deepgram Nova streaming transcription for Live WebSocket streaming transcription using the Nova-2 model with interim results and automatic finalization.
- Send only Finalized audio recording; Transcription request parameters; Optional refinement prompt and writing mode settings to OpenRouter for Finalized audio batch transcription and optional text refinement using Gemini 2.5 Flash Lite.
- Keep external service credentials out of logs, files, UI state, product records, and rendered documents.

## Operational Constraints

- Must be a native macOS menu-bar utility.
- Must not automatically switch providers or incur unexpected costs.
- Must not upload or sync transcripts to external clouds.
- Must not store API keys in UserDefaults, files, or logs.
- Audio exists only for the active request. After a recoverable provider failure, temporary audio may be retained only while awaiting an explicit retry or explicit provider switch. Accepted success, explicit discard, cancellation, unrecoverable malformed audio, or exhausted recovery deletes temporary audio and verifies absence. Saved recordings survive only after explicit user action. Incomplete, failed, cancelled, or partial text is never pasted or persisted as completed output.
- Must use macOS Accessibility APIs for safe auto-paste.
- Must support both push-to-talk and toggle recording modes.
- Must keep local transcript storage bounded.

## Success Criteria

- Enable reliable global push-to-talk and toggle dictation from any macOS app.
- Provide clear visual feedback during capture with a minimal floating HUD.
- Route transcription through an explicitly selected provider without automatic switching.
- Insert transcribed text safely into the focused app while preserving the previous clipboard.
- Store transcripts locally with search, copy, and deletion, without external sync.
- Protect API credentials using secure macOS storage and never log or persist them insecurely.
- Guarantee temporary audio cleanup after successful transcription or cancellation.
- Support custom writing modes and vocabulary for deterministic refinement.
- Hotkeys work from any focused app.
- Conflict detection prevents silent failures.
- Push-to-talk and toggle modes behave as configured.
- System shortcuts remain functional.
- HUD appears immediately on recording start.
- Audio levels update in real time.
- Stop and cancel actions are responsive.
- HUD remains unobtrusive and does not steal focus.
- Provider selection is explicit and respected.
- Deepgram streaming shows interim results and finalizes automatically.
- OpenRouter batch transcription returns finalized text.
- Optional refinement applies only when configured.
- Provider must be selected before recording.
- No automatic provider switching occurs.
- Cost-related actions are explicit.
- User can change provider between recordings.
- Direct Accessibility insertion writes one approved complete candidate without touching the clipboard
- Command-V fallback restores the clipboard only when its app-owned changeCount is unchanged
- A newer external clipboard value is never overwritten
- Preview mode requires explicit approval and cancellation inserts nothing
- Copy-only mode leaves the complete transcript on the clipboard without restoration
- Partial, empty, failed, cancelled, and unapproved text is never inserted
- Text is inserted into the focused app.
- Original clipboard content is restored.
- Insertion failure does not lose the transcript.
- Accessibility permission is requested when needed.
- Transcripts are searchable offline.
- Copy and delete actions work atomically.
- No external sync occurs.
- Storage remains bounded.
- Custom modes affect refinement output.
- Vocabulary expansion is applied consistently.
- Changes are deterministic and reproducible.
- Defaults are used when custom settings are invalid.
- Credentials are stored only in Keychain.
- Keys are never written to logs or files.
- Credential updates are atomic.
- Missing credentials block provider use with a clear message.
- Audio files are deleted after success or cancellation.
- Temporary storage is sandboxed.
- Cleanup is guaranteed and retried on failure.
- No audio persists across sessions.

## Explicit Assumptions

- The selected preset is authoritative for every technology and mechanical decision.
- Omitted mechanics use the conservative preset-defined contract without another provider request.

## Scope Boundaries

- Included features: Global Hotkeys and Push-to-Talk/Toggle Modes; Microphone Capture and Floating HUD; Dual-Provider Routing; Provider Selection and Cost Protection; Safe Auto-Paste and Clipboard Preservation; Local History and Offline Search; Custom Writing Modes and Vocabulary; Credential Vault; Temporary Audio Cleanup
- Excluded outcomes: Do not automatically switch transcription providers or incur costs without explicit user action.; Do not upload, sync, or back up transcripts to external clouds.; Do not store API keys in UserDefaults, files, or application logs.; Do not retain audio files after successful transcription or cancellation.; Do not block or override system shortcuts when registering global hotkeys.; Do not provide a full document editor or note-taking workspace.; Do not support non-macOS platforms.; Do not offer offline or on-device transcription.
- Locked delivery preset: native-macos-swiftui-menubar

## Traceability Index

- FEAT-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES — Global Hotkeys and Push-to-Talk/Toggle Modes — Requirement REQ-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES — Acceptance ACC-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES-01, ACC-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES-02, ACC-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES-03, ACC-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES-04 — Owner OWN-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES — Contracts CON-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES-INTERFACE, CON-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES-RECOVERY, CON-DATA-TRANSCRIPT, CON-DATA-WRITING-MODE-CONFIGURATION, CON-DATA-PROVIDER-PREFERENCE, CON-DATA-HOTKEY-CONFIGURATION, CON-LIFECYCLE-AUDIO-CAPTURE-TERMINATION, CON-LIFECYCLE-PRESET, CON-PERSISTENCE-TRANSCRIPT, CON-PERSISTENCE-WRITING-MODE-CONFIGURATION, CON-PERSISTENCE-PROVIDER-PREFERENCE, CON-PERSISTENCE-HOTKEY-CONFIGURATION, CON-PERMISSION-MICROPHONE, CON-PERMISSION-GLOBAL-INPUT, CON-SECURITY-BOUNDARY, CON-PACKAGING-RELEASE — Files Sources/Whisperbar/Features/GlobalHotkeysAndPushToTalkToggleModesFeature.swift; Tests/WhisperbarTests/GlobalHotkeysAndPushToTalkToggleModesFeatureTests.swift — Phase PHASE-06-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES — Task TASK-06-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES depends on TASK-01-FOUNDATION, TASK-03-DATA-STORE, TASK-04-LIFECYCLE-COORDINATOR, TASK-05-PERMISSION-COORDINATOR
- FEAT-MICROPHONE-CAPTURE-AND-FLOATING-HUD — Microphone Capture and Floating HUD — Requirement REQ-MICROPHONE-CAPTURE-AND-FLOATING-HUD — Acceptance ACC-MICROPHONE-CAPTURE-AND-FLOATING-HUD-01, ACC-MICROPHONE-CAPTURE-AND-FLOATING-HUD-02, ACC-MICROPHONE-CAPTURE-AND-FLOATING-HUD-03, ACC-MICROPHONE-CAPTURE-AND-FLOATING-HUD-04 — Owner OWN-MICROPHONE-CAPTURE-AND-FLOATING-HUD — Contracts CON-MICROPHONE-CAPTURE-AND-FLOATING-HUD-INTERFACE, CON-MICROPHONE-CAPTURE-AND-FLOATING-HUD-RECOVERY, CON-DATA-TRANSCRIPT, CON-DATA-WRITING-MODE-CONFIGURATION, CON-DATA-PROVIDER-PREFERENCE, CON-DATA-HOTKEY-CONFIGURATION, CON-LIFECYCLE-AUDIO-CAPTURE-TERMINATION, CON-LIFECYCLE-PRESET, CON-PERSISTENCE-TRANSCRIPT, CON-PERSISTENCE-WRITING-MODE-CONFIGURATION, CON-PERSISTENCE-PROVIDER-PREFERENCE, CON-PERSISTENCE-HOTKEY-CONFIGURATION, CON-PERMISSION-MICROPHONE, CON-SECURITY-BOUNDARY, CON-PACKAGING-RELEASE — Files Sources/Whisperbar/Features/MicrophoneCaptureAndFloatingHudFeature.swift; Tests/WhisperbarTests/MicrophoneCaptureAndFloatingHudFeatureTests.swift — Phase PHASE-14-MICROPHONE-CAPTURE-AND-FLOATING-HUD — Task TASK-14-MICROPHONE-CAPTURE-AND-FLOATING-HUD depends on TASK-01-FOUNDATION, TASK-03-DATA-STORE, TASK-04-LIFECYCLE-COORDINATOR, TASK-05-PERMISSION-COORDINATOR
- FEAT-DUAL-PROVIDER-ROUTING — Dual-Provider Routing — Requirement REQ-DUAL-PROVIDER-ROUTING — Acceptance ACC-DUAL-PROVIDER-ROUTING-01, ACC-DUAL-PROVIDER-ROUTING-02, ACC-DUAL-PROVIDER-ROUTING-03, ACC-DUAL-PROVIDER-ROUTING-04 — Owner OWN-DUAL-PROVIDER-ROUTING — Contracts CON-DUAL-PROVIDER-ROUTING-INTERFACE, CON-DUAL-PROVIDER-ROUTING-RECOVERY, CON-DATA-TRANSCRIPT, CON-DATA-API-CREDENTIAL, CON-DATA-PROVIDER-PREFERENCE, CON-INTEGRATION-DEEPGRAM-NOVA-STREAMING-TRANSCRIPTION, CON-INTEGRATION-OPENROUTER-TRANSCRIPTION, CON-INTEGRATION-OPENROUTER-REFINEMENT, CON-LIFECYCLE-AUDIO-CAPTURE-TERMINATION, CON-LIFECYCLE-PRESET, CON-PERSISTENCE-TRANSCRIPT, CON-PERSISTENCE-PROVIDER-PREFERENCE, CON-CREDENTIAL-DEEPGRAM-NOVA-STREAMING-TRANSCRIPTION, CON-CREDENTIAL-OPENROUTER, CON-PERMISSION-MICROPHONE, CON-PERMISSION-NETWORK, CON-SECURITY-BOUNDARY, CON-PACKAGING-RELEASE — Files Sources/Whisperbar/Features/DualProviderRoutingFeature.swift; Tests/WhisperbarTests/DualProviderRoutingFeatureTests.swift — Phase PHASE-12-DUAL-PROVIDER-ROUTING — Task TASK-12-DUAL-PROVIDER-ROUTING depends on TASK-01-FOUNDATION, TASK-02-CREDENTIAL-VAULT, TASK-03-DATA-STORE, TASK-07-INTEGRATION-DEEPGRAM-NOVA-STREAMING-TRANSCRIPTION, TASK-08-INTEGRATION-OPENROUTER-REFINEMENT, TASK-09-INTEGRATION-OPENROUTER-TRANSCRIPTION, TASK-04-LIFECYCLE-COORDINATOR, TASK-05-PERMISSION-COORDINATOR
- FEAT-PROVIDER-SELECTION-AND-COST-PROTECTION — Provider Selection and Cost Protection — Requirement REQ-PROVIDER-SELECTION-AND-COST-PROTECTION — Acceptance ACC-PROVIDER-SELECTION-AND-COST-PROTECTION-01, ACC-PROVIDER-SELECTION-AND-COST-PROTECTION-02, ACC-PROVIDER-SELECTION-AND-COST-PROTECTION-03, ACC-PROVIDER-SELECTION-AND-COST-PROTECTION-04 — Owner OWN-PROVIDER-SELECTION-AND-COST-PROTECTION — Contracts CON-PROVIDER-SELECTION-AND-COST-PROTECTION-INTERFACE, CON-PROVIDER-SELECTION-AND-COST-PROTECTION-RECOVERY, CON-LIFECYCLE-AUDIO-CAPTURE-TERMINATION, CON-LIFECYCLE-PRESET, CON-PERMISSION-MICROPHONE, CON-PERMISSION-NETWORK, CON-SECURITY-BOUNDARY, CON-PACKAGING-RELEASE — Files Sources/Whisperbar/Features/ProviderSelectionAndCostProtectionFeature.swift; Tests/WhisperbarTests/ProviderSelectionAndCostProtectionFeatureTests.swift — Phase PHASE-16-PROVIDER-SELECTION-AND-COST-PROTECTION — Task TASK-16-PROVIDER-SELECTION-AND-COST-PROTECTION depends on TASK-01-FOUNDATION, TASK-04-LIFECYCLE-COORDINATOR, TASK-05-PERMISSION-COORDINATOR
- FEAT-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION — Safe Auto-Paste and Clipboard Preservation — Requirement REQ-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION — Acceptance ACC-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION-01, ACC-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION-02, ACC-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION-03, ACC-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION-04, ACC-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION-05, ACC-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION-06, ACC-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION-07, ACC-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION-08, ACC-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION-09, ACC-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION-10 — Owner OWN-PASTE-COORDINATOR — Contracts CON-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION-INTERFACE, CON-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION-RECOVERY, CON-PASTE-WORKFLOW, CON-DATA-TRANSCRIPT, CON-DATA-PROVIDER-PREFERENCE, CON-LIFECYCLE-PRESET, CON-PERSISTENCE-TRANSCRIPT, CON-PERSISTENCE-PROVIDER-PREFERENCE, CON-PERMISSION-CLIPBOARD, CON-PERMISSION-ACCESSIBILITY, CON-SECURITY-BOUNDARY, CON-PACKAGING-RELEASE — Files Sources/Whisperbar/Features/PasteCoordinator.swift; Tests/WhisperbarTests/PasteCoordinatorTests.swift — Phase PHASE-15-PASTE-COORDINATOR — Task TASK-15-PASTE-COORDINATOR depends on TASK-01-FOUNDATION, TASK-03-DATA-STORE, TASK-04-LIFECYCLE-COORDINATOR, TASK-05-PERMISSION-COORDINATOR
- FEAT-LOCAL-HISTORY-AND-OFFLINE-SEARCH — Local History and Offline Search — Requirement REQ-LOCAL-HISTORY-AND-OFFLINE-SEARCH — Acceptance ACC-LOCAL-HISTORY-AND-OFFLINE-SEARCH-01, ACC-LOCAL-HISTORY-AND-OFFLINE-SEARCH-02, ACC-LOCAL-HISTORY-AND-OFFLINE-SEARCH-03, ACC-LOCAL-HISTORY-AND-OFFLINE-SEARCH-04 — Owner OWN-LOCAL-HISTORY-AND-OFFLINE-SEARCH — Contracts CON-LOCAL-HISTORY-AND-OFFLINE-SEARCH-INTERFACE, CON-LOCAL-HISTORY-AND-OFFLINE-SEARCH-RECOVERY, CON-DATA-TRANSCRIPT, CON-DATA-WRITING-MODE-CONFIGURATION, CON-DATA-PROVIDER-PREFERENCE, CON-DATA-HOTKEY-CONFIGURATION, CON-LIFECYCLE-PRESET, CON-PERSISTENCE-TRANSCRIPT, CON-PERSISTENCE-WRITING-MODE-CONFIGURATION, CON-PERSISTENCE-PROVIDER-PREFERENCE, CON-PERSISTENCE-HOTKEY-CONFIGURATION, CON-PERMISSION-CLIPBOARD, CON-SECURITY-BOUNDARY, CON-PACKAGING-RELEASE — Files Sources/Whisperbar/Features/LocalHistoryAndOfflineSearchFeature.swift; Tests/WhisperbarTests/LocalHistoryAndOfflineSearchFeatureTests.swift — Phase PHASE-13-LOCAL-HISTORY-AND-OFFLINE-SEARCH — Task TASK-13-LOCAL-HISTORY-AND-OFFLINE-SEARCH depends on TASK-01-FOUNDATION, TASK-03-DATA-STORE, TASK-04-LIFECYCLE-COORDINATOR, TASK-05-PERMISSION-COORDINATOR
- FEAT-CUSTOM-WRITING-MODES-AND-VOCABULARY — Custom Writing Modes and Vocabulary — Requirement REQ-CUSTOM-WRITING-MODES-AND-VOCABULARY — Acceptance ACC-CUSTOM-WRITING-MODES-AND-VOCABULARY-01, ACC-CUSTOM-WRITING-MODES-AND-VOCABULARY-02, ACC-CUSTOM-WRITING-MODES-AND-VOCABULARY-03, ACC-CUSTOM-WRITING-MODES-AND-VOCABULARY-04 — Owner OWN-CUSTOM-WRITING-MODES-AND-VOCABULARY — Contracts CON-CUSTOM-WRITING-MODES-AND-VOCABULARY-INTERFACE, CON-CUSTOM-WRITING-MODES-AND-VOCABULARY-RECOVERY, CON-DATA-TRANSCRIPT, CON-DATA-API-CREDENTIAL, CON-DATA-WRITING-MODE-CONFIGURATION, CON-DATA-VOCABULARY-LIST, CON-DATA-PROVIDER-PREFERENCE, CON-DATA-HOTKEY-CONFIGURATION, CON-INTEGRATION-OPENROUTER-TRANSCRIPTION, CON-INTEGRATION-OPENROUTER-REFINEMENT, CON-LIFECYCLE-PRESET, CON-PERSISTENCE-TRANSCRIPT, CON-PERSISTENCE-WRITING-MODE-CONFIGURATION, CON-PERSISTENCE-VOCABULARY-LIST, CON-PERSISTENCE-PROVIDER-PREFERENCE, CON-PERSISTENCE-HOTKEY-CONFIGURATION, CON-CREDENTIAL-OPENROUTER, CON-SECURITY-BOUNDARY, CON-PACKAGING-RELEASE — Files Sources/Whisperbar/Features/CustomWritingModesAndVocabularyFeature.swift; Tests/WhisperbarTests/CustomWritingModesAndVocabularyFeatureTests.swift — Phase PHASE-11-CUSTOM-WRITING-MODES-AND-VOCABULARY — Task TASK-11-CUSTOM-WRITING-MODES-AND-VOCABULARY depends on TASK-01-FOUNDATION, TASK-02-CREDENTIAL-VAULT, TASK-03-DATA-STORE, TASK-08-INTEGRATION-OPENROUTER-REFINEMENT, TASK-09-INTEGRATION-OPENROUTER-TRANSCRIPTION, TASK-04-LIFECYCLE-COORDINATOR
- FEAT-CREDENTIAL-VAULT — Credential Vault — Requirement REQ-CREDENTIAL-VAULT — Acceptance ACC-CREDENTIAL-VAULT-01, ACC-CREDENTIAL-VAULT-02, ACC-CREDENTIAL-VAULT-03, ACC-CREDENTIAL-VAULT-04 — Owner OWN-CREDENTIAL-VAULT-FEATURE — Contracts CON-CREDENTIAL-VAULT-INTERFACE, CON-CREDENTIAL-VAULT-RECOVERY, CON-DATA-API-CREDENTIAL, CON-INTEGRATION-DEEPGRAM-NOVA-STREAMING-TRANSCRIPTION, CON-INTEGRATION-OPENROUTER-TRANSCRIPTION, CON-INTEGRATION-OPENROUTER-REFINEMENT, CON-LIFECYCLE-PRESET, CON-CREDENTIAL-DEEPGRAM-NOVA-STREAMING-TRANSCRIPTION, CON-CREDENTIAL-OPENROUTER, CON-PERMISSION-NETWORK, CON-SECURITY-BOUNDARY, CON-PACKAGING-RELEASE — Files Sources/Whisperbar/Features/CredentialVaultFeature.swift; Tests/WhisperbarTests/CredentialVaultFeatureTests.swift — Phase PHASE-10-CREDENTIAL-VAULT-FEATURE — Task TASK-10-CREDENTIAL-VAULT-FEATURE depends on TASK-01-FOUNDATION, TASK-02-CREDENTIAL-VAULT, TASK-07-INTEGRATION-DEEPGRAM-NOVA-STREAMING-TRANSCRIPTION, TASK-08-INTEGRATION-OPENROUTER-REFINEMENT, TASK-09-INTEGRATION-OPENROUTER-TRANSCRIPTION, TASK-04-LIFECYCLE-COORDINATOR, TASK-05-PERMISSION-COORDINATOR
- FEAT-TEMPORARY-AUDIO-CLEANUP — Temporary Audio Cleanup — Requirement REQ-TEMPORARY-AUDIO-CLEANUP — Acceptance ACC-TEMPORARY-AUDIO-CLEANUP-01, ACC-TEMPORARY-AUDIO-CLEANUP-02, ACC-TEMPORARY-AUDIO-CLEANUP-03, ACC-TEMPORARY-AUDIO-CLEANUP-04 — Owner OWN-TEMPORARY-AUDIO-CLEANUP — Contracts CON-TEMPORARY-AUDIO-CLEANUP-INTERFACE, CON-TEMPORARY-AUDIO-CLEANUP-RECOVERY, CON-DATA-TRANSCRIPT, CON-DATA-TEMPORARY-AUDIO-RECORDING, CON-DATA-API-CREDENTIAL, CON-DATA-PROVIDER-PREFERENCE, CON-INTEGRATION-OPENROUTER-TRANSCRIPTION, CON-INTEGRATION-OPENROUTER-REFINEMENT, CON-LIFECYCLE-AUDIO-CAPTURE-TERMINATION, CON-LIFECYCLE-PRESET, CON-PERSISTENCE-TRANSCRIPT, CON-PERSISTENCE-TEMPORARY-AUDIO-RECORDING, CON-PERSISTENCE-PROVIDER-PREFERENCE, CON-CREDENTIAL-OPENROUTER, CON-PERMISSION-MICROPHONE, CON-SECURITY-BOUNDARY, CON-PACKAGING-RELEASE — Files Sources/Whisperbar/Features/TemporaryAudioCleanupFeature.swift; Tests/WhisperbarTests/TemporaryAudioCleanupFeatureTests.swift — Phase PHASE-17-TEMPORARY-AUDIO-CLEANUP — Task TASK-17-TEMPORARY-AUDIO-CLEANUP depends on TASK-01-FOUNDATION, TASK-02-CREDENTIAL-VAULT, TASK-03-DATA-STORE, TASK-08-INTEGRATION-OPENROUTER-REFINEMENT, TASK-09-INTEGRATION-OPENROUTER-TRANSCRIPTION, TASK-04-LIFECYCLE-COORDINATOR, TASK-05-PERMISSION-COORDINATOR
- REQ-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES — Feature FEAT-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES — The product must Registers global hotkeys safely, detects conflicts, handles smooth release, and supports both push-to-talk and toggle recording modes.
- REQ-MICROPHONE-CAPTURE-AND-FLOATING-HUD — Feature FEAT-MICROPHONE-CAPTURE-AND-FLOATING-HUD — The product must Captures microphone audio and displays a floating HUD with live input levels, elapsed duration, active mode, and instant stop/cancel controls.
- REQ-DUAL-PROVIDER-ROUTING — Feature FEAT-DUAL-PROVIDER-ROUTING — The product must Routes audio to Deepgram for live WebSocket streaming with interim results and automatic finalization, or to OpenRouter for finalized audio batch transcription with optional text refinement using Gemini 2.5 Flash Lite.
- REQ-PROVIDER-SELECTION-AND-COST-PROTECTION — Feature FEAT-PROVIDER-SELECTION-AND-COST-PROTECTION — The product must Requires an explicit provider toggle before recording; never automatically switches providers or silently incurs costs.
- REQ-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION — Feature FEAT-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION — The product must After one successful final transcription and optional successful refinement, choose exactly one complete insertion candidate and apply the configured auto-paste, copy-only, or preview mode through the deterministic native macOS insertion contract; never insert partial, empty, failed, cancelled, or unapproved text.
- REQ-LOCAL-HISTORY-AND-OFFLINE-SEARCH — Feature FEAT-LOCAL-HISTORY-AND-OFFLINE-SEARCH — The product must Stores transcripts in bounded local storage with full-text search, copy, and atomic deletion; no transcripts are uploaded or synced to external clouds.
- REQ-CUSTOM-WRITING-MODES-AND-VOCABULARY — Feature FEAT-CUSTOM-WRITING-MODES-AND-VOCABULARY — The product must Feeds configurable prompts and terminology expansion deterministically into refinement and transcription requests.
- REQ-CREDENTIAL-VAULT — Feature FEAT-CREDENTIAL-VAULT — The product must Stores credentials in secure macOS Keychain storage; never stores keys in UserDefaults, files, or application logs.
- REQ-TEMPORARY-AUDIO-CLEANUP — Feature FEAT-TEMPORARY-AUDIO-CLEANUP — The product must Writes audio to temporary sandboxed storage during recording and guarantees deletion immediately upon successful transcription or cancellation.
- ACC-CREDENTIAL-VAULT-01 — feature — Features FEAT-CREDENTIAL-VAULT — Owner OWN-CREDENTIAL-VAULT-FEATURE
- ACC-CREDENTIAL-VAULT-02 — feature — Features FEAT-CREDENTIAL-VAULT — Owner OWN-CREDENTIAL-VAULT-FEATURE
- ACC-CREDENTIAL-VAULT-03 — feature — Features FEAT-CREDENTIAL-VAULT — Owner OWN-CREDENTIAL-VAULT-FEATURE
- ACC-CREDENTIAL-VAULT-04 — feature — Features FEAT-CREDENTIAL-VAULT — Owner OWN-CREDENTIAL-VAULT-FEATURE
- ACC-CUSTOM-WRITING-MODES-AND-VOCABULARY-01 — feature — Features FEAT-CUSTOM-WRITING-MODES-AND-VOCABULARY — Owner OWN-CUSTOM-WRITING-MODES-AND-VOCABULARY
- ACC-CUSTOM-WRITING-MODES-AND-VOCABULARY-02 — feature — Features FEAT-CUSTOM-WRITING-MODES-AND-VOCABULARY — Owner OWN-CUSTOM-WRITING-MODES-AND-VOCABULARY
- ACC-CUSTOM-WRITING-MODES-AND-VOCABULARY-03 — feature — Features FEAT-CUSTOM-WRITING-MODES-AND-VOCABULARY — Owner OWN-CUSTOM-WRITING-MODES-AND-VOCABULARY
- ACC-CUSTOM-WRITING-MODES-AND-VOCABULARY-04 — feature — Features FEAT-CUSTOM-WRITING-MODES-AND-VOCABULARY — Owner OWN-CUSTOM-WRITING-MODES-AND-VOCABULARY
- ACC-DUAL-PROVIDER-ROUTING-01 — feature — Features FEAT-DUAL-PROVIDER-ROUTING — Owner OWN-DUAL-PROVIDER-ROUTING
- ACC-DUAL-PROVIDER-ROUTING-02 — feature — Features FEAT-DUAL-PROVIDER-ROUTING — Owner OWN-DUAL-PROVIDER-ROUTING
- ACC-DUAL-PROVIDER-ROUTING-03 — feature — Features FEAT-DUAL-PROVIDER-ROUTING — Owner OWN-DUAL-PROVIDER-ROUTING
- ACC-DUAL-PROVIDER-ROUTING-04 — feature — Features FEAT-DUAL-PROVIDER-ROUTING — Owner OWN-DUAL-PROVIDER-ROUTING
- ACC-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES-01 — feature — Features FEAT-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES — Owner OWN-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES
- ACC-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES-02 — feature — Features FEAT-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES — Owner OWN-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES
- ACC-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES-03 — feature — Features FEAT-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES — Owner OWN-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES
- ACC-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES-04 — feature — Features FEAT-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES — Owner OWN-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES
- ACC-LOCAL-HISTORY-AND-OFFLINE-SEARCH-01 — feature — Features FEAT-LOCAL-HISTORY-AND-OFFLINE-SEARCH — Owner OWN-LOCAL-HISTORY-AND-OFFLINE-SEARCH
- ACC-LOCAL-HISTORY-AND-OFFLINE-SEARCH-02 — feature — Features FEAT-LOCAL-HISTORY-AND-OFFLINE-SEARCH — Owner OWN-LOCAL-HISTORY-AND-OFFLINE-SEARCH
- ACC-LOCAL-HISTORY-AND-OFFLINE-SEARCH-03 — feature — Features FEAT-LOCAL-HISTORY-AND-OFFLINE-SEARCH — Owner OWN-LOCAL-HISTORY-AND-OFFLINE-SEARCH
- ACC-LOCAL-HISTORY-AND-OFFLINE-SEARCH-04 — feature — Features FEAT-LOCAL-HISTORY-AND-OFFLINE-SEARCH — Owner OWN-LOCAL-HISTORY-AND-OFFLINE-SEARCH
- ACC-MICROPHONE-CAPTURE-AND-FLOATING-HUD-01 — feature — Features FEAT-MICROPHONE-CAPTURE-AND-FLOATING-HUD — Owner OWN-MICROPHONE-CAPTURE-AND-FLOATING-HUD
- ACC-MICROPHONE-CAPTURE-AND-FLOATING-HUD-02 — feature — Features FEAT-MICROPHONE-CAPTURE-AND-FLOATING-HUD — Owner OWN-MICROPHONE-CAPTURE-AND-FLOATING-HUD
- ACC-MICROPHONE-CAPTURE-AND-FLOATING-HUD-03 — feature — Features FEAT-MICROPHONE-CAPTURE-AND-FLOATING-HUD — Owner OWN-MICROPHONE-CAPTURE-AND-FLOATING-HUD
- ACC-MICROPHONE-CAPTURE-AND-FLOATING-HUD-04 — feature — Features FEAT-MICROPHONE-CAPTURE-AND-FLOATING-HUD — Owner OWN-MICROPHONE-CAPTURE-AND-FLOATING-HUD
- ACC-PROVIDER-SELECTION-AND-COST-PROTECTION-01 — feature — Features FEAT-PROVIDER-SELECTION-AND-COST-PROTECTION — Owner OWN-PROVIDER-SELECTION-AND-COST-PROTECTION
- ACC-PROVIDER-SELECTION-AND-COST-PROTECTION-02 — feature — Features FEAT-PROVIDER-SELECTION-AND-COST-PROTECTION — Owner OWN-PROVIDER-SELECTION-AND-COST-PROTECTION
- ACC-PROVIDER-SELECTION-AND-COST-PROTECTION-03 — feature — Features FEAT-PROVIDER-SELECTION-AND-COST-PROTECTION — Owner OWN-PROVIDER-SELECTION-AND-COST-PROTECTION
- ACC-PROVIDER-SELECTION-AND-COST-PROTECTION-04 — feature — Features FEAT-PROVIDER-SELECTION-AND-COST-PROTECTION — Owner OWN-PROVIDER-SELECTION-AND-COST-PROTECTION
- ACC-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION-01 — feature — Features FEAT-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION — Owner OWN-PASTE-COORDINATOR
- ACC-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION-02 — feature — Features FEAT-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION — Owner OWN-PASTE-COORDINATOR
- ACC-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION-03 — feature — Features FEAT-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION — Owner OWN-PASTE-COORDINATOR
- ACC-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION-04 — feature — Features FEAT-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION — Owner OWN-PASTE-COORDINATOR
- ACC-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION-05 — feature — Features FEAT-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION — Owner OWN-PASTE-COORDINATOR
- ACC-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION-06 — feature — Features FEAT-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION — Owner OWN-PASTE-COORDINATOR
- ACC-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION-07 — feature — Features FEAT-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION — Owner OWN-PASTE-COORDINATOR
- ACC-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION-08 — feature — Features FEAT-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION — Owner OWN-PASTE-COORDINATOR
- ACC-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION-09 — feature — Features FEAT-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION — Owner OWN-PASTE-COORDINATOR
- ACC-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION-10 — feature — Features FEAT-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION — Owner OWN-PASTE-COORDINATOR
- ACC-TEMPORARY-AUDIO-CLEANUP-01 — feature — Features FEAT-TEMPORARY-AUDIO-CLEANUP — Owner OWN-TEMPORARY-AUDIO-CLEANUP
- ACC-TEMPORARY-AUDIO-CLEANUP-02 — feature — Features FEAT-TEMPORARY-AUDIO-CLEANUP — Owner OWN-TEMPORARY-AUDIO-CLEANUP
- ACC-TEMPORARY-AUDIO-CLEANUP-03 — feature — Features FEAT-TEMPORARY-AUDIO-CLEANUP — Owner OWN-TEMPORARY-AUDIO-CLEANUP
- ACC-TEMPORARY-AUDIO-CLEANUP-04 — feature — Features FEAT-TEMPORARY-AUDIO-CLEANUP — Owner OWN-TEMPORARY-AUDIO-CLEANUP
- CON-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES-INTERFACE — Global Hotkeys and Push-to-Talk/Toggle Modes interface (interface) — Owner OWN-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES — Features FEAT-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES
- CON-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES-RECOVERY — Global Hotkeys and Push-to-Talk/Toggle Modes recovery (recovery) — Owner OWN-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES — Features FEAT-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES
- CON-MICROPHONE-CAPTURE-AND-FLOATING-HUD-INTERFACE — Microphone Capture and Floating HUD interface (interface) — Owner OWN-MICROPHONE-CAPTURE-AND-FLOATING-HUD — Features FEAT-MICROPHONE-CAPTURE-AND-FLOATING-HUD
- CON-MICROPHONE-CAPTURE-AND-FLOATING-HUD-RECOVERY — Microphone Capture and Floating HUD recovery (recovery) — Owner OWN-MICROPHONE-CAPTURE-AND-FLOATING-HUD — Features FEAT-MICROPHONE-CAPTURE-AND-FLOATING-HUD
- CON-DUAL-PROVIDER-ROUTING-INTERFACE — Dual-Provider Routing interface (interface) — Owner OWN-DUAL-PROVIDER-ROUTING — Features FEAT-DUAL-PROVIDER-ROUTING
- CON-DUAL-PROVIDER-ROUTING-RECOVERY — Dual-Provider Routing recovery (recovery) — Owner OWN-DUAL-PROVIDER-ROUTING — Features FEAT-DUAL-PROVIDER-ROUTING
- CON-PROVIDER-SELECTION-AND-COST-PROTECTION-INTERFACE — Provider Selection and Cost Protection interface (interface) — Owner OWN-PROVIDER-SELECTION-AND-COST-PROTECTION — Features FEAT-PROVIDER-SELECTION-AND-COST-PROTECTION
- CON-PROVIDER-SELECTION-AND-COST-PROTECTION-RECOVERY — Provider Selection and Cost Protection recovery (recovery) — Owner OWN-PROVIDER-SELECTION-AND-COST-PROTECTION — Features FEAT-PROVIDER-SELECTION-AND-COST-PROTECTION
- CON-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION-INTERFACE — Safe Auto-Paste and Clipboard Preservation interface (interface) — Owner OWN-PASTE-COORDINATOR — Features FEAT-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION
- CON-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION-RECOVERY — Safe Auto-Paste and Clipboard Preservation recovery (recovery) — Owner OWN-PASTE-COORDINATOR — Features FEAT-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION
- CON-LOCAL-HISTORY-AND-OFFLINE-SEARCH-INTERFACE — Local History and Offline Search interface (interface) — Owner OWN-LOCAL-HISTORY-AND-OFFLINE-SEARCH — Features FEAT-LOCAL-HISTORY-AND-OFFLINE-SEARCH
- CON-LOCAL-HISTORY-AND-OFFLINE-SEARCH-RECOVERY — Local History and Offline Search recovery (recovery) — Owner OWN-LOCAL-HISTORY-AND-OFFLINE-SEARCH — Features FEAT-LOCAL-HISTORY-AND-OFFLINE-SEARCH
- CON-CUSTOM-WRITING-MODES-AND-VOCABULARY-INTERFACE — Custom Writing Modes and Vocabulary interface (interface) — Owner OWN-CUSTOM-WRITING-MODES-AND-VOCABULARY — Features FEAT-CUSTOM-WRITING-MODES-AND-VOCABULARY
- CON-CUSTOM-WRITING-MODES-AND-VOCABULARY-RECOVERY — Custom Writing Modes and Vocabulary recovery (recovery) — Owner OWN-CUSTOM-WRITING-MODES-AND-VOCABULARY — Features FEAT-CUSTOM-WRITING-MODES-AND-VOCABULARY
- CON-CREDENTIAL-VAULT-INTERFACE — Credential Vault interface (interface) — Owner OWN-CREDENTIAL-VAULT-FEATURE — Features FEAT-CREDENTIAL-VAULT
- CON-CREDENTIAL-VAULT-RECOVERY — Credential Vault recovery (recovery) — Owner OWN-CREDENTIAL-VAULT-FEATURE — Features FEAT-CREDENTIAL-VAULT
- CON-TEMPORARY-AUDIO-CLEANUP-INTERFACE — Temporary Audio Cleanup interface (interface) — Owner OWN-TEMPORARY-AUDIO-CLEANUP — Features FEAT-TEMPORARY-AUDIO-CLEANUP
- CON-TEMPORARY-AUDIO-CLEANUP-RECOVERY — Temporary Audio Cleanup recovery (recovery) — Owner OWN-TEMPORARY-AUDIO-CLEANUP — Features FEAT-TEMPORARY-AUDIO-CLEANUP
- CON-PASTE-WORKFLOW — Deterministic paste workflow (interface) — Owner OWN-PASTE-COORDINATOR — Features FEAT-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION
- CON-DATA-TRANSCRIPT — Transcript (data) — Owner OWN-DATA-STORE — Features FEAT-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES, FEAT-MICROPHONE-CAPTURE-AND-FLOATING-HUD, FEAT-DUAL-PROVIDER-ROUTING, FEAT-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION, FEAT-LOCAL-HISTORY-AND-OFFLINE-SEARCH, FEAT-CUSTOM-WRITING-MODES-AND-VOCABULARY, FEAT-TEMPORARY-AUDIO-CLEANUP
- CON-DATA-TEMPORARY-AUDIO-RECORDING — Temporary Audio Recording (data) — Owner OWN-DATA-STORE — Features FEAT-TEMPORARY-AUDIO-CLEANUP
- CON-DATA-API-CREDENTIAL — API Credential (data) — Owner OWN-CREDENTIAL-VAULT — Features FEAT-DUAL-PROVIDER-ROUTING, FEAT-CREDENTIAL-VAULT, FEAT-CUSTOM-WRITING-MODES-AND-VOCABULARY, FEAT-TEMPORARY-AUDIO-CLEANUP
- CON-DATA-WRITING-MODE-CONFIGURATION — Writing Mode Configuration (data) — Owner OWN-DATA-STORE — Features FEAT-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES, FEAT-MICROPHONE-CAPTURE-AND-FLOATING-HUD, FEAT-LOCAL-HISTORY-AND-OFFLINE-SEARCH, FEAT-CUSTOM-WRITING-MODES-AND-VOCABULARY
- CON-DATA-VOCABULARY-LIST — Vocabulary List (data) — Owner OWN-DATA-STORE — Features FEAT-CUSTOM-WRITING-MODES-AND-VOCABULARY
- CON-DATA-PROVIDER-PREFERENCE — Provider Preference (data) — Owner OWN-DATA-STORE — Features FEAT-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES, FEAT-MICROPHONE-CAPTURE-AND-FLOATING-HUD, FEAT-DUAL-PROVIDER-ROUTING, FEAT-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION, FEAT-LOCAL-HISTORY-AND-OFFLINE-SEARCH, FEAT-CUSTOM-WRITING-MODES-AND-VOCABULARY, FEAT-TEMPORARY-AUDIO-CLEANUP
- CON-DATA-HOTKEY-CONFIGURATION — Hotkey Configuration (data) — Owner OWN-DATA-STORE — Features FEAT-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES, FEAT-MICROPHONE-CAPTURE-AND-FLOATING-HUD, FEAT-LOCAL-HISTORY-AND-OFFLINE-SEARCH, FEAT-CUSTOM-WRITING-MODES-AND-VOCABULARY
- CON-DATA-CLIPBOARD-SNAPSHOT — Clipboard Snapshot (data) — Owner OWN-DATA-STORE — Features none
- CON-INTEGRATION-DEEPGRAM-NOVA-STREAMING-TRANSCRIPTION — Deepgram Nova streaming transcription integration (integration) — Owner OWN-INTEGRATION-DEEPGRAM-NOVA-STREAMING-TRANSCRIPTION — Features FEAT-DUAL-PROVIDER-ROUTING, FEAT-CREDENTIAL-VAULT
- CON-INTEGRATION-OPENROUTER-TRANSCRIPTION — OpenRouter transcription integration (integration) — Owner OWN-INTEGRATION-OPENROUTER-TRANSCRIPTION — Features FEAT-DUAL-PROVIDER-ROUTING, FEAT-CUSTOM-WRITING-MODES-AND-VOCABULARY, FEAT-CREDENTIAL-VAULT, FEAT-TEMPORARY-AUDIO-CLEANUP
- CON-INTEGRATION-OPENROUTER-REFINEMENT — OpenRouter refinement integration (integration) — Owner OWN-INTEGRATION-OPENROUTER-REFINEMENT — Features FEAT-DUAL-PROVIDER-ROUTING, FEAT-CUSTOM-WRITING-MODES-AND-VOCABULARY, FEAT-CREDENTIAL-VAULT, FEAT-TEMPORARY-AUDIO-CLEANUP
- CON-LIFECYCLE-APPLICATION-LAUNCH — Application launch (lifecycle) — Owner OWN-LIFECYCLE-COORDINATOR — Features none
- CON-LIFECYCLE-APPLICATION-TERMINATION — Application termination (lifecycle) — Owner OWN-LIFECYCLE-COORDINATOR — Features none
- CON-LIFECYCLE-AUDIO-CAPTURE-TERMINATION — Audio capture termination (lifecycle) — Owner OWN-LIFECYCLE-COORDINATOR — Features FEAT-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES, FEAT-MICROPHONE-CAPTURE-AND-FLOATING-HUD, FEAT-DUAL-PROVIDER-ROUTING, FEAT-PROVIDER-SELECTION-AND-COST-PROTECTION, FEAT-TEMPORARY-AUDIO-CLEANUP
- CON-LIFECYCLE-PRESET — Native macOS SwiftUI Menu Bar lifecycle (lifecycle) — Owner OWN-LIFECYCLE-COORDINATOR — Features FEAT-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES, FEAT-MICROPHONE-CAPTURE-AND-FLOATING-HUD, FEAT-DUAL-PROVIDER-ROUTING, FEAT-PROVIDER-SELECTION-AND-COST-PROTECTION, FEAT-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION, FEAT-LOCAL-HISTORY-AND-OFFLINE-SEARCH, FEAT-CUSTOM-WRITING-MODES-AND-VOCABULARY, FEAT-CREDENTIAL-VAULT, FEAT-TEMPORARY-AUDIO-CLEANUP
- CON-PERSISTENCE-TRANSCRIPT — Transcript persistence (persistence) — Owner OWN-DATA-STORE — Features FEAT-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES, FEAT-MICROPHONE-CAPTURE-AND-FLOATING-HUD, FEAT-DUAL-PROVIDER-ROUTING, FEAT-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION, FEAT-LOCAL-HISTORY-AND-OFFLINE-SEARCH, FEAT-CUSTOM-WRITING-MODES-AND-VOCABULARY, FEAT-TEMPORARY-AUDIO-CLEANUP
- CON-PERSISTENCE-TEMPORARY-AUDIO-RECORDING — Temporary Audio Recording persistence (persistence) — Owner OWN-DATA-STORE — Features FEAT-TEMPORARY-AUDIO-CLEANUP
- CON-PERSISTENCE-WRITING-MODE-CONFIGURATION — Writing Mode Configuration persistence (persistence) — Owner OWN-DATA-STORE — Features FEAT-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES, FEAT-MICROPHONE-CAPTURE-AND-FLOATING-HUD, FEAT-LOCAL-HISTORY-AND-OFFLINE-SEARCH, FEAT-CUSTOM-WRITING-MODES-AND-VOCABULARY
- CON-PERSISTENCE-VOCABULARY-LIST — Vocabulary List persistence (persistence) — Owner OWN-DATA-STORE — Features FEAT-CUSTOM-WRITING-MODES-AND-VOCABULARY
- CON-PERSISTENCE-PROVIDER-PREFERENCE — Provider Preference persistence (persistence) — Owner OWN-DATA-STORE — Features FEAT-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES, FEAT-MICROPHONE-CAPTURE-AND-FLOATING-HUD, FEAT-DUAL-PROVIDER-ROUTING, FEAT-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION, FEAT-LOCAL-HISTORY-AND-OFFLINE-SEARCH, FEAT-CUSTOM-WRITING-MODES-AND-VOCABULARY, FEAT-TEMPORARY-AUDIO-CLEANUP
- CON-PERSISTENCE-HOTKEY-CONFIGURATION — Hotkey Configuration persistence (persistence) — Owner OWN-DATA-STORE — Features FEAT-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES, FEAT-MICROPHONE-CAPTURE-AND-FLOATING-HUD, FEAT-LOCAL-HISTORY-AND-OFFLINE-SEARCH, FEAT-CUSTOM-WRITING-MODES-AND-VOCABULARY
- CON-PERSISTENCE-CLIPBOARD-SNAPSHOT — Clipboard Snapshot persistence (persistence) — Owner OWN-DATA-STORE — Features none
- CON-CREDENTIAL-DEEPGRAM-NOVA-STREAMING-TRANSCRIPTION — Deepgram Nova streaming transcription credential (credential) — Owner OWN-CREDENTIAL-VAULT — Features FEAT-DUAL-PROVIDER-ROUTING, FEAT-CREDENTIAL-VAULT
- CON-CREDENTIAL-OPENROUTER — OpenRouter credential (credential) — Owner OWN-CREDENTIAL-VAULT — Features FEAT-DUAL-PROVIDER-ROUTING, FEAT-CUSTOM-WRITING-MODES-AND-VOCABULARY, FEAT-CREDENTIAL-VAULT, FEAT-TEMPORARY-AUDIO-CLEANUP
- CON-PERMISSION-MICROPHONE — microphone permission (permission) — Owner OWN-PERMISSION-COORDINATOR — Features FEAT-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES, FEAT-MICROPHONE-CAPTURE-AND-FLOATING-HUD, FEAT-DUAL-PROVIDER-ROUTING, FEAT-PROVIDER-SELECTION-AND-COST-PROTECTION, FEAT-TEMPORARY-AUDIO-CLEANUP
- CON-PERMISSION-CLIPBOARD — clipboard permission (permission) — Owner OWN-PERMISSION-COORDINATOR — Features FEAT-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION, FEAT-LOCAL-HISTORY-AND-OFFLINE-SEARCH
- CON-PERMISSION-GLOBAL-INPUT — global-input permission (permission) — Owner OWN-PERMISSION-COORDINATOR — Features FEAT-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES
- CON-PERMISSION-ACCESSIBILITY — accessibility permission (permission) — Owner OWN-PERMISSION-COORDINATOR — Features FEAT-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION
- CON-PERMISSION-NOTIFICATIONS — notifications permission (permission) — Owner OWN-PERMISSION-COORDINATOR — Features none
- CON-PERMISSION-FILESYSTEM — filesystem permission (permission) — Owner OWN-PERMISSION-COORDINATOR — Features none
- CON-PERMISSION-NETWORK — network permission (permission) — Owner OWN-PERMISSION-COORDINATOR — Features FEAT-DUAL-PROVIDER-ROUTING, FEAT-PROVIDER-SELECTION-AND-COST-PROTECTION, FEAT-CREDENTIAL-VAULT
- CON-PERMISSION-BACKGROUND-STARTUP — background-startup permission (permission) — Owner OWN-PERMISSION-COORDINATOR — Features none
- CON-SECURITY-BOUNDARY — Privacy and security boundary (security) — Owner OWN-PACKAGING — Features FEAT-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES, FEAT-MICROPHONE-CAPTURE-AND-FLOATING-HUD, FEAT-DUAL-PROVIDER-ROUTING, FEAT-PROVIDER-SELECTION-AND-COST-PROTECTION, FEAT-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION, FEAT-LOCAL-HISTORY-AND-OFFLINE-SEARCH, FEAT-CUSTOM-WRITING-MODES-AND-VOCABULARY, FEAT-CREDENTIAL-VAULT, FEAT-TEMPORARY-AUDIO-CLEANUP
- CON-PACKAGING-RELEASE — Native macOS SwiftUI Menu Bar packaging (packaging) — Owner OWN-PACKAGING — Features FEAT-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES, FEAT-MICROPHONE-CAPTURE-AND-FLOATING-HUD, FEAT-DUAL-PROVIDER-ROUTING, FEAT-PROVIDER-SELECTION-AND-COST-PROTECTION, FEAT-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION, FEAT-LOCAL-HISTORY-AND-OFFLINE-SEARCH, FEAT-CUSTOM-WRITING-MODES-AND-VOCABULARY, FEAT-CREDENTIAL-VAULT, FEAT-TEMPORARY-AUDIO-CLEANUP
