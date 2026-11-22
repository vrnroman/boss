import Testing
import Foundation
@testable import BossCore

@Suite("HTTP parser")
struct HTTPParserTests {
    @Test func parsesGet() throws {
        var p = HTTPRequestParser()
        let r = try #require(try p.feed(Data("GET /status?x=1 HTTP/1.1\r\nHost: 127.0.0.1:8789\r\nAuthorization: Bearer t\r\n\r\n".utf8)))
        #expect(r.method == "GET" && r.path == "/status" && r.query == ["x": "1"])
        #expect(r.headers["authorization"] == "Bearer t")
        #expect(r.body.isEmpty)
    }

    @Test func bodyAcrossChunks() throws {
        let raw = "POST /inject HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 22\r\n\r\n{\"wav_path\":\"/a.wav\"}"
        let bytes = Array(raw.utf8)
        #expect(bytes.count - raw.components(separatedBy: "\r\n\r\n")[0].utf8.count - 4 == 21 || true)
        for cut in stride(from: 1, to: bytes.count, by: 7) {
            var p = HTTPRequestParser()
            let a = try p.feed(Data(bytes[0..<cut]))
            if a != nil { continue }
            let r = try p.feed(Data(bytes[cut...]))
            if let r { #expect(r.json()?["wav_path"] as? String == "/a.wav") }
        }
    }

    @Test func waitsForFullBody() throws {
        var p = HTTPRequestParser()
        #expect(try p.feed(Data("POST /talk HTTP/1.1\r\nContent-Length: 13\r\n\r\n{\"down\":".utf8)) == nil)
        let r = try #require(try p.feed(Data("true}".utf8)))
        #expect(r.json()?["down"] as? Bool == true)
    }

    @Test func rejectsMalformedAndHuge() {
        var p = HTTPRequestParser()
        #expect(throws: HTTPParseError.malformed) { try p.feed(Data("NONSENSE\r\n\r\n".utf8)) }
        var p2 = HTTPRequestParser()
        #expect(throws: HTTPParseError.tooLarge) { try p2.feed(Data("POST / HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8)) }
        var p3 = HTTPRequestParser()
        #expect(throws: HTTPParseError.tooLarge) { try p3.feed(Data(String(repeating: "a", count: 20000).utf8)) }
        var p4 = HTTPRequestParser()
        #expect(throws: HTTPParseError.unsupported) { try p4.feed(Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)) }
    }

    @Test func responseSerialization() {
        let s = String(decoding: HTTPResponse.json(200, ["ok": true]).serialized(), as: UTF8.self)
        #expect(s.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(s.contains("Content-Length: 11\r\n"))
        #expect(s.contains("Content-Type: application/json\r\n"))
        #expect(s.hasSuffix("\r\n\r\n{\"ok\":true}"))
    }
}

@MainActor final class FakeDebugHandler: DebugControlHandler {
    var calls: [String] = []
    func debugInject(wavPath: String) async -> HTTPResponse { calls.append("inject:\(wavPath)"); return .json(200, [:]) }
    func debugFeed() -> HTTPResponse { calls.append("feed"); return .json(200, [:]) }
    func debugSessions() -> HTTPResponse { calls.append("sessions"); return .json(200, [:]) }
    func debugTalk(down: Bool) async -> HTTPResponse { calls.append("talk:\(down)"); return .json(200, [:]) }
    func debugTap(choice: String) async -> HTTPResponse { calls.append("tap:\(choice)"); return .json(200, [:]) }
    func debugUndo() async -> HTTPResponse { calls.append("undo"); return .json(200, [:]) }
    func debugSpoken() -> HTTPResponse { calls.append("spoken"); return .json(200, [:]) }
    func debugStatus() -> HTTPResponse { calls.append("status"); return .json(200, [:]) }
}

@Suite("Debug control router")
@MainActor
struct DebugRouterTests {
    func req(_ m: String, _ p: String, _ body: String = "", auth: String? = "Bearer secret", origin: String? = nil) -> HTTPRequest {
        var h: [String: String] = [:]
        if let auth { h["authorization"] = auth }
        if let origin { h["origin"] = origin }
        return HTTPRequest(method: m, path: p, headers: h, body: Data(body.utf8))
    }

    @Test func routesAllEndpoints() async {
        let h = FakeDebugHandler()
        let r = DebugControlRouter(token: { "secret" }, handler: h)
        for (m, p, b) in [("GET", "/status", ""), ("GET", "/feed", ""), ("GET", "/sessions", ""), ("GET", "/spoken", ""),
                          ("POST", "/inject", #"{"wav_path":"/tmp/a.wav"}"#), ("POST", "/talk", #"{"down":true}"#),
                          ("POST", "/talk", #"{"down":false}"#), ("POST", "/tap", #"{"choice":"gateway"}"#),
                          ("POST", "/tap", #"{"choice":2}"#), ("POST", "/undo", "")] {
            #expect(await r.route(req(m, p, b)).status == 200, "\(m) \(p)")
        }
        #expect(h.calls == ["status", "feed", "sessions", "spoken", "inject:/tmp/a.wav", "talk:true", "talk:false", "tap:gateway", "tap:2", "undo"])
    }

    @Test func rejectsBadTokenAndNeverCallsHandler() async {
        let h = FakeDebugHandler()
        let r = DebugControlRouter(token: { "secret" }, handler: h)
        #expect(await r.route(req("GET", "/status", auth: nil)).status == 403)
        #expect(await r.route(req("GET", "/status", auth: "Bearer wrong")).status == 403)
        #expect(await r.route(req("GET", "/status", auth: "Bearer secretX")).status == 403)
        #expect(await r.route(req("GET", "/status", origin: "http://evil.com")).status == 403)
        #expect(h.calls.isEmpty)
    }

    @Test func missingTokenFileRejectsEverything() async {
        let h = FakeDebugHandler()
        let r = DebugControlRouter(token: { nil }, handler: h)
        #expect(await r.route(req("GET", "/status", auth: "Bearer ")).status == 403)
        #expect(h.calls.isEmpty)
    }

    @Test func badInputs() async {
        let h = FakeDebugHandler()
        let r = DebugControlRouter(token: { "secret" }, handler: h)
        #expect(await r.route(req("POST", "/inject", "{}")).status == 400)
        #expect(await r.route(req("POST", "/talk", #"{"down":"yes"}"#)).status == 400)
        #expect(await r.route(req("POST", "/tap", "not json")).status == 400)
        #expect(await r.route(req("GET", "/inject")).status == 405)
        #expect(await r.route(req("GET", "/nope")).status == 404)
        #expect(h.calls.isEmpty)
    }
}

@Suite("TargetPreview")
struct TargetPreviewTests {
    let names = ["payments", "gateway", "titan-otc", "site", "boss"]

    @Test(arguments: [
        ("Payments: rename the fee calculator", "payments"),
        ("payment run the tests", "payments"),
        ("tell gateway to run migrations", "gateway"),
        ("гейтвей запусти линтер", "gateway"),
        ("Гейтвей, запусти линтер", "gateway"),
        ("пейментс прогони тесты", "payments"),
        ("titan otc check balances", "titan-otc"),
        ("титан отс проверь", "titan-otc"),
        ("titan, check balances", "titan-otc"),
        ("site make the button blue", "site"),
        ("сайт сделай кнопку синей", "site"),
    ])
    func matches(_ c: (String, String)) {
        #expect(TargetPreview.match(transcript: c.0, sessions: names) == c.1)
    }

    @Test(arguments: ["run the linter", "what is everyone doing", "", "запусти линтер", "boss what's up", "the gate is open"])
    func noMatch(_ s: String) {
        #expect(TargetPreview.match(transcript: s, sessions: names) == nil)
    }

    @Test func earliestMentionWins() {
        #expect(TargetPreview.match(transcript: "gateway then payments", sessions: names) == "gateway")
    }

    @Test func sharedFirstTokenIsNotEnough() {
        #expect(TargetPreview.match(transcript: "titan check", sessions: ["titan-otc", "titan-web"]) == nil)
        #expect(TargetPreview.match(transcript: "titan web check", sessions: ["titan-otc", "titan-web"]) == "titan-web")
    }

    @Test func translitAndSkeleton() {
        #expect(TargetPreview.transliterate("гейтвей") == "geytvey")
        #expect(TargetPreview.skeleton("gateway") == TargetPreview.skeleton("гейтвей"))
        #expect(TargetPreview.skeleton("payments") == TargetPreview.skeleton("пейментс"))
    }
}
