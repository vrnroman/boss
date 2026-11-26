import Foundation
import CoreGraphics

/// One line of a session's chat as Roman wants to see it: what he said, and each turn's final reply
/// (a result, an answer to his question, or a question for him). Narration mid-turn, tool calls,
/// tool output and other sessions' messages are left out.
public struct ChatEntry: Equatable, Sendable, Identifiable {
    public enum Role: String, Sendable { case you, session }
    public enum Kind: String, Sendable {
        case typed      // Roman typed it in that session's terminal (or in the chat window)
        case voice      // Roman said it to Boss, relayed as "Roman (voice): ..."
        case result     // the turn's final reply: work done
        case answer     // the final reply to a question Roman asked
        case question   // the final reply asks Roman something
    }
    public var id: String
    public var role: Role
    public var kind: Kind
    public var text: String
    public var at: Date?

    public init(id: String, role: Role, kind: Kind, text: String, at: Date?) {
        self.id = id; self.role = role; self.kind = kind; self.text = text; self.at = at
    }
}

public enum SessionChat {
    /// `~/.claude/projects/<cwd, every character other than a letter, digit or "-" as "-">/<sessionId>.jsonl`.
    public static func transcriptURL(home: URL, cwd: String, sessionId: String) -> URL {
        let escaped = String(cwd.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" ? $0 : "-" })
        return home.appendingPathComponent(".claude/projects").appendingPathComponent(escaped)
            .appendingPathComponent("\(sessionId).jsonl")
    }

    /// Does Roman's message ask something (so the reply to it is an answer)?
    public static func isQuestion(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.contains("?") { return true }
        let starts = ["what", "why", "how", "where", "when", "which", "who", "is ", "are ", "can ", "could ", "does ",
                      "did ", "should ", "would ", "will ", "any ", "check", "find", "explain", "tell me", "show me",
                      "что", "почему", "как", "где", "когда", "какой", "какая", "какие", "кто", "можно", "есть ли", "проверь", "найди", "объясни", "покажи"]
        return starts.contains { t.hasPrefix($0) }
    }

    /// The final reply asks Roman something when its last paragraph ends with a question mark.
    public static func asksRoman(_ reply: String) -> Bool {
        let paras = reply.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n\n")
        guard let last = paras.last?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return last.hasSuffix("?") || last.hasSuffix("?**") || last.hasSuffix("?*")
    }

    /// Voice relays from Boss: "Roman (voice):\n<words>\n(When done, SendMessage me ...)".
    static func voiceText(_ body: String) -> String? {
        let b = body.trimmingCharacters(in: .whitespacesAndNewlines)
        var rest: Substring
        if b.hasPrefix("Roman (voice) answers:") { rest = b.dropFirst("Roman (voice) answers:".count) }
        else if b.hasPrefix("Roman (voice):") { rest = b.dropFirst("Roman (voice):".count) }
        else { return nil }
        var lines = rest.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Drop the relay's own trailers: the reply instructions and the artifact-content notice.
        if let i = lines.firstIndex(where: { $0.hasPrefix("(When done, SendMessage") || $0.hasPrefix("<artifact-content") }) {
            lines = Array(lines[..<i])
        }
        let t = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    static func texts(_ content: Any?) -> (text: String, images: Int) {
        if let s = content as? String { return (s, 0) }
        guard let parts = content as? [[String: Any]] else { return ("", 0) }
        var out: [String] = []
        var images = 0
        for p in parts {
            switch p["type"] as? String {
            case "text": if let t = p["text"] as? String { out.append(t) }
            case "image": images += 1
            default: break
            }
        }
        return (out.joined(separator: "\n\n"), images)
    }

    /// The chat from transcript lines (JSONL), oldest first, at most `limit` entries.
    public static func parse(_ jsonl: String, limit: Int = 40) -> [ChatEntry] {
        var out: [ChatEntry] = []
        var lastAsk: String?
        for line in jsonl.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let e = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  e["isSidechain"] as? Bool != true else { continue }
            let type = e["type"] as? String
            let id = e["uuid"] as? String ?? UUID().uuidString
            let at = date(e["timestamp"])
            let message = e["message"] as? [String: Any]
            if type == "user" {
                if e["isCompactSummary"] as? Bool == true { continue }
                // A message from another session: only Boss relaying Roman's own words counts.
                if let origin = e["origin"] as? [String: Any], origin["kind"] as? String == "peer" {
                    if let body = origin["body"] as? String, let said = voiceText(body) {
                        out.append(ChatEntry(id: id, role: .you, kind: .voice, text: said, at: at))
                        lastAsk = said
                    }
                    continue
                }
                if e["isMeta"] as? Bool == true { continue }
                let (raw, images) = texts(message?["content"])
                var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.hasPrefix("<") || t.hasPrefix("[Request interrupted") { t = "" }
                if images > 0 { t = ([t] + Array(repeating: "[image]", count: images)).filter { !$0.isEmpty }.joined(separator: " ") }
                guard !t.isEmpty else { continue }
                out.append(ChatEntry(id: id, role: .you, kind: .typed, text: t, at: at))
                lastAsk = t
            } else if type == "assistant" {
                // Only a turn's final reply: mid-turn narration stops for a tool, the reply ends the turn.
                let stop = message?["stop_reason"] as? String
                guard stop == "end_turn" || stop == "stop_sequence" || stop == "max_tokens" else { continue }
                let t = texts(message?["content"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty, t != "No response requested." else { continue }
                let kind: ChatEntry.Kind = lastAsk.map(isQuestion) == true ? .answer : asksRoman(t) ? .question : .result
                out.append(ChatEntry(id: id, role: .session, kind: kind, text: t, at: at))
                lastAsk = nil
            }
        }
        return Array(out.suffix(limit))
    }

    /// Reads the end of the transcript (the last `maxBytes`) and parses it. Empty when unreadable.
    public static func load(url: URL, maxBytes: Int = 2_000_000, limit: Int = 40) -> [ChatEntry] {
        guard let text = tail(url: url, maxBytes: maxBytes) else { return [] }
        return parse(text, limit: limit)
    }

    /// The last `maxBytes` of a file as text, without the line the cut went through.
    static func tail(url: URL, maxBytes: Int) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd() else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) } // a cut first line
        return text
    }
}

/// Where the chat window goes: beside the panel, the panel's height, on the right when it fits,
/// else on the left, else on the roomier side kept on screen.
public enum ChatPlacement {
    public static func frame(panel f: CGRect, screen vf: CGRect, width: CGFloat, gap: CGFloat = 8) -> CGRect {
        let roomRight = vf.maxX - (f.maxX + gap)
        let roomLeft = (f.minX - gap) - vf.minX
        var x: CGFloat
        if roomRight >= width { x = f.maxX + gap }
        else if roomLeft >= width { x = f.minX - gap - width }
        else { x = roomRight >= roomLeft ? vf.maxX - width : vf.minX }
        x = min(max(x, vf.minX), vf.maxX - width)
        return CGRect(x: x, y: f.minY, width: width, height: f.height)
    }
}
