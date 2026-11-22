import AVFoundation
import BossCore

/// Audio-thread side: converts mic buffers to 16 kHz mono Int16, keeps the pre-roll,
/// accumulates the active recording. Not main-actor bound (the tap runs on a realtime thread).
final class AudioPipe: @unchecked Sendable {
    private let lock = NSLock()
    private var preRoll = PreRollBuffer()
    private var acc: RecordingAccumulator?
    private var _level: Double = 0
    private var converter: AVAudioConverter?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    /// Native-format buffers while recording (for the live on-device recognizer).
    var onRecordingBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?

    func configure(input: AVAudioFormat) {
        converter = AVAudioConverter(from: input, to: outFormat)
    }

    func process(_ buf: AVAudioPCMBuffer) {
        guard let conv = converter else { return }
        let ratio = 16_000 / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        guard err == nil, let ch = out.int16ChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
        let rms = AudioLevel.rms(samples)
        lock.lock()
        preRoll.append(samples)
        acc?.append(samples)
        let recording = acc != nil
        _level = AudioLevel.meter(rms)
        lock.unlock()
        if recording { onRecordingBuffer?(buf) }
    }

    func begin() { lock.lock(); acc = RecordingAccumulator(preRoll: preRoll.snapshot(), maxSeconds: 180); lock.unlock() }
    func end() -> [Int16] { lock.lock(); defer { acc = nil; lock.unlock() }; return acc?.samples ?? [] }
    func discard() { lock.lock(); acc = nil; lock.unlock() }
    var level: Double { lock.lock(); defer { lock.unlock() }; return _level }
}

/// Real microphone. The engine runs continuously once mic permission is granted, so the
/// 300 ms pre-roll always holds the moments before Right Option goes down.
@MainActor
final class AudioCapture: Recorder {
    private let engine = AVAudioEngine()
    let pipe = AudioPipe()
    private var running = false
    private var configObserver: NSObjectProtocol?
    var onPermissionGranted: (() -> Void)?

    var permission: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "granted"
        case .denied, .restricted: return "denied"
        default: return "undetermined"
        }
    }

    /// Start the always-on engine if we already have permission (never prompts).
    func prepare() {
        if permission == "granted" { startEngine() }
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartEngine() }
        }
    }

    private func restartEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        startEngine()
    }

    @discardableResult
    func startEngine() -> Bool {
        if running { return true }
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { return false }
        pipe.configure(input: fmt)
        installTap(input, fmt)
        engine.prepare()
        do { try engine.start(); running = true } catch {
            input.removeTap(onBus: 0)
            NSLog("Boss: audio engine failed: \(error)")
            return false
        }
        return true
    }

    private nonisolated func installTap(_ input: AVAudioInputNode, _ fmt: AVAudioFormat) {
        let pipe = self.pipe
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buf, _ in pipe.process(buf) }
    }

    func start() -> Bool {
        switch permission {
        case "granted":
            guard startEngine() else { return false }
            pipe.begin()
            return true
        case "undetermined":
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    if granted { self.startEngine(); self.onPermissionGranted?() }
                }
            }
            return false
        default:
            return false
        }
    }

    func stop() -> [Int16] { pipe.end() }
    func cancel() { pipe.discard() }
    var level: Double { running ? pipe.level : 0 }
}
