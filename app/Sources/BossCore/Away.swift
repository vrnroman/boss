import Foundation

/// "Roman is away" = no keyboard/mouse input for >= threshold seconds.
public struct AwayDetector: Sendable {
    public var threshold: TimeInterval
    public var idleSeconds: @Sendable () -> TimeInterval
    public init(threshold: TimeInterval = 600, idleSeconds: @escaping @Sendable () -> TimeInterval) {
        self.threshold = threshold; self.idleSeconds = idleSeconds
    }
    public var isAway: Bool { idleSeconds() >= threshold }
}

/// When Roman is away, say/ask also go to Telegram as plain text.
public final class TelegramFallback: @unchecked Sendable {
    public typealias Runner = @Sendable (_ text: String) -> Void
    public var away: AwayDetector
    public var enabled = true
    private let runner: Runner
    private let clock: @Sendable () -> Date
    private var sent = Set<String>()
    private let lock = NSLock()
    public private(set) var sentTexts: [String] = []

    public init(away: AwayDetector, clock: @escaping @Sendable () -> Date = { Date() }, runner: @escaping Runner) {
        self.away = away; self.clock = clock; self.runner = runner
    }

    /// The real runner: `sh ~/.claude/tools/telegram-send.sh "<text>"`.
    /// Telegram is for the real install only. A test, demo or sandbox instance (debug control on,
    /// BOSS_NO_TELEGRAM, or a BOSS_HOME other than ~/Boss) must never message the owner's phone:
    /// a run of test apps while the screen was locked once sent dozens of test reports.
    public static func allowed(env: [String: String], defaultHome: String) -> Bool {
        if env["BOSS_NO_TELEGRAM"] == "1" || env["BOSS_DEBUG_CONTROL"] == "1" { return false }
        if let h = env["BOSS_HOME"], !h.isEmpty,
           URL(fileURLWithPath: (h as NSString).expandingTildeInPath).standardizedFileURL.path != URL(fileURLWithPath: defaultHome).standardizedFileURL.path {
            return false
        }
        return true
    }

    public static func shellRunner(script: String = "~/.claude/tools/telegram-send.sh", log: URL? = nil) -> Runner {
        { text in
            if let log {
                let line = "{\"at\":\"\(ISO8601DateFormatter().string(from: Date()))\",\"event\":\"telegram_send\",\"chars\":\(text.count)}\n"
                if let h = try? FileHandle(forWritingTo: log) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
                else { try? Data(line.utf8).write(to: log) }
            }
            let path = (script as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [path, text]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
        }
    }

    public static func format(_ e: ChannelEvent, at: Date) -> String? {
        let t = SGT.time(at)
        switch e {
        case .say(let s):
            var lines = ["Boss \(t): " + SpeechItem.format(session: s.session, text: s.text)]
            for l in s.links { lines.append(l.title == l.url ? l.url : "\(l.title): \(l.url)") }
            return lines.joined(separator: "\n")
        case .ask(let a):
            var lines = ["Boss asks \(t): " + SpeechItem.format(session: a.session, text: a.question)]
            if !a.choices.isEmpty { lines.append("Choices: " + a.choices.joined(separator: " | ")) }
            return lines.joined(separator: "\n")
        default: return nil
        }
    }

    /// Returns true if a Telegram message was sent.
    @discardableResult
    public func handle(_ e: ChannelEvent) -> Bool {
        guard enabled, away.isAway else { return false }
        let key: String
        switch e {
        // Only a report (a task done) or a status answer reaches his phone; "info" notices
        // (a channel hiccup, a retry) never do (Roman, 2026-11-24: done, answers, questions only).
        case .say(let s):
            guard s.kind != "info" else { return false }
            key = "say:" + s.id
        case .ask(let a): key = "ask:" + a.questionID
        default: return false
        }
        guard let text = Self.format(e, at: clock()) else { return false }
        lock.lock()
        let fresh = sent.insert(key).inserted
        if fresh { sentTexts.append(text) }
        lock.unlock()
        guard fresh else { return false }
        runner(text)
        return true
    }
}
