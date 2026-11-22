import AppKit
import BossCore

@MainActor
final class Sounds: SoundPlaying {
    private var cache: [SoundCue: NSSound] = [:]
    func play(_ cue: SoundCue) {
        if cache[cue] == nil, let url = Bundle.main.resourceURL?.appendingPathComponent("sounds/\(cue.fileName)"),
           let s = NSSound(contentsOf: url, byReference: true) {
            s.volume = 0.55
            cache[cue] = s
        }
        guard let s = cache[cue] else { return }
        s.stop()
        s.play()
    }
}
