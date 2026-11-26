import Foundation
import BossCore

/// The real credential readers behind the limits strip. Nothing here is stored or logged.
extension AppDelegate {
    func makeLimits(telegramAllowed: Bool) -> LimitsStore {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Test, demo and sandbox instances never ask the real providers (same rule as Telegram).
        let live = env["BOSS_LIMITS"] == "1" || (telegramAllowed && env["BOSS_NO_LIMITS"] != "1")
        let http = URLSessionTransport()
        let sources: [LimitsSource] = live ? [
            ClaudeLimitsSource(http: http, credentials: { Self.claudeCredentials(home: home) }),
            KimiLimitsSource(http: http, key: { KimiKey.find(env: env, home: home) }),
            GeminiLimitsSource(http: http, auth: { Self.antigravityAuth(home: home) },
                               proxyLog: { Self.proxyLogTail(home: home) }),
        ] : []
        return LimitsStore(sources: sources, cacheURL: live ? paths.state.appendingPathComponent("limits.json") : nil,
                           expanded: UserDefaults.standard.bool(forKey: "limitsExpanded"),
                           saveExpanded: { UserDefaults.standard.set($0, forKey: "limitsExpanded") })
    }

    func refreshLimits(force: Bool) {
        guard let limits else { return }
        Task { await limits.tick(now: Date(), force: force) }
    }

    /// Claude Code's login: the macOS keychain item, else the credentials file it uses elsewhere.
    nonisolated static func claudeCredentials(home: URL) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus == 0, let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                return s
            }
        }
        return try? String(contentsOf: home.appendingPathComponent(".claude/.credentials.json"), encoding: .utf8)
    }

    nonisolated static func proxyDir(home: URL) -> URL {
        let cfg = try? String(contentsOf: home.appendingPathComponent(".cli-proxy-api/config.yaml"), encoding: .utf8)
        return AntigravityAuth.authDir(home: home, config: cfg)
    }

    /// CLIProxyAPI's Antigravity login, the one geminicode.sh uses.
    nonisolated static func antigravityAuth(home: URL) -> AntigravityAuth? {
        let dir = proxyDir(home: home)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where f.lastPathComponent.hasPrefix("antigravity-") && f.pathExtension == "json" {
            if let d = try? Data(contentsOf: f), let a = AntigravityAuth.parse(d) { return a }
        }
        return nil
    }

    /// The last 128 KB of the proxy's log: recent "quota exhausted" refusals.
    nonisolated static func proxyLogTail(home: URL) -> String? {
        let url = proxyDir(home: home).appendingPathComponent("proxy.log")
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 131_072 ? size - 131_072 : 0)
        guard let d = try? h.readToEnd() else { return nil }
        return String(decoding: d, as: UTF8.self)
    }
}
