import AVFoundation
import Accelerate

enum MicRecorderError: LocalizedError {
    case alreadyRecording
    case inputUnavailable

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "Microphone recording is already in progress."
        case .inputUnavailable: return "No usable microphone input was found."
        }
    }
}

final class MicRecorder: @unchecked Sendable {
    var levelHandler: (@Sendable (Float) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _levelHandler }
        set { lock.lock(); defer { lock.unlock() }; _levelHandler = newValue }
    }

    /// Fork of each captured buffer for live transcription. The sink deep-copies
    /// immediately — the buffer here is only valid during the tap callback.
    var bufferSink: (@Sendable (AVAudioPCMBuffer) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _bufferSink }
        set { lock.lock(); defer { lock.unlock() }; _bufferSink = newValue }
    }

    static var permissionGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    private let lock = NSLock()
    private let restartQueue = DispatchQueue(label: "parfait.mic-recorder.restart")
    private var _levelHandler: (@Sendable (Float) -> Void)?
    private var _bufferSink: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var configObserver: (any NSObjectProtocol)?
    private var smoothedLevel: Float = 0
    private var lastLevelEmit: CFAbsoluteTime = 0

    func start(writingTo url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard engine == nil else { throw MicRecorderError.alreadyRecording }

        let engine = AVAudioEngine()
        applyVoiceProcessing(engine) // best-effort AEC before we read the input format
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw MicRecorderError.inputUnavailable
        }

        // Apple's AAC encoder tops out at 48 kHz; higher-rate inputs go through a converter.
        let fileSampleRate = min(inputFormat.sampleRate, 48_000)
        let fileChannels = min(inputFormat.channelCount, 2)
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: fileSampleRate,
                AVNumberOfChannelsKey: Int(fileChannels),
                AVEncoderBitRateKey: 128_000,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false)

        self.engine = engine
        self.file = file

        do {
            try installAndStartLocked(engine)
        } catch {
            // Voice processing can be finicky on some devices/outputs; if it broke
            // engine start, retry once without it rather than fail the recording.
            guard engine.inputNode.isVoiceProcessingEnabled else {
                teardownLocked()
                throw error
            }
            try? engine.inputNode.setVoiceProcessingEnabled(false)
            engine.inputNode.removeTap(onBus: 0)
            do {
                try installAndStartLocked(engine)
            } catch {
                teardownLocked()
                throw error
            }
        }

        // Watch for device switches only once we're actually running (this also
        // avoids adding a second observer if the AEC-fallback retry above ran).
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.restartQueue.async { self?.restartAfterConfigurationChange() }
        }
    }

    private func installAndStartLocked(_ engine: AVAudioEngine) throws {
        try installTapLocked(on: engine)
        engine.prepare()
        try engine.start()
    }

    /// Apple's voice-processing I/O cancels the system-output echo (plus AGC and
    /// noise suppression) so the mic carries only the local speaker — the fix for the
    /// far end bleeding into the "You" channel when the user is on speakers.
    /// Best-effort and gated by a setting; if the OS refuses it we record without it,
    /// and the batch echo-dedup still cleans the transcript.
    private func applyVoiceProcessing(_ engine: AVAudioEngine) {
        let wanted = AppSettings.echoCancellation
        guard engine.inputNode.isVoiceProcessingEnabled != wanted else { return }
        try? engine.inputNode.setVoiceProcessingEnabled(wanted)
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        teardownLocked()
    }

    deinit {
        stop()
    }

    // MARK: - Engine plumbing

    private func installTapLocked(on engine: AVAudioEngine) throws {
        guard let file else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MicRecorderError.inputUnavailable
        }
        if format == file.processingFormat {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: format, to: file.processingFormat) else {
                throw MicRecorderError.inputUnavailable
            }
            self.converter = converter
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
    }

    /// Default input device switched: the engine stops itself and the old tap format is stale.
    private func restartAfterConfigurationChange() {
        lock.lock()
        defer { lock.unlock() }
        guard let engine, file != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        applyVoiceProcessing(engine)
        do {
            try installTapLocked(on: engine)
            engine.prepare()
            try engine.start()
        } catch {
            // No usable input right now; the next configuration change retries.
        }
    }

    private func teardownLocked() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
        converter = nil
        file = nil // releases the writer, finalizing the .m4a
        smoothedLevel = 0
        lastLevelEmit = 0
    }

    // MARK: - Tap callback

    private func process(_ buffer: AVAudioPCMBuffer) {
        var emit: (@Sendable (Float) -> Void, Float)?
        var sink: (@Sendable (AVAudioPCMBuffer) -> Void)?
        lock.lock()
        writeLocked(buffer)
        if let level = meterLocked(buffer), let handler = _levelHandler {
            emit = (handler, level)
        }
        sink = _bufferSink
        lock.unlock()
        sink?(buffer)
        if let (handler, level) = emit {
            handler(level)
        }
    }

    private func writeLocked(_ buffer: AVAudioPCMBuffer) {
        guard let file else { return }
        guard let converter else {
            try? file.write(from: buffer)
            return
        }
        let ratio = file.processingFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else {
            return
        }
        var fed = false
        var conversionError: NSError?
        // .noDataNow keeps the converter's resampler state alive across tap buffers.
        let status = converter.convert(to: out, error: &conversionError) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status != .error, out.frameLength > 0 {
            try? file.write(from: out)
        }
    }

    private static let meterFloorDB: Float = -55   // near-silence -> level 0
    private static let meterCeilingDB: Float = -12  // loud/near-clip speech -> level 1

    private func meterLocked(_ buffer: AVAudioPCMBuffer) -> Float? {
        guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] else { return nil }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(buffer.frameLength))
        // dBFS mapped to a floor/ceiling window (rather than raw sqrt(rms)) so normal speech
        // (~-35..-20 dBFS) actually fills the meter instead of only the loudest moments.
        let dB = 20 * log10(max(rms, 1e-6))
        let normalized = (dB - Self.meterFloorDB) / (Self.meterCeilingDB - Self.meterFloorDB)
        smoothedLevel += (min(1, max(0, normalized)) - smoothedLevel) * 0.3
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastLevelEmit >= 0.1 else { return nil }
        lastLevelEmit = now
        return smoothedLevel
    }
}
