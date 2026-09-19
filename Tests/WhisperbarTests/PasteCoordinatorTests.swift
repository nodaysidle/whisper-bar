import Foundation
import Testing
@testable import Whisperbar

/// TASK-15-PASTE-COORDINATOR focused checks.
///
/// Covers FEAT-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION and contracts
/// CON-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION-INTERFACE,
/// CON-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION-RECOVERY, and
/// CON-PASTE-WORKFLOW (steps 1–15) through fully injected native seams: no
/// live application, no Accessibility element, no real clipboard, no
/// synthesized key event, and no TCC prompt is touched by these tests.
@Suite("PasteCoordinator — deterministic paste workflow")
@MainActor
struct PasteCoordinatorTests {

    // MARK: - Fakes

    /// One direct Accessibility insertion interaction.
    struct DirectInsertion: Equatable {
        let text: String
        let processIdentifier: Int32
    }

    /// Full in-memory native environment implementing every injected seam of
    /// CON-PASTE-WORKFLOW's native adapter boundary.
    final class FakeInsertionEnvironment: @unchecked Sendable,
        FocusedTargetCapturing, AccessibilityInserting, PasteboardServicing,
        TargetActivating, CommandVPressing {

        private let lock = NSLock()

        // Configurable behavior
        private var _nextCapturedTarget: InsertionTarget?
        private var _targetStillValid = true
        private var _directInsertionSucceeds = true
        private var _writeSucceeds = true
        private var _restoreSucceeds = true
        private var _activationSucceeds = true
        private var _frontmostAfterActivation = true
        private var _commandVSucceeds = true

        /// Two representations prove the snapshot keeps every item
        /// representation, not only plain text.
        private var _representations: [PasteboardRepresentation] = [
            PasteboardRepresentation(
                type: "public.utf8-plain-text",
                data: Data("original clipboard".utf8)
            ),
            PasteboardRepresentation(
                type: "public.rtf",
                data: Data("{\\rtf1 original}".utf8)
            ),
        ]
        private var _changeCount = 41

        // Interaction logs
        private var _events: [String] = []
        private var _captureCallCount = 0
        private var _validityChecks: [Int32] = []
        private var _directInsertions: [DirectInsertion] = []
        private var _snapshotCallCount = 0
        private var _writes: [String] = []
        private var _activationCalls: [Int32] = []
        private var _frontmostChecks: [Int32] = []
        private var _commandVCalls = 0
        private var _changeCountReads = 0
        private var _restoreCalls: [ClipboardSnapshot] = []

        var nextCapturedTarget: InsertionTarget? {
            get { lock.withLock { _nextCapturedTarget } }
            set { lock.withLock { _nextCapturedTarget = newValue } }
        }
        var targetStillValid: Bool {
            get { lock.withLock { _targetStillValid } }
            set { lock.withLock { _targetStillValid = newValue } }
        }
        var directInsertionSucceeds: Bool {
            get { lock.withLock { _directInsertionSucceeds } }
            set { lock.withLock { _directInsertionSucceeds = newValue } }
        }
        var writeSucceeds: Bool {
            get { lock.withLock { _writeSucceeds } }
            set { lock.withLock { _writeSucceeds = newValue } }
        }
        var restoreSucceeds: Bool {
            get { lock.withLock { _restoreSucceeds } }
            set { lock.withLock { _restoreSucceeds = newValue } }
        }
        var activationSucceeds: Bool {
            get { lock.withLock { _activationSucceeds } }
            set { lock.withLock { _activationSucceeds = newValue } }
        }
        var frontmostAfterActivation: Bool {
            get { lock.withLock { _frontmostAfterActivation } }
            set { lock.withLock { _frontmostAfterActivation = newValue } }
        }
        var commandVSucceeds: Bool {
            get { lock.withLock { _commandVSucceeds } }
            set { lock.withLock { _commandVSucceeds = newValue } }
        }

        var events: [String] { lock.withLock { _events } }
        var captureCallCount: Int { lock.withLock { _captureCallCount } }
        var validityChecks: [Int32] { lock.withLock { _validityChecks } }
        var directInsertions: [DirectInsertion] { lock.withLock { _directInsertions } }
        var snapshotCallCount: Int { lock.withLock { _snapshotCallCount } }
        var writes: [String] { lock.withLock { _writes } }
        var activationCalls: [Int32] { lock.withLock { _activationCalls } }
        var frontmostChecks: [Int32] { lock.withLock { _frontmostChecks } }
        var commandVCalls: Int { lock.withLock { _commandVCalls } }
        var changeCountReads: Int { lock.withLock { _changeCountReads } }
        var restoreCallCount: Int { lock.withLock { _restoreCalls.count } }
        var lastRestoredSnapshot: ClipboardSnapshot? { lock.withLock { _restoreCalls.last } }
        var changeCount: Int { lock.withLock { _changeCount } }
        var clipboardText: String? {
            lock.withLock {
                guard let representation = _representations.first(where: { $0.type == "public.utf8-plain-text" }) else {
                    return nil
                }
                return String(data: representation.data, encoding: .utf8)
            }
        }

        /// Simulates another application or the user changing the clipboard.
        func mutateClipboardExternally(_ text: String) {
            lock.withLock {
                _changeCount += 1
                _events.append("externalMutation")
                _representations = [
                    PasteboardRepresentation(
                        type: "public.utf8-plain-text",
                        data: Data(text.utf8)
                    )
                ]
            }
        }

        // MARK: FocusedTargetCapturing (steps 1 and 4)

        func captureTarget() -> InsertionTarget? {
            lock.withLock {
                _captureCallCount += 1
                _events.append("capture")
                return _nextCapturedTarget
            }
        }

        func isTargetStillValid(_ target: InsertionTarget) -> Bool {
            lock.withLock {
                _validityChecks.append(target.processIdentifier)
                _events.append("validity:\(target.processIdentifier)")
                return _targetStillValid
            }
        }

        // MARK: AccessibilityInserting (step 5)

        func insertViaSelectedText(_ text: String, into target: InsertionTarget) -> Bool {
            lock.withLock {
                _directInsertions.append(
                    DirectInsertion(text: text, processIdentifier: target.processIdentifier)
                )
                _events.append("directInsert:\(target.processIdentifier)")
                return _directInsertionSucceeds
            }
        }

        // MARK: PasteboardServicing (steps 6, 7, 11, 12)

        func snapshot() -> ClipboardSnapshot {
            lock.withLock {
                _snapshotCallCount += 1
                _events.append("snapshot:\(_changeCount)")
                return ClipboardSnapshot(
                    items: [PasteboardItemSnapshot(representations: _representations)],
                    changeCount: _changeCount
                )
            }
        }

        func writeText(_ text: String) -> Int? {
            lock.withLock {
                _events.append("write")
                guard _writeSucceeds else { return nil }
                _writes.append(text)
                _changeCount += 1
                _representations = [
                    PasteboardRepresentation(
                        type: "public.utf8-plain-text",
                        data: Data(text.utf8)
                    )
                ]
                return _changeCount
            }
        }

        func currentChangeCount() -> Int {
            lock.withLock {
                _changeCountReads += 1
                _events.append("changeCount:\(_changeCount)")
                return _changeCount
            }
        }

        func restore(_ snapshot: ClipboardSnapshot) -> Bool {
            lock.withLock {
                _restoreCalls.append(snapshot)
                _events.append("restore")
                guard _restoreSucceeds else { return false }
                _changeCount += 1
                _representations = snapshot.items.first?.representations ?? []
                return true
            }
        }

        // MARK: TargetActivating (step 8)

        func activate(_ target: InsertionTarget) -> Bool {
            lock.withLock {
                _activationCalls.append(target.processIdentifier)
                _events.append("activate:\(target.processIdentifier)")
                return _activationSucceeds
            }
        }

        func isFrontmost(_ target: InsertionTarget) -> Bool {
            lock.withLock {
                _frontmostChecks.append(target.processIdentifier)
                _events.append("frontmost:\(target.processIdentifier)")
                return _frontmostAfterActivation
            }
        }

        // MARK: CommandVPressing (step 9)

        func synthesizeCommandV() -> Bool {
            lock.withLock {
                _commandVCalls += 1
                _events.append("commandV")
                return _commandVSucceeds
            }
        }
    }

    /// Observable permission states shared by the availability/request seams.
    final class FakePermissionStates: @unchecked Sendable {
        private let lock = NSLock()
        private var _accessibility: PermissionState = .authorized
        private var _clipboard: PermissionState = .authorized

        var accessibility: PermissionState {
            get { lock.withLock { _accessibility } }
            set { lock.withLock { _accessibility = newValue } }
        }
        var clipboard: PermissionState {
            get { lock.withLock { _clipboard } }
            set { lock.withLock { _clipboard = newValue } }
        }
    }

    /// The explicit Accessibility trust request seam; never a TCC prompt.
    final class FakeTrustRequester: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        private var _result: PermissionState = .denied

        var calls: Int { lock.withLock { _calls } }

        func setResult(_ value: PermissionState) {
            lock.withLock { _result = value }
        }

        func request() async -> PermissionState {
            lock.withLock {
                _calls += 1
                return _result
            }
        }
    }

    /// The bounded-wait seam (step 10); records the requested interval and can
    /// inject an external clipboard mutation exactly when the wait fires.
    final class FakeWait: @unchecked Sendable {
        private let lock = NSLock()
        private var _intervals: [Int] = []
        private var _onWait: (() -> Void)?

        var intervals: [Int] { lock.withLock { _intervals } }

        func setOnWait(_ action: (() -> Void)?) {
            lock.withLock { _onWait = action }
        }

        func wait(_ milliseconds: Int) async {
            let action = lock.withLock { () -> (() -> Void)? in
                _intervals.append(milliseconds)
                return _onWait
            }
            action?()
        }
    }

    // MARK: - Room

    struct Room {
        let coordinator: PasteCoordinator
        let environment: FakeInsertionEnvironment
        let permissions: FakePermissionStates
        let trust: FakeTrustRequester
        let wait: FakeWait
    }

    private func makeTarget(
        pid: Int32 = 4242,
        bundle: String = "com.example.editor",
        editable: Bool = true
    ) -> InsertionTarget {
        InsertionTarget(
            processIdentifier: pid,
            bundleIdentifier: bundle,
            localizedName: "Example Editor",
            hasEditableSelectedTextBoundary: editable
        )
    }

    private func makeRoom() -> Room {
        let environment = FakeInsertionEnvironment()
        let permissions = FakePermissionStates()
        let trust = FakeTrustRequester()
        let wait = FakeWait()
        let coordinator = PasteCoordinator(
            targetCapture: environment,
            accessibilityInserter: environment,
            pasteboard: environment,
            activator: environment,
            commandVPressing: environment,
            accessibilityAvailability: { permissions.accessibility },
            requestAccessibilityTrust: {
                let state = await trust.request()
                permissions.accessibility = state
                return state
            },
            clipboardAvailability: { permissions.clipboard },
            waitForPasteConsumption: { await wait.wait($0) }
        )
        return Room(
            coordinator: coordinator,
            environment: environment,
            permissions: permissions,
            trust: trust,
            wait: wait
        )
    }

    private func isFailed(_ coordinator: PasteCoordinator) -> Bool {
        if case .failed = coordinator.state { return true }
        return false
    }

    // MARK: - Step 1: capture at recording start

    @Test("The target is captured once at recording start and a later focus change is never substituted")
    func captureStoresTargetAndLaterFocusIsNeverSubstituted() async {
        let room = makeRoom()
        room.environment.nextCapturedTarget = makeTarget(pid: 100)

        #expect(room.coordinator.captureInsertionTarget())
        #expect(room.coordinator.capturedTarget?.processIdentifier == 100)
        #expect(room.environment.captureCallCount == 1)

        // Focus moves to a different application after the capture.
        room.environment.nextCapturedTarget = makeTarget(pid: 999)

        #expect(await room.coordinator.requestInsertion(from: .succeeded(finalTranscript: "Hello", refinedText: nil)))
        #expect(room.environment.directInsertions == [DirectInsertion(text: "Hello", processIdentifier: 100)])
        #expect(room.environment.captureCallCount == 1)
        #expect(room.coordinator.lastInsertionPath == .directAccessibility)
    }

    // MARK: - Step 5: direct Accessibility insertion

    @Test("Direct Accessibility insertion writes the candidate without touching the clipboard")
    func directAccessibilityInsertionNeverTouchesTheClipboard() async {
        let room = makeRoom()
        room.environment.nextCapturedTarget = makeTarget(pid: 100)
        #expect(room.coordinator.captureInsertionTarget())

        #expect(await room.coordinator.requestInsertion(from: .succeeded(finalTranscript: "Direct text", refinedText: nil)))

        #expect(room.coordinator.state == .succeeded)
        #expect(room.coordinator.lastInsertionPath == .directAccessibility)
        #expect(room.environment.directInsertions == [DirectInsertion(text: "Direct text", processIdentifier: 100)])
        #expect(room.environment.snapshotCallCount == 0)
        #expect(room.environment.writes.isEmpty)
        #expect(room.environment.changeCountReads == 0)
        #expect(room.environment.restoreCallCount == 0)
        #expect(room.environment.activationCalls.isEmpty)
        #expect(room.environment.commandVCalls == 0)
        #expect(room.environment.clipboardText == "original clipboard")
        #expect(room.coordinator.retainedTranscriptText == nil)
    }

    // MARK: - Steps 6–11: clipboard fallback, one Command-V, bounded wait, restoration

    @Test("A non-editable target falls back to one snapshot, one write, one Command-V after activation, a 750 ms bounded wait, and an ownership-safe restore")
    func nonEditableTargetRunsTheDeterministicFallback() async {
        let room = makeRoom()
        room.environment.nextCapturedTarget = makeTarget(pid: 100, editable: false)
        #expect(room.coordinator.captureInsertionTarget())

        #expect(await room.coordinator.requestInsertion(from: .succeeded(finalTranscript: "Fallback text", refinedText: nil)))

        #expect(room.coordinator.state == .succeeded)
        #expect(room.coordinator.lastInsertionPath == .clipboardFallback)
        #expect(room.coordinator.lastRestoreOutcome == .restored)
        #expect(PasteCoordinator.pasteConsumptionWaitMilliseconds == 750)
        #expect(room.wait.intervals == [750])
        #expect(room.environment.snapshotCallCount == 1)
        #expect(room.environment.writes == ["Fallback text"])
        #expect(room.environment.activationCalls == [100])
        #expect(room.environment.frontmostChecks == [100])
        #expect(room.environment.commandVCalls == 1)
        #expect(room.environment.restoreCallCount == 1)
        #expect(room.environment.clipboardText == "original clipboard")
        // Every original representation is preserved and restored.
        #expect(room.environment.lastRestoredSnapshot?.items.first?.representations.count == 2)
        // Exact deterministic order of the native interactions.
        #expect(room.environment.events == [
            "capture",
            "validity:100",
            "snapshot:41",
            "write",
            "activate:100",
            "frontmost:100",
            "commandV",
            "changeCount:42",
            "restore",
        ])
    }

    @Test("A failed direct insertion attempt falls back to the clipboard path")
    func failedDirectInsertionFallsBackToTheClipboardPath() async {
        let room = makeRoom()
        room.environment.nextCapturedTarget = makeTarget(pid: 100, editable: true)
        room.environment.directInsertionSucceeds = false
        #expect(room.coordinator.captureInsertionTarget())

        #expect(await room.coordinator.requestInsertion(from: .succeeded(finalTranscript: "Fallback text", refinedText: nil)))

        #expect(room.coordinator.state == .succeeded)
        #expect(room.environment.directInsertions == [DirectInsertion(text: "Fallback text", processIdentifier: 100)])
        #expect(room.environment.writes == ["Fallback text"])
        #expect(room.environment.commandVCalls == 1)
        #expect(room.environment.restoreCallCount == 1)
    }

    // MARK: - Step 4: stale target

    @Test("A captured application that is no longer available fails before any privileged work and preserves the transcript")
    func staleTargetFailsBeforePrivilegedWork() async {
        let room = makeRoom()
        room.environment.nextCapturedTarget = makeTarget(pid: 100)
        room.environment.targetStillValid = false
        #expect(room.coordinator.captureInsertionTarget())

        #expect(await room.coordinator.requestInsertion(from: .succeeded(finalTranscript: "Hello", refinedText: nil)) == false)

        #expect(isFailed(room.coordinator))
        #expect(room.coordinator.lastFailure?.category == .targetNoLongerAvailable)
        #expect(room.environment.validityChecks == [100])
        #expect(room.environment.directInsertions.isEmpty)
        #expect(room.environment.snapshotCallCount == 0)
        #expect(room.environment.writes.isEmpty)
        #expect(room.environment.activationCalls.isEmpty)
        #expect(room.environment.commandVCalls == 0)
        #expect(room.environment.restoreCallCount == 0)
        #expect(room.environment.clipboardText == "original clipboard")
        // The completed transcript is retained with the documented recovery actions.
        #expect(room.coordinator.retainedTranscriptText == "Hello")
        #expect(room.coordinator.availableRecoveryActions == [.copy, .preview, .retry])
    }

    @Test("No captured target fails before any privileged work and preserves the transcript")
    func missingCapturedTargetFailsBeforePrivilegedWork() async {
        let room = makeRoom()

        #expect(await room.coordinator.requestInsertion(from: .succeeded(finalTranscript: "Hello", refinedText: nil)) == false)

        #expect(room.coordinator.lastFailure?.category == .noCapturedTarget)
        #expect(room.environment.validityChecks.isEmpty)
        #expect(room.environment.snapshotCallCount == 0)
        #expect(room.environment.writes.isEmpty)
        #expect(room.environment.commandVCalls == 0)
        #expect(room.coordinator.retainedTranscriptText == "Hello")
    }

    // MARK: - ACC-01: Accessibility trust

    @Test("Accessibility trust is requested exactly once when it has never been determined")
    func accessibilityTrustIsRequestedWhenNeeded() async {
        let room = makeRoom()
        room.environment.nextCapturedTarget = makeTarget(pid: 100)
        room.permissions.accessibility = .notDetermined
        room.trust.setResult(.authorized)
        #expect(room.coordinator.captureInsertionTarget())

        #expect(await room.coordinator.requestInsertion(from: .succeeded(finalTranscript: "Hello", refinedText: nil)))

        #expect(room.trust.calls == 1)
        #expect(room.coordinator.state == .succeeded)
        #expect(room.environment.directInsertions == [DirectInsertion(text: "Hello", processIdentifier: 100)])
    }

    @Test("An Accessibility denial skips privileged control, keeps the manual path, and never re-prompts")
    func accessibilityDenialKeepsTheManualPath() async {
        let room = makeRoom()
        room.environment.nextCapturedTarget = makeTarget(pid: 100)
        room.permissions.accessibility = .denied
        #expect(room.coordinator.captureInsertionTarget())

        #expect(await room.coordinator.requestInsertion(from: .succeeded(finalTranscript: "Hello", refinedText: nil)) == false)

        #expect(isFailed(room.coordinator))
        #expect(room.coordinator.lastFailure?.category == .accessibilityDenied)
        #expect(room.trust.calls == 0)
        #expect(room.environment.directInsertions.isEmpty)
        #expect(room.environment.snapshotCallCount == 0)
        #expect(room.environment.writes.isEmpty)
        #expect(room.environment.activationCalls.isEmpty)
        #expect(room.environment.commandVCalls == 0)
        #expect(room.environment.restoreCallCount == 0)
        // The clipboard keeps its prior content until an explicit user action.
        #expect(room.environment.clipboardText == "original clipboard")
        #expect(room.coordinator.retainedTranscriptText == "Hello")
        #expect(room.coordinator.availableRecoveryActions == [.copy, .preview, .retry])
    }

    @Test("A denied trust request after notDetermined still keeps the manual path")
    func deniedTrustRequestKeepsTheManualPath() async {
        let room = makeRoom()
        room.environment.nextCapturedTarget = makeTarget(pid: 100)
        room.permissions.accessibility = .notDetermined
        room.trust.setResult(.denied)

        #expect(await room.coordinator.requestInsertion(from: .succeeded(finalTranscript: "Hello", refinedText: nil)) == false)

        #expect(room.coordinator.lastFailure?.category == .accessibilityDenied)
        #expect(room.trust.calls == 1)
        #expect(room.environment.directInsertions.isEmpty)
        #expect(room.environment.commandVCalls == 0)
        #expect(room.coordinator.retainedTranscriptText == "Hello")
    }

    @Test("An unavailable clipboard stops the fallback before anything is written")
    func clipboardUnavailableStopsTheFallback() async {
        let room = makeRoom()
        room.environment.nextCapturedTarget = makeTarget(pid: 100, editable: false)
        room.permissions.clipboard = .denied
        #expect(room.coordinator.captureInsertionTarget())

        #expect(await room.coordinator.requestInsertion(from: .succeeded(finalTranscript: "Hello", refinedText: nil)) == false)

        #expect(room.coordinator.lastFailure?.category == .clipboardUnavailable)
        #expect(room.environment.snapshotCallCount == 0)
        #expect(room.environment.writes.isEmpty)
        #expect(room.environment.activationCalls.isEmpty)
        #expect(room.environment.commandVCalls == 0)
        #expect(room.coordinator.retainedTranscriptText == "Hello")
    }

    // MARK: - ACC-02: external clipboard mutation wins

    @Test("A clipboard change by another process during the bounded wait skips restoration")
    func externalMutationSkipsRestoration() async {
        let room = makeRoom()
        room.environment.nextCapturedTarget = makeTarget(pid: 100, editable: false)
        room.wait.setOnWait { room.environment.mutateClipboardExternally("user typed elsewhere") }
        #expect(room.coordinator.captureInsertionTarget())

        #expect(await room.coordinator.requestInsertion(from: .succeeded(finalTranscript: "Fallback text", refinedText: nil)))

        #expect(room.coordinator.state == .succeeded)
        #expect(room.coordinator.lastRestoreOutcome == .skippedExternalMutation)
        #expect(room.environment.restoreCallCount == 0)
        #expect(room.environment.clipboardText == "user typed elsewhere")
        #expect(room.environment.events.last == "changeCount:43")
    }

    // MARK: - Step 8: activation failures stop before the key event

    @Test("Activation failure stops before the synthetic key event and restores the clipboard")
    func activationFailureStopsBeforeKeyEvent() async {
        let room = makeRoom()
        room.environment.nextCapturedTarget = makeTarget(pid: 100, editable: false)
        room.environment.activationSucceeds = false
        #expect(room.coordinator.captureInsertionTarget())

        #expect(await room.coordinator.requestInsertion(from: .succeeded(finalTranscript: "Fallback text", refinedText: nil)) == false)

        #expect(room.coordinator.lastFailure?.category == .activationFailed)
        #expect(room.environment.commandVCalls == 0)
        #expect(room.wait.intervals.isEmpty)
        #expect(room.environment.restoreCallCount == 1)
        #expect(room.coordinator.lastRestoreOutcome == .restored)
        #expect(room.environment.clipboardText == "original clipboard")
        #expect(room.coordinator.retainedTranscriptText == "Fallback text")
    }

    @Test("A failed frontmost verification after activation stops before the synthetic key event")
    func frontmostVerificationFailureStopsBeforeKeyEvent() async {
        let room = makeRoom()
        room.environment.nextCapturedTarget = makeTarget(pid: 100, editable: false)
        room.environment.frontmostAfterActivation = false
        #expect(room.coordinator.captureInsertionTarget())

        #expect(await room.coordinator.requestInsertion(from: .succeeded(finalTranscript: "Fallback text", refinedText: nil)) == false)

        #expect(room.coordinator.lastFailure?.category == .activationFailed)
        #expect(room.environment.activationCalls == [100])
        #expect(room.environment.commandVCalls == 0)
        #expect(room.environment.restoreCallCount == 1)
        #expect(room.coordinator.retainedTranscriptText == "Fallback text")
    }

    // MARK: - Step 9 + 13: synthetic paste failure

    @Test("Synthetic Command-V failure restores the clipboard and preserves the transcript")
    func syntheticPasteFailurePreservesTheTranscript() async {
        let room = makeRoom()
        room.environment.nextCapturedTarget = makeTarget(pid: 100, editable: false)
        room.environment.commandVSucceeds = false
        #expect(room.coordinator.captureInsertionTarget())

        #expect(await room.coordinator.requestInsertion(from: .succeeded(finalTranscript: "Fallback text", refinedText: nil)) == false)

        #expect(room.coordinator.lastFailure?.category == .syntheticPasteFailed)
        #expect(room.environment.commandVCalls == 1)
        #expect(room.wait.intervals.isEmpty)
        #expect(room.environment.restoreCallCount == 1)
        #expect(room.environment.clipboardText == "original clipboard")
        #expect(room.coordinator.retainedTranscriptText == "Fallback text")
        #expect(room.coordinator.availableRecoveryActions == [.copy, .preview, .retry])
    }

    // MARK: - Step 13: restoration failure

    @Test("A failed restoration is reported with its exact category and keeps the transcript")
    func restorationFailureIsReported() async {
        let room = makeRoom()
        room.environment.nextCapturedTarget = makeTarget(pid: 100, editable: false)
        room.environment.restoreSucceeds = false
        #expect(room.coordinator.captureInsertionTarget())

        #expect(await room.coordinator.requestInsertion(from: .succeeded(finalTranscript: "Fallback text", refinedText: nil)) == false)

        #expect(room.coordinator.lastFailure?.category == .restorationFailed)
        #expect(room.coordinator.lastRestoreOutcome == .failed)
        #expect(room.coordinator.retainedTranscriptText == "Fallback text")
    }

    // MARK: - Step 15: copy-only mode

    @Test("Copy-only mode leaves the complete transcript on the clipboard without a snapshot, a key event, or a restoration")
    func copyOnlyLeavesTranscriptOnClipboard() async {
        let room = makeRoom()
        room.environment.nextCapturedTarget = makeTarget(pid: 100)
        room.permissions.accessibility = .denied
        room.coordinator.configure(mode: .copyOnly)
        #expect(room.coordinator.captureInsertionTarget())

        #expect(await room.coordinator.requestInsertion(from: .succeeded(finalTranscript: "Copy me", refinedText: nil)))

        #expect(room.coordinator.state == .succeeded)
        #expect(room.coordinator.lastInsertionPath == .copyOnly)
        #expect(room.environment.writes == ["Copy me"])
        #expect(room.environment.clipboardText == "Copy me")
        #expect(room.environment.snapshotCallCount == 0)
        #expect(room.environment.restoreCallCount == 0)
        #expect(room.environment.activationCalls.isEmpty)
        #expect(room.environment.commandVCalls == 0)
        #expect(room.environment.changeCountReads == 0)
        // Copy-only needs no Accessibility work at all.
        #expect(room.trust.calls == 0)
        #expect(room.environment.directInsertions.isEmpty)
    }

    // MARK: - Step 14: preview mode

    @Test("Preview mode inserts nothing before explicit approval")
    func previewModeWaitsForExplicitApproval() async {
        let room = makeRoom()
        room.environment.nextCapturedTarget = makeTarget(pid: 100)
        room.coordinator.configure(mode: .preview)
        #expect(room.coordinator.captureInsertionTarget())

        #expect(await room.coordinator.requestInsertion(from: .succeeded(finalTranscript: "Preview text", refinedText: nil)))

        #expect(room.coordinator.isAwaitingPreviewApproval)
        #expect(room.coordinator.pendingPreviewText == "Preview text")
        #expect(room.coordinator.retainedTranscriptText == "Preview text")
        #expect(room.environment.directInsertions.isEmpty)
        #expect(room.environment.writes.isEmpty)
        #expect(room.environment.commandVCalls == 0)
        #expect(room.environment.snapshotCallCount == 0)
    }

    @Test("Preview approval runs the deterministic insertion workflow")
    func previewApprovalRunsTheWorkflow() async {
        let room = makeRoom()
        room.environment.nextCapturedTarget = makeTarget(pid: 100)
        room.coordinator.configure(mode: .preview)
        #expect(room.coordinator.captureInsertionTarget())
        #expect(await room.coordinator.requestInsertion(from: .succeeded(finalTranscript: "Preview text", refinedText: nil)))

        #expect(await room.coordinator.approvePreview())

        #expect(room.coordinator.state == .succeeded)
        #expect(room.coordinator.isAwaitingPreviewApproval == false)
        #expect(room.coordinator.pendingPreviewText == nil)
        #expect(room.environment.directInsertions == [DirectInsertion(text: "Preview text", processIdentifier: 100)])
    }

    @Test("Preview cancellation inserts nothing and preserves the completed transcript")
    func previewCancellationInsertsNothing() async {
        let room = makeRoom()
        room.environment.nextCapturedTarget = makeTarget(pid: 100)
        room.coordinator.configure(mode: .preview)
        #expect(room.coordinator.captureInsertionTarget())
        #expect(await room.coordinator.requestInsertion(from: .succeeded(finalTranscript: "Preview text", refinedText: nil)))

        #expect(room.coordinator.cancelPreview())

        #expect(room.coordinator.state == .cancelled)
        #expect(room.coordinator.isAwaitingPreviewApproval == false)
        #expect(room.coordinator.pendingPreviewText == nil)
        #expect(room.coordinator.retainedTranscriptText == "Preview text")
        #expect(room.environment.directInsertions.isEmpty)
        #expect(room.environment.writes.isEmpty)
        #expect(room.environment.commandVCalls == 0)
    }

    // MARK: - Step 2: candidate selection

    @Test("Candidate selection prefers the accepted refined text and never returns a blank candidate")
    func candidateSelectionRules() {
        let refined = PasteCoordinator.insertionCandidate(
            finalTranscript: "raw text",
            refinedText: "refined text"
        )
        #expect(refined?.text == "refined text")
        #expect(refined?.source == .refinedText)

        let raw = PasteCoordinator.insertionCandidate(finalTranscript: "raw text", refinedText: nil)
        #expect(raw?.text == "raw text")
        #expect(raw?.source == .finalTranscript)

        #expect(PasteCoordinator.insertionCandidate(finalTranscript: "  \n", refinedText: nil) == nil)
        #expect(PasteCoordinator.insertionCandidate(finalTranscript: "", refinedText: "") == nil)
    }

    @Test("Refined text is inserted when refinement succeeded and the final raw transcript otherwise")
    func refinedTextWinsOnlyWhenRefinementSucceeded() async {
        let room = makeRoom()
        room.environment.nextCapturedTarget = makeTarget(pid: 100)
        #expect(room.coordinator.captureInsertionTarget())

        #expect(await room.coordinator.requestInsertion(
            from: .succeeded(finalTranscript: "raw text", refinedText: "refined text")
        ))
        #expect(room.environment.directInsertions.last == DirectInsertion(text: "refined text", processIdentifier: 100))

        #expect(await room.coordinator.requestInsertion(
            from: .succeeded(finalTranscript: "raw text", refinedText: nil)
        ))
        #expect(room.environment.directInsertions.last == DirectInsertion(text: "raw text", processIdentifier: 100))
        #expect(room.environment.directInsertions.count == 2)
    }

    // MARK: - Step 3 + ACC-08: never insert partial, empty, failed, cancelled text

    @Test("Empty and blank completions are rejected without any native interaction")
    func emptyCompletionsAreRejected() async {
        let room = makeRoom()
        room.environment.nextCapturedTarget = makeTarget(pid: 100)
        #expect(room.coordinator.captureInsertionTarget())

        #expect(await room.coordinator.requestInsertion(from: .succeeded(finalTranscript: "", refinedText: nil)) == false)
        #expect(room.coordinator.lastFailure?.category == .emptyOrIncompleteText)

        #expect(await room.coordinator.requestInsertion(from: .succeeded(finalTranscript: "  \n", refinedText: nil)) == false)
        #expect(room.coordinator.lastFailure?.category == .emptyOrIncompleteText)

        // A blank refined result is never replaced by a second candidate.
        #expect(await room.coordinator.requestInsertion(from: .succeeded(finalTranscript: "raw text", refinedText: "")) == false)
        #expect(room.coordinator.lastFailure?.category == .emptyOrIncompleteText)

        #expect(room.environment.directInsertions.isEmpty)
        #expect(room.environment.writes.isEmpty)
        #expect(room.environment.commandVCalls == 0)
        #expect(room.coordinator.retainedTranscriptText == nil)
    }

    @Test("Partial and failed finalizations are never inserted")
    func partialAndFailedFinalizationsAreNeverInserted() async {
        let room = makeRoom()
        room.environment.nextCapturedTarget = makeTarget(pid: 100)
        #expect(room.coordinator.captureInsertionTarget())

        #expect(await room.coordinator.requestInsertion(from: .partial(text: "half a sentence")) == false)
        #expect(room.coordinator.lastFailure?.category == .rejectedResult)

        #expect(await room.coordinator.requestInsertion(from: .failed) == false)
        #expect(room.coordinator.lastFailure?.category == .rejectedResult)

        #expect(room.environment.directInsertions.isEmpty)
        #expect(room.environment.writes.isEmpty)
        #expect(room.coordinator.retainedTranscriptText == nil)
    }

    @Test("A cancelled finalization inserts nothing and changes no native state")
    func cancelledFinalizationInsertsNothing() async {
        let room = makeRoom()
        room.environment.nextCapturedTarget = makeTarget(pid: 100)
        #expect(room.coordinator.captureInsertionTarget())

        #expect(await room.coordinator.requestInsertion(from: .cancelled) == false)

        #expect(room.coordinator.state == .cancelled)
        #expect(room.environment.directInsertions.isEmpty)
        #expect(room.environment.writes.isEmpty)
        #expect(room.environment.commandVCalls == 0)
        #expect(room.environment.restoreCallCount == 0)
    }

    // MARK: - Recovery: fresh target retry and explicit copy

    @Test("An explicit retry captures a fresh target instead of reusing the stale element")
    func retryCapturesAFreshTarget() async {
        let room = makeRoom()
        room.environment.nextCapturedTarget = makeTarget(pid: 100)
        room.environment.targetStillValid = false
        #expect(room.coordinator.captureInsertionTarget())
        #expect(await room.coordinator.requestInsertion(from: .succeeded(finalTranscript: "Retry me", refinedText: nil)) == false)
        #expect(room.coordinator.lastFailure?.category == .targetNoLongerAvailable)

        // Recovery state: a fresh target is available now.
        room.environment.targetStillValid = true
        room.environment.nextCapturedTarget = makeTarget(pid: 777)

        #expect(await room.coordinator.retryInsertion())

        #expect(room.coordinator.state == .succeeded)
        #expect(room.environment.captureCallCount == 2)
        #expect(room.environment.directInsertions == [DirectInsertion(text: "Retry me", processIdentifier: 777)])
    }

    @Test("The copy recovery action writes the retained transcript only on explicit action")
    func copyRecoveryActionIsExplicit() async {
        let room = makeRoom()
        room.environment.nextCapturedTarget = makeTarget(pid: 100)
        room.environment.targetStillValid = false
        #expect(room.coordinator.captureInsertionTarget())
        #expect(await room.coordinator.requestInsertion(from: .succeeded(finalTranscript: "Retry me", refinedText: nil)) == false)

        #expect(room.environment.writes.isEmpty)

        #expect(room.coordinator.copyRetainedTranscript())

        #expect(room.environment.writes == ["Retry me"])
        #expect(room.environment.clipboardText == "Retry me")
        // An explicit copy is one complete intentional overwrite; nothing is restored.
        #expect(room.environment.snapshotCallCount == 0)
        #expect(room.environment.restoreCallCount == 0)
        #expect(room.coordinator.retainedTranscriptText == "Retry me")
    }

    // MARK: - Termination

    @Test("Termination releases the captured target and any pending insertion state")
    func terminationReleasesInsertionState() async {
        let room = makeRoom()
        room.environment.nextCapturedTarget = makeTarget(pid: 100)
        room.coordinator.configure(mode: .preview)
        #expect(room.coordinator.captureInsertionTarget())
        #expect(await room.coordinator.requestInsertion(from: .succeeded(finalTranscript: "Preview text", refinedText: nil)))
        #expect(room.coordinator.isAwaitingPreviewApproval)

        await room.coordinator.releaseForTermination()

        #expect(room.coordinator.capturedTarget == nil)
        #expect(room.coordinator.pendingPreviewText == nil)
        #expect(room.coordinator.retainedTranscriptText == nil)
        #expect(room.coordinator.state == .idle)
    }
}
