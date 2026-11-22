import Foundation

public enum PostResult: Equatable, Sendable {
    case accepted(duplicate: Bool)
    case bossOffline              // 503: keep queued
    case unauthorized             // 401/403: token problem
    case failed(String)           // network or other HTTP error

    public var isAccepted: Bool { if case .accepted = self { return true }; return false }
}

/// What the rest of the app needs from the channel (fakeable in tests).
public protocol ChannelAPI: Sendable {
    func postUtterance(id: String, text: String, mode: String, lang: String?, sessions: [SessionInfo]) async -> PostResult
    func postAnswer(questionID: String, text: String) async -> PostResult
    func postUndo(utteranceID: String) async -> PostResult
    func cancelRoute(routeID: String) async -> PostResult
    func getState(sessions: [SessionInfo]) async -> ChannelState?
    func health() async -> Bool?   // boss_connected, nil = channel unreachable
}

public struct ChannelClient: ChannelAPI {
    public var baseURL: URL
    public var token: @Sendable () -> String?
    public var transport: HTTPTransport

    public init(baseURL: URL = URL(string: "http://127.0.0.1:\(Ports.channel())")!,
                token: @escaping @Sendable () -> String?, transport: HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL; self.token = token; self.transport = transport
    }

    public func request(_ method: String, _ path: String, json: [String: Any]? = nil) -> URLRequest {
        var req = URLRequest(url: URL(string: path, relativeTo: baseURL)!.absoluteURL, timeoutInterval: 10)
        req.httpMethod = method
        if let t = token() { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        }
        return req
    }

    func post(_ path: String, _ body: [String: Any]) async -> PostResult {
        do {
            let r = try await transport.send(request("POST", path, json: body))
            switch r.status {
            case 200..<300:
                let o = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any]
                return .accepted(duplicate: (o?["duplicate"] as? Bool) ?? false)
            case 503: return .bossOffline
            case 401, 403: return .unauthorized
            default: return .failed("HTTP \(r.status) \(String(decoding: r.body.prefix(120), as: UTF8.self))")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    public func postUtterance(id: String, text: String, mode: String, lang: String?, sessions: [SessionInfo]) async -> PostResult {
        var b: [String: Any] = ["id": id, "text": text, "mode": mode]
        if let lang { b["lang"] = lang }
        // Live sessions (same filter as the tower) so Boss can route without a tool round trip.
        b["sessions"] = sessions.map { ["name": $0.name, "cwd": $0.cwd, "status": $0.status] }
        return await post("/utterance", b)
    }
    public func postAnswer(questionID: String, text: String) async -> PostResult {
        await post("/answer", ["question_id": questionID, "text": text])
    }
    public func postUndo(utteranceID: String) async -> PostResult {
        await post("/undo", ["utterance_id": utteranceID])
    }
    public func cancelRoute(routeID: String) async -> PostResult {
        await post("/cancel_route", ["route_id": routeID])
    }
    /// The live sessions ride along so the channel can resolve nicknames even before any utterance.
    public func getState(sessions: [SessionInfo]) async -> ChannelState? {
        var path = "/state"
        if !sessions.isEmpty,
           let d = try? JSONSerialization.data(withJSONObject: sessions.map { ["name": $0.name, "cwd": $0.cwd, "status": $0.status] }),
           let q = String(data: d, encoding: .utf8)?.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
            path += "?sessions=\(q)"
        }
        guard let r = try? await transport.send(request("GET", path)), r.status == 200 else { return nil }
        return ChannelState.decode(r.body)
    }
    public func health() async -> Bool? {
        guard let r = try? await transport.send(request("GET", "/health")), r.status == 200,
              let o = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] else { return nil }
        return (o["boss_connected"] as? Bool) ?? false
    }
}
