import Foundation

/// Subscription limits (Roman, 2026-11-26): Claude, plus Kimi and Gemini when this Mac has them.
/// Each provider has its own windows (5 h, day, week, month...), each with its own reset.

public struct LimitWindow: Equatable, Sendable, Codable {
    public var label: String        // "5h", "week", "day", "month", "week · Fable", "quota"
    public var used: Double         // 0...1
    public var resetsAt: Date?
    public init(label: String, used: Double, resetsAt: Date?) {
        self.label = label; self.used = min(max(used, 0), 1); self.resetsAt = resetsAt
    }
}

public struct ProviderLimits: Equatable, Sendable, Codable, Identifiable {
    public var id: String           // "claude" | "kimi" | "gemini"
    public var name: String
    public var windows: [LimitWindow]
    public var note: String?        // e.g. "Neon limited now"
    public var limitedNow = false   // the provider is refusing requests right now
    public var asOf: Date
    public init(id: String, name: String, windows: [LimitWindow], note: String? = nil, limitedNow: Bool = false, asOf: Date) {
        self.id = id; self.name = name; self.windows = windows; self.note = note; self.limitedNow = limitedNow; self.asOf = asOf
    }
    /// The fullest window: what the one-line summary shows.
    public var peak: Double { limitedNow ? 1 : (windows.map(\.used).max() ?? 0) }
    /// The reset that matters most: the fullest window's.
    public var peakWindow: LimitWindow? { windows.max { $0.used < $1.used } }
}

public enum LimitsParse {
    static func date(_ s: String?) -> Date? {
        guard var s, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        // Microsecond fractions ("…00.178161+00:00") are more than the formatter takes: cut them.
        if let dot = s.firstIndex(of: "."), let end = s[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            s.removeSubrange(dot..<end)
        }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    static func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }

    /// "week", "day", "5h", "month", "30m" for a window length.
    public static func durationLabel(seconds s: Double) -> String {
        let day = 86_400.0
        if s >= 28 * day { return "month" }
        if s.truncatingRemainder(dividingBy: 7 * day) == 0 { return s == 7 * day ? "week" : "\(Int(s / (7 * day)))w" }
        if s.truncatingRemainder(dividingBy: day) == 0 { return s == day ? "day" : "\(Int(s / day))d" }
        if s >= 3600, s.truncatingRemainder(dividingBy: 3600) == 0 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 60))m"
    }

    static func groupLabel(_ g: String) -> String {
        switch g.lowercased() {
        case "weekly", "seven_day", "week": return "week"
        case "daily", "day": return "day"
        case "monthly", "month": return "month"
        case "five_hour", "session", "5h": return "5h"
        default: return g.replacingOccurrences(of: "_", with: " ")
        }
    }

    // MARK: Claude: GET api.anthropic.com/api/oauth/usage

    public static func claude(_ data: Data, now: Date) -> ProviderLimits? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var windows: [LimitWindow] = []
        if let limits = o["limits"] as? [[String: Any]] {
            for l in limits where (l["is_active"] as? Bool) != false {
                guard let pct = num(l["percent"]) else { continue }
                var label = groupLabel((l["group"] as? String) ?? (l["kind"] as? String) ?? "limit")
                if let scope = l["scope"] as? [String: Any], let model = scope["model"] as? [String: Any],
                   let name = model["display_name"] as? String { label += " · \(name)" }
                windows.append(LimitWindow(label: label, used: pct / 100, resetsAt: date(l["resets_at"] as? String)))
            }
        }
        // Older responses (and windows the list leaves out) come as named fields.
        for (key, label) in [("five_hour", "5h"), ("seven_day", "week")] {
            guard let w = o[key] as? [String: Any], let u = num(w["utilization"]) else { continue }
            if windows.contains(where: { $0.label == label }) { continue }
            windows.append(LimitWindow(label: label, used: u / 100, resetsAt: date(w["resets_at"] as? String)))
        }
        guard !windows.isEmpty else { return nil }
        return ProviderLimits(id: "claude", name: "Claude", windows: sortWindows(windows), asOf: now)
    }

    // MARK: Kimi Code: GET api.kimi.com/coding/v1/usages

    public static func kimi(_ data: Data, now: Date) -> ProviderLimits? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var windows: [LimitWindow] = []
        if let usages = o["usages"] as? [String: Any] {
            // {"limit_5h": {"used_ratio": 0.11, "reset_time": "…"}, "limit_7d": {…}}
            for (k, v) in usages {
                guard let w = v as? [String: Any], let r = num(w["used_ratio"]) else { continue }
                windows.append(LimitWindow(label: kimiKeyLabel(k), used: r, resetsAt: date(w["reset_time"] as? String)))
            }
        }
        if windows.isEmpty {
            func ratio(_ d: [String: Any]) -> Double? {
                guard let lim = num(d["limit"]), lim > 0 else { return nil }
                if let used = num(d["used"]) { return used / lim }
                if let rem = num(d["remaining"]) { return (lim - rem) / lim }
                return nil
            }
            for l in (o["limits"] as? [[String: Any]]) ?? [] {
                guard let d = l["detail"] as? [String: Any], let r = ratio(d) else { continue }
                var label = "window"
                if let w = l["window"] as? [String: Any], let n = num(w["duration"]) {
                    let unit = (w["timeUnit"] as? String ?? "").uppercased()
                    let secs = unit.contains("SECOND") ? n : unit.contains("HOUR") ? n * 3600 : unit.contains("DAY") ? n * 86_400 : n * 60
                    label = durationLabel(seconds: secs)
                }
                windows.append(LimitWindow(label: label, used: r, resetsAt: date(d["resetTime"] as? String)))
            }
            if let u = o["usage"] as? [String: Any], let r = ratio(u) {
                windows.append(LimitWindow(label: "plan", used: r, resetsAt: date(u["resetTime"] as? String)))
            }
        }
        guard !windows.isEmpty else { return nil }
        return ProviderLimits(id: "kimi", name: "Kimi", windows: sortWindows(windows), asOf: now)
    }

    static func kimiKeyLabel(_ k: String) -> String {
        // limit_5h, limit_7d, limit_1d, limit_30d, limit_1m (month)
        let s = k.lowercased().replacingOccurrences(of: "limit_", with: "")
        guard let unit = s.last, let n = Double(s.dropLast()) else { return groupLabel(s) }
        switch unit {
        case "m": return n == 1 ? "month" : "\(Int(n)) months"
        case "h": return durationLabel(seconds: n * 3600)
        case "d": return durationLabel(seconds: n * 86_400)
        case "w": return durationLabel(seconds: n * 7 * 86_400)
        default: return s
        }
    }

    // MARK: Gemini via Antigravity: POST cloudcode-pa…/v1internal:fetchAvailableModels

    /// Google reports a remaining fraction and reset per model. Gemini models share a pool, so the
    /// summary is the emptiest Gemini model. `exhausted` lists models the proxy saw refused recently.
    public static func gemini(_ data: Data, exhausted: [String] = [], now: Date) -> ProviderLimits? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = o["models"] as? [String: Any] else { return nil }
        var worst: (used: Double, reset: Date?)?
        for (id, v) in models where id.hasPrefix("gemini") {
            guard let m = v as? [String: Any], let q = m["quotaInfo"] as? [String: Any],
                  let rem = num(q["remainingFraction"]), let reset = q["resetTime"] as? String else { continue }
            let used = 1 - rem
            if worst == nil || used > worst!.used { worst = (used, date(reset)) }
        }
        guard let w = worst else { return nil }
        let names = exhausted.map(prettyGemini)
        return ProviderLimits(id: "gemini", name: "Gemini", windows: [LimitWindow(label: "quota", used: w.used, resetsAt: w.reset)],
                              note: names.isEmpty ? nil : "\(names.joined(separator: ", ")) limited now",
                              limitedNow: !names.isEmpty, asOf: now)
    }

    /// "gemini-4-neon-xhigh" → "Neon".
    static func prettyGemini(_ id: String) -> String {
        let parts = id.split(separator: "-").map(String.init)
        if parts.count >= 3, parts[0] == "gemini", let name = parts.dropFirst(2).first { return name.prefix(1).uppercased() + name.dropFirst() }
        return id
    }

    /// Models the CLIProxyAPI log shows refused for quota within `window` seconds of `now`.
    /// Log lines: "[2026-11-26 23:23:48] [id] [warn ] … model=gemini-4-neon-xhigh … RESOURCE_EXHAUSTED".
    public static func proxyExhausted(log: String, now: Date, window: TimeInterval = 600, timeZone: TimeZone = .current) -> [String] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone; f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var seen: [String] = []
        for line in log.split(separator: "\n") where line.contains("RESOURCE_EXHAUSTED") || line.contains("reason=quota") {
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]"),
                  let t = f.date(from: String(line[line.index(after: line.startIndex)..<close])),
                  now.timeIntervalSince(t) <= window, now.timeIntervalSince(t) >= -60 else { continue }
            guard let r = line.range(of: "model=") ?? line.range(of: "model \"") else { continue }
            let model = line[r.upperBound...].prefix { !$0.isWhitespace && $0 != "\"" && $0 != "," }
            let m = String(model)
            if !m.isEmpty, !seen.contains(m) { seen.append(m) }
        }
        return seen
    }

    static func sortWindows(_ w: [LimitWindow]) -> [LimitWindow] {
        // Shortest window first: 5h, day, week, month; scoped ones after their group.
        func rank(_ l: String) -> Int {
            let base = l.split(separator: "·").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? l
            switch base {
            case let b where b.hasSuffix("m") && Int(b.dropLast()) != nil: return 0
            case let b where b.hasSuffix("h") && Int(b.dropLast()) != nil: return 1
            case "day": return 2
            case let b where b.hasSuffix("d") && Int(b.dropLast()) != nil: return 3
            case "week": return 4
            case "month": return 6
            default: return 5
            }
        }
        return w.enumerated().sorted { a, b in
            let ra = rank(a.element.label), rb = rank(b.element.label)
            if ra != rb { return ra < rb }
            if a.element.label.contains("·") != b.element.label.contains("·") { return !a.element.label.contains("·") }
            return a.offset < b.offset
        }.map(\.element)
    }
}

public enum ResetText {
    /// "03:16" today, "tomorrow 04:06", "Sun 22:16" within a week, "Dec 3 14:00" beyond. Local time.
    public static func format(_ d: Date?, now: Date, calendar: Calendar = .current) -> String {
        guard let d else { return "" }
        if d <= now { return "now" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = calendar.timeZone
        if calendar.isDate(d, inSameDayAs: now) { f.dateFormat = "HH:mm"; return f.string(from: d) }
        if let t = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(d, inSameDayAs: t) {
            f.dateFormat = "HH:mm"; return "tomorrow " + f.string(from: d)
        }
        if d.timeIntervalSince(now) < 6 * 86_400 { f.dateFormat = "EEE HH:mm"; return f.string(from: d) }
        f.dateFormat = "MMM d HH:mm"; return f.string(from: d)
    }

    /// "in 3h 12m", "in 2d 4h", "in 8m".
    public static func countdown(_ d: Date?, now: Date) -> String {
        guard let d else { return "" }
        let s = Int(d.timeIntervalSince(now))
        if s <= 0 { return "now" }
        let days = s / 86_400, h = (s % 86_400) / 3600, m = (s % 3600) / 60
        if days > 0 { return "in \(days)d \(h)h" }
        if h > 0 { return "in \(h)h \(m)m" }
        return "in \(max(m, 1))m"
    }
}
