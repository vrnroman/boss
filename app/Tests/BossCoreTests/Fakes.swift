import Foundation
@testable import BossCore

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { get { lock.lock(); defer { lock.unlock() }; return v } set { lock.lock(); v = newValue; lock.unlock() } }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&v); lock.unlock() }
}

func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("bosstest-" + UUID().uuidString)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

final class FakeChannel: ChannelAPI, @unchecked Sendable {
    struct Call: Equatable { var path: String; var body: [String: String] }
    let calls = Box<[Call]>([])
    let sessionsSent = Box<[[String]]>([])
    let result = Box<PostResult>(.accepted(duplicate: false))
    let state = Box<ChannelState?>(nil)
    func record(_ p: String, _ b: [String: String]) -> PostResult { calls.mutate { $0.append(Call(path: p, body: b)) }; return result.value }
    func postUtterance(id: String, text: String, mode: String, lang: String?, sessions: [SessionInfo]) async -> PostResult {
        sessionsSent.mutate { $0.append(sessions.map(\.name)) }
        return record("/utterance", ["id": id, "text": text, "mode": mode, "lang": lang ?? ""])
    }
    func postAnswer(questionID: String, text: String) async -> PostResult { record("/answer", ["question_id": questionID, "text": text]) }
    func postUndo(utteranceID: String) async -> PostResult { record("/undo", ["utterance_id": utteranceID]) }
    func cancelRoute(routeID: String) async -> PostResult { record("/cancel_route", ["route_id": routeID]) }
    func getState() async -> ChannelState? { state.value }
    func health() async -> Bool? { true }
    var paths: [String] { calls.value.map(\.path) }
}

final class FakeTranscriber: Transcriber, @unchecked Sendable {
    let text = Box<String>("payments: run the tests")
    let lang = Box<String?>("en")
    let fail = Box<Bool>(false)
    let calls = Box<Int>(0)
    let prompts = Box<[String]>([])
    /// Called inside transcribe, so tests can check what exists on disk at that moment.
    var onCall: (@Sendable () -> Void)?
    func transcribe(wav: Data, prompt: String, language: String?) async throws -> Transcript {
        calls.mutate { $0 += 1 }
        prompts.mutate { $0.append(prompt) }
        onCall?()
        if fail.value { throw TranscriberError.http(500, "down") }
        return Transcript(text: text.value, lang: lang.value)
    }
}

@MainActor final class FakeSpeaker: Speaker {
    var spoken: [String] = []
    var stopped = 0
    func speak(_ text: String, lang: String?) async { spoken.append(text) }
    func stop() { stopped += 1 }
}

@MainActor final class FakeSounds: SoundPlaying {
    var played: [SoundCue] = []
    func play(_ cue: SoundCue) { played.append(cue) }
}

@MainActor final class FakeRecorder: Recorder {
    var permission = "granted"
    var samples: [Int16] = (0..<16000).map { Int16(8000 * sin(Double($0) * 0.06)) }
    var starts = 0, stops = 0, cancels = 0
    var available = true
    var level: Double = 0
    func start() -> Bool { guard available else { return false }; starts += 1; return true }
    func stop() -> [Int16] { stops += 1; return samples }
    func cancel() { cancels += 1 }
}

@MainActor
struct Rig {
    let channel = FakeChannel()
    let transcriber = FakeTranscriber()
    let speaker = FakeSpeaker()
    let sounds = FakeSounds()
    let recorder = FakeRecorder()
    let outbox: Outbox
    let settings: BossSettings
    let engine: BossEngine
    let sleeps = Box<[Double]>([])

    init(sessions: [SessionInfo] = [SessionInfo(pid: 1, cwd: "/x/payments", name: "payments", status: "busy"),
                                    SessionInfo(pid: 2, cwd: "/x/gateway", name: "gateway", status: "idle")],
         telegram: TelegramFallback? = nil, sleep: ((Double) async -> Void)? = nil) {
        outbox = Outbox(dir: tempDir())
        let suite = "bosstest-" + UUID().uuidString
        settings = BossSettings(defaults: UserDefaults(suiteName: suite)!)
        let sl = sleeps
        let deps = BossDependencies(channel: channel, transcriber: transcriber, outbox: outbox,
                                    loadSessions: { sessions }, speaker: speaker, sounds: sounds, recorder: recorder,
                                    settings: settings, telegram: telegram,
                                    sleep: sleep ?? { d in sl.mutate { $0.append(d) }; await Task.yield() })
        engine = BossEngine(deps: deps)
        engine.refreshSessions()
    }
}

/// Wait until `cond` holds (for detached Tasks the engine spawns).
@MainActor func eventually(_ timeout: Double = 2, _ cond: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if cond() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return cond()
}
