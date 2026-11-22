import Foundation

public enum CardKind: String, Codable, Sendable { case youSaid, report, question, confirm, system }

/// One feed card. A flat struct so `/feed` can return it as JSON as-is.
public struct Card: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: CardKind
    public var createdAt: Date
    public var text: String
    public var session: String?
    public var lang: String?
    public var links: [Link] = []

    // You said
    public var utteranceID: String?
    public var target: String?
    /// saved | transcribing | sent | delivered | failed | asking | ignored | undone | dropped
    public var status: String?
    public var note: String?
    public var mode: String?
    public var answersQuestionID: String?

    // Question
    public var questionID: String?
    public var choices: [String] = []
    public var answered: Bool?
    public var answer: String?

    // Confirm
    public var routeID: String?
    public var reason: String?
    public var windowMs: Int?
    public var deadline: Date?
    public var cancelled: Bool?

    // System
    public var level: String?     // info | warning | error
    public var action: String?    // e.g. "grantInputMonitoring", "restartBoss"

    public init(id: String, kind: CardKind, createdAt: Date, text: String) {
        self.id = id; self.kind = kind; self.createdAt = createdAt; self.text = text
    }

    public var langChip: String? { lang.map { $0.uppercased() } }
}

/// The feed: newest first, applying channel events and local outbox progress.
public struct FeedModel: Sendable {
    public private(set) var cards: [Card] = []
    public var limit: Int
    private var seenEventKeys = Set<String>()

    public init(limit: Int = 200) { self.limit = limit }

    public func card(_ id: String) -> Card? { cards.first { $0.id == id } }
    public var newestOpenQuestion: Card? { cards.first { $0.kind == .question && $0.answered != true } }

    private mutating func insert(_ c: Card) {
        if let i = cards.firstIndex(where: { $0.id == c.id }) { cards[i] = c; return }
        cards.insert(c, at: 0)
        if cards.count > limit { cards.removeLast(cards.count - limit) }
    }
    private mutating func modify(_ id: String, _ f: (inout Card) -> Void) {
        if let i = cards.firstIndex(where: { $0.id == id }) { f(&cards[i]) }
    }

    // MARK: local events

    /// A recording was saved to the outbox (before transcription).
    public mutating func addRecording(utteranceID: String, mode: String, answersQuestionID: String?, at: Date) {
        guard card("you-\(utteranceID)") == nil else { return }
        var c = Card(id: "you-\(utteranceID)", kind: .youSaid, createdAt: at, text: "…")
        c.utteranceID = utteranceID; c.status = "saved"; c.mode = mode; c.answersQuestionID = answersQuestionID
        insert(c)
    }
    public mutating func setTranscript(utteranceID: String, text: String, lang: String?) {
        modify("you-\(utteranceID)") { $0.text = text; $0.lang = lang; if $0.status == "saved" { $0.status = "transcribing" } }
    }
    public mutating func setStatus(utteranceID: String, _ status: String, note: String? = nil) {
        modify("you-\(utteranceID)") { c in
            // never move a card backwards from delivered to sent
            if c.status == "delivered" && status == "sent" { return }
            c.status = status
            if let note { c.note = note }
        }
    }
    public mutating func markAnswered(questionID: String, answer: String) {
        modify("q-\(questionID)") { $0.answered = true; $0.answer = answer }
    }
    public mutating func cancelConfirm(routeID: String) {
        modify("c-\(routeID)") { $0.cancelled = true }
    }
    @discardableResult
    public mutating func addSystem(_ text: String, level: String = "warning", action: String? = nil, at: Date, key: String? = nil) -> String {
        let id = "sys-" + (key ?? UUID().uuidString)
        var c = Card(id: id, kind: .system, createdAt: at, text: text)
        c.level = level; c.action = action
        if let key, card(id) != nil {   // keyed system cards are updated, not duplicated
            modify(id) { $0.text = text; $0.level = level }
            return id
        }
        insert(c)
        return id
    }
    public mutating func remove(_ id: String) { cards.removeAll { $0.id == id } }

    // MARK: channel events

    /// Applies one SSE event. Returns false if it was a duplicate (replayed) event and nothing changed.
    @discardableResult
    public mutating func apply(_ e: ChannelEvent, at now: Date) -> Bool {
        switch e {
        case .say(let s):
            guard seenEventKeys.insert("say:\(s.id)").inserted else { return false }
            var c = Card(id: "r-\(s.id)", kind: .report, createdAt: s.at ?? now, text: s.text)
            c.session = s.session; c.lang = s.lang; c.links = s.links
            c.note = s.kind
            insert(c)
        case .ask(let a):
            guard seenEventKeys.insert("ask:\(a.questionID)").inserted else { return false }
            var c = Card(id: "q-\(a.questionID)", kind: .question, createdAt: a.at ?? now, text: a.question)
            c.questionID = a.questionID; c.choices = a.choices; c.session = a.session; c.lang = a.lang
            c.answered = false; c.utteranceID = a.aboutID
            insert(c)
            if let about = a.aboutID { setStatus(utteranceID: about, "asking") }
        case .routed(let r):
            if card("you-\(r.utteranceID)") == nil {
                // routed for an utterance we did not record (e.g. after app restart): show it anyway
                var c = Card(id: "you-\(r.utteranceID)", kind: .youSaid, createdAt: now, text: "…")
                c.utteranceID = r.utteranceID
                insert(c)
            }
            modify("you-\(r.utteranceID)") { c in
                if !r.target.isEmpty { c.target = r.target }
                if c.status == "undone" { return }
                if c.status == "delivered" && r.status == "sent" { return }
                c.status = r.status
                if let n = r.note { c.note = n }
            }
            // A decided route ends any confirm countdown for this utterance.
            for i in cards.indices where cards[i].kind == .confirm && cards[i].utteranceID == r.utteranceID {
                cards[i].deadline = cards[i].deadline.map { min($0, now) }
            }
        case .confirm(let c0):
            guard seenEventKeys.insert("confirm:\(c0.routeID)").inserted else { return false }
            var c = Card(id: "c-\(c0.routeID)", kind: .confirm, createdAt: now, text: "→ \(c0.target)")
            c.routeID = c0.routeID; c.utteranceID = c0.utteranceID; c.target = c0.target; c.reason = c0.reason
            c.windowMs = c0.windowMs; c.deadline = now.addingTimeInterval(Double(c0.windowMs) / 1000); c.cancelled = false
            insert(c)
            modify("you-\(c0.utteranceID)") { $0.target = c0.target }
        case .boss, .unknown:
            return false
        }
        return true
    }

    /// Text of the last route for the pill: "→ payments".
    public var lastRoute: String? {
        cards.first { $0.kind == .youSaid && $0.target != nil }.flatMap { $0.target.map { "→ \($0)" } }
    }
}
