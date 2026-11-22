import Foundation

/// Outbox entry: `<id>.json` next to `<id>.wav`. Written BEFORE transcription.
public struct OutboxItem: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case saved, transcribed, sent, failed }
    public var id: String
    public var created_at: String
    public var state: State
    public var text: String?
    public var lang: String?
    /// "talk" | "handsfree" | "feedback" | "answer"
    public var mode: String
    /// Set when this utterance answers a question (posted to /answer, not /utterance).
    public var question_id: String?
    public var attempts: Int
    public var error: String?
    /// `true` = never retry (filtered as silent / hallucination / undecodable).
    public var final: Bool?
    public var updated_at: String?

    public init(id: String, created_at: String, state: State = .saved, mode: String = "talk",
                question_id: String? = nil) {
        self.id = id; self.created_at = created_at; self.state = state; self.mode = mode
        self.question_id = question_id; self.attempts = 0
    }

    public var isRetryable: Bool { state != .sent && final != true }
}

public enum OutboxID {
    /// "u-20261122-210102-3fa9c1": sortable, unique, safe as a filename.
    public static func make(now: Date = Date(), random: String = String(UUID().uuidString.prefix(6)).lowercased()) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyyMMdd-HHmmssSSS"
        return "u-\(df.string(from: now))-\(random)"
    }
    public static func isValid(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } && !id.hasPrefix(".")
    }
}

public enum OutboxError: Error, Equatable { case invalidID, missing }

/// File-backed outbox. All writes are atomic.
public final class Outbox: @unchecked Sendable {
    public let dir: URL
    private let lock = NSLock()
    private let clock: () -> Date

    public init(dir: URL, clock: @escaping () -> Date = Date.init) {
        self.dir = dir
        self.clock = clock
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    public func wavURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).wav") }
    public func jsonURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).json") }

    /// Save audio + metadata. Idempotent: an existing id is returned unchanged.
    @discardableResult
    public func save(id: String, wav: Data, mode: String = "talk", questionID: String? = nil) throws -> OutboxItem {
        guard OutboxID.isValid(id) else { throw OutboxError.invalidID }
        lock.lock(); defer { lock.unlock() }
        if let existing = readUnlocked(id) { return existing }
        try wav.write(to: wavURL(id), options: .atomic)
        let item = OutboxItem(id: id, created_at: Timestamp.iso(clock()), mode: mode, question_id: questionID)
        try writeUnlocked(item)
        return item
    }

    public func read(_ id: String) -> OutboxItem? {
        lock.lock(); defer { lock.unlock() }
        return readUnlocked(id)
    }

    public func wav(_ id: String) -> Data? { try? Data(contentsOf: wavURL(id)) }

    /// Read-modify-write one item.
    @discardableResult
    public func update(_ id: String, _ change: (inout OutboxItem) -> Void) throws -> OutboxItem {
        lock.lock(); defer { lock.unlock() }
        guard var item = readUnlocked(id) else { throw OutboxError.missing }
        change(&item)
        item.updated_at = Timestamp.iso(clock())
        try writeUnlocked(item)
        return item
    }

    public func all() -> [OutboxItem] {
        lock.lock(); defer { lock.unlock() }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }
            .compactMap { readUnlocked(String($0.dropLast(5))) }
            .sorted { $0.created_at < $1.created_at }
    }

    /// Items that still need to reach the channel, oldest first.
    public func unsent() -> [OutboxItem] { all().filter { $0.isRetryable } }

    private func readUnlocked(_ id: String) -> OutboxItem? {
        guard let d = try? Data(contentsOf: jsonURL(id)) else { return nil }
        return try? JSONDecoder().decode(OutboxItem.self, from: d)
    }
    private func writeUnlocked(_ item: OutboxItem) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        try enc.encode(item).write(to: jsonURL(item.id), options: .atomic)
    }
}

/// When to retry unsent outbox items: every `interval` seconds, and immediately when Boss reconnects.
public struct RetryPolicy: Sendable {
    public var interval: TimeInterval
    public var maxTranscribeAttempts: Int
    private var lastRun: TimeInterval?
    public init(interval: TimeInterval = 5, maxTranscribeAttempts: Int = 5) {
        self.interval = interval; self.maxTranscribeAttempts = maxTranscribeAttempts
    }
    /// Called from a periodic timer.
    public mutating func shouldRun(at t: TimeInterval) -> Bool {
        if let l = lastRun, t - l < interval - 1e-9 { return false }
        lastRun = t
        return true
    }
    /// Boss connected: run now and restart the interval.
    public mutating func bossReconnected(at t: TimeInterval) -> Bool {
        lastRun = t
        return true
    }
}
