import AppKit
import Observation
import SwiftUI

// MARK: - Locked identity (TRD "Locked Identity")

/// Single source of truth for the locked identity values from TRD.md.
/// Contract tests fail on any drift.
enum AppIdentity {
    static let bundleIdentifier = "com.whisperbar.app"
    static let appName = "WhisperBar"
    static let executableName = "Whisperbar"
    static let artifactPath = "dist/WhisperBar.app"
    /// Runtime minimum-system identity: "14.0". The locked @Observable stack
    /// requires the macOS 14 SDK, and the packaged Info.plist plus the release
    /// binary deployment target are both 14.0 (Scripts/package_app.sh fails
    /// closed if they differ). NOTE — recorded deviation: the canonical
    /// packet still renders the TRD-locked LSMinimumSystemVersion literal
    /// 13.0; the canonical documents are not edited, and this runtime identity
    /// is the reconciled production value used by the manifest, the plist, the
    /// binary, and the contract tests.
    static let minimumSystemVersion = "14.0"
    static let shortVersion = "1.0.0"
    static let buildVersion = "1"
    static let packageType = "APPL"
    static let iconFile = "AppIcon"

    static let keychainService = "com.whisperbar.app.credentials"
    static let deepgramKeychainAccount = "deepgram-nova-streaming-transcription-api-key"
    static let openRouterKeychainAccount = "openrouter-api-key"
    static let typesafeKeychainAccount = "typesafe-api-key"

    static let databaseFileName = "voice.sqlite3"
    static let applicationSupportDirectoryName = "com.whisperbar.app"
    static let temporaryDirectoryName = "com.whisperbar.app"
}

// MARK: - App wiring

/// Main-actor hand-off between the SwiftUI App entry, the NSApplication
/// delegate adaptor, and the single MenuBarController.
@MainActor
enum AppWire {
    static var controller: MenuBarController?
}

// MARK: - Lifecycle delegate

/// Thin AppKit adaptor. It only forwards lifecycle notifications; all state
/// changes live in MenuBarController (and, from PHASE-04 on, LifecycleCoordinator).
@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    static weak var latest: AppLifecycleDelegate?

    override init() {
        super.init()
        AppLifecycleDelegate.latest = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppWire.controller?.applicationDidFinishLaunching()
        AppWire.controller?.openMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppWire.controller?.openMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        AppWire.controller?.buildDockMenu()
    }

    /// CON-LIFECYCLE-APPLICATION-TERMINATION, awaited: AppKit is told to wait
    /// (`.terminateLater`), the controller stops the active session and
    /// releases every registered resource through the lifecycle owner, and
    /// exactly one `reply(toApplicationShouldTerminate:)` follows. Answering
    /// `.terminateNow` would end the process before those releases ran.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppWire.controller?.isTerminationRequested == true else {
            return .terminateCancel
        }
        return requestAwaitedTermination { allow in
            sender.reply(toApplicationShouldTerminate: allow)
        }
    }

    /// The terminateLater/reply contract without a running application: the
    /// focused tests drive this directly, so the awaited ordering is provable
    /// and no test has to call into a live NSApplication.
    func requestAwaitedTermination(
        reply: @escaping @MainActor (Bool) -> Void
    ) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await AppWire.controller?.completeTermination()
            reply(true)
        }
        return .terminateLater
    }

    /// The awaited release already ran from `applicationShouldTerminate`;
    /// AppKit's later callback only records the terminal presentation state.
    func applicationWillTerminate(_ notification: Notification) {
        AppWire.controller?.applicationWillTerminate()
    }
}

// MARK: - Native save destination chooser (explicit save seam)

/// The production save-destination chooser of the explicit user save: one
/// native save panel whose suggested name is the recording's value-free
/// deterministic file name. It is only ever presented by the explicit save
/// action — construction and launch present nothing — and the composition
/// root injects a deterministic fake in tests, so no test opens a panel.
@MainActor
struct SystemSaveDestinationChooser {

    func chooseSaveDestination(
        suggestedFileName: String
    ) async -> TemporaryAudioCleanupFeature.SaveDestinationDecision {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFileName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else {
            // A cancelled selection changes nothing: the caller keeps the
            // recording and claims no removal.
            return .cancelled
        }
        return .chosen(url)
    }
}

// MARK: - MenuBarController (single presentation owner)

/// The one @Observable @MainActor presentation owner for menu, settings, HUD,
/// and feature state (ARD "Architectural Style"). Later phases attach real
/// owners here; nothing privileged (capture, network, prompts) happens in init.
@Observable
@MainActor
final class MenuBarController {

    // MARK: Presentation state

    var statusText: String = "Idle" {
        didSet {
            updateMenuBarIcon()
        }
    }
    var menuBarSystemImageName: String = "waveform"
    var lastErrorMessage: String?
    private(set) var didFinishLaunching = false
    var isTerminationRequested: Bool = false

    // MARK: Owner state (PHASE-02)

    /// OWN-CREDENTIAL-VAULT instance owned by the composition root.
    let credentialVault: CredentialVault

    /// Value-free credential status cache; populated only from explicit user
    /// actions, never at launch, and never containing secret material.
    private(set) var credentialStatuses: [CredentialKey: CredentialStatus] = [:]

    // MARK: Owner state (PHASE-03)

    /// OWN-DATA-STORE instance owned by the composition root.
    let dataStore: DataStore

    /// Value-free storage summary for settings presentation.
    private(set) var storageSummary: String = "Unknown"

    // MARK: Owner state (PHASE-04)

    /// OWN-LIFECYCLE-COORDINATOR instance owned by the composition root.
    let lifecycleCoordinator: LifecycleCoordinator

    // MARK: Owner state (PHASE-05)

    /// OWN-PERMISSION-COORDINATOR instance owned by the composition root.
    let permissionCoordinator: PermissionCoordinator

    // MARK: Owner state (PHASE-06)

    /// OWN-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES instance owned by the
    /// composition root. Registered as a termination resource so no shortcut
    /// outlives the process.
    let globalHotkeysFeature: GlobalHotkeysAndPushToTalkToggleModesFeature

    // MARK: Owner state (PHASE-07)

    /// OWN-INTEGRATION-DEEPGRAM-NOVA-STREAMING-TRANSCRIPTION instance owned by
    /// the composition root. Shares the composition root's CredentialVault so
    /// keys stay request-local and are never copied.
    let deepgramStreamingIntegration: DeepgramNovaStreamingTranscriptionIntegration

    // MARK: Owner state (PHASE-08)

    /// OWN-INTEGRATION-OPENROUTER-REFINEMENT instance owned by the composition
    /// root. Refinement stays disabled until an explicit configuration.
    let refinementIntegration: OpenrouterRefinementIntegration

    // MARK: Owner state (PHASE-09)

    /// OWN-INTEGRATION-OPENROUTER-TRANSCRIPTION instance owned by the
    /// composition root for finalized imported-audio batch transcription.
    let batchTranscriptionIntegration: OpenrouterTranscriptionIntegration

    // MARK: Owner state (PHASE-10)

    /// OWN-CREDENTIAL-VAULT-FEATURE instance owned by the composition root.
    /// It shares the composition root's CredentialVault and Deepgram
    /// integration, so the settings-facing credential surface and provider
    /// use read the same vault and keys are never copied.
    let credentialVaultFeature: CredentialVaultFeature

    // MARK: Owner state (PHASE-11)

    /// OWN-CUSTOM-WRITING-MODES-AND-VOCABULARY instance owned by the
    /// composition root. It reads stored writing modes and vocabulary through
    /// the shared DataStore and feeds deterministic request parameters to the
    /// shared OpenRouter integrations and Deepgram streaming keyterms.
    let customWritingFeature: CustomWritingModesAndVocabularyFeature

    // MARK: Owner state (PHASE-12)

    /// Jev structured decision engine integration for hallucination filtering and mode routing.
    let jevDecisionIntegration: JevDecisionIntegration

    /// OWN-DUAL-PROVIDER-ROUTING instance owned by the composition root. It
    /// routes each session to the shared Deepgram streaming or OpenRouter batch
    /// integration according to the explicitly selected provider and never
    /// falls back automatically.
    let dualProviderRoutingFeature: DualProviderRoutingFeature

    // MARK: Owner state (PHASE-13)

    /// OWN-LOCAL-HISTORY-AND-OFFLINE-SEARCH instance owned by the composition
    /// root. It shares the composition root's DataStore for bounded local
    /// history, offline search, copy, and atomic delete, and reads clipboard
    /// availability from the shared PermissionCoordinator without prompting.
    let localHistoryFeature: LocalHistoryAndOfflineSearchFeature

    // MARK: Owner state (PHASE-14)

    /// OWN-MICROPHONE-CAPTURE-AND-FLOATING-HUD instance owned by the
    /// composition root. Recording starts from the forwarded hotkey actions,
    /// the non-activating floating HUD presents capture state, live input
    /// levels, elapsed time, and the active mode, and captured audio is
    /// converted to the locked linear16 16 kHz mono PCM frames before it is
    /// forwarded to the selected transcription route.
    let microphoneCaptureFeature: MicrophoneCaptureAndFloatingHudFeature

    // MARK: Owner state (PHASE-15)

    /// OWN-PASTE-COORDINATOR instance owned by the composition root. It
    /// captures the insertion target at recording start and applies exactly
    /// one approved complete candidate through the deterministic native
    /// insertion workflow, preserving the previous clipboard content whenever
    /// it still owns it.
    let pasteCoordinator: PasteCoordinator

    // MARK: Owner state (PHASE-16)

    /// OWN-PROVIDER-SELECTION-AND-COST-PROTECTION instance owned by the
    /// composition root. It restores and persists the user's explicit
    /// provider selection through the shared DataStore, keeps recording
    /// blocked until that selection exists, and never switches providers,
    /// falls back, or retries a paid request automatically.
    let providerSelectionAndCostProtectionFeature: ProviderSelectionAndCostProtectionFeature

    // MARK: Owner state (PHASE-17)

    /// OWN-TEMPORARY-AUDIO-CLEANUP instance owned by the composition root. It
    /// tracks each recording's temporary audio through the shared DataStore:
    /// storage is prepared at recording start, stale audio from earlier
    /// sessions is gone before a new session starts, terminal paths delete the
    /// audio only with verified absence, audio is retained only while awaiting
    /// an explicit retry or an explicit provider switch, saving happens only
    /// on an explicit user action, and its cleanup outcomes are reported to
    /// the lifecycle owner.
    let temporaryAudioCleanupFeature: TemporaryAudioCleanupFeature

    // MARK: Recording session orchestration state

    /// The one active recording session's composition-level bookkeeping. The
    /// session is the single state machine the hotkey start/stop signals and
    /// the stop/cancel paths act on; a signal that does not belong to the
    /// current session is ignored.
    private struct RecordingSession {
        let recordingID: UUID
        let route: TranscriptionRoute
        let temporaryAudioURL: URL?
        var stopRequested = false
        var cancelRequested = false
        /// Set when the session's WAV container could not be finalized. An
        /// unfinalized or header-only recording is never valid recovery audio:
        /// no retention window may keep it and no completion may claim it.
        var recordingFileFinalizationFailed = false
    }

    private var activeSession: RecordingSession? {
        didSet {
            updateMenuBarIcon()
        }
    }

    /// The start attempt currently in flight: created before the first await
    /// of the start sequence and cleared when the attempt becomes the active
    /// session or ends. A stop or cancel signal that arrives while any start
    /// await is in progress is remembered here — never dropped — and is
    /// honored at the next start checkpoint, before capture or provider paid
    /// work continues.
    private struct RecordingStartIntent {
        var stopRequested = false
        var cancelRequested = false
        var isEndRequested: Bool { stopRequested || cancelRequested }
    }

    private var recordingStartIntent: RecordingStartIntent?

    /// The in-flight start attempt's task, so an in-app or HUD control that
    /// ends a session during its start window awaits the settled state instead
    /// of racing it. The start attempt never awaits a stop or cancel action,
    /// and no action body ever calls a control, so joining this task from a
    /// control is always acyclic — a control can never await the task that is
    /// running it.
    private var sessionStartingTask: Task<Void, Never>?

    /// Serialized frame hand-off to the selected route: the capture feature's
    /// converted locked-format frames are yielded in capture order and one
    /// consumer delivers them in exactly that order, so no per-frame task
    /// races the provider or the recording file.
    private var audioFrameContinuation: AsyncStream<Data>.Continuation?
    private var audioFrameTask: Task<Void, Never>?

    /// The streaming route's receive-side driver: it pumps provider events,
    /// sends KeepAlive inside the idle window, and finalizes on user stop.
    private var streamingSessionTask: Task<Void, Never>?

    /// The active streaming route's interim text for the menu presentation
    /// (the HUD reads the same value through the capture feature). Interim
    /// text is presentation only: it is never an insertion or persistence
    /// candidate, and every terminal path clears it.
    private(set) var interimTranscript: String = ""

    /// The session's one provider-supported recording file writer: the locked
    /// 16 kHz mono PCM is recorded to this single WAV container for the
    /// streaming route as well as the batch route, so a retained or explicitly
    /// saved recording is never an empty placeholder. Audio exists only while
    /// the session is active.
    private var recordingFileWriter: MicrophoneWavFileWriter?

    /// The awaited termination task, so a repeated quit request joins the same
    /// release instead of starting a second one.
    private var terminationTask: Task<Void, Never>?

    /// Pump cadence for the streaming route. Tests inject a fast tick; the
    /// production default is a bounded, user-invisible interval.
    private let sessionTickInterval: Duration

    /// True only while a recording session is active. The menu presentation
    /// and the focused pipeline checks read this.
    var isRecordingSessionActive: Bool { activeSession != nil }

    /// True while a recording session is in flight: the start sequence is
    /// still running or the session is active. The in-app and HUD controls
    /// and the provider lock read this authoritative notion, so a stop or
    /// cancel that arrives during the start sequence is never a no-op.
    var isRecordingSessionInFlight: Bool {
        activeSession != nil || recordingStartIntent != nil
    }

    /// True while the explicit provider selection is locked because a
    /// recording session (or its completion pipeline) is in flight. The
    /// provider changes only between recordings
    /// (ACC-PROVIDER-SELECTION-AND-COST-PROTECTION-04).
    var isProviderSelectionLocked: Bool { isRecordingSessionInFlight }

    // MARK: User-facing control surface state

    /// The dictation mode the in-app record control starts. The mode vocabulary
    /// belongs to the hotkey feature; the in-app control never guesses, and the
    /// same single session state machine runs either way.
    var inAppRecordingMode: HotkeyMode = .pushToTalk

    /// The settings tab currently presented. A fresh install opens on `.setup`,
    /// where every required action has a visible in-app control.
    var selectedSettingsTab: SettingsTab = .setup

    /// The explicitly selected provider, mirrored from the cost gate (the
    /// routing owner must agree; `syncProviderPresentation` surfaces any drift
    /// instead of hiding it).
    private(set) var selectedProvider: TranscriptionProviderID?

    /// Value-free provider summary for the menu and settings surface.
    private(set) var providerSummary = "No provider selected — recording is blocked until you choose one."

    /// Value-free provider feedback: the explicit selection result, the lock,
    /// or the fail-safe rollback. It never carries secret material.
    private(set) var providerFeedback: String?

    /// Value-free credential feedback; it never carries secret material.
    private(set) var credentialFeedback: String?

    /// Value-free shortcut feedback (registration outcome or conflict recovery).
    private(set) var hotkeyFeedback: String?

    /// The stored shortcut configuration currently presented by the editor.
    private(set) var hotkeyConfiguration: HotkeyConfiguration = .empty

    /// Value-free summary of the active shortcut registration.
    private(set) var hotkeyRegistrationSummary = "No dictation shortcut is registered yet."

    /// Value-free writing-mode and vocabulary feedback.
    private(set) var writingFeedback: String?

    /// The stored writing modes currently presented.
    private(set) var writingModes: [WritingMode] = []

    /// The stored vocabulary terms currently presented.
    private(set) var vocabularyTerms: [VocabularyTerm] = []

    /// The writing mode explicitly selected for the next recording, when any.
    private(set) var selectedWritingModeID: String?

    /// Value-free history feedback.
    private(set) var historyFeedback: String?

    /// The bounded local history currently presented (newest first).
    private(set) var historyTranscripts: [TranscriptRecord] = []

    /// The offline search query currently presented.
    var historyQuery: String = ""

    /// Value-free paste feedback (preview, recovery, or a failure message).
    private(set) var pasteFeedback: String?

    /// The configured insertion mode currently presented.
    private(set) var pasteMode: PasteMode = .autoPaste

    /// True while a completed transcript waits for explicit preview approval.
    private(set) var isPreviewAwaitingApproval = false

    /// The complete transcript waiting for explicit preview approval, when any.
    private(set) var pendingPreviewText: String?

    /// The complete transcript preserved after a failed insertion, when any.
    private(set) var retainedPasteText: String?

    /// Whether optional refinement is explicitly enabled.
    private(set) var refinementEnabled = false

    /// Value-free refinement feedback.
    private(set) var refinementFeedback: String?

    /// Value-free permission and login-item states per domain.
    private(set) var permissionStates: [PermissionDomain: PermissionState] = [:]

    /// Value-free permission feedback (guidance or the explicit request result).
    private(set) var permissionFeedback: String?

    /// The login-item status presented by the launch-at-login toggle.
    private(set) var launchAtLoginStatus: LoginItemStatus = .notRegistered

    /// Value-free launch-at-login feedback.
    private(set) var launchAtLoginFeedback: String?

    // MARK: Fn (Globe) key & clipboard preservation
    private var flagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var isFnKeyDown: Bool = false
    private var isFnRecordingActive: Bool = false

    /// Whether the Fn (Globe) key acts as a push-to-talk key.
    private(set) var useFnKeyForPushToTalk: Bool = false

    /// Whether the previous clipboard is restored after auto-paste.
    private(set) var restoreClipboardAfterPaste: Bool = false

    // MARK: - TypeSafe Jev Intelligence settings
    private(set) var jevEnabled: Bool = true
    private(set) var jevSmartRefinementGateEnabled: Bool = true
    private(set) var jevAutoWritingModeEnabled: Bool = true
    private(set) var jevHallucinationGuardrailEnabled: Bool = true
    private(set) var typesafeKeyStatus: CredentialVault.TypesafeKeyStatus = .missing

    /// Whether the app keeps its Dock icon visible and remains in .regular mode.
    var keepDockIconVisible: Bool = true

    /// The one awaitable record/stop/cancel action the composition root runs
    /// for a session signal (shortcut or in-app control). In-app controls await
    /// it, so a control reflects the settled session state instead of racing it.
    private var sessionActionTask: Task<Void, Never>?

    // MARK: Lifecycle

    init(
        credentialVault: CredentialVault = CredentialVault(),
        dataStore: DataStore = DataStore(),
        lifecycleCoordinator: LifecycleCoordinator = LifecycleCoordinator(),
        permissionCoordinator: PermissionCoordinator = PermissionCoordinator(),
        globalHotkeysFeature: GlobalHotkeysAndPushToTalkToggleModesFeature? = nil,
        deepgramStreamingIntegration: DeepgramNovaStreamingTranscriptionIntegration? = nil,
        refinementIntegration: OpenrouterRefinementIntegration? = nil,
        batchTranscriptionIntegration: OpenrouterTranscriptionIntegration? = nil,
        credentialVaultFeature: CredentialVaultFeature? = nil,
        customWritingFeature: CustomWritingModesAndVocabularyFeature? = nil,
        jevDecisionIntegration: JevDecisionIntegration? = nil,
        dualProviderRoutingFeature: DualProviderRoutingFeature? = nil,
        localHistoryFeature: LocalHistoryAndOfflineSearchFeature? = nil,
        microphoneCaptureFeature: MicrophoneCaptureAndFloatingHudFeature? = nil,
        pasteCoordinator: PasteCoordinator? = nil,
        providerSelectionAndCostProtectionFeature: ProviderSelectionAndCostProtectionFeature? = nil,
        temporaryAudioCleanupFeature: TemporaryAudioCleanupFeature? = nil,
        saveDestinationChooser: (@MainActor (String) async -> TemporaryAudioCleanupFeature.SaveDestinationDecision)? = nil,
        sessionTickInterval: Duration = .milliseconds(250),
        keepDockIconVisible: Bool = true
    ) {
        self.sessionTickInterval = sessionTickInterval
        self.credentialVault = credentialVault
        self.keepDockIconVisible = keepDockIconVisible
        self.dataStore = dataStore
        self.lifecycleCoordinator = lifecycleCoordinator
        self.permissionCoordinator = permissionCoordinator

        // The default feature reads the cached global-input permission state
        // (never prompting) so a denial falls back to the in-app controls.
        let permissions = permissionCoordinator
        let hotkeys = globalHotkeysFeature ?? GlobalHotkeysAndPushToTalkToggleModesFeature(
            globalInputAvailability: { permissions.lastKnownStates[.globalInput] ?? .notDetermined }
        )
        self.globalHotkeysFeature = hotkeys

        let deepgram = deepgramStreamingIntegration
            ?? DeepgramNovaStreamingTranscriptionIntegration(credentialVault: credentialVault)
        self.deepgramStreamingIntegration = deepgram

        self.refinementIntegration = refinementIntegration
            ?? OpenrouterRefinementIntegration(credentialVault: credentialVault)

        self.batchTranscriptionIntegration = batchTranscriptionIntegration
            ?? OpenrouterTranscriptionIntegration(credentialVault: credentialVault)

        let jev = jevDecisionIntegration
            ?? JevDecisionIntegration(credentialVault: credentialVault)
        self.jevDecisionIntegration = jev

        self.credentialVaultFeature = credentialVaultFeature
            ?? CredentialVaultFeature(vault: credentialVault, deepgramIntegration: deepgram)

        let writing = customWritingFeature
            ?? CustomWritingModesAndVocabularyFeature(dataStore: dataStore)
        self.customWritingFeature = writing

        let routing = dualProviderRoutingFeature ?? DualProviderRoutingFeature(
            dataStore: dataStore,
            deepgramIntegration: deepgram,
            refinementIntegration: self.refinementIntegration,
            batchIntegration: self.batchTranscriptionIntegration,
            jevIntegration: jev
        )
        self.dualProviderRoutingFeature = routing

        let history = localHistoryFeature ?? LocalHistoryAndOfflineSearchFeature(
            dataStore: dataStore,
            clipboard: SystemClipboardWriter(),
            clipboardAvailability: { permissions.lastKnownStates[.clipboard] ?? .notDetermined }
        )
        self.localHistoryFeature = history

        // Capture reads the cached microphone permission state and, only from
        // the explicit recording start, may request AVCaptureDevice audio
        // authorization through the shared PermissionCoordinator.
        let capture = microphoneCaptureFeature ?? MicrophoneCaptureAndFloatingHudFeature(
            microphoneAvailability: { permissions.lastKnownStates[.microphone] ?? .notDetermined },
            requestMicrophoneAccess: { await permissions.request(.microphone) }
        )
        self.microphoneCaptureFeature = capture

        // Paste reads the cached Accessibility and clipboard permission states
        // and, only from an actual insertion workflow, may request
        // Accessibility trust through the shared PermissionCoordinator.
        let paste = pasteCoordinator ?? PasteCoordinator(
            accessibilityAvailability: { permissions.lastKnownStates[.accessibility] ?? .notDetermined },
            requestAccessibilityTrust: { await permissions.request(.accessibility) },
            clipboardAvailability: { permissions.lastKnownStates[.clipboard] ?? .notDetermined }
        )
        self.pasteCoordinator = paste

        // Cost protection reads and writes only the explicit provider
        // preference through the shared DataStore, checks credential
        // availability through the shared Keychain-backed vault (a value-free
        // status only), and reads the cached network permission without
        // prompting.
        let costProtection = providerSelectionAndCostProtectionFeature ?? ProviderSelectionAndCostProtectionFeature(
            loadStoredSelection: { await dataStore.providerPreference() },
            storeSelection: { await dataStore.setProviderPreference($0) },
            credentialAvailability: { provider in
                let key: CredentialKey = switch provider {
                case .deepgramStreaming: .deepgramNovaStreamingTranscription
                case .openRouterBatch: .openRouter
                }
                return await credentialVault.status(for: key) == .configured
            },
            networkAvailability: { permissions.lastKnownStates[.network] ?? .notDetermined },
            requestNetworkAccess: { await permissions.request(.network) }
        )
        self.providerSelectionAndCostProtectionFeature = costProtection

        // Temporary audio lives only for the active request: the cleanup owner
        // reads and writes the shared DataStore's sandboxed temporary and
        // saved recording placement, and reports each cleanup outcome to the
        // lifecycle owner. The explicit save asks the injected destination
        // chooser — the native save panel in production, a deterministic fake
        // in tests — and nothing here touches the filesystem at launch.
        let tempAudio = temporaryAudioCleanupFeature ?? TemporaryAudioCleanupFeature(
            prepareTemporaryRecording: { recordingID, fileExtension in
                try await dataStore.prepareTemporaryRecording(recordingID: recordingID, fileExtension: fileExtension)
            },
            temporaryRecordingExists: { recordingID in
                await dataStore.temporaryRecordingExists(recordingID: recordingID)
            },
            discardTemporaryRecording: { recordingID in
                try await dataStore.discardTemporaryRecording(recordingID: recordingID)
            },
            saveRecording: { recordingID, fileExtension, destination in
                try await dataStore.saveRecording(
                    recordingID: recordingID,
                    fileExtension: fileExtension,
                    destination: destination
                )
            },
            chooseSaveDestination: saveDestinationChooser ?? { suggestedFileName in
                await SystemSaveDestinationChooser().chooseSaveDestination(
                    suggestedFileName: suggestedFileName
                )
            },
            purgeStaleTemporaryRecordings: {
                try await dataStore.purgeStaleTemporaryRecordings()
            },
            reportCaptureTermination: { reason, cleanup in
                _ = lifecycleCoordinator.recordCaptureTermination(reason: reason, cleanup: cleanup)
            }
        )
        self.temporaryAudioCleanupFeature = tempAudio

        lifecycleCoordinator.registerTerminationResource(name: "global-hotkeys", releaser: hotkeys)
        lifecycleCoordinator.registerLaunchStep(name: "global-hotkeys") {
            let configuration = await dataStore.hotkeyConfiguration()
            _ = await MainActor.run { hotkeys.configure(configuration) }
        }
        // Preset-owned state only: stored writing modes and vocabulary are
        // loaded at launch; no provider request or capture starts here.
        lifecycleCoordinator.registerLaunchStep(name: "custom-writing-modes") {
            await writing.load()
        }
        // Preset-owned state only: the explicitly stored provider preference
        // is restored at launch; no provider request or capture starts here.
        lifecycleCoordinator.registerTerminationResource(name: "dual-provider-routing", releaser: routing)
        lifecycleCoordinator.registerLaunchStep(name: "provider-routing") {
            await routing.loadProviderPreference()
        }

        // Preset-owned state only: the bounded local transcript history is
        // loaded at launch; no clipboard write, upload, or deletion happens here.
        lifecycleCoordinator.registerTerminationResource(name: "local-history", releaser: history)
        lifecycleCoordinator.registerLaunchStep(name: "local-history") {
            await history.load()
        }

        // Recording starts via the hotkey the user already pressed: the
        // composition root runs exactly one session state machine per action —
        // the paid-request gate, the temporary audio session, the insertion
        // target, the explicitly selected provider route, and then capture —
        // and forwards every stop or cancel signal to that same session.
        hotkeys.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .startRecording(let mode):
                let task = Task { @MainActor [weak self] in
                    _ = await self?.beginRecordingSession(mode: mode)
                }
                self.sessionActionTask = task
                self.sessionStartingTask = task
            case .stopRecording(_, let reason):
                self.sessionActionTask = Task { @MainActor [weak self] in
                    await self?.finishRecordingSession(reason: reason)
                }
            }
        }
        // Converted locked-format PCM frames flow only to the explicitly
        // selected transcription route, in capture order, through the one
        // ordered hand-off below (never through a task per frame).
        capture.onAudioFrame = { [weak self] pcm in
            self?.enqueueAudioFrame(pcm)
        }
        // The floating HUD's instant stop and cancel controls route through
        // this composition root and drive the one authoritative recording
        // session state machine — the same workflow the matching shortcut and
        // the in-app controls run — instead of the capture-only terminal path:
        // stop finalizes the selected route and completes cost, history,
        // paste, and verified cleanup; cancel stops the route, cancels the
        // paid request, and deletes the temporary audio with verified absence.
        capture.onStopControlRequested = { [weak self] in
            await self?.handleHudStopControl()
        }
        capture.onCancelControlRequested = { [weak self] in
            await self?.handleHudCancelControl()
        }
        routing.onHudNotice = { [weak self] notice in
            self?.statusText = notice
            let delay: TimeInterval? = notice.contains("Refining") ? nil : 1.8
            self?.microphoneCaptureFeature.showStatusPill(notice, autoDismissDelay: delay)
        }
        // The input device, the buffer sink, and the non-activating floating
        // HUD panel are released before termination completes.
        lifecycleCoordinator.registerTerminationResource(name: "microphone-capture", releaser: capture)

        // The captured insertion target and any in-flight clipboard snapshot
        // are released before termination completes
        // (CON-LIFECYCLE-APPLICATION-TERMINATION).
        lifecycleCoordinator.registerTerminationResource(name: "paste-coordinator", releaser: paste)

        // Preset-owned state only: the explicitly stored provider selection
        // is restored at launch, so recording stays blocked until the user
        // has actually selected a provider. Runtime request state is released
        // before termination completes.
        lifecycleCoordinator.registerTerminationResource(name: "provider-selection-and-cost-protection", releaser: costProtection)
        lifecycleCoordinator.registerLaunchStep(name: "provider-selection") {
            await costProtection.loadProviderSelection()
        }

        // The active, retained, or pending temporary audio is deleted with
        // verified absence before termination completes, and the outcome is
        // reported to the lifecycle owner with the app-termination reason
        // (CON-LIFECYCLE-AUDIO-CAPTURE-TERMINATION).
        lifecycleCoordinator.registerTerminationResource(name: "temporary-audio-cleanup", releaser: tempAudio)
    }

    /// CON-LIFECYCLE-APPLICATION-LAUNCH: initialize preset-owned state only.
    /// Never start privileged capture, remote requests, or destructive work.
    func applicationDidFinishLaunching() {
        guard !didFinishLaunching else { return }
        didFinishLaunching = true
        statusText = "Ready"
        setupScreenChangeObserver()
        if keepDockIconVisible {
            elevateToRegularPolicy()
        }
        Task { @MainActor [weak self, lifecycleCoordinator] in
            await lifecycleCoordinator.applicationDidFinishLaunching()
            if self?.keepDockIconVisible == true {
                self?.elevateToRegularPolicy()
            }
            await self?.refreshLaunchPresentation()
        }
    }

    /// The user-facing values a freshly launched instance presents: the stored
    /// preset state (provider, hotkeys, modes, vocabulary, history, paste mode,
    /// refinement) is mirrored from its owners. No Keychain value, no prompt,
    /// no provider request, and no destructive work happens here.
    private func refreshLaunchPresentation() async {
        if case .failed(let reason) = lifecycleCoordinator.state {
            lastErrorMessage = "Startup did not complete during \(reason). Nothing privileged was started; retry explicitly."
        }
        syncProviderPresentation()
        if hotkeyConfiguration.isEmpty {
            _ = await useSafeDefaultHotkeys()
        }
        syncHotkeyPresentation()
        syncWritingPresentation()
        syncHistoryPresentation()
        syncPastePresentation(notice: nil)
        launchAtLoginStatus = lifecycleCoordinator.launchAtLoginStatus
        useFnKeyForPushToTalk = await dataStore.useFnKeyForPushToTalk()
        restoreClipboardAfterPaste = await dataStore.restoreClipboardAfterPaste()
        pasteCoordinator.restoreClipboard = restoreClipboardAfterPaste
        jevEnabled = await dataStore.isJevEnabled()
        jevSmartRefinementGateEnabled = await dataStore.isJevSmartRefinementGateEnabled()
        jevAutoWritingModeEnabled = await dataStore.isJevAutoWritingModeEnabled()
        jevHallucinationGuardrailEnabled = await dataStore.isJevHallucinationGuardrailEnabled()
        dualProviderRoutingFeature.setJevEnabled(jevEnabled)
        dualProviderRoutingFeature.setJevSmartRefinementGateEnabled(jevSmartRefinementGateEnabled)
        dualProviderRoutingFeature.setJevAutoWritingModeEnabled(jevAutoWritingModeEnabled)
        dualProviderRoutingFeature.setJevHallucinationGuardrailEnabled(jevHallucinationGuardrailEnabled)
        setupFlagsMonitor()
        await refreshRefinementPresentation()
        await refreshTypesafeKeyStatus()
    }

    /// CON-LIFECYCLE-APPLICATION-TERMINATION, awaited: stop the active
    /// session's work, then release every registered resource through the
    /// lifecycle owner (the live stream, the input device, the temporary audio
    /// with verified absence, hotkeys, the clipboard snapshot, and the HUD).
    /// `applicationShouldTerminate` answers AppKit only after this completes.
    func completeTermination() async {
        if let terminationTask {
            await terminationTask.value
            return
        }
        let task: Task<Void, Never> = Task { @MainActor [weak self] in
            _ = await self?.performTerminationRelease()
        }
        terminationTask = task
        await task.value
    }

    private func performTerminationRelease() async {
        statusText = "Terminating"
        stopFlagsMonitoring()
        stopScreenChangeObserver()
        // Stop new session work first: no frame delivery, pump, or route send
        // outlives termination.
        let streamingDriver = streamingSessionTask
        streamingSessionTask = nil
        streamingDriver?.cancel()
        recordingFileWriter?.cancel()
        recordingFileWriter = nil
        stopAudioFrameDelivery()
        activeSession = nil
        syncInterimTranscript()
        // The lifecycle owner releases every registered resource before
        // termination completes (CON-LIFECYCLE-APPLICATION-TERMINATION).
        await lifecycleCoordinator.applicationWillTerminate()
        // The temporary-audio owner's termination outcome is preserved, never
        // discarded, and mirrored for the terminal presentation.
        lastTemporaryAudioOutcome = temporaryAudioCleanupFeature.lastTerminationOutcome ?? lastTemporaryAudioOutcome
        syncTemporaryAudioPresentation()
        // The receive-side driver can only exit once the released route closed
        // its socket, which the release above guarantees.
        await streamingDriver?.value
    }

    /// The AppKit callback that follows a completed `.terminateLater` reply:
    /// the awaited release already ran, so this only records the terminal
    /// presentation state.
    func applicationWillTerminate() {
        statusText = "Terminating"
    }

    func requestTermination() {
        isTerminationRequested = true
        NSApp.terminate(nil)
    }

    // MARK: Recording session orchestration

    /// One explicit user-started recording:
    /// the paid-request gate, the temporary audio session, the insertion
    /// target, the selected provider route, and capture start, in that order.
    /// A blocked gate, missing temporary storage, a failed route start, or a
    /// failed capture start ends the attempt with an explicit terminal state,
    /// and nothing retries, falls back, or switches providers automatically.
    ///
    /// The attempt is the authoritative session from its acceptance onward: a
    /// stop or cancel signal that arrives while any start await is in progress
    /// is remembered on the start intent and honored at the next checkpoint,
    /// before capture or provider paid work continues.
    private func beginRecordingSession(mode: HotkeyMode) async {
        guard activeSession == nil, recordingStartIntent == nil else {
            // A session (or its completion pipeline) is still running: the
            // duplicate start never disturbs it.
            return
        }
        recordingStartIntent = RecordingStartIntent()
        defer {
            recordingStartIntent = nil
            sessionStartingTask = nil
        }

        // PHASE-16: recording stays blocked until the explicit provider
        // selection passes the cost gate. The origin is always the user's own
        // action, and there is no automatic provider switch, fallback, or
        // paid retry anywhere here.
        let origin: PaidRequestOrigin = providerSelectionAndCostProtectionFeature.awaitingExplicitRecovery
            ? .explicitRetry
            : .explicitStart
        let decision = await providerSelectionAndCostProtectionFeature.requestPaidRecording(origin: origin)
        let provider: TranscriptionProviderID
        switch decision {
        case .allowed(let authorized):
            provider = authorized
        case .blocked(let failure):
            lastErrorMessage = failure.message
            statusText = "Recording blocked"
            // The session never started: the single recording state machine is
            // released so neither a shortcut nor the in-app controls stay
            // stuck in a recording state.
            globalHotkeysFeature.reportStartFailure()
            return
        }
        let route = TranscriptionRoute(provider: provider)
        lastErrorMessage = nil
        guard !isStartEndRequested else {
            await endStartingSessionBeforeCapture(recordingID: nil)
            return
        }

        // PHASE-17: the recording's temporary audio storage is prepared (with
        // stale audio from earlier sessions already gone) before capture can
        // run. A recording that cannot secure its temporary storage does not
        // start, and the paid request it never made ends as cancelled.
        let recordingID = UUID()
        guard await temporaryAudioCleanupFeature.beginSession(
            recordingID: recordingID,
            fileExtension: Self.temporaryAudioFileExtension(for: route)
        ) else {
            lastErrorMessage = temporaryAudioCleanupFeature.lastFailure?.message
            syncTemporaryAudioPresentation()
            statusText = "Recording blocked"
            _ = providerSelectionAndCostProtectionFeature.cancelActivePaidRequest()
            globalHotkeysFeature.reportStartFailure()
            return
        }
        syncTemporaryAudioPresentation()
        guard !isStartEndRequested else {
            await endStartingSessionBeforeCapture(recordingID: recordingID)
            return
        }

        // CON-PASTE-WORKFLOW step 1: the insertion target is captured at
        // recording start, before any later focus change occurs.
        _ = pasteCoordinator.captureInsertionTarget()

        let session = RecordingSession(
            recordingID: recordingID,
            route: route,
            temporaryAudioURL: temporaryAudioCleanupFeature.activeTemporaryAudioURL
        )

        // CON-PERMISSION-MICROPHONE: the microphone authorization is resolved
        // before the selected provider route is opened, so a first-run access
        // prompt completes before a live socket or recording file exists and
        // no streaming route ever times out waiting for audio that cannot
        // arrive. A non-authorized resolution records the documented
        // permission failure and ends the attempt here — no route, no
        // provider request, and no recording.
        guard await microphoneCaptureFeature.resolveMicrophoneAuthorizationBeforeRoute() else {
            lastErrorMessage = microphoneCaptureFeature.lastFailure?.message
            statusText = "Recording blocked"
            _ = providerSelectionAndCostProtectionFeature.cancelActivePaidRequest()
            recordTemporaryAudioOutcome(await temporaryAudioCleanupFeature.cancelSession(recordingID: recordingID))
            globalHotkeysFeature.reportStartFailure()
            return
        }
        guard !isStartEndRequested else {
            await endStartingSessionBeforeCapture(recordingID: recordingID)
            return
        }

        // Every route records the identical locked 16 kHz mono PCM into one
        // valid WAV container before capture can run: a retained or explicitly
        // saved recording is never an empty placeholder. A session whose
        // recording file cannot be prepared ends before capture, with nothing
        // retained.
        guard let recordingURL = session.temporaryAudioURL else {
            lastErrorMessage = "The recording file location was unavailable, so the recording did not start."
            statusText = "Recording blocked"
            _ = providerSelectionAndCostProtectionFeature.cancelActivePaidRequest()
            recordTemporaryAudioOutcome(await temporaryAudioCleanupFeature.discardExplicitly(recordingID: recordingID))
            globalHotkeysFeature.reportStartFailure()
            return
        }
        let writer = MicrophoneWavFileWriter(url: recordingURL)
        do {
            try writer.begin()
        } catch {
            lastErrorMessage = "The recording file could not be prepared, so the recording did not start."
            statusText = "Recording blocked"
            _ = providerSelectionAndCostProtectionFeature.cancelActivePaidRequest()
            recordTemporaryAudioOutcome(await temporaryAudioCleanupFeature.discardExplicitly(recordingID: recordingID))
            globalHotkeysFeature.reportStartFailure()
            return
        }
        recordingFileWriter = writer

        // The selected route is ready before audio flows: Deepgram opens
        // exactly one stream for this user-started recording. A route that
        // cannot start ends the session before capture, with nothing retained.
        switch route {
        case .deepgramStreaming:
            let parameters = customWritingFeature.parameters
            guard await dualProviderRoutingFeature.startLiveStreaming(
                language: nil,
                keyterms: parameters.keyterms
            ) else {
                recordingFileWriter?.cancel()
                recordingFileWriter = nil
                _ = providerSelectionAndCostProtectionFeature.reportPaidRequestFailure()
                recordTemporaryAudioOutcome(await temporaryAudioCleanupFeature.cancelSession(recordingID: recordingID))
                lastErrorMessage = dualProviderRoutingFeature.lastFailure?.message
                    ?? "The selected transcription route could not start, so no recording was made; retry explicitly."
                statusText = "Recording blocked"
                globalHotkeysFeature.reportStartFailure()
                return
            }
        case .openRouterBatch:
            break
        }
        guard !isStartEndRequested else {
            await endStartingSessionBeforeCapture(recordingID: recordingID)
            return
        }

        // The attempt passes its final checkpoint and becomes the active
        // session: from here the ordinary stop and cancel paths own the one
        // terminal transition. Nothing between the checkpoint and this
        // assignment awaits, so no signal can be lost in between.
        activeSession = session
        recordingStartIntent = nil
        startAudioFrameDelivery()
        syncInterimTranscript()

        let captureStarted = await microphoneCaptureFeature.startCapture(mode: mode)
        guard captureStarted else {
            await failRecordingSessionStart(session)
            return
        }
        // A cancel that arrived while capture was still starting already owns
        // this session's terminal transition, so nothing may resurrect it. A
        // stop that arrived in the same window still needs the streaming
        // driver: its finalize path is what completes the session, and this
        // attempt settles with that completion instead of racing it.
        guard let liveSession = activeSession,
              liveSession.recordingID == session.recordingID,
              !liveSession.cancelRequested else {
            return
        }
        if route == .deepgramStreaming {
            startStreamingSessionDriver(session)
            if liveSession.stopRequested {
                await streamingSessionTask?.value
            }
        }
        if !liveSession.stopRequested {
            statusText = "Recording"
        }
    }

    /// The stop signal from the hotkey (user release, toggle off, or the
    /// in-app stop control) or from a reported provider failure. A session
    /// that is already stopping or cancelling is left untouched: there is
    /// exactly one state machine per session.
    ///
    /// A signal that arrives while the start sequence is still awaiting has no
    /// active session yet; it is remembered on the start intent — never
    /// dropped — and honored by the start sequence before capture or provider
    /// paid work continues (or, once the session is active, by the ordinary
    /// terminal paths). A signal with no attempt in flight maps to nothing.
    private func finishRecordingSession(
        reason: GlobalHotkeysAndPushToTalkToggleModesFeature.StopReason
    ) async {
        guard let session = activeSession else {
            switch reason {
            case .cancelled:
                recordingStartIntent?.cancelRequested = true
            case .userRelease, .userToggledOff, .providerFailure:
                recordingStartIntent?.stopRequested = true
            }
            return
        }
        guard !session.stopRequested, !session.cancelRequested else {
            return
        }
        switch reason {
        case .cancelled:
            await cancelActiveRecordingSession(session)
        case .userRelease, .userToggledOff, .providerFailure:
            await stopActiveRecordingSession(session)
        }
    }

    /// True while the current start attempt has been asked to stop or cancel
    /// and has not yet reached its terminal state.
    private var isStartEndRequested: Bool {
        recordingStartIntent?.isEndRequested == true
    }

    /// Ends the current start attempt before it becomes a recording: its stop
    /// or cancel signal arrived while the start sequence was still awaiting,
    /// so nothing was captured and no provider request was ever sent. The one
    /// terminal transition: the authorized paid request is cancelled (no cost
    /// is incurred and nothing is claimed), the selected route is cancelled if
    /// it had already started, the recording file is abandoned, and the
    /// prepared temporary audio is deleted with verified absence. No
    /// transcript, history record, insertion, or recovery window follows.
    ///
    /// The start intent stays published for the whole wind-down, so no new
    /// start can begin until this attempt has fully ended.
    private func endStartingSessionBeforeCapture(recordingID: UUID?) async {
        recordingFileWriter?.cancel()
        recordingFileWriter = nil
        stopAudioFrameDelivery()
        await dualProviderRoutingFeature.cancelCurrentOperation()
        _ = providerSelectionAndCostProtectionFeature.cancelActivePaidRequest()
        if let recordingID {
            recordTemporaryAudioOutcome(
                await temporaryAudioCleanupFeature.cancelSession(recordingID: recordingID)
            )
        }
        syncInterimTranscript()
        lastErrorMessage = "The recording was stopped before it started, so nothing was recorded and no transcription request was made. Start again when you are ready."
        statusText = "Recording cancelled"
    }

    /// The user stop: capture is released first, every buffered frame is
    /// delivered, and the selected route is finalized exactly once. Streaming
    /// sends Finalize here so the shared pump consumer can receive the final
    /// boundary; batch finalizes its recording file and transcribes it on
    /// stop. Completion then runs the authoritative cost gate, the bounded
    /// local history save, the single paste request, and the verified
    /// temporary-audio cleanup.
    private func stopActiveRecordingSession(_ session: RecordingSession) async {
        activeSession?.stopRequested = true
        _ = await microphoneCaptureFeature.stopCapture()
        await drainAudioFrameDelivery()
        switch session.route {
        case .deepgramStreaming:
            // The recorded file is finalized before the route completion runs:
            // the session's recording is a valid WAV container at rest, so a
            // retained or explicitly saved recording is never meaningless. A
            // finalization that fails is recorded on the session so nothing
            // later claims or retains the unfinalized file as valid recovery
            // audio.
            do {
                _ = try recordingFileWriter?.finish()
            } catch {
                activeSession?.recordingFileFinalizationFailed = true
            }
            recordingFileWriter = nil
            await dualProviderRoutingFeature.stopAndFinalize()
            await streamingSessionTask?.value
        case .openRouterBatch:
            await finalizeBatchRecordingSession(session)
        }
    }

    /// The explicit cancel: the paid request ends as cancelled, the route
    /// stops (late results are discarded), the capture session is cancelled,
    /// and the temporary audio is deleted with verified absence and reported
    /// to the lifecycle owner as a cancellation.
    private func cancelActiveRecordingSession(_ session: RecordingSession) async {
        guard activeSession?.recordingID == session.recordingID else { return }
        activeSession = nil
        streamingSessionTask?.cancel()
        streamingSessionTask = nil
        recordingFileWriter?.cancel()
        recordingFileWriter = nil
        stopAudioFrameDelivery()
        _ = await microphoneCaptureFeature.cancelCapture()
        await dualProviderRoutingFeature.cancelCurrentOperation()
        _ = providerSelectionAndCostProtectionFeature.cancelActivePaidRequest()
        recordTemporaryAudioOutcome(await temporaryAudioCleanupFeature.cancelSession(recordingID: session.recordingID))
        syncInterimTranscript()
        lastErrorMessage = nil
        statusText = "Recording cancelled"
    }

    /// A capture that never started has no provider request in flight and no
    /// active recording: the route and the paid request end as cancelled and
    /// the temporary audio is deleted with verified absence.
    private func failRecordingSessionStart(_ session: RecordingSession) async {
        guard activeSession?.recordingID == session.recordingID else { return }
        activeSession = nil
        streamingSessionTask?.cancel()
        streamingSessionTask = nil
        recordingFileWriter?.cancel()
        recordingFileWriter = nil
        stopAudioFrameDelivery()
        await dualProviderRoutingFeature.cancelCurrentOperation()
        _ = providerSelectionAndCostProtectionFeature.cancelActivePaidRequest()
        recordTemporaryAudioOutcome(await temporaryAudioCleanupFeature.cancelSession(recordingID: session.recordingID))
        syncInterimTranscript()
        lastErrorMessage = microphoneCaptureFeature.lastFailure?.message
        statusText = "Recording blocked"
        globalHotkeysFeature.reportStartFailure()
    }

    /// A provider or recording failure ends the session: the paid request's
    /// terminal state is recorded from its own failure, capture is released,
    /// and the temporary audio follows the routing owner's retention policy —
    /// retained only after a recoverable provider failure while awaiting an
    /// explicit retry or provider switch, otherwise deleted with verified
    /// absence. No fallback request ever follows.
    ///
    /// A retention window opens only for a finalized, non-empty WAV container:
    /// it is exactly the audio an explicit retry or an explicit save acts on.
    /// A finalization that failed — here or on the stop path — is never
    /// retained as recoverable audio; it is discarded with verified absence.
    private func failActiveRecordingSession(_ session: RecordingSession, message: String? = nil) async {
        guard let liveSession = activeSession, liveSession.recordingID == session.recordingID else { return }
        activeSession = nil
        streamingSessionTask = nil
        stopAudioFrameDelivery()
        _ = await microphoneCaptureFeature.stopCapture()
        _ = providerSelectionAndCostProtectionFeature.reportPaidRequestFailure()
        if dualProviderRoutingFeature.retainsTemporaryAudioForExplicitRecovery,
           finalizeRecordingFileForExplicitRecovery(
               finalizationAlreadyFailed: liveSession.recordingFileFinalizationFailed
           ) {
            recordTemporaryAudioOutcome(
                temporaryAudioCleanupFeature.retainAfterRecoverableProviderFailure(
                    recordingID: session.recordingID
                )
            )
        } else {
            recordingFileWriter?.cancel()
            recordingFileWriter = nil
            recordTemporaryAudioOutcome(
                await temporaryAudioCleanupFeature.discardExplicitly(recordingID: session.recordingID)
            )
        }
        syncInterimTranscript()
        lastErrorMessage = message
            ?? dualProviderRoutingFeature.lastFailure?.message
            ?? "The recording failed. No automatic retry or fallback occurs; retry explicitly."
        statusText = "Recording failed"
        // Keep the hotkey state machine honest; it never fires while it is
        // not recording, and the emitted stop maps to no active session.
        globalHotkeysFeature.reportProviderFailure()
    }

    /// Finalizes the session's recording file for an explicit recovery window
    /// and reports whether it is valid recovery audio. A recording that could
    /// not be finalized, or that recorded no audio at all, is never retained
    /// as recoverable: the retention window only ever holds a finalized,
    /// non-empty WAV container. The writer is released either way.
    private func finalizeRecordingFileForExplicitRecovery(finalizationAlreadyFailed: Bool) -> Bool {
        guard !finalizationAlreadyFailed else {
            recordingFileWriter?.cancel()
            recordingFileWriter = nil
            return false
        }
        guard let writer = recordingFileWriter else {
            // No writer is open: the file was already finalized by the stop
            // path and its outcome is recorded on the session.
            return true
        }
        recordingFileWriter = nil
        do {
            return try writer.finish() > 0
        } catch {
            return false
        }
    }

    /// The streaming route's receive-side driver: it pumps provider events
    /// while the recording is live (the shared pump drains the fake/test
    /// event stream or blocks on the live socket), sends KeepAlive inside the
    /// idle window, and converts a mid-recording provider failure into the
    /// session's failure terminal state. On user stop it finalizes exactly
    /// once: Finalize was sent by the stop path, the pump receives the final
    /// boundary, and completion runs the cost, history, paste, and cleanup
    /// paths.
    private func startStreamingSessionDriver(_ session: RecordingSession) {
        streamingSessionTask = Task { @MainActor [weak self] in
            await self?.driveStreamingSession(session)
        }
    }

    private func driveStreamingSession(_ session: RecordingSession) async {
        while !Task.isCancelled {
            guard let current = activeSession, current.recordingID == session.recordingID else { return }
            if current.cancelRequested { return }
            if current.stopRequested { break }
            _ = await dualProviderRoutingFeature.keepAliveIfNeeded()
            await dualProviderRoutingFeature.pump()
            syncInterimTranscript()
            if case .failed = dualProviderRoutingFeature.state {
                await failActiveRecordingSession(session)
                return
            }
            try? await Task.sleep(for: sessionTickInterval)
        }
        guard !Task.isCancelled,
              let current = activeSession,
              current.recordingID == session.recordingID,
              current.stopRequested else {
            return
        }
        await finalizeStreamingSession(session)
    }

    private func finalizeStreamingSession(_ session: RecordingSession) async {
        _ = await microphoneCaptureFeature.stopCapture()
        await drainAudioFrameDelivery()
        await dualProviderRoutingFeature.stopAndFinalize()
        let parameters = customWritingFeature.parameters
        guard let outcome = await dualProviderRoutingFeature.completeLiveStream(
            modeName: parameters.modeName,
            modeInstructions: parameters.modeInstructions
        ) else {
            // Failure, cancellation, or an empty final transcript: no history
            // record and no insertion may follow.
            await failActiveRecordingSession(session)
            return
        }
        await completeRecordingSession(session, outcome: outcome)
    }

    private func finalizeBatchRecordingSession(_ session: RecordingSession) async {
        guard let writer = recordingFileWriter, let url = session.temporaryAudioURL else {
            await failActiveRecordingSession(
                session,
                message: "The recording file was unavailable, so the recording was not transcribed."
            )
            return
        }
        recordingFileWriter = nil
        let recordedByteCount: Int
        do {
            recordedByteCount = try writer.finish()
        } catch {
            // The container could not be finalized: the file is not valid
            // recovery audio, so nothing may retain or transcribe it.
            activeSession?.recordingFileFinalizationFailed = true
            await failActiveRecordingSession(
                session,
                message: "The recording file could not be finalized, so nothing was transcribed."
            )
            return
        }
        guard recordedByteCount > 0 else {
            // An empty (header-only) recording is never sent to a provider.
            await rejectEmptyBatchRecordingSession(session)
            return
        }
        let parameters = customWritingFeature.parameters
        guard let outcome = await dualProviderRoutingFeature.transcribeImportedFile(
            at: url,
            language: nil,
            providerOrder: nil,
            modeName: parameters.modeName,
            modeInstructions: parameters.modeInstructions
        ) else {
            await failActiveRecordingSession(session)
            return
        }
        await completeRecordingSession(session, outcome: outcome)
    }

    /// An empty batch recording is rejected before any provider transport: no
    /// upload is made, the authorized paid request ends as cancelled (no cost
    /// is incurred and no usage is claimed), and the prepared temporary audio
    /// is deleted with verified absence. No transcript, history record,
    /// insertion, or recovery window follows.
    private func rejectEmptyBatchRecordingSession(_ session: RecordingSession) async {
        guard activeSession?.recordingID == session.recordingID else { return }
        activeSession = nil
        stopAudioFrameDelivery()
        _ = providerSelectionAndCostProtectionFeature.cancelActivePaidRequest()
        recordTemporaryAudioOutcome(
            await temporaryAudioCleanupFeature.cancelSession(recordingID: session.recordingID)
        )
        syncInterimTranscript()
        lastErrorMessage = "The recording contained no audio, so no transcription request was made; nothing was sent and no cost was incurred. Start again when you are ready."
        statusText = "Recording cancelled"
    }

    /// The one successful completion path: the authoritative
    /// provider-reported usage reaches the cost gate's terminal state, the one
    /// accepted complete text is saved to bounded local history, and exactly
    /// one insertion candidate runs the paste workflow — which deletes the
    /// recording's temporary audio with verified absence before any insertion
    /// begins. Only a provider-completed, non-empty outcome ever reaches it.
    private func completeRecordingSession(
        _ session: RecordingSession,
        outcome: DualProviderRoutingFeature.Outcome
    ) async {
        guard activeSession?.recordingID == session.recordingID else { return }
        let usage = await providerReportedUsage(for: outcome)
        _ = providerSelectionAndCostProtectionFeature.completePaidRequest(withProviderReportedUsage: usage)
        if let text = outcome.candidateText {
            _ = await localHistoryFeature.saveTranscript(text: text, provider: outcome.provider)
        }
        _ = await insertCompletedTranscription(outcome)
        guard activeSession?.recordingID == session.recordingID else { return }
        activeSession = nil
        stopAudioFrameDelivery()
        syncInterimTranscript()
        lastErrorMessage = nil
        if outcome.isHallucination {
            let notice = outcome.hudNotice ?? "🛡️ Ignored phantom audio"
            statusText = notice
            microphoneCaptureFeature.showStatusPill(notice)
        } else if outcome.refinement == .bypassedCleanSpeech {
            let notice = outcome.hudNotice ?? "⚡ Instant Paste"
            statusText = notice
            microphoneCaptureFeature.showStatusPill(notice)
        } else if case .applied = outcome.refinement {
            let notice = "✨ Refined"
            statusText = notice
            microphoneCaptureFeature.showStatusPill(notice)
        } else {
            statusText = "Ready"
            microphoneCaptureFeature.clearStatusPill()
        }
    }

    /// The provider-reported usage of the just-completed paid request. Every
    /// field is a value the provider itself returned: the streaming socket has
    /// no documented usage object, so its monetary usage stays unavailable,
    /// and a missing batch monetary field is never estimated.
    private func providerReportedUsage(
        for outcome: DualProviderRoutingFeature.Outcome
    ) async -> ProviderReportedUsage {
        switch outcome.provider {
        case .deepgramStreaming:
            return ProviderReportedUsage(
                provider: .deepgramStreaming,
                requestReference: await deepgramStreamingIntegration.providerRequestID,
                providerReportedDurationSeconds: nil,
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: nil,
                providerReportedCostUSD: nil
            )
        case .openRouterBatch:
            let usage = await batchTranscriptionIntegration.lastUsage
            return ProviderReportedUsage(
                provider: .openRouterBatch,
                requestReference: await batchTranscriptionIntegration.lastGenerationID,
                providerReportedDurationSeconds: usage?.seconds,
                inputTokens: usage?.inputTokens,
                outputTokens: usage?.outputTokens,
                totalTokens: usage?.totalTokens,
                providerReportedCostUSD: Self.providerReportedCost(usage?.cost)
            )
        }
    }

    /// The provider-reported JSON cost recovered through its shortest exact
    /// decimal text, so the display reproduces the provider's value and never
    /// a client-side estimate.
    private static func providerReportedCost(_ cost: Double?) -> Decimal? {
        guard let cost, cost.isFinite else { return nil }
        return Decimal(string: String(cost), locale: Locale(identifier: "en_US_POSIX"))
    }

    /// The temporary recording file extension: both routes record the locked
    /// linear16 16 kHz mono PCM into the same canonical WAV container, so a
    /// retained or explicitly saved recording is a valid provider-supported
    /// file for either route.
    private static func temporaryAudioFileExtension(for route: TranscriptionRoute) -> String {
        switch route {
        case .deepgramStreaming, .openRouterBatch:
            return "wav"
        }
    }

    // MARK: Ordered audio frame hand-off

    /// Ordered hand-off of one converted locked-format frame. The single
    /// consumer below delivers frames to the selected route in exactly the
    /// capture order.
    private func enqueueAudioFrame(_ pcm: Data) {
        audioFrameContinuation?.yield(pcm)
    }

    private func startAudioFrameDelivery() {
        stopAudioFrameDelivery()
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        audioFrameContinuation = continuation
        audioFrameTask = Task { @MainActor [weak self] in
            for await frame in stream {
                await self?.deliverAudioFrame(frame)
            }
        }
    }

    /// Finishes the ordered stream without waiting; only the paths that must
    /// know every frame landed use the awaiting drain.
    private func stopAudioFrameDelivery() {
        audioFrameContinuation?.finish()
        audioFrameContinuation = nil
        audioFrameTask?.cancel()
        audioFrameTask = nil
    }

    private func drainAudioFrameDelivery() async {
        audioFrameContinuation?.finish()
        audioFrameContinuation = nil
        let task = audioFrameTask
        audioFrameTask = nil
        await task?.value
    }

    /// One frame is written once into the session's recording file — for both
    /// routes — and the explicitly selected streaming route additionally
    /// sends it live. A frame that cannot be stored ends the session honestly:
    /// a recording that silently loses audio is never transcribed or retained
    /// as if it were complete.
    private func deliverAudioFrame(_ pcm: Data) async {
        guard let session = activeSession, !session.cancelRequested else { return }
        guard let writer = recordingFileWriter else {
            await failActiveRecordingSession(
                session,
                message: "The recording audio could not be stored, so the recording was stopped without transcribing."
            )
            return
        }
        do {
            try writer.append(pcm)
        } catch {
            await failActiveRecordingSession(
                session,
                message: "The recording audio could not be stored, so the recording was stopped without transcribing."
            )
            return
        }
        if session.route == .deepgramStreaming {
            _ = await dualProviderRoutingFeature.sendAudio(pcm)
        }
    }

    // MARK: Temporary-audio outcome presentation and recovery controls

    /// The last temporary-audio cleanup outcome mirrored for presentation.
    /// Privacy-safe: verified absence, a retained-awaiting marker, or a
    /// privacy-safe failure message — never audio content, paths, or
    /// recording identifiers.
    private(set) var lastTemporaryAudioOutcome: AudioCaptureCleanupOutcome?

    /// Value-free temporary-audio feedback: the owner's last notice, or its
    /// privacy-safe failure message.
    private(set) var temporaryAudioFeedback: String?

    /// True while retained temporary audio awaits an explicit retry or an
    /// explicit provider switch (the owner's recovery window).
    var isTemporaryAudioRecoveryAwaitingExplicitAction: Bool {
        temporaryAudioCleanupFeature.retainsTemporaryAudioForExplicitRecovery
    }

    /// True while a cleanup that could not verify absence still needs the
    /// explicit retry action.
    var isTemporaryAudioCleanupPending: Bool {
        temporaryAudioCleanupFeature.pendingCleanupRecordingID != nil
    }

    /// True while the user can explicitly save or discard the retained
    /// recording; never while a recording session is in flight.
    var canActOnRetainedTemporaryRecording: Bool {
        !isRecordingSessionInFlight && temporaryAudioCleanupFeature.retainedRecordingID != nil
    }

    /// True while the temporary-audio recovery surface is relevant: retained
    /// audio awaits an explicit action, or a failed cleanup awaits its retry.
    var showsTemporaryAudioRecoveryControls: Bool {
        isTemporaryAudioRecoveryAwaitingExplicitAction || isTemporaryAudioCleanupPending
    }

    /// Records one temporary-audio outcome and mirrors the owner's
    /// privacy-safe notice or failure into the presented feedback.
    @discardableResult
    private func recordTemporaryAudioOutcome(_ outcome: AudioCaptureCleanupOutcome) -> AudioCaptureCleanupOutcome {
        lastTemporaryAudioOutcome = outcome
        syncTemporaryAudioPresentation()
        return outcome
    }

    /// Mirrors the temporary-audio owner's privacy-safe presentation: a
    /// failed state presents its privacy-safe message, every other state
    /// presents the owner's last notice. Never paths, identifiers, or audio.
    private func syncTemporaryAudioPresentation() {
        if case .failed(let failure) = temporaryAudioCleanupFeature.state {
            temporaryAudioFeedback = failure.message
        } else {
            temporaryAudioFeedback = temporaryAudioCleanupFeature.lastNotice
        }
    }

    /// The explicit user save of the retained recording: it moves the audio
    /// to the destination the injected chooser returns (the native save panel
    /// in production) and closes the recovery window with verified absence.
    /// A cancelled destination selection is neutral — the audio, the window,
    /// and every claim stay exactly as they were and its notice is presented
    /// as a notice, never as a failure — and a failed save is reported
    /// honestly without claiming anything.
    @discardableResult
    func saveTemporaryRecordingExplicitly() async -> Bool {
        guard !isRecordingSessionInFlight,
              let recordingID = temporaryAudioCleanupFeature.retainedRecordingID,
              let fileExtension = temporaryAudioCleanupFeature.recordingFileExtension else {
            temporaryAudioFeedback = "No retained recording is available to save; a recording is retained only after a recoverable provider failure while awaiting an explicit retry or an explicit provider switch."
            return false
        }
        let saved = await temporaryAudioCleanupFeature.saveRecordingExplicitly(
            recordingID: recordingID,
            fileExtension: fileExtension
        )
        if saved {
            syncTemporaryAudioPresentation()
        } else if temporaryAudioCleanupFeature.lastFailure?.category == .saveFailed {
            syncTemporaryAudioPresentation()
        } else {
            // The destination selection was cancelled: neutral, nothing
            // moved, and no failure is presented for it.
            temporaryAudioFeedback = temporaryAudioCleanupFeature.lastNotice
        }
        return saved
    }

    /// The explicit user discard of the retained recording: it deletes the
    /// audio with verified absence and closes the recovery window.
    @discardableResult
    func discardTemporaryRecordingExplicitly() async -> Bool {
        guard !isRecordingSessionInFlight,
              let recordingID = temporaryAudioCleanupFeature.retainedRecordingID else {
            temporaryAudioFeedback = "No retained recording is available to discard; a recording is retained only after a recoverable provider failure while awaiting an explicit retry or an explicit provider switch."
            return false
        }
        let outcome = await temporaryAudioCleanupFeature.discardExplicitly(recordingID: recordingID)
        recordTemporaryAudioOutcome(outcome)
        return outcome == .verifiedAbsence
    }

    /// The explicit user retry of a cleanup that could not verify absence;
    /// success is claimed only when absence is actually verified.
    @discardableResult
    func retryTemporaryAudioCleanupExplicitly() async -> Bool {
        let outcome = await temporaryAudioCleanupFeature.retryPendingCleanup()
        recordTemporaryAudioOutcome(outcome)
        return outcome == .verifiedAbsence
    }

    // MARK: In-app recording controls (user-facing record/stop/cancel)

    /// The in-app record control. It runs the same one session state machine
    /// the global shortcut runs (paid-request gate, temporary audio, insertion
    /// target, selected route, capture) and returns only after the attempt has
    /// settled, so a fresh install can dictate from the menu or Settings
    /// without any shortcut being configured.
    @discardableResult
    func startInAppRecording(mode: HotkeyMode? = nil) async -> Bool {
        guard !isRecordingSessionInFlight else { return false }
        let effectiveMode = mode ?? inAppRecordingMode
        guard globalHotkeysFeature.beginInAppRecording(mode: effectiveMode) else { return false }
        await settleSessionAction()
        return isRecordingSessionActive
    }

    /// The in-app stop control: it ends the session exactly like the matching
    /// shortcut and returns after the completion pipeline settled. The
    /// authoritative session — an attempt still in its start window as well
    /// as an active recording — takes the stop directly, so the control is
    /// never a no-op just because the shortcut state machine already reached
    /// a terminal state; the shortcut is informed first so both views agree.
    @discardableResult
    func stopInAppRecording() async -> Bool {
        guard isRecordingSessionInFlight else { return false }
        _ = globalHotkeysFeature.finishInAppRecording()
        await finishRecordingSession(reason: .userRelease)
        await settleSessionAction()
        return !isRecordingSessionInFlight
    }

    /// The in-app cancel control: the paid request ends as cancelled, late
    /// results are discarded, and the temporary audio is deleted with verified
    /// absence. Like the stop control it acts on the authoritative session
    /// regardless of the shortcut state machine's state.
    @discardableResult
    func cancelInAppRecording() async -> Bool {
        guard isRecordingSessionInFlight else { return false }
        globalHotkeysFeature.cancelRecording()
        await finishRecordingSession(reason: .cancelled)
        await settleSessionAction()
        return !isRecordingSessionInFlight
    }

    /// Awaits the one session action the emitted signal started and the
    /// in-flight start attempt, so an in-app or HUD control reflects the
    /// settled session state instead of racing it. The start attempt is joined
    /// explicitly because a stop that arrives during the start window is
    /// honored by the start sequence at its next checkpoint, which happens
    /// after the stop action itself has already returned.
    ///
    /// Both slots are only ever filled with tasks created by the shortcut
    /// handler and the controls, and none of those bodies calls a control, so
    /// a settle can never await the task that is running it (a task awaiting
    /// itself would deadlock). The start sequence never awaits a stop or
    /// cancel action, so joining both slots is acyclic.
    private func settleSessionAction() async {
        if let task = sessionActionTask {
            await task.value
        }
        if let task = sessionStartingTask {
            await task.value
        }
    }

    // MARK: Floating HUD control routing (composition owns the session machine)

    /// The floating HUD's instant Stop control. It ends the active session
    /// through the composition root's one authoritative session flow — the
    /// same flow the matching shortcut and the in-app Stop control run
    /// (capture release, ordered frame drain, stream finalize or batch
    /// transcription, cost completion, history, paste, verified cleanup) — so
    /// the HUD can never change capture state alone. Without an active
    /// session the control is a no-op.
    private func handleHudStopControl() async {
        _ = await stopInAppRecording()
    }

    /// The floating HUD's instant Cancel control. It runs the composition
    /// root's one authoritative cancel path — the same path the matching
    /// shortcut and the in-app Cancel control run (route cancellation,
    /// paid-request cancellation, temporary audio deleted with verified
    /// absence) — so a HUD cancel ends cost and cleanup, not only capture.
    private func handleHudCancelControl() async {
        _ = await cancelInAppRecording()
    }

    // MARK: Interim streaming text (presentation only)

    /// Mirrors the active streaming route's interim text into the capture
    /// feature's HUD and the menu presentation. Interim text is never an
    /// insertion or persistence candidate, and every terminal path clears it
    /// on both surfaces.
    private func syncInterimTranscript() {
        let interim = dualProviderRoutingFeature.interimTranscript
        if interimTranscript != interim {
            interimTranscript = interim
        }
        if microphoneCaptureFeature.interimTranscript != interim {
            microphoneCaptureFeature.updateInterimTranscript(interim)
        }
    }

    // MARK: Provider selection (wired atomically to both owners)

    /// The one provider-picker action. It applies the explicit selection to
    /// both CON-DATA-PROVIDER-PREFERENCE owners in one fail-safe transaction —
    /// the cost-protection gate and the dual-provider routing feature — and
    /// succeeds only when both owners agree, so the two views and the stored
    /// preference can never drift: if the second owner rejects the change, the
    /// first owner is rolled back to the last agreed selection. The selection
    /// is locked while a recording session is in flight — starting or active
    /// (ACC-PROVIDER-SELECTION-AND-COST-PROTECTION-04: the provider changes
    /// only between recordings).
    @discardableResult
    func selectProvider(_ provider: TranscriptionProviderID?) async -> Bool {
        guard !isRecordingSessionInFlight else {
            providerFeedback = "The provider selection is locked while a recording is in flight — starting or active. Stop or cancel the recording, then change the provider between recordings."
            lastErrorMessage = providerFeedback
            syncProviderPresentation()
            return false
        }
        let lastAgreedSelection = providerSelectionAndCostProtectionFeature.selectedProvider
        guard await providerSelectionAndCostProtectionFeature.selectProvider(provider) else {
            providerFeedback = providerSelectionAndCostProtectionFeature.lastFailure?.message
            lastErrorMessage = providerFeedback
            syncProviderPresentation()
            return false
        }
        guard await dualProviderRoutingFeature.selectProvider(provider) else {
            // The second owner rejected the change: roll the cost gate back to
            // the last agreed selection so nothing half-applied is left behind
            // and the stored preference agrees with both owners again.
            _ = await providerSelectionAndCostProtectionFeature.selectProvider(lastAgreedSelection)
            providerFeedback = "The provider selection could not be applied to both owners, so it was rolled back to the last agreed selection; the stored preference is unchanged."
            lastErrorMessage = providerFeedback
            syncProviderPresentation()
            return false
        }
        lastErrorMessage = nil
        syncProviderPresentation()
        if let provider {
            providerFeedback = "\(provider.displayName) is the explicitly selected provider for this and future recordings."
        } else {
            providerFeedback = "The provider selection was cleared; recording stays blocked until you select a provider explicitly."
        }
        return true
    }

    /// Mirrors the two selection owners into the presented summary. A drift is
    /// surfaced explicitly instead of hidden; selecting a provider re-joins them.
    private func syncProviderPresentation() {
        let costSelection = providerSelectionAndCostProtectionFeature.selectedProvider
        let routingSelection = dualProviderRoutingFeature.selectedProvider
        switch (costSelection, routingSelection) {
        case (nil, nil):
            selectedProvider = nil
            providerSummary = "No provider selected — recording is blocked until you choose one."
        case (let cost?, let routing?) where cost == routing:
            selectedProvider = cost
            providerSummary = "\(cost.displayName) is selected for both the cost gate and the routing owner."
        case (let cost, let routing):
            selectedProvider = cost
            let costName = cost?.displayName ?? "none"
            let routingName = routing?.displayName ?? "none"
            providerSummary = "The provider selection drifted (cost gate: \(costName), routing: \(routingName)). Select a provider explicitly to re-join both owners."
        }
    }

    // MARK: Credential entry, save, delete, and test (value-free presentation)

    /// Explicit user action: stores or atomically replaces one API key. The
    /// entered value is handed to the vault once and is never read back into any
    /// presented state; only a value-free status and a value-free notice remain.
    @discardableResult
    func saveCredential(_ value: String, for key: CredentialKey) async -> Bool {
        let saved = await credentialVaultFeature.save(value, for: key)
        credentialFeedback = saved
            ? credentialVaultFeature.lastNotice
            : credentialVaultFeature.lastFailure?.message
        await refreshCredentialStatuses()
        if saved {
            lastErrorMessage = nil
        }
        return saved
    }

    /// Explicit user action: removes one stored API key after the Keychain
    /// confirms the deletion.
    @discardableResult
    func deleteCredential(for key: CredentialKey) async -> Bool {
        let deleted = await credentialVaultFeature.delete(key)
        credentialFeedback = deleted
            ? credentialVaultFeature.lastNotice
            : credentialVaultFeature.lastFailure?.message
        await refreshCredentialStatuses()
        return deleted
    }

    /// Explicit user action: verifies a stored credential through the
    /// provider's documented no-audio connection test. It never exposes the
    /// stored value and never stores a new one.
    @discardableResult
    func testCredentialConnection(for key: CredentialKey) async -> CredentialConnectionOutcome {
        let outcome = await credentialVaultFeature.testConnection(for: key)
        switch outcome {
        case .verified(let requestID):
            credentialFeedback = requestID.map { "The \(key.displayName) connection was verified (provider request \($0))." }
                ?? "The \(key.displayName) connection was verified."
        case .missingCredential:
            credentialFeedback = "No \(key.displayName) API key is stored yet; add one and test again."
        case .failed(let message):
            credentialFeedback = message
        case .notAvailable(let message):
            credentialFeedback = message
        }
        await refreshCredentialStatuses()
        return outcome
    }

    // MARK: Hotkey setup, safe defaults, and conflict recovery

    /// Carbon modifier flags of the locked provider-neutral hotkey value.
    static let commandModifier: UInt32 = 256
    static let shiftModifier: UInt32 = 512
    static let optionModifier: UInt32 = 2048
    static let controlModifier: UInt32 = 4096
    static let hyperModifier: UInt32 = controlModifier | optionModifier | shiftModifier | commandModifier

    /// The deterministic safe default a fresh install can apply in one action:
    /// control+option plus two distinct keys, so the combination can never
    /// capture normal typing and the two roles can never duplicate each other.
    static let safeDefaultHotkeyConfiguration = HotkeyConfiguration(
        pushToTalk: HotkeyIdentifier(keyCode: 2, modifiers: controlModifier | optionModifier),
        toggle: HotkeyIdentifier(keyCode: 17, modifiers: controlModifier | optionModifier)
    )

    /// Karabiner Hyperkey preset (Control + Option + Shift + Command):
    /// Hyper+D for push-to-talk, Hyper+T for toggle.
    static let karabinerHyperkeyConfiguration = HotkeyConfiguration(
        pushToTalk: HotkeyIdentifier(keyCode: 2, modifiers: hyperModifier),
        toggle: HotkeyIdentifier(keyCode: 17, modifiers: hyperModifier)
    )

    /// The editable key choices of the shortcut editor: Carbon virtual key
    /// codes, deterministic and provider-neutral.
    static let editableHotkeyKeys: [(name: String, keyCode: UInt32)] = [
        ("A", 0), ("B", 11), ("C", 8), ("D", 2), ("E", 14), ("F", 3), ("G", 5),
        ("H", 4), ("I", 34), ("J", 38), ("K", 40), ("L", 37), ("M", 46), ("N", 45),
        ("O", 31), ("P", 35), ("Q", 12), ("R", 15), ("S", 1), ("T", 17), ("U", 32),
        ("V", 9), ("W", 13), ("X", 7), ("Y", 16), ("Z", 6),
        ("0", 29), ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("5", 23), ("6", 22),
        ("7", 26), ("8", 28), ("9", 25),
        ("Space", 49), ("Return", 36), ("Tab", 48), ("Escape", 53),
        ("F1", 122), ("F2", 120), ("F3", 99), ("F4", 118), ("F5", 96), ("F6", 97),
        ("F7", 98), ("F8", 100), ("F9", 101), ("F10", 109), ("F11", 103), ("F12", 111)
    ]

    /// The presented form of one shortcut, e.g. `⌃⌥D`. An empty configuration
    /// reads as `not set`.
    static func describeHotkey(_ identifier: HotkeyIdentifier?) -> String {
        guard let identifier else { return "not set" }
        var text = ""
        if identifier.modifiers & controlModifier != 0 { text += "⌃" }
        if identifier.modifiers & optionModifier != 0 { text += "⌥" }
        if identifier.modifiers & shiftModifier != 0 { text += "⇧" }
        if identifier.modifiers & commandModifier != 0 { text += "⌘" }
        let key = editableHotkeyKeys.first { $0.keyCode == identifier.keyCode }?.name
        return text + (key ?? "key \(identifier.keyCode)")
    }

    /// The presented form of one shortcut configuration.
    static func describeHotkeys(_ configuration: HotkeyConfiguration) -> String {
        "Push-to-talk \(describeHotkey(configuration.pushToTalk)) · Toggle \(describeHotkey(configuration.toggle))"
    }

    /// Explicit user action: registers the edited configuration and persists it
    /// only after registration succeeded. A conflict, an unchanged duplicate, or
    /// an invalid value leaves the previous shortcuts and the stored
    /// configuration untouched, and recovery is this same explicit action again.
    @discardableResult
    func applyHotkeyConfiguration(_ configuration: HotkeyConfiguration) async -> Bool {
        switch globalHotkeysFeature.configure(configuration) {
        case .registered(let registered):
            await dataStore.setHotkeyConfiguration(registered)
            hotkeyConfiguration = registered
            hotkeyFeedback = "The dictation shortcuts are registered: \(Self.describeHotkeys(registered))."
            lastErrorMessage = nil
            syncHotkeyPresentation()
            return true
        case .rejected(let failure):
            hotkeyFeedback = failure.message
            lastErrorMessage = failure.message
            syncHotkeyPresentation()
            return false
        }
    }

    /// Explicit user action: applies the deterministic safe default
    /// configuration through the same registration and persistence path.
    @discardableResult
    func useSafeDefaultHotkeys() async -> Bool {
        await applyHotkeyConfiguration(Self.safeDefaultHotkeyConfiguration)
    }

    /// Explicit user action: applies the Karabiner Hyperkey configuration
    /// (⌃⌥⇧⌘D for push-to-talk, ⌃⌥⇧⌘T for toggle).
    @discardableResult
    func useKarabinerHyperkeyPreset() async -> Bool {
        await applyHotkeyConfiguration(Self.karabinerHyperkeyConfiguration)
    }

    /// Explicit user action: configures whether the Fn (Globe) key is used for push-to-talk.
    func setUseFnKeyForPushToTalk(_ enabled: Bool) async {
        useFnKeyForPushToTalk = enabled
        await dataStore.setUseFnKeyForPushToTalk(enabled)
    }

    /// Explicit user action: configures whether to restore previous clipboard after auto-paste.
    func setRestoreClipboardAfterPaste(_ restore: Bool) async {
        restoreClipboardAfterPaste = restore
        pasteCoordinator.restoreClipboard = restore
        await dataStore.setRestoreClipboardAfterPaste(restore)
    }

    // MARK: - TypeSafe Jev Intelligence settings

    func setJevEnabled(_ enabled: Bool) async {
        jevEnabled = enabled
        dualProviderRoutingFeature.setJevEnabled(enabled)
        await dataStore.setJevEnabled(enabled)
    }

    func setJevSmartRefinementGateEnabled(_ enabled: Bool) async {
        jevSmartRefinementGateEnabled = enabled
        dualProviderRoutingFeature.setJevSmartRefinementGateEnabled(enabled)
        await dataStore.setJevSmartRefinementGateEnabled(enabled)
    }

    func setJevAutoWritingModeEnabled(_ enabled: Bool) async {
        jevAutoWritingModeEnabled = enabled
        dualProviderRoutingFeature.setJevAutoWritingModeEnabled(enabled)
        await dataStore.setJevAutoWritingModeEnabled(enabled)
    }

    func setJevHallucinationGuardrailEnabled(_ enabled: Bool) async {
        jevHallucinationGuardrailEnabled = enabled
        dualProviderRoutingFeature.setJevHallucinationGuardrailEnabled(enabled)
        await dataStore.setJevHallucinationGuardrailEnabled(enabled)
    }

    func refreshTypesafeKeyStatus() async {
        typesafeKeyStatus = await credentialVault.typesafeKeyStatus()
    }

    // MARK: - Fn (Globe) Key Listener (Push-to-Talk)

    func setupFlagsMonitor() {
        stopFlagsMonitoring()
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleFlagsChanged(event: event)
            }
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleFlagsChanged(event: event)
            }
            return event
        }
    }

    func stopFlagsMonitoring() {
        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
            flagsMonitor = nil
        }
        if let local = localFlagsMonitor {
            NSEvent.removeMonitor(local)
            localFlagsMonitor = nil
        }
    }

    private func handleFlagsChanged(event: NSEvent) {
        guard useFnKeyForPushToTalk else { return }
        let isFnEvent = event.keyCode == 63 || event.modifierFlags.contains(.function)
        guard isFnEvent else { return }

        let fnPressed = event.modifierFlags.contains(.function)
        if fnPressed && !isFnKeyDown {
            isFnKeyDown = true
            isFnRecordingActive = true
            Task { @MainActor [weak self] in
                _ = await self?.startInAppRecording(mode: .pushToTalk)
            }
        } else if !fnPressed && isFnKeyDown {
            isFnKeyDown = false
            if isFnRecordingActive {
                isFnRecordingActive = false
                Task { @MainActor [weak self] in
                    _ = await self?.stopInAppRecording()
                }
            }
        }
    }

    /// Explicit user action: retries the last attempted configuration after a
    /// conflict (CON-GLOBAL-HOTKEYS-AND-PUSH-TO-TALK-TOGGLE-MODES-RECOVERY). A
    /// retry that registers persists exactly like an explicit apply.
    @discardableResult
    func retryHotkeyRegistration() async -> Bool {
        switch globalHotkeysFeature.retryRegistration() {
        case .registered(let registered):
            await dataStore.setHotkeyConfiguration(registered)
            hotkeyConfiguration = registered
            hotkeyFeedback = "The dictation shortcuts are registered: \(Self.describeHotkeys(registered))."
            lastErrorMessage = nil
            syncHotkeyPresentation()
            return true
        case .rejected(let failure):
            hotkeyFeedback = failure.message
            lastErrorMessage = failure.message
            syncHotkeyPresentation()
            return false
        }
    }

    /// Reads the stored shortcut configuration into the presented editor state.
    func loadHotkeyConfiguration() async {
        hotkeyConfiguration = await dataStore.hotkeyConfiguration()
        syncHotkeyPresentation()
    }

    /// Mirrors the active registration and the stored configuration.
    private func syncHotkeyPresentation() {
        switch globalHotkeysFeature.registrationState {
        case .unregistered:
            hotkeyRegistrationSummary = "No dictation shortcut is registered; the in-app controls still record."
        case .registered(let registered):
            hotkeyRegistrationSummary = "Registered: \(Self.describeHotkeys(registered))."
        }
        if hotkeyConfiguration.isEmpty {
            hotkeyConfiguration = globalHotkeysFeature.lastValidConfiguration
        }
    }

    // MARK: Writing modes and vocabulary

    /// Explicit user action: saves or replaces one writing mode. An invalid
    /// mode is rejected by the owner before any write and nothing changes.
    @discardableResult
    func saveWritingMode(
        id: String?,
        name: String,
        instructions: String,
        isDefault: Bool
    ) async -> Bool {
        let mode = WritingMode(
            id: id ?? UUID().uuidString,
            name: name,
            instructions: instructions,
            isDefault: isDefault
        )
        let saved = await customWritingFeature.saveMode(mode)
        writingFeedback = saved
            ? customWritingFeature.lastNotice
            : customWritingFeature.lastFailure?.message
        syncWritingPresentation()
        return saved
    }

    /// Explicit user action: deletes one writing mode. Deleting the active mode
    /// falls back to the stored default mode or the locked default behavior.
    @discardableResult
    func deleteWritingMode(id: String) async -> Bool {
        let deleted = await customWritingFeature.deleteMode(id: id)
        writingFeedback = deleted
            ? customWritingFeature.lastNotice
            : customWritingFeature.lastFailure?.message
        syncWritingPresentation()
        return deleted
    }

    /// Explicit selection of the writing mode the next recording applies.
    @discardableResult
    func selectWritingMode(id: String?) -> Bool {
        let selected = customWritingFeature.selectMode(id: id)
        writingFeedback = selected
            ? customWritingFeature.lastNotice
            : customWritingFeature.lastFailure?.message
        syncWritingPresentation()
        return selected
    }

    /// Explicit user action: adds one validated vocabulary term.
    @discardableResult
    func addVocabularyTerm(_ term: String) async -> Bool {
        let added = await customWritingFeature.addVocabularyTerm(term)
        writingFeedback = added
            ? customWritingFeature.lastNotice
            : customWritingFeature.lastFailure?.message
        syncWritingPresentation()
        return added
    }

    /// Explicit user action: removes one vocabulary term.
    @discardableResult
    func removeVocabularyTerm(id: String) async -> Bool {
        let removed = await customWritingFeature.removeVocabularyTerm(id: id)
        writingFeedback = removed
            ? customWritingFeature.lastNotice
            : customWritingFeature.lastFailure?.message
        syncWritingPresentation()
        return removed
    }

    /// Explicit user retry of the stored writing-mode and vocabulary load.
    @discardableResult
    func reloadWritingConfiguration() async -> Bool {
        let loaded = await customWritingFeature.retry()
        writingFeedback = loaded
            ? customWritingFeature.lastNotice
            : customWritingFeature.lastFailure?.message
        syncWritingPresentation()
        return loaded
    }

    private func syncWritingPresentation() {
        writingModes = customWritingFeature.modes
        vocabularyTerms = customWritingFeature.vocabularyTerms
        selectedWritingModeID = customWritingFeature.activeModeID
    }

    // MARK: Local history: search, copy, and delete

    /// Explicit user retry of the bounded local history load.
    @discardableResult
    func reloadHistory() async -> Bool {
        let loaded = await localHistoryFeature.retry()
        historyFeedback = loaded
            ? localHistoryFeature.lastNotice
            : localHistoryFeature.lastFailure?.message
        syncHistoryPresentation()
        return loaded
    }

    /// Offline full-text search through local storage only. An empty query
    /// returns the bounded recent list again.
    @discardableResult
    func searchHistory(_ query: String) async -> Bool {
        historyQuery = query
        let searched = await localHistoryFeature.search(query)
        historyFeedback = searched
            ? localHistoryFeature.lastNotice
            : localHistoryFeature.lastFailure?.message
        syncHistoryPresentation()
        return searched
    }

    /// Explicit user copy of one complete transcript.
    @discardableResult
    func copyHistoryEntry(id: String) -> Bool {
        let copied = localHistoryFeature.copy(id: id)
        historyFeedback = copied
            ? localHistoryFeature.lastNotice
            : localHistoryFeature.lastFailure?.message
        syncHistoryPresentation()
        return copied
    }

    /// Explicit user delete of one transcript, reported only after the durable
    /// state confirms the absence.
    @discardableResult
    func deleteHistoryEntry(id: String) async -> Bool {
        let deleted = await localHistoryFeature.delete(id: id)
        historyFeedback = deleted
            ? localHistoryFeature.lastNotice
            : localHistoryFeature.lastFailure?.message
        syncHistoryPresentation()
        return deleted
    }

    private func syncHistoryPresentation() {
        historyTranscripts = localHistoryFeature.transcripts
    }

    // MARK: Paste mode, preview approval, and recovery

    /// Explicit configuration of the insertion mode.
    func setPasteMode(_ mode: PasteMode) {
        pasteCoordinator.configure(mode: mode)
        pasteFeedback = "Insertion mode set to \(Self.describe(pasteMode: mode))."
        syncPastePresentation(notice: nil)
    }

    /// The presented form of one insertion mode.
    static func describe(pasteMode: PasteMode) -> String {
        switch pasteMode {
        case .autoPaste: return "auto-paste"
        case .copyOnly: return "copy-only"
        case .preview: return "preview"
        }
    }

    /// Step 14: explicit approval of the waiting preview. Nothing was inserted
    /// before this action.
    @discardableResult
    func approvePastePreview() async -> Bool {
        let approved = await pasteCoordinator.approvePreview()
        pasteFeedback = approved ? pasteCoordinator.lastNotice : pasteCoordinator.lastFailure?.message
        syncPastePresentation(notice: nil)
        return approved
    }

    /// Step 14: explicit cancellation of the waiting preview. The complete
    /// transcript is preserved.
    @discardableResult
    func cancelPastePreview() -> Bool {
        let cancelled = pasteCoordinator.cancelPreview()
        pasteFeedback = cancelled ? pasteCoordinator.lastNotice : pasteCoordinator.lastFailure?.message
        syncPastePresentation(notice: nil)
        return cancelled
    }

    /// Step 13: explicit copy of the retained complete transcript.
    @discardableResult
    func copyRetainedPasteText() -> Bool {
        let copied = pasteCoordinator.copyRetainedTranscript()
        pasteFeedback = copied ? pasteCoordinator.lastNotice : pasteCoordinator.lastFailure?.message
        syncPastePresentation(notice: nil)
        return copied
    }

    /// Step 13: explicit retry of a failed insertion with a freshly captured
    /// target.
    @discardableResult
    func retryPasteInsertion() async -> Bool {
        let retried = await pasteCoordinator.retryInsertion()
        pasteFeedback = retried ? pasteCoordinator.lastNotice : pasteCoordinator.lastFailure?.message
        syncPastePresentation(notice: nil)
        return retried
    }

    /// Mirrors the paste owner's presentation values.
    private func syncPastePresentation(notice: String?) {
        pasteMode = pasteCoordinator.mode
        isPreviewAwaitingApproval = pasteCoordinator.isAwaitingPreviewApproval
        pendingPreviewText = pasteCoordinator.pendingPreviewText
        retainedPasteText = pasteCoordinator.retainedTranscriptText
        if let notice {
            pasteFeedback = notice
        }
    }

    // MARK: Optional refinement

    /// The explicit refinement toggle. Refinement stays off until it is
    /// explicitly enabled, and a disabled refinement never fails a recording.
    @discardableResult
    func setRefinementEnabled(_ enabled: Bool) async -> Bool {
        await refinementIntegration.setEnabled(enabled)
        await refreshRefinementPresentation()
        refinementFeedback = enabled
            ? "Optional refinement is enabled; it runs only after a successful transcription."
            : "Optional refinement is off; the accepted transcription is used unchanged."
        return true
    }

    /// Mirrors the refinement owner's explicit enabled flag.
    func refreshRefinementPresentation() async {
        refinementEnabled = await refinementIntegration.isEnabled
        if refinementFeedback == nil {
            refinementFeedback = refinementEnabled
                ? "Optional refinement is enabled; it runs only after a successful transcription."
                : "Optional refinement is off; the accepted transcription is used unchanged."
        }
    }

    // MARK: Permissions and launch at login

    /// Explicit user action: re-reads every permission and status value. Every
    /// read is read-only, so no prompt is raised and nothing privileged starts.
    func refreshPermissionStates() async {
        var updated: [PermissionDomain: PermissionState] = [:]
        for domain in PermissionDomain.allCases {
            updated[domain] = await permissionCoordinator.refresh(domain)
        }
        permissionStates = updated
        launchAtLoginStatus = lifecycleCoordinator.launchAtLoginStatus
        permissionFeedback = "Permission and status values were re-read; nothing was prompted."
    }

    /// Explicit user action: the one path that may raise a system prompt for a
    /// domain that supports one. A denial keeps the documented manual path.
    @discardableResult
    func requestPermission(_ domain: PermissionDomain) async -> PermissionState {
        let state = await permissionCoordinator.request(domain)
        permissionStates[domain] = state
        if let guidance = permissionCoordinator.recoveryGuidance(for: domain) {
            permissionFeedback = guidance
        } else if let manual = permissionCoordinator.manualPathDescription(for: domain) {
            permissionFeedback = "\(domain.displayName): \(Self.describe(permissionState: state)). \(manual)"
        } else {
            permissionFeedback = "\(domain.displayName): \(Self.describe(permissionState: state))."
        }
        return state
    }

    /// The actionable guidance for a domain that is not authorized, when any.
    func permissionGuidance(for domain: PermissionDomain) -> String? {
        permissionCoordinator.recoveryGuidance(for: domain)
    }

    /// The documented manual path of a denied domain, when any.
    func permissionManualPath(for domain: PermissionDomain) -> String? {
        permissionCoordinator.manualPathDescription(for: domain)
    }

    /// The presented form of one permission state.
    static func describe(permissionState: PermissionState) -> String {
        switch permissionState {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not determined yet"
        case .unavailable: return "unavailable"
        }
    }

    /// The presented form of the login-item status.
    static func describe(loginItemStatus: LoginItemStatus) -> String {
        switch loginItemStatus {
        case .enabled: return "enabled"
        case .notRegistered: return "not registered"
        case .requiresApproval: return "waiting for approval in System Settings"
        case .notFound: return "unavailable for this build"
        }
    }

    /// The explicit launch-at-login toggle (CON-PERMISSION-BACKGROUND-STARTUP).
    /// Denial leaves manual launch available and is reported honestly.
    @discardableResult
    func setLaunchAtLogin(_ enabled: Bool) async -> Bool {
        do {
            try lifecycleCoordinator.setLaunchAtLogin(enabled: enabled)
        } catch LoginItemError.requiresApproval {
            launchAtLoginStatus = lifecycleCoordinator.launchAtLoginStatus
            launchAtLoginFeedback = "Launch at login needs approval in System Settings → General → Login Items. Manual launch remains available."
            lastErrorMessage = launchAtLoginFeedback
            return false
        } catch {
            launchAtLoginStatus = lifecycleCoordinator.launchAtLoginStatus
            launchAtLoginFeedback = "The launch-at-login setting could not be changed. Manual launch remains available."
            lastErrorMessage = launchAtLoginFeedback
            return false
        }
        launchAtLoginStatus = lifecycleCoordinator.launchAtLoginStatus
        launchAtLoginFeedback = enabled
            ? "WhisperBar starts at login."
            : "WhisperBar no longer starts at login."
        lastErrorMessage = nil
        return true
    }

    // MARK: Credential presentation (PHASE-02)

    /// Explicit user action only: refreshes the value-free credential status
    /// map. Missing credentials block provider use with a clear message.
    func refreshCredentialStatuses() async {
        var updated: [CredentialKey: CredentialStatus] = [:]
        for key in CredentialKey.allCases {
            updated[key] = await credentialVault.status(for: key)
        }
        credentialStatuses = updated
        await refreshTypesafeKeyStatus()
    }

    func credentialBlockingMessage(for key: CredentialKey) -> String? {
        CredentialVault.blockingMessage(for: key, status: credentialStatuses[key] ?? .missing)
    }

    // MARK: Local storage presentation (PHASE-03)

    /// Explicit refresh of the value-free storage summary.
    func refreshStorageSummary() async {
        switch await dataStore.availability {
        case .available:
            let count = (try? await dataStore.transcriptCount()) ?? 0
            storageSummary = "Local history available (\(count) saved)"
        case .unavailable:
            storageSummary = "Local history unavailable — transcription still works"
        }
    }

    // MARK: Global hotkey presentation (PHASE-06)

    /// Explicit user action: reload the stored hotkey configuration and
    /// re-register the global shortcuts. Conflicts surface as a clear message
    /// while the previous shortcuts stay active.
    func reloadHotkeyConfiguration() async {
        let configuration = await dataStore.hotkeyConfiguration()
        switch globalHotkeysFeature.configure(configuration) {
        case .registered:
            lastErrorMessage = nil
            hotkeyFeedback = "The stored dictation shortcuts are registered: \(Self.describeHotkeys(configuration))."
        case .rejected(let failure):
            lastErrorMessage = failure.message
            hotkeyFeedback = failure.message
        }
        syncHotkeyPresentation()
    }

    // MARK: Paste and clipboard preservation (PHASE-15)

    /// Composition hand-off: exactly one successfully completed route outcome
    /// enters the paste workflow as exactly one insertion candidate
    /// (CON-PASTE-WORKFLOW step 2). The refined text is offered only when
    /// refinement succeeded; otherwise the accepted final raw transcript is.
    /// Never called from init or launch.
    @discardableResult
    func insertCompletedTranscription(_ outcome: DualProviderRoutingFeature.Outcome) async -> Bool {
        guard outcome.candidateText != nil else {
            return false
        }
        // PHASE-17: accepted success deletes this recording's temporary audio
        // with verified absence before any insertion workflow begins.
        if let recordingID = temporaryAudioCleanupFeature.activeRecordingID {
            recordTemporaryAudioOutcome(await temporaryAudioCleanupFeature.acceptSuccess(recordingID: recordingID))
        }
        let completed: CompletedTranscription
        switch outcome.refinement {
        case .applied(let text):
            completed = .succeeded(finalTranscript: outcome.rawTranscript, refinedText: text)
        case .notConfigured, .failed, .bypassedCleanSpeech, .hallucinationIgnored:
            completed = .succeeded(finalTranscript: outcome.rawTranscript, refinedText: nil)
        }
        let inserted = await pasteCoordinator.requestInsertion(from: completed)
        if !inserted && pasteCoordinator.mode != .preview {
            _ = pasteCoordinator.copyRetainedTranscript()
        }
        return inserted
    }

    // MARK: View builders (kept here so later phases never touch App/Settings files)

    func settingsView() -> some View {
        SettingsRoot(controller: self)
    }

    // MARK: - Menu Bar Status Item & Screen / Notch Lifecycle

    private var screenChangeObserver: (any NSObjectProtocol)?

    func setupScreenChangeObserver() {
        stopScreenChangeObserver()
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleScreenParametersChanged()
            }
        }
    }

    func stopScreenChangeObserver() {
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            screenChangeObserver = nil
        }
    }

    func handleScreenParametersChanged() {
        updateMenuBarIcon()
    }

    /// Whether any connected screen features a display cutout / notch.
    var hasNotchScreen: Bool {
        NSScreen.screens.contains { screen in
            screen.auxiliaryTopLeftArea != nil || screen.auxiliaryTopRightArea != nil
        }
    }

    /// Update status item icon symbol ensuring crispness and responsive visual state.
    func updateMenuBarIcon() {
        if isRecordingSessionActive {
            menuBarSystemImageName = "waveform.circle.fill"
        } else if statusText.contains("Refining") {
            menuBarSystemImageName = "sparkles"
        } else if statusText.contains("blocked") || statusText.contains("failed") {
            menuBarSystemImageName = "waveform.slash"
        } else {
            menuBarSystemImageName = "waveform"
        }
    }

    // MARK: - Window Activation & Presentation Lifecycle

    private var mainWindowController: NSWindowController?

    /// Elevate activation policy to `.regular` and ensure standard menu bar shortcuts exist.
    func elevateToRegularPolicy() {
        lifecycleCoordinator.transitionToRegular()
        setupApplicationMenuIfNeeded()
    }

    func openMainWindow() {
        elevateToRegularPolicy()

        if let window = mainWindowController?.window {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.center()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "WhisperBar Settings"
        window.tabbingMode = .disallowed
        window.center()
        SettingsWindowDelegate.shared.controller = self
        window.delegate = SettingsWindowDelegate.shared
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SettingsWindow(controller: self))
        let wc = NSWindowController(window: window)
        mainWindowController = wc
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func closeMainWindow() {
        guard let window = mainWindowController?.window else { return }
        window.close()
    }

    func handleWindowWillClose(_ notification: Notification) {
        let closingWindow = notification.object as? NSWindow
        let hasOtherVisibleRegularWindows = NSApplication.shared.windows.contains { window in
            guard window != closingWindow else { return false }
            guard window.isVisible && !window.isFloatingPanel && !(window is NSPanel) else { return false }
            return true
        }

        if !hasOtherVisibleRegularWindows && !keepDockIconVisible {
            lifecycleCoordinator.transitionToAccessory()
        }
    }

    func buildDockMenu() -> NSMenu {
        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(dockMenuOpenSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())
        let toggleItem = NSMenuItem(title: "Toggle Dictation", action: #selector(dockMenuToggleDictation), keyEquivalent: "d")
        toggleItem.target = self
        menu.addItem(toggleItem)
        return menu
    }

    @objc func dockMenuOpenSettings() {
        openMainWindow()
    }

    @objc func dockMenuToggleDictation() {
        Task { @MainActor in
            if self.isRecordingSessionActive {
                _ = await self.stopInAppRecording()
            } else {
                _ = await self.startInAppRecording()
            }
        }
    }

    private func setupApplicationMenuIfNeeded() {
        let app = NSApplication.shared
        guard app.mainMenu == nil || app.mainMenu?.items.isEmpty == true else { return }

        let mainMenu = NSMenu()

        // Application Menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(AppIdentity.appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide \(AppIdentity.appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit \(AppIdentity.appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit Menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(redoItem)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Window Menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        app.mainMenu = mainMenu
    }
}

@MainActor
final class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowDelegate()
    weak var controller: MenuBarController?

    func windowWillClose(_ notification: Notification) {
        if let controller {
            controller.handleWindowWillClose(notification)
        } else {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - Settings tabs

/// The settings tabs of the dedicated settings window (CON-LIFECYCLE-PRESET).
/// A fresh install opens on `.setup`, where every required action has a visible
/// in-app control; nothing that the product requires can only be done through
/// an API.
enum SettingsTab: String, CaseIterable, Hashable, Identifiable {
    case setup
    case intelligence
    case providers
    case hotkeys
    case modes
    case history
    case paste

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .setup: return "Setup"
        case .intelligence: return "Intelligence"
        case .providers: return "Providers & Keys"
        case .hotkeys: return "Shortcuts"
        case .modes: return "Modes & Vocabulary"
        case .history: return "History"
        case .paste: return "Paste & Permissions"
        }
    }

    var systemImage: String {
        switch self {
        case .setup: return "checklist"
        case .intelligence: return "sparkles"
        case .providers: return "key"
        case .hotkeys: return "keyboard"
        case .modes: return "text.badge.plus"
        case .history: return "clock.arrow.circlepath"
        case .paste: return "doc.on.clipboard"
        }
    }
}

/// Stable identifiers of every user-facing control. The contract tests fail if
/// one of these controls disappears from the surface, so a capability can never
/// silently regress into an API-only path.
enum MenuControlID {
    static let recordStart = "whisperbar.control.recordStart"
    static let recordStop = "whisperbar.control.recordStop"
    static let recordCancel = "whisperbar.control.recordCancel"
    static let recordingMode = "whisperbar.control.recordingMode"
    static let providerPicker = "whisperbar.control.providerPicker"
    static let temporaryAudioSave = "whisperbar.control.temporaryAudioSave"
    static let temporaryAudioDiscard = "whisperbar.control.temporaryAudioDiscard"
    static let temporaryAudioRetryCleanup = "whisperbar.control.temporaryAudioRetryCleanup"
    static let credentialField = "whisperbar.control.credentialField"
    static let credentialSave = "whisperbar.control.credentialSave"
    static let credentialDelete = "whisperbar.control.credentialDelete"
    static let credentialTest = "whisperbar.control.credentialTest"
    static let credentialRefresh = "whisperbar.control.credentialRefresh"
    static let hotkeyPushToTalk = "whisperbar.control.hotkeyPushToTalk"
    static let hotkeyToggle = "whisperbar.control.hotkeyToggle"
    static let hotkeyApply = "whisperbar.control.hotkeyApply"
    static let hotkeySafeDefault = "whisperbar.control.hotkeySafeDefault"
    static let hotkeyRetry = "whisperbar.control.hotkeyRetry"
    static let modeName = "whisperbar.control.modeName"
    static let modeInstructions = "whisperbar.control.modeInstructions"
    static let modeSave = "whisperbar.control.modeSave"
    static let modeDelete = "whisperbar.control.modeDelete"
    static let vocabularyField = "whisperbar.control.vocabularyField"
    static let vocabularyAdd = "whisperbar.control.vocabularyAdd"
    static let vocabularyRemove = "whisperbar.control.vocabularyRemove"
    static let historySearch = "whisperbar.control.historySearch"
    static let historyCopy = "whisperbar.control.historyCopy"
    static let historyDelete = "whisperbar.control.historyDelete"
    static let historyReload = "whisperbar.control.historyReload"
    static let pasteApprove = "whisperbar.control.pasteApprove"
    static let pasteCancel = "whisperbar.control.pasteCancel"
    static let pasteCopyRetained = "whisperbar.control.pasteCopyRetained"
    static let pasteRetry = "whisperbar.control.pasteRetry"
    static let refinementToggle = "whisperbar.control.refinementToggle"
    static let permissionRefresh = "whisperbar.control.permissionRefresh"
    static let permissionRequest = "whisperbar.control.permissionRequest"
    static let launchAtLoginToggle = "whisperbar.control.launchAtLoginToggle"
    static let settingsTab = "whisperbar.control.settingsTab"
}

// MARK: - Menu content

struct MenuBarContent: View {
    @Bindable var controller: MenuBarController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: controller.menuBarSystemImageName)
                Text(AppIdentity.appName)
                    .font(.headline)
                Spacer()
                Text(controller.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let message = controller.lastErrorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            DictationControls(controller: controller)

            Divider()

            ProviderQuickPicker(controller: controller)

            if controller.showsTemporaryAudioRecoveryControls {
                Divider()
                TemporaryAudioRecoveryControls(controller: controller)
            }

            if controller.isPreviewAwaitingApproval {
                Divider()
                PastePreviewControls(controller: controller)
            }

            Divider()

            HStack {
                Button("Settings…") {
                    controller.openMainWindow()
                }
                .keyboardShortcut(",", modifiers: .command)

                Spacer()

                Button("Quit WhisperBar") {
                    controller.requestTermination()
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
        .padding(16)
        .frame(width: 360)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("WhisperBar menu")
    }
}

/// The in-app record/stop/cancel controls, shared by the menu and the setup
/// surface. They drive the same one session state machine the global shortcuts
/// drive, so dictation is available on a fresh install without any shortcut.
struct DictationControls: View {
    @Bindable var controller: MenuBarController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dictation")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker("Recording mode", selection: $controller.inAppRecordingMode) {
                Text("Push-to-talk").tag(HotkeyMode.pushToTalk)
                Text("Toggle").tag(HotkeyMode.toggle)
            }
            .pickerStyle(.segmented)
            .disabled(controller.isRecordingSessionInFlight)
            .accessibilityIdentifier(MenuControlID.recordingMode)
            .accessibilityLabel("In-app recording mode")

            HStack {
                Button("Start recording") {
                    Task { _ = await controller.startInAppRecording() }
                }
                .disabled(controller.isRecordingSessionInFlight)
                .accessibilityIdentifier(MenuControlID.recordStart)
                .accessibilityLabel("Start recording")

                Button("Stop") {
                    Task { _ = await controller.stopInAppRecording() }
                }
                .disabled(!controller.isRecordingSessionInFlight)
                .accessibilityIdentifier(MenuControlID.recordStop)
                .accessibilityLabel("Stop recording and transcribe")

                Button("Cancel") {
                    Task { _ = await controller.cancelInAppRecording() }
                }
                .disabled(!controller.isRecordingSessionInFlight)
                .accessibilityIdentifier(MenuControlID.recordCancel)
                .accessibilityLabel("Cancel recording")
            }

            if controller.isRecordingSessionInFlight, !controller.interimTranscript.isEmpty {
                Text(controller.interimTranscript)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Interim transcript")
            }
        }
    }
}

/// The compact provider picker of the menu. It writes the explicit selection to
/// both owners through the one controller action, so the two can never drift.
struct ProviderQuickPicker: View {
    let controller: MenuBarController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Transcription provider")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Picker("Provider", selection: providerSelection) {
                Text("No provider (recording stays blocked)").tag(TranscriptionProviderID?.none)
                ForEach(TranscriptionProviderID.allCases, id: \.self) { provider in
                    Text(provider.displayName).tag(TranscriptionProviderID?.some(provider))
                }
            }
            .labelsHidden()
            .disabled(controller.isProviderSelectionLocked)
            .accessibilityIdentifier(MenuControlID.providerPicker)
            .accessibilityLabel("Transcription provider")

            Text(controller.providerSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let feedback = controller.providerFeedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var providerSelection: Binding<TranscriptionProviderID?> {
        Binding(
            get: { controller.selectedProvider },
            set: { newValue in
                Task { _ = await controller.selectProvider(newValue) }
            }
        )
    }
}

/// Step 14 of CON-PASTE-WORKFLOW: a waiting preview inserts nothing until it is
/// explicitly approved, and cancelling preserves the complete transcript.
struct PastePreviewControls: View {
    let controller: MenuBarController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preview awaiting approval")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let preview = controller.pendingPreviewText {
                Text(preview)
                    .font(.callout)
                    .lineLimit(4)
                    .accessibilityLabel("Transcript preview")
            }
            HStack {
                Button("Insert") {
                    Task { _ = await controller.approvePastePreview() }
                }
                .accessibilityIdentifier(MenuControlID.pasteApprove)
                .accessibilityLabel("Approve preview and insert")

                Button("Cancel preview") {
                    _ = controller.cancelPastePreview()
                }
                .accessibilityIdentifier(MenuControlID.pasteCancel)
                .accessibilityLabel("Cancel preview")
            }
        }
    }
}

/// Temporary-audio recovery controls (CON-TEMPORARY-AUDIO-CLEANUP-RECOVERY):
/// after a recoverable provider failure the retained recording can be saved
/// to a user-chosen destination or explicitly discarded, and a cleanup that
/// could not verify absence has its own explicit retry. Nothing here happens
/// automatically, and every control runs the authoritative owner action.
struct TemporaryAudioRecoveryControls: View {
    let controller: MenuBarController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recording recovery")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let feedback = controller.temporaryAudioFeedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if controller.canActOnRetainedTemporaryRecording {
                    Button("Save recording…") {
                        Task { _ = await controller.saveTemporaryRecordingExplicitly() }
                    }
                    .accessibilityIdentifier(MenuControlID.temporaryAudioSave)
                    .accessibilityLabel("Save the retained recording")

                    Button("Discard recording") {
                        Task { _ = await controller.discardTemporaryRecordingExplicitly() }
                    }
                    .accessibilityIdentifier(MenuControlID.temporaryAudioDiscard)
                    .accessibilityLabel("Discard the retained recording")
                }

                if controller.isTemporaryAudioCleanupPending {
                    Button("Retry cleanup") {
                        Task { _ = await controller.retryTemporaryAudioCleanupExplicitly() }
                    }
                    .accessibilityIdentifier(MenuControlID.temporaryAudioRetryCleanup)
                    .accessibilityLabel("Retry temporary audio cleanup")
                }
            }
        }
    }
}

// MARK: - Settings root

struct SettingsRoot: View {
    @Bindable var controller: MenuBarController

    var body: some View {
        TabView(selection: $controller.selectedSettingsTab) {
            SetupSettingsView(controller: controller)
                .tabItem { Label(SettingsTab.setup.displayName, systemImage: SettingsTab.setup.systemImage) }
                .tag(SettingsTab.setup)
            JevIntelligenceSettingsView(controller: controller)
                .tabItem { Label(SettingsTab.intelligence.displayName, systemImage: SettingsTab.intelligence.systemImage) }
                .tag(SettingsTab.intelligence)
            ProvidersSettingsView(controller: controller)
                .tabItem { Label(SettingsTab.providers.displayName, systemImage: SettingsTab.providers.systemImage) }
                .tag(SettingsTab.providers)
            HotkeysSettingsView(controller: controller)
                .tabItem { Label(SettingsTab.hotkeys.displayName, systemImage: SettingsTab.hotkeys.systemImage) }
                .tag(SettingsTab.hotkeys)
            ModesSettingsView(controller: controller)
                .tabItem { Label(SettingsTab.modes.displayName, systemImage: SettingsTab.modes.systemImage) }
                .tag(SettingsTab.modes)
            HistorySettingsView(controller: controller)
                .tabItem { Label(SettingsTab.history.displayName, systemImage: SettingsTab.history.systemImage) }
                .tag(SettingsTab.history)
            PasteSettingsView(controller: controller)
                .tabItem { Label(SettingsTab.paste.displayName, systemImage: SettingsTab.paste.systemImage) }
                .tag(SettingsTab.paste)
        }
        .padding(16)
        .accessibilityIdentifier(MenuControlID.settingsTab)
        .accessibilityLabel("WhisperBar settings tabs")
    }
}

// MARK: - Setup tab

/// The deterministic first-run path: one ordered list of the required steps,
/// each with a reachable in-app control, plus the in-app dictation controls so a
/// fresh install can dictate before any shortcut exists.
struct SetupSettingsView: View {
    @Bindable var controller: MenuBarController

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("Application", value: AppIdentity.appName)
                LabeledContent("Status", value: controller.statusText)
                LabeledContent("Local history", value: controller.storageSummary)
                Button("Refresh status") {
                    Task {
                        await controller.refreshStorageSummary()
                        await controller.refreshPermissionStates()
                    }
                }
                .accessibilityIdentifier(MenuControlID.permissionRefresh)
                .accessibilityLabel("Refresh status")
            }

            Section("Setup steps") {
                SetupStepRow(
                    step: 1,
                    title: "Choose a transcription provider",
                    detail: controller.providerSummary,
                    actionTitle: "Open Providers & Keys"
                ) {
                    controller.selectedSettingsTab = .providers
                }

                SetupStepRow(
                    step: 2,
                    title: "Add the API key for the selected provider",
                    detail: credentialDetail,
                    actionTitle: "Enter the API key"
                ) {
                    controller.selectedSettingsTab = .providers
                }

                SetupStepRow(
                    step: 3,
                    title: "Grant Microphone access for dictation",
                    detail: "Microphone: \(permissionText(.microphone))",
                    actionTitle: "Request Microphone access"
                ) {
                    Task { _ = await controller.requestPermission(.microphone) }
                }

                SetupStepRow(
                    step: 4,
                    title: "Set up the global shortcuts (optional — the in-app controls always work)",
                    detail: controller.hotkeyRegistrationSummary,
                    actionTitle: "Use safe defaults"
                ) {
                    Task { _ = await controller.useSafeDefaultHotkeys() }
                }

                SetupStepRow(
                    step: 5,
                    title: "Try dictation from here",
                    detail: "Start, stop, or cancel a recording with the in-app controls.",
                    actionTitle: nil,
                    action: nil
                )
                DictationControls(controller: controller)
            }

            Section("Startup") {
                Toggle("Launch WhisperBar at login", isOn: Binding(
                    get: { controller.launchAtLoginStatus == .enabled },
                    set: { enabled in Task { _ = await controller.setLaunchAtLogin(enabled) } }
                ))
                .accessibilityIdentifier(MenuControlID.launchAtLoginToggle)
                .accessibilityLabel("Launch WhisperBar at login")

                Text("Launch at login: \(MenuBarController.describe(loginItemStatus: controller.launchAtLoginStatus))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let feedback = controller.launchAtLoginFeedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let guidance = controller.permissionGuidance(for: .backgroundStartup) {
                    Text(guidance)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let message = controller.lastErrorMessage {
                Section("Attention") {
                    Text(message)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Privacy") {
                Text("WhisperBar keeps transcripts, credentials, and audio inside their declared local boundaries. Credentials live only in the macOS Keychain; audio exists only for the active request.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var credentialDetail: String {
        guard let provider = controller.selectedProvider else {
            return "Select a provider first; recording stays blocked until you do."
        }
        let key: CredentialKey = switch provider {
        case .deepgramStreaming: .deepgramNovaStreamingTranscription
        case .openRouterBatch: .openRouter
        }
        switch controller.credentialStatuses[key] ?? .missing {
        case .configured: return "A \(key.displayName) key is stored in the Keychain."
        case .missing: return "No \(key.displayName) key is stored yet."
        case .unavailable: return "The \(key.displayName) key could not be read from the Keychain."
        }
    }

    private func permissionText(_ domain: PermissionDomain) -> String {
        guard let state = controller.permissionStates[domain] else {
            return "not checked yet — use Refresh status"
        }
        return MenuBarController.describe(permissionState: state)
    }
}

/// One numbered setup step with a single deterministic action.
struct SetupStepRow: View {
    let step: Int
    let title: String
    let detail: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(step).")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.callout)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .accessibilityLabel(actionTitle)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Providers tab

struct ProvidersSettingsView: View {
    @Bindable var controller: MenuBarController

    var body: some View {
        Form {
            Section("Transcription provider") {
                ProviderQuickPicker(controller: controller)
                Text("The selection is explicit and stays fixed for a recording. WhisperBar never switches providers, never falls back, and never retries a paid request automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("API keys (stored only in the macOS Keychain)") {
                HStack {
                    Button("Refresh key status") {
                        Task { await controller.refreshCredentialStatuses() }
                    }
                    .accessibilityIdentifier(MenuControlID.credentialRefresh)
                    .accessibilityLabel("Refresh key status")
                    Text("Only a value-free status is shown; a stored key is never read back.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(CredentialKey.allCases, id: \.self) { key in
                    CredentialRow(controller: controller, key: key)
                }
                if let feedback = controller.credentialFeedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Optional refinement (OpenRouter)") {
                Toggle("Refine each transcript with the selected writing mode", isOn: Binding(
                    get: { controller.refinementEnabled },
                    set: { enabled in Task { _ = await controller.setRefinementEnabled(enabled) } }
                ))
                .accessibilityIdentifier(MenuControlID.refinementToggle)
                .accessibilityLabel("Enable optional refinement")

                Text("Refinement stays off until it is explicitly enabled, uses the stored OpenRouter key, and never replaces the accepted transcript when it fails.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let feedback = controller.refinementFeedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// One provider credential: entry, save, delete, and test. The entered value is
/// handed to the vault once and never read back into presentation state.
struct CredentialRow: View {
    let controller: MenuBarController
    let key: CredentialKey

    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(key.displayName)
                    .font(.headline)
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SecureField("Paste the \(key.displayName) API key", text: $draft)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(MenuControlID.credentialField)
                .accessibilityLabel("\(key.displayName) API key entry")

            HStack {
                Button("Save key") {
                    let value = draft
                    Task {
                        if await controller.saveCredential(value, for: key) {
                            draft = ""
                        }
                    }
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier(MenuControlID.credentialSave)
                .accessibilityLabel("Save \(key.displayName) API key")

                Button("Delete key") {
                    Task { _ = await controller.deleteCredential(for: key) }
                }
                .disabled(!isConfigured)
                .accessibilityIdentifier(MenuControlID.credentialDelete)
                .accessibilityLabel("Delete the stored \(key.displayName) API key")

                Button("Test connection") {
                    Task { _ = await controller.testCredentialConnection(for: key) }
                }
                .disabled(!isConfigured)
                .accessibilityIdentifier(MenuControlID.credentialTest)
                .accessibilityLabel("Test the \(key.displayName) connection")
            }

            if let blocking = controller.credentialBlockingMessage(for: key) {
                Text(blocking)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private var isConfigured: Bool {
        controller.credentialStatuses[key] == .configured
    }

    private var statusText: String {
        switch controller.credentialStatuses[key] ?? .missing {
        case .configured: return "A key is stored"
        case .missing: return "No key stored"
        case .unavailable: return "Keychain unavailable"
        }
    }
}

// MARK: - Shortcuts tab

/// The editable shortcut setup: a safe default in one action, per-role key and
/// modifier editors, and an explicit conflict-retry path. A rejected
/// configuration leaves the previous shortcuts and the stored configuration
/// untouched.
struct HotkeysSettingsView: View {
    @Bindable var controller: MenuBarController

    @State private var pushToTalkKeyCode: UInt32 = 2
    @State private var pushToTalkModifiers: UInt32 = MenuBarController.controlModifier | MenuBarController.optionModifier
    @State private var toggleKeyCode: UInt32 = 17
    @State private var toggleModifiers: UInt32 = MenuBarController.controlModifier | MenuBarController.optionModifier
    @State private var didLoad = false

    var body: some View {
        Form {
            Section("Active shortcuts") {
                Text(controller.hotkeyRegistrationSummary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("Push-to-talk", value: MenuBarController.describeHotkey(controller.hotkeyConfiguration.pushToTalk))
                LabeledContent("Toggle", value: MenuBarController.describeHotkey(controller.hotkeyConfiguration.toggle))
                HStack {
                    Button("Retry registration") {
                        Task { _ = await controller.retryHotkeyRegistration() }
                    }
                    .accessibilityIdentifier(MenuControlID.hotkeyRetry)
                    .accessibilityLabel("Retry shortcut registration")

                    Button("Reload stored shortcuts") {
                        Task { await controller.loadHotkeyConfiguration() }
                    }
                    .accessibilityLabel("Reload the stored shortcuts")
                }
                if let feedback = controller.hotkeyFeedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Presets") {
                HStack(spacing: 12) {
                    Button("Safe defaults (⌃⌥D / ⌃⌥T)") {
                        Task { _ = await controller.useSafeDefaultHotkeys() }
                    }
                    .accessibilityIdentifier(MenuControlID.hotkeySafeDefault)
                    .accessibilityLabel("Use the safe default shortcuts")

                    Button("Karabiner Hyperkey (⌃⌥⇧⌘T / ⌃⌥⇧⌘D)") {
                        Task { _ = await controller.useKarabinerHyperkeyPreset() }
                    }
                    .accessibilityLabel("Use Karabiner Hyperkey shortcuts")
                }
                Text("Hyperkey preset sets ⌃⌥⇧⌘T for toggle mode and ⌃⌥⇧⌘D for push-to-talk (standard Karabiner ⌃⌥⇧⌘ mapping).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Fn (Globe) Key Push-to-Talk") {
                Toggle("Use Fn (Globe) key for Push-to-Talk", isOn: Binding(
                    get: { controller.useFnKeyForPushToTalk },
                    set: { newValue in
                        Task { await controller.setUseFnKeyForPushToTalk(newValue) }
                    }
                ))
                Text("Press and hold the Fn (Globe) key to speak, release to finish and paste. Works alongside global hotkeys.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Push-to-talk shortcut") {
                HotkeyEditorRow(
                    keyCode: $pushToTalkKeyCode,
                    modifiers: $pushToTalkModifiers,
                    label: "Push-to-talk shortcut"
                )
                .accessibilityIdentifier(MenuControlID.hotkeyPushToTalk)
            }

            Section("Toggle shortcut") {
                HotkeyEditorRow(
                    keyCode: $toggleKeyCode,
                    modifiers: $toggleModifiers,
                    label: "Toggle shortcut"
                )
                .accessibilityIdentifier(MenuControlID.hotkeyToggle)
            }

            Section("Apply") {
                HStack {
                    Button("Apply shortcuts") {
                        Task {
                            _ = await controller.applyHotkeyConfiguration(editedConfiguration)
                        }
                    }
                    .accessibilityIdentifier(MenuControlID.hotkeyApply)
                    .accessibilityLabel("Apply the edited shortcuts")

                    Button("Disable global shortcuts") {
                        Task { _ = await controller.applyHotkeyConfiguration(.empty) }
                    }
                    .accessibilityLabel("Disable global shortcuts")
                }
                Text("A shortcut needs at least one modifier and the two roles must differ. If a combination is already used by another application it is rejected with an explanation, the previous shortcuts stay active, and you can choose another combination and apply again. The in-app controls keep working either way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            syncEditorFromController()
        }
        .onChange(of: controller.hotkeyConfiguration) { _, _ in
            syncEditorFromController()
        }
    }

    private var editedConfiguration: HotkeyConfiguration {
        HotkeyConfiguration(
            pushToTalk: HotkeyIdentifier(keyCode: pushToTalkKeyCode, modifiers: pushToTalkModifiers),
            toggle: HotkeyIdentifier(keyCode: toggleKeyCode, modifiers: toggleModifiers)
        )
    }

    private func syncEditorFromController() {
        if let pushToTalk = controller.hotkeyConfiguration.pushToTalk {
            pushToTalkKeyCode = pushToTalk.keyCode
            pushToTalkModifiers = pushToTalk.modifiers
        }
        if let toggle = controller.hotkeyConfiguration.toggle {
            toggleKeyCode = toggle.keyCode
            toggleModifiers = toggle.modifiers
        }
    }
}

/// One shortcut editor: the four Carbon modifier flags plus the editable key.
struct HotkeyEditorRow: View {
    @Binding var keyCode: UInt32
    @Binding var modifiers: UInt32
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                modifierToggle("⌃", flag: MenuBarController.controlModifier, name: "Control")
                modifierToggle("⌥", flag: MenuBarController.optionModifier, name: "Option")
                modifierToggle("⇧", flag: MenuBarController.shiftModifier, name: "Shift")
                modifierToggle("⌘", flag: MenuBarController.commandModifier, name: "Command")
                Button("Set Hyper (⌃⌥⇧⌘)") {
                    modifiers = MenuBarController.hyperModifier
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            Picker("Key", selection: $keyCode) {
                ForEach(MenuBarController.editableHotkeyKeys, id: \.keyCode) { entry in
                    Text(entry.name).tag(entry.keyCode)
                }
            }
            .accessibilityLabel("\(label) key")

            Text("Current combination: \(MenuBarController.describeHotkey(HotkeyIdentifier(keyCode: keyCode, modifiers: modifiers)))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func modifierToggle(_ symbol: String, flag: UInt32, name: String) -> some View {
        Toggle(symbol, isOn: Binding(
            get: { modifiers & flag != 0 },
            set: { isOn in
                if isOn {
                    modifiers |= flag
                } else {
                    modifiers &= ~flag
                }
            }
        ))
        .toggleStyle(.checkbox)
        .accessibilityLabel("\(label) \(name) modifier")
    }
}

// MARK: - Modes and vocabulary tab

struct ModesSettingsView: View {
    @Bindable var controller: MenuBarController

    @State private var editorModeID: String?
    @State private var modeName = ""
    @State private var modeInstructions = ""
    @State private var modeIsDefault = false
    @State private var newTerm = ""

    var body: some View {
        Form {
            Section("Writing modes") {
                if controller.writingModes.isEmpty {
                    Text("No writing mode is stored yet. Add one below; without a mode the locked default behavior applies.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(controller.writingModes) { mode in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(mode.name)
                                    .font(.callout)
                                if mode.isDefault {
                                    Text("default")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if controller.selectedWritingModeID == mode.id {
                                    Text("selected")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(mode.instructions)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        Spacer()
                        Button("Select") {
                            _ = controller.selectWritingMode(id: mode.id)
                        }
                        .accessibilityLabel("Select the \(mode.name) writing mode")
                        Button("Edit") {
                            editorModeID = mode.id
                            modeName = mode.name
                            modeInstructions = mode.instructions
                            modeIsDefault = mode.isDefault
                        }
                        .accessibilityLabel("Edit the \(mode.name) writing mode")
                        Button("Delete") {
                            Task { _ = await controller.deleteWritingMode(id: mode.id) }
                        }
                        .accessibilityIdentifier(MenuControlID.modeDelete)
                        .accessibilityLabel("Delete the \(mode.name) writing mode")
                    }
                }
                HStack {
                    Button("Use the locked default behavior") {
                        _ = controller.selectWritingMode(id: nil)
                    }
                    .accessibilityLabel("Clear the selected writing mode")
                    Button("Reload from storage") {
                        Task { _ = await controller.reloadWritingConfiguration() }
                    }
                    .accessibilityLabel("Reload writing modes and vocabulary")
                }
                if let feedback = controller.writingFeedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section(editorModeID == nil ? "New writing mode" : "Edit writing mode") {
                TextField("Name", text: $modeName)
                    .accessibilityIdentifier(MenuControlID.modeName)
                    .accessibilityLabel("Writing mode name")
                TextField("Instructions", text: $modeInstructions, axis: .vertical)
                    .lineLimit(3...6)
                    .accessibilityIdentifier(MenuControlID.modeInstructions)
                    .accessibilityLabel("Writing mode instructions")
                Toggle("Use as the stored default mode", isOn: $modeIsDefault)
                    .accessibilityLabel("Store as the default writing mode")
                HStack {
                    Button("Save mode") {
                        Task {
                            let saved = await controller.saveWritingMode(
                                id: editorModeID,
                                name: modeName,
                                instructions: modeInstructions,
                                isDefault: modeIsDefault
                            )
                            if saved {
                                editorModeID = nil
                                modeName = ""
                                modeInstructions = ""
                                modeIsDefault = false
                            }
                        }
                    }
                    .disabled(modeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || modeInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier(MenuControlID.modeSave)
                    .accessibilityLabel("Save the writing mode")

                    Button("Clear editor") {
                        editorModeID = nil
                        modeName = ""
                        modeInstructions = ""
                        modeIsDefault = false
                    }
                    .accessibilityLabel("Clear the writing mode editor")
                }
            }

            Section("Vocabulary") {
                HStack {
                    TextField("Term", text: $newTerm)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier(MenuControlID.vocabularyField)
                        .accessibilityLabel("Vocabulary term")
                    Button("Add term") {
                        let term = newTerm
                        Task {
                            if await controller.addVocabularyTerm(term) {
                                newTerm = ""
                            }
                        }
                    }
                    .disabled(newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier(MenuControlID.vocabularyAdd)
                    .accessibilityLabel("Add the vocabulary term")
                }
                if controller.vocabularyTerms.isEmpty {
                    Text("No vocabulary term is stored yet. Added terms are fed deterministically into transcription requests.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(controller.vocabularyTerms) { term in
                    HStack {
                        Text(term.term)
                            .font(.callout)
                        Spacer()
                        Button("Remove") {
                            Task { _ = await controller.removeVocabularyTerm(id: term.id) }
                        }
                        .accessibilityIdentifier(MenuControlID.vocabularyRemove)
                        .accessibilityLabel("Remove the \(term.term) vocabulary term")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - History tab

struct HistorySettingsView: View {
    @Bindable var controller: MenuBarController

    var body: some View {
        Form {
            Section("Offline search") {
                HStack {
                    TextField("Search transcripts", text: $controller.historyQuery)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier(MenuControlID.historySearch)
                        .accessibilityLabel("Search transcripts")
                        .onSubmit {
                            Task { _ = await controller.searchHistory(controller.historyQuery) }
                        }
                    Button("Search") {
                        Task { _ = await controller.searchHistory(controller.historyQuery) }
                    }
                    .accessibilityLabel("Search local history")
                    Button("Show recent") {
                        Task { _ = await controller.searchHistory("") }
                    }
                    .accessibilityLabel("Show the recent transcripts")
                    Button("Reload") {
                        Task { _ = await controller.reloadHistory() }
                    }
                    .accessibilityIdentifier(MenuControlID.historyReload)
                    .accessibilityLabel("Reload local history")
                }

                Text(controller.storageSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let feedback = controller.historyFeedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Transcripts (\(controller.historyTranscripts.count))") {
                if controller.historyTranscripts.isEmpty {
                    Text("No stored transcript matches. Local history is bounded, offline-only, and never uploaded or synced anywhere.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(controller.historyTranscripts) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.text)
                            .font(.callout)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Text("\(record.provider.displayName) · \(record.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Copy") {
                                _ = controller.copyHistoryEntry(id: record.id)
                            }
                            .accessibilityIdentifier(MenuControlID.historyCopy)
                            .accessibilityLabel("Copy the transcript")
                            Button("Delete") {
                                Task { _ = await controller.deleteHistoryEntry(id: record.id) }
                            }
                            .accessibilityIdentifier(MenuControlID.historyDelete)
                            .accessibilityLabel("Delete the transcript from local history")
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Paste and permissions tab

struct PasteSettingsView: View {
    @Bindable var controller: MenuBarController

    var body: some View {
        Form {
            Section("Insertion mode") {
                Picker("Insertion mode", selection: Binding(
                    get: { controller.pasteMode },
                    set: { controller.setPasteMode($0) }
                )) {
                    Text("Auto-paste").tag(PasteMode.autoPaste)
                    Text("Copy only").tag(PasteMode.copyOnly)
                    Text("Preview first").tag(PasteMode.preview)
                }
                .accessibilityLabel("Insertion mode")

                Text("Auto-paste prefers direct Accessibility insertion, snapshots the clipboard before any write, restores it only while WhisperBar still owns it, and never overwrites newer clipboard content. Copy-only leaves the transcript on the clipboard; preview inserts nothing until you approve it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let feedback = controller.pasteFeedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Clipboard behavior") {
                Toggle("Restore previous clipboard after auto-paste", isOn: Binding(
                    get: { controller.restoreClipboardAfterPaste },
                    set: { newValue in
                        Task { await controller.setRestoreClipboardAfterPaste(newValue) }
                    }
                ))
                Text("When disabled (default), the transcript remains on your clipboard so you can manually press ⌘V in apps like Antinote that reject synthetic paste events.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Preview and recovery") {
                if let preview = controller.pendingPreviewText {
                    Text("Waiting for explicit approval:")
                        .font(.callout)
                    Text(preview)
                        .font(.callout)
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Insert") {
                            Task { _ = await controller.approvePastePreview() }
                        }
                        .accessibilityIdentifier(MenuControlID.pasteApprove)
                        .accessibilityLabel("Approve preview and insert")
                        Button("Cancel preview") {
                            _ = controller.cancelPastePreview()
                        }
                        .accessibilityIdentifier(MenuControlID.pasteCancel)
                        .accessibilityLabel("Cancel preview")
                    }
                } else {
                    Text(controller.isPreviewAwaitingApproval
                        ? "A preview is waiting for approval."
                        : "No preview is waiting for approval.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let retained = controller.retainedPasteText {
                    Text("Preserved after an insertion failure:")
                        .font(.callout)
                    Text(retained)
                        .font(.callout)
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Copy the transcript") {
                            _ = controller.copyRetainedPasteText()
                        }
                        .accessibilityIdentifier(MenuControlID.pasteCopyRetained)
                        .accessibilityLabel("Copy the preserved transcript")
                        Button("Retry insertion") {
                            Task { _ = await controller.retryPasteInsertion() }
                        }
                        .accessibilityIdentifier(MenuControlID.pasteRetry)
                        .accessibilityLabel("Retry the insertion")
                    }
                }
            }

            Section("Permissions and access") {
                HStack {
                    Button("Refresh permission status") {
                        Task { await controller.refreshPermissionStates() }
                    }
                    .accessibilityIdentifier(MenuControlID.permissionRefresh)
                    .accessibilityLabel("Refresh permission status")
                    Text("Every read is read-only; nothing is prompted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(PermissionDomain.allCases, id: \.self) { domain in
                    PermissionRow(controller: controller, domain: domain)
                }

                if let feedback = controller.permissionFeedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// One permission or access domain: its value-free state, the actionable
/// guidance, and the explicit request control where a prompt exists.
struct PermissionRow: View {
    let controller: MenuBarController
    let domain: PermissionDomain

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(domain.displayName)
                    .font(.callout)
                Spacer()
                Text(stateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if domain.supportsExplicitRequest {
                    Button("Request") {
                        Task { _ = await controller.requestPermission(domain) }
                    }
                    .accessibilityIdentifier(MenuControlID.permissionRequest)
                    .accessibilityLabel("Request \(domain.displayName) access")
                }
            }
            if let guidance = controller.permissionGuidance(for: domain) {
                Text(guidance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let manual = controller.permissionManualPath(for: domain) {
                Text(manual)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private var stateText: String {
        guard let state = controller.permissionStates[domain] else { return "not checked yet" }
        return MenuBarController.describe(permissionState: state)
    }
}

extension PermissionDomain {
    /// The domains whose system prompt can be raised from the explicit request
    /// control. Every other domain is managed entirely by its own explicit
    /// toggle or by the operating system.
    var supportsExplicitRequest: Bool {
        switch self {
        case .microphone, .accessibility, .notifications:
            return true
        case .clipboard, .globalInput, .filesystem, .network, .backgroundStartup:
            return false
        }
    }
}
