import Foundation

/// Runtime locations (`~/Boss` unless `BOSS_HOME` is set).
public struct BossPaths: Sendable {
    public var home: URL
    public init(home: URL) { self.home = home }
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> BossPaths {
        if let h = env["BOSS_HOME"], !h.isEmpty { return BossPaths(home: URL(fileURLWithPath: (h as NSString).expandingTildeInPath)) }
        return BossPaths(home: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Boss"))
    }
    public var tokenFile: URL { home.appendingPathComponent("token") }
    public var outbox: URL { home.appendingPathComponent("outbox") }
    public var logs: URL { home.appendingPathComponent("logs") }
    public var state: URL { home.appendingPathComponent("state") }

    /// Bearer token, trimmed; nil if missing/empty.
    public func readToken() -> String? {
        guard let s = try? String(contentsOf: tokenFile, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

public enum Ports {
    public static func channel(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Int {
        Int(env["BOSS_PORT"] ?? "") ?? 8788
    }
    public static let debugControl = 8789
    public static let whisper = 8791
    public static let tts = 8792
}

/// Singapore time formatting for anything shown to Roman.
public enum SGT {
    public static let zone = TimeZone(identifier: "Asia/Singapore")!
    public static func time(_ d: Date) -> String { fmt("HH:mm", d) + " SGT" }
    public static func dateTime(_ d: Date) -> String { fmt("yyyy-MM-dd HH:mm", d) + " SGT" }
    /// "21:01 SGT" if `d` is the same SGT day as `now`, else "2026-10-10 21:01 SGT".
    public static func smart(_ d: Date, now: Date) -> String {
        fmt("yyyy-MM-dd", d) == fmt("yyyy-MM-dd", now) ? time(d) : dateTime(d)
    }
    private static func fmt(_ f: String, _ d: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = zone
        df.dateFormat = f
        return df.string(from: d)
    }
}

/// Lenient timestamp parsing: ISO-8601 strings (with or without fractional seconds),
/// or epoch numbers in seconds or milliseconds.
public enum Timestamp {
    public static func parse(_ any: Any?) -> Date? {
        switch any {
        case let n as NSNumber: return fromNumber(n.doubleValue)
        case let d as Double: return fromNumber(d)
        case let i as Int: return fromNumber(Double(i))
        case let s as String:
            if let d = Double(s) { return fromNumber(d) }
            let f1 = ISO8601DateFormatter()
            f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f1.date(from: s) { return d }
            let f2 = ISO8601DateFormatter()
            return f2.date(from: s)
        default: return nil
        }
    }
    public static func fromNumber(_ v: Double) -> Date {
        v > 1e11 ? Date(timeIntervalSince1970: v / 1000) : Date(timeIntervalSince1970: v)
    }
    public static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
}

/// A short human duration: "45 s", "3 min", "1 h 5 min".
public func shortDuration(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds))
    if s < 60 { return "\(s) s" }
    if s < 3600 { return "\(s / 60) min" }
    let h = s / 3600, m = (s % 3600) / 60
    return m == 0 ? "\(h) h" : "\(h) h \(m) min"
}
