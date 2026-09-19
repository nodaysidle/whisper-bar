---
title: WhisperBar Vault Receipt and Project Handoff
type: project-handoff
status: local-release-candidate
project: WhisperBar
created: 2026-09-19 19:37 CEST
source: Eldio/Hermes verified build session
canonical_project_path: /Volumes/omarchyuser/projekti/whisper-bar
---

# WhisperBar — Vault Receipt & Project Handoff

## Executive status

WhisperBar is a native macOS menu-bar dictation application implemented from the canonical project packet in `/Volumes/omarchyuser/projekti/whisper-bar/`. All **18/18 sequential phases** in `TASKS.md` were implemented and the final local release candidate passed its automated tests, release build, packaging, strict local code-sign verification, DMG verification, fresh launch, clean termination, and an independent cold sign-off audit.

**Local status:** release candidate ready for manual device/provider validation and production signing/notarization.  
**Cold audit:** PASS, 9/10, no P0–P2 production blockers.  
**Distribution boundary:** locally ad-hoc signed only; not installed to `/Applications`, Developer ID signed, notarized, uploaded, or published.

## 1. Architectural Summary & Verified Spec Compliance

### Canonical packet

Implementation followed the authority chain defined by the project:

1. `AGENTS.md` — execution constraints, file ownership, strict-concurrency rules, and forbidden patterns.
2. `PRD.md` — product behavior and user meaning.
3. `ARD.md` — architecture boundaries and ownership hierarchy.
4. `TRD.md` — provider, audio, persistence, security, and packaging contracts.
5. `TASKS.md` — 18-phase sequential implementation plan.

### Phase completion

| Phase | Delivery | Status |
| --- | --- | --- |
| 01 | Foundation, app identity, `MenuBarExtra`, settings scene | Verified |
| 02 | Native Keychain credential vault | Verified |
| 03 | SQLite/UserDefaults data ownership boundaries | Verified |
| 04 | Application lifecycle coordination | Verified |
| 05 | Permissions and recovery guidance | Verified |
| 06 | Global hotkeys, push-to-talk, and toggle modes | Verified |
| 07 | Deepgram Nova streaming integration | Verified |
| 08 | OpenRouter refinement integration | Verified |
| 09 | OpenRouter batch transcription integration | Verified |
| 10 | Credential-vault UI feature | Verified |
| 11 | Custom writing modes and vocabulary | Verified |
| 12 | Explicit dual-provider routing | Verified |
| 13 | Bounded local history and offline search | Verified |
| 14 | Microphone capture and non-activating floating HUD | Verified |
| 15 | Deterministic paste coordinator | Verified |
| 16 | Provider selection and paid-request cost protection | Verified |
| 17 | Temporary-audio cleanup and recovery | Verified |
| 18 | `.app`/DMG packaging and signing contract | Verified |

### Native architecture

- **Language/runtime:** Swift 6 with strict concurrency checks.
- **UI:** SwiftUI `MenuBarExtra` and settings surfaces with AppKit bridges where native macOS behavior is required.
- **Composition owner:** `@Observable @MainActor final class MenuBarController`.
- **Concurrency boundaries:** main-actor presentation/state ownership; actor/sendable boundaries for audio, provider, persistence, and lifecycle work; no package-wide default main-actor isolation.
- **Audio:** microphone frames are converted to headerless signed 16-bit little-endian, 16 kHz, mono PCM and delivered through one ordered consumer; recoverable audio is stored in a valid WAV container.
- **Persistence:** SQLite/FTS5 for bounded local transcript history; UserDefaults only for non-secret preferences such as provider and shortcut configuration.
- **Credentials:** native Security framework generic-password Keychain items under service `com.whisperbar.app.credentials`; credentials are never persisted to UserDefaults, plist files, history, or logs.
- **Lifecycle:** one authoritative recording session machine covers hotkeys, in-app controls, HUD controls, start-window stop/cancel races, provider cost state, history, paste, and verified temporary-audio cleanup.
- **Runtime minimum:** macOS **14.0**. This is an intentional implementation deviation from the canonical 13.0 literal because Observation's `@Observable` requires macOS 14; `Package.swift`, `AppIdentity`, packaged `Info.plist`, Mach-O deployment target, and tests agree on 14.0.

### Security and privacy compliance

- Provider credentials remain request-local and Keychain-backed.
- No plaintext credential persistence path was found by contract tests or cold audit.
- No automatic paid provider fallback or retry is allowed.
- Provider selection is explicit, persisted only after both routing and cost owners agree, and locked while a recording is starting or active.
- Clipboard restoration is ownership-safe; external clipboard mutation wins.
- Temporary audio is deleted through bounded retries and verified absence before cleanup is claimed.

## 2. Artifact Manifest & Distribution Paths

| Artifact | Path | Verification |
| --- | --- | --- |
| Application bundle | `/Volumes/omarchyuser/projekti/whisper-bar/dist/WhisperBar.app` | arm64, bundle ID `com.whisperbar.app`, macOS 14.0, strict codesign verification passed |
| DMG | `/Volumes/omarchyuser/projekti/whisper-bar/dist/WhisperBar.dmg` | 3,057,132 bytes; `hdiutil verify` VALID |
| Release executable | `/Volumes/omarchyuser/projekti/whisper-bar/.build/release/Whisperbar` | release build passed; packaged executable 3,190,384 bytes |
| App icon source | `/Volumes/omarchyuser/projekti/whisper-bar/Resources/AppIcon.png` | packaging contract validated |
| App icon bundle resource | `/Volumes/omarchyuser/projekti/whisper-bar/Resources/AppIcon.icns` | packaging contract validated |
| Bundle metadata | `/Volumes/omarchyuser/projekti/whisper-bar/Resources/Info.plist` | identity/minimum-OS contract validated |
| Entitlements | `/Volumes/omarchyuser/projekti/whisper-bar/Resources/App.entitlements` | reviewed empty dictionary for local ad-hoc package |
| Packaging script | `/Volumes/omarchyuser/projekti/whisper-bar/Scripts/package_app.sh` | fail-closed package/sign/DMG flow verified |

### Checksums

- `WhisperBar.dmg` SHA-256: `dbbea3bc19bcbd764689a851cc98be51cda20c763a0bcb2e2835efcb5ca0aaa0`
- `AppIcon.icns` SHA-256: `bb0e0b037205e1844e4ab627051b6c9edefd75c0038b19dd556ba70790b93f1a`
- `AppIcon.png` SHA-256: `ef7b045eaa2dccd59c663f6f7ffc15bf6a9f66e1e28c0b1e5b6ab8b2b06dca40`

### Signing state

- Identifier: `com.whisperbar.app`
- Signature: ad-hoc
- Team identifier: not set
- Strict verification: passed
- Developer ID signing: not performed
- Apple notarization/stapling: not performed

## 3. Test Matrix & Verification Signoff

| Gate | Observed result |
| --- | --- |
| Focused controller composition suite | **13/13 passed** |
| Full Swift Testing suite | **268/268 passed across 19 suites** |
| Test failures | **0** |
| `swift build -c release` | PASS |
| Packaging script | PASS |
| Arm64 and minimum-OS checks | PASS |
| `codesign --verify --deep --strict` | PASS |
| `hdiutil verify dist/WhisperBar.dmg` | VALID |
| Fresh packaged launch | PASS, PID observed |
| Clean SIGTERM shutdown | PASS |
| Independent cold sign-off audit | PASS, 9/10, no P0–P2 blockers |
| `.build` files tracked by Git | 0 |

### Warning disclosure

The requested “zero warnings” statement cannot be truthfully attested. The final release build passed but emitted **three known compiler warnings**:

1. `Sources/Whisperbar/Platform/CredentialVault.swift:172` — redundant optional comparison.
2. `Sources/Whisperbar/Platform/DataStore.swift:436` — unused result from best-effort rollback.
3. `Sources/Whisperbar/Platform/OpenrouterTranscriptionIntegration.swift:416` — unused decoded error envelope.

They are non-blocking and were present at final sign-off, but should be cleared before a public production release. Automated test warnings/failures did not invalidate the 268/268 result.

### High-value regression coverage

- HUD and in-app Stop/Cancel use the authoritative session lifecycle.
- Stop/cancel during every start window is remembered and cannot create a ghost paid recording.
- Two consecutive recording sessions open and finalize independently.
- Microphone permission resolves before provider connection.
- Deepgram interim text reaches presentation and clears on terminal paths.
- Streaming and batch routes produce canonical WAV recovery/transcription input.
- Header-only/empty batch audio is rejected before provider transport.
- Recoverable provider failure retains finalized audio only for explicit recovery.
- Provider switching is locked during start/recording and rolls back on owner rejection.
- Paid-request completion, failure, and cancellation reset the gate for later sessions.
- History, paste, and temporary cleanup execute only on accepted final transcripts.

## 4. Subsystem & Provider Wire Inventory

### Deepgram Nova streaming

- Endpoint family: `wss://api.deepgram.com/v1/listen`
- Model: `nova-3`
- Encoding: `linear16`
- Sample rate: `16000`
- Channels: mono
- Authentication: `Token` header sourced from Keychain at request time.
- Frames: ordered binary PCM delivery; no empty or misaligned frames.
- Keepalive: sent only after real audio and while idle.
- Completion: explicit `Finalize`, terminal metadata, and close handling.
- Presentation: interim transcript plus ordered accepted final segments.
- Failure policy: no silent fallback; recoverable failures can retain finalized local WAV audio for explicit user action.

### OpenRouter batch transcription

- Endpoint: `/api/v1/audio/transcriptions`
- Input: finalized local WAV recorded from the same canonical 16 kHz mono PCM stream.
- Local preflight: supported audio, non-empty payload, maximum 25 MB, maximum 60 seconds.
- Correlation: `X-Generation-Id` retained when provided.
- Cost: authoritative provider-reported usage only; unavailable rather than estimated when omitted.
- Retry/fallback: explicit user action only.

### OpenRouter refinement

- Endpoint: `/api/v1/chat/completions`
- Model: `google/gemini-2.5-flash-lite`
- Temperature: `0.0`
- Inputs: accepted raw transcript plus deterministic writing-mode/vocabulary context.
- Disabled or unconfigured state: zero refinement requests and zero refinement spend.
- Failure policy: raw transcript remains authoritative; failed/blank refinement never replaces it.

### Supporting subsystems

- **CredentialVault:** Keychain save/delete/status/test with no secret reflection into observable or persisted UI state.
- **PermissionCoordinator:** microphone, Accessibility, global input, notifications, clipboard, filesystem, and network status/recovery boundaries.
- **GlobalHotkeys:** push-to-talk and toggle modes, collision recovery, one authoritative recording session.
- **DataStore:** versioned SQLite schema, FTS5 offline search, bounded 500-item history, local-only transcript persistence.
- **PasteCoordinator:** captured-target insertion, direct Accessibility path, clipboard fallback, preview/copy-only modes, bounded wait, ownership-safe restore.
- **TemporaryAudioCleanup:** verified deletion, bounded retry, retained-recovery save/discard/retry controls, native save destination chooser.
- **LifecycleCoordinator:** menu-bar activation policy, launch-at-login control, awaited termination cleanup.

## 5. Next Milestones & Production Handoff Checklist

### Required before public production release

- [ ] Resolve the three compiler warnings and rerun all 268 tests, release build, package, signing, and smoke gates.
- [ ] Exercise first-run microphone, Accessibility, Input Monitoring/global-hotkey, notification, and clipboard permission flows on a clean macOS 14+ account.
- [ ] Validate real Keychain save/read/delete behavior with non-production test credentials.
- [ ] Run a live Deepgram streaming session, including interim text, explicit finalize, network interruption, stop-during-connect, and retained-audio recovery.
- [ ] Run live OpenRouter batch transcription and refinement with bounded test audio and verify usage/cost reporting.
- [ ] Verify paste behavior in representative native and non-native target applications.
- [ ] Run VoiceOver, keyboard focus-order, reduced-motion, contrast, and Accessibility Inspector checks.
- [ ] Close the cold-audit P3 advisory: prevent retention of a header-only WAV if a zero-audio Deepgram session encounters a coincident recoverable transport failure.
- [ ] Perform Developer ID Application signing with an approved Apple Developer identity.
- [ ] Submit for notarization and staple the ticket to the `.app`/DMG.
- [ ] Validate Gatekeeper behavior on a clean machine and launch from the mounted DMG.
- [ ] Decide the release version, changelog, privacy/support URLs, and distribution channel.
- [ ] Recompute and record final artifact sizes and SHA-256 hashes after production signing/notarization.

### Explicit non-actions in this build session

- No `/Applications` installation.
- No Developer ID signing or notarization.
- No live provider credentials or paid API calls.
- No commit, push, pull request, GitHub release, or deployment.
- No canonical specification documents were rewritten to hide the macOS 14 deployment deviation.

## Handoff commands

From `/Volumes/omarchyuser/projekti/whisper-bar`:

```sh
swift test
swift build -c release
./Scripts/package_app.sh
codesign --verify --deep --strict dist/WhisperBar.app
hdiutil verify dist/WhisperBar.dmg
```

Installation remains separately approval-gated by the packaging script.

## Final receipt

- Final automated suite: **268/268 passing**.
- Final cold audit: **PASS**.
- Local package/sign/DMG/fresh-launch evidence: **PASS**.
- Production deployment state: **handoff-ready, not publicly released**.
- Canonical project receipt: `/Volumes/omarchyuser/projekti/whisper-bar/SUMMARIZE.md`.
