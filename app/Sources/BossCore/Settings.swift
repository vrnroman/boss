import Foundation

/// User settings in UserDefaults (inject a suite in tests).
public final class BossSettings: @unchecked Sendable {
    public let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "radioSounds": true, "livePreview": true, "humor": 1, "languageLock": "auto",
            "voice": "", "muted": false, "kokoroRussian": false, "telegramFallback": true,
            "debugControl": false, "userWords": [String](),
        ])
    }
    public var radioSounds: Bool { get { defaults.bool(forKey: "radioSounds") } set { defaults.set(newValue, forKey: "radioSounds") } }
    public var livePreview: Bool { get { defaults.bool(forKey: "livePreview") } set { defaults.set(newValue, forKey: "livePreview") } }
    /// 0 (dry, none) … 3. Default 1.
    public var humor: Int {
        get { min(3, max(0, defaults.integer(forKey: "humor"))) }
        set { defaults.set(min(3, max(0, newValue)), forKey: "humor") }
    }
    /// "auto" | "en" | "ru"
    public var languageLock: String {
        get { let v = defaults.string(forKey: "languageLock") ?? "auto"; return ["auto", "en", "ru"].contains(v) ? v : "auto" }
        set { defaults.set(["auto", "en", "ru"].contains(newValue) ? newValue : "auto", forKey: "languageLock") }
    }
    /// Whisper `language` parameter: nil = auto.
    public var whisperLanguage: String? { languageLock == "auto" ? nil : languageLock }
    /// Preferred English system voice name ("" = best installed).
    public var voice: String { get { defaults.string(forKey: "voice") ?? "" } set { defaults.set(newValue, forKey: "voice") } }
    public var muted: Bool { get { defaults.bool(forKey: "muted") } set { defaults.set(newValue, forKey: "muted") } }
    /// Use Kokoro for Russian too (default: Russian always uses the system voice Milena).
    public var kokoroRussian: Bool { get { defaults.bool(forKey: "kokoroRussian") } set { defaults.set(newValue, forKey: "kokoroRussian") } }
    public var telegramFallback: Bool { get { defaults.bool(forKey: "telegramFallback") } set { defaults.set(newValue, forKey: "telegramFallback") } }
    public var debugControl: Bool { get { defaults.bool(forKey: "debugControl") } set { defaults.set(newValue, forKey: "debugControl") } }
    /// Extra vocabulary for whisper's prompt.
    public var userWords: [String] { get { defaults.stringArray(forKey: "userWords") ?? [] } set { defaults.set(newValue, forKey: "userWords") } }
}
