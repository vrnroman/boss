import Testing
import Foundation
@testable import BossCore

@Suite("Outbox")
struct OutboxTests {
    @Test func saveWritesWavAndJsonInSavedState() throws {
        let ob = Outbox(dir: tempDir())
        let item = try ob.save(id: "u-1", wav: Data([1, 2, 3]))
        #expect(item.state == .saved)
        #expect(FileManager.default.fileExists(atPath: ob.wavURL("u-1").path))
        #expect(FileManager.default.fileExists(atPath: ob.jsonURL("u-1").path))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: ob.jsonURL("u-1"))) as! [String: Any]
        #expect(json["id"] as? String == "u-1")
        #expect(json["state"] as? String == "saved")
        #expect(json["created_at"] is String)
        #expect(json["text"] == nil)
    }

    @Test func saveIsIdempotent() throws {
        let ob = Outbox(dir: tempDir())
        try ob.save(id: "u-1", wav: Data([1]))
        try ob.update("u-1") { $0.state = .sent; $0.text = "hi" }
        let again = try ob.save(id: "u-1", wav: Data([9, 9]))
        #expect(again.state == .sent)
        #expect(ob.wav("u-1") == Data([1]))
        #expect(ob.all().count == 1)
    }

    @Test func rejectsPathTraversalIDs() {
        let ob = Outbox(dir: tempDir())
        #expect(throws: OutboxError.invalidID) { try ob.save(id: "../evil", wav: Data()) }
        #expect(throws: OutboxError.invalidID) { try ob.save(id: "", wav: Data()) }
    }

    @Test func unsentListsOnlyRetryableOldestFirst() throws {
        var t = Date(timeIntervalSince1970: 1000)
        let ob = Outbox(dir: tempDir(), clock: { t })
        try ob.save(id: "a", wav: Data()); t += 1
        try ob.save(id: "b", wav: Data()); t += 1
        try ob.save(id: "c", wav: Data()); t += 1
        try ob.save(id: "d", wav: Data())
        try ob.update("b") { $0.state = .sent }
        try ob.update("c") { $0.state = .failed; $0.final = true }
        try ob.update("d") { $0.state = .failed }
        #expect(ob.unsent().map(\.id) == ["a", "d"])
    }

    @Test func idsAreUniqueAndValid() {
        let a = OutboxID.make(), b = OutboxID.make()
        #expect(a != b)
        #expect(OutboxID.isValid(a))
        #expect(a.hasPrefix("u-"))
    }

    @Test func retryPolicyEvery5s() {
        var p = RetryPolicy()
        #expect(Bool(p.shouldRun(at: 0)))
        #expect(!Bool(p.shouldRun(at: 1)))
        #expect(!Bool(p.shouldRun(at: 4.99)))
        #expect(Bool(p.shouldRun(at: 5)))
        #expect(!Bool(p.shouldRun(at: 6)))
        #expect(Bool(p.bossReconnected(at: 7)))
        #expect(!Bool(p.shouldRun(at: 11)))   // interval restarts at reconnect
        #expect(Bool(p.shouldRun(at: 12)))
    }
}

@Suite("Pipeline")
@MainActor
struct PipelineTests {
    @Test func outboxIsWrittenBeforeTranscription() async throws {
        let rig = Rig()
        let seen = Box<[String]>([])
        let ob = rig.outbox
        rig.transcriber.onCall = {
            // At transcription time the WAV and JSON (state saved) must already be on disk.
            for it in ob.all() {
                seen.mutate { $0.append("\(it.state.rawValue):\(FileManager.default.fileExists(atPath: ob.wavURL(it.id).path))") }
            }
        }
        #expect(rig.engine.beginTalk(source: .button))
        let id = try #require(await rig.engine.endTalk())
        #expect(seen.value == ["saved:true"])
        let item = try #require(rig.outbox.read(id))
        #expect(item.state == .sent)
        #expect(item.text == "payments: run the tests")
        #expect(item.lang == "en")
        #expect(rig.channel.paths == ["/utterance"])
        #expect(rig.channel.calls.value[0].body["id"] == id)
        #expect(rig.engine.feed.card("you-\(id)")?.status == "sent")
    }

    @Test func utteranceCarriesLiveSessions() async throws {
        let rig = Rig()
        rig.engine.beginTalk(source: .button)
        _ = await rig.engine.endTalk()
        #expect(rig.channel.sessionsSent.value == [["payments", "gateway"]])
    }

    @Test func vocabularyPromptHasSessionNames() async {
        let rig = Rig()
        rig.settings.userWords = ["Apigee"]
        rig.engine.beginTalk(source: .button)
        _ = await rig.engine.endTalk()
        #expect(rig.transcriber.prompts.value.first == "Sessions (payments, gateway, etc). Words (Apigee, etc).")
    }

    @Test func cancelSendsNothing() async {
        let rig = Rig()
        rig.engine.beginTalk(source: .hotkey)
        rig.engine.cancelTalk()
        #expect(rig.recorder.cancels == 1)
        #expect(await rig.engine.endTalk() == nil)
        #expect(rig.channel.calls.value.isEmpty)
        #expect(rig.transcriber.calls.value == 0)
        #expect(rig.outbox.all().isEmpty)
    }

    @Test func gestureEscPathSendsNothing() async {
        let rig = Rig()
        var g = GestureDetector()
        rig.engine.handleGesture(g.handle(.optionDown, at: 0))
        rig.engine.handleGesture(g.tick(at: 0.35))
        #expect(rig.engine.recording != nil)
        rig.engine.handleGesture(g.handle(.escape, at: 1))
        let t = rig.engine.handleGesture(g.handle(.optionUp, at: 1.2))
        #expect(t == nil)
        #expect(rig.engine.recording == nil)
        #expect(rig.channel.calls.value.isEmpty)
        #expect(rig.outbox.all().isEmpty)
    }

    @Test func gestureShortTapSendsNothing() async {
        let rig = Rig()
        var g = GestureDetector()
        rig.engine.handleGesture(g.handle(.optionDown, at: 0))
        rig.engine.handleGesture(g.tick(at: 0.2))
        let t = rig.engine.handleGesture(g.handle(.optionUp, at: 0.25))
        #expect(t == nil)
        #expect(rig.recorder.starts == 0)
        #expect(rig.channel.calls.value.isEmpty)
    }

    @Test func gestureHoldSends() async {
        let rig = Rig()
        var g = GestureDetector()
        rig.engine.handleGesture(g.handle(.optionDown, at: 0))
        rig.engine.handleGesture(g.tick(at: 0.3))
        let t = rig.engine.handleGesture(g.handle(.optionUp, at: 2))
        #expect(rig.recorder.stops == 1)   // mic stopped synchronously at release
        _ = await t?.value
        #expect(rig.channel.paths == ["/utterance"])
    }

    @Test func tooShortAndSilentAreDroppedBeforeOutbox() async {
        let rig = Rig()
        rig.recorder.samples = [Int16](repeating: 2000, count: 3000)   // 0.19 s
        rig.engine.beginTalk(source: .button)
        #expect(await rig.engine.endTalk() == nil)
        rig.recorder.samples = [Int16](repeating: 0, count: 32000)
        rig.engine.beginTalk(source: .button)
        #expect(await rig.engine.endTalk() == nil)
        #expect(rig.outbox.all().isEmpty)
        #expect(rig.transcriber.calls.value == 0)
        #expect(rig.channel.calls.value.isEmpty)
    }

    @Test func hallucinationIsDroppedNotSentAndNotRetried() async throws {
        let rig = Rig()
        rig.transcriber.text.value = "Thanks for watching!"
        rig.engine.beginTalk(source: .button)
        let id = try #require(await rig.engine.endTalk())
        #expect(rig.channel.calls.value.isEmpty)
        let it = try #require(rig.outbox.read(id))
        #expect(it.state == .failed && it.final == true)
        #expect(rig.outbox.unsent().isEmpty)
        #expect(rig.engine.feed.card("you-\(id)")?.status == "dropped")
        await rig.engine.retryUnsent()
        #expect(rig.channel.calls.value.isEmpty)
    }

    @Test func offlineQueuesThenRetriesOnReconnect() async throws {
        let rig = Rig()
        rig.channel.result.value = .bossOffline
        rig.engine.beginTalk(source: .button)
        let id = try #require(await rig.engine.endTalk())
        #expect(rig.outbox.read(id)?.state == .failed)
        #expect(rig.engine.feed.card("you-\(id)")?.status == "queued")
        #expect(rig.outbox.unsent().map(\.id) == [id])
        rig.channel.result.value = .accepted(duplicate: false)
        rig.engine.handle(.boss(connected: true))
        #expect(await eventually { rig.outbox.read(id)?.state == .sent })
        // transcribed once; the retry only re-posted the text
        #expect(rig.transcriber.calls.value == 1)
        #expect(rig.channel.paths == ["/utterance", "/utterance"])
        #expect(rig.channel.calls.value[1].body["id"] == id)   // same id: idempotent at the channel
    }

    @Test func retryTickEvery5sRetranscribesFailedWhisper() async throws {
        let rig = Rig()
        rig.transcriber.fail.value = true
        rig.engine.beginTalk(source: .button)
        let id = try #require(await rig.engine.endTalk())
        #expect(rig.outbox.read(id)?.state == .failed)
        #expect(rig.outbox.read(id)?.text == nil)
        #expect(rig.channel.calls.value.isEmpty)
        rig.transcriber.fail.value = false
        await rig.engine.retryTick(now: 100)
        #expect(rig.outbox.read(id)?.state == .sent)
        await rig.engine.retryTick(now: 101)   // too soon, and nothing left anyway
        #expect(rig.channel.calls.value.count == 1)
    }

    @Test func retryTickDoesNotRunWithin5s() async throws {
        let rig = Rig()
        rig.channel.result.value = .failed("down")
        rig.engine.beginTalk(source: .button)
        _ = await rig.engine.endTalk()
        await rig.engine.retryTick(now: 0)
        await rig.engine.retryTick(now: 3)
        #expect(rig.channel.calls.value.count == 2)   // original + one retry at t=0
        await rig.engine.retryTick(now: 5)
        #expect(rig.channel.calls.value.count == 3)
    }

    @Test func transcriptionGivesUpAfterMaxAttempts() async throws {
        let rig = Rig()
        rig.transcriber.fail.value = true
        rig.engine.beginTalk(source: .button)
        let id = try #require(await rig.engine.endTalk())
        for _ in 0..<10 { await rig.engine.retryUnsent() }
        #expect(rig.transcriber.calls.value == 5)
        #expect(rig.outbox.read(id)?.final == true)
    }

    @Test func languageLockIsPassedAndUsed() async throws {
        let rig = Rig()
        rig.settings.languageLock = "ru"
        rig.transcriber.lang.value = "en"
        rig.engine.beginTalk(source: .button)
        let id = try #require(await rig.engine.endTalk())
        #expect(rig.outbox.read(id)?.lang == "ru")
    }

    @Test func micUnavailableShowsSystemCard() async {
        let rig = Rig()
        rig.recorder.available = false
        rig.recorder.permission = "denied"
        #expect(!rig.engine.beginTalk(source: .button))
        #expect(rig.engine.feed.cards.first?.kind == .system)
        #expect(rig.engine.feed.cards.first?.text.contains("Microphone") == true)
    }

    @Test func resendFailedReusesID() async throws {
        let rig = Rig()
        rig.channel.result.value = .failed("x")
        rig.engine.beginTalk(source: .button)
        let id = try #require(await rig.engine.endTalk())
        rig.channel.result.value = .accepted(duplicate: false)
        await rig.engine.resend(utteranceID: id)
        #expect(rig.channel.calls.value.map { $0.body["id"] } == [id, id])
        #expect(rig.outbox.read(id)?.state == .sent)
    }

    @Test func resendSentMakesNewUtterance() async throws {
        let rig = Rig()
        rig.engine.beginTalk(source: .button)
        let id = try #require(await rig.engine.endTalk())
        await rig.engine.resend(utteranceID: id)
        let ids = rig.channel.calls.value.map { $0.body["id"]! }
        #expect(ids.count == 2 && ids[0] == id && ids[1] != id)
        #expect(rig.channel.calls.value[1].body["text"] == "payments: run the tests")
        #expect(rig.transcriber.calls.value == 1)
    }
}
