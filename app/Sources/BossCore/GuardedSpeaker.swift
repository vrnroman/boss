import Foundation

/// The raw voice outputs: the local Kokoro voice (synthesize, then play) and the macOS voice.
@MainActor public protocol VoiceBackend: AnyObject {
    /// Kokoro audio for `text`, or nil when the sidecar is unavailable. Takes a moment.
    func synthesize(_ text: String, lang: String) async -> Data?
    /// Starts playing; calls `done` once when it ends or fails. False if it could not start.
    func play(_ data: Data, done: @escaping @MainActor () -> Void) -> Bool
    /// Starts the macOS voice; calls `done` once when it ends or is cancelled.
    func say(_ text: String, ru: Bool, done: @escaping @MainActor () -> Void)
    /// Silences everything now.
    func halt()
    var useKokoro: (String?) -> Bool { get }
}

/// A speaker that is silent the instant `stop()` is called, whatever stage it was in: a line still
/// being synthesized when Roman starts talking is never played (it used to start over his voice a
/// second later), a late "finished" from an old line never ends the new one, and two lines never
/// overlap.
@MainActor public final class GuardedSpeaker: Speaker {
    let backend: VoiceBackend
    private var generation = 0
    private var finish: (() -> Void)?

    public init(backend: VoiceBackend) { self.backend = backend }

    public func speak(_ text: String, lang: String?) async {
        stop()                                  // never two at once
        let gen = generation
        if backend.useKokoro(lang), let wav = await backend.synthesize(text, lang: lang ?? "en") {
            guard gen == generation else { return }          // stopped while synthesizing: say nothing
            if await run(gen, { done in self.backend.play(wav, done: done) }) { return }
            guard gen == generation else { return }
        }
        guard gen == generation else { return }
        _ = await run(gen) { done in self.backend.say(text, ru: lang == "ru", done: done); return true }
    }

    public func stop() {
        generation += 1
        backend.halt()
        let f = finish
        finish = nil
        f?()
    }

    /// Starts one output and waits for its end, its stop, or a newer line; a callback from an older
    /// line is ignored.
    private func run(_ gen: Int, _ start: (@escaping @MainActor () -> Void) -> Bool) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            var resumed = false
            let end: (Bool) -> Void = { ok in if !resumed { resumed = true; c.resume(returning: ok) } }
            finish = { end(true) }
            let started = start { [weak self] in
                guard let self, gen == self.generation else { return }
                self.finish = nil
                end(true)
            }
            if !started { finish = nil; end(false) }
        }
    }
}
