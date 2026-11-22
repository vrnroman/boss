import Foundation

/// Fixed-capacity ring buffer of 16 kHz Int16 samples. Keeps the last `capacity`
/// samples so the first word of a push-to-talk is never clipped.
public struct PreRollBuffer: Sendable {
    /// 300 ms at 16 kHz.
    public static let defaultSamples = 4800
    public let capacity: Int
    private var storage: [Int16]
    private var head = 0      // next write index
    private var filled = 0

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.storage = Array(repeating: 0, count: capacity)
    }

    /// 300 ms at 16 kHz by default.
    public init(seconds: Double = 0.3, sampleRate: Int = 16_000) {
        self.init(capacity: max(1, Int(Double(sampleRate) * seconds)))
    }

    public var count: Int { filled }

    public mutating func append(_ samples: [Int16]) {
        if samples.count >= capacity {
            storage = Array(samples.suffix(capacity))
            head = 0
            filled = capacity
            return
        }
        for s in samples {
            storage[head] = s
            head = (head + 1) % capacity
        }
        filled = min(capacity, filled + samples.count)
    }

    /// Oldest-first copy of the buffered samples.
    public func snapshot() -> [Int16] {
        // Not yet wrapped: data lives in [0, head) and head == filled.
        if filled < capacity { return Array(storage[0..<filled]) }
        return Array(storage[head..<capacity]) + Array(storage[0..<head])
    }

    public mutating func clear() { head = 0; filled = 0 }
}

/// Collects one recording: the pre-roll snapshot plus everything after it.
public struct RecordingAccumulator: Sendable {
    public private(set) var samples: [Int16]
    public let sampleRate: Int
    public let maxSamples: Int
    public init(preRoll: [Int16], sampleRate: Int = 16_000, maxSeconds: Double = 120) {
        self.samples = preRoll
        self.sampleRate = sampleRate
        self.maxSamples = Int(Double(sampleRate) * maxSeconds)
    }
    public mutating func append(_ s: [Int16]) {
        guard samples.count < maxSamples else { return }
        samples.append(contentsOf: s.prefix(maxSamples - samples.count))
    }
    public var duration: Double { Double(samples.count) / Double(sampleRate) }
}

public enum WAV {
    /// 16-bit PCM mono WAV (RIFF) file bytes.
    public static func encode(samples: [Int16], sampleRate: Int = 16_000) -> Data {
        var d = Data()
        let dataBytes = samples.count * 2
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1)                       // PCM
        u16(1)                       // mono
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 2))  // byte rate
        u16(2)                       // block align
        u16(16)                      // bits per sample
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        samples.withUnsafeBufferPointer { buf in
            for s in buf { var x = s.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        }
        return d
    }

    public struct Decoded: Equatable, Sendable {
        public var sampleRate: Int
        public var channels: Int
        public var samples: [Int16]   // first channel only
        public var duration: Double { Double(samples.count) / Double(sampleRate) }
    }

    /// Decode a PCM16 WAV (any rate / channel count; returns channel 0). nil if not PCM16 WAV.
    public static func decode(_ data: Data) -> Decoded? {
        let b = [UInt8](data)
        guard b.count >= 12, String(bytes: b[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: b[8..<12], encoding: .ascii) == "WAVE" else { return nil }
        func u32(_ i: Int) -> Int { Int(b[i]) | Int(b[i+1]) << 8 | Int(b[i+2]) << 16 | Int(b[i+3]) << 24 }
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i+1]) << 8 }
        var i = 12
        var rate = 0, channels = 0, bits = 0, format = 0
        while i + 8 <= b.count {
            let id = String(bytes: b[i..<i+4], encoding: .ascii) ?? ""
            let size = u32(i + 4)
            let body = i + 8
            if id == "fmt " && body + 16 <= b.count {
                format = u16(body); channels = u16(body + 2); rate = u32(body + 4); bits = u16(body + 14)
            } else if id == "data" {
                guard format == 1 || format == 0xFFFE, bits == 16, channels > 0, rate > 0 else { return nil }
                let end = min(b.count, body + size)
                var out: [Int16] = []
                out.reserveCapacity((end - body) / (2 * channels))
                var j = body
                while j + 2 * channels <= end {
                    out.append(Int16(bitPattern: UInt16(b[j]) | UInt16(b[j+1]) << 8))
                    j += 2 * channels
                }
                return Decoded(sampleRate: rate, channels: channels, samples: out)
            }
            i = body + size + (size & 1)
        }
        return nil
    }
}

public enum AudioLevel {
    /// RMS in 0...1 (full scale = 1).
    public static func rms(_ samples: ArraySlice<Int16>) -> Double {
        guard !samples.isEmpty else { return 0 }
        var acc = 0.0
        for s in samples { let f = Double(s) / 32768.0; acc += f * f }
        return (acc / Double(samples.count)).squareRoot()
    }
    public static func rms(_ samples: [Int16]) -> Double { rms(samples[...]) }

    /// Meter value 0...1 on a -60…0 dBFS scale.
    public static func meter(_ rms: Double) -> Double {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(1, max(0, (db + 60) / 60))
    }
}

/// Lifts a quiet recording toward a healthy level before transcription (a webcam mic across the
/// desk peaked at -25 dBFS in a real run, and whisper heard nothing at that level).
public enum AutoGain {
    /// Scales so the peak reaches `targetPeak` (fraction of full scale), never by more than `maxGain`,
    /// and never down. Loud recordings come back unchanged.
    public static func apply(_ samples: [Int16], targetPeak: Double = 0.7, maxGain: Double = 10) -> [Int16] {
        var peak: Int32 = 0
        for s in samples { let a = abs(Int32(s)); if a > peak { peak = a } }
        guard peak > 0 else { return samples }
        let gain = min(maxGain, targetPeak * 32767 / Double(peak))
        guard gain > 1.05 else { return samples }
        var out = [Int16](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            out[i] = Int16(max(-32767, min(32767, (Double(samples[i]) * gain).rounded())))
        }
        return out
    }
}

/// Decides whether a recording is worth transcribing.
public struct AudioGate: Sendable {
    public enum Verdict: Equatable, Sendable { case ok, tooShort, silent }
    public var minDuration: Double
    public var rmsFloor: Double
    public init(minDuration: Double = 0.3, rmsFloor: Double = 0.004) {
        self.minDuration = minDuration
        self.rmsFloor = rmsFloor
    }
    public func evaluate(samples: [Int16], sampleRate: Int = 16_000) -> Verdict {
        let dur = Double(samples.count) / Double(sampleRate)
        if dur < minDuration { return .tooShort }
        // Use the loudest 100 ms window so a short word in a long silence still passes.
        let win = max(1, sampleRate / 10)
        var peak = 0.0
        var i = 0
        while i < samples.count {
            let end = min(samples.count, i + win)
            peak = max(peak, AudioLevel.rms(samples[i..<end]))
            i += win
        }
        return peak < rmsFloor ? .silent : .ok
    }

    /// Milliseconds of voiced audio: 20 ms frames clearly above the recording's own noise floor
    /// (its 10th-percentile frame level) and above twice the absolute floor. Room noise, a fan or a
    /// hum stays near its own floor and scores ~0; a spoken word scores hundreds.
    public func voicedMs(samples: [Int16], sampleRate: Int = 16_000) -> Int {
        let frame = max(1, sampleRate / 50)
        var levels: [Double] = []
        var i = 0
        while i + frame <= samples.count {
            levels.append(AudioLevel.rms(samples[i..<(i + frame)]))
            i += frame
        }
        guard !levels.isEmpty else { return 0 }
        let sorted = levels.sorted()
        let noise = sorted[Int(Double(sorted.count - 1) * 0.1)]   // the quietest tenth: the room between words
        let threshold = max(rmsFloor * 2, noise * 2.5)   // ~8 dB above the room
        return levels.filter { $0 > threshold }.count * 20
    }

    /// Stricter check for recordings nobody chose to start (the answer window): needs real speech.
    public func evaluateUnprompted(samples: [Int16], sampleRate: Int = 16_000, minVoicedMs: Int = 120) -> Verdict {
        let v = evaluate(samples: samples, sampleRate: sampleRate)
        guard v == .ok else { return v }
        return voicedMs(samples: samples, sampleRate: sampleRate) >= minVoicedMs ? .ok : .silent
    }
}
