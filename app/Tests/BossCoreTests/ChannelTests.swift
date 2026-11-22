import Testing
import Foundation
@testable import BossCore

@Suite("ChannelClient")
struct ChannelClientTests {
    func client(_ tr: RecordingTransport, token: String? = "tok") -> ChannelClient {
        ChannelClient(baseURL: URL(string: "http://127.0.0.1:8788")!, token: { token }, transport: tr)
    }
    func body(_ r: URLRequest) -> [String: Any] { (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data())) as? [String: Any] ?? [:] }

    @Test func utteranceRequest() async {
        let tr = RecordingTransport()
        tr.response.value = HTTPResult(status: 202, body: Data(#"{"ok":true,"id":"u1","duplicate":true}"#.utf8))
        let r = await client(tr).postUtterance(id: "u1", text: "hi", mode: "talk", lang: "en",
                                               sessions: [SessionInfo(pid: 1, cwd: "/a/payments", name: "payments", status: "busy")])
        #expect(r == .accepted(duplicate: true))
        let req = tr.requests.value[0]
        #expect(req.url?.absoluteString == "http://127.0.0.1:8788/utterance")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(req.value(forHTTPHeaderField: "Origin") == nil)
        let b = body(req)
        #expect(b["id"] as? String == "u1")
        #expect(b["text"] as? String == "hi")
        #expect(b["mode"] as? String == "talk")
        #expect(b["lang"] as? String == "en")
        let ss = b["sessions"] as? [[String: String]]
        #expect(ss == [["name": "payments", "cwd": "/a/payments", "status": "busy", "sessionId": ""]])
    }

    @Test func statusMapping() async {
        let tr = RecordingTransport()
        let c = client(tr)
        tr.response.value = HTTPResult(status: 503, body: Data(#"{"error":"boss offline"}"#.utf8))
        #expect(await c.postAnswer(questionID: "q", text: "a") == .bossOffline)
        tr.response.value = HTTPResult(status: 403, body: Data())
        #expect(await c.postUndo(utteranceID: "u") == .unauthorized)
        tr.response.value = HTTPResult(status: 500, body: Data("x".utf8))
        if case .failed = await c.cancelRoute(routeID: "r") {} else { Issue.record("expected failed") }
        tr.error.value = true
        if case .failed = await c.postUndo(utteranceID: "u") {} else { Issue.record("expected failed") }
    }

    @Test func otherEndpointsBodies() async {
        let tr = RecordingTransport()
        let c = client(tr)
        _ = await c.postAnswer(questionID: "q1", text: "gateway")
        _ = await c.postUndo(utteranceID: "u9")
        _ = await c.cancelRoute(routeID: "r3")
        let rs = tr.requests.value
        #expect(rs.map { $0.url!.path } == ["/answer", "/undo", "/cancel_route"])
        #expect(body(rs[0]) as? [String: String] == ["question_id": "q1", "text": "gateway"])
        #expect(body(rs[1]) as? [String: String] == ["utterance_id": "u9"])
        #expect(body(rs[2]) as? [String: String] == ["route_id": "r3"])
    }

    @Test func noTokenNoAuthHeader() async {
        let tr = RecordingTransport()
        _ = await client(tr, token: nil).getState(sessions: [])
        #expect(tr.requests.value[0].value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func stateDecodes() async throws {
        let tr = RecordingTransport()
        tr.response.value = HTTPResult(status: 200, body: Data(#"""
        {"routes":[{"route_id":"r1","utterance_id":"u1","target":"payments","explicit":true,"reason":"named","decision":"send","at":"2026-11-22T13:00:00.000Z"}],
         "questions":[{"question_id":"q1","question":"Which colour?","choices":["blue","green"],"session":"site","at":"2026-11-22T13:01:00.000Z"}],
         "reports":{"payments":{"text":"All 248 tests pass.\nPR 482","at":"2026-11-22T12:59:00Z"}},
         "ledger":{"payments":{"blind":14,"misses":1,"graduated":true},"gateway":{"blind":0,"misses":0,"graduated":false}},
         "settings":{"humor":2,"allow":"*"}}
        """#.utf8))
        let s = try #require(await client(tr).getState(sessions: []))
        #expect(s.routes.first?.target == "payments")
        #expect(s.routes.first?.status == "send")
        #expect(s.questions.first?.choices == ["blue", "green"])
        #expect(s.questions.first?.at == Timestamp.parse("2026-11-22T13:01:00Z"))
        #expect(s.reports["payments"]?.text.hasPrefix("All 248") == true)
        #expect(s.ledger["payments"] == ChannelState.Ledger(blind: 14, misses: 1, graduated: true))
        #expect(s.humor == 2)
        #expect(s.blindTotals.blind == 14 && s.blindTotals.total == 15)
    }

    @Test func health() async {
        let tr = RecordingTransport()
        tr.response.value = HTTPResult(status: 200, body: Data(#"{"ok":true,"boss_connected":false}"#.utf8))
        #expect(await client(tr).health() == false)
        tr.error.value = true
        #expect(await client(tr).health() == nil)
    }
}

@Suite("SSE")
struct SSETests {
    @Test func basicEvent() {
        var p = SSEParser()
        let m = p.feed("id: 7\nevent: say\ndata: {\"text\":\"hi\"}\n\n")
        #expect(m == [SSEMessage(id: "7", event: "say", data: "{\"text\":\"hi\"}")])
        #expect(p.lastEventID == "7")
    }

    @Test func multiLineDataAndDefaultType() {
        var p = SSEParser()
        #expect(p.feed("data: a\ndata: b\ndata:c\n\n") == [SSEMessage(id: nil, event: "message", data: "a\nb\nc")])
    }

    @Test func commentsAndKeepalivesAreIgnored() {
        var p = SSEParser()
        #expect(p.feed(": ping\n\n: ping\n\n").isEmpty)
        #expect(p.comments == 2)
    }

    @Test func eventWithoutDataIsNotDispatched() {
        var p = SSEParser()
        #expect(p.feed("event: say\nid: 3\n\n").isEmpty)
        #expect(p.lastEventID == "3")
    }

    @Test func everySplitPointGivesSameResult() {
        let stream = "id: 1\r\nevent: ask\r\ndata: {\"q\":\"Платежи или gateway?\"}\r\n\r\n: ping\n\nid: 2\nevent: routed\ndata: x\ndata: y\n\n"
        var whole = SSEParser()
        let expected = whole.feed(stream)
        #expect(expected.count == 2)
        #expect(expected[0].data == "{\"q\":\"Платежи или gateway?\"}")
        let bytes = Array(stream.utf8)
        for cut in 1..<bytes.count {
            var p = SSEParser()
            let got = p.feed(Array(bytes[0..<cut])) + p.feed(Array(bytes[cut...]))
            #expect(got == expected, "split at \(cut)")
        }
    }

    @Test func byteAtATime() {
        var p = SSEParser()
        var out: [SSEMessage] = []
        for b in "event: boss\rdata: {\"connected\":true}\r\r".utf8 { out += p.feed([b]) }
        #expect(out == [SSEMessage(id: nil, event: "boss", data: "{\"connected\":true}")])
    }

    @Test func retryField() {
        var p = SSEParser()
        _ = p.feed("retry: 2500\n\n")
        #expect(p.retryMs == 2500)
    }

    @Test func idPersistsAcrossEvents() {
        var p = SSEParser()
        let m = p.feed("id: 5\ndata: a\n\ndata: b\n\n")
        #expect(m.map(\.id) == ["5", "5"])
    }

    @Test func backoffDoublesCapsAndResets() {
        var b = Backoff(base: 0.5, cap: 4)
        #expect([b.next(), b.next(), b.next(), b.next(), b.next()] == [0.5, 1, 2, 4, 4])
        b.reset()
        #expect(b.next() == 0.5)
    }

    final class ScriptedSource: SSEStreamSource, @unchecked Sendable {
        let opens = Box<[String?]>([])
        let scripts: [[String]]
        init(_ s: [[String]]) { scripts = s }
        func open(lastEventID: String?) async throws -> AsyncThrowingStream<Data, Error> {
            let n = opens.value.count
            opens.mutate { $0.append(lastEventID) }
            guard n < scripts.count else { throw URLError(.cannotConnectToHost) }
            let chunks = scripts[n]
            return AsyncThrowingStream { c in
                for ch in chunks { c.yield(Data(ch.utf8)) }
                c.finish(throwing: URLError(.networkConnectionLost))
            }
        }
    }

    @Test func clientReconnectsWithLastEventIDAndBacksOff() async {
        let src = ScriptedSource([["id: 1\nevent: say\nda", "ta: {}\n\nid: 2\nevent: boss\ndata: {}\n\n"], ["id: 3\ndata: z\n\n"]])
        let sleeps = Box<[Double]>([])
        let got = Box<[String]>([])
        let c = SSEClient(source: src, sleep: { d in sleeps.mutate { $0.append(d) } })
        c.onMessage = { m in got.mutate { $0.append(m.id ?? "") } }
        await c.run(maxConnections: 4)
        #expect(got.value == ["1", "2", "3"])
        #expect(src.opens.value == [nil, "2", "3", "3"])
        #expect(c.lastEventID == "3")
        // data arrived on both first connections → backoff reset each time; then failures grow
        #expect(sleeps.value == [0.5, 0.5, 1])
    }
}

@Suite("ChannelEvent decoding")
struct EventDecodeTests {
    @Test func say() {
        let e = ChannelEvent.decode(type: "say", data: #"{"id":"s1","text":"Renamed.","links":[{"title":"PR 482","url":"https://x/482"}],"speak":true,"session":"payments","kind":"report","seq":4,"at":"2026-11-22T13:00:00.000Z"}"#)
        guard case .say(let s) = e else { Issue.record("not say"); return }
        #expect(s.id == "s1" && s.session == "payments" && s.links == [Link(title: "PR 482", url: "https://x/482")])
        #expect(s.at != nil)
    }
    @Test func askRoutedConfirmBoss() {
        if case .ask(let a) = ChannelEvent.decode(type: "ask", data: #"{"question_id":"q1","question":"Payments or gateway?","choices":["payments","gateway"],"about_id":"u1"}"#) {
            #expect(a.choices.count == 2 && a.aboutID == "u1")
        } else { Issue.record("ask") }
        #expect(ChannelEvent.decode(type: "routed", data: #"{"utterance_id":"u1","target":"gateway","status":"delivered"}"#)
                == .routed(RoutedEvent(utteranceID: "u1", target: "gateway", status: "delivered", note: nil)))
        #expect(ChannelEvent.decode(type: "confirm", data: #"{"route_id":"r1","utterance_id":"u1","target":"site","reason":"recent","window_ms":2500}"#)
                == .confirm(ConfirmEvent(routeID: "r1", utteranceID: "u1", target: "site", reason: "recent", windowMs: 2500)))
        #expect(ChannelEvent.decode(type: "boss", data: #"{"connected":true}"#) == .boss(connected: true))
        #expect(ChannelEvent.decode(type: "zzz", data: "{}") == .unknown(type: "zzz"))
        #expect(ChannelEvent.decode(type: "say", data: "not json") == nil)
        #expect(ChannelEvent.decode(type: "ask", data: "{}") == nil)
    }
}
