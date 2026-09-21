# Architectural Retrospective & Lessons Learned: WhisperBar Audits

This document captures the failure modes, blind spots, and architectural lessons from the 4-round audit cycle of WhisperBar (v1.1.0 → v1.1.2).

---

## 1. Failure Modes & Root Causes

### A. The "Mock-to-Mock" Verification Trap
* **The Failure:** Early unit tests were written to verify individual helper methods in isolation rather than the integrated execution path. For instance:
  - `statusPillDismissalWhenIdle` invoked `microphoneCaptureFeature.clearStatusPill()` directly. It never called `handleHudCancelControl()` (the actual action triggered when a user clicks Cancel on the floating HUD). The test passed, but the user button remained completely inert.
  - The icon test manually assigned `controller.sessionPhase = .failed` and verified the property setter, rather than exercising `failActiveRecordingSession` during an actual socket drop.
* **The Rule:** **Never assert on manually synthesized downstream states.** A test must trigger the root action (`room.hud.cancelAction?()`, `failNextReceive()`, `startInAppRecording()`) and verify that the full cascade settles correctly.

---

### B. Incomplete Abstraction & String-Matching Fallbacks
* **The Failure:** The `SessionPhase` enum (`idle`, `recording`, `refining`, `blocked`, `failed`) was introduced to be the single source of truth for the app's visual state. However:
  - `updateMenuBarIcon()` retained fallback clauses checking `statusText.contains("Refining")` or `statusText.contains("blocked")`.
  - Notice routing (`onHudNotice`) passed raw user-facing text, requiring the controller to guess what phase the app was entering by searching for the word `"Refining"`.
  - Any copy change, localization, or rewording silently desynchronized the menu bar icon.
* **The Rule:** **Eliminate all string parsing from state machines.** State transitions must be driven strictly by typed enums (e.g. `HudNoticePhase.refining` vs `.status`). If a method still relies on `.contains(...)` after introducing an enum, the abstraction is incomplete.

---

### C. The SwiftUI Layout Shift Drag Cancellation Bug
* **The Failure:** The in-app "Hold to Talk" button was implemented using `Text(...)` and `.gesture(DragGesture(minimumDistance: 0))`.
  - When pressed, the text swapped from `"Press & Hold to Speak"` to `"Release to Finish"`, and an additional Cancel button appeared in the row.
  - This changed the frame geometry and view hierarchy underneath the pointer while the mouse button was held down.
  - The layout shift caused SwiftUI to cancel the active drag gesture immediately, aborting recording within milliseconds of starting.
  - Additionally, `DragGesture` completely broke VoiceOver and keyboard accessibility.
* **The Rule:** **Hold-to-talk controls must use fixed layout bounds and track press transitions without structural hierarchy changes.** Use a fixed-size `Button` with a custom `ButtonStyle` listening to `configuration.isPressed`, and expose explicit VoiceOver `.accessibilityAction` handlers.

---

### D. Blocking Socket Reads in Real-Time Control Loops
* **The Failure:** `URLSessionWebSocketTask.receive()` suspends indefinitely when no audio is incoming (silence).
  - Awaiting `receive()` directly inside the session loop prevented the controller from inspecting `stopRequested`.
  - Hitting Stop appeared completely unresponsive until the next Deepgram frame arrived or the 15-second network timeout fired.
* **The Rule:** **Network socket reads must never block control state machines.** Use detached read tasks raced against bounded poll intervals (`sessionTickInterval = 40ms`). Benign pauses (`pollIdle`) must allow the loop to tick without canceling the in-flight read.

---

### E. Keyboard Recorder Interaction Edge Cases
* **The Failure:**
  - Pressing Escape while recording a shortcut was captured as a key event, synthesizing a shortcut like `⌃⌥Escape`.
  - Pressing any bare key without modifiers automatically invented modifiers (`⌃⌥`).
  - Both push-to-talk and toggle shortcut recorders could be armed simultaneously, stealing keystrokes from each other.
* **The Rule:**
  - Escape (`keyCode 53`) must unconditionally cancel recording without committing changes.
  - Bare keystrokes without modifier flags must be rejected.
  - Multi-role shortcut editors must share an exclusive `armedRole` coordinator.

---

### F. Environment & Packaging Assumptions
* **The Failure:**
  - `package_app.sh` ran `open -b com.whisperbar.app` to verify installation. On macOS, LaunchServices resolved this to the already-open instance in `dist/` rather than `/Applications/WhisperBar.app`.
  - Smoke tests checked `LSBundlePath`, which is not an emitted key in `lsappinfo info`.
* **The Rule:** **Never assume bundle IDs identify disk paths.** Verification scripts must terminate running instances (`pkill`), explicitly launch the targeted bundle path (`open "$INSTALL_TARGET"`), and assert against `bundle path=`.

---

## 2. Checklist for Future Work

- [ ] **No Substring State Inference:** Never inspect user-facing strings to determine internal state.
- [ ] **No Layout Shifts in Pointer Tracking:** Press tracking views must keep identical dimensions when pressed.
- [ ] **Zero Blocking in Event Loops:** Real-time pump loops must have sub-50ms tick timeouts.
- [ ] **End-to-End Test Plumbing:** Verify user-facing closures (`cancelAction`, `stopAction`), never internal setters.
- [ ] **Targeted Process Verification:** Verify binaries by exact file path on disk, not just bundle identifier.
