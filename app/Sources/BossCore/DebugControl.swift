import Foundation

/// What the debug control server drives (implemented by BossEngine).
@MainActor
public protocol DebugControlHandler: AnyObject {
    func debugInject(wavPath: String) async -> HTTPResponse
    func debugFeed() -> HTTPResponse
    func debugSessions() -> HTTPResponse
    func debugTalk(down: Bool) async -> HTTPResponse
    func debugTap(choice: String) async -> HTTPResponse
    func debugUndo() async -> HTTPResponse
    func debugSpoken() -> HTTPResponse
    func debugStatus() -> HTTPResponse
    func debugSnapshot(path: String, window: String) -> HTTPResponse
    func debugChat(name: String?) -> HTTPResponse
    func debugLanguage(_ code: String) -> HTTPResponse
}

/// Routes debug-control HTTP requests. Token-guarded; browser requests (Origin) refused.
@MainActor
public struct DebugControlRouter {
    public var token: () -> String?
    public weak var handler: DebugControlHandler?
    public init(token: @escaping () -> String?, handler: DebugControlHandler?) {
        self.token = token; self.handler = handler
    }

    public func authorized(_ r: HTTPRequest) -> Bool {
        guard let t = token(), !t.isEmpty, let auth = r.headers["authorization"] else { return false }
        let expected = "Bearer \(t)"
        // constant-time compare
        let a = Array(auth.utf8), b = Array(expected.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in a.indices { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    public func route(_ r: HTTPRequest) async -> HTTPResponse {
        if r.headers["origin"] != nil { return .error(403, "origin not allowed") }
        guard authorized(r) else { return .error(403, "bad token") }
        guard let h = handler else { return .error(503, "app not ready") }
        switch (r.method, r.path) {
        case ("GET", "/status"): return h.debugStatus()
        case ("GET", "/feed"): return h.debugFeed()
        case ("GET", "/sessions"): return h.debugSessions()
        case ("GET", "/spoken"): return h.debugSpoken()
        case ("POST", "/inject"):
            guard let j = r.json(), let p = j["wav_path"] as? String, !p.isEmpty else { return .error(400, "wav_path required") }
            return await h.debugInject(wavPath: p)
        case ("POST", "/talk"):
            guard let j = r.json(), let d = j["down"] as? Bool else { return .error(400, "down:bool required") }
            return await h.debugTalk(down: d)
        case ("POST", "/tap"):
            guard let j = r.json() else { return .error(400, "bad json") }
            let choice: String
            if let s = j["choice"] as? String { choice = s }
            else if let n = j["choice"] as? NSNumber { choice = n.stringValue }
            else { return .error(400, "choice required") }
            return await h.debugTap(choice: choice)
        case ("POST", "/undo"): return await h.debugUndo()
        case ("POST", "/language"):
            guard let j = r.json(), let c = j["lang"] as? String, ["en", "ru"].contains(c) else { return .error(400, "lang en|ru required") }
            return h.debugLanguage(c)
        case ("POST", "/snapshot"):
            guard let j = r.json(), let p = j["path"] as? String, p.hasSuffix(".png") else { return .error(400, "path (.png) required") }
            let w = j["window"] as? String ?? "panel"
            guard ["panel", "chat"].contains(w) else { return .error(400, "window panel|chat") }
            return h.debugSnapshot(path: p, window: w)
        case ("POST", "/chat"):
            // {"name": "<session>"} opens its chat window; {} or {"name": null} closes it.
            guard let j = r.json() else { return .error(400, "json body required") }
            if let n = j["name"], !(n is NSNull) && !(n is String) { return .error(400, "name must be a string") }
            return h.debugChat(name: j["name"] as? String)
        case (_, "/status"), (_, "/feed"), (_, "/sessions"), (_, "/spoken"), (_, "/inject"), (_, "/talk"), (_, "/tap"), (_, "/undo"), (_, "/snapshot"), (_, "/language"), (_, "/chat"):
            return .error(405, "method not allowed")
        default:
            return .error(404, "not found")
        }
    }
}
