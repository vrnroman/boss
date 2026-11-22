import Testing
import Foundation
@testable import BossCore

@Suite("Audio")
struct AudioTests {
    @Test func preRollKeepsLast300ms() {
        var b = PreRollBuffer()
        #expect(b.capacity == 4800)
        b.append((0..<3000).map { Int16($0 % 1000) })
        #expect(b.snapshot().count == 3000)
        b.append((0..<3000).map { Int16(5000 + $0 % 1000) })
        let s = b.snapshot()
        #expect(s.count == 4800)
        #expect(s.last == Int16(5000 + 2999 % 1000))
        // oldest kept is sample index 1200 of the first batch
        #expect(s.first == Int16(1200 % 1000))
    }

    @Test func preRollOrderAcrossManyWraps() {
        var b = PreRollBuffer(capacity: 5)
        for i in 0..<23 { b.append([Int16(i)]) }
        #expect(b.snapshot() == [18, 19, 20, 21, 22])
        b.append((100..<110).map { Int16($0) })
        #expect(b.snapshot() == [105, 106, 107, 108, 109])
        b.clear()
        #expect(b.snapshot().isEmpty)
    }

    @Test func accumulatorStartsWithPreRollAndCaps() {
        var a = RecordingAccumulator(preRoll: [1, 2, 3], sampleRate: 10, maxSeconds: 1)
        a.append([4, 5, 6, 7, 8, 9, 10, 11, 12])
        #expect(a.samples == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        #expect(a.duration == 1)
    }

    @Test func wavRoundTrip() throws {
        let s: [Int16] = [0, 1, -1, 32767, -32768, 1234]
        let d = WAV.encode(samples: s)
        #expect(d.count == 44 + s.count * 2)
        #expect(String(decoding: d[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: d[8..<16], as: UTF8.self) == "WAVEfmt ")
        let dec = try #require(WAV.decode(d))
        #expect(dec.sampleRate == 16000)
        #expect(dec.channels == 1)
        #expect(dec.samples == s)
    }

    @Test func wavHeaderFields() {
        let d = [UInt8](WAV.encode(samples: [Int16](repeating: 0, count: 16000)))
        func u32(_ i: Int) -> Int { Int(d[i]) | Int(d[i+1]) << 8 | Int(d[i+2]) << 16 | Int(d[i+3]) << 24 }
        #expect(u32(24) == 16000)       // sample rate
        #expect(u32(28) == 32000)       // byte rate
        #expect(d[34] == 16)            // bits
        #expect(u32(40) == 32000)       // data size
    }

    @Test func decodeRejectsGarbage() {
        #expect(WAV.decode(Data("hello world, not a wav".utf8)) == nil)
    }

    func tone(seconds: Double, amp: Double) -> [Int16] {
        (0..<Int(16000 * seconds)).map { Int16(amp * 32767 * sin(Double($0) * 2 * .pi * 440 / 16000)) }
    }

    @Test func gateDropsShort() {
        let g = AudioGate()
        #expect(g.evaluate(samples: tone(seconds: 0.29, amp: 0.5)) == .tooShort)
        #expect(g.evaluate(samples: tone(seconds: 0.31, amp: 0.5)) == .ok)
    }

    @Test func gateDropsSilence() {
        let g = AudioGate()
        #expect(g.evaluate(samples: [Int16](repeating: 0, count: 16000)) == .silent)
        #expect(g.evaluate(samples: tone(seconds: 1, amp: 0.001)) == .silent)
        #expect(g.evaluate(samples: tone(seconds: 1, amp: 0.05)) == .ok)
    }

    @Test func gateKeepsShortWordInLongSilence() {
        let s = [Int16](repeating: 0, count: 32000) + tone(seconds: 0.2, amp: 0.2) + [Int16](repeating: 0, count: 16000)
        #expect(AudioGate().evaluate(samples: s) == .ok)
    }

    @Test func meterScale() {
        #expect(AudioLevel.meter(0) == 0)
        #expect(AudioLevel.meter(1) == 1)
        #expect(abs(AudioLevel.meter(0.001) - 0) < 0.01)   // -60 dB
        #expect(abs(AudioLevel.rms(tone(seconds: 1, amp: 1)) - 0.707) < 0.01)
    }
}
