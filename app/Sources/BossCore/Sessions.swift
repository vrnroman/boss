import Foundation

/// One Claude Code session file from `~/.claude/sessions/<pid>.json`.
public struct SessionInfo: Equatable, Sendable, Codable {
    public var pid: Int32
    public var sessionId: String
    public var cwd: String
    public var name: String
    public var status: String
    public var kind: String
    public var updatedAt: Date?
    public var startedAt: Date?

    public init(pid: Int32, sessionId: String = "", cwd: String = "", name: String, status: String = "idle",
                kind: String = "interactive", updatedAt: Date? = nil, startedAt: Date? = nil) {
        self.pid = pid; self.sessionId = sessionId; self.cwd = cwd; self.name = name; self.status = status
        self.kind = kind; self.updatedAt = updatedAt; self.startedAt = startedAt
    }

    public static func parse(_ data: Data) -> SessionInfo? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pid = (o["pid"] as? NSNumber)?.int32Value else { return nil }
        let cwd = o["cwd"] as? String ?? ""
        let name = (o["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (cwd as NSString).lastPathComponent
        return SessionInfo(pid: pid, sessionId: o["sessionId"] as? String ?? "", cwd: cwd, name: name,
                           status: o["status"] as? String ?? "unknown", kind: o["kind"] as? String ?? "",
                           updatedAt: Timestamp.parse(o["updatedAt"]), startedAt: Timestamp.parse(o["startedAt"]))
    }

    public var cwdBase: String { (cwd as NSString).lastPathComponent }
}

/// Reads live interactive sessions. Filesystem, liveness and tty lookup are injected.
public struct SessionsStore: Sendable {
    public var dir: URL
    public var isAlive: @Sendable (Int32) -> Bool
    public var ttyLookup: @Sendable (Int32) -> String?
    /// Names never shown or routed to (Boss itself, under any name).
    public var hidden: Set<String> = ["boss"]
    /// When set, only names matching one of these globs are shown (demos and tests).
    public var only: [String]? = nil

    /// Builds a store from BOSS_NAME (hidden too) and BOSS_SESSIONS_ONLY ("payments,site" or "bt-*").
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> SessionsStore {
        var s = SessionsStore()
        if let n = env["BOSS_NAME"], !n.isEmpty { s.hidden.insert(n.lowercased()) }
        if let o = env["BOSS_SESSIONS_ONLY"], !o.isEmpty {
            s.only = o.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return s
    }

    public static func glob(_ pattern: String, _ name: String) -> Bool {
        let parts = pattern.lowercased().split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        let n = name.lowercased()
        if parts.count == 1 { return n == parts[0] }
        guard n.hasPrefix(parts[0]) else { return false }
        var rest = n.dropFirst(parts[0].count)
        for (i, p) in parts.dropFirst().enumerated() {
            let last = i == parts.count - 2
            if last { return p.isEmpty || rest.hasSuffix(p) }
            guard let r = rest.range(of: p) else { return false }
            rest = rest[r.upperBound...]
        }
        return true
    }

    public func visible(_ name: String) -> Bool {
        if hidden.contains(name.lowercased()) { return false }
        if let only { return only.contains { SessionsStore.glob($0, name) } }
        return true
    }

    public init(dir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions"),
                isAlive: @escaping @Sendable (Int32) -> Bool = SessionsStore.pidAlive,
                ttyLookup: @escaping @Sendable (Int32) -> String? = SessionsStore.psTTY) {
        self.dir = dir; self.isAlive = isAlive; self.ttyLookup = ttyLookup
    }

    public static let pidAlive: @Sendable (Int32) -> Bool = { pid in
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    /// `ps -o tty= -p <pid>` → "/dev/ttys003" (nil if none / "??").
    public static let psTTY: @Sendable (Int32) -> String? = { pid in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "tty=", "-p", String(pid)]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return normalizeTTY(out)
    }

    public static func normalizeTTY(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.hasPrefix("?") { return nil }
        return t.hasPrefix("/dev/") ? t : "/dev/" + t
    }

    /// Live interactive sessions, excluding Boss itself. Newest name wins on duplicates.
    public func load() -> [SessionInfo] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var out: [SessionInfo] = []
        for f in files where f.hasSuffix(".json") {
            guard let d = try? Data(contentsOf: dir.appendingPathComponent(f)),
                  let s = SessionInfo.parse(d) else { continue }
            guard s.kind == "interactive", visible(s.name), isAlive(s.pid) else { continue }
            out.append(s)
        }
        return out.sorted { $0.name < $1.name }
    }
}

/// One row of the timing tower.
public struct TowerRow: Equatable, Sendable, Codable, Identifiable {
    public enum Group: Int, Codable, Sendable, Comparable {
        case waiting = 0, busy = 1, idle = 2, other = 3
        public static func < (a: Group, b: Group) -> Bool { a.rawValue < b.rawValue }
    }
    public var id: String { name }
    public var name: String
    public var cwdBase: String
    public var pid: Int32
    public var status: String
    public var group: Group
    /// Seconds waiting on Roman (only for `.waiting`).
    public var waitSeconds: Double?
    public var waitText: String?
    public var questionID: String?
    /// The pending question, or the last report's short text.
    public var detail: String?
    /// "b/(b+m)" e.g. "14/15", nil if never routed blind.
    public var trust: String?
    public var graduated: Bool
    /// The nickname Roman gave this session, if any (shown first; the real name stays visible).
    public var nickname: String? = nil
}

public enum Tower {
    /// Before the channel answers: the project folder as the name (no numbering yet).
    public static func folderName(_ s: SessionInfo) -> String? {
        let f = s.cwdBase.lowercased()
        return f.isEmpty || f == s.name.lowercased() ? nil : f
    }

    /// Shorten a report to one line for the tower.
    public static func short(_ s: String, max: Int = 80) -> String {
        let first = s.split(whereSeparator: { $0 == "\n" }).first.map(String.init) ?? s
        if first.count <= max { return first }
        return String(first.prefix(max - 1)) + "…"
    }

    /// `questionSeen` = when the app received each question (fallback when the state has no `at`).
    public static func rows(sessions: [SessionInfo], state: ChannelState?, now: Date,
                            questionSeen: [String: Date] = [:]) -> [TowerRow] {
        var rows: [TowerRow] = sessions.map { s in
            let q = state?.questions.filter { ($0.session ?? "") == s.name }
                .min { ($0.at ?? questionSeen[$0.questionID] ?? now) < ($1.at ?? questionSeen[$1.questionID] ?? now) }
            let group: TowerRow.Group
            switch (q != nil, s.status) {
            case (true, _): group = .waiting
            case (_, "busy"): group = .busy
            case (_, "idle"): group = .idle
            default: group = .other
            }
            var wait: Double?
            if let q { wait = now.timeIntervalSince(q.at ?? questionSeen[q.questionID] ?? now) }
            let trust = state?.ledger[s.name].flatMap { l -> String? in
                (l.blind + l.misses) == 0 ? nil : "\(l.blind)/\(l.blind + l.misses)"
            }
            return TowerRow(name: s.name, cwdBase: s.cwdBase, pid: s.pid, status: s.status, group: group,
                            waitSeconds: wait, waitText: wait.map(shortDuration), questionID: q?.questionID,
                            detail: q.map { $0.question } ?? state?.reports[s.name].map { short($0.text) },
                            trust: trust, graduated: state?.ledger[s.name]?.graduated ?? false,
                            nickname: state?.display[s.name] ?? state?.nicknames[s.name] ?? Tower.folderName(s))
        }
        rows.sort { a, b in
            if a.group != b.group { return a.group < b.group }
            if a.group == .waiting, let wa = a.waitSeconds, let wb = b.waitSeconds, wa != wb { return wa > wb }
            return a.name < b.name
        }
        return rows
    }

    /// "2 working · 1 waiting on you"
    public static func counts(_ rows: [TowerRow]) -> String {
        let w = rows.filter { $0.group == .waiting }.count
        let b = rows.filter { $0.group == .busy }.count
        var parts: [String] = []
        if b > 0 { parts.append("\(b) working") }
        if w > 0 { parts.append("\(w) waiting on you") }
        if parts.isEmpty { return rows.isEmpty ? "no sessions" : "\(rows.count) idle" }
        return parts.joined(separator: " · ")
    }
}
