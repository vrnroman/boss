import Testing
import Foundation
@testable import BossCore

extension TL {
    /// A message Roman sent while the session was busy (delivered mid-turn).
    static func queued(_ text: String, id: String = UUID().uuidString) -> String {
        json(["type": "attachment", "uuid": id, "timestamp": "2026-11-24T04:00:30.000Z",
              "attachment": ["type": "queued_command", "commandMode": "prompt", "prompt": text, "origin": ["kind": "human"]]])
    }
    static func queuedVoice(_ body: String, id: String = UUID().uuidString) -> String {
        json(["type": "attachment", "uuid": id, "attachment": ["type": "queued_command", "commandMode": "prompt",
              "prompt": "<cross-session-message from-name=\"boss\">\n\(body)\n</cross-session-message>",
              "origin": ["kind": "peer", "name": "boss", "body": body]]])
    }
    static func taskNotice() -> String {
        json(["type": "attachment", "uuid": UUID().uuidString, "attachment": ["type": "queued_command", "commandMode": "task-notification",
              "prompt": "<task-notification>done</task-notification>", "origin": ["kind": "task-notification"]]])
    }
}

@Suite("Ask tracking: every question kept")
struct SessionThreadTests {
    @Test func aFollowUpMidTurnIsItsOwnAsk() {
        let lines = [
            TL.user("build the export feature", id: "a1"),
            TL.assistant("Starting with the schema.", stop: "tool_use"),
            TL.toolCall(), TL.toolResult(),
            TL.queued("also, which format does the bank want?", id: "a2"),
            TL.assistant("Noted: the bank wants CSV, I'll use it.", stop: "tool_use"),
            TL.toolCall(), TL.toolResult(),
            TL.queuedVoice("Roman (voice):\nand keep the old export\n(When done, SendMessage me a REPORT)", id: "a3"),
            TL.taskNotice(),
            TL.assistant("Export shipped in PR #4, CSV, old export kept.", stop: "end_turn"),
        ].joined(separator: "\n")
        let t = SessionThread.parse(lines)
        #expect(t.asks.map(\.id) == ["a1", "a2", "a3"])
        #expect(t.asks.map(\.via) == [.typed, .typed, .voice])
        #expect(t.asks[2].text == "and keep the old export")
        #expect(t.asks[0].narration == ["Starting with the schema."])
        #expect(t.asks[1].narration == ["Noted: the bank wants CSV, I'll use it."])
        #expect(t.asks.allSatisfy { $0.final == "Export shipped in PR #4, CSV, old export kept." })
        #expect(t.asks[1].isQuestion && !t.asks[0].isQuestion)
    }

    @Test func aRunningTurnLeavesItsAsksOpen() {
        let t = SessionThread.parse([TL.user("done?", id: "x"), TL.assistant("Done.", stop: "end_turn"),
                                     TL.user("now deploy it", id: "y"), TL.assistant("Deploying.", stop: "tool_use")].joined(separator: "\n"))
        #expect(t.asks.map(\.ended) == [true, false])
        #expect(t.asks[1].narration == ["Deploying."])
    }

    @Test func noiseIsNotAnAsk() {
        let lines = [TL.peer("REPORT\nSPOKEN: done", name: "reelshow"), TL.user("<command-name>/clear</command-name>"),
                     TL.taskNotice(), TL.toolResult(), TL.assistant("orphan reply", stop: "end_turn")].joined(separator: "\n")
        #expect(SessionThread.parse(lines).asks.isEmpty)
    }

    @Test func aDuplicateDeliveryIsKeptOnce() {
        let t = SessionThread.parse([TL.queued("stop the worker", id: "q"), TL.user("stop the worker", id: "u")].joined(separator: "\n"))
        #expect(t.asks.map(\.id) == ["q"])
    }

    @Test func theKeyChangesWithProgressOnly() {
        let a = SessionThread.parse(TL.user("hi", id: "a"))
        let b = SessionThread.parse([TL.user("hi", id: "a"), TL.toolCall()].joined(separator: "\n"))
        let c = SessionThread.parse([TL.user("hi", id: "a"), TL.assistant("hello", stop: "end_turn", id: "r")].joined(separator: "\n"))
        #expect(a.key == b.key)          // a tool call alone changes nothing Roman sees
        #expect(a.key != c.key)
    }

    @Test func keepsTheLastAsks() {
        let lines = (1...20).flatMap { [TL.user("task \($0)"), TL.assistant("done \($0)", stop: "end_turn")] }.joined(separator: "\n")
        #expect(SessionThread.parse(lines, limit: 3).asks.map(\.text) == ["task 18", "task 19", "task 20"])
    }
}

@Suite("Ask tracking: cards")
struct DigestViewTests {
    let thread = SessionThread(asks: [
        Ask(id: "a", text: "build the export", via: .typed, at: nil, final: "Shipped PR #4.\n\nDetails follow."),
        Ask(id: "b", text: "which format?", via: .voice, at: nil, final: "Shipped PR #4.\n\nDetails follow."),
        Ask(id: "c", text: "now deploy", via: .typed, at: nil, narration: ["Deploying to prod."]),
    ], key: "k")

    @Test func withoutADigestTheReplyIsClipped() {
        let cards = DigestView.cards(thread, digest: nil, working: true)
        #expect(cards.map(\.state) == [.answered, .answered, .working])
        #expect(cards[0].answer == "Shipped PR #4. · Details follow.")
        #expect(cards[2].answer == "Deploying to prod.")
    }

    @Test func theDigestGivesEachAskItsOwnAnswerAndFlagsMissedOnes() {
        let d = SessionDigest(key: "k", headline: "Deploying export", done: ["Export built"], next: ["Deploy"], answers: [
            .init(id: "a", state: .answered, answer: "Export built, PR #4."),
            .init(id: "b", state: .missed, answer: ""),
            .init(id: "c", state: .working, answer: ""),
        ])
        let cards = DigestView.cards(thread, digest: d, working: true)
        #expect(cards.map(\.state) == [.answered, .missed, .working])
        #expect(cards[0].answer == "Export built, PR #4.")
        #expect(cards[1].answer == "")                 // a missed question shows no borrowed answer
        #expect(cards[1].full == "Shipped PR #4.\n\nDetails follow.")
    }

    @Test func anEndedTurnIsNeverStillWorking() {
        let d = SessionDigest(key: "k", headline: "", done: [], next: [], answers: [.init(id: "a", state: .working, answer: "")])
        #expect(DigestView.cards(thread, digest: d, working: false)[0].state == .answered)
    }

    @Test func clipCutsOnAWord() {
        #expect(DigestView.clip("one two three four five", 12) == "one two…")
        #expect(DigestView.clip("**bold** `code`", 50) == "bold code")
    }
}

@Suite("Ask tracking: digest prompt")
struct DigestPromptTests {
    @Test func aSharedReplyGoesInOnce() {
        let t = SessionThread(asks: [Ask(id: "a", text: "x", via: .typed, at: nil, final: "R"),
                                     Ask(id: "b", text: "y?", via: .typed, at: nil, final: "R")], key: "k")
        let s = DigestPrompt.input(t, status: "idle")
        #expect(s.components(separatedBy: "### Turn reply\nR").count == 2)
        #expect(s.contains("id=a") && s.contains("id=b") && s.hasPrefix("<data>") && s.hasSuffix("</data>"))
    }

    @Test func decodesAndDropsBadAnswers() {
        let d = DigestPrompt.decode(["headline": "h", "done": ["1", "2", "3", "4", "5", "6"], "next": [],
                                     "answers": [["id": "a", "state": "answered", "answer": "yes"], ["id": "b", "state": "bogus"]]], key: "k")
        #expect(d?.done.count == 5 && d?.answers.map(\.id) == ["a"] && d?.key == "k")
        #expect(DigestPrompt.decode("nope", key: "k") == nil)
    }
}

final class FakeSummarizer: Summarizer, @unchecked Sendable {
    let lock = NSLock()
    var _calls: [String] = []
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
    var reply: SessionDigest?
    func digest(input: String, key: String) async -> SessionDigest? {
        lock.lock(); _calls.append(key); lock.unlock()
        return reply.map { var d = $0; d.key = key; return d }
    }
}

@Suite("Ask tracking: when to summarize")
@MainActor
struct DigestKeeperTests {
    func thread(_ key: String) -> SessionThread { SessionThread(asks: [Ask(id: "a", text: "x", via: .typed, at: nil)], key: key) }
    func settle() async { for _ in 0..<20 { await Task.yield() } }

    @Test func onlyWhenTheThreadChangedAndThrottledWhileWorking() async {
        let f = FakeSummarizer(); f.reply = SessionDigest(key: "", headline: "h", done: [], next: [], answers: [])
        let k = DigestKeeper(summarizer: f, dir: nil, minGap: 45)
        k.select(sessionId: "s1")
        let t0 = Date()
        #expect(k.update(thread("k1"), status: "busy", now: t0))
        #expect(!k.update(thread("k1"), status: "busy", now: t0))       // one at a time
        await settle()
        #expect(k.digest?.key == "k1")
        #expect(!k.update(thread("k1"), status: "idle", now: t0))       // unchanged: nothing to do
        #expect(!k.update(thread("k2"), status: "busy", now: t0.addingTimeInterval(10)))   // too soon while working
        #expect(k.update(thread("k2"), status: "idle", now: t0.addingTimeInterval(10)))    // idle: right away
        await settle()
        #expect(f.calls == ["k1", "k2"])
        #expect(!k.update(SessionThread(asks: [], key: ""), status: "idle"))                // nothing asked yet
    }

    @Test func digestsAreCachedPerSession() async {
        let dir = tempDir()
        let f = FakeSummarizer(); f.reply = SessionDigest(key: "", headline: "cached", done: [], next: [], answers: [])
        let k = DigestKeeper(summarizer: f, dir: dir)
        k.select(sessionId: "s1")
        k.update(thread("k1"), status: "idle")
        await settle()
        let again = DigestKeeper(summarizer: f, dir: dir)
        again.select(sessionId: "s1")
        #expect(again.digest?.headline == "cached")
        #expect(!again.update(thread("k1"), status: "idle"))           // reopening costs nothing
        again.select(sessionId: "s2")
        #expect(again.digest == nil)
    }

    @Test func aFailedSummaryKeepsTheOldOne() async {
        let f = FakeSummarizer()
        let k = DigestKeeper(summarizer: f, dir: nil)
        k.select(sessionId: "s")
        k.update(thread("k1"), status: "idle")
        await settle()
        #expect(k.digest == nil && !k.running)
        let none = DigestKeeper(summarizer: nil, dir: nil)
        #expect(!none.update(thread("k1"), status: "idle"))
    }
}
