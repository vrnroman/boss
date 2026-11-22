import Testing
@testable import BossCore

@Suite("Talk press: hold or toggle")
struct TalkPressTests {
    @Test func holdAndReleaseSends() {
        var p = TalkPress()
        #expect(p.press(at: 0) == .start)
        #expect(p.release(at: 0.8) == .stop)
        #expect(!p.recording)
    }
    @Test func tapStartsTapAgainSends() {
        var p = TalkPress()
        #expect(p.press(at: 0) == .start)
        #expect(p.release(at: 0.1) == .none)   // still recording
        #expect(p.recording && p.latched)
        #expect(p.press(at: 5) == .stop)
        #expect(p.release(at: 5.1) == .none)   // the second release does nothing
        #expect(!p.recording)
    }
    @Test func thresholdEdge() {
        var a = TalkPress(); _ = a.press(at: 0); #expect(a.release(at: 0.299) == .none)
        var b = TalkPress(); _ = b.press(at: 0); #expect(b.release(at: 0.3) == .stop)
    }
    @Test func resetAfterCancelStartsFresh() {
        var p = TalkPress()
        _ = p.press(at: 0); _ = p.release(at: 0.1)
        p.reset()
        #expect(p.press(at: 1) == .start)
    }
    @Test func strayReleaseDoesNothing() {
        var p = TalkPress()
        #expect(p.release(at: 1) == .none)
    }
}

@Suite("Talk controls in the engine")
@MainActor
struct TalkControlEngineTests {
    @Test func tapStartsRecordingTapAgainSends() async {
        let rig = Rig()
        rig.engine.talkControlDown(source: .hotkey)
        rig.engine.talkControlUp(source: .hotkey)          // quick tap
        #expect(rig.engine.recording != nil)
        #expect(rig.engine.talkLatched)
        #expect(rig.channel.calls.value.isEmpty)
        rig.engine.talkControlDown(source: .hotkey)        // second tap sends
        rig.engine.talkControlUp(source: .hotkey)
        #expect(await eventually { rig.channel.paths == ["/utterance"] })
        #expect(rig.engine.recording == nil)
    }

    @Test func holdAndReleaseSends() async {
        let rig = Rig()
        rig.engine.talkControlDown(source: .button)
        try? await Task.sleep(nanoseconds: 350_000_000)
        rig.engine.talkControlUp(source: .button)
        #expect(await eventually { rig.channel.paths == ["/utterance"] })
        #expect(!rig.engine.talkLatched)
    }

    @Test func escapeAfterATapCancelsAndTheNextTapStartsFresh() async {
        let rig = Rig()
        rig.engine.talkControlDown(source: .hotkey); rig.engine.talkControlUp(source: .hotkey)
        rig.engine.cancelTalk()
        #expect(rig.engine.recording == nil)
        rig.engine.talkControlDown(source: .hotkey)
        #expect(rig.engine.recording != nil)               // started again, not "sent"
        #expect(rig.channel.calls.value.isEmpty)
    }

    @Test func noMicMeansNoStuckLatch() async {
        let rig = Rig()
        rig.recorder.permission = "denied"
        rig.recorder.available = false
        rig.engine.talkControlDown(source: .button); rig.engine.talkControlUp(source: .button)
        #expect(!rig.engine.talkLatched)
        #expect(rig.engine.recording == nil)
    }
}
