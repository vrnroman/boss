import Testing
import Foundation
@testable import BossCore

@Suite("Engine flows")
@MainActor
struct EngineTests {
    func ask(_ id: String = "q1", session: String? = nil) -> ChannelEvent {
        .ask(AskEvent(questionID: id, question: "Payments or gateway?", choices: ["payments", "gateway"], aboutID: nil, session: session, lang: "en", at: nil))
    }

    @Test func askIsSpokenThenMicOpensAndSpeechPostsAnswer() async throws {
        let rig = Rig()
        rig.transcriber.text.value = "gateway"
        rig.engine.handle(ask())
        #expect(await eventually { rig.speaker.spoken == ["Payments or gateway?"] })
        // after speaking, the answer window opens and auto-closes after 6 s (fake sleep is instant)
        #expect(await eventually { rig.channel.paths == ["/answer"] })
        #expect(rig.sleeps.value.first == 6)
        #expect(rig.channel.calls.value[0].body == ["question_id": "q1", "text": "gateway"])
        #expect(!rig.channel.paths.contains("/utterance"))
        #expect(await eventually { rig.engine.feed.card("q-q1")?.answered == true })
        #expect(rig.engine.answerWindow == nil && rig.engine.recording == nil)
    }

    @Test func silentAnswerWindowSendsNothing() async {
        let rig = Rig()
        rig.recorder.samples = [Int16](repeating: 0, count: 16000 * 6)
        rig.engine.handle(ask())
        #expect(await eventually { rig.recorder.stops == 1 })
        #expect(rig.channel.calls.value.isEmpty)
        #expect(rig.outbox.all().isEmpty)
        #expect(rig.engine.feed.card("q-q1")?.answered == false)
    }

    @Test func roomNoiseInTheAnswerWindowSendsNothing() async {
        // Real run: a fan through the Brio, level above the floor but no speech, became "Japanese".
        let rig = Rig()
        rig.recorder.samples = TestAudio.roomNoise(16000 * 6)
        rig.transcriber.text.value = "ゼリーのレンジで作りましょう。"
        rig.engine.handle(ask())
        #expect(await eventually { rig.recorder.stops == 1 })
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(rig.transcriber.calls.value == 0, "noise never reaches whisper")
        #expect(rig.channel.calls.value.isEmpty)
    }

    @Test func nonLatinNonCyrillicTranscriptIsDroppedEvenFromHoldToTalk() async {
        let rig = Rig()
        rig.transcriber.text.value = "ゼリーのレンジで作りましょう。"
        rig.transcriber.lang.value = nil
        _ = rig.engine.beginTalk(source: .button)
        _ = await rig.engine.endTalk()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(!rig.channel.paths.contains("/utterance"))
    }

    @Test func answerWindowSpeechDetectedAsOtherLanguageIsDropped() async {
        let rig = Rig()
        rig.transcriber.text.value = "Ja, genau"
        rig.transcriber.lang.value = "de"
        rig.engine.handle(ask())
        #expect(await eventually { rig.recorder.stops == 1 })
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(!rig.channel.paths.contains("/answer"))
    }

    @Test func holdToTalkKeepsAMislabelledLatinTranscript() async {
        // Prompted speech is never thrown away for a language label: "never lose a word".
        let rig = Rig()
        rig.transcriber.text.value = "payments run the tests"
        rig.transcriber.lang.value = "de"
        _ = rig.engine.beginTalk(source: .button)
        _ = await rig.engine.endTalk()
        #expect(await eventually { rig.channel.paths.contains("/utterance") })
    }

    @Test func noMicPermissionNoAnswerWindow() async {
        let rig = Rig()
        rig.recorder.permission = "undetermined"
        rig.engine.handle(ask())
        #expect(await eventually { rig.speaker.spoken.count == 1 })
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(rig.recorder.starts == 0)
        #expect(rig.engine.answerWindow == nil)
    }

    @Test func debugSilentAnswerWindowWithoutMicExpiresAndRecordsNothing() async {
        let rig = Rig(sleep: { _ in try? await Task.sleep(nanoseconds: 50_000_000) })
        rig.recorder.permission = "denied"
        rig.engine.allowSilentAnswerWindow = true
        rig.engine.handle(ask())
        #expect(await eventually { rig.engine.answerWindow?.questionID == "q1" })
        #expect(rig.recorder.starts == 0)
        #expect(await eventually { rig.engine.answerWindow == nil })
        #expect(rig.channel.calls.value.isEmpty)
    }

    @Test func tapChoicePostsAnswerAndClosesWindow() async {
        let rig = Rig(sleep: { _ in try? await Task.sleep(nanoseconds: 5_000_000_000) })
        rig.engine.handle(ask())
        #expect(await eventually { rig.engine.answerWindow != nil })
        let r = await rig.engine.tapChoice(questionID: "q1", choice: "payments")
        #expect(r.isAccepted)
        #expect(rig.channel.calls.value.map(\.path) == ["/answer"])
        #expect(rig.channel.calls.value[0].body["text"] == "payments")
        #expect(rig.engine.answerWindow == nil)
        #expect(rig.engine.recording == nil)
        #expect(rig.recorder.cancels == 1)   // the open mic was discarded, not sent
    }

    @Test func debugTapByTextAndIndex() async throws {
        let rig = Rig(sleep: { _ in try? await Task.sleep(nanoseconds: 5_000_000_000) })
        rig.recorder.permission = "denied"
        rig.engine.handle(ask("q1"))
        var r = await rig.engine.debugTap(choice: "GATEWAY")
        #expect(r.status == 200)
        rig.engine.handle(ask("q2"))
        r = await rig.engine.debugTap(choice: "1")
        #expect(r.status == 200)
        #expect(rig.channel.calls.value.map { $0.body["text"] } == ["gateway", "payments"])
        r = await rig.engine.debugTap(choice: "x")
        #expect(r.status == 409)   // no open question left
        rig.engine.handle(ask("q3"))
        r = await rig.engine.debugTap(choice: "nonsense")
        #expect(r.status == 400)
    }

    @Test func questionsJumpAheadInRealQueue() async {
        let rig = Rig()
        rig.recorder.permission = "denied"
        rig.engine.handle(.say(SayEvent(id: "s1", text: "one", links: [], speak: true, session: "payments", lang: "en", kind: "report", at: nil)))
        rig.engine.handle(.say(SayEvent(id: "s2", text: "two", links: [], speak: true, session: "payments", lang: "en", kind: "report", at: nil)))
        rig.engine.handle(ask(session: "site"))
        #expect(await eventually { rig.speaker.spoken.count == 3 })
        #expect(rig.speaker.spoken == ["payments: one", "site: Payments or gateway?", "payments: two"])
    }

    @Test func speechPausedWhileRecording() async {
        let rig = Rig()
        rig.engine.beginTalk(source: .button)
        rig.engine.handle(.say(SayEvent(id: "s1", text: "done", links: [], speak: true, session: "p", lang: "en", kind: "report", at: nil)))
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(rig.speaker.spoken.isEmpty)
        _ = await rig.engine.endTalk()
        #expect(await eventually { rig.speaker.spoken == ["p: done"] })
    }

    @Test func muteKeepsCardsButSilences() async {
        let rig = Rig()
        rig.engine.setMuted(true)
        rig.engine.handle(.say(SayEvent(id: "s1", text: "done", links: [], speak: true, session: "p", lang: "en", kind: "report", at: nil)))
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(rig.speaker.spoken.isEmpty)
        #expect(rig.engine.feed.cards.count == 1)
        #expect(rig.engine.speech.log.count == 1 && rig.engine.speech.log[0].muted)
    }

    @Test func speakFalseIsNotSpoken() async {
        let rig = Rig()
        rig.engine.handle(.say(SayEvent(id: "s1", text: "quiet", links: [], speak: false, session: nil, lang: nil, kind: "info", at: nil)))
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(rig.speaker.spoken.isEmpty)
        #expect(rig.engine.feed.cards.count == 1)
    }

    @Test func replayedEventsAreNotSpokenTwice() async {
        let rig = Rig()
        let e = ChannelEvent.say(SayEvent(id: "s1", text: "done", links: [], speak: true, session: nil, lang: nil, kind: "report", at: nil))
        rig.engine.handle(e); rig.engine.handle(e)
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(rig.speaker.spoken == ["done"])
    }

    @Test func telegramOnlyWhenAway() async {
        let idle = Box<Double>(0)
        let sent = Box<[String]>([])
        let tg = TelegramFallback(away: AwayDetector(idleSeconds: { idle.value })) { t in sent.mutate { $0.append(t) } }
        let rig = Rig(telegram: tg)
        rig.recorder.permission = "denied"
        rig.engine.handle(.say(SayEvent(id: "s1", text: "a", links: [], speak: true, session: nil, lang: nil, kind: "report", at: nil)))
        #expect(sent.value.isEmpty)
        idle.value = 601
        rig.engine.handle(.say(SayEvent(id: "s2", text: "b", links: [], speak: true, session: nil, lang: nil, kind: "report", at: nil)))
        rig.engine.handle(ask())
        #expect(sent.value.count == 2)
        #expect(sent.value[0].contains("SGT: b"))
    }

    @Test func undoNewestSent() async throws {
        let rig = Rig()
        rig.engine.beginTalk(source: .button)
        let id = try #require(await rig.engine.endTalk())
        let r = await rig.engine.debugUndo()
        #expect(r.status == 200)
        #expect(rig.channel.calls.value.last == FakeChannel.Call(path: "/undo", body: ["utterance_id": id]))
        #expect(rig.engine.feed.card("you-\(id)")?.status == "undone")
        #expect(await rig.engine.debugUndo().status == 409)   // nothing left to undo
    }

    @Test func cancelRoute() async {
        let rig = Rig()
        rig.engine.handle(.confirm(ConfirmEvent(routeID: "r1", utteranceID: "u1", target: "site", reason: "", windowMs: 2500)))
        await rig.engine.cancelRoute(routeID: "r1")
        #expect(rig.channel.paths == ["/cancel_route"])
        #expect(rig.engine.feed.card("c-r1")?.cancelled == true)
    }

    @Test func statusColours() async {
        let rig = Rig()
        #expect(rig.engine.status == .offline)
        rig.engine.applyHealth(true)
        #expect(rig.engine.status == .idle)
        rig.engine.beginTalk(source: .button)
        #expect(rig.engine.status == .listening)
        rig.engine.cancelTalk()
        rig.engine.applyHealth(nil)
        #expect(rig.engine.status == .offline)
        #expect(!rig.engine.bossConnected)
    }

    @Test func injectRunsFullPipeline() async throws {
        let rig = Rig()
        let path = tempDir().appendingPathComponent("x.wav")
        try WAV.encode(samples: rig.recorder.samples).write(to: path)
        let r = await rig.engine.debugInject(wavPath: path.path)
        let o = try JSONSerialization.jsonObject(with: r.body) as! [String: Any]
        #expect(o["state"] as? String == "sent")
        #expect(o["text"] as? String == "payments: run the tests")
        let id = o["id"] as! String
        #expect(rig.outbox.wav(id) != nil)
        #expect(rig.channel.paths == ["/utterance"])
    }

    @Test func injectSilenceIsDropped() async throws {
        let rig = Rig()
        let path = tempDir().appendingPathComponent("s.wav")
        try WAV.encode(samples: [Int16](repeating: 0, count: 16000)).write(to: path)
        let r = await rig.engine.debugInject(wavPath: path.path)
        let o = try JSONSerialization.jsonObject(with: r.body) as! [String: Any]
        #expect(o["dropped"] as? String == "silent")
        #expect(rig.channel.calls.value.isEmpty && rig.transcriber.calls.value == 0)
        #expect(await rig.engine.debugInject(wavPath: "/nonexistent.wav").status == 400)
    }

    @Test func injectDuringAnswerWindowAnswers() async throws {
        let rig = Rig(sleep: { _ in try? await Task.sleep(nanoseconds: 5_000_000_000) })
        rig.transcriber.text.value = "gateway"
        rig.engine.handle(ask())
        #expect(await eventually { rig.engine.answerWindow != nil })
        let path = tempDir().appendingPathComponent("a.wav")
        try WAV.encode(samples: rig.recorder.samples).write(to: path)
        let r = await rig.engine.debugInject(wavPath: path.path)
        let o = try JSONSerialization.jsonObject(with: r.body) as! [String: Any]
        #expect(o["question_id"] as? String == "q1")
        #expect(rig.channel.paths == ["/answer"])
    }

    @Test func debugTalkDrivesSamePath() async throws {
        let rig = Rig()
        #expect(await rig.engine.debugTalk(down: false).status == 409)
        #expect(await rig.engine.debugTalk(down: true).status == 200)
        #expect(rig.engine.recording?.source == .debug)
        let r = await rig.engine.debugTalk(down: false)
        let o = try JSONSerialization.jsonObject(with: r.body) as! [String: Any]
        #expect(o["state"] as? String == "sent")
        #expect(rig.channel.paths == ["/utterance"])
    }

    @Test func countsIncludeBossQuestions() async {
        let rig = Rig()
        rig.recorder.permission = "denied"
        #expect(rig.engine.countsText == "1 working")
        rig.engine.handle(ask())
        #expect(rig.engine.countsText == "1 working · 1 question")
        _ = await rig.engine.tapChoice(questionID: "q1", choice: "gateway")
        #expect(rig.engine.countsText == "1 working")
    }

    @Test func debugStatusShape() throws {
        let rig = Rig()
        rig.engine.hotkeyActive = true
        let o = try JSONSerialization.jsonObject(with: rig.engine.debugStatus().body) as! [String: Any]
        #expect(o["panel"] as? String == "pill")
        #expect(o["hotkey_tap_active"] as? Bool == true)
        #expect(o["mic_permission"] as? String == "granted")
        #expect(o["boss_connected"] as? Bool == false)
    }

    @Test func livePreviewChip() {
        let rig = Rig()
        rig.engine.updatePartialTranscript("гейтвей запусти")
        #expect(rig.engine.previewTarget == nil)   // not recording: ignored
        rig.engine.beginTalk(source: .button)
        rig.engine.updatePartialTranscript("гейтвей запусти")
        #expect(rig.engine.previewTarget == "gateway")
        rig.settings.livePreview = false
        rig.engine.updatePartialTranscript("payments")
        #expect(rig.engine.previewTarget == "gateway")   // setting off: no updates
        rig.engine.cancelTalk()
        #expect(rig.engine.previewTarget == nil)
    }

    @Test func soundsFollowToggle() async {
        let rig = Rig()
        rig.engine.beginTalk(source: .button)
        _ = await rig.engine.endTalk()
        #expect(rig.sounds.played == [.start, .stop, .sent])
        rig.settings.radioSounds = false
        rig.sounds.played = []
        rig.engine.beginTalk(source: .button)
        _ = await rig.engine.endTalk()
        #expect(rig.sounds.played.isEmpty)
    }
}
