import Foundation

public struct SpeechItem: Equatable, Sendable, Codable {
    public enum Priority: Int, Codable, Sendable { case question = 0, report = 1 }
    public var id: String
    public var text: String          // already formatted "<session>: <text>"
    public var lang: String?
    public var priority: Priority
    /// Set for question items: the question to open the answer window for after speaking.
    public var questionID: String?
    public init(id: String, text: String, lang: String?, priority: Priority, questionID: String? = nil) {
        self.id = id; self.text = text; self.lang = lang; self.priority = priority; self.questionID = questionID
    }

    /// Text as a voice should read it: the macOS Russian voice says "backslash" for « », so quote
    /// marks and backslashes are dropped (found in a real run).
    public static func speakable(_ text: String) -> String {
        var t = text
        for ch in ["«", "»", "„", "“", "”", "\\"] { t = t.replacingOccurrences(of: ch, with: "") }
        return t.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    public static func format(session: String?, text: String) -> String {
        guard let s = session?.trimmingCharacters(in: .whitespaces), !s.isEmpty, s.lowercased() != "boss" else { return text }
        if text.lowercased().hasPrefix(s.lowercased() + ":") { return text }
        return "\(s): \(text)"
    }
}

/// Log entry for `GET /spoken`.
public struct SpokenEntry: Codable, Equatable, Sendable {
    public var text: String
    public var lang: String?
    public var at: Date
    public var muted: Bool
    public var priority: String
}

/// One utterance at a time; questions jump ahead of reports (FIFO inside a priority);
/// paused while recording; mute drops speech (cards still appear).
public struct SpeechQueue: Sendable {
    public private(set) var pending: [SpeechItem] = []
    public private(set) var current: SpeechItem?
    public var paused = false
    public var muted = false
    public private(set) var log: [SpokenEntry] = []
    public private(set) var lastSpoken: SpeechItem?

    public init() {}

    /// Returns false if dropped (muted or duplicate id).
    @discardableResult
    public mutating func enqueue(_ item: SpeechItem, at now: Date) -> Bool {
        log.append(SpokenEntry(text: item.text, lang: item.lang, at: now, muted: muted,
                               priority: item.priority == .question ? "question" : "report"))
        if log.count > 500 { log.removeFirst(log.count - 500) }
        if muted { return false }
        if current?.id == item.id || pending.contains(where: { $0.id == item.id }) { return false }
        // insert after the last item with the same or higher priority
        let idx = pending.lastIndex(where: { $0.priority.rawValue <= item.priority.rawValue }).map { $0 + 1 } ?? 0
        pending.insert(item, at: idx)
        return true
    }

    /// The next item to start, if nothing is playing and we are not paused.
    public mutating func startNext() -> SpeechItem? {
        guard current == nil, !paused, !pending.isEmpty else { return nil }
        let item = pending.removeFirst()
        current = item
        return item
    }

    public mutating func finishCurrent() {
        if let c = current { lastSpoken = c }
        current = nil
    }

    /// Mute: clears what is waiting (they stay as cards).
    public mutating func setMuted(_ m: Bool) {
        muted = m
        if m { pending.removeAll() }
    }

    /// Repeat: put the last spoken item at the front.
    public mutating func repeatLast() -> Bool {
        guard let l = lastSpoken, !muted else { return false }
        var again = l
        again.id = l.id + "-r\(Int.random(in: 0..<1_000_000))"
        again.questionID = nil
        pending.insert(again, at: 0)
        return true
    }

    public mutating func clearLog() { log.removeAll() }
}
