import Testing
import Foundation
@testable import BossCore

@Suite("Sessions & tower")
struct SessionsTests {
    func write(_ dir: URL, _ name: String, _ json: String) {
        try! json.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    @Test func loadFiltersDeadNonInteractiveAndBoss() {
        let d = tempDir()
        write(d, "1.json", #"{"pid":1,"sessionId":"a","cwd":"/x/payments","name":"payments","status":"busy","kind":"interactive","updatedAt":1795320092669,"startedAt":1795319846088}"#)
        write(d, "2.json", #"{"pid":2,"cwd":"/x/dead","name":"dead","status":"idle","kind":"interactive"}"#)
        write(d, "3.json", #"{"pid":3,"cwd":"/x/bg","name":"bg","status":"idle","kind":"background"}"#)
        write(d, "4.json", #"{"pid":4,"cwd":"/x/boss","name":"boss","status":"idle","kind":"interactive"}"#)
        write(d, "5.json", #"{"pid":5,"cwd":"/x/gateway","status":"idle","kind":"interactive"}"#)
        write(d, "6.json", "garbage")
        write(d, "1.abc.key", "secret")
        let store = SessionsStore(dir: d, isAlive: { $0 != 2 }, ttyLookup: { _ in nil })
        let s = store.load()
        #expect(s.map(\.name) == ["gateway", "payments"])   // name falls back to cwd basename
        let p = s.first { $0.name == "payments" }!
        #expect(p.updatedAt == Date(timeIntervalSince1970: 1795320092.669))
        #expect(p.cwdBase == "payments")
    }

    @Test func filtersHideBossUnderItsTestNameAndHonourOnly() {
        let s = SessionsStore.fromEnvironment(["BOSS_NAME": "bt-boss", "BOSS_SESSIONS_ONLY": "bt-*, payments"])
        #expect(!s.visible("boss"))
        #expect(!s.visible("bt-boss"))
        #expect(s.visible("bt-alpha"))
        #expect(s.visible("payments"))
        #expect(!s.visible("reelshow-9d"))
        #expect(!s.visible("xbt-alpha"))
        let all = SessionsStore.fromEnvironment([:])
        #expect(all.visible("reelshow-9d"))
        #expect(!all.visible("Boss"))
        #expect(SessionsStore.glob("*-docs", "beta-docs"))
        #expect(SessionsStore.glob("a*c*e", "abcde"))
        #expect(!SessionsStore.glob("a*c*e", "abcdf"))
    }

    @Test func pidAliveForSelfAndNotForBogus() {
        #expect(SessionsStore.pidAlive(getpid()))
        #expect(!SessionsStore.pidAlive(999_999))
        #expect(!SessionsStore.pidAlive(0))
    }

    @Test func ttyNormalization() {
        #expect(SessionsStore.normalizeTTY("ttys003\n") == "/dev/ttys003")
        #expect(SessionsStore.normalizeTTY("??") == nil)
        #expect(SessionsStore.normalizeTTY("") == nil)
    }

    @Test func towerSortWaitingByLongestWaitThenBusyThenIdle() {
        let now = Date(timeIntervalSince1970: 10_000)
        let sessions = [
            SessionInfo(pid: 1, cwd: "/a/alpha", name: "alpha", status: "idle"),
            SessionInfo(pid: 2, cwd: "/a/bravo", name: "bravo", status: "busy"),
            SessionInfo(pid: 3, cwd: "/a/site", name: "site", status: "busy"),
            SessionInfo(pid: 4, cwd: "/a/gate", name: "gateway", status: "idle"),
            SessionInfo(pid: 5, cwd: "/a/x", name: "xray", status: "weird"),
            SessionInfo(pid: 6, cwd: "/a/c", name: "charlie", status: "busy"),
        ]
        var st = ChannelState()
        st.questions = [
            .init(questionID: "q1", question: "Which colour?", choices: [], session: "site", aboutID: nil, at: now.addingTimeInterval(-60)),
            .init(questionID: "q2", question: "Migrate now?", choices: [], session: "gateway", aboutID: nil, at: now.addingTimeInterval(-300)),
            .init(questionID: "q3", question: "Unrelated", choices: [], session: nil, aboutID: nil, at: now),
        ]
        st.reports = ["bravo": .init(text: "Renamed, all 248 tests pass.\nmore", at: now)]
        st.ledger = ["bravo": .init(blind: 14, misses: 1, graduated: true), "alpha": .init(blind: 0, misses: 0, graduated: false)]
        let rows = Tower.rows(sessions: sessions, state: st, now: now)
        #expect(rows.map(\.name) == ["gateway", "site", "bravo", "charlie", "alpha", "xray"])
        #expect(rows[0].group == .waiting && rows[0].waitText == "5 min" && rows[0].detail == "Migrate now?")
        #expect(rows[1].waitSeconds == 60)
        #expect(rows[2].detail == "Renamed, all 248 tests pass.")
        #expect(rows[2].trust == "14/15" && rows[2].graduated)
        #expect(rows[4].trust == nil)
        #expect(rows[3].waitSeconds == nil)
        #expect(Tower.counts(rows) == "2 working · 2 waiting on you")
    }

    @Test func towerUsesSeenTimeWhenStateHasNoAt() {
        let now = Date(timeIntervalSince1970: 1000)
        var st = ChannelState()
        st.questions = [.init(questionID: "q", question: "?", choices: [], session: "a", aboutID: nil, at: nil)]
        let rows = Tower.rows(sessions: [SessionInfo(pid: 1, name: "a")], state: st, now: now, questionSeen: ["q": now.addingTimeInterval(-42)])
        #expect(rows[0].waitText == "42 s")
    }

    @Test func countsText() {
        #expect(Tower.counts([]) == "no sessions")
        let idle = TowerRow(name: "a", cwdBase: "a", pid: 1, status: "idle", group: .idle, graduated: false)
        #expect(Tower.counts([idle]) == "1 idle")
    }

    @Test func shortDurations() {
        #expect(shortDuration(5) == "5 s")
        #expect(shortDuration(600) == "10 min")
        #expect(shortDuration(3900) == "1 h 5 min")
        #expect(shortDuration(-3) == "0 s")
    }
}

@Suite("Feed")
struct FeedTests {
    let t0 = Date(timeIntervalSince1970: 1000)

    @Test func youSaidLifecycle() {
        var f = FeedModel()
        f.addRecording(utteranceID: "u1", mode: "talk", answersQuestionID: nil, at: t0)
        #expect(f.card("you-u1")?.status == "saved")
        f.setTranscript(utteranceID: "u1", text: "run tests", lang: "en")
        #expect(f.card("you-u1")?.langChip == "EN")
        f.setStatus(utteranceID: "u1", "sent")
        f.apply(.routed(RoutedEvent(utteranceID: "u1", target: "payments", status: "delivered", note: nil)), at: t0)
        #expect(f.card("you-u1")?.status == "delivered")
        #expect(f.card("you-u1")?.target == "payments")
        // late "sent" never moves a delivered card backwards
        f.setStatus(utteranceID: "u1", "sent")
        f.apply(.routed(RoutedEvent(utteranceID: "u1", target: "payments", status: "sent", note: nil)), at: t0)
        #expect(f.card("you-u1")?.status == "delivered")
        #expect(f.lastRoute == "→ payments")
    }

    @Test func bossRoutedSentMeansDeliveredToTheWorker() {
        var f = FeedModel()
        f.addRecording(utteranceID: "u2", mode: "talk", answersQuestionID: nil, at: t0)
        f.setStatus(utteranceID: "u2", "sent")   // accepted by the channel: not yet in a worker
        #expect(f.card("you-u2")?.target == nil)
        f.apply(.routed(RoutedEvent(utteranceID: "u2", target: "gateway", status: "sent", note: nil)), at: t0)
        #expect(f.card("you-u2")?.status == "delivered")
        #expect(f.card("you-u2")?.target == "gateway")
        f.apply(.routed(RoutedEvent(utteranceID: "u2", target: "gateway", status: "ignored", note: nil)), at: t0)
        #expect(f.card("you-u2")?.status == "ignored")
    }

    @Test func newestFirstAndDedupe() {
        var f = FeedModel()
        let say = SayEvent(id: "s1", text: "Done.", links: [Link(title: "PR", url: "https://x")], speak: true, session: "payments", lang: "en", kind: "report", at: nil)
        #expect(Bool(f.apply(.say(say), at: t0)))
        #expect(!Bool(f.apply(.say(say), at: t0)))   // replay after reconnect: no duplicate
        f.apply(.ask(AskEvent(questionID: "q1", question: "Payments or gateway?", choices: ["payments", "gateway"], aboutID: nil, session: nil, lang: nil, at: nil)), at: t0)
        #expect(f.cards.map(\.kind) == [.question, .report])
        #expect(f.cards[1].links.count == 1)
        #expect(f.newestOpenQuestion?.questionID == "q1")
        f.markAnswered(questionID: "q1", answer: "gateway")
        #expect(f.newestOpenQuestion == nil)
        #expect(f.card("q-q1")?.answer == "gateway")
    }

    @Test func askAboutUtteranceMarksItAsking() {
        var f = FeedModel()
        f.addRecording(utteranceID: "u1", mode: "talk", answersQuestionID: nil, at: t0)
        f.apply(.ask(AskEvent(questionID: "q", question: "Which?", choices: [], aboutID: "u1", session: nil, lang: nil, at: nil)), at: t0)
        #expect(f.card("you-u1")?.status == "asking")
    }

    @Test func confirmCountdownAndCancel() {
        var f = FeedModel()
        f.addRecording(utteranceID: "u1", mode: "talk", answersQuestionID: nil, at: t0)
        f.apply(.confirm(ConfirmEvent(routeID: "r1", utteranceID: "u1", target: "site", reason: "recent topic", windowMs: 2500)), at: t0)
        let c = f.card("c-r1")!
        #expect(c.kind == .confirm && c.text == "→ site" && c.reason == "recent topic")
        #expect(c.deadline == t0.addingTimeInterval(2.5))
        #expect(f.card("you-u1")?.target == "site")
        f.cancelConfirm(routeID: "r1")
        #expect(f.card("c-r1")?.cancelled == true)
    }

    @Test func routedEndsConfirmCountdown() {
        var f = FeedModel()
        f.apply(.confirm(ConfirmEvent(routeID: "r1", utteranceID: "u1", target: "site", reason: "", windowMs: 2500)), at: t0)
        f.apply(.routed(RoutedEvent(utteranceID: "u1", target: "site", status: "sent", note: nil)), at: t0.addingTimeInterval(1))
        #expect(f.card("c-r1")?.deadline == t0.addingTimeInterval(1))
    }

    @Test func routedForUnknownUtteranceCreatesCard() {
        var f = FeedModel()
        f.apply(.routed(RoutedEvent(utteranceID: "zz", target: "gw", status: "failed", note: "no such session")), at: t0)
        #expect(f.card("you-zz")?.status == "failed")
        #expect(f.card("you-zz")?.note == "no such session")
    }

    @Test func undoneStaysUndone() {
        var f = FeedModel()
        f.addRecording(utteranceID: "u1", mode: "talk", answersQuestionID: nil, at: t0)
        f.setStatus(utteranceID: "u1", "undone")
        f.apply(.routed(RoutedEvent(utteranceID: "u1", target: "p", status: "delivered", note: nil)), at: t0)
        #expect(f.card("you-u1")?.status == "undone")
    }

    @Test func bossAndUnknownDoNotAddCards() {
        var f = FeedModel()
        #expect(!Bool(f.apply(.boss(connected: true), at: t0)))
        #expect(!Bool(f.apply(.unknown(type: "x"), at: t0)))
        #expect(f.cards.isEmpty)
    }

    @Test func keyedSystemCardsUpdateInPlace() {
        var f = FeedModel()
        f.addSystem("a", at: t0, key: "k")
        f.addSystem("b", at: t0, key: "k")
        #expect(f.cards.count == 1 && f.cards[0].text == "b")
    }

    @Test func limitDropsOldest() {
        var f = FeedModel(limit: 3)
        for i in 0..<5 { f.addSystem("\(i)", at: t0) }
        #expect(f.cards.map(\.text) == ["4", "3", "2"])
    }

    @Test func cardsEncodeToJSON() throws {
        var f = FeedModel()
        f.addRecording(utteranceID: "u1", mode: "talk", answersQuestionID: nil, at: t0)
        let r = HTTPResponse.encodable(200, ["cards": f.cards])
        let o = try JSONSerialization.jsonObject(with: r.body) as! [String: [[String: Any]]]
        #expect(o["cards"]?.first?["kind"] as? String == "youSaid")
        #expect(o["cards"]?.first?["status"] as? String == "saved")
    }
}

@Suite("SpeechQueue")
struct SpeechQueueTests {
    let t = Date(timeIntervalSince1970: 0)
    func r(_ id: String) -> SpeechItem { SpeechItem(id: id, text: id, lang: "en", priority: .report) }
    func q(_ id: String) -> SpeechItem { SpeechItem(id: id, text: id, lang: "en", priority: .question, questionID: id) }

    @Test func oneAtATime() {
        var s = SpeechQueue()
        s.enqueue(r("a"), at: t); s.enqueue(r("b"), at: t)
        #expect(s.startNext()?.id == "a")
        #expect(s.startNext() == nil)   // a is still playing
        s.finishCurrent()
        #expect(s.startNext()?.id == "b")
    }

    @Test func questionsJumpAheadOfReportsButStayFIFO() {
        var s = SpeechQueue()
        s.enqueue(r("r1"), at: t); s.enqueue(r("r2"), at: t)
        s.enqueue(q("q1"), at: t); s.enqueue(q("q2"), at: t)
        s.enqueue(r("r3"), at: t)
        #expect(s.pending.map(\.id) == ["q1", "q2", "r1", "r2", "r3"])
    }

    @Test func questionDoesNotInterruptCurrent() {
        var s = SpeechQueue()
        s.enqueue(r("r1"), at: t)
        _ = s.startNext()
        s.enqueue(q("q1"), at: t)
        #expect(s.current?.id == "r1")
        #expect(s.startNext() == nil)
    }

    @Test func pausedWhileRecording() {
        var s = SpeechQueue()
        s.paused = true
        s.enqueue(r("a"), at: t)
        #expect(s.startNext() == nil)
        s.paused = false
        #expect(s.startNext()?.id == "a")
    }

    @Test func muteDropsButLogs() {
        var s = SpeechQueue()
        s.enqueue(r("a"), at: t)
        s.setMuted(true)
        #expect(s.pending.isEmpty)
        #expect(!Bool(s.enqueue(r("b"), at: t)))
        #expect(s.startNext() == nil)
        #expect(s.log.map(\.muted) == [false, true])
    }

    @Test func duplicatesIgnored() {
        var s = SpeechQueue()
        #expect(Bool(s.enqueue(r("a"), at: t)))
        #expect(!Bool(s.enqueue(r("a"), at: t)))
        #expect(s.pending.count == 1)
    }

    @Test func repeatLast() {
        var s = SpeechQueue()
        #expect(!Bool(s.repeatLast()))
        s.enqueue(q("q"), at: t); _ = s.startNext(); s.finishCurrent()
        #expect(Bool(s.repeatLast()))
        #expect(s.pending.first?.text == "q")
        #expect(s.pending.first?.questionID == nil)   // a repeat does not reopen the mic
    }

    @Test func format() {
        #expect(SpeechItem.format(session: "payments", text: "All tests pass.") == "payments: All tests pass.")
        #expect(SpeechItem.format(session: nil, text: "Boss ready.") == "Boss ready.")
        #expect(SpeechItem.format(session: "boss", text: "Hi") == "Hi")
        #expect(SpeechItem.format(session: "payments", text: "payments: done") == "payments: done")
    }
}

@Suite("Away & Telegram")
struct TelegramTests {
    // 2026-11-22 13:01:00 UTC = 21:01 SGT
    let at = Date(timeIntervalSince1970: 1795352460)
    func say(_ id: String = "s1") -> ChannelEvent {
        .say(SayEvent(id: id, text: "All 248 tests pass.", links: [Link(title: "PR 482", url: "https://gh/482")], speak: true, session: "payments", lang: "en", kind: "report", at: nil))
    }

    @Test func sgtFormatting() {
        #expect(SGT.time(at) == "21:01 SGT")
        #expect(SGT.smart(at, now: at) == "21:01 SGT")
        #expect(SGT.smart(at, now: at.addingTimeInterval(86400)) == "2026-11-22 21:01 SGT")
    }

    @Test func awayThreshold() {
        #expect(!AwayDetector(idleSeconds: { 599 }).isAway)
        #expect(AwayDetector(idleSeconds: { 600 }).isAway)
    }

    @Test func formatsWithSGT() {
        #expect(TelegramFallback.format(say(), at: at) == "Boss 21:01 SGT: payments: All 248 tests pass.\nPR 482: https://gh/482")
        let ask = ChannelEvent.ask(AskEvent(questionID: "q", question: "Payments or gateway?", choices: ["payments", "gateway"], aboutID: nil, session: nil, lang: nil, at: nil))
        #expect(TelegramFallback.format(ask, at: at) == "Boss asks 21:01 SGT: Payments or gateway?\nChoices: payments | gateway")
        #expect(TelegramFallback.format(.boss(connected: true), at: at) == nil)
    }

    @Test func sendsWhenAwayOncePerEvent() {
        let sent = Box<[String]>([])
        let at = self.at
        let tg = TelegramFallback(away: AwayDetector(idleSeconds: { 900 }), clock: { at }) { t in sent.mutate { $0.append(t) } }
        #expect(tg.handle(say()))
        #expect(!tg.handle(say()))          // replayed event: not sent twice
        #expect(tg.handle(say("s2")))
        #expect(sent.value.count == 2)
        #expect(sent.value[0].hasPrefix("Boss 21:01 SGT: payments:"))
    }

    @Test func doesNotSendWhenActive() {
        let sent = Box<[String]>([])
        let tg = TelegramFallback(away: AwayDetector(idleSeconds: { 30 })) { t in sent.mutate { $0.append(t) } }
        #expect(!tg.handle(say()))
        #expect(sent.value.isEmpty)
    }

    @Test func doesNotSendRoutedOrWhenDisabled() {
        let sent = Box<[String]>([])
        let tg = TelegramFallback(away: AwayDetector(idleSeconds: { 9999 })) { t in sent.mutate { $0.append(t) } }
        #expect(!tg.handle(.routed(RoutedEvent(utteranceID: "u", target: "p", status: "sent", note: nil))))
        tg.enabled = false
        #expect(!tg.handle(say()))
        #expect(sent.value.isEmpty)
    }
}

@Suite("Telegram only from the real install")
struct TelegramGuardTests {
    let home = "/Users/r/Boss"
    @Test func realInstallMaySend() {
        #expect(TelegramFallback.allowed(env: [:], defaultHome: home))
        #expect(TelegramFallback.allowed(env: ["BOSS_HOME": "/Users/r/Boss/"], defaultHome: home))
    }
    @Test func testsDemosAndSandboxesNeverSend() {
        #expect(!TelegramFallback.allowed(env: ["BOSS_DEBUG_CONTROL": "1"], defaultHome: home))
        #expect(!TelegramFallback.allowed(env: ["BOSS_NO_TELEGRAM": "1"], defaultHome: home))
        #expect(!TelegramFallback.allowed(env: ["BOSS_HOME": "/var/folders/x/boss-app-e2e-1/home"], defaultHome: home))
    }
}

@Suite("Speakable text")
struct SpeakableTests {
    @Test func quotesAndBackslashesAreNotRead() {
        #expect(SpeechItem.speakable("site: заголовок «Деньги за секунды»") == "site: заголовок Деньги за секунды")
        #expect(SpeechItem.speakable("a \\ b “c”") == "a b c")
        #expect(SpeechItem.speakable("plain text") == "plain text")
    }
}
