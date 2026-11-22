import Foundation

public struct Link: Codable, Equatable, Sendable, Hashable {
    public var title: String
    public var url: String
    public init(title: String, url: String) { self.title = title; self.url = url }
}

public struct SayEvent: Equatable, Sendable {
    public var id: String
    public var text: String
    public var links: [Link]
    public var speak: Bool
    public var session: String?
    public var lang: String?
    public var kind: String   // report | info | status
    public var at: Date?
}

public struct AskEvent: Equatable, Sendable {
    public var questionID: String
    public var question: String
    public var choices: [String]
    public var aboutID: String?
    public var session: String?
    public var lang: String?
    public var at: Date?
}

public struct RoutedEvent: Equatable, Sendable {
    public var utteranceID: String
    public var target: String
    public var status: String   // sent | delivered | failed | asking | ignored
    public var note: String?
}

public struct ConfirmEvent: Equatable, Sendable {
    public var routeID: String
    public var utteranceID: String
    public var target: String
    public var reason: String
    public var windowMs: Int
}

/// A decoded SSE event from `GET /events`.
public enum ChannelEvent: Equatable, Sendable {
    case say(SayEvent)
    case ask(AskEvent)
    case routed(RoutedEvent)
    case confirm(ConfirmEvent)
    case boss(connected: Bool)
    case unknown(type: String)

    public static func decode(type: String, data: String) -> ChannelEvent? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any] else { return nil }
        func s(_ k: String) -> String? { (obj[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let at = Timestamp.parse(obj["at"])
        switch type {
        case "say":
            guard let text = obj["text"] as? String else { return nil }
            let links = (obj["links"] as? [[String: Any]] ?? []).compactMap { l -> Link? in
                guard let u = l["url"] as? String else { return nil }
                return Link(title: (l["title"] as? String) ?? u, url: u)
            }
            let id = s("id") ?? (obj["seq"].map { "say-\($0)" }) ?? UUID().uuidString
            return .say(SayEvent(id: id, text: text, links: links, speak: (obj["speak"] as? Bool) ?? true,
                                 session: s("session"), lang: s("lang"), kind: s("kind") ?? "report", at: at))
        case "ask":
            guard let qid = s("question_id"), let q = obj["question"] as? String else { return nil }
            return .ask(AskEvent(questionID: qid, question: q, choices: (obj["choices"] as? [String]) ?? [],
                                 aboutID: s("about_id"), session: s("session"), lang: s("lang"), at: at))
        case "routed":
            guard let uid = s("utterance_id") else { return nil }
            return .routed(RoutedEvent(utteranceID: uid, target: s("target") ?? "", status: s("status") ?? "sent", note: s("note")))
        case "confirm":
            guard let rid = s("route_id") else { return nil }
            let w = (obj["window_ms"] as? NSNumber)?.intValue ?? 2500
            return .confirm(ConfirmEvent(routeID: rid, utteranceID: s("utterance_id") ?? "", target: s("target") ?? "",
                                         reason: s("reason") ?? "", windowMs: w))
        case "boss":
            return .boss(connected: (obj["connected"] as? Bool) ?? false)
        default:
            return .unknown(type: type)
        }
    }
}

/// `GET /state`, decoded leniently (unknown fields ignored, missing ones defaulted).
public struct ChannelState: Equatable, Sendable {
    public struct Question: Equatable, Sendable {
        public var questionID: String
        public var question: String
        public var choices: [String]
        public var session: String?
        public var aboutID: String?
        public var at: Date?
    }
    public struct Report: Equatable, Sendable { public var text: String; public var at: Date? }
    public struct Ledger: Equatable, Sendable { public var blind: Int; public var misses: Int; public var graduated: Bool }
    public struct Route: Equatable, Sendable {
        public var routeID: String; public var utteranceID: String; public var target: String; public var status: String?; public var at: Date?
    }

    public var routes: [Route] = []
    public var questions: [Question] = []
    public var reports: [String: Report] = [:]
    public var ledger: [String: Ledger] = [:]
    public var humor: Int?
    /// session name -> the nickname Roman gave it.
    public var nicknames: [String: String] = [:]

    public init() {}
    public init(routes: [Route] = [], questions: [Question] = [], reports: [String: Report] = [:], ledger: [String: Ledger] = [:]) {
        self.routes = routes; self.questions = questions; self.reports = reports; self.ledger = ledger
    }

    public static func decode(_ data: Data) -> ChannelState? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var st = ChannelState()
        st.routes = (o["routes"] as? [[String: Any]] ?? []).map {
            Route(routeID: $0["route_id"] as? String ?? "", utteranceID: $0["utterance_id"] as? String ?? "",
                  target: $0["target"] as? String ?? "", status: ($0["status"] as? String) ?? ($0["decision"] as? String),
                  at: Timestamp.parse($0["at"]))
        }
        st.questions = (o["questions"] as? [[String: Any]] ?? []).compactMap {
            guard let id = $0["question_id"] as? String else { return nil }
            return Question(questionID: id, question: $0["question"] as? String ?? "", choices: $0["choices"] as? [String] ?? [],
                            session: $0["session"] as? String, aboutID: $0["about_id"] as? String,
                            at: Timestamp.parse($0["at"] ?? $0["asked_at"] ?? $0["created_at"]))
        }
        for (k, v) in o["reports"] as? [String: [String: Any]] ?? [:] {
            st.reports[k] = Report(text: v["text"] as? String ?? "", at: Timestamp.parse(v["at"]))
        }
        for (k, v) in o["ledger"] as? [String: [String: Any]] ?? [:] {
            st.ledger[k] = Ledger(blind: (v["blind"] as? NSNumber)?.intValue ?? 0,
                                  misses: (v["misses"] as? NSNumber)?.intValue ?? 0,
                                  graduated: v["graduated"] as? Bool ?? false)
        }
        st.humor = ((o["settings"] as? [String: Any])?["humor"] as? NSNumber)?.intValue
        st.nicknames = o["nicknames"] as? [String: String] ?? [:]
        return st
    }

    /// Totals across all targets for the pill: "routed blind 14/15".
    public var blindTotals: (blind: Int, total: Int) {
        let b = ledger.values.reduce(0) { $0 + $1.blind }
        let m = ledger.values.reduce(0) { $0 + $1.misses }
        return (b, b + m)
    }
}
