import AppKit
import AVFoundation
import Foundation
import SwiftUI

// MARK: - Input value types

/// The format of one delivered microphone input buffer, in the input's own
/// sample rate and channel layout. Conversion to the locked PCM contract
/// happens in `MicrophonePCMConverter`, never in the capture adapter.
struct MicrophoneInputFormat: Equatable, Sendable {
    let sampleRate: Double
    let channelCount: Int
}

/// One interleaved float input buffer copied off the input device. The live
/// adapter only forwards samples; it holds no audio state of its own.
struct MicrophoneInputBuffer: Equatable, Sendable {
    let samples: [Float]
    let format: MicrophoneInputFormat
}

// MARK: - Capture seam (CON-MICROPHONE-CAPTURE-AND-FLOATING-HUD-INTERFACE)

/// Privacy-safe capture failures. No case carries audio content or device
/// identity.
enum MicrophoneCaptureError: Error, Equatable, Sendable {
    case deviceUnavailable
    case engineStartFailed
}

/// Injectable microphone boundary so tests never open a real microphone, a
/// real audio engine, or a TCC prompt.
protocol MicrophoneCapturing: Sendable {
    /// Starts the input device and returns its native format. Called only
    /// from an explicit user-started recording.
    func beginCapture() async throws -> MicrophoneInputFormat
    /// Stops the input device. Safe to call on every terminal path, including
    /// when capture never started.
    func endCapture() async
    /// Installs the single buffer sink. `nil` clears it so no delegate or
    /// callback outlives a terminal path.
    func setBufferSink(_ sink: (@Sendable (MicrophoneInputBuffer) -> Void)?) async
}

// MARK: - Live AVAudioEngine adapter

/// Live capture adapter. The engine is created only when an explicit
/// recording starts, so construction and launch touch no device and raise no
/// prompt. The audio thread only copies samples and forwards them; every
/// allocation, conversion, and state change happens on the main actor.
final class SystemMicrophoneCapture: MicrophoneCapturing, @unchecked Sendable {

    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var sink: (@Sendable (MicrophoneInputBuffer) -> Void)?

    func setBufferSink(_ sink: (@Sendable (MicrophoneInputBuffer) -> Void)?) async {
        lock.withLock { self.sink = sink }
    }

    func beginCapture() async throws -> MicrophoneInputFormat {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MicrophoneCaptureError.deviceUnavailable
        }

        let channelCount = Int(format.channelCount)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let channels = buffer.floatChannelData else { return }
            let sink = self.lock.withLock { self.sink }
            guard let sink else { return }
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { return }
            var samples = [Float](repeating: 0, count: frameCount * channelCount)
            for channel in 0..<channelCount {
                let source = channels[channel]
                for frame in 0..<frameCount {
                    samples[frame * channelCount + channel] = source[frame]
                }
            }
            sink(
                MicrophoneInputBuffer(
                    samples: samples,
                    format: MicrophoneInputFormat(
                        sampleRate: buffer.format.sampleRate,
                        channelCount: channelCount
                    )
                )
            )
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw MicrophoneCaptureError.engineStartFailed
        }
        lock.withLock { self.engine = engine }
        return MicrophoneInputFormat(sampleRate: format.sampleRate, channelCount: channelCount)
    }

    func endCapture() async {
        let engine = lock.withLock { () -> AVAudioEngine? in
            let existing = self.engine
            self.engine = nil
            return existing
        }
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

// MARK: - PCM conversion (TRD audio contract)

/// Converts captured input into the locked audio contract: raw headerless
/// linear16, 16-bit little-endian signed PCM at 16000 Hz and one channel, and
/// emits only non-empty data aligned to two-byte samples. The conversion is a
/// pure function over delivered buffers, so it is fully unit-testable without
/// an audio device.
enum MicrophonePCMConverter {

    static let targetSampleRateHz: Double = 16_000
    static let targetChannelCount = 1
    static let bytesPerSample = 2

    /// Converts one buffer. Returns `nil` when the buffer carries no complete
    /// input frame or a malformed format; an empty or odd-length result is
    /// never produced.
    static func convert(_ buffer: MicrophoneInputBuffer) -> Data? {
        let format = buffer.format
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else {
            return nil
        }
        let channelCount = format.channelCount
        let inputFrames = buffer.samples.count / channelCount
        guard inputFrames > 0 else { return nil }

        let outputFrames = max(
            1,
            Int((Double(inputFrames) * targetSampleRateHz / format.sampleRate).rounded())
        )
        let step = format.sampleRate / targetSampleRateHz

        var bytes: [UInt8] = []
        bytes.reserveCapacity(outputFrames * bytesPerSample)
        for index in 0..<outputFrames {
            let sample: Float
            if format.sampleRate == targetSampleRateHz {
                sample = downmixedSample(buffer.samples, channelCount: channelCount, frameIndex: index)
            } else {
                let position = Double(index) * step
                let lowerIndex = min(Int(position), inputFrames - 1)
                let upperIndex = min(lowerIndex + 1, inputFrames - 1)
                let fraction = Float(position - Double(lowerIndex))
                let lower = downmixedSample(buffer.samples, channelCount: channelCount, frameIndex: lowerIndex)
                let upper = downmixedSample(buffer.samples, channelCount: channelCount, frameIndex: upperIndex)
                sample = lower + (upper - lower) * fraction
            }
            let quantized = quantize(sample)
            let raw = UInt16(bitPattern: quantized)
            bytes.append(UInt8(raw & 0xFF))
            bytes.append(UInt8(raw >> 8))
        }
        return Data(bytes)
    }

    /// The binary-frame gate shared with the streaming integration: non-empty
    /// data aligned to two-byte samples.
    static func isValidFrame(_ data: Data) -> Bool {
        !data.isEmpty && data.count % bytesPerSample == 0
    }

    /// Normalized 0...1 input level (RMS) for the HUD's live meter. Non-finite
    /// samples contribute digital silence.
    static func normalizedLevel(samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for sample in samples {
            let value = sample.isFinite ? Double(sample) : 0
            sum += value * value
        }
        let rms = (sum / Double(samples.count)).squareRoot()
        return Float(min(max(rms, 0), 1))
    }

    // MARK: Internals

    /// Downmixes one frame across all channels; non-finite samples count as
    /// digital silence instead of propagating a NaN or an infinity.
    private static func downmixedSample(_ samples: [Float], channelCount: Int, frameIndex: Int) -> Float {
        var sum: Float = 0
        for channel in 0..<channelCount {
            let value = samples[frameIndex * channelCount + channel]
            sum += value.isFinite ? value : 0
        }
        return sum / Float(channelCount)
    }

    private static func quantize(_ value: Float) -> Int16 {
        guard value.isFinite else { return 0 }
        let clamped = Swift.min(Swift.max(value, -1), 1)
        let scaled = Int((clamped * 32_768).rounded())
        return Int16(clamping: scaled)
    }
}

// MARK: - Provider-supported recording file (locked PCM in a WAV container)

/// The single recording-file failure surface: nothing here carries audio
/// content, file paths, or device identity.
enum MicrophoneRecordingFileError: Error, Equatable, Sendable {
    case fileUnavailable
    case invalidFrameByteCount
}

/// Appends captured locked-format PCM frames to one finalized WAV file, so a
/// batch transcription route is given real recorded audio in a
/// provider-supported container instead of an empty file.
///
/// The container is exactly `wav`: a 44-byte RIFF/WAVE header around the
/// headerless linear16 16 kHz mono PCM that `MicrophonePCMConverter` already
/// produces. No transcode, no second encoding, and no other format is ever
/// written; the header is rewritten exactly once with the final sizes when the
/// recording stops, and `finish()` closes the file so nothing outlives the
/// session.
@MainActor
final class MicrophoneWavFileWriter {

    /// The canonical RIFF header length for the locked 16-bit PCM layout.
    static let headerByteCount = 44

    private let url: URL
    private let fileManager: FileManager
    private var handle: FileHandle?
    /// The number of audio (non-header) bytes written so far.
    private(set) var dataByteCount = 0

    init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    /// True only while the file is open for appends and not yet finalized.
    var isOpen: Bool { handle != nil }

    /// The locked recording duration of the bytes written so far, derived from
    /// the locked sample rate and contained entirely in the audio contract.
    var recordedDurationSeconds: Double {
        Double(dataByteCount) / (MicrophonePCMConverter.targetSampleRateHz * Double(MicrophonePCMConverter.bytesPerSample))
    }

    /// Creates or truncates the recording file and writes the placeholder
    /// header. The file it writes is always inside the temporary location the
    /// temporary-audio owner prepared.
    func begin() throws {
        guard handle == nil else { return }
        if !fileManager.fileExists(atPath: url.path) {
            _ = fileManager.createFile(atPath: url.path, contents: nil)
        }
        let opened: FileHandle
        do {
            opened = try FileHandle(forWritingTo: url)
            try opened.truncate(atOffset: 0)
            try opened.write(contentsOf: Self.header(dataByteCount: 0))
        } catch {
            handle = nil
            throw MicrophoneRecordingFileError.fileUnavailable
        }
        handle = opened
        dataByteCount = 0
    }

    /// Appends one locked-format PCM frame. Empty or misaligned data is never
    /// written: an invalid frame must not corrupt the recording.
    func append(_ pcm: Data) throws {
        guard let handle else { throw MicrophoneRecordingFileError.fileUnavailable }
        guard !pcm.isEmpty, pcm.count % MicrophonePCMConverter.bytesPerSample == 0 else {
            throw MicrophoneRecordingFileError.invalidFrameByteCount
        }
        do {
            try handle.write(contentsOf: pcm)
        } catch {
            throw MicrophoneRecordingFileError.fileUnavailable
        }
        dataByteCount += pcm.count
    }

    /// Finalizes the RIFF sizes, flushes, and closes the file exactly once.
    /// Returns the number of recorded audio bytes.
    @discardableResult
    func finish() throws -> Int {
        guard let handle else { return dataByteCount }
        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: Self.header(dataByteCount: dataByteCount))
            try handle.synchronize()
            try handle.close()
        } catch {
            self.handle = nil
            throw MicrophoneRecordingFileError.fileUnavailable
        }
        self.handle = nil
        return dataByteCount
    }

    /// Abandons the recording without finalizing. Used only by terminal paths
    /// that discard the recording; no removal is claimed here.
    func cancel() {
        try? handle?.close()
        handle = nil
    }

    // MARK: Header construction (little-endian canonical RIFF/WAVE)

    private static func header(dataByteCount: Int) -> Data {
        let channelCount = UInt16(MicrophonePCMConverter.targetChannelCount)
        let sampleRate = UInt32(MicrophonePCMConverter.targetSampleRateHz)
        let bitsPerSample = UInt16(MicrophonePCMConverter.bytesPerSample * 8)
        let blockAlign = channelCount * bitsPerSample / 8
        let byteRate = sampleRate * UInt32(blockAlign)
        let audioByteCount = UInt32(clamping: dataByteCount)

        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLittleEndian(UInt32(36) + audioByteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1)) // PCM
        data.appendLittleEndian(channelCount)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.append(contentsOf: Array("data".utf8))
        data.appendLittleEndian(audioByteCount)
        return data
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}

// MARK: - Floating HUD presentation value

/// One complete HUD presentation: visibility, capture phase, live input level,
/// elapsed duration, the active dictation mode, an optional message, and the
/// active route's interim streaming text (presentation only — interim text is
/// never an insertion or persistence candidate).
struct CaptureHudSnapshot: Equatable, Sendable {

    enum Phase: Equatable, Sendable {
        case idle
        case recording
        case finished
        case cancelled
        case error
    }

    let isVisible: Bool
    let phase: Phase
    let level: Float
    let elapsedDuration: TimeInterval
    let mode: HotkeyMode?
    let message: String?
    let interimTranscript: String?
    let statusPill: String?

    init(
        isVisible: Bool,
        phase: Phase,
        level: Float,
        elapsedDuration: TimeInterval,
        mode: HotkeyMode?,
        message: String?,
        interimTranscript: String?,
        statusPill: String? = nil
    ) {
        self.isVisible = isVisible
        self.phase = phase
        self.level = level
        self.elapsedDuration = elapsedDuration
        self.mode = mode
        self.message = message
        self.interimTranscript = interimTranscript
        self.statusPill = statusPill
    }

    static let hidden = CaptureHudSnapshot(
        isVisible: false,
        phase: .idle,
        level: 0,
        elapsedDuration: 0,
        mode: nil,
        message: nil,
        interimTranscript: nil,
        statusPill: nil
    )
}

// MARK: - Non-activating HUD panel contract
// (ACC-MICROPHONE-CAPTURE-AND-FLOATING-HUD-03)

/// The floating HUD is a borderless, non-activating panel: it never becomes
/// key or main, never activates the application, and never steals focus from
/// the focused application.
enum HudPanelContract {
    /// Borderless + non-activating panel style; never a titled/key window.
    static var styleMask: NSWindow.StyleMask { [.borderless, .nonactivatingPanel] }
    static let isFloatingPanel = true
    static let becomesKeyOnPresentation = false
    static let stealsFocus = false
    static let canBecomeKeyOrMain = false
}

/// The live HUD panel: borderless, non-activating, and explicitly unable to
/// become key or main even if AppKit asks.
final class NonActivatingHudPanel: NSPanel {
    override var canBecomeKey: Bool { HudPanelContract.canBecomeKeyOrMain }
    override var canBecomeMain: Bool { HudPanelContract.canBecomeKeyOrMain }
}

/// Injectable HUD boundary so tests never create a panel. The seam is
/// deliberately presentation-only: it exposes no activation, `makeKey`, or
/// focus call, so presenting the HUD cannot raise or focus the app.
@MainActor
protocol HudPresenting: Sendable {
    /// Presents or updates the HUD. `isVisible == false` hides it.
    func present(_ snapshot: CaptureHudSnapshot)
    /// Installs the HUD's instant stop and cancel controls.
    func setControlActions(
        stop: @escaping @MainActor () -> Void,
        cancel: @escaping @MainActor () -> Void
    )
}

// MARK: - Live non-activating HUD presenter

@MainActor
final class NonActivatingHudPresenter: HudPresenting {

    private var panel: NonActivatingHudPanel?
    private let model = CaptureHudModel()
    private var stopAction: (@MainActor () -> Void)?
    private var cancelAction: (@MainActor () -> Void)?

    func setControlActions(
        stop: @escaping @MainActor () -> Void,
        cancel: @escaping @MainActor () -> Void
    ) {
        stopAction = stop
        cancelAction = cancel
    }

    func present(_ snapshot: CaptureHudSnapshot) {
        guard snapshot.isVisible else {
            panel?.orderOut(nil)
            return
        }
        let panel = panel ?? makePanel()
        self.panel = panel
        model.snapshot = snapshot
        positionPanel(panel)
        // orderFrontRegardless presents the panel without activating the app
        // and without moving key focus away from the focused application.
        panel.orderFrontRegardless()
    }

    private func positionPanel(_ panel: NonActivatingHudPanel) {
        let screen = NSScreen.screens.first {
            $0.frame.contains(NSEvent.mouseLocation)
        } ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let fittingSize = panel.contentView?.fittingSize ?? panel.frame.size
        let targetSize = NSSize(width: max(fittingSize.width, 32), height: max(fittingSize.height, 32))
        panel.setContentSize(targetSize)
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - targetSize.width / 2,
            y: visible.minY + 36
        ))
    }

    private func makePanel() -> NonActivatingHudPanel {
        let panel = NonActivatingHudPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 44),
            styleMask: HudPanelContract.styleMask,
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = HudPanelContract.isFloatingPanel
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        let hosting = NSHostingView(
            rootView: CaptureHudContentView(
                model: model,
                stop: { [weak self] in self?.stopAction?() },
                cancel: { [weak self] in self?.cancelAction?() }
            )
        )
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        positionPanel(panel)
        return panel
    }
}

/// Observable bridge between the feature snapshots and the live panel.
@MainActor
final class CaptureHudModel: ObservableObject {
    @Published var snapshot: CaptureHudSnapshot = .hidden
}

/// Minimal HUD content: active mode, elapsed time, a live input-level meter,
/// and instant stop/cancel controls with stable accessibility labels.
private struct CaptureHudContentView: View {
    @ObservedObject var model: CaptureHudModel
    let stop: () -> Void
    let cancel: () -> Void

    var body: some View {
        Group {
            if let pill = model.snapshot.statusPill {
                HStack(spacing: 8) {
                    Text(pill)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)

                    Button(action: cancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .padding(4)
                            .background(Circle().fill(.quaternary))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss status")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 2)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("HUD status: \(pill)")
            } else {
                HStack(spacing: 10) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(modeLabel)
                            .font(.system(size: 12, weight: .semibold))
                            .accessibilityLabel("Active mode")
                        Text(timeLabel)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Elapsed recording time")
                    }

                    LevelMeter(level: model.snapshot.level)

                    if let interim = model.snapshot.interimTranscript, !interim.isEmpty {
                        Text(interim)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 120, alignment: .leading)
                    }

                    if let message = model.snapshot.message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                            .accessibilityLabel("Recording error")
                    }

                    Spacer(minLength: 0)

                    Button(action: stop) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 9, weight: .bold))
                            .padding(5)
                            .background(Circle().fill(.quaternary))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop recording")

                    Button(action: cancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .padding(5)
                            .background(Circle().fill(.quaternary))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel recording")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 3)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("WhisperBar recording HUD")
            }
        }
    }

    private var modeLabel: String {
        switch model.snapshot.mode {
        case .pushToTalk: return "Push-to-talk"
        case .toggle: return "Toggle"
        case nil: return "Recording"
        }
    }

    private var timeLabel: String {
        let elapsed = max(0, Int(model.snapshot.elapsedDuration))
        return String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }
}

private struct LevelMeter: View {
    let level: Float

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.quaternary)
            Capsule()
                .fill(.red.opacity(0.85))
                .frame(width: 80 * CGFloat(Swift.min(Swift.max(level, 0), 1)))
        }
        .frame(width: 80, height: 4)
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(Swift.min(Swift.max(level, 0), 1) * 100)) percent")
    }
}

// MARK: - MicrophoneCaptureAndFloatingHudFeature

/// OWN-MICROPHONE-CAPTURE-AND-FLOATING-HUD.
///
/// Owns CON-MICROPHONE-CAPTURE-AND-FLOATING-HUD-INTERFACE and
/// CON-MICROPHONE-CAPTURE-AND-FLOATING-HUD-RECOVERY: recording starts from
/// the explicit hotkey action, captures microphone audio exactly for the
/// active request, converts it to the locked linear16 16 kHz mono PCM
/// contract, and presents a minimal floating HUD with live input levels,
/// elapsed duration, the active mode, and instant stop/cancel controls that
/// never steal focus.
///
/// Every operation is idle, active, succeeded, failed, or cancelled; the last
/// valid state is preserved on every failure; no automatic retry, restart, or
/// re-capture ever follows a failure or a terminal path. Recovery is an
/// explicit user retry, and every terminal path releases the input device,
/// the buffer sink, and the HUD.
@MainActor
final class MicrophoneCaptureAndFloatingHudFeature: TerminationReleasing {

    // MARK: States

    enum State: Equatable, Sendable {
        case idle
        case active
        case succeeded
        case failed(Failure)
        case cancelled
    }

    struct Failure: Equatable, Sendable {
        enum Category: Equatable, Sendable {
            case permissionDenied
            case microphoneUnavailable
        }

        let category: Category
        let message: String
    }

    // MARK: Observable state

    private(set) var state: State = .idle
    /// The active dictation mode shown by the HUD while a session is active.
    private(set) var activeMode: HotkeyMode?
    /// Mode of the last explicit start request, used by explicit retries only.
    private(set) var lastRequestedMode: HotkeyMode?
    private(set) var lastFailure: Failure?
    private(set) var lastNotice: String?
    private(set) var hudSnapshot: CaptureHudSnapshot = .hidden
    /// Current status pill displayed in HUD (e.g. ⚡ Instant Paste, ✨ Refining..., 🛡️ Ignored phantom audio).
    private(set) var currentStatusPill: String?
    /// The active route's interim streaming text shown by the HUD while
    /// recording. Presentation only: never an insertion or persistence
    /// candidate, cleared on every terminal path.
    private(set) var interimTranscript: String = ""
    /// Live 0...1 input level for the HUD meter.
    private(set) var inputLevel: Float = 0
    private(set) var receivedBufferCount = 0
    private(set) var emittedFrameCount = 0
    private(set) var droppedBufferCount = 0
    private(set) var lastEmittedFrameByteCount = 0
    /// True only while the input device is actually running.
    private(set) var isCaptureEngineRunning = false

    /// Exactly one active recording state machine; a duplicate start never
    /// disturbs an active session.
    var isRecording: Bool {
        if case .active = state { return true }
        return false
    }

    /// Elapsed recording time for the HUD.
    var elapsedDuration: TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, now().timeIntervalSince(startedAt))
    }

    /// Hand-off hook for the converted locked-format PCM frames. The
    /// composition root forwards them to the selected transcription route.
    var onAudioFrame: (@MainActor (Data) -> Void)?

    /// Composition hand-off for the HUD's instant stop control. When the
    /// composition root installs this seam, the HUD stop drives the one
    /// authoritative recording-session state machine (stream finalize or batch
    /// transcription on stop) instead of the capture-only terminal path. The
    /// capture-only fallback remains for a standalone feature instance.
    var onStopControlRequested: (@MainActor () async -> Void)?

    /// Composition hand-off for the HUD's instant cancel control. When the
    /// composition root installs this seam, the HUD cancel drives the one
    /// authoritative session state machine (paid-request cancellation plus
    /// verified temporary-audio cleanup) instead of the capture-only path.
    var onCancelControlRequested: (@MainActor () async -> Void)?

    // MARK: Dependencies

    private let capture: MicrophoneCapturing
    private let hudPresenter: HudPresenting
    private let microphoneAvailability: @MainActor () -> PermissionState
    private let requestMicrophoneAccess: @MainActor () async -> PermissionState
    private let now: @Sendable () -> Date

    private var startedAt: Date?

    /// Ordered buffer ingestion. The live sink yields each delivered buffer
    /// into this stream; the single consumer below ingests them on the main
    /// actor in exactly the delivery order, so no per-buffer task races the
    /// conversion and no callback outlives a terminal path.
    private var bufferContinuation: AsyncStream<MicrophoneInputBuffer>.Continuation?
    private var bufferIngestionTask: Task<Void, Never>?
    private var autoDismissPillTask: Task<Void, Never>?

    init(
        capture: MicrophoneCapturing = SystemMicrophoneCapture(),
        hudPresenter: HudPresenting = NonActivatingHudPresenter(),
        microphoneAvailability: @escaping @MainActor () -> PermissionState = { .authorized },
        requestMicrophoneAccess: @escaping @MainActor () async -> PermissionState = { .authorized },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.capture = capture
        self.hudPresenter = hudPresenter
        self.microphoneAvailability = microphoneAvailability
        self.requestMicrophoneAccess = requestMicrophoneAccess
        self.now = now
        hudPresenter.setControlActions(
            stop: { [weak self] in
                Task { @MainActor in await self?.handleHudStopControl() }
            },
            cancel: { [weak self] in
                Task { @MainActor in await self?.handleHudCancelControl() }
            }
        )
    }

    // MARK: HUD control routing (composition seam owns the session machine)

    /// The HUD stop control: the composition root's authoritative session
    /// state machine runs the terminal path (stream finalize / batch
    /// transcription, cost completion, history, paste, and verified cleanup).
    /// Without that seam the capture-only stop remains for a standalone
    /// feature instance.
    private func handleHudStopControl() async {
        if let onStopControlRequested {
            await onStopControlRequested()
            return
        }
        _ = await stopCapture()
    }

    /// The HUD cancel control: the composition root's authoritative session
    /// state machine runs the cancel path (paid-request cancellation, route
    /// cancellation, verified temporary-audio cleanup). Without that seam the
    /// capture-only cancel remains for a standalone feature instance.
    private func handleHudCancelControl() async {
        if let onCancelControlRequested {
            await onCancelControlRequested()
            return
        }
        _ = await cancelCapture()
    }

    // MARK: Interim streaming text (presentation only)

    /// Main-actor entry for the active route's interim streaming text (the
    /// Deepgram route's latest interim result). It updates the HUD snapshot
    /// while recording — the menu presentation reads the same value through
    /// the composition root. Interim text is presentation only: it is never
    /// an insertion or persistence candidate, and it is cleared on every
    /// terminal path. A call without an active session is ignored.
    func updateInterimTranscript(_ text: String) {
        guard isRecording else { return }
        interimTranscript = text
        publishHud(isVisible: true, phase: .recording)
    }

    // MARK: Microphone authorization (resolved before any provider route)

    /// Resolves the microphone authorization for one explicit user action:
    /// the cached state is read first, and only `notDetermined` runs the
    /// single access request. It never starts capture and never prompts more
    /// than once per explicit action.
    @discardableResult
    func resolveMicrophoneAuthorization() async -> PermissionState {
        var availability = microphoneAvailability()
        if availability == .notDetermined {
            availability = await requestMicrophoneAccess()
        }
        return availability
    }

    /// Resolves the microphone authorization before any provider route or
    /// socket is opened (the composition root's ordering requirement): the
    /// first-run access prompt completes before a live socket or recording
    /// file exists, so no route ever waits for audio that cannot arrive. A
    /// non-authorized resolution records the documented permission failure
    /// (HUD error, explicit retry) without starting capture and returns
    /// false; the caller ends the session before opening a route.
    @discardableResult
    func resolveMicrophoneAuthorizationBeforeRoute() async -> Bool {
        guard await resolveMicrophoneAuthorization() == .authorized else {
            _ = await fail(.permissionDenied)
            return false
        }
        return true
    }

    // MARK: Start (recording starts via hotkey)

    /// Starts one user-initiated recording session. The HUD appears
    /// immediately, before any permission prompt or engine start. If
    /// microphone access is unavailable the HUD shows an error and recording
    /// does not start.
    @discardableResult
    func startCapture(mode: HotkeyMode) async -> Bool {
        guard !isRecording else {
            lastNotice = "A recording is already active; the current session is unchanged."
            return false
        }

        autoDismissPillTask?.cancel()
        autoDismissPillTask = nil
        currentStatusPill = nil

        lastRequestedMode = mode
        activeMode = mode
        lastFailure = nil
        lastNotice = nil
        inputLevel = 0
        interimTranscript = ""
        startedAt = now()
        isCaptureEngineRunning = false
        state = .active
        // HUD appears immediately: presented with the start request, before
        // any awaited work. It is a non-activating panel, so the focused
        // application keeps focus.
        publishHud(isVisible: true, phase: .recording)

        // CON-PERMISSION-MICROPHONE: request AVCaptureDevice audio
        // authorization before capture, only from this explicit user action.
        // The composition root resolves the same authorization before it opens
        // any provider route; this single implementation keeps that ordering
        // valid for a standalone feature instance too.
        let availability = await resolveMicrophoneAuthorization()
        guard isRecording else { return false }
        guard availability == .authorized else {
            return await fail(.permissionDenied)
        }

        // Buffers are delivered through one ordered stream: the device sink
        // yields in delivery order and the single main-actor consumer ingests
        // in exactly that order, so no per-buffer task races the conversion
        // and the terminal paths can await the consumer.
        let (bufferStream, bufferContinuation) = AsyncStream.makeStream(of: MicrophoneInputBuffer.self)
        self.bufferContinuation = bufferContinuation
        bufferIngestionTask = Task { @MainActor [weak self] in
            for await buffer in bufferStream {
                self?.ingestCaptureBuffer(buffer)
            }
        }
        await capture.setBufferSink { buffer in
            bufferContinuation.yield(buffer)
        }

        do {
            _ = try await capture.beginCapture()
        } catch {
            return await fail(.microphoneUnavailable)
        }

        guard isRecording else {
            // The user stopped or cancelled while the engine was starting:
            // the late engine is released and recording never reports as
            // started.
            await releaseCaptureResources()
            return false
        }
        isCaptureEngineRunning = true
        return true
    }

    // MARK: Stop and cancel (instant HUD controls)

    /// User stop: ends the session, hides the HUD, and releases the input
    /// device and buffer sink.
    @discardableResult
    func stopCapture() async -> Bool {
        guard isRecording else { return false }
        state = .succeeded
        activeMode = nil
        inputLevel = 0
        interimTranscript = ""
        stopHud(phase: .finished)
        await releaseCaptureResources()
        return true
    }

    /// Explicit cancel: ends the session immediately, discards every late
    /// buffer, and releases the input device and buffer sink.
    @discardableResult
    func cancelCapture() async -> Bool {
        guard isRecording else { return false }
        state = .cancelled
        activeMode = nil
        inputLevel = 0
        interimTranscript = ""
        stopHud(phase: .cancelled)
        await releaseCaptureResources()
        return true
    }

    /// Explicit user retry of the last requested recording. Nothing retries
    /// automatically.
    @discardableResult
    func retry() async -> Bool {
        guard !isRecording, let mode = lastRequestedMode else { return false }
        return await startCapture(mode: mode)
    }

    /// Explicit dismissal of a visible HUD (for example a failed session).
    /// The last valid state is preserved so an explicit retry stays possible.
    func dismissHud() {
        autoDismissPillTask?.cancel()
        autoDismissPillTask = nil
        currentStatusPill = nil
        guard hudSnapshot.isVisible else { return }
        publishHud(isVisible: false, phase: hudSnapshot.phase, message: hudSnapshot.message)
    }

    // MARK: Buffer ingestion and conversion

    /// Main-actor entry for one delivered input buffer. Buffers arriving on a
    /// terminal path are discarded, never converted, and never forwarded.
    func ingestCaptureBuffer(_ buffer: MicrophoneInputBuffer) {
        guard isRecording, isCaptureEngineRunning else {
            droppedBufferCount += 1
            return
        }
        receivedBufferCount += 1
        inputLevel = MicrophonePCMConverter.normalizedLevel(samples: buffer.samples)
        if let frame = MicrophonePCMConverter.convert(buffer) {
            emittedFrameCount += 1
            lastEmittedFrameByteCount = frame.count
            onAudioFrame?(frame)
        } else {
            // Never forward empty or malformed frames.
            droppedBufferCount += 1
        }
        publishHud(isVisible: true, phase: .recording)
    }

    // MARK: HUD status pill & badges

    func showStatusPill(_ pill: String, autoDismissDelay: TimeInterval? = 1.8) {
        autoDismissPillTask?.cancel()
        autoDismissPillTask = nil
        currentStatusPill = pill
        hudSnapshot = CaptureHudSnapshot(
            isVisible: true,
            phase: .finished,
            level: 0,
            elapsedDuration: elapsedDuration,
            mode: activeMode,
            message: nil,
            interimTranscript: nil,
            statusPill: pill
        )
        hudPresenter.present(hudSnapshot)

        if let autoDismissDelay, autoDismissDelay > 0 {
            autoDismissPillTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: UInt64(autoDismissDelay * 1_000_000_000))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                self.clearStatusPill()
            }
        }
    }

    func clearStatusPill() {
        autoDismissPillTask?.cancel()
        autoDismissPillTask = nil
        guard currentStatusPill != nil else { return }
        currentStatusPill = nil
        if !isRecording {
            publishHud(isVisible: false, phase: .finished)
        }
    }

    // MARK: Termination

    /// CON-LIFECYCLE-APPLICATION-TERMINATION: stop the input device, clear the
    /// buffer sink, and hide the HUD so no capture resource outlives the
    /// process.
    func releaseForTermination() async {
        autoDismissPillTask?.cancel()
        autoDismissPillTask = nil
        state = .idle
        activeMode = nil
        inputLevel = 0
        interimTranscript = ""
        currentStatusPill = nil
        startedAt = nil
        publishHud(isVisible: false, phase: .idle)
        await releaseCaptureResources()
    }

    // MARK: Failure bookkeeping and cleanup

    @discardableResult
    private func fail(_ category: Failure.Category) async -> Bool {
        autoDismissPillTask?.cancel()
        autoDismissPillTask = nil
        let failure = Failure(category: category, message: Self.message(for: category))
        lastFailure = failure
        activeMode = nil
        inputLevel = 0
        interimTranscript = ""
        currentStatusPill = nil
        isCaptureEngineRunning = false
        state = .failed(failure)
        // The HUD shows the error; recording did not start.
        publishHud(isVisible: true, phase: .error, message: failure.message)
        await releaseCaptureResources()
        return false
    }

    /// Releases the input device and the buffer sink on every terminal path,
    /// and finishes the ordered ingestion so no callback, buffer, or consumer
    /// outlives the terminal state.
    private func releaseCaptureResources() async {
        bufferContinuation?.finish()
        bufferContinuation = nil
        let ingestion = bufferIngestionTask
        bufferIngestionTask = nil
        await capture.setBufferSink(nil)
        await capture.endCapture()
        await ingestion?.value
        isCaptureEngineRunning = false
    }

    // MARK: HUD publication

    private func publishHud(isVisible: Bool, phase: CaptureHudSnapshot.Phase, message: String? = nil) {
        hudSnapshot = CaptureHudSnapshot(
            isVisible: isVisible,
            phase: phase,
            level: inputLevel,
            elapsedDuration: elapsedDuration,
            mode: activeMode,
            message: message,
            interimTranscript: interimTranscript.isEmpty ? nil : interimTranscript,
            statusPill: currentStatusPill
        )
        hudPresenter.present(hudSnapshot)
    }

    private func stopHud(phase: CaptureHudSnapshot.Phase) {
        startedAt = nil
        publishHud(isVisible: false, phase: phase)
    }

    // MARK: Privacy-safe messages

    private static func message(for category: Failure.Category) -> String {
        switch category {
        case .permissionDenied:
            return "Microphone access is not available, so recording did not start. Enable Microphone access for WhisperBar in System Settings → Privacy & Security → Microphone, then retry explicitly."
        case .microphoneUnavailable:
            return "No microphone input is available, so recording did not start. Check the input device and retry explicitly."
        }
    }
}
