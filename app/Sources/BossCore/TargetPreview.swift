import Foundation

/// Matches a partial live transcript ("payments: rename…", "гейтвей, запусти…") to a live
/// session name, for the "→ name" chip shown while Roman is still talking.
public enum TargetPreview {
    static let translit: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "yo", "ж": "zh", "з": "z",
        "и": "i", "й": "y", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r",
        "с": "s", "т": "t", "у": "u", "ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "sch",
        "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
    ]

    /// Cyrillic → Latin (simple, lossy).
    public static func transliterate(_ s: String) -> String {
        var out = ""
        for ch in s.lowercased() { out += translit[ch] ?? String(ch) }
        return out
    }

    /// Consonant skeleton used to compare across spellings/scripts: "gateway" and "geytvey" → "gtv".
    public static func skeleton(_ word: String) -> String {
        var w = transliterate(word)
        for (a, b) in [("ph", "f"), ("ck", "k"), ("kh", "h"), ("ch", "c"), ("sh", "s"), ("ts", "s"), ("x", "ks"), ("qu", "kv")] {
            w = w.replacingOccurrences(of: a, with: b)
        }
        var out = ""
        for ch in w {
            var c = ch
            switch c {
            case "w": c = "v"
            case "c", "q": c = "k"
            case "z": c = "s"
            case "j": c = "g"
            default: break
            }
            if "aeiouyh".contains(c) { continue }
            guard c.isLetter || c.isNumber else { continue }
            if out.last != c { out.append(c) }
        }
        return out
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
    }

    /// Does spoken `w` sound like name token `t`?
    static func similar(_ w: String, _ t: String) -> Bool {
        let lw = transliterate(w)
        if lw == t { return true }
        if t.count >= 4 && lw.count >= 4 {
            let d = levenshtein(lw, t)
            if Double(d) / Double(max(lw.count, t.count)) <= 0.25 { return true }
        }
        let sw = skeleton(w), st = skeleton(t)
        if st.count >= 3 && sw == st { return true }
        // Short names spoken in Russian ("сайт" → site): same skeleton is enough.
        let cyrillic = w.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        if cyrillic && st.count == 2 && sw == st && lw.count <= t.count + 1 { return true }
        if st.count >= 5 && levenshtein(sw, st) <= 1 { return true }
        return false
    }

    /// The best matching session name or nil. Looks at the first `window` words.
    public static func match(transcript: String, sessions: [String], window: Int = 6) -> String? {
        let ws = Array(words(transcript).prefix(window))
        guard !ws.isEmpty else { return nil }
        struct Cand { var name: String; var pos: Int; var tokens: Int }
        var best: [Cand] = []
        for name in sessions where name.lowercased() != "boss" {
            let toks = words(name)
            guard !toks.isEmpty else { continue }
            // full multi-token sequence ("titan otc"), or the whole name spoken as one word ("titanotc")
            for i in ws.indices {
                if i + toks.count <= ws.count, zip(ws[i..<(i + toks.count)], toks).allSatisfy({ similar($0, $1) }) {
                    best.append(Cand(name: name, pos: i, tokens: toks.count)); break
                }
                if toks.count > 1, similar(ws[i], toks.joined()) {
                    best.append(Cand(name: name, pos: i, tokens: toks.count)); break
                }
            }
        }
        // Distinctive first token ("titan" for "titan-otc") counts if no other session shares it.
        if best.isEmpty {
            for name in sessions where name.lowercased() != "boss" {
                let toks = words(name)
                guard toks.count > 1, let first = toks.first, first.count >= 4, !first.allSatisfy(\.isNumber) else { continue }
                let shared = sessions.filter { $0 != name && words($0).first == first }.count
                if shared == 0, let i = ws.firstIndex(where: { similar($0, first) }) {
                    best.append(Cand(name: name, pos: i, tokens: 1))
                }
            }
        }
        return best.sorted { $0.pos != $1.pos ? $0.pos < $1.pos : $0.tokens > $1.tokens }.first?.name
    }
}
