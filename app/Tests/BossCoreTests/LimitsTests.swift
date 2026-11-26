import Testing
import Foundation
@testable import BossCore

/// Response shapes as the three providers sent them on 2026-11-26.
enum LimitFixtures {
    static let claude = """
    {"five_hour":null,"seven_day":{"utilization":5.0,"resets_at":"2026-12-03T06:00:00.178161+00:00"},
     "limits":[{"kind":"weekly_all","group":"weekly","percent":5,"severity":"normal","resets_at":"2026-12-03T06:00:00.178161+00:00","scope":null,"is_active":true},
               {"kind":"weekly_scoped","group":"weekly","percent":1,"resets_at":"2026-12-03T06:00:00.178333+00:00","scope":{"model":{"id":null,"display_name":"Fable"}},"is_active":false}]}
    """
    static let claudeOld = """
    {"five_hour":{"utilization":42.0,"resets_at":"2026-11-26T19:00:00+00:00"},"seven_day":{"utilization":80,"resets_at":"2026-12-03T06:00:00Z"}}
    """
    static let kimi = """
    {"usage":{"limit":"100","used":"5","remaining":"95","resetTime":"2026-11-29T14:16:28.988438Z"},
     "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","used":"12","remaining":"88","resetTime":"2026-11-26T19:16:28.988438Z"}}],
     "usages":{"limit_5h":{"used_ratio":0.1158,"reset_time":"2026-11-26T19:16:29Z"},"limit_7d":{"used_ratio":0.0491,"reset_time":"2026-11-29T14:16:28Z"}}}
    """
    static let kimiNoUsages = """
    {"usage":{"limit":"100","used":"5","remaining":"95","resetTime":"2026-11-29T14:16:28Z"},
     "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","used":"12","resetTime":"2026-11-26T19:16:28Z"}},
               {"window":{"duration":1,"timeUnit":"TIME_UNIT_DAY"},"detail":{"limit":"50","remaining":"10","resetTime":"2026-11-27T00:00:00Z"}}]}
    """
    static let gemini = """
    {"models":{"gemini-4-hydrogen-sonar":{"quotaInfo":{"remainingFraction":0.9796,"resetTime":"2026-11-26T20:06:34Z"}},
               "gemini-3-flash":{"quotaInfo":{"remainingFraction":0.99,"resetTime":"2026-11-26T20:06:34Z"}},
               "claude-opus-5-5-high":{"quotaInfo":{"remainingFraction":0.10,"resetTime":"2026-11-26T20:32:03Z"}},
               "tab_flash_lite_preview":{"quotaInfo":{"remainingFraction":1}}}}
    """
    static func d(_ s: String) -> Data { Data(s.utf8) }
}

struct LimitsParseTests {
    let now = LimitsParse.date("2026-11-26T15:30:00Z")!

    @Test func claudeReadsActiveLimitsOnlyWithTheirReset() throws {
        let p = try #require(LimitsParse.claude(LimitFixtures.d(LimitFixtures.claude), now: now))
        #expect(p.windows.count == 1)                       // the inactive Fable-scoped one is left out
        #expect(p.windows[0].label == "week")
        #expect(abs(p.windows[0].used - 0.05) < 1e-9)
        #expect(abs(p.windows[0].resetsAt!.timeIntervalSince(LimitsParse.date("2026-12-03T06:00:00Z")!)) < 1)
    }

    @Test func claudeFallsBackToNamedWindowsShortestFirst() throws {
        let p = try #require(LimitsParse.claude(LimitFixtures.d(LimitFixtures.claudeOld), now: now))
        #expect(p.windows.map(\.label) == ["5h", "week"])
        #expect(abs(p.peak - 0.8) < 1e-9)
        #expect(p.peakWindow?.label == "week")
    }

    @Test func claudeWithNoWindowsIsNothing() {
        #expect(LimitsParse.claude(LimitFixtures.d(#"{"five_hour":null,"seven_day":null,"limits":[]}"#), now: now) == nil)
        #expect(LimitsParse.claude(LimitFixtures.d("not json"), now: now) == nil)
    }

    @Test func kimiPrefersTheNamedRatios() throws {
        let p = try #require(LimitsParse.kimi(LimitFixtures.d(LimitFixtures.kimi), now: now))
        #expect(p.windows.map(\.label) == ["5h", "week"])
        #expect(abs(p.windows[0].used - 0.1158) < 1e-9)
        #expect(p.windows[1].resetsAt == LimitsParse.date("2026-11-29T14:16:28Z"))
    }

    @Test func kimiWindowsFromDurationsWhenRatiosAreMissing() throws {
        let p = try #require(LimitsParse.kimi(LimitFixtures.d(LimitFixtures.kimiNoUsages), now: now))
        #expect(p.windows.map(\.label) == ["5h", "day", "plan"])
        #expect(abs(p.windows[1].used - 0.8) < 1e-9)       // 10 of 50 remaining
    }

    @Test func geminiIsTheEmptiestGeminiModelNotTheOthers() throws {
        let p = try #require(LimitsParse.gemini(LimitFixtures.d(LimitFixtures.gemini), now: now))
        #expect(p.windows.count == 1)
        #expect(abs(p.windows[0].used - (1 - 0.9796)) < 1e-6)   // claude-opus at 10% left is ignored
        #expect(!p.limitedNow && p.note == nil)
        let limited = try #require(LimitsParse.gemini(LimitFixtures.d(LimitFixtures.gemini), exhausted: ["gemini-4-neon-xhigh"], now: now))
        #expect(limited.limitedNow && limited.note == "Neon limited now" && limited.peak == 1)
    }

    @Test func durationLabels() {
        #expect(LimitsParse.durationLabel(seconds: 5 * 3600) == "5h")
        #expect(LimitsParse.durationLabel(seconds: 86_400) == "day")
        #expect(LimitsParse.durationLabel(seconds: 7 * 86_400) == "week")
        #expect(LimitsParse.durationLabel(seconds: 30 * 86_400) == "month")
        #expect(LimitsParse.durationLabel(seconds: 1800) == "30m")
        #expect(LimitsParse.kimiKeyLabel("limit_1m") == "month")
        #expect(LimitsParse.kimiKeyLabel("limit_1d") == "day")
        #expect(LimitsParse.kimiKeyLabel("limit_7d") == "week")
    }

    @Test func proxyLogRecentQuotaRefusalsOnly() {
        let tz = TimeZone(identifier: "Asia/Singapore")!
        let now = LimitsParse.date("2026-11-26T15:30:00Z")!          // 23:30 SGT
        let log = """
        [2026-11-26 23:05:00] [a] [warn ] 429 | upstream execution failed: provider=antigravity model=gemini-4-argon-high err={ "status": "RESOURCE_EXHAUSTED" }
        [2026-11-26 23:23:48] [b] [warn ] 429 | upstream execution failed: provider=antigravity model=gemini-4-neon-xhigh auth=x err={ "status": "RESOURCE_EXHAUSTED" }
        [2026-11-26 23:25:13] [c] [warn ] auth unavailable for model "gemini-4-hydrogen-xhigh" (provider=antigravity) are in cooldown: [reason=quota, remaining=2s]
        [2026-11-26 23:26:00] [d] [info ] 200 | model=gemini-4-neon-xhigh ok
        """
        #expect(LimitsParse.proxyExhausted(log: log, now: now, timeZone: tz) == ["gemini-4-neon-xhigh", "gemini-4-hydrogen-xhigh"])
        #expect(LimitsParse.proxyExhausted(log: log, now: now.addingTimeInterval(3600), timeZone: tz).isEmpty)
    }

    @Test func resetTextIsLocalAndShort() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Singapore")!
        let now = LimitsParse.date("2026-11-26T15:30:00Z")!          // Thu 23:30 SGT
        #expect(ResetText.format(LimitsParse.date("2026-11-26T15:45:00Z"), now: now, calendar: cal) == "23:45")
        #expect(ResetText.format(LimitsParse.date("2026-11-26T19:16:29Z"), now: now, calendar: cal) == "tomorrow 03:16")
        #expect(ResetText.format(LimitsParse.date("2026-11-29T14:16:28Z"), now: now, calendar: cal) == "Sun 22:16")
        #expect(ResetText.format(LimitsParse.date("2026-12-03T06:00:00Z"), now: now, calendar: cal) == "Dec 3 14:00")
        #expect(ResetText.format(LimitsParse.date("2026-11-26T15:00:00Z"), now: now, calendar: cal) == "now")
        #expect(ResetText.countdown(LimitsParse.date("2026-11-26T19:16:29Z"), now: now) == "in 3h 46m")
        #expect(ResetText.countdown(LimitsParse.date("2026-11-29T14:16:28Z"), now: now) == "in 2d 22h")
    }
}

struct KimiKeyTests {
    @Test func findsTheKeyOnlyInAKimiCodeSetup() {
        let script = """
        # Claude Code on Kimi Code
        export ANTHROPIC_BASE_URL=https://api.kimi.com/coding/
        export ANTHROPIC_API_KEY="sk-kimi-abcdefghijklmnop1234"
        """
        #expect(KimiKey.find(in: script) == "sk-kimi-abcdefghijklmnop1234")
        let moonshot = "export ANTHROPIC_BASE_URL=https://api.moonshot.ai/anthropic\nexport ANTHROPIC_API_KEY=sk-abcdefghijklmnopqrst"
        #expect(KimiKey.find(in: moonshot) == nil)
        let commented = "export ANTHROPIC_BASE_URL=https://api.kimi.com/coding/\n# export ANTHROPIC_API_KEY=sk-kimi-abcdefghijklmnop1234"
        #expect(KimiKey.find(in: commented) == nil)
        let indirect = "export ANTHROPIC_BASE_URL=https://api.kimi.com/coding/\nexport ANTHROPIC_API_KEY=\"$KIMI\""
        #expect(KimiKey.find(in: indirect) == nil)
    }

    @Test func envWinsThenFilesInTheHomeFolder() {
        let home = URL(fileURLWithPath: "/nonexistent-home")
        #expect(KimiKey.find(env: ["KIMI_API_KEY": "k-env"], home: home) == "k-env")
        let files = [home.appendingPathComponent(".zshrc").path:
                        "export ANTHROPIC_BASE_URL=https://api.kimi.com/coding/\nexport ANTHROPIC_AUTH_TOKEN=sk-kimi-zzzzzzzzzzzzzzzzzz"]
        #expect(KimiKey.find(env: [:], home: home, read: { files[$0.path] }) == "sk-kimi-zzzzzzzzzzzzzzzzzz")
        #expect(KimiKey.find(env: [:], home: home, read: { _ in nil }) == nil)
    }
}

struct AntigravityAuthTests {
    @Test func parsesTheProxyCredentialAndItsEndpoint() throws {
        let j = #"{"type":"antigravity","access_token":"ya29.x","project_id":"p1","expired":"2026-11-27T00:05:53+08:00","antigravity_capability_hints":{"endpoint":"https://daily-cloudcode-pa.googleapis.com"}}"#
        let a = try #require(AntigravityAuth.parse(Data(j.utf8)))
        #expect(a.endpoint == "https://daily-cloudcode-pa.googleapis.com" && a.projectID == "p1")
        #expect(a.expires == LimitsParse.date("2026-11-26T16:05:53Z"))
        #expect(AntigravityAuth.parse(Data(#"{"type":"antigravity","access_token":"t","disabled":true}"#.utf8)) == nil)
        #expect(AntigravityAuth.parse(Data(#"{"type":"codex","access_token":"t"}"#.utf8)) == nil)
    }

    @Test func authDirFromTheProxyConfig() {
        let home = URL(fileURLWithPath: "/Users/x")
        #expect(AntigravityAuth.authDir(home: home, config: "oauth:\n  auth-dir: \"~/.cli-proxy-api\"").path == "/Users/x/.cli-proxy-api")
        #expect(AntigravityAuth.authDir(home: home, config: "auth-dir: /opt/auth # here").path == "/opt/auth")
        #expect(AntigravityAuth.authDir(home: home, config: nil).path == "/Users/x/.cli-proxy-api")
    }
}

// MARK: Sources over a fake transport

final class FakeHTTP: HTTPTransport, @unchecked Sendable {
    let reply: Box<HTTPResult?>
    let seen = Box<[URLRequest]>([])
    init(_ r: HTTPResult?) { reply = Box(r) }
    func send(_ request: URLRequest) async throws -> HTTPResult {
        seen.mutate { $0.append(request) }
        guard let r = reply.value else { throw URLError(.notConnectedToInternet) }
        return r
    }
}

struct LimitsSourceTests {
    let now = LimitsParse.date("2026-11-26T15:30:00Z")!
    let creds = #"{"claudeAiOauth":{"accessToken":"tok","expiresAt":1895720856769}}"#

    @Test func claudeSendsTheOAuthTokenAndParses() async {
        let http = FakeHTTP(HTTPResult(status: 200, body: LimitFixtures.d(LimitFixtures.claude)))
        let c = creds
        let r = await ClaudeLimitsSource(http: http, credentials: { c }).fetch(now: now)
        guard case .ok(let p) = r else { Issue.record("not ok: \(r)"); return }
        #expect(p.id == "claude")
        let req = http.seen.value[0]
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(req.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
    }

    @Test func claudeMissingLoginIsAbsentAndExpiredSkipsTheCall() async {
        let http = FakeHTTP(HTTPResult(status: 200, body: Data()))
        #expect(await ClaudeLimitsSource(http: http, credentials: { nil }).fetch(now: now) == .absent)
        let old = #"{"claudeAiOauth":{"accessToken":"tok","expiresAt":1000}}"#
        #expect(await ClaudeLimitsSource(http: http, credentials: { old }).fetch(now: now) == .failed)
        #expect(http.seen.value.isEmpty)
    }

    @Test func rateLimitBacksOffForWhatTheServerSays() async {
        let http = FakeHTTP(HTTPResult(status: 429, body: Data(), headers: ["retry-after": "3058"]))
        let c = creds
        #expect(await ClaudeLimitsSource(http: http, credentials: { c }).fetch(now: now) == .backoff(3058))
        #expect(await KimiLimitsSource(http: http, key: { "k" }).fetch(now: now) == .backoff(3058))
    }

    @Test func kimiNoKeyOrDeadKeyIsAbsentNetworkFailureIsNot() async {
        #expect(await KimiLimitsSource(http: FakeHTTP(nil), key: { nil }).fetch(now: now) == .absent)
        #expect(await KimiLimitsSource(http: FakeHTTP(HTTPResult(status: 401, body: Data())), key: { "k" }).fetch(now: now) == .absent)
        #expect(await KimiLimitsSource(http: FakeHTTP(nil), key: { "k" }).fetch(now: now) == .failed)
        let ok = await KimiLimitsSource(http: FakeHTTP(HTTPResult(status: 200, body: LimitFixtures.d(LimitFixtures.kimi))), key: { "k" }).fetch(now: now)
        guard case .ok(let p) = ok else { Issue.record("not ok"); return }
        #expect(p.windows.count == 2)
    }

    @Test func geminiPostsToTheProxyEndpointAndAddsLimitedModels() async {
        let http = FakeHTTP(HTTPResult(status: 200, body: LimitFixtures.d(LimitFixtures.gemini)))
        let auth = AntigravityAuth(accessToken: "ya", projectID: "p1", endpoint: "https://daily.example", expires: now.addingTimeInterval(600))
        let log = "[2026-11-26 23:28:00] [b] [warn ] 429 model=gemini-4-neon-xhigh RESOURCE_EXHAUSTED"
        let src = GeminiLimitsSource(http: http, auth: { auth }, proxyLog: { log })
        let r = await src.fetch(now: now)
        guard case .ok(let p) = r else { Issue.record("not ok: \(r)"); return }
        let req = http.seen.value[0]
        #expect(req.url?.absoluteString == "https://daily.example/v1internal:fetchAvailableModels" && req.httpMethod == "POST")
        #expect(String(decoding: req.httpBody ?? Data(), as: UTF8.self) == #"{"project":"p1"}"#)
        // The log times are local; only assert the flag when this Mac runs on SGT.
        if TimeZone.current.secondsFromGMT() == 8 * 3600 { #expect(p.limitedNow) }
    }

    @Test func geminiWithoutLoginIsAbsentAndAnExpiredTokenKeepsTheLastNumbers() async {
        let http = FakeHTTP(HTTPResult(status: 200, body: Data()))
        #expect(await GeminiLimitsSource(http: http, auth: { nil }).fetch(now: now) == .absent)
        let stale = AntigravityAuth(accessToken: "ya", projectID: nil, endpoint: "https://x", expires: now.addingTimeInterval(-1))
        #expect(await GeminiLimitsSource(http: http, auth: { stale }).fetch(now: now) == .failed)
        #expect(http.seen.value.isEmpty)
    }
}

// MARK: Store

final class ScriptedSource: LimitsSource, @unchecked Sendable {
    let id: String
    let interval: TimeInterval
    let replies: Box<[LimitsFetch]>
    let calls = Box(0)
    init(_ id: String, interval: TimeInterval = 300, _ replies: [LimitsFetch]) { self.id = id; self.interval = interval; self.replies = Box(replies) }
    func fetch(now: Date) async -> LimitsFetch {
        calls.mutate { $0 += 1 }
        var r = LimitsFetch.failed
        replies.mutate { if !$0.isEmpty { r = $0.removeFirst() } }
        return r
    }
}

@MainActor
struct LimitsStoreTests {
    let t0 = LimitsParse.date("2026-11-26T15:30:00Z")!
    func prov(_ id: String, _ used: Double, at: Date) -> ProviderLimits {
        ProviderLimits(id: id, name: id, windows: [LimitWindow(label: "week", used: used, resetsAt: at.addingTimeInterval(86_400))], asOf: at)
    }

    @Test func showsOnlyProvidersThatAnswerInSourceOrder() async {
        let gem = ScriptedSource("gemini", [.ok(prov("gemini", 0.2, at: t0))])
        let kimi = ScriptedSource("kimi", [.absent])
        let claude = ScriptedSource("claude", [.ok(prov("claude", 0.05, at: t0))])
        let s = LimitsStore(sources: [claude, kimi, gem])
        await s.tick(now: t0)
        #expect(s.providers.map(\.id) == ["claude", "gemini"])
    }

    @Test func waitsForTheIntervalAndAFailureKeepsTheLastNumbers() async {
        let c = ScriptedSource("claude", interval: 600, [.ok(prov("claude", 0.05, at: t0)), .failed])
        let s = LimitsStore(sources: [c])
        await s.tick(now: t0)
        await s.tick(now: t0.addingTimeInterval(300))
        #expect(c.calls.value == 1)
        await s.tick(now: t0.addingTimeInterval(601))
        #expect(c.calls.value == 2)
        #expect(s.providers.first?.windows.first?.used == 0.05)
    }

    @Test func aBackoffHoldsEvenWhenThePanelForcesARefresh() async {
        let c = ScriptedSource("claude", interval: 600, [.backoff(3000), .ok(prov("claude", 0.1, at: t0))])
        let s = LimitsStore(sources: [c])
        await s.tick(now: t0)
        await s.tick(now: t0.addingTimeInterval(100), force: true)
        #expect(c.calls.value == 1)
        await s.tick(now: t0.addingTimeInterval(3001))
        #expect(c.calls.value == 2 && s.providers.count == 1)
        // Without a back-off, opening the panel asks again early, but not twice within two minutes.
        await s.tick(now: t0.addingTimeInterval(3060), force: true)
        #expect(c.calls.value == 2)
        await s.tick(now: t0.addingTimeInterval(3130), force: true)
        #expect(c.calls.value == 3)
    }

    @Test func aProviderThatGoesAwayDisappears() async {
        let k = ScriptedSource("kimi", interval: 60, [.ok(prov("kimi", 0.3, at: t0)), .absent])
        let s = LimitsStore(sources: [k])
        await s.tick(now: t0)
        #expect(s.providers.count == 1)
        await s.tick(now: t0.addingTimeInterval(61))
        #expect(s.providers.isEmpty)
    }

    @Test func cacheSurvivesARestartButNotADay() async throws {
        let url = tempDir().appendingPathComponent("limits.json")
        let now = Date()
        let s = LimitsStore(sources: [ScriptedSource("claude", [.ok(prov("claude", 0.4, at: now))])], cacheURL: url)
        await s.tick(now: now)
        let again = LimitsStore(sources: [ScriptedSource("claude", [])], cacheURL: url)
        #expect(again.providers.first?.windows.first?.used == 0.4)
        let other = LimitsStore(sources: [ScriptedSource("kimi", [])], cacheURL: url)
        #expect(other.providers.isEmpty)                    // a provider with no source is not shown
        let old = LimitsStore(sources: [ScriptedSource("claude", [.ok(prov("claude", 0.4, at: now.addingTimeInterval(-90_000)))])], cacheURL: url)
        await old.tick(now: now)
        #expect(old.providers.isEmpty)
    }

    @Test func aPassedResetReadsAsEmptyAndLevels() {
        let w = LimitWindow(label: "5h", used: 0.95, resetsAt: t0)
        #expect(LimitsStore.current(w, now: t0.addingTimeInterval(1)).used == 0)
        #expect(LimitsStore.current(w, now: t0.addingTimeInterval(-1)).used == 0.95)
        #expect(LimitsStore.level(0.5) == .ok && LimitsStore.level(0.75) == .warn && LimitsStore.level(0.9) == .high)
    }

    @Test func expandedIsRemembered() {
        let saved = Box<[Bool]>([])
        let s = LimitsStore(sources: [], expanded: false, saveExpanded: { v in saved.mutate { $0.append(v) } })
        s.expanded = true
        #expect(saved.value == [true])
    }
}
