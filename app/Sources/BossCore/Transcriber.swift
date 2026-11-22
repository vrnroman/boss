import Foundation

public struct Transcript: Equatable, Sendable {
    public var text: String
    /// "en" / "ru" / other ISO code, nil if unknown.
    public var lang: String?
    public init(text: String, lang: String?) { self.text = text; self.lang = lang }
}

public protocol Transcriber: Sendable {
    /// `language` nil = auto-detect.
    func transcribe(wav: Data, prompt: String, language: String?) async throws -> Transcript
}

public enum TranscriberError: Error, Equatable {
    case http(Int, String)
    case badResponse
}

/// multipart/form-data body builder.
public struct MultipartBody: Sendable {
    public let boundary: String
    private var data = Data()
    public init(boundary: String = "boss-" + UUID().uuidString) { self.boundary = boundary }

    public mutating func addField(_ name: String, _ value: String) {
        data.append(Data("--\(boundary)\r\n".utf8))
        data.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        data.append(Data(value.utf8))
        data.append(Data("\r\n".utf8))
    }
    public mutating func addFile(_ name: String, filename: String, contentType: String, _ bytes: Data) {
        data.append(Data("--\(boundary)\r\n".utf8))
        data.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8))
        data.append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
        data.append(bytes)
        data.append(Data("\r\n".utf8))
    }
    public func finalized() -> Data {
        var d = data
        d.append(Data("--\(boundary)--\r\n".utf8))
        return d
    }
    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }
}

public enum LanguageCode {
    /// whisper.cpp verbose_json gives names ("english", "russian"); normalise to ISO codes.
    public static func normalize(_ raw: String?) -> String? {
        guard let r = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !r.isEmpty else { return nil }
        switch r {
        case "english", "en", "en-us", "en_us", "en-gb": return "en"
        case "russian", "ru", "ru-ru", "ru_ru": return "ru"
        case "ukrainian", "uk": return "uk"
        case "german", "de": return "de"
        case "french", "fr": return "fr"
        case "spanish", "es": return "es"
        case "chinese", "zh": return "zh"
        default: return r.count == 2 ? r : nil
        }
    }
    /// Script-based guess when whisper gives no language.
    public static func guess(_ text: String) -> String? {
        var cyr = 0, lat = 0
        for u in text.unicodeScalars {
            if (0x0400...0x04FF).contains(u.value) { cyr += 1 }
            else if (u.value >= 65 && u.value <= 90) || (u.value >= 97 && u.value <= 122) { lat += 1 }
        }
        if cyr == 0 && lat == 0 { return nil }
        return cyr > lat ? "ru" : "en"
    }
}

/// whisper.cpp `whisper-server` client: POST /inference.
public struct WhisperServerTranscriber: Transcriber {
    public var baseURL: URL
    public var transport: HTTPTransport
    public var timeout: TimeInterval
    public init(baseURL: URL = URL(string: "http://127.0.0.1:\(Ports.whisper)")!,
                transport: HTTPTransport = URLSessionTransport(), timeout: TimeInterval = 30) {
        self.baseURL = baseURL; self.transport = transport; self.timeout = timeout
    }

    public func makeRequest(wav: Data, prompt: String, language: String?, boundary: String = "boss-" + UUID().uuidString) -> URLRequest {
        var mp = MultipartBody(boundary: boundary)
        mp.addFile("file", filename: "utterance.wav", contentType: "audio/wav", wav)
        mp.addField("response_format", "verbose_json")
        mp.addField("language", language ?? "auto")
        mp.addField("temperature", "0.0")
        if !prompt.isEmpty { mp.addField("prompt", prompt) }
        var req = URLRequest(url: baseURL.appendingPathComponent("inference"), timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue(mp.contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = mp.finalized()
        return req
    }

    public static func parse(_ data: Data) throws -> Transcript {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscriberError.badResponse
        }
        var text = (obj["text"] as? String) ?? ""
        if text.isEmpty, let segs = obj["segments"] as? [[String: Any]] {
            text = segs.compactMap { $0["text"] as? String }.joined()
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lang = LanguageCode.normalize(obj["language"] as? String) ?? LanguageCode.guess(text)
        return Transcript(text: text, lang: lang)
    }

    public func transcribe(wav: Data, prompt: String, language: String?) async throws -> Transcript {
        let res = try await transport.send(makeRequest(wav: wav, prompt: prompt, language: language))
        guard (200..<300).contains(res.status) else {
            throw TranscriberError.http(res.status, String(decoding: res.body.prefix(200), as: UTF8.self))
        }
        return try Self.parse(res.body)
    }
}

/// Builds whisper's `prompt` so names like "Titan" and "Apigee" come out right.
///
/// Format matters (measured against whisper-server, 2026-11-22): a plain list such as
/// "Sessions: payments, gateway." makes whisper DROP a session name that opens the utterance
/// ("Payments, run the tests" → "Run the tests"), typically the last listed name. Closing each
/// list with "etc" inside parentheses kept the name in 14/14 trials across orders and languages.
public enum VocabularyPrompt {
    public static func build(sessionNames: [String], words: [String], maxChars: Int = 600) -> String {
        var seen = Set<String>()
        func uniq(_ xs: [String]) -> [String] {
            xs.map { $0.trimmingCharacters(in: .whitespaces) }
              .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        }
        var names = uniq(sessionNames.filter { $0.lowercased() != "boss" })
        var extra = uniq(words)
        func render() -> String {
            var parts: [String] = []
            if !names.isEmpty { parts.append("Sessions (" + names.joined(separator: ", ") + ", etc).") }
            if !extra.isEmpty { parts.append("Words (" + extra.joined(separator: ", ") + ", etc).") }
            return parts.joined(separator: " ")
        }
        var s = render()
        // Trim whole entries (never mid-word) until it fits.
        while s.count > maxChars && (!extra.isEmpty || !names.isEmpty) {
            if !extra.isEmpty { extra.removeLast() } else { names.removeLast() }
            s = render()
        }
        return s
    }
}

/// Drops known whisper hallucinations on silence/noise. Matches the WHOLE transcript only,
/// so "Thank you, run the tests" is kept.
public enum HallucinationFilter {
    static let phrases: [String] = [
        "thank you", "thank you very much", "thanks", "thanks for watching", "thank you for watching",
        "thanks for watching and see you next time", "please subscribe", "subscribe to my channel",
        "like and subscribe", "bye", "bye bye", "you", "so", "the end", "uh", "um", "hmm",
        "see you next time", "i'll see you next time",
        "продолжение следует", "спасибо", "спасибо за внимание", "спасибо за просмотр",
        "подписывайтесь на канал", "до новых встреч", "всем пока", "пока",
        "субтитры сделал dimatorzok", "субтитры создавал dimatorzok", "субтитры делал dimatorzok",
        "редактор субтитров а синецкая корректор а егорова", "субтитры подогнал симон",
        "amara org", "субтитры amara org",
    ]
    static let normalizedSet: Set<String> = Set(phrases.map(normalize))

    /// Lowercase, drop [BLANK_AUDIO]-style tags and punctuation, collapse spaces.
    public static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        t = t.replacingOccurrences(of: "\\[[^\\]]*\\]|\\([^)]*\\)|\\*[^*]*\\*", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "ё", with: "е")
        let kept = t.unicodeScalars.map { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// The cleaned text to send, or nil if it should be dropped.
    public static func clean(_ text: String) -> String? {
        let stripped = text.replacingOccurrences(of: "\\[[A-Z_ ]+\\]", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let n = normalize(stripped)
        if n.isEmpty { return nil }
        if normalizedSet.contains(n) { return nil }
        // Repeated hallucination ("Thank you. Thank you. Thank you.")
        for p in normalizedSet where p.count >= 4 {
            let words = n.split(separator: " ").count
            let pw = p.split(separator: " ").count
            if pw > 0 && words % pw == 0 && words > pw {
                let rep = Array(repeating: p, count: words / pw).joined(separator: " ")
                if rep == n { return nil }
            }
        }
        return stripped.split(whereSeparator: { $0 == " " || $0 == "\n" }).joined(separator: " ")
    }
}
