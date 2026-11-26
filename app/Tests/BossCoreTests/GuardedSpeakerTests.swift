import Testing
import Foundation
@testable import BossCore

/// A voice whose synthesis waits until the test releases it, and whose playback ends when told.
@MainActor final class FakeVoice: VoiceBackend {
    var kokoro = true
    var useKokoro: (String?) -> Bool { { [unowned self] _ in self.kokoro } }
    var log: [String] = []                       // what actually reached the speakers
    var halts = 0
    private var pendingSynth: [CheckedContinuation<Data?, Never>] = []
    private var dones: [@MainActor () -> Void] = []

    func synthesize(_ text: String, lang: String) async -> Data? {
        log.append("synth:\(text)")
        return await withCheckedContinuation { pendingSynth.append($0) }
    }
    func releaseSynthesis(_ ok: Bool = true) {
        let p = pendingSynth; pendingSynth = []
        p.forEach { $0.resume(returning: ok ? Data([1]) : nil) }
    }
    func play(_ data: Data, done: @escaping @MainActor () -> Void) -> Bool { log.append("play"); dones.append(done); return true }
    func say(_ text: String, ru: Bool, done: @escaping @MainActor () -> Void) { log.append("say:\(text)"); dones.append(done) }
    func halt() { halts += 1 }
    /// The oldest output reports that it ended (late callbacks included).
    func endOldest() { if !dones.isEmpty { dones.removeFirst()() } }
    var playing: Int { dones.count }
}

func settle() async { for _ in 0..<30 { await Task.yield() }; try? await Task.sleep(nanoseconds: 20_000_000) }

@Suite("Speaker: silent the moment Roman talks")
@MainActor
struct GuardedSpeakerTests {
    @Test func stopWhileSynthesizingNeverPlaysIt() async {
        let v = FakeVoice(); let s = GuardedSpeaker(backend: v)
        var returned = false
        Task { await s.speak("payments: all green", lang: "en"); returned = true }
        await settle()
        #expect(v.log == ["synth:payments: all green"])
        s.stop()                                  // Roman presses Talk while Kokoro is still working
        v.releaseSynthesis()                      // the audio arrives a moment later
        await settle()
        #expect(returned)
        #expect(!v.log.contains("play") && !v.log.contains { $0.hasPrefix("say:") })   // not a sound
    }

    @Test func stopWhilePlayingSilencesAndReturns() async {
        let v = FakeVoice(); let s = GuardedSpeaker(backend: v)
        var returned = false
        Task { await s.speak("one", lang: "en"); returned = true }
        await settle(); v.releaseSynthesis(); await settle()
        #expect(v.log.last == "play" && !returned)
        let halts = v.halts
        s.stop()
        await settle()
        #expect(returned && v.halts == halts + 1)
    }

    @Test func aLateFinishFromAnOldLineDoesNotEndTheNewOne() async {
        let v = FakeVoice(); v.kokoro = false
        let s = GuardedSpeaker(backend: v)
        Task { await s.speak("old", lang: "en") }
        await settle()
        s.stop()                                   // cut off; its "finished" callback is still to come
        var newDone = false
        Task { await s.speak("new", lang: "en"); newDone = true }
        await settle()
        v.endOldest()                              // the old line's late callback
        await settle()
        #expect(!newDone)                          // the new line keeps playing
        v.endOldest()
        await settle()
        #expect(newDone)
    }

    @Test func noKokoroFallsBackToTheMacVoice() async {
        let v = FakeVoice(); let s = GuardedSpeaker(backend: v)
        var done = false
        Task { await s.speak("hi", lang: "en"); done = true }
        await settle(); v.releaseSynthesis(false); await settle()
        #expect(v.log == ["synth:hi", "say:hi"])
        v.endOldest(); await settle()
        #expect(done)
    }

    @Test func aNewLineStopsTheOldOneFirst() async {
        let v = FakeVoice(); v.kokoro = false
        let s = GuardedSpeaker(backend: v)
        var firstDone = false
        Task { await s.speak("a", lang: "en"); firstDone = true }
        await settle()
        Task { await s.speak("b", lang: "en") }
        #expect(await eventually { firstDone })
        #expect(v.halts >= 2 && v.log == ["say:a", "say:b"])
    }
}

@Suite("Speech with several sessions reporting")
@MainActor
struct SpeechManySessionsTests {
    func report(_ session: String, _ text: String, id: String) -> ChannelEvent {
        .say(SayEvent(id: id, text: text, links: [], speak: true, session: session, lang: "en", kind: "report", at: nil))
    }

    @Test func romanTalkingSilencesAllAndTheCutLineIsSaidAgainFromTheStart() async {
        let rig = Rig()
        rig.speaker.duration = 5
        rig.engine.handle(report("payments", "tests green", id: "a"))
        rig.engine.handle(report("gateway", "deploy done", id: "b"))
        rig.engine.handle(report("site", "copy fixed", id: "c"))
        #expect(await eventually { rig.speaker.spoken == ["payments: tests green"] })
        _ = rig.engine.beginTalk(source: .button)
        #expect(rig.speaker.stopped == 1)
        // More news while he talks: nothing is said.
        rig.engine.handle(report("reelshow", "episode 50 live", id: "d"))
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(rig.speaker.spoken == ["payments: tests green"])
        rig.speaker.duration = 0
        _ = await rig.engine.endTalk()
        #expect(await eventually { rig.speaker.spoken.count == 5 })
        #expect(rig.speaker.spoken == ["payments: tests green", "payments: tests green", "gateway: deploy done",
                                       "site: copy fixed", "reelshow: episode 50 live"])
    }

    @Test func talkingTwiceInARowStillLosesNothing() async {
        let rig = Rig()
        rig.speaker.duration = 5
        rig.engine.handle(report("payments", "one", id: "a"))
        rig.engine.handle(report("gateway", "two", id: "b"))
        #expect(await eventually { rig.speaker.spoken == ["payments: one"] })
        _ = rig.engine.beginTalk(source: .button)
        _ = await rig.engine.endTalk()
        #expect(await eventually { rig.speaker.spoken == ["payments: one", "payments: one"] })
        _ = rig.engine.beginTalk(source: .button)   // cuts it again
        rig.speaker.duration = 0
        _ = await rig.engine.endTalk()
        #expect(await eventually { rig.speaker.spoken.count == 4 })
        #expect(rig.speaker.spoken == ["payments: one", "payments: one", "payments: one", "gateway: two"])
    }
}
