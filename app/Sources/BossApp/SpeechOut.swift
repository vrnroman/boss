import AVFoundation
import AppKit
import BossCore

/// Kokoro sidecar first (English; Russian only if `kokoroRussian`), else AVSpeechSynthesizer
/// (Milena for Russian, the best installed en-US voice for English).
@MainActor
final class SpeechOut: NSObject, Speaker, VoiceBackend, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    private let settings: BossSettings
    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var playerDone: (@MainActor () -> Void)?
    private var sayDone: (@MainActor () -> Void)?
    private var utterance: AVSpeechUtterance?
    private lazy var guarded = GuardedSpeaker(backend: self)
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        return URLSession(configuration: c)
    }()
    private var kokoroDownUntil = Date.distantPast

    init(settings: BossSettings) {
        self.settings = settings
        super.init()
        synth.delegate = self
    }

    // Speaker: everything goes through the guard, which stops at any stage.
    func speak(_ text: String, lang: String?) async { await guarded.speak(text, lang: lang) }
    func stop() { guarded.stop() }

    // VoiceBackend
    var useKokoro: (String?) -> Bool {
        { [unowned self] lang in (lang != "ru" || self.settings.kokoroRussian) && Date() > self.kokoroDownUntil }
    }

    func synthesize(_ text: String, lang: String) async -> Data? {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(Ports.tts)/speak")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "lang": lang])
        do {
            let (data, resp) = try await session.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200, data.count > 44 else { return nil }
            return data
        } catch {
            kokoroDownUntil = Date().addingTimeInterval(30)   // don't wait on a dead sidecar every time
            return nil
        }
    }

    func play(_ data: Data, done: @escaping @MainActor () -> Void) -> Bool {
        player?.stop()
        guard let p = try? AVAudioPlayer(data: data) else { return false }
        player = p
        p.delegate = self
        playerDone = done
        guard p.play() else { playerDone = nil; return false }
        return true
    }

    func say(_ text: String, ru: Bool, done: @escaping @MainActor () -> Void) {
        let u = AVSpeechUtterance(string: SpeechItem.speakable(text))
        u.voice = ru ? Self.russianVoice() : Self.englishVoice(preferred: settings.voice)
        u.rate = AVSpeechUtteranceDefaultSpeechRate * (ru ? 1.0 : 1.02)
        sayDone = done
        utterance = u
        synth.speak(u)
    }

    func halt() {
        player?.stop()
        player = nil
        playerDone = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        sayDone = nil
        utterance = nil
    }

    static func russianVoice() -> AVSpeechSynthesisVoice? {
        let ru = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("ru") }
        return ru.first { $0.name.hasPrefix("Milena") && $0.quality != .default } ?? ru.first { $0.name.hasPrefix("Milena") }
            ?? ru.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: "ru-RU")
    }

    static func englishVoice(preferred: String) -> AVSpeechSynthesisVoice? {
        let en = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-US" }
        if !preferred.isEmpty, let v = en.first(where: { $0.name == preferred }) { return v }
        let females = ["Ava", "Zoe", "Samantha", "Allison", "Susan", "Nicky", "Evan"]
        let ranked = en.sorted { a, b in
            if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
            let ia = females.firstIndex { a.name.hasPrefix($0) } ?? 99, ib = females.firstIndex { b.name.hasPrefix($0) } ?? 99
            return ia < ib
        }
        return ranked.first { $0.gender == .female } ?? ranked.first ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in guard u === self.utterance else { return }; self.utterance = nil; let d = self.sayDone; self.sayDone = nil; d?() }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in guard u === self.utterance else { return }; self.utterance = nil; let d = self.sayDone; self.sayDone = nil; d?() }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in guard p === self.player else { return }; let d = self.playerDone; self.playerDone = nil; d?() }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ p: AVAudioPlayer, error: Error?) {
        Task { @MainActor in guard p === self.player else { return }; let d = self.playerDone; self.playerDone = nil; d?() }
    }
}
