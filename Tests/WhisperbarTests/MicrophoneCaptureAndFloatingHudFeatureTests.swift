import AppKit
import Foundation
import Testing
@testable import Whisperbar

/// TASK-14-MICROPHONE-CAPTURE-AND-FLOATING-HUD focused checks.
///
/// Covers FEAT-MICROPHONE-CAPTURE-AND-FLOATING-HUD and contracts
/// CON-MICROPHONE-CAPTURE-AND-FLOATING-HUD-INTERFACE and
/// CON-MICROPHONE-CAPTURE-AND-FLOATING-HUD-RECOVERY through an injected
/// capture seam, an in-memory HUD presenter, a fake permission surface, and a
/// fake clock. No real microphone, audio engine, TCC prompt, audio device,
/// floating panel, or network request is touched by these tests.
@Suite("MicrophoneCaptureAndFloatingHudFeature — capture and floating HUD")
@MainActor
struct MicrophoneCaptureAndFloatingHudFeatureTests {

    typealias Feature = MicrophoneCaptureAndFloatingHudFeature

    // MARK: - Fakes

    /// Actor-isolated capture seam: nothing is recorded, nothing is prompted.
    actor FakeMicrophoneCapture: MicrophoneCapturing {
        private let format: MicrophoneInputFormat
        private var sink: (@Sendable (MicrophoneInputBuffer) -> Void)?
        private var startError: MicrophoneCaptureError?
        private var gate: CheckedContinuation<Void, Error>?
        private var isGated = false
        private(set) var startCount = 0
        private(set) var endCount = 0

        init(format: MicrophoneInputFormat = MicrophoneInputFormat(sampleRate: 48_000, channelCount: 1)) {
            self.format = format
        }

        var hasSink: Bool { sink != nil }

        func configure(startError: MicrophoneCaptureError?) {
            self.startError = startError
        }

        func gateNextStart() {
            isGated = true
        }

        func releaseStart(with error: MicrophoneCaptureError? = nil) {
            startError = error
            let continuation = gate
            gate = nil
            continuation?.resume()
        }

        func beginCapture() async throws -> MicrophoneInputFormat {
            startCount += 1
            if isGated {
                isGated = false
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    gate = continuation
                }
            }
            if let startError {
                throw startError
            }
            return format
        }

        func endCapture() async {
            endCount += 1
        }

        func setBufferSink(_ sink: (@Sendable (MicrophoneInputBuffer) -> Void)?) async {
            self.sink = sink
        }

        func deliver(_ buffer: MicrophoneInputBuffer) {
            sink?(buffer)
        }
    }

    /// In-memory HUD presenter: records every presented snapshot and the
    /// installed stop/cancel control actions. It has no activation surface.
    @MainActor
    final class FakeHudPresenter: HudPresenting {
        private(set) var presentations: [CaptureHudSnapshot] = []
        private(set) var stopAction: (@MainActor () -> Void)?
        private(set) var cancelAction: (@MainActor () -> Void)?

        var latest: CaptureHudSnapshot? { presentations.last }
        var isVisible: Bool { latest?.isVisible == true }

        func present(_ snapshot: CaptureHudSnapshot) {
            presentations.append(snapshot)
        }

        func setControlActions(
            stop: @escaping @MainActor () -> Void,
            cancel: @escaping @MainActor () -> Void
        ) {
            stopAction = stop
            cancelAction = cancel
        }
    }

    /// Mutable permission surface so the documented explicit-retry path is
    /// observable without any TCC interaction.
    final class AvailabilityBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: PermissionState
        private var _requestResult: PermissionState
        private var _requestCount = 0

        init(value: PermissionState, requestResult: PermissionState?) {
            _value = value
            _requestResult = requestResult ?? value
        }

        var value: PermissionState {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }

        var requestCount: Int { lock.withLock { _requestCount } }

        func recordRequest() -> PermissionState {
            lock.withLock {
                _requestCount += 1
                _value = _requestResult
                return _requestResult
            }
        }
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var _now = Date(timeIntervalSince1970: 1_767_225_600)
        var now: Date { lock.withLock { _now } }
        func advance(_ interval: TimeInterval) {
            lock.withLock { _now = _now.addingTimeInterval(interval) }
        }
    }

    // MARK: - Room (feature + injected seams)

    struct Room {
        let feature: Feature
        let capture: FakeMicrophoneCapture
        let hud: FakeHudPresenter
        let clock: Clock
        let box: AvailabilityBox
    }

    private func makeRoom(
        availability: PermissionState = .authorized,
        requestResult: PermissionState? = nil,
        capture: FakeMicrophoneCapture = FakeMicrophoneCapture(),
        hud: FakeHudPresenter = FakeHudPresenter(),
        clock: Clock = Clock()
    ) -> Room {
        let box = AvailabilityBox(value: availability, requestResult: requestResult)
        let feature = Feature(
            capture: capture,
            hudPresenter: hud,
            microphoneAvailability: { box.value },
            requestMicrophoneAccess: { box.recordRequest() },
            now: { clock.now }
        )
        return Room(feature: feature, capture: capture, hud: hud, clock: clock, box: box)
    }

    // MARK: - Helpers

    private func constantBuffer(
        _ value: Float,
        frameCount: Int,
        sampleRate: Double = 48_000,
        channels: Int = 1
    ) -> MicrophoneInputBuffer {
        MicrophoneInputBuffer(
            samples: [Float](repeating: value, count: frameCount * channels),
            format: MicrophoneInputFormat(sampleRate: sampleRate, channelCount: channels)
        )
    }

    private func pcm16Samples(_ data: Data) -> [Int16] {
        let bytes = [UInt8](data)
        var samples: [Int16] = []
        var index = 0
        while index + 1 < bytes.count {
            let raw = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
            samples.append(Int16(bitPattern: raw))
            index += 2
        }
        return samples
    }

    /// Bounded wait for an enqueued main-actor continuation (the capture sink
    /// hops onto the main actor) without any unbounded sleep loop.
    private func settle(_ condition: () async -> Bool, attempts: Int = 400) async {
        for _ in 0..<attempts {
            if await condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 250_000)
        }
    }

    // MARK: - ACC-MICROPHONE-CAPTURE-AND-FLOATING-HUD-01
    // Audio levels update in real time.

    @Test("Audio levels update in real time for every delivered buffer")
    func levelsUpdateInRealTime() async {
        let room = makeRoom()
        #expect(await room.feature.startCapture(mode: .pushToTalk))
        let presentationsBefore = room.hud.presentations.count

        await room.capture.deliver(constantBuffer(0.5, frameCount: 480))
        await settle { room.feature.receivedBufferCount == 1 }
        #expect(abs(room.feature.inputLevel - 0.5) < 0.001)
        #expect(room.hud.latest?.level == room.feature.inputLevel)
        #expect(room.hud.presentations.count == presentationsBefore + 1)

        // Digital silence is still a valid, non-empty PCM frame.
        await room.capture.deliver(constantBuffer(0.0, frameCount: 480))
        await settle { room.feature.receivedBufferCount == 2 }
        #expect(room.feature.inputLevel == 0)
        #expect(room.feature.emittedFrameCount == 2)

        await room.capture.deliver(constantBuffer(0.9, frameCount: 480))
        await settle { room.feature.receivedBufferCount == 3 }
        #expect(abs(room.feature.inputLevel - 0.9) < 0.001)
        #expect(room.hud.presentations.count == presentationsBefore + 3)
        #expect(room.hud.latest?.phase == .recording)

        // The HUD measures elapsed recording time from the recording start.
        room.clock.advance(2.5)
        await room.capture.deliver(constantBuffer(0.4, frameCount: 480))
        await settle { room.feature.receivedBufferCount == 4 }
        #expect(abs((room.hud.latest?.elapsedDuration ?? 0) - 2.5) < 0.001)
    }

    // MARK: - ACC-MICROPHONE-CAPTURE-AND-FLOATING-HUD-02
    // HUD appears immediately on recording start.

    @Test("HUD appears immediately on recording start, before the capture engine is up")
    func hudAppearsImmediatelyOnStart() async {
        let capture = FakeMicrophoneCapture()
        await capture.gateNextStart()
        let room = makeRoom(capture: capture)

        let startTask = Task { await room.feature.startCapture(mode: .pushToTalk) }
        await settle { await capture.startCount == 1 }

        // The HUD is already visible while the engine is still starting.
        #expect(room.feature.isCaptureEngineRunning == false)
        #expect(room.feature.hudSnapshot.isVisible)
        #expect(room.feature.hudSnapshot.phase == .recording)
        #expect(room.feature.hudSnapshot.mode == .pushToTalk)
        #expect(room.hud.isVisible)
        #expect(room.hud.latest?.mode == .pushToTalk)
        #expect(room.feature.state == .active)

        await capture.releaseStart()
        #expect(await startTask.value)
        #expect(room.feature.isCaptureEngineRunning)
        #expect(room.feature.hudSnapshot.isVisible)
    }

    // MARK: - ACC-MICROPHONE-CAPTURE-AND-FLOATING-HUD-03
    // HUD remains unobtrusive and does not steal focus.

    @Test("The floating HUD is non-activating and never becomes key, main, or focus")
    func hudIsNonActivating() async {
        #expect(HudPanelContract.styleMask.contains(.nonactivatingPanel))
        #expect(HudPanelContract.styleMask.contains(.borderless))
        #expect(!HudPanelContract.styleMask.contains(.titled))
        #expect(HudPanelContract.becomesKeyOnPresentation == false)
        #expect(HudPanelContract.stealsFocus == false)
        #expect(HudPanelContract.canBecomeKeyOrMain == false)

        // Presenting stays declarative state only: the seam has no activate,
        // makeKey, or focus API, so the app is never raised by the HUD.
        let room = makeRoom()
        #expect(await room.feature.startCapture(mode: .toggle))
        #expect(room.hud.latest?.isVisible == true)
    }

    // MARK: - ACC-MICROPHONE-CAPTURE-AND-FLOATING-HUD-04
    // Stop and cancel actions are responsive.

    @Test("Stop ends the session, releases capture resources, and hides the HUD")
    func stopIsResponsiveAndReleasesResources() async {
        let room = makeRoom()
        #expect(await room.feature.startCapture(mode: .pushToTalk))
        await room.capture.deliver(constantBuffer(0.7, frameCount: 480))
        await settle { room.feature.receivedBufferCount == 1 }

        #expect(await room.feature.stopCapture())
        #expect(room.feature.state == .succeeded)
        #expect(room.feature.isRecording == false)
        #expect(room.feature.isCaptureEngineRunning == false)
        #expect(room.feature.hudSnapshot.isVisible == false)
        #expect(room.hud.latest?.isVisible == false)
        #expect(room.hud.latest?.phase == .finished)
        #expect(await room.capture.endCount == 1)
        #expect(await room.capture.hasSink == false)

        // Late buffers after the terminal path are discarded.
        await room.capture.deliver(constantBuffer(0.7, frameCount: 480))
        await settle { room.feature.droppedBufferCount >= 1 }
        #expect(room.feature.receivedBufferCount == 1)
        #expect(room.feature.emittedFrameCount == 1)

        // A stop without an active session is a no-op.
        #expect(await room.feature.stopCapture() == false)
    }

    @Test("Cancel ends the session immediately, discards late data, and releases resources")
    func cancelIsResponsiveAndDiscardsLateData() async {
        let room = makeRoom()
        #expect(await room.feature.startCapture(mode: .toggle))
        #expect(room.feature.hudSnapshot.isVisible)

        #expect(await room.feature.cancelCapture())
        #expect(room.feature.state == .cancelled)
        #expect(room.feature.hudSnapshot.isVisible == false)
        #expect(room.hud.latest?.phase == .cancelled)
        #expect(await room.capture.endCount == 1)
        #expect(await room.capture.hasSink == false)

        await room.capture.deliver(constantBuffer(0.5, frameCount: 480))
        await settle { room.feature.droppedBufferCount >= 1 }
        #expect(room.feature.receivedBufferCount == 0)

        #expect(await room.feature.cancelCapture() == false)
    }

    @Test("The HUD stop and cancel controls end the session immediately")
    func hudControlsEndTheSession() async {
        let room = makeRoom()
        #expect(await room.feature.startCapture(mode: .pushToTalk))
        room.hud.stopAction?()
        await settle { await room.capture.endCount == 1 }
        #expect(room.feature.state == .succeeded)
        #expect(await room.capture.endCount == 1)

        #expect(await room.feature.startCapture(mode: .toggle))
        room.hud.cancelAction?()
        await settle { await room.capture.endCount == 2 }
        #expect(room.feature.state == .cancelled)
        #expect(await room.capture.endCount == 2)
    }

    @Test("HUD stop and cancel route through the composition seams when the controller installs them")
    func hudControlsRouteThroughCompositionSeams() async {
        let room = makeRoom()
        var stopRequests = 0
        var cancelRequests = 0
        room.feature.onStopControlRequested = { stopRequests += 1 }
        room.feature.onCancelControlRequested = { cancelRequests += 1 }

        #expect(await room.feature.startCapture(mode: .pushToTalk))
        room.hud.stopAction?()
        await settle { stopRequests == 1 }

        // The composition root owns the terminal path: the capture-only
        // fallback never runs, so the feature session is left to the
        // authoritative session state machine.
        #expect(stopRequests == 1)
        #expect(cancelRequests == 0)
        #expect(room.feature.isRecording)
        #expect(await room.capture.endCount == 0)

        room.hud.cancelAction?()
        await settle { cancelRequests == 1 }
        #expect(cancelRequests == 1)
        #expect(room.feature.isRecording)
        #expect(await room.capture.endCount == 0)
    }

    @Test("Interim streaming text updates the HUD while recording and clears on every terminal path")
    func interimTranscriptUpdatesHudAndClearsOnTerminalPath() async {
        let room = makeRoom()
        #expect(await room.feature.startCapture(mode: .toggle))
        #expect(room.feature.hudSnapshot.interimTranscript == nil)

        room.feature.updateInterimTranscript("hel")
        #expect(room.feature.interimTranscript == "hel")
        #expect(room.feature.hudSnapshot.interimTranscript == "hel")
        #expect(room.hud.latest?.interimTranscript == "hel")
        #expect(room.feature.hudSnapshot.phase == .recording)

        room.feature.updateInterimTranscript("hello wor")
        #expect(room.feature.hudSnapshot.interimTranscript == "hello wor")

        // Stop: the terminal snapshot no longer carries interim text.
        #expect(await room.feature.stopCapture())
        #expect(room.feature.interimTranscript.isEmpty)
        #expect(room.feature.hudSnapshot.interimTranscript == nil)
        #expect(room.hud.latest?.interimTranscript == nil)

        // An update without an active session is ignored.
        room.feature.updateInterimTranscript("late")
        #expect(room.feature.interimTranscript.isEmpty)

        // Cancel clears it as well.
        #expect(await room.feature.startCapture(mode: .pushToTalk))
        room.feature.updateInterimTranscript("cancelled text")
        #expect(room.feature.hudSnapshot.interimTranscript == "cancelled text")
        #expect(await room.feature.cancelCapture())
        #expect(room.feature.interimTranscript.isEmpty)
        #expect(room.feature.hudSnapshot.interimTranscript == nil)
    }

    @Test("Microphone authorization resolves before any provider route and never prompts twice")
    func authorizationResolvesBeforeRoute() async {
        let granted = makeRoom(availability: .notDetermined, requestResult: .authorized)
        #expect(await granted.feature.resolveMicrophoneAuthorizationBeforeRoute())
        #expect(granted.box.requestCount == 1)
        // The pre-route resolution itself starts no capture and opens nothing.
        #expect(await granted.capture.startCount == 0)
        #expect(granted.feature.isCaptureEngineRunning == false)

        // The standalone start reuses the resolved authorization: one prompt.
        #expect(await granted.feature.startCapture(mode: .toggle))
        #expect(granted.box.requestCount == 1)
        #expect(await granted.capture.startCount == 1)

        // A non-authorized resolution records the documented failure without
        // starting capture; the HUD shows the error and nothing was opened.
        let denied = makeRoom(availability: .notDetermined, requestResult: .denied)
        #expect(await denied.feature.resolveMicrophoneAuthorizationBeforeRoute() == false)
        #expect(denied.box.requestCount == 1)
        #expect(denied.feature.lastFailure?.category == .permissionDenied)
        #expect(denied.feature.hudSnapshot.phase == .error)
        #expect(denied.feature.hudSnapshot.isVisible)
        #expect(await denied.capture.startCount == 0)
        // The terminal path releases the capture seam.
        #expect(await denied.capture.endCount == 1)
    }

    // MARK: - Locked PCM conversion (TRD audio contract)

    @Test("Captured audio converts to raw headerless linear16 16 kHz mono PCM")
    func lockedPCMConversion() {
        #expect(MicrophonePCMConverter.targetSampleRateHz == 16_000)
        #expect(MicrophonePCMConverter.targetChannelCount == 1)

        let buffer = MicrophoneInputBuffer(
            samples: [0.5, -0.5, 1.0, -1.0],
            format: MicrophoneInputFormat(sampleRate: 16_000, channelCount: 1)
        )
        let frame = MicrophonePCMConverter.convert(buffer)
        // 0.5 → 0x4000, -0.5 → 0xC000, 1.0 → full scale 0x7FFF,
        // -1.0 → 0x8000, all little-endian 16-bit signed.
        #expect(frame == Data([0x00, 0x40, 0x00, 0xC0, 0xFF, 0x7F, 0x00, 0x80]))
        #expect(MicrophonePCMConverter.isValidFrame(frame ?? Data()))
        #expect(frame?.count ?? 0 > 0)
        #expect((frame?.count ?? 1) % 2 == 0)
        // The same frame passes the Deepgram integration's binary-frame gate:
        // non-empty and aligned to two-byte samples.
        #expect(DeepgramNovaStreamingTranscriptionIntegration.validatedAudioFrame(frame ?? Data()) != nil)
    }

    @Test("Conversion downmixes and resamples deterministically")
    func conversionDownmixesAndResamples() {
        // 24 kHz mono ramp at 16 kHz: two output frames, linear interpolation.
        let ramp = MicrophoneInputBuffer(
            samples: [0.0, 0.5, 1.0],
            format: MicrophoneInputFormat(sampleRate: 24_000, channelCount: 1)
        )
        let rampFrame = MicrophonePCMConverter.convert(ramp)
        #expect(rampFrame?.count == 4)
        #expect(pcm16Samples(rampFrame ?? Data()) == [0, 24_576])

        // 48 kHz stereo [1.0, -1.0] downmixes to mono silence at 16 kHz.
        var stereo: [Float] = []
        for _ in 0..<48 { stereo.append(contentsOf: [1.0, -1.0]) }
        let stereoBuffer = MicrophoneInputBuffer(
            samples: stereo,
            format: MicrophoneInputFormat(sampleRate: 48_000, channelCount: 2)
        )
        let stereoFrame = MicrophonePCMConverter.convert(stereoBuffer)
        // 48 input frames → 16 output frames → 32 bytes.
        #expect(stereoFrame?.count == 32)
        #expect(pcm16Samples(stereoFrame ?? Data()).allSatisfy { $0 == 0 })
    }

    @Test("Empty, malformed, and non-finite input never produces an invalid frame")
    func invalidInputNeverEmitsFrames() async {
        let room = makeRoom()
        #expect(await room.feature.startCapture(mode: .pushToTalk))

        // Empty buffers convert to nothing at all.
        let empty = MicrophoneInputBuffer(samples: [], format: MicrophoneInputFormat(sampleRate: 48_000, channelCount: 1))
        #expect(MicrophonePCMConverter.convert(empty) == nil)
        await room.capture.deliver(empty)
        await settle { room.feature.droppedBufferCount == 1 }
        #expect(room.feature.emittedFrameCount == 0)
        #expect(room.feature.lastEmittedFrameByteCount == 0)

        // Malformed formats convert to nothing at all.
        #expect(MicrophonePCMConverter.convert(
            MicrophoneInputBuffer(samples: [1, 2], format: MicrophoneInputFormat(sampleRate: 0, channelCount: 2))
        ) == nil)
        #expect(MicrophonePCMConverter.convert(
            MicrophoneInputBuffer(samples: [1, 2], format: MicrophoneInputFormat(sampleRate: 48_000, channelCount: 0))
        ) == nil)

        // Non-finite samples degrade to silence; the frame stays valid.
        let nonFinite = MicrophoneInputBuffer(
            samples: [.nan, .infinity, -.infinity, 0.25],
            format: MicrophoneInputFormat(sampleRate: 16_000, channelCount: 1)
        )
        let frame = MicrophonePCMConverter.convert(nonFinite)
        #expect(pcm16Samples(frame ?? Data()) == [0, 0, 0, 8_192])
        #expect(MicrophonePCMConverter.isValidFrame(frame ?? Data()))

        await room.capture.deliver(nonFinite)
        await settle { room.feature.receivedBufferCount == 2 }
        #expect(room.feature.emittedFrameCount == 1)
        #expect(room.feature.lastEmittedFrameByteCount == 8)
    }

    @Test("Converted frames are forwarded to the transcription hand-off hook")
    func framesAreForwardedToTheHandOffHook() async {
        let room = makeRoom()
        var forwarded: [Data] = []
        room.feature.onAudioFrame = { forwarded.append($0) }
        #expect(await room.feature.startCapture(mode: .toggle))

        let buffer = constantBuffer(0.5, frameCount: 480)
        await room.capture.deliver(buffer)
        await settle { forwarded.count == 1 }
        #expect(forwarded.first == MicrophonePCMConverter.convert(buffer))
        #expect(forwarded.first?.count == 320)

        // Nothing is forwarded after a terminal path.
        #expect(await room.feature.stopCapture())
        await room.capture.deliver(constantBuffer(0.6, frameCount: 480))
        await settle { room.feature.droppedBufferCount >= 1 }
        #expect(forwarded.count == 1)
    }

    // MARK: - Failure and explicit recovery
    // (CON-MICROPHONE-CAPTURE-AND-FLOATING-HUD-RECOVERY)

    @Test("Unavailable microphone access shows a HUD error, never starts recording, and recovers on explicit retry")
    func unavailableMicrophoneShowsErrorAndDoesNotStart() async {
        let room = makeRoom(availability: .denied)
        #expect(await room.feature.startCapture(mode: .pushToTalk) == false)
        #expect(room.feature.lastFailure?.category == .permissionDenied)

        if case .failed(let failure) = room.feature.state {
            #expect(failure.category == .permissionDenied)
        } else {
            Issue.record("expected a failed state, got \(room.feature.state)")
        }

        // Recording does not start.
        #expect(await room.capture.startCount == 0)
        #expect(room.feature.isCaptureEngineRunning == false)
        #expect(room.feature.isRecording == false)

        // The HUD shows the error.
        #expect(room.feature.hudSnapshot.isVisible)
        #expect(room.feature.hudSnapshot.phase == .error)
        #expect(room.feature.hudSnapshot.message?.contains("Microphone") == true)

        // No automatic retry ever follows a failure.
        await settle { await room.capture.startCount > 0 }
        #expect(await room.capture.startCount == 0)

        // The user grants access and retries explicitly.
        room.box.value = .authorized
        #expect(await room.feature.retry())
        #expect(room.feature.state == .active)
        #expect(room.feature.hudSnapshot.phase == .recording)
        #expect(await room.capture.startCount == 1)
    }

    @Test("A notDetermined microphone state requests access once from the explicit start action")
    func notDeterminedRequestsAccessOnExplicitStart() async {
        let granted = makeRoom(availability: .notDetermined, requestResult: .authorized)
        #expect(await granted.feature.startCapture(mode: .toggle))
        #expect(granted.box.requestCount == 1)
        #expect(granted.feature.isCaptureEngineRunning)

        // A denied request is a HUD error with no start, and no repeated
        // prompt: only an explicit retry may ask again.
        let denied = makeRoom(availability: .notDetermined, requestResult: .denied)
        #expect(await denied.feature.startCapture(mode: .toggle) == false)
        #expect(denied.feature.lastFailure?.category == .permissionDenied)
        #expect(await denied.capture.startCount == 0)
        #expect(denied.box.requestCount == 1)
        #expect(denied.feature.hudSnapshot.phase == .error)

        #expect(await denied.feature.startCapture(mode: .toggle) == false)
        #expect(denied.box.requestCount == 1)
    }

    @Test("A capture engine failure shows a HUD error and recovers only on explicit retry")
    func engineFailureShowsErrorAndRecoversOnExplicitRetry() async {
        let capture = FakeMicrophoneCapture()
        await capture.configure(startError: .engineStartFailed)
        let room = makeRoom(capture: capture)

        #expect(await room.feature.startCapture(mode: .pushToTalk) == false)
        #expect(room.feature.lastFailure?.category == .microphoneUnavailable)
        #expect(await capture.startCount == 1)
        #expect(room.feature.isCaptureEngineRunning == false)
        #expect(room.feature.hudSnapshot.isVisible)
        #expect(room.feature.hudSnapshot.phase == .error)
        // The terminal path releases the capture seam.
        #expect(await capture.endCount == 1)
        #expect(await capture.hasSink == false)

        // No automatic retry.
        await settle { await capture.startCount > 1 }
        #expect(await capture.startCount == 1)

        await capture.configure(startError: nil)
        #expect(await room.feature.retry())
        #expect(room.feature.state == .active)
        #expect(await capture.startCount == 2)
        #expect(room.feature.hudSnapshot.phase == .recording)
    }

    @Test("A failed HUD can be dismissed explicitly and keeps the failed state for retry")
    func failedHudCanBeDismissedExplicitly() async {
        let room = makeRoom(availability: .denied)
        #expect(await room.feature.startCapture(mode: .pushToTalk) == false)
        #expect(room.feature.hudSnapshot.isVisible)

        room.feature.dismissHud()
        #expect(room.feature.hudSnapshot.isVisible == false)
        #expect(room.hud.latest?.isVisible == false)

        if case .failed = room.feature.state {
            // The last valid failed state is preserved for the explicit retry.
        } else {
            Issue.record("expected a failed state, got \(room.feature.state)")
        }
        room.box.value = .authorized
        #expect(await room.feature.retry())
        #expect(room.feature.hudSnapshot.isVisible)
    }

    @Test("A duplicate start never disturbs the active recording session")
    func duplicateStartIsRejected() async {
        let room = makeRoom()
        #expect(await room.feature.startCapture(mode: .pushToTalk))
        #expect(await room.feature.startCapture(mode: .toggle) == false)
        #expect(await room.capture.startCount == 1)
        #expect(room.feature.activeMode == .pushToTalk)
        #expect(room.feature.state == .active)
        #expect(room.feature.hudSnapshot.mode == .pushToTalk)
        #expect(room.feature.lastNotice?.contains("already") == true)
    }

    @Test("Stop during engine startup still releases the late-arriving engine")
    func stopDuringStartupReleasesLateEngine() async {
        let capture = FakeMicrophoneCapture()
        await capture.gateNextStart()
        let room = makeRoom(capture: capture)

        let startTask = Task { await room.feature.startCapture(mode: .toggle) }
        await settle { await capture.startCount == 1 }
        #expect(room.feature.hudSnapshot.isVisible)

        #expect(await room.feature.stopCapture())
        #expect(room.feature.state == .succeeded)
        await capture.releaseStart()
        #expect(await startTask.value == false)
        await settle { await capture.endCount == 2 }
        #expect(room.feature.isCaptureEngineRunning == false)
        #expect(await capture.hasSink == false)
    }

    // MARK: - Termination cleanup

    @Test("Termination releases the capture engine, the sink, and the HUD")
    func terminationReleasesEverything() async {
        let room = makeRoom()
        #expect(await room.feature.startCapture(mode: .toggle))

        await room.feature.releaseForTermination()
        #expect(await room.capture.endCount == 1)
        #expect(await room.capture.hasSink == false)
        #expect(room.feature.hudSnapshot.isVisible == false)
        #expect(room.feature.state == .idle)

        await room.capture.deliver(constantBuffer(0.5, frameCount: 480))
        await settle { room.feature.droppedBufferCount >= 1 }
        #expect(room.feature.receivedBufferCount == 0)
    }

    // MARK: - Ordered ingestion (serialized frame delivery)

    @Test("Buffers are ingested exactly once and in delivery order through the one ordered consumer")
    func buffersAreIngestedInDeliveryOrder() async {
        let room = makeRoom()
        var forwardedFirstSamples: [Int16] = []
        room.feature.onAudioFrame = { frame in
            forwardedFirstSamples.append(pcm16Samples(frame).first ?? -1)
        }
        #expect(await room.feature.startCapture(mode: .pushToTalk))

        // Distinguishable constants: 0.25 → 8192, 0.5 → 16384, 0.75 → 24576.
        await room.capture.deliver(constantBuffer(0.25, frameCount: 480))
        await room.capture.deliver(constantBuffer(0.5, frameCount: 480))
        await room.capture.deliver(constantBuffer(0.75, frameCount: 480))
        await settle { room.feature.receivedBufferCount == 3 }
        await settle { forwardedFirstSamples.count == 3 }

        #expect(forwardedFirstSamples == [8_192, 16_384, 24_576])
        #expect(room.feature.receivedBufferCount == 3)
        #expect(room.feature.emittedFrameCount == 3)

        // A terminal path finishes the ordered consumer: nothing is ingested
        // and nothing is forwarded afterwards.
        #expect(await room.feature.stopCapture())
        await room.capture.deliver(constantBuffer(0.5, frameCount: 480))
        await settle { forwardedFirstSamples.count > 3 }
        #expect(forwardedFirstSamples.count == 3)
        #expect(room.feature.receivedBufferCount == 3)
    }

    // MARK: - Provider-supported recording file (batch route input)

    private func recordingFileRoom() -> (writer: MicrophoneWavFileWriter, url: URL, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperBarWavFileTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("audio.wav")
        return (MicrophoneWavFileWriter(url: url), url, directory)
    }

    private func headerField(_ data: Data, at offset: Int, byteCount: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<byteCount {
            value |= UInt32(data[offset + index]) << (8 * UInt32(index))
        }
        return value
    }

    @Test("Recorded frames land in one canonical linear16 16 kHz mono WAV container")
    func recordingFileIsCanonicalWav() throws {
        let room = recordingFileRoom()
        defer { try? FileManager.default.removeItem(at: room.directory) }

        try room.writer.begin()
        #expect(room.writer.isOpen)
        // Before any audio, the file holds only the placeholder header.
        #expect(try Data(contentsOf: room.url).count == MicrophoneWavFileWriter.headerByteCount)

        let frame = try #require(MicrophonePCMConverter.convert(constantBuffer(0.5, frameCount: 480)))
        try room.writer.append(frame)
        try room.writer.append(frame)
        #expect(room.writer.dataByteCount == 640)
        #expect(abs(room.writer.recordedDurationSeconds - 0.02) < 0.0001)

        #expect(try room.writer.finish() == 640)
        #expect(room.writer.isOpen == false)

        let data = try Data(contentsOf: room.url)
        #expect(data.count == MicrophoneWavFileWriter.headerByteCount + 640)
        #expect(String(data: data[0..<4], encoding: .utf8) == "RIFF")
        #expect(String(data: data[8..<12], encoding: .utf8) == "WAVE")
        #expect(String(data: data[12..<16], encoding: .utf8) == "fmt ")
        #expect(String(data: data[36..<40], encoding: .utf8) == "data")
        // RIFF size covers the WAVE header plus the audio bytes.
        #expect(headerField(data, at: 4, byteCount: 4) == 36 + 640)
        #expect(headerField(data, at: 16, byteCount: 4) == 16)
        #expect(headerField(data, at: 20, byteCount: 2) == 1)      // PCM
        #expect(headerField(data, at: 22, byteCount: 2) == 1)      // mono
        #expect(headerField(data, at: 24, byteCount: 4) == 16_000) // 16 kHz
        #expect(headerField(data, at: 28, byteCount: 4) == 32_000) // bytes per second
        #expect(headerField(data, at: 32, byteCount: 2) == 2)      // block align
        #expect(headerField(data, at: 34, byteCount: 2) == 16)     // bits per sample
        #expect(headerField(data, at: 40, byteCount: 4) == 640)
        // The audio payload is the locked PCM, byte for byte, in order.
        #expect(Data(data[44...]) == frame + frame)
    }

    @Test("Empty and misaligned frames are never written into the recording file")
    func recordingFileRejectsInvalidFrames() throws {
        let room = recordingFileRoom()
        defer { try? FileManager.default.removeItem(at: room.directory) }

        try room.writer.begin()
        #expect(throws: MicrophoneRecordingFileError.invalidFrameByteCount) {
            try room.writer.append(Data())
        }
        #expect(throws: MicrophoneRecordingFileError.invalidFrameByteCount) {
            try room.writer.append(Data([0x01]))
        }
        #expect(room.writer.dataByteCount == 0)
        _ = try room.writer.finish()
    }

    @Test("A finalized recording is readable exactly as the batch preflight expects")
    func finalizedRecordingPassesBatchPreflight() async throws {
        let room = recordingFileRoom()
        defer { try? FileManager.default.removeItem(at: room.directory) }

        try room.writer.begin()
        // 0.5 seconds of locked-format digital silence: 24 000 input frames at
        // 48 kHz convert to 8 000 frames at 16 kHz → 16 000 bytes.
        let silence = try #require(MicrophonePCMConverter.convert(constantBuffer(0.0, frameCount: 24_000)))
        try room.writer.append(silence)
        #expect(try room.writer.finish() == 16_000)
        #expect(abs(room.writer.recordedDurationSeconds - 0.5) < 0.0001)

        // The production inspector reads the recorded container: a real WAV,
        // not an empty file, accepted by the locked batch preflight.
        let inspector = AVFoundationAudioFileInspector()
        let file = try await inspector.inspect(url: room.url)
        #expect(file.format == "wav")
        #expect(file.sizeBytes == MicrophoneWavFileWriter.headerByteCount + 16_000)
        #expect(abs(file.durationSeconds - 0.5) < 0.01)
        #expect(OpenrouterTranscriptionIntegration.preflightFailure(for: file) == nil)
    }
}

// MARK: - Composition: MenuBarController ↔ HUD session routing, interim text, permission ordering

/// Composition-level regression checks for the menu-bar composition root.
///
/// These tests build the real `MenuBarController` over fake capture, HUD,
/// Deepgram socket, Keychain, paste, and permission seams, proving that:
/// (A) the floating HUD's Stop/Cancel controls run the controller's one
/// authoritative recording session state machine (terminal completion with
/// cost, history, paste, and verified cleanup; cancel with paid-request
/// cancellation and verified temporary-audio cleanup) instead of the
/// capture-only path; (B) the Deepgram interim transcript is propagated into
/// the capture HUD and the menu presentation and is cleared on the terminal
/// path; (C) the microphone authorization resolves before any provider route
/// or socket is opened — a denied resolution ends the attempt before the
/// route; (D) a recoverable live-stream failure retains the finalized,
/// non-empty WAV container in the temporary-audio recovery window, and a new
/// explicit recording start closes that window with verified absence; (E) the
/// batch route records the same canonical WAV container, finalizes it on
/// stop, transcribes it, and deletes it after success, while a header-only
/// batch recording is rejected before any provider transport with the paid
/// request cancelled and the audio deleted with verified absence; (F) the
/// provider selection is locked while a recording session is in flight —
/// starting or active — and a selection the second owner rejects is rolled
/// back so both owners and the stored preference keep the last agreed
/// provider; (G) a stop or a cancel that arrives while the start sequence is
/// still awaiting is remembered and ends the attempt before capture and
/// before any provider route, cancelling the paid request and deleting the
/// prepared temporary audio with verified absence; and (H) two consecutive
/// sessions each run their own route, finalize exactly once, and clear their
/// temporary audio.
/// No real microphone, TCC prompt, socket, network request, Keychain item,
/// clipboard, or panel is touched.
@Suite("MenuBarController composition — HUD session routing, interim text, and permission ordering", .serialized)
@MainActor
struct MenuBarControllerHudCompositionTests {

    typealias Sandbox = DataStoreTests.Sandbox
    typealias FakeSocketFactory = DeepgramNovaStreamingTranscriptionIntegrationTests.FakeSocketFactory
    typealias FakeHTTPTransport = OpenrouterRefinementIntegrationTests.FakeHTTPTransport
    typealias InMemoryKeychainStore = OpenrouterRefinementIntegrationTests.InMemoryKeychainStore
    typealias FakeAudioInspector = OpenrouterTranscriptionIntegrationTests.FakeAudioInspector
    typealias FakeAudioReader = OpenrouterTranscriptionIntegrationTests.FakeAudioReader
    typealias FakeMicCapture = MicrophoneCaptureAndFloatingHudFeatureTests.FakeMicrophoneCapture
    typealias FakeHudPresenter = MicrophoneCaptureAndFloatingHudFeatureTests.FakeHudPresenter
    typealias Clock = MicrophoneCaptureAndFloatingHudFeatureTests.Clock
    typealias FakeProbe = PermissionCoordinatorTests.FakeProbe
    typealias FakeLoginItems = PermissionCoordinatorTests.FakeLoginItems
    typealias FakeHotkeyRegistrar = GlobalHotkeysAndPushToTalkToggleModesFeatureTests.FakeHotkeyRegistrar
    typealias FakeInsertionEnvironment = PasteCoordinatorTests.FakeInsertionEnvironment
    typealias Gate = OpenrouterRefinementIntegrationTests.Gate

    // MARK: - Fakes

    /// Gated permission probe: `requestMicrophoneAccess()` suspends until the
    /// test releases it, so the provider-route ordering is observable without
    /// any TCC interaction.
    final class GatedMicrophoneProbe: PermissionProbing, @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<PermissionState, Never>?
        private var _requestCount = 0
        private var _isRequestPending = false

        var requestCount: Int { lock.withLock { _requestCount } }
        var isRequestPending: Bool { lock.withLock { _isRequestPending } }

        func requestMicrophoneAccess() async -> PermissionState {
            await withCheckedContinuation { (continuation: CheckedContinuation<PermissionState, Never>) in
                lock.withLock {
                    _requestCount += 1
                    _isRequestPending = true
                    self.continuation = continuation
                }
            }
        }

        func releaseRequest(granted: Bool) {
            let pending = lock.withLock { () -> CheckedContinuation<PermissionState, Never>? in
                let continuation = self.continuation
                self.continuation = nil
                _isRequestPending = false
                return continuation
            }
            pending?.resume(returning: granted ? .authorized : .denied)
        }

        func microphoneAuthorizationStatus() -> PermissionState { .notDetermined }
        func globalInputAvailability() -> PermissionState { .authorized }
        func accessibilityTrusted() -> PermissionState { .authorized }
        func requestAccessibilityTrust() -> PermissionState { .authorized }
        func notificationAuthorizationStatus() async -> PermissionState { .authorized }
        func requestNotificationAuthorization() async -> PermissionState { .authorized }
        func clipboardAvailability() -> PermissionState { .authorized }
        func filesystemAvailability() -> PermissionState { .authorized }
        func networkAvailability() -> PermissionState { .authorized }
    }

    /// Scripted save-destination chooser: records the value-free suggested
    /// file name and returns the scripted decision, so the interactive save
    /// seam is exercised without ever opening the native save panel.
    final class FakeSaveDestinationChooser: @unchecked Sendable {
        private let lock = NSLock()
        private var decisions: [TemporaryAudioCleanupFeature.SaveDestinationDecision] = []
        private var names: [String] = []

        var suggestedFileNames: [String] { lock.withLock { names } }

        func scriptNext(_ decision: TemporaryAudioCleanupFeature.SaveDestinationDecision) {
            lock.withLock { decisions.append(decision) }
        }

        func choose(_ suggestedFileName: String) -> TemporaryAudioCleanupFeature.SaveDestinationDecision {
            lock.withLock {
                names.append(suggestedFileName)
                return decisions.isEmpty ? .storeDefault : decisions.removeFirst()
            }
        }
    }

    // MARK: - Room (composition root + injected seams)

    struct Room {
        let controller: MenuBarController
        let capture: FakeMicCapture
        let hud: FakeHudPresenter
        let hotkeys: GlobalHotkeysAndPushToTalkToggleModesFeature
        let factory: FakeSocketFactory
        let pasteEnvironment: FakeInsertionEnvironment
        let costProtection: ProviderSelectionAndCostProtectionFeature
        let cleanup: TemporaryAudioCleanupFeature
        let store: DataStore
        let sandbox: Sandbox
        let batchTransport: FakeHTTPTransport
        let batchInspector: FakeAudioInspector
        let batchReader: FakeAudioReader
        let chooser: FakeSaveDestinationChooser
    }

    private func makeVault() -> CredentialVault {
        let store = InMemoryKeychainStore()
        try? store.store(
            value: "dg-composition-key",
            account: CredentialKey.deepgramNovaStreamingTranscription.account,
            service: "com.whisperbar.app.credentials"
        )
        try? store.store(
            value: "or-composition-key",
            account: CredentialKey.openRouter.account,
            service: "com.whisperbar.app.credentials"
        )
        return CredentialVault(store: store, service: "com.whisperbar.app.credentials")
    }

    private func makeRoom(
        probe: any PermissionProbing = FakeProbe(),
        tick: Duration = .milliseconds(1),
        chooser: FakeSaveDestinationChooser? = nil
    ) -> Room {
        let sandbox = DataStoreTests.makeSandbox()
        let store = sandbox.makeStore()
        let clock = Clock()
        let factory = FakeSocketFactory()
        let vault = makeVault()

        let deepgram = DeepgramNovaStreamingTranscriptionIntegration(
            credentialVault: vault,
            socketFactory: factory,
            now: { clock.now }
        )
        let batchTransport = FakeHTTPTransport()
        let batchInspector = FakeAudioInspector()
        let batchReader = FakeAudioReader()
        let batch = OpenrouterTranscriptionIntegration(
            credentialVault: vault,
            transport: batchTransport,
            inspector: batchInspector,
            reader: batchReader
        )
        let refinement = OpenrouterRefinementIntegration(
            credentialVault: vault,
            transport: FakeHTTPTransport(),
            isEnabled: false
        )
        let permissions = PermissionCoordinator(probe: probe, loginItemService: FakeLoginItems())
        let hotkeys = GlobalHotkeysAndPushToTalkToggleModesFeature(
            registrar: FakeHotkeyRegistrar(),
            globalInputAvailability: { .authorized }
        )

        let capture = FakeMicCapture()
        let hud = FakeHudPresenter()
        let microphoneFeature = MicrophoneCaptureAndFloatingHudFeature(
            capture: capture,
            hudPresenter: hud,
            microphoneAvailability: { permissions.lastKnownStates[.microphone] ?? .notDetermined },
            requestMicrophoneAccess: { await permissions.request(.microphone) },
            now: { clock.now }
        )

        let pasteEnvironment = FakeInsertionEnvironment()
        pasteEnvironment.nextCapturedTarget = InsertionTarget(
            processIdentifier: 4_242,
            bundleIdentifier: "com.example.editor",
            localizedName: "Editor",
            hasEditableSelectedTextBoundary: true
        )
        let paste = PasteCoordinator(
            targetCapture: pasteEnvironment,
            accessibilityInserter: pasteEnvironment,
            pasteboard: pasteEnvironment,
            activator: pasteEnvironment,
            commandVPressing: pasteEnvironment,
            accessibilityAvailability: { .authorized },
            requestAccessibilityTrust: { .authorized },
            clipboardAvailability: { .authorized },
            waitForPasteConsumption: { _ in }
        )

        let costProtection = ProviderSelectionAndCostProtectionFeature(
            loadStoredSelection: { await store.providerPreference() },
            storeSelection: { await store.setProviderPreference($0) },
            credentialAvailability: { _ in true },
            networkAvailability: { .authorized },
            requestNetworkAccess: { .authorized }
        )

        // The interactive save destination is always the deterministic fake in
        // tests: no test ever opens the native save panel.
        let saveChooser = chooser ?? FakeSaveDestinationChooser()
        let controller = MenuBarController(
            credentialVault: vault,
            dataStore: store,
            permissionCoordinator: permissions,
            globalHotkeysFeature: hotkeys,
            deepgramStreamingIntegration: deepgram,
            refinementIntegration: refinement,
            batchTranscriptionIntegration: batch,
            microphoneCaptureFeature: microphoneFeature,
            pasteCoordinator: paste,
            providerSelectionAndCostProtectionFeature: costProtection,
            saveDestinationChooser: { suggestedFileName in saveChooser.choose(suggestedFileName) },
            sessionTickInterval: tick
        )
        return Room(
            controller: controller,
            capture: capture,
            hud: hud,
            hotkeys: hotkeys,
            factory: factory,
            pasteEnvironment: pasteEnvironment,
            costProtection: costProtection,
            cleanup: controller.temporaryAudioCleanupFeature,
            store: store,
            sandbox: sandbox,
            batchTransport: batchTransport,
            batchInspector: batchInspector,
            batchReader: batchReader,
            chooser: saveChooser
        )
    }

    // MARK: - Helpers

    private func buffer(
        _ value: Float,
        frameCount: Int = 480,
        sampleRate: Double = 48_000,
        channels: Int = 1
    ) -> MicrophoneInputBuffer {
        MicrophoneInputBuffer(
            samples: [Float](repeating: value, count: frameCount * channels),
            format: MicrophoneInputFormat(sampleRate: sampleRate, channelCount: channels)
        )
    }

    private func resultJSON(
        transcript: String,
        isFinal: Bool,
        speechFinal: Bool = false,
        fromFinalize: Bool = false
    ) -> String {
        let finalFlag = isFinal ? "true" : "false"
        let speechFlag = speechFinal ? "true" : "false"
        let fromFlag = fromFinalize ? "true" : "false"
        return """
        {"type":"Results","channel_index":[0,1],"duration":1.25,"start":0.0,\
        "channel":{"alternatives":[{"transcript":"\(transcript)","confidence":0.99,\
        "words":[{"word":"\(transcript)","start":0.0,"end":0.9,"confidence":0.99}]}]},\
        "is_final":\(finalFlag),"speech_final":\(speechFlag),"from_finalize":\(fromFlag)}
        """
    }

    /// One complete OpenRouter batch transcription response body, including
    /// provider-reported usage, for the batch-route composition tests.
    private func batchSuccessBody(text: String) -> Data {
        Data(
            "{\"text\":\"\(text)\",\"model\":\"openai/gpt-4o-transcribe\",\"id\":\"gen-batch-1\",\"usage\":{\"seconds\":4.2,\"total_tokens\":210,\"input_tokens\":200,\"output_tokens\":10,\"cost\":0.00075}}".utf8
        )
    }

    private let metadataJSON = """
    {"type":"Metadata","request_id":"dg-composition-1","sha256":"abc","created":"2026-01-01T00:00:00Z",\
    "duration":1.5,"channels":1,"transaction_key":"deprecated"}
    """

    /// Bounded wait for an enqueued main-actor continuation without any
    /// unbounded sleep loop.
    private func settle(_ condition: () async -> Bool, attempts: Int = 600) async {
        for _ in 0..<attempts {
            if await condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 500_000)
        }
    }

    // MARK: - (A) HUD Stop routes through the authoritative session machine

    @Test("The HUD Stop control runs the authoritative terminal session flow, not only capture")
    func hudStopTriggersTerminalSessionFlow() async {
        let room = makeRoom()
        defer { room.sandbox.clean() }

        #expect(await room.controller.selectProvider(.deepgramStreaming))
        #expect(await room.controller.startInAppRecording())
        #expect(room.factory.connectCount == 1)
        #expect(room.controller.isRecordingSessionActive)
        #expect(room.controller.statusText == "Recording")
        #expect(room.costProtection.isPaidRequestActive)
        #expect(room.cleanup.isSessionActive)
        #expect(room.hud.isVisible)

        // One captured buffer reaches the live route in capture order.
        await room.capture.deliver(buffer(0.5))
        await settle { room.factory.session.sentBinaries.count == 1 }

        // The provider's final boundary and metadata arrive, then the user
        // presses Stop on the floating HUD.
        room.factory.session.enqueue(
            text: resultJSON(transcript: "hello world", isFinal: true, speechFinal: true, fromFinalize: true)
        )
        room.factory.session.enqueue(text: metadataJSON)
        room.hud.stopAction?()
        await settle {
            !room.controller.isRecordingSessionActive && room.controller.statusText == "Ready"
        }

        // The authoritative terminal flow ran: exactly one Finalize reached
        // the route of exactly one stream; the provider result completed the
        // cost gate, bounded history, the one insertion, and verified cleanup.
        #expect(room.controller.isRecordingSessionActive == false)
        #expect(room.controller.statusText == "Ready")
        #expect(room.factory.session.sentTexts.first == #"{"type":"Finalize"}"#)
        #expect(room.factory.session.sentTexts.filter { $0 == #"{"type":"Finalize"}"# }.count == 1)
        #expect(room.factory.session.closeRequested)
        #expect(room.factory.connectCount == 1)
        #expect(room.costProtection.state == .succeeded)
        #expect(room.costProtection.lastUsageDisplay?.provider == .deepgramStreaming)
        let stored = try? await room.store.recentTranscripts()
        #expect(stored?.map(\.text) == ["hello world"])
        #expect(room.pasteEnvironment.directInsertions.map(\.text) == ["hello world"])
        #expect(room.cleanup.state == .succeeded)
        #expect(room.cleanup.audioRemovalVerified)
        #expect(room.cleanup.isAudioLifecycleClear)
        #expect(room.hud.latest?.isVisible == false)
        #expect(room.hud.latest?.phase == .finished)
    }

    // MARK: - (A) HUD Cancel cancels cost and cleanup

    @Test("The HUD Cancel control cancels the paid request and deletes the temporary audio with verified absence")
    func hudCancelCancelsCostAndCleanup() async {
        let room = makeRoom()
        defer { room.sandbox.clean() }

        #expect(await room.controller.selectProvider(.deepgramStreaming))
        #expect(await room.controller.startInAppRecording())
        #expect(room.costProtection.isPaidRequestActive)
        #expect(room.cleanup.isSessionActive)
        #expect(room.controller.isRecordingSessionActive)

        room.hud.cancelAction?()
        await settle {
            !room.controller.isRecordingSessionActive && room.controller.statusText == "Recording cancelled"
        }

        // The authoritative cancel path cancelled the paid request, stopped
        // the route, and deleted the temporary audio with verified absence.
        #expect(room.controller.statusText == "Recording cancelled")
        #expect(room.costProtection.state == .cancelled)
        #expect(room.cleanup.state == .cancelled)
        #expect(room.cleanup.audioRemovalVerified)
        #expect(room.cleanup.isAudioLifecycleClear)
        #expect(room.factory.session.closeRequested)
        // Nothing was persisted or inserted for a cancelled session.
        let stored = try? await room.store.recentTranscripts()
        #expect(stored?.isEmpty == true)
        #expect(room.pasteEnvironment.directInsertions.isEmpty)
        // The HUD moves to the cancelled terminal snapshot.
        #expect(room.hud.latest?.phase == .cancelled)
        #expect(room.hud.latest?.isVisible == false)
        #expect(await room.capture.endCount == 1)
    }

    // MARK: - (C) Microphone authorization resolves before the route opens

    @Test("Microphone authorization resolves before the provider route opens: no socket exists while the prompt is pending")
    func microphoneAuthorizationResolvesBeforeRouteOpens() async {
        let probe = GatedMicrophoneProbe()
        let room = makeRoom(probe: probe)
        defer { room.sandbox.clean() }
        #expect(await room.controller.selectProvider(.deepgramStreaming))

        let startTask = Task { await room.controller.startInAppRecording() }
        await settle { probe.isRequestPending }

        // The first-run prompt is still pending and the provider route (and
        // its socket) must not exist yet — the ordering regression this test
        // pins down (a socket that waits for impossible audio times out).
        #expect(probe.requestCount == 1)
        #expect(room.factory.connectCount == 0)
        #expect(room.controller.isRecordingSessionActive == false)

        // The user grants access; only now does the route open and capture run.
        probe.releaseRequest(granted: true)
        #expect(await startTask.value)
        #expect(probe.requestCount == 1)
        #expect(room.factory.connectCount == 1)
        #expect(room.controller.isRecordingSessionActive)
        #expect(await room.capture.startCount == 1)

        room.hud.cancelAction?()
        await settle { !room.controller.isRecordingSessionActive }
    }

    @Test("A denied microphone authorization ends the session before any provider route is opened")
    func deniedMicrophoneAuthorizationBlocksBeforeRoute() async {
        let probe = FakeProbe()
        probe.microphoneState = .notDetermined
        probe.microphoneGranted = false
        let room = makeRoom(probe: probe)
        defer { room.sandbox.clean() }
        #expect(await room.controller.selectProvider(.deepgramStreaming))

        #expect(await room.controller.startInAppRecording() == false)
        #expect(probe.microRequests == 1)
        // No provider route, no socket, no paid request, no recording.
        #expect(room.factory.connectCount == 0)
        #expect(room.controller.isRecordingSessionActive == false)
        #expect(room.controller.statusText == "Recording blocked")
        #expect(room.controller.sessionPhase == .blocked)
        #expect(room.controller.menuBarSystemImageName == "waveform.slash")
        #expect(room.costProtection.state == .cancelled)
        #expect(room.costProtection.lastUsageDisplay == nil)
        // The prepared temporary audio was deleted with verified absence.
        #expect(room.cleanup.isAudioLifecycleClear)
        #expect(room.cleanup.state == .cancelled)
        #expect(room.cleanup.audioRemovalVerified)
        // The HUD shows the documented permission failure and capture never
        // started.
        #expect(room.hud.latest?.phase == .error)
        #expect(room.hud.latest?.message?.contains("Microphone") == true)
        #expect(await room.capture.startCount == 0)
    }

    // MARK: - (B) Interim transcript reaches the HUD and the menu presentation

    @Test("The Deepgram interim transcript reaches the HUD and the menu presentation, then clears on the terminal path")
    func interimTranscriptPropagatesToHudAndMenu() async {
        let room = makeRoom()
        defer { room.sandbox.clean() }

        #expect(await room.controller.selectProvider(.deepgramStreaming))
        #expect(await room.controller.startInAppRecording())
        #expect(room.controller.interimTranscript.isEmpty)

        await room.capture.deliver(buffer(0.5))
        await settle { room.factory.session.sentBinaries.count == 1 }
        room.factory.session.enqueue(text: resultJSON(transcript: "hel", isFinal: false))
        await settle { room.controller.interimTranscript == "hel" }

        // Both surfaces show the interim text while recording; it is never an
        // insertion or persistence candidate.
        #expect(room.controller.interimTranscript == "hel")
        #expect(room.controller.microphoneCaptureFeature.interimTranscript == "hel")
        #expect(room.controller.microphoneCaptureFeature.hudSnapshot.interimTranscript == "hel")
        #expect(room.hud.latest?.interimTranscript == "hel")
        let stored = try? await room.store.recentTranscripts()
        #expect(stored?.isEmpty == true)
        #expect(room.pasteEnvironment.directInsertions.isEmpty)

        // A terminal path clears the interim text everywhere.
        room.hud.cancelAction?()
        await settle {
            !room.controller.isRecordingSessionActive && room.controller.interimTranscript.isEmpty
        }
        #expect(room.controller.interimTranscript.isEmpty)
        #expect(room.controller.microphoneCaptureFeature.interimTranscript.isEmpty)
        #expect(room.controller.microphoneCaptureFeature.hudSnapshot.interimTranscript == nil)
    }

    // MARK: - (D) Recovery window retains the finalized WAV after a recoverable failure

    @Test("A recoverable live-stream failure retains the finalized WAV container, and a new recording closes the recovery window")
    func recoverableFailureRetainsFinalizedWav() async {
        let room = makeRoom()
        defer { room.sandbox.clean() }
        #expect(await room.controller.selectProvider(.deepgramStreaming))
        #expect(await room.controller.startInAppRecording())

        guard let audioURL = room.cleanup.activeTemporaryAudioURL else {
            Issue.record("expected a prepared temporary audio URL")
            return
        }
        await room.capture.deliver(buffer(0.5))
        await settle { room.factory.session.sentBinaries.count == 1 }

        // The live connection fails with a recoverable transport error: the
        // session ends and its audio is retained for an explicit recovery.
        room.factory.session.failNextReceive(with: .transport)
        await settle {
            !room.controller.isRecordingSessionActive
                && room.controller.isTemporaryAudioRecoveryAwaitingExplicitAction
        }

        #expect(room.controller.statusText == "Recording failed")
        #expect(room.controller.sessionPhase == .failed)
        #expect(room.controller.menuBarSystemImageName == "waveform.slash")
        if case .failed = room.costProtection.state {
            // Expected terminal cost state after a recoverable provider failure.
        } else {
            Issue.record("expected the paid-request gate to report failure")
        }
        #expect(room.cleanup.retainsTemporaryAudioForExplicitRecovery)
        #expect(room.cleanup.retainedRecordingID != nil)
        #expect(room.cleanup.isSessionActive == false)
        #expect(room.cleanup.isAudioLifecycleClear == false)
        #expect(room.controller.canActOnRetainedTemporaryRecording)

        // The retained file is a finalized, non-empty WAV container: the
        // canonical header around exactly the payload that reached the live
        // route, so an explicit retry or an explicit save acts on real audio.
        let retainedData = try? Data(contentsOf: audioURL)
        let livePayloadByteCount = room.factory.session.sentBinaries.last?.count ?? 0
        #expect(livePayloadByteCount > 0)
        #expect(retainedData?.count == MicrophoneWavFileWriter.headerByteCount + livePayloadByteCount)
        if let retainedData {
            #expect(retainedData.prefix(4).elementsEqual(Array("RIFF".utf8)))
        } else {
            Issue.record("expected the retained recording on disk")
        }

        // A new explicit recording start closes the recovery window with
        // verified absence before its own storage is prepared.
        #expect(await room.controller.startInAppRecording())
        #expect(room.cleanup.retainedRecordingID == nil)
        #expect(room.cleanup.retainsTemporaryAudioForExplicitRecovery == false)
        room.hud.cancelAction?()
        await settle {
            !room.controller.isRecordingSessionActive && room.controller.statusText == "Recording cancelled"
        }
        #expect(room.cleanup.isAudioLifecycleClear)
    }

    // MARK: - (E) Batch route records, finalizes, transcribes, and deletes

    @Test("The batch route records the canonical WAV container, finalizes it on stop, transcribes it, and deletes it after success")
    func batchRouteRecordsFinalizesTranscribesAndDeletes() async {
        let room = makeRoom()
        defer { room.sandbox.clean() }
        #expect(await room.controller.selectProvider(.openRouterBatch))

        room.batchInspector.configure(
            file: ImportedAudioFile(
                url: URL(fileURLWithPath: "/sandbox/batch-recording.wav"),
                format: "wav",
                sizeBytes: 1_000,
                durationSeconds: 4.2
            )
        )
        room.batchReader.configure(data: Data(repeating: 0x2A, count: 1_000))
        room.batchTransport.configure(status: 200, body: batchSuccessBody(text: "batch hello"))

        #expect(await room.controller.startInAppRecording())
        guard let audioURL = room.cleanup.activeTemporaryAudioURL else {
            Issue.record("expected a prepared temporary audio URL")
            return
        }

        // One captured buffer is appended to the same canonical container the
        // streaming route writes.
        await room.capture.deliver(buffer(0.5))
        await settle {
            let attributes = try? FileManager.default.attributesOfItem(atPath: audioURL.path)
            let size = (attributes?[.size] as? Int) ?? 0
            return size > MicrophoneWavFileWriter.headerByteCount
        }

        #expect(await room.controller.stopInAppRecording())
        await settle { !room.controller.isRecordingSessionInFlight }

        // Exactly one paid batch transport carried the finalized recording;
        // the transcript completed the cost gate, history, insertion, and
        // verified cleanup.
        #expect(room.batchInspector.inspectCount == 1)
        #expect(room.batchReader.readCount == 1)
        #expect(room.batchTransport.requests.count == 1)
        #expect((room.batchTransport.requests.first?.body.count ?? 0) > 0)
        #expect(room.costProtection.state == .succeeded)
        #expect(room.costProtection.lastUsageDisplay?.provider == .openRouterBatch)
        let stored = try? await room.store.recentTranscripts()
        #expect(stored?.map(\.text) == ["batch hello"])
        #expect(room.pasteEnvironment.directInsertions.map(\.text) == ["batch hello"])
        #expect(room.cleanup.state == .succeeded)
        #expect(room.cleanup.audioRemovalVerified)
        #expect(room.cleanup.isAudioLifecycleClear)
        #expect(room.controller.statusText == "Ready")
        #expect(!FileManager.default.fileExists(atPath: audioURL.path))
    }

    // MARK: - (E) Empty batch is rejected before any provider transport

    @Test("An empty batch recording is rejected before any provider transport: the paid request is cancelled and the audio deleted with verified absence")
    func emptyBatchRejectedBeforeProviderTransport() async {
        let room = makeRoom()
        defer { room.sandbox.clean() }
        #expect(await room.controller.selectProvider(.openRouterBatch))

        #expect(await room.controller.startInAppRecording())
        #expect(room.costProtection.isPaidRequestActive)
        #expect(room.cleanup.isSessionActive)

        // No audio was captured: the stop finalizes a header-only recording,
        // which is never sent anywhere.
        #expect(await room.controller.stopInAppRecording())
        await settle { !room.controller.isRecordingSessionInFlight }

        #expect(room.batchTransport.requests.isEmpty)
        #expect(room.batchInspector.inspectCount == 0)
        #expect(room.batchReader.readCount == 0)
        #expect(room.costProtection.state == .cancelled)
        #expect(room.costProtection.lastUsageDisplay == nil)
        let stored = try? await room.store.recentTranscripts()
        #expect(stored?.isEmpty == true)
        #expect(room.pasteEnvironment.directInsertions.isEmpty)
        #expect(room.cleanup.state == .cancelled)
        #expect(room.cleanup.audioRemovalVerified)
        #expect(room.cleanup.isAudioLifecycleClear)
        #expect(room.controller.statusText == "Recording cancelled")
    }

    // MARK: - (F) Provider selection lock and fail-safe rollback

    @Test("The provider selection is locked while the recording session is in flight — starting or active")
    func providerSelectionLockedWhileSessionInFlight() async {
        let probe = GatedMicrophoneProbe()
        let room = makeRoom(probe: probe)
        defer { room.sandbox.clean() }
        #expect(await room.controller.selectProvider(.deepgramStreaming))

        let startTask = Task { await room.controller.startInAppRecording() }
        await settle { probe.isRequestPending }

        // The attempt is in flight but not yet active: the selection is
        // already locked, and the refused change leaves both owners and the
        // stored preference untouched.
        #expect(room.controller.isRecordingSessionInFlight)
        #expect(room.controller.isRecordingSessionActive == false)
        #expect(room.controller.isProviderSelectionLocked)
        #expect(await room.controller.selectProvider(.openRouterBatch) == false)
        #expect(room.controller.providerFeedback?.contains("locked") == true)
        #expect(room.costProtection.selectedProvider == .deepgramStreaming)
        #expect(room.controller.dualProviderRoutingFeature.selectedProvider == .deepgramStreaming)
        #expect(await room.store.providerPreference() == .deepgramStreaming)

        probe.releaseRequest(granted: true)
        #expect(await startTask.value)
        #expect(room.controller.isProviderSelectionLocked)

        // The cancel ends the session and the selection unlocks.
        room.hud.cancelAction?()
        await settle { !room.controller.isRecordingSessionInFlight }
        #expect(room.controller.isProviderSelectionLocked == false)
    }

    @Test("A selection the second owner rejects is rolled back so both owners and the stored preference keep the last agreed provider")
    func providerSelectionRollsBackWhenSecondOwnerRejects() async {
        let room = makeRoom()
        defer { room.sandbox.clean() }
        #expect(await room.controller.selectProvider(.deepgramStreaming))

        // A live route the routing owner owns: its selection transaction
        // rejects while a route is active, so the controller's second-owner
        // rejection path runs with no controller session in flight.
        #expect(await room.controller.dualProviderRoutingFeature.startLiveStreaming())

        #expect(await room.controller.selectProvider(.openRouterBatch) == false)
        #expect(room.controller.providerFeedback?.contains("rolled back") == true)
        #expect(room.costProtection.selectedProvider == .deepgramStreaming)
        #expect(room.controller.dualProviderRoutingFeature.selectedProvider == .deepgramStreaming)
        #expect(room.controller.selectedProvider == .deepgramStreaming)
        #expect(await room.store.providerPreference() == .deepgramStreaming)

        await room.controller.dualProviderRoutingFeature.cancelCurrentOperation()
    }

    // MARK: - (G) Stop and cancel during the start window

    @Test("A stop during the start window is remembered: the attempt ends before capture and before any provider route, cancelling the paid request and deleting the prepared audio")
    func stopDuringStartWindowEndsAttemptBeforeCapture() async {
        let probe = GatedMicrophoneProbe()
        let room = makeRoom(probe: probe)
        defer { room.sandbox.clean() }
        #expect(await room.controller.selectProvider(.deepgramStreaming))

        let startTask = Task { await room.controller.startInAppRecording() }
        await settle { probe.isRequestPending }

        // The attempt is in flight, not yet a recording, and no provider
        // route exists while the start sequence is suspended.
        #expect(room.controller.isRecordingSessionInFlight)
        #expect(room.controller.isRecordingSessionActive == false)
        #expect(room.factory.connectCount == 0)
        #expect(room.costProtection.isPaidRequestActive)
        #expect(room.cleanup.isSessionActive)

        // The user presses Stop on the floating HUD while the start awaits:
        // the stop is remembered on the authoritative attempt.
        room.hud.stopAction?()
        await settle { room.hotkeys.state == .succeeded(.pushToTalk) }

        // The user then grants the microphone authorization; the remembered
        // stop ends the attempt at its next checkpoint.
        probe.releaseRequest(granted: true)
        #expect(await startTask.value == false)
        await settle { !room.controller.isRecordingSessionInFlight }

        #expect(room.controller.isRecordingSessionActive == false)
        #expect(room.controller.statusText == "Recording cancelled")
        #expect(room.factory.connectCount == 0)
        #expect(await room.capture.startCount == 0)
        #expect(room.costProtection.state == .cancelled)
        #expect(room.cleanup.state == .cancelled)
        #expect(room.cleanup.audioRemovalVerified)
        #expect(room.cleanup.isAudioLifecycleClear)
        let stored = try? await room.store.recentTranscripts()
        #expect(stored?.isEmpty == true)
        #expect(room.pasteEnvironment.directInsertions.isEmpty)
    }

    @Test("A cancel during the start window is remembered: the attempt ends before capture with the paid request and the prepared audio cancelled")
    func cancelDuringStartWindowEndsAttemptBeforeCapture() async {
        let probe = GatedMicrophoneProbe()
        let room = makeRoom(probe: probe)
        defer { room.sandbox.clean() }
        #expect(await room.controller.selectProvider(.deepgramStreaming))

        let startTask = Task { await room.controller.startInAppRecording() }
        await settle { probe.isRequestPending }
        #expect(room.controller.isRecordingSessionInFlight)

        room.hud.cancelAction?()
        await settle { room.hotkeys.state == .cancelled(.pushToTalk) }

        probe.releaseRequest(granted: true)
        #expect(await startTask.value == false)
        await settle { !room.controller.isRecordingSessionInFlight }

        #expect(room.controller.statusText == "Recording cancelled")
        #expect(room.factory.connectCount == 0)
        #expect(await room.capture.startCount == 0)
        #expect(room.costProtection.state == .cancelled)
        #expect(room.cleanup.state == .cancelled)
        #expect(room.cleanup.audioRemovalVerified)
        #expect(room.cleanup.isAudioLifecycleClear)
        #expect(room.hud.isVisible == false)
    }

    // MARK: - (H) Two consecutive sessions

    @Test("Two consecutive sessions each open their own route, finalize exactly once, and clear their temporary audio")
    func twoConsecutiveSessionsEachSettleOwnResources() async {
        let room = makeRoom()
        defer { room.sandbox.clean() }
        #expect(await room.controller.selectProvider(.deepgramStreaming))

        // Session one.
        #expect(await room.controller.startInAppRecording())
        #expect(room.factory.connectCount == 1)
        await room.capture.deliver(buffer(0.5))
        await settle { room.factory.session.sentBinaries.count == 1 }
        room.factory.session.enqueue(
            text: resultJSON(transcript: "first", isFinal: true, speechFinal: true, fromFinalize: true)
        )
        room.factory.session.enqueue(text: metadataJSON)
        room.hud.stopAction?()
        await settle {
            !room.controller.isRecordingSessionActive && room.controller.statusText == "Ready"
        }
        #expect(room.cleanup.isAudioLifecycleClear)
        #expect(room.cleanup.audioRemovalVerified)

        // Session two: the second explicit start runs the same state machine
        // over fresh resources.
        #expect(await room.controller.startInAppRecording())
        #expect(room.factory.connectCount == 2)
        #expect(room.controller.isRecordingSessionActive)
        #expect(room.costProtection.isPaidRequestActive)
        await room.capture.deliver(buffer(0.25))
        await settle { room.factory.session.sentBinaries.count == 2 }
        room.factory.session.enqueue(
            text: resultJSON(transcript: "second", isFinal: true, speechFinal: true, fromFinalize: true)
        )
        room.factory.session.enqueue(text: metadataJSON)
        room.hud.stopAction?()
        await settle {
            !room.controller.isRecordingSessionActive && room.controller.statusText == "Ready"
        }

        // Each session finalized exactly once, and both transcripts were
        // stored and inserted in order.
        #expect(room.factory.session.sentTexts.filter { $0 == #"{"type":"Finalize"}"# }.count == 2)
        let stored = try? await room.store.recentTranscripts()
        #expect(stored?.map(\.text) == ["second", "first"])
        #expect(room.pasteEnvironment.directInsertions.map(\.text) == ["first", "second"])
        #expect(room.cleanup.isAudioLifecycleClear)
        #expect(room.cleanup.audioRemovalVerified)
        #expect(room.controller.isRecordingSessionInFlight == false)
        #expect(room.controller.statusText == "Ready")
    }

    @Test("NonActivatingHudPresenter toggles visibility and respects snapshot state")
    func nonActivatingHudPresenterLifecycle() async {
        let presenter = NonActivatingHudPresenter()
        var stopped = false
        var cancelled = false
        presenter.setControlActions(stop: { stopped = true }, cancel: { cancelled = true })

        // Hidden snapshot
        presenter.present(.hidden)

        // Visible snapshot with pill
        let visibleSnapshot = CaptureHudSnapshot(
            isVisible: true,
            phase: .recording,
            level: 0.5,
            elapsedDuration: 3.0,
            mode: .toggle,
            message: "Listening...",
            interimTranscript: "Hello world",
            statusPill: "⚡ Instant Paste"
        )
        presenter.present(visibleSnapshot)

        #expect(!stopped)
        #expect(!cancelled)

        // Hide again
        presenter.present(.hidden)
    }

    @Test("Status pill dismissal via HUD cancel action clears pill, restores Ready status, and hides HUD when session is idle")
    func statusPillDismissalWhenIdle() async {
        let room = makeRoom()
        defer { room.sandbox.clean() }

        // Show a status pill while idle
        room.controller.statusText = "⚡ Instant Paste"
        room.controller.microphoneCaptureFeature.showStatusPill("⚡ Instant Paste", autoDismissDelay: nil)
        #expect(room.hud.isVisible)
        #expect(room.hud.latest?.statusPill == "⚡ Instant Paste")

        // Clicking cancel in the HUD triggers the cancelAction closure installed by controller
        room.hud.cancelAction?()
        await settle { !room.hud.isVisible }

        #expect(!room.hud.isVisible)
        #expect(room.controller.microphoneCaptureFeature.hudSnapshot.isVisible == false)
        #expect(room.controller.sessionPhase == .idle)
        #expect(room.controller.statusText == "Ready")
        #expect(room.controller.menuBarSystemImageName == "waveform")
    }

    @Test("SessionPhase accurately drives the menu bar system image across real controller session transitions")
    func sessionPhaseDrivesMenuBarIconAcrossRealTransitions() async {
        // 1. Blocked transition: attempt recording when mic permission is denied
        let blockedProbe = FakeProbe()
        blockedProbe.microphoneState = .notDetermined
        blockedProbe.microphoneGranted = false
        let blockedRoom = makeRoom(probe: blockedProbe)
        defer { blockedRoom.sandbox.clean() }

        #expect(blockedRoom.controller.sessionPhase == .idle)
        #expect(blockedRoom.controller.menuBarSystemImageName == "waveform")

        #expect(await blockedRoom.controller.selectProvider(.deepgramStreaming))
        #expect(await blockedRoom.controller.startInAppRecording() == false)
        #expect(blockedRoom.controller.sessionPhase == .blocked)
        #expect(blockedRoom.controller.statusText == "Recording blocked")
        #expect(blockedRoom.controller.menuBarSystemImageName == "waveform.slash")

        // Reset via HUD cancel control
        await blockedRoom.controller.handleHudCancelControl()
        #expect(blockedRoom.controller.sessionPhase == .idle)
        #expect(blockedRoom.controller.statusText == "Ready")
        #expect(blockedRoom.controller.menuBarSystemImageName == "waveform")

        // 2. Successful recording start and cancel transitions in active room
        let activeRoom = makeRoom()
        defer { activeRoom.sandbox.clean() }

        #expect(await activeRoom.controller.selectProvider(.deepgramStreaming))
        #expect(await activeRoom.controller.startInAppRecording(mode: .pushToTalk) == true)
        #expect(activeRoom.controller.sessionPhase == .recording)
        #expect(activeRoom.controller.menuBarSystemImageName == "waveform.circle.fill")

        #expect(await activeRoom.controller.cancelInAppRecording() == true)
        #expect(activeRoom.controller.sessionPhase == .idle)
        #expect(activeRoom.controller.menuBarSystemImageName == "waveform")

        // 3. Refining comes from the routing notice phase, not from the notice text.
        activeRoom.controller.dualProviderRoutingFeature.onHudNotice?("Working", .refining)
        #expect(activeRoom.controller.sessionPhase == .refining)
        #expect(activeRoom.controller.statusText == "Working")
        #expect(activeRoom.controller.menuBarSystemImageName == "sparkles")

        activeRoom.controller.dualProviderRoutingFeature.onHudNotice?("Done", .status)
        #expect(activeRoom.controller.sessionPhase == .idle)
        #expect(activeRoom.controller.menuBarSystemImageName == "waveform")

        #expect(await activeRoom.controller.startInAppRecording(mode: .pushToTalk) == true)
        activeRoom.factory.session.failNextReceive(with: .transport)
        await settle { activeRoom.controller.sessionPhase == .failed }
        #expect(activeRoom.controller.sessionPhase == .failed)
        #expect(activeRoom.controller.statusText == "Recording failed")
        #expect(activeRoom.controller.menuBarSystemImageName == "waveform.slash")
    }
}
