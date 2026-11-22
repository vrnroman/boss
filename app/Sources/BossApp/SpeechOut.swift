import AVFoundation
import AppKit
import BossCore

/// Kokoro sidecar first (English; Russian only if `kokoroRussian`), else AVSpeechSynthesizer
/// (Milena for Russian, the best installed en-US voice for English).
@MainActor
final class SpeechOut: NSObject, Speaker, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    private let settings: BossSettings
    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var continuation: CheckedContinuation<Void, Never>?
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

    func speak(_ text: String, lang: String?) async {
        let ru = lang == "ru"
        if (!ru || settings.kokoroRussian), Date() > kokoroDownUntil, let wav = await kokoro(text, lang: lang ?? "en") {
            if await play(wav) { return }
        }
        await system(text, ru: ru)
    }

    func stop() {
        player?.stop()
        synth.stopSpeaking(at: .immediate)
        finish()
    }

    private func finish() {
        let c = continuation
        continuation = nil
        c?.resume()
    }

    private func kokoro(_ text: String, lang: String) async -> Data? {
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

    private func play(_ data: Data) async -> Bool {
        guard let p = try? AVAudioPlayer(data: data) else { return false }
        player = p
        p.delegate = self
        guard p.play() else { return false }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in continuation = c }
        return true
    }

    private func system(_ text: String, ru: Bool) async {
        let u = AVSpeechUtterance(string: SpeechItem.speakable(text))
        u.voice = ru ? Self.russianVoice() : Self.englishVoice(preferred: settings.voice)
        u.rate = AVSpeechUtteranceDefaultSpeechRate * (ru ? 1.0 : 1.02)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            continuation = c
            synth.speak(u)
        }
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
        Task { @MainActor in self.finish() }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finish() }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ p: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.finish() }
    }
}
