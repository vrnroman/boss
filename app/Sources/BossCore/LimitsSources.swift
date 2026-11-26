import Foundation

/// Where each subscription's usage comes from. Credentials are read fresh on every fetch (Claude
/// Code and the Gemini proxy rotate them) and never stored or logged by Boss.

func retryAfter(_ r: HTTPResult) -> TimeInterval {
    Double(r.headers["retry-after"]?.trimmingCharacters(in: .whitespaces) ?? "") ?? 900
}

// MARK: Claude

public struct ClaudeLimitsSource: LimitsSource {
    public let id = "claude"
    public let interval: TimeInterval = 10 * 60
    let http: HTTPTransport
    /// The JSON Claude Code keeps in the login keychain ("Claude Code-credentials"), or nil.
    let credentials: @Sendable () -> String?
    public init(http: HTTPTransport, credentials: @escaping @Sendable () -> String?) {
        self.http = http; self.credentials = credentials
    }

    public func fetch(now: Date) async -> LimitsFetch {
        guard let raw = credentials(), let d = raw.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let oauth = o["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return .absent }
        // An expired token: Claude Code renews it on its next request. Keep the last numbers.
        if let exp = LimitsParse.num(oauth["expiresAt"]), exp / 1000 < now.timeIntervalSince1970 { return .failed }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("boss", forHTTPHeaderField: "User-Agent")
        guard let r = try? await http.send(req) else { return .failed }
        if r.status == 429 { return .backoff(retryAfter(r)) }
        guard r.status == 200, let p = LimitsParse.claude(r.body, now: now) else { return .failed }
        return .ok(p)
    }
}

// MARK: Kimi Code

public enum KimiKey {
    /// Files where a Kimi Code setup usually lives: launch scripts in the home folder and shell rc files.
    public static func candidateFiles(home: URL, fm: FileManager = .default) -> [URL] {
        var out: [URL] = []
        if let items = try? fm.contentsOfDirectory(at: home, includingPropertiesForKeys: nil) {
            out += items.filter { $0.pathExtension == "sh" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        for rc in [".zshrc", ".zprofile", ".zshenv", ".bashrc", ".bash_profile", ".profile", ".config/fish/config.fish"] {
            out.append(home.appendingPathComponent(rc))
        }
        return out
    }

    /// A Kimi Code (subscription) key in one file's text: it must point Claude Code at
    /// api.kimi.com/coding. The pay-as-you-go Moonshot platform has no plan limits to show.
    public static func find(in text: String) -> String? {
        guard text.contains("api.kimi.com/coding") else { return nil }
        for line in text.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("#") { continue }
            for name in ["KIMI_API_KEY", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"] {
                guard let r = l.range(of: "\(name)=") else { continue }
                let before = l[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                guard before.isEmpty || before == "export" || before == "set -gx" else { continue }
                var v = String(l[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if let hash = v.range(of: " #") { v = String(v[..<hash.lowerBound]) }
                v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                if v.count >= 16, !v.contains("$") { return v }
            }
        }
        return nil
    }

    public static func find(env: [String: String], home: URL, read: (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) }) -> String? {
        if let k = env["KIMI_API_KEY"], !k.isEmpty { return k }
        for f in candidateFiles(home: home) { if let t = read(f), let k = find(in: t) { return k } }
        return nil
    }
}

public struct KimiLimitsSource: LimitsSource {
    public let id = "kimi"
    public let interval: TimeInterval = 5 * 60
    let http: HTTPTransport
    let key: @Sendable () -> String?
    public init(http: HTTPTransport, key: @escaping @Sendable () -> String?) { self.http = http; self.key = key }

    public func fetch(now: Date) async -> LimitsFetch {
        guard let k = key() else { return .absent }
        var req = URLRequest(url: URL(string: "https://api.kimi.com/coding/v1/usages")!)
        req.timeoutInterval = 20
        req.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization")
        guard let r = try? await http.send(req) else { return .failed }
        if r.status == 429 { return .backoff(retryAfter(r)) }
        if r.status == 401 || r.status == 403 { return .absent }   // a dead key is no subscription
        guard r.status == 200, let p = LimitsParse.kimi(r.body, now: now) else { return .failed }
        return .ok(p)
    }
}

// MARK: Gemini (Antigravity login, through CLIProxyAPI)

public struct AntigravityAuth: Equatable, Sendable {
    public var accessToken: String
    public var projectID: String?
    public var endpoint: String
    public var expires: Date?

    /// One CLIProxyAPI credential file (`antigravity-*.json` in its auth dir).
    public static func parse(_ data: Data) -> AntigravityAuth? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (o["type"] as? String) == "antigravity", (o["disabled"] as? Bool) != true,
              let t = o["access_token"] as? String, !t.isEmpty else { return nil }
        let hints = o["antigravity_capability_hints"] as? [String: Any]
        return AntigravityAuth(accessToken: t, projectID: o["project_id"] as? String,
                               endpoint: (hints?["endpoint"] as? String) ?? "https://cloudcode-pa.googleapis.com",
                               expires: LimitsParse.date(o["expired"] as? String))
    }

    /// The proxy's auth dir: `auth-dir` in its config, else ~/.cli-proxy-api.
    public static func authDir(home: URL, config: String?) -> URL {
        let def = home.appendingPathComponent(".cli-proxy-api")
        guard let config else { return def }
        for line in config.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("auth-dir:") else { continue }
            var v = String(l.dropFirst("auth-dir:".count))
            if let hash = v.range(of: " #") { v = String(v[..<hash.lowerBound]) }
            v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if v.hasPrefix("~/") { return home.appendingPathComponent(String(v.dropFirst(2))) }
            if v.hasPrefix("/") { return URL(fileURLWithPath: v) }
        }
        return def
    }
}

public struct GeminiLimitsSource: LimitsSource {
    public let id = "gemini"
    public let interval: TimeInterval = 5 * 60
    let http: HTTPTransport
    let auth: @Sendable () -> AntigravityAuth?
    let proxyLog: @Sendable () -> String?
    /// Google only answers the quota call for its Antigravity client, as the proxy itself does.
    static let userAgent = "antigravity/1.15.8 darwin/arm64"
    public init(http: HTTPTransport, auth: @escaping @Sendable () -> AntigravityAuth?, proxyLog: @escaping @Sendable () -> String? = { nil }) {
        self.http = http; self.auth = auth; self.proxyLog = proxyLog
    }

    public func fetch(now: Date) async -> LimitsFetch {
        guard let a = auth() else { return .absent }
        // The proxy renews the token while it runs; when it is stopped the token lapses. Keep the last numbers.
        if let e = a.expires, e < now { return .failed }
        guard let url = URL(string: a.endpoint + "/v1internal:fetchAvailableModels") else { return .failed }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("Bearer \(a.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = try? JSONSerialization.data(withJSONObject: a.projectID.map { ["project": $0] } ?? [:])
        guard let r = try? await http.send(req) else { return .failed }
        if r.status == 429 { return .backoff(retryAfter(r)) }
        let exhausted = proxyLog().map { LimitsParse.proxyExhausted(log: $0, now: now) } ?? []
        guard r.status == 200, let p = LimitsParse.gemini(r.body, exhausted: exhausted, now: now) else { return .failed }
        return .ok(p)
    }
}
