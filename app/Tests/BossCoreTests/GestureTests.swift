import Testing
@testable import BossCore

@Suite("GestureDetector")
struct GestureTests {
    /// Press at 0, release at `ms`, ticking every 1 ms in between (like the app's timer).
    func press(_ g: inout GestureDetector, from start: Double, ms: Double, tick: Bool = true) -> [GestureEvent] {
        var out = g.handle(.optionDown, at: start)
        if tick {
            var t = start
            while t < start + ms / 1000 - 1e-9 { out += g.tick(at: t); t += 0.001 }
        }
        out += g.handle(.optionUp, at: start + ms / 1000)
        return out
    }

    @Test func pressOf299msIsTapNotTalk() {
        var g = GestureDetector()
        let e = press(&g, from: 10, ms: 299)
        #expect(e == [.armed, .tap])
        #expect(!e.contains(.talkStart) && !e.contains(.talkEnd))
    }

    @Test func pressOf300msIsHold() {
        var g = GestureDetector()
        #expect(press(&g, from: 10, ms: 300, tick: false) == [.armed, .talkStart, .talkEnd])
    }

    @Test func pressOf301msIsHoldViaTick() {
        var g = GestureDetector()
        #expect(press(&g, from: 10, ms: 301) == [.armed, .talkStart, .talkEnd])
    }

    @Test func tickBeforeThresholdDoesNothing() {
        var g = GestureDetector()
        _ = g.handle(.optionDown, at: 0)
        #expect(g.tick(at: 0.299) == [])
        #expect(g.tick(at: 0.300) == [.talkStart])
        #expect(g.tick(at: 0.5) == [])          // only once
        #expect(g.isRecording)
        #expect(g.handle(.optionUp, at: 2) == [.talkEnd])
        #expect(g.state == .idle)
    }

    func doubleTap(gapMs: Double) -> [GestureEvent] {
        var g = GestureDetector()
        var e = press(&g, from: 0, ms: 50)                    // first tap released at 0.050
        e += press(&g, from: 0.050 + gapMs / 1000 - 0.040, ms: 40)   // second released at 0.050 + gap
        return e
    }

    @Test func doubleTapAt349ms() { #expect(doubleTap(gapMs: 349) == [.armed, .tap, .armed, .doubleTap]) }
    @Test func doubleTapAt350ms() { #expect(doubleTap(gapMs: 350) == [.armed, .tap, .armed, .doubleTap]) }
    @Test func noDoubleTapAt351ms() {
        let e = doubleTap(gapMs: 351)
        #expect(e == [.armed, .tap, .armed, .tap])
        #expect(!e.contains(.doubleTap))
    }

    @Test func tripleTapIsDoubleThenTap() {
        var g = GestureDetector()
        var e = press(&g, from: 0, ms: 40)
        e += press(&g, from: 0.1, ms: 40)
        e += press(&g, from: 0.2, ms: 40)
        #expect(e.filter { $0 == .doubleTap }.count == 1)
        #expect(e.last == .tap)
    }

    @Test func holdBetweenTapsBreaksDoubleTap() {
        var g = GestureDetector()
        var e = press(&g, from: 0, ms: 40)
        e += press(&g, from: 0.1, ms: 400)
        #expect(!e.contains(.doubleTap))
        #expect(e.suffix(2) == [.talkStart, .talkEnd])
    }

    @Test func escWhileRecordingCancelsAndReleaseSendsNothing() {
        var g = GestureDetector()
        _ = g.handle(.optionDown, at: 0)
        _ = g.tick(at: 0.4)
        #expect(g.handle(.escape, at: 1) == [.cancel])
        let up = g.handle(.optionUp, at: 1.5)
        #expect(up == [])
        #expect(!up.contains(.talkEnd))
        #expect(g.state == .idle)
    }

    @Test func escBeforeThresholdCancelsAndNeverStartsTalk() {
        var g = GestureDetector()
        _ = g.handle(.optionDown, at: 0)
        #expect(g.handle(.escape, at: 0.1) == [.cancel])
        #expect(g.tick(at: 0.5) == [])
        #expect(g.handle(.optionUp, at: 0.6) == [])
    }

    @Test func escWhenIdleDoesNothing() {
        var g = GestureDetector()
        #expect(g.handle(.escape, at: 0) == [])
        #expect(g.state == .idle)
    }

    @Test func optionAsChordModifierIsNotAGesture() {
        var g = GestureDetector()
        _ = g.handle(.optionDown, at: 0)
        #expect(g.handle(.otherKey, at: 0.1) == [.cancel])
        #expect(g.tick(at: 0.5) == [])
        #expect(g.handle(.optionUp, at: 0.6) == [])
    }

    @Test func otherKeyWhileRecordingKeepsRecording() {
        var g = GestureDetector()
        _ = g.handle(.optionDown, at: 0)
        _ = g.tick(at: 0.3)
        #expect(g.handle(.otherKey, at: 0.5) == [])
        #expect(g.handle(.optionUp, at: 1) == [.talkEnd])
    }

    @Test func repeatedDownIsIgnored() {
        var g = GestureDetector()
        _ = g.handle(.optionDown, at: 0)
        #expect(g.handle(.optionDown, at: 0.1) == [])
        #expect(g.handle(.optionUp, at: 0.15) == [.tap])
    }

    @Test func strayUpIsIgnored() {
        var g = GestureDetector()
        #expect(g.handle(.optionUp, at: 0) == [])
    }
}
