import Foundation
import Observation

public enum SoundCue: String, Sendable, CaseIterable {
    case start, stop, sent, report, question, error
    /// File in Resources/sounds/.
    public var fileName: String {
        switch self {
        case .start: return "radio_open.wav"
        case .stop: return "radio_close.wav"
        case .sent: return "sent.wav"
        case .report: return "report.wav"
        case .question: return "question.wav"
        case .error: return "error.wav"
        }
    }
}

@MainActor public protocol SoundPlaying: AnyObject { func play(_ cue: SoundCue) }

@MainActor public protocol Speaker: AnyObject {
    /// Speak and return when finished (or failed).
    func speak(_ text: String, lang: String?) async
    func stop()
}

/// Microphone side (real: AVAudioEngine with pre-roll; tests: canned samples).
@MainActor public protocol Recorder: AnyObject {
    /// "granted" | "denied" | "undetermined"
    var permission: String { get }
    /// Begin a recording that includes the pre-roll. Returns false if the mic is unavailable.
    func start() -> Bool
    /// End the recording; returns 16 kHz mono samples.
    func stop() -> [Int16]
    func cancel()
    /// Current input level 0…1 (meter scale).
    var level: Double { get }
}

public enum AppStatus: String, Sendable { case idle, listening, speaking, waiting, offline }

public enum TalkSource: String, Sendable { case hotkey, button, debug, answerWindow }

/// Everything the engine needs from the outside world.
public struct BossDependencies {
    public var channel: ChannelAPI
    public var transcriber: Transcriber
    public var outbox: Outbox
    public var loadSessions: () -> [SessionInfo]
    public var ttyLookup: (Int32) -> String?
    public var clock: () -> Date
    public var speaker: Speaker
    public var sounds: SoundPlaying
    public var recorder: Recorder
    public var settings: BossSettings
    public var telegram: TelegramFallback?
    public var showSession: (_ name: String, _ tty: String?) -> Void
    public var openURL: (String) -> Void
    public var restartBoss: () -> Void
    public var gate: AudioGate
    /// Sleep used for the answer-window timer (tests make it instant / controlled).
    public var sleep: (Double) async -> Void

    public init(channel: ChannelAPI, transcriber: Transcriber, outbox: Outbox,
                loadSessions: @escaping () -> [SessionInfo], ttyLookup: @escaping (Int32) -> String? = { _ in nil },
                clock: @escaping () -> Date = Date.init, speaker: Speaker, sounds: SoundPlaying, recorder: Recorder,
                settings: BossSettings, telegram: TelegramFallback? = nil,
                showSession: @escaping (String, String?) -> Void = { _, _ in }, openURL: @escaping (String) -> Void = { _ in },
                restartBoss: @escaping () -> Void = {}, gate: AudioGate = AudioGate(),
                sleep: @escaping (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1e9)) }) {
        self.channel = channel; self.transcriber = transcriber; self.outbox = outbox; self.loadSessions = loadSessions
        self.ttyLookup = ttyLookup; self.clock = clock; self.speaker = speaker; self.sounds = sounds; self.recorder = recorder
        self.settings = settings; self.telegram = telegram; self.showSession = showSession; self.openURL = openURL
        self.restartBoss = restartBoss; self.gate = gate; self.sleep = sleep
    }
}

/// The app's brain: recording → outbox → transcription → channel, the feed, the speech queue,
/// the answer window, the timing tower. UI-free; the app target only wires real IO into it.
@MainActor
@Observable
public final class BossEngine {
    public let deps: BossDependencies

    // Observed state
    public private(set) var feed = FeedModel()
    public private(set) var tower: [TowerRow] = []
    public private(set) var sessions: [SessionInfo] = []
    public private(set) var channelState: ChannelState?
    public private(set) var channelReachable = false
    public private(set) var bossConnected = false
    public private(set) var recording: Recording?
    public private(set) var speaking = false
    public private(set) var previewTarget: String?
    public private(set) var answerWindow: AnswerWindow?
    /// Debug control only: keep a 6 s answer window even without mic permission (see openAnswerWindow).
    public var allowSilentAnswerWindow = false
    public var hotkeyActive = false
    public var panelExpanded = false
    public var panelVisible = true
    public private(set) var speech = SpeechQueue()
    public var level: Double = 0

    public struct Recording: Equatable, Sendable {
        public var startedAt: Date
        public var source: TalkSource
        /// Non-nil when this recording answers a question.
        public var questionID: String?
    }
    public struct AnswerWindow: Equatable, Sendable {
        public var questionID: String
        public var deadline: Date
    }

    // Internals
    private var questionSeen: [String: Date] = [:]
    private var inFlight = Set<String>()
    private var retry = RetryPolicy()
    private var answerTimerToken = 0
    private var lastVoiceAt: Date?
    public private(set) var processed: [String] = []   // utterance ids processed (debug)

    public static let answerWindowSeconds: Double = 6

    public init(deps: BossDependencies) {
        self.deps = deps
        speech.muted = deps.settings.muted
    }

    // MARK: - Derived

    public var status: AppStatus {
        if recording != nil { return .listening }
        if speaking { return .speaking }
        if !channelReachable || !bossConnected { return .offline }
        if feed.newestOpenQuestion != nil || tower.contains(where: { $0.group == .waiting }) { return .waiting }
        return .idle
    }
    public var muted: Bool { speech.muted }
    /// "2 working · 1 waiting on you", plus questions Boss itself is asking.
    public var countsText: String {
        let towerQ = Set(tower.compactMap(\.questionID))
        let own = feed.cards.filter { $0.kind == .question && $0.answered != true && !towerQ.contains($0.questionID ?? "") }.count
        let base = Tower.counts(tower)
        guard own > 0 else { return base }
        return base + " · " + (own == 1 ? "1 question" : "\(own) questions")
    }
    public var lastRouteText: String? { feed.lastRoute }
    public var blindText: String? {
        guard let t = channelState?.blindTotals, t.total > 0 else { return nil }
        return "routed blind \(t.blind)/\(t.total)"
    }
    public var recordingElapsed: TimeInterval {
        recording.map { deps.clock().timeIntervalSince($0.startedAt) } ?? 0
    }

    // MARK: - Talk (hotkey, button, debug all land here)

    /// Applies detector output. Returns the send task when a talk ended (tests await it).
    @discardableResult
    public func handleGesture(_ events: [GestureEvent]) -> Task<String?, Never>? {
        var task: Task<String?, Never>?
        for e in events {
            switch e {
            case .talkStart: beginTalk(source: .hotkey)
            case .talkEnd:
                let finished = finishRecording()   // stop the mic right at release
                task = Task { await self.send(finished) }
            case .cancel: cancelTalk()
            case .armed, .tap, .doubleTap: break   // doubleTap reserved for M3 hands-free
            }
        }
        return task
    }

    @discardableResult
    public func beginTalk(source: TalkSource) -> Bool {
        if let r = recording {
            // A manual press during the auto answer window takes it over (push-to-talk until release).
            if r.source == .answerWindow && source != .answerWindow {
                recording?.source = source
                answerTimerToken += 1
                return true
            }
            return false
        }
        guard deps.recorder.start() else {
            feed.addSystem(micProblemText(), level: "error", action: "grantMicrophone", at: deps.clock(), key: "mic")
            deps.sounds.play(.error)
            return false
        }
        let qid = answerWindow?.questionID
        recording = Recording(startedAt: deps.clock(), source: source, questionID: qid)
        lastVoiceAt = nil
        previewTarget = nil
        speech.paused = true
        if deps.settings.radioSounds && source != .answerWindow { deps.sounds.play(.start) }
        return true
    }

    func micProblemText() -> String {
        deps.recorder.permission == "denied"
            ? "Microphone access is off. Allow Boss in System Settings › Privacy & Security › Microphone."
            : "Microphone unavailable. Boss could not start recording."
    }

    /// Ends the recording and sends it. Returns the utterance id if something was queued.
    @discardableResult
    public func endTalk() async -> String? {
        await send(finishRecording())
    }

    /// Stops the mic synchronously and returns what was captured.
    func finishRecording() -> (Recording, [Int16])? {
        guard let r = recording else { return nil }
        let samples = deps.recorder.stop()
        recording = nil
        answerTimerToken += 1
        if r.questionID != nil { answerWindow = nil }
        previewTarget = nil
        if deps.settings.radioSounds && r.source != .answerWindow { deps.sounds.play(.stop) }
        speech.paused = false
        pumpSpeech()
        return (r, samples)
    }

    func send(_ finished: (Recording, [Int16])?) async -> String? {
        guard let (r, samples) = finished else { return nil }
        let verdict = deps.gate.evaluate(samples: samples)
        guard verdict == .ok else {
            if r.source != .answerWindow {
                feed.addSystem(verdict == .tooShort ? "Too short, nothing sent." : "Didn't hear anything, nothing sent.",
                               level: "info", at: deps.clock(), key: "gate")
            }
            return nil
        }
        let id = OutboxID.make(now: deps.clock())
        await process(id: id, wav: WAV.encode(samples: samples), mode: r.questionID != nil ? "answer" : "talk", questionID: r.questionID)
        return id
    }

    /// Synchronous wrapper for UI callbacks.
    public func endTalkDetached() { Task { await endTalk() } }

    public func cancelTalk() {
        guard let r = recording else { return }
        deps.recorder.cancel()
        recording = nil
        answerTimerToken += 1
        if r.questionID != nil { answerWindow = nil }
        previewTarget = nil
        if deps.settings.radioSounds { deps.sounds.play(.stop) }
        speech.paused = false
        pumpSpeech()
    }

    /// Partial transcript from the on-device recognizer while recording.
    public func updatePartialTranscript(_ text: String) {
        guard recording != nil, deps.settings.livePreview else { return }
        previewTarget = TargetPreview.match(transcript: text, sessions: sessions.map(\.name))
    }

    /// Fed by the app's level meter timer.
    public func updateLevel(_ l: Double) {
        level = l
        if recording != nil && l > 0.35 { lastVoiceAt = deps.clock() }
    }

    // MARK: - Pipeline: outbox → transcribe → channel

    /// The single path every recording (real, injected, retried) goes through.
    @discardableResult
    public func process(id: String, wav: Data, mode: String, questionID: String?) async -> OutboxItem? {
        do {
            try deps.outbox.save(id: id, wav: wav, mode: mode, questionID: questionID)
        } catch {
            feed.addSystem("Could not save the recording: \(error)", level: "error", at: deps.clock())
            deps.sounds.play(.error)
            return nil
        }
        processed.append(id)
        feed.addRecording(utteranceID: id, mode: mode, answersQuestionID: questionID, at: deps.clock())
        return await advance(id)
    }

    /// Moves one outbox item forward as far as it can go (transcribe if needed, then send).
    @discardableResult
    func advance(_ id: String) async -> OutboxItem? {
        guard !inFlight.contains(id) else { return deps.outbox.read(id) }
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        guard var item = deps.outbox.read(id), item.isRetryable else { return deps.outbox.read(id) }
        refreshSessions()   // fresh names for the whisper prompt and the /utterance `sessions` list

        if item.text == nil {
            guard let wav = deps.outbox.wav(id) else {
                item = (try? deps.outbox.update(id) { $0.state = .failed; $0.final = true; $0.error = "audio missing" }) ?? item
                feed.setStatus(utteranceID: id, "failed", note: "audio missing")
                return item
            }
            let prompt = VocabularyPrompt.build(sessionNames: sessions.map(\.name), words: deps.settings.userWords)
            do {
                let t = try await deps.transcriber.transcribe(wav: wav, prompt: prompt, language: deps.settings.whisperLanguage)
                guard let clean = HallucinationFilter.clean(t.text) else {
                    item = (try? deps.outbox.update(id) { $0.state = .failed; $0.final = true; $0.error = "filtered"; $0.text = t.text }) ?? item
                    feed.setTranscript(utteranceID: id, text: t.text.isEmpty ? "(nothing heard)" : t.text, lang: t.lang)
                    feed.setStatus(utteranceID: id, "dropped", note: "nothing to send")
                    return item
                }
                let lang = deps.settings.whisperLanguage ?? t.lang
                item = (try? deps.outbox.update(id) { $0.state = .transcribed; $0.text = clean; $0.lang = lang; $0.error = nil }) ?? item
                feed.setTranscript(utteranceID: id, text: clean, lang: lang)
            } catch {
                let max = retry.maxTranscribeAttempts
                item = (try? deps.outbox.update(id) {
                    $0.attempts += 1; $0.state = .failed; $0.error = "transcription: \(error)"
                    if $0.attempts >= max { $0.final = true }
                }) ?? item
                feed.setStatus(utteranceID: id, "failed", note: "transcription failed, retrying")
                feed.addSystem("Transcription failed (whisper-server on :\(Ports.whisper)?). Saved; will retry.",
                               level: "warning", at: deps.clock(), key: "whisper")
                return item
            }
        }
        return await deliver(item)
    }

    func deliver(_ item0: OutboxItem) async -> OutboxItem {
        var item = item0
        guard let text = item.text else { return item }
        let result: PostResult
        if let q = item.question_id {
            result = await deps.channel.postAnswer(questionID: q, text: text)
        } else {
            result = await deps.channel.postUtterance(id: item.id, text: text, mode: item.mode == "answer" ? "talk" : item.mode, lang: item.lang, sessions: sessions)
        }
        switch result {
        case .accepted:
            item = (try? deps.outbox.update(item.id) { $0.state = .sent; $0.error = nil }) ?? item
            feed.setStatus(utteranceID: item.id, "sent")
            if let q = item.question_id { feed.markAnswered(questionID: q, answer: text) }
            feed.remove("sys-offline-queue")
            if deps.settings.radioSounds { deps.sounds.play(.sent) }
        case .bossOffline, .failed, .unauthorized:
            let why: String
            switch result {
            case .bossOffline: why = "Boss offline"
            case .unauthorized: why = "token rejected"
            case .failed(let m): why = m
            default: why = ""
            }
            item = (try? deps.outbox.update(item.id) { $0.state = .failed; $0.attempts += 1; $0.error = why }) ?? item
            feed.setStatus(utteranceID: item.id, result == .bossOffline ? "queued" : "failed", note: why)
            if result == .unauthorized {
                feed.addSystem("The channel rejected the token in ~/Boss/token.", level: "error", at: deps.clock(), key: "token")
            }
        }
        return item
    }

    /// Timer tick (call every second): retries every 5 s.
    public func retryTick(now: TimeInterval) async {
        guard retry.shouldRun(at: now) else { return }
        await retryUnsent()
    }

    public func retryUnsent() async {
        for item in deps.outbox.unsent() where !inFlight.contains(item.id) {
            await advance(item.id)
        }
    }

    // MARK: - Channel events

    public func handleSSE(_ m: SSEMessage) {
        guard let e = ChannelEvent.decode(type: m.event, data: m.data) else { return }
        handle(e)
    }

    public func handle(_ e: ChannelEvent) {
        let now = deps.clock()
        if case .boss(let c) = e {
            setBossConnected(c)
            return
        }
        let fresh = feed.apply(e, at: now)
        guard fresh else { return }
        switch e {
        case .say(let s):
            deps.telegram?.handle(e)
            if s.kind == "report" { deps.sounds.playIf(deps.settings.radioSounds, .report) }
            if s.speak {
                speech.enqueue(SpeechItem(id: "say-\(s.id)", text: SpeechItem.format(session: s.session, text: s.text),
                                          lang: s.lang ?? LanguageCode.guess(s.text), priority: .report), at: now)
                pumpSpeech()
            }
            Task { await refreshState() }
        case .ask(let a):
            questionSeen[a.questionID] = a.at ?? now
            deps.telegram?.handle(e)
            deps.sounds.playIf(deps.settings.radioSounds, .question)
            let spoken = SpeechItem.format(session: a.session, text: a.question)
            let queued = speech.enqueue(SpeechItem(id: "ask-\(a.questionID)", text: spoken,
                                                   lang: a.lang ?? LanguageCode.guess(a.question), priority: .question,
                                                   questionID: a.questionID), at: now)
            if queued { pumpSpeech() } else { openAnswerWindow(questionID: a.questionID) } // muted: still listen
            Task { await refreshState() }
        case .routed(let r):
            if r.status == "failed" { deps.sounds.playIf(deps.settings.radioSounds, .error) }
            Task { await refreshState() }
        case .confirm, .boss, .unknown:
            break
        }
    }

    public func setBossConnected(_ c: Bool) {
        let was = bossConnected
        bossConnected = c
        if c { channelReachable = true }
        if c && !was {
            feed.remove("sys-offline")
            if retry.bossReconnected(at: deps.clock().timeIntervalSince1970) { Task { await retryUnsent() } }
        }
    }

    public func setChannelReachable(_ r: Bool, bossConnected b: Bool?) {
        channelReachable = r
        if let b { setBossConnected(b) } else if !r { bossConnected = false }
    }

    /// Health poll result: nil = channel down.
    public func applyHealth(_ h: Bool?) {
        setChannelReachable(h != nil, bossConnected: h)
    }

    public func refreshState() async {
        if let s = await deps.channel.getState() {
            channelState = s
            channelReachable = true
        }
        rebuildTower()
    }

    public func refreshSessions() {
        sessions = deps.loadSessions()
        rebuildTower()
    }

    func rebuildTower() {
        tower = Tower.rows(sessions: sessions, state: channelState, now: deps.clock(), questionSeen: questionSeen)
    }

    // MARK: - Speech

    func pumpSpeech() {
        guard !speaking, let item = speech.startNext() else { return }
        speaking = true
        Task { @MainActor in
            await deps.speaker.speak(item.text, lang: item.lang)
            speech.finishCurrent()
            speaking = false
            if let q = item.questionID, feed.card("q-\(q)")?.answered != true {
                openAnswerWindow(questionID: q)
            }
            pumpSpeech()
        }
    }

    public func setMuted(_ m: Bool) {
        speech.setMuted(m)
        deps.settings.muted = m
        if m && speaking { deps.speaker.stop() }
    }

    public func repeatLast() {
        if speech.repeatLast() { pumpSpeech() }
    }

    // MARK: - Answer window

    /// After a question is spoken: open the mic for 6 s; speech in it answers the question.
    public func openAnswerWindow(questionID: String) {
        guard recording == nil else { return }
        let micOK = deps.recorder.permission == "granted"
        if !micOK {
            // No mic: no window, unless the debug harness asked for a listening-free one
            // (so an injected spoken answer can be tested end to end without a microphone).
            guard allowSilentAnswerWindow else { return }
            answerWindow = AnswerWindow(questionID: questionID, deadline: deps.clock().addingTimeInterval(Self.answerWindowSeconds))
            answerTimerToken += 1
            let token = answerTimerToken
            Task { @MainActor in
                await deps.sleep(Self.answerWindowSeconds)
                if token == answerTimerToken, answerWindow?.questionID == questionID { answerWindow = nil }
            }
            return
        }
        answerWindow = AnswerWindow(questionID: questionID, deadline: deps.clock().addingTimeInterval(Self.answerWindowSeconds))
        guard beginTalk(source: .answerWindow) else { answerWindow = nil; return }
        answerTimerToken += 1
        let token = answerTimerToken
        Task { @MainActor in
            await deps.sleep(Self.answerWindowSeconds)
            // extend while Roman is still talking (up to 15 s total)
            var extra = 0.0
            while token == answerTimerToken, let v = lastVoiceAt, deps.clock().timeIntervalSince(v) < 0.7, extra < 9 {
                await deps.sleep(0.5); extra += 0.5
            }
            guard token == answerTimerToken, recording?.source == .answerWindow else { return }
            await endTalk()
        }
    }

    // MARK: - Card actions

    public func tapChoice(questionID: String, choice: String) async -> PostResult {
        let r = await deps.channel.postAnswer(questionID: questionID, text: choice)
        if r.isAccepted {
            feed.markAnswered(questionID: questionID, answer: choice)
            if recording?.questionID == questionID && recording?.source == .answerWindow { cancelTalk() }
            if answerWindow?.questionID == questionID { answerWindow = nil }
            deps.sounds.playIf(deps.settings.radioSounds, .sent)
        } else {
            feed.addSystem("Could not send the answer (\(r)).", level: "error", at: deps.clock(), key: "answer")
        }
        return r
    }

    /// Undo the newest sent utterance (or a specific one).
    @discardableResult
    public func undo(utteranceID: String? = nil) async -> (String, PostResult)? {
        let card = utteranceID.flatMap { feed.card("you-\($0)") }
            ?? feed.cards.first { $0.kind == .youSaid && ["sent", "delivered", "asking"].contains($0.status ?? "") }
        guard let c = card, let uid = c.utteranceID else { return nil }
        let r = await deps.channel.postUndo(utteranceID: uid)
        if r.isAccepted { feed.setStatus(utteranceID: uid, "undone") }
        else { feed.addSystem("Undo failed (\(r)).", level: "error", at: deps.clock(), key: "undo") }
        return (uid, r)
    }

    /// Resend a You-said card. Unsent items go again with the same id; sent ones as a new utterance.
    public func resend(utteranceID: String) async {
        guard let item = deps.outbox.read(utteranceID) else { return }
        if item.state == .sent {
            guard let wav = deps.outbox.wav(utteranceID) else { return }
            let id = OutboxID.make(now: deps.clock())
            try? deps.outbox.save(id: id, wav: wav, mode: item.mode == "answer" ? "talk" : item.mode)
            _ = try? deps.outbox.update(id) { $0.text = item.text; $0.lang = item.lang; if item.text != nil { $0.state = .transcribed } }
            feed.addRecording(utteranceID: id, mode: item.mode, answersQuestionID: nil, at: deps.clock())
            if let t = item.text { feed.setTranscript(utteranceID: id, text: t, lang: item.lang) }
            await advance(id)
        } else {
            _ = try? deps.outbox.update(utteranceID) { $0.final = nil; if $0.attempts >= 5 { $0.attempts = 0 } }
            await advance(utteranceID)
        }
    }

    public func cancelRoute(routeID: String) async {
        let r = await deps.channel.cancelRoute(routeID: routeID)
        if r.isAccepted { feed.cancelConfirm(routeID: routeID) }
        else { feed.addSystem("Cancel failed (\(r)).", level: "error", at: deps.clock(), key: "cancel") }
    }

    public func showSession(_ name: String) {
        let pid = sessions.first { $0.name == name }?.pid
        deps.showSession(name, pid.flatMap { deps.ttyLookup($0) })
    }

    public func addSystem(_ text: String, level: String = "warning", action: String? = nil, key: String? = nil) {
        feed.addSystem(text, level: level, action: action, at: deps.clock(), key: key)
    }
    public func removeCard(_ id: String) { feed.remove(id) }
}

extension SoundPlaying {
    func playIf(_ on: Bool, _ cue: SoundCue) { if on { play(cue) } }
}

// MARK: - Debug control

extension BossEngine: DebugControlHandler {
    public func debugInject(wavPath: String) async -> HTTPResponse {
        let path = (wavPath as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path) else { return .error(400, "cannot read \(wavPath)") }
        if let dec = WAV.decode(data), dec.sampleRate == 16_000 {
            let v = deps.gate.evaluate(samples: dec.samples, sampleRate: dec.sampleRate)
            if v != .ok { return .json(200, ["ok": false, "dropped": v == .tooShort ? "too_short" : "silent"]) }
        }
        // Inside an open answer window the injection answers the question, like real speech would.
        var qid: String?
        if let w = answerWindow {
            qid = w.questionID
            if recording?.source == .answerWindow { deps.recorder.cancel(); recording = nil; speech.paused = false }
            answerTimerToken += 1
            answerWindow = nil
        }
        let id = OutboxID.make(now: deps.clock())
        let item = await process(id: id, wav: data, mode: qid == nil ? "talk" : "answer", questionID: qid)
        var out: [String: Any] = ["ok": item != nil, "id": id]
        if let item {
            out["state"] = item.state.rawValue
            if let t = item.text { out["text"] = t }
            if let l = item.lang { out["lang"] = l }
            if let e = item.error { out["error"] = e }
        }
        if let qid { out["question_id"] = qid }
        return .json(200, out)
    }

    public func debugFeed() -> HTTPResponse { .encodable(200, ["cards": feed.cards]) }
    public func debugSessions() -> HTTPResponse { .encodable(200, ["sessions": tower]) }
    public func debugSpoken() -> HTTPResponse { .encodable(200, ["spoken": speech.log]) }

    public func debugTalk(down: Bool) async -> HTTPResponse {
        if down {
            let ok = beginTalk(source: .debug)
            return .json(ok ? 200 : 409, ["ok": ok, "recording": recording != nil, "mic_permission": deps.recorder.permission])
        }
        guard recording != nil else { return .json(409, ["ok": false, "error": "not recording"]) }
        let id = await endTalk()
        var out: [String: Any] = ["ok": true]
        if let id { out["id"] = id; if let it = deps.outbox.read(id) { out["state"] = it.state.rawValue; out["text"] = it.text ?? "" } }
        else { out["dropped"] = true }
        return .json(200, out)
    }

    public func debugTap(choice: String) async -> HTTPResponse {
        guard let q = feed.newestOpenQuestion, let qid = q.questionID else { return .error(409, "no open question") }
        var pick = q.choices.first { $0.caseInsensitiveCompare(choice) == .orderedSame }
        if pick == nil, let n = Int(choice), n >= 1, n <= q.choices.count { pick = q.choices[n - 1] }
        if pick == nil && q.choices.isEmpty { pick = choice }
        guard let answer = pick else { return .json(400, ["error": "no such choice", "choices": q.choices]) }
        let r = await tapChoice(questionID: qid, choice: answer)
        return .json(r.isAccepted ? 200 : 502, ["ok": r.isAccepted, "question_id": qid, "answer": answer])
    }

    public func debugUndo() async -> HTTPResponse {
        guard let (uid, r) = await undo() else { return .error(409, "nothing to undo") }
        return .json(r.isAccepted ? 200 : 502, ["ok": r.isAccepted, "utterance_id": uid])
    }

    public func debugStatus() -> HTTPResponse {
        var o: [String: Any] = [
            "ok": true,
            "panel": panelExpanded ? "expanded" : "pill",
            "panel_visible": panelVisible,
            "status": status.rawValue,
            "boss_connected": bossConnected,
            "channel_reachable": channelReachable,
            "hotkey_tap_active": hotkeyActive,
            "mic_permission": deps.recorder.permission,
            "recording": recording != nil,
            "speaking": speaking,
            "muted": muted,
            "outbox_unsent": deps.outbox.unsent().count,
            "sessions": tower.count,
            "cards": feed.cards.count,
        ]
        if let w = answerWindow { o["answer_window"] = ["question_id": w.questionID] }
        if let r = recording { o["recording_source"] = r.source.rawValue }
        return .json(200, o)
    }
}
