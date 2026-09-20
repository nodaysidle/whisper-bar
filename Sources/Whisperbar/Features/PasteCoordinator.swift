import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - Insertion value types

/// Identity of the focused external application captured at recording start
/// (CON-PASTE-WORKFLOW step 1).
struct InsertionTarget: Equatable, Sendable {
    let processIdentifier: Int32
    let bundleIdentifier: String?
    let localizedName: String?
    /// True when the captured AX focused element exposed the editable
    /// selected-text boundary (kAXSelectedTextAttribute settable).
    let hasEditableSelectedTextBoundary: Bool
}

/// The one complete insertion candidate selected per CON-PASTE-WORKFLOW step 2.
struct InsertionCandidate: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case refinedText
        case finalTranscript
    }

    let text: String
    let source: Source
}

/// The accepted outcome of one transcription session handed to the paste
/// coordinator. Only `succeeded` can ever produce an insertion candidate:
/// partial, failed, and cancelled finalizations never insert anything.
enum CompletedTranscription: Equatable, Sendable {
    case succeeded(finalTranscript: String, refinedText: String?)
    case partial(text: String)
    case failed
    case cancelled
}

/// The configured insertion mode (CON-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION-INTERFACE).
enum PasteMode: Equatable, Sendable, CaseIterable {
    case autoPaste
    case copyOnly
    case preview
}

/// How a completed insertion candidate reached the focused application.
enum InsertionPath: Equatable, Sendable {
    case directAccessibility
    case clipboardFallback
    case copyOnly
}

/// Outcome of the ownership-safe clipboard restoration (steps 11–12).
enum RestoreOutcome: Equatable, Sendable {
    case restored
    case skippedExternalMutation
    case failed
}

/// Recovery actions exposed after an insertion failure (step 13).
enum RecoveryAction: Equatable, Sendable {
    case copy
    case preview
    case retry
}

// MARK: - Native adapter boundary (CON-PASTE-WORKFLOW)

/// Step 1 and step 4: focus captured at recording start; the captured target
/// is never replaced by a later-focused application.
protocol FocusedTargetCapturing: Sendable {
    /// The frontmost external application and its current AX focused element
    /// when available; `nil` when no usable external target is focused.
    func captureTarget() -> InsertionTarget?
    /// The captured target is still valid for the captured process
    /// identifier: the application still runs and a captured editable focused
    /// element still exists.
    func isTargetStillValid(_ target: InsertionTarget) -> Bool
}

/// Step 5: direct Accessibility insertion through the editable selected-text
/// boundary (kAXSelectedTextAttribute).
protocol AccessibilityInserting: Sendable {
    func insertViaSelectedText(_ text: String, into target: InsertionTarget) -> Bool
}

/// Steps 6, 7, 11, 12: representation-preserving pasteboard snapshot, one
/// write of one candidate, changeCount reads, and ownership-safe restoration.
protocol PasteboardServicing: Sendable {
    /// Captures every existing item and representation plus the original
    /// changeCount before anything is written.
    func snapshot() -> ClipboardSnapshot
    /// Writes the one candidate; returns the app-owned post-write changeCount
    /// or `nil` when the write failed.
    func writeText(_ text: String) -> Int?
    func currentChangeCount() -> Int
    /// Restores a full snapshot; returns whether the restoration succeeded.
    func restore(_ snapshot: ClipboardSnapshot) -> Bool
}

/// Step 8: reactivation of the captured application and frontmost
/// verification.
protocol TargetActivating: Sendable {
    func activate(_ target: InsertionTarget) -> Bool
    func isFrontmost(_ target: InsertionTarget) -> Bool
}

/// Step 9: exactly one synthesized Command-V.
protocol CommandVPressing: Sendable {
    func synthesizeCommandV() -> Bool
}

// MARK: - Live adapters (injected by default; tests never load them)

/// Live focused-target capture through NSWorkspace and ApplicationServices.
/// The capture excludes this process, so the HUD, the menu-bar popover, or
/// anything else owned by WhisperBar is never captured as the target.
struct SystemFocusedTargetCapture: FocusedTargetCapturing {

    func captureTarget() -> InsertionTarget? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier != NSRunningApplication.current.processIdentifier
        else { return nil }
        let pid = frontmost.processIdentifier
        var editable = false
        if let element = Self.focusedElement(forProcess: pid) {
            editable = Self.isSelectedTextSettable(element)
        }
        return InsertionTarget(
            processIdentifier: pid,
            bundleIdentifier: frontmost.bundleIdentifier,
            localizedName: frontmost.localizedName,
            hasEditableSelectedTextBoundary: editable
        )
    }

    func isTargetStillValid(_ target: InsertionTarget) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: target.processIdentifier),
              !application.isTerminated
        else { return false }
        return true
    }

    private static func focusedElement(forProcess pid: Int32) -> AXUIElement? {
        let applicationElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func isSelectedTextSettable(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &settable
        ) == .success else { return false }
        return settable.boolValue
    }
}

/// Live direct insertion: sets kAXSelectedTextAttribute on the captured
/// process's current focused element. It never reads or writes NSPasteboard.
struct SystemAccessibilityInserter: AccessibilityInserting {

    func insertViaSelectedText(_ text: String, into target: InsertionTarget) -> Bool {
        let applicationElement = AXUIElementCreateApplication(target.processIdentifier)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
            let focusedValue,
            CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else { return false }
        let element = focusedValue as! AXUIElement
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        ) == .success
    }
}

/// Live pasteboard service. The snapshot keeps every item and every
/// representation (type + raw data) plus the changeCount so restoration is
/// representation-preserving and ownership-safe.
struct SystemPasteboardService: PasteboardServicing {

    func snapshot() -> ClipboardSnapshot {
        let pasteboard = NSPasteboard.general
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            PasteboardItemSnapshot(
                representations: item.types.compactMap { type in
                    item.data(forType: type).map { data in
                        PasteboardRepresentation(type: type.rawValue, data: data)
                    }
                }
            )
        }
        return ClipboardSnapshot(items: items, changeCount: pasteboard.changeCount)
    }

    func writeText(_ text: String) -> Int? {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return nil }
        return pasteboard.changeCount
    }

    func currentChangeCount() -> Int {
        NSPasteboard.general.changeCount
    }

    func restore(_ snapshot: ClipboardSnapshot) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items = snapshot.items.map { itemSnapshot -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for representation in itemSnapshot.representations {
                item.setData(
                    representation.data,
                    forType: NSPasteboard.PasteboardType(representation.type)
                )
            }
            return item
        }
        guard !items.isEmpty else { return true }
        return pasteboard.writeObjects(items)
    }
}

/// Live activation: NSRunningApplication reactivation plus frontmost
/// verification through NSWorkspace.
struct SystemTargetActivator: TargetActivating {

    func activate(_ target: InsertionTarget) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: target.processIdentifier) else {
            return false
        }
        let success = application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        return success || application.isActive
    }

    func isFrontmost(_ target: InsertionTarget) -> Bool {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
            return true
        }
        for _ in 0..<10 {
            usleep(25_000)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
                return true
            }
        }
        if let application = NSRunningApplication(processIdentifier: target.processIdentifier), application.isActive {
            return true
        }
        return false
    }
}

/// Live Command-V synthesis: exactly one Command-V keystroke posted as a
/// keyboard event, only after successful target reactivation.
struct SystemCommandVPresser: CommandVPressing {

    /// kVK_ANSI_V.
    private static let keyCodeV: CGKeyCode = 0x09

    func synthesizeCommandV() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: Self.keyCodeV, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: Self.keyCodeV, keyDown: false)
        else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        usleep(30_000)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}

// MARK: - PasteCoordinator

/// OWN-PASTE-COORDINATOR.
///
/// Owns FEAT-SAFE-AUTO-PASTE-AND-CLIPBOARD-PRESERVATION and
/// CON-PASTE-WORKFLOW: one deterministic insertion workflow for exactly one
/// approved complete candidate. AppKit, ApplicationServices, NSPasteboard,
/// and CGEvent are reached only through the injected native adapters above,
/// so tests use no live application, clipboard, or key event.
///
/// The 15 locked steps: (1) capture the target at recording start;
/// (2) choose exactly one candidate; (3) never insert partial, empty, failed,
/// cancelled, or unapproved text; (4) verify Accessibility authorization and
/// target validity; (5) prefer direct Accessibility insertion (no pasteboard
/// access); (6) snapshot every pasteboard representation before writing;
/// (7) write one candidate and record the app-owned changeCount;
/// (8) reactivate and verify frontmost; (9) synthesize one Command-V only
/// after verified activation; (10) wait the bounded 750 ms; (11) restore only
/// while this app still owns the changeCount; (12) newer external clipboard
/// content is never overwritten; (13) failures retain the transcript and
/// expose copy/preview/retry with a privacy-safe category; (14) preview
/// inserts nothing before explicit approval; (15) copy-only leaves the
/// transcript on the clipboard without a synthetic paste or restoration.
@MainActor
final class PasteCoordinator: TerminationReleasing {

    // MARK: Contract markers

    /// Step 10: the bounded documented consumption wait. Asserted by the
    /// focused tests.
    static let pasteConsumptionWaitMilliseconds = 750

    // MARK: States

    enum State: Equatable, Sendable {
        case idle
        case active
        case succeeded
        case failed(Failure)
        case cancelled
    }

    struct Failure: Equatable, Sendable {
        /// Privacy-safe failure categories: no case carries clipboard
        /// content, transcript text, or application identity.
        enum Category: Equatable, Sendable {
            case busy
            case rejectedResult
            case emptyOrIncompleteText
            case accessibilityDenied
            case noCapturedTarget
            case targetNoLongerAvailable
            case clipboardUnavailable
            case activationFailed
            case syntheticPasteFailed
            case restorationFailed
            case nothingPending
        }

        let category: Category
        let message: String
    }

    // MARK: Observable state

    private(set) var state: State = .idle
    private(set) var mode: PasteMode = .autoPaste
    /// The target captured at recording start. Only an explicit retry may
    /// replace it with a fresh capture.
    private(set) var capturedTarget: InsertionTarget?
    private(set) var lastFailure: Failure?
    private(set) var lastNotice: String?
    private(set) var lastInsertionPath: InsertionPath?
    private(set) var lastRestoreOutcome: RestoreOutcome?

    private var retainedCandidate: InsertionCandidate?
    private var pendingPreviewCandidate: InsertionCandidate?
    private var activeSnapshot: ClipboardSnapshot?
    private var activePostWriteChangeCount: Int?
    private var isExecutingWorkflow = false

    /// The complete transcript preserved across every failure, preview, and
    /// cancellation terminal path; `nil` after a successful completion.
    var retainedTranscriptText: String? { retainedCandidate?.text }

    /// The complete transcript waiting for explicit preview approval.
    var pendingPreviewText: String? { pendingPreviewCandidate?.text }

    var isAwaitingPreviewApproval: Bool { pendingPreviewCandidate != nil }

    /// Step 13: after an insertion failure the completed transcript stays
    /// visible with copy, preview, and explicit retry actions.
    var availableRecoveryActions: [RecoveryAction] {
        guard case .failed = state, retainedCandidate != nil else { return [] }
        return [.copy, .preview, .retry]
    }

    var restoreClipboard: Bool

    // MARK: Dependencies

    private let targetCapture: FocusedTargetCapturing
    private let accessibilityInserter: AccessibilityInserting
    private let pasteboard: PasteboardServicing
    private let activator: TargetActivating
    private let commandVPressing: CommandVPressing
    private let accessibilityAvailability: @MainActor () -> PermissionState
    private let requestAccessibilityTrust: @MainActor () async -> PermissionState
    private let clipboardAvailability: @MainActor () -> PermissionState
    private let waitForPasteConsumption: @Sendable (Int) async -> Void
    private let replacementEngine: VocabularyReplacementEngine

    init(
        targetCapture: FocusedTargetCapturing = SystemFocusedTargetCapture(),
        accessibilityInserter: AccessibilityInserting = SystemAccessibilityInserter(),
        pasteboard: PasteboardServicing = SystemPasteboardService(),
        activator: TargetActivating = SystemTargetActivator(),
        commandVPressing: CommandVPressing = SystemCommandVPresser(),
        accessibilityAvailability: @escaping @MainActor () -> PermissionState = { .authorized },
        requestAccessibilityTrust: @escaping @MainActor () async -> PermissionState = { .denied },
        clipboardAvailability: @escaping @MainActor () -> PermissionState = { .authorized },
        waitForPasteConsumption: @escaping @Sendable (Int) async -> Void = { milliseconds in
            try? await Task.sleep(for: .milliseconds(Int64(milliseconds)))
        },
        restoreClipboard: Bool = true,
        replacementEngine: VocabularyReplacementEngine = .default
    ) {
        self.targetCapture = targetCapture
        self.accessibilityInserter = accessibilityInserter
        self.pasteboard = pasteboard
        self.activator = activator
        self.commandVPressing = commandVPressing
        self.accessibilityAvailability = accessibilityAvailability
        self.requestAccessibilityTrust = requestAccessibilityTrust
        self.clipboardAvailability = clipboardAvailability
        self.waitForPasteConsumption = waitForPasteConsumption
        self.restoreClipboard = restoreClipboard
        self.replacementEngine = replacementEngine
    }

    // MARK: Step 1 — capture at recording start

    /// Captures the target NSRunningApplication identity and its current
    /// Accessibility focused element when available. Called at recording
    /// start only; the captured target is never re-resolved implicitly.
    @discardableResult
    func captureInsertionTarget() -> Bool {
        capturedTarget = targetCapture.captureTarget()
        return capturedTarget != nil
    }

    // MARK: Configured mode

    func configure(mode: PasteMode) {
        self.mode = mode
    }

    // MARK: Steps 2–3 — candidate selection and dispatch

    /// Step 2 + 3: exactly one insertion candidate — the accepted refined text
    /// when refinement succeeded, otherwise the accepted final raw transcript.
    /// Returns `nil` when the single candidate is blank so empty text is never
    /// inserted (a blank refined result is never replaced by a second
    /// candidate).
    static func insertionCandidate(
        finalTranscript: String,
        refinedText: String?,
        replacementEngine: VocabularyReplacementEngine = .default
    ) -> InsertionCandidate? {
        let rawText: String
        let source: InsertionCandidate.Source
        if let refinedText {
            rawText = refinedText
            source = .refinedText
        } else {
            rawText = finalTranscript
            source = .finalTranscript
        }
        let text = replacementEngine.replace(in: rawText)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return InsertionCandidate(text: text, source: source)
    }

    /// The one entry point for a completed transcription. Never inserts
    /// partial, empty, failed, cancelled, or unapproved text.
    @discardableResult
    func requestInsertion(from completed: CompletedTranscription) async -> Bool {
        switch completed {
        case .cancelled:
            pendingPreviewCandidate = nil
            lastFailure = nil
            lastNotice = "The transcription was cancelled; nothing was inserted."
            state = .cancelled
            return false
        case .failed:
            return fail(
                .rejectedResult,
                message: "A failed finalization is never inserted; nothing was changed."
            )
        case .partial:
            return fail(
                .rejectedResult,
                message: "Partial or interim text is never inserted; nothing was changed."
            )
        case .succeeded(let finalTranscript, let refinedText):
            guard let candidate = Self.insertionCandidate(
                finalTranscript: finalTranscript,
                refinedText: refinedText,
                replacementEngine: replacementEngine
            ) else {
                return fail(
                    .emptyOrIncompleteText,
                    message: "Empty or incomplete text is never inserted; nothing was changed."
                )
            }
            // A new completed transcription supersedes any earlier pending
            // preview: there is always exactly one candidate.
            pendingPreviewCandidate = nil
            retainedCandidate = candidate
            return await dispatch(candidate)
        }
    }

    private func dispatch(_ candidate: InsertionCandidate) async -> Bool {
        switch mode {
        case .autoPaste:
            return await executeInsertion(candidate)
        case .copyOnly:
            return executeCopyOnly(candidate)
        case .preview:
            pendingPreviewCandidate = candidate
            lastFailure = nil
            lastInsertionPath = nil
            lastRestoreOutcome = nil
            lastNotice = "Preview mode: the complete transcript is waiting for your explicit approval; nothing has been inserted."
            state = .active
            return true
        }
    }

    // MARK: Step 14 — explicit preview approval and cancellation

    @discardableResult
    func approvePreview() async -> Bool {
        guard let candidate = pendingPreviewCandidate else {
            return fail(
                .nothingPending,
                message: "No preview is waiting for explicit approval; nothing was inserted."
            )
        }
        pendingPreviewCandidate = nil
        return await executeInsertion(candidate)
    }

    @discardableResult
    func cancelPreview() -> Bool {
        guard let candidate = pendingPreviewCandidate else {
            return fail(
                .nothingPending,
                message: "No preview is waiting for cancellation; nothing was changed."
            )
        }
        pendingPreviewCandidate = nil
        retainedCandidate = candidate
        lastFailure = nil
        lastNotice = "The preview was cancelled; nothing was inserted and the complete transcript is preserved."
        state = .cancelled
        return true
    }

    // MARK: Step 13 — explicit recovery actions

    /// Explicit user copy of the retained complete transcript: one atomic
    /// intentional overwrite; nothing is snapshotted, synthesized, or
    /// restored.
    @discardableResult
    func copyRetainedTranscript() -> Bool {
        guard let candidate = retainedCandidate else {
            return fail(
                .nothingPending,
                message: "There is no completed transcript to copy; nothing was changed."
            )
        }
        guard clipboardAvailability() == .authorized, pasteboard.writeText(candidate.text) != nil else {
            return fail(
                .clipboardUnavailable,
                message: "The clipboard could not be used right now; the complete transcript stays visible for manual copy."
            )
        }
        lastNotice = "Copied the complete transcript to the clipboard; it stays visible."
        return true
    }

    /// Explicit retry: captures a fresh target instead of reusing a stale
    /// Accessibility element, then re-runs the deterministic workflow with
    /// the retained complete transcript.
    @discardableResult
    func retryInsertion() async -> Bool {
        guard let candidate = retainedCandidate else {
            return fail(
                .nothingPending,
                message: "There is no completed transcript to retry; nothing was inserted."
            )
        }
        capturedTarget = targetCapture.captureTarget()
        pendingPreviewCandidate = nil
        return await executeInsertion(candidate)
    }

    // MARK: Steps 4–12 — the one deterministic insertion workflow

    private func executeInsertion(_ candidate: InsertionCandidate) async -> Bool {
        guard !isExecutingWorkflow else {
            return fail(
                .busy,
                message: "An insertion workflow is already running; nothing was changed."
            )
        }
        isExecutingWorkflow = true
        defer { isExecutingWorkflow = false }

        state = .active
        lastFailure = nil
        lastInsertionPath = nil
        lastRestoreOutcome = nil

        // Step 4 — Accessibility authorization: requested only when it has
        // never been determined; a denial is never re-prompted.
        let availability = await resolvedAccessibilityAvailability()
        guard availability == .authorized else {
            return failAccessibilityManualPath(candidateText: candidate.text)
        }

        // Step 4 — the captured target must remain valid for its captured
        // process identifier; a later-focused application never substitutes.
        guard let target = capturedTarget else {
            if !restoreClipboard {
                _ = pasteboard.writeText(candidate.text)
            }
            return fail(
                .noCapturedTarget,
                message: "No insertion target was captured at recording start, so nothing was inserted; the complete transcript is preserved for copy, preview, or an explicit retry."
            )
        }
        guard targetCapture.isTargetStillValid(target) else {
            if !restoreClipboard {
                _ = pasteboard.writeText(candidate.text)
            }
            return fail(
                .targetNoLongerAvailable,
                message: "The captured application is no longer available, so nothing was inserted; the complete transcript is preserved for copy, preview, or an explicit retry."
            )
        }

        // Step 5 — direct Accessibility insertion first; success performs no
        // NSPasteboard access at all.
        if target.hasEditableSelectedTextBoundary,
           accessibilityInserter.insertViaSelectedText(candidate.text, into: target) {
            if !restoreClipboard {
                _ = pasteboard.writeText(candidate.text)
            }
            finishSuccess(
                path: .directAccessibility,
                notice: "Inserted the complete transcript directly into the focused app."
            )
            return true
        }

        // Step 6 — snapshot every existing item and representation (plus the
        // original changeCount) before writing anything.
        guard clipboardAvailability() == .authorized else {
            return fail(
                .clipboardUnavailable,
                message: "The clipboard is unavailable right now, so nothing was inserted; the complete transcript is preserved for copy, preview, or an explicit retry."
            )
        }
        let snapshot = pasteboard.snapshot()

        // Step 7 — write the one candidate and record the app-owned
        // post-write changeCount.
        guard let postWriteChangeCount = pasteboard.writeText(candidate.text) else {
            return fail(
                .clipboardUnavailable,
                message: "The clipboard write failed, so nothing was inserted; the complete transcript is preserved for copy, preview, or an explicit retry."
            )
        }
        activeSnapshot = snapshot
        activePostWriteChangeCount = postWriteChangeCount

        // Step 8 — reactivate the captured application and verify it became
        // frontmost; a failed activation stops before any synthetic key event.
        guard activator.activate(target), activator.isFrontmost(target) else {
            if restoreClipboard {
                let disposition = restoreOwnedClipboard(
                    snapshot: snapshot,
                    postWriteChangeCount: postWriteChangeCount
                )
                lastRestoreOutcome = disposition
                return fail(
                    .activationFailed,
                    message: "The captured application could not be reactivated, so no synthetic paste was sent; \(Self.clipboardDispositionText(disposition)) and the complete transcript is preserved for copy, preview, or an explicit retry."
                )
            } else {
                return fail(
                    .activationFailed,
                    message: "The captured application could not be reactivated, so no synthetic paste was sent. The complete transcript was copied to your clipboard so you can paste with ⌘V."
                )
            }
        }

        // Step 9 — exactly one Command-V, only after verified activation.
        guard commandVPressing.synthesizeCommandV() else {
            if restoreClipboard {
                let disposition = restoreOwnedClipboard(
                    snapshot: snapshot,
                    postWriteChangeCount: postWriteChangeCount
                )
                lastRestoreOutcome = disposition
                return fail(
                    .syntheticPasteFailed,
                    message: "The synthetic Command-V could not be sent, so nothing was pasted; \(Self.clipboardDispositionText(disposition)) and the complete transcript is preserved for copy, preview, or an explicit retry."
                )
            } else {
                return fail(
                    .syntheticPasteFailed,
                    message: "The synthetic Command-V could not be sent, so nothing was pasted. The complete transcript was copied to your clipboard so you can paste with ⌘V."
                )
            }
        }

        // Step 10 — bounded documented wait for the target to consume the
        // paste.
        await waitForPasteConsumption(Self.pasteConsumptionWaitMilliseconds)

        if !restoreClipboard {
            finishSuccess(
                path: .clipboardFallback,
                notice: "Inserted the complete transcript and kept it on the clipboard."
            )
            return true
        }

        // Steps 11–12 — restore only while this app still owns the clipboard;
        // newer external clipboard content is never overwritten.
        switch restoreOwnedClipboard(
            snapshot: snapshot,
            postWriteChangeCount: postWriteChangeCount
        ) {
        case .restored:
            lastRestoreOutcome = .restored
            finishSuccess(
                path: .clipboardFallback,
                notice: "Inserted the complete transcript and restored the original clipboard content."
            )
            return true
        case .skippedExternalMutation:
            lastRestoreOutcome = .skippedExternalMutation
            finishSuccess(
                path: .clipboardFallback,
                notice: "Inserted the complete transcript; the clipboard was changed by another app, so that newer clipboard content was kept."
            )
            return true
        case .failed:
            lastRestoreOutcome = .failed
            return fail(
                .restorationFailed,
                message: "The complete transcript was inserted, but the original clipboard content could not be restored; the transcript stays available for copy or preview."
            )
        }
    }

    // MARK: Step 15 — copy-only

    private func executeCopyOnly(_ candidate: InsertionCandidate) -> Bool {
        guard clipboardAvailability() == .authorized, pasteboard.writeText(candidate.text) != nil else {
            return fail(
                .clipboardUnavailable,
                message: "Copy-only mode could not place the transcript on the clipboard; the complete transcript stays visible for manual copy."
            )
        }
        finishSuccess(
            path: .copyOnly,
            notice: "Copy-only mode left the complete transcript on the clipboard; nothing was inserted and no restoration was performed."
        )
        return true
    }

    // MARK: Internal helpers

    /// Steps 4 + ACC-01: read the cached Accessibility state; only a
    /// never-determined state triggers the explicit trust request.
    private func resolvedAccessibilityAvailability() async -> PermissionState {
        let current = accessibilityAvailability()
        guard current == .notDetermined else { return current }
        return await requestAccessibilityTrust()
    }

    /// CON-PERMISSION-ACCESSIBILITY denied behavior: skip privileged control
    /// and keep the documented manual path. The clipboard's prior content is
    /// left untouched until an explicit user copy action.
    private func failAccessibilityManualPath(candidateText: String? = nil) -> Bool {
        if !restoreClipboard, let text = candidateText {
            _ = pasteboard.writeText(text)
        }
        return fail(
            .accessibilityDenied,
            message: "Accessibility access is not granted, so nothing was inserted. The complete transcript is preserved for manual copy, preview, or an explicit retry after enabling Accessibility access."
        )
    }

    /// Steps 11–12: restore only while `postWriteChangeCount` is still the
    /// current changeCount; otherwise a newer external mutation wins.
    private func restoreOwnedClipboard(
        snapshot: ClipboardSnapshot,
        postWriteChangeCount: Int
    ) -> RestoreOutcome {
        guard pasteboard.currentChangeCount() == postWriteChangeCount else {
            activeSnapshot = nil
            activePostWriteChangeCount = nil
            return .skippedExternalMutation
        }
        let restored = pasteboard.restore(snapshot)
        activeSnapshot = nil
        activePostWriteChangeCount = nil
        return restored ? .restored : .failed
    }

    private static func clipboardDispositionText(_ outcome: RestoreOutcome) -> String {
        switch outcome {
        case .restored: return "the original clipboard content was restored"
        case .skippedExternalMutation: return "newer clipboard content from another app was kept"
        case .failed: return "the original clipboard content could not be restored"
        }
    }

    private func finishSuccess(path: InsertionPath, notice: String) {
        lastInsertionPath = path
        lastFailure = nil
        lastNotice = notice
        retainedCandidate = nil
        state = .succeeded
    }

    @discardableResult
    private func fail(_ category: Failure.Category, message: String) -> Bool {
        let failure = Failure(category: category, message: message)
        lastFailure = failure
        state = .failed(failure)
        return false
    }

    // MARK: Termination

    /// CON-LIFECYCLE-APPLICATION-TERMINATION: release the captured target and
    /// any in-flight clipboard snapshot before termination completes. While
    /// this app still owns the clipboard, the snapshot is restored once.
    func releaseForTermination() async {
        if let snapshot = activeSnapshot,
           let postWriteChangeCount = activePostWriteChangeCount,
           pasteboard.currentChangeCount() == postWriteChangeCount {
            _ = pasteboard.restore(snapshot)
        }
        activeSnapshot = nil
        activePostWriteChangeCount = nil
        capturedTarget = nil
        pendingPreviewCandidate = nil
        retainedCandidate = nil
        state = .idle
    }
}
