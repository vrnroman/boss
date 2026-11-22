import Foundation

public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]   // lowercased names
    public var body: Data

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
        self.method = method; self.path = path; self.query = query; self.headers = headers; self.body = body
    }

    public func json() -> [String: Any]? {
        if body.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}

public struct HTTPResponse: Equatable, Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }

    public static func json(_ status: Int, _ obj: Any) -> HTTPResponse {
        let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: d)
    }
    public static func encodable<T: Encodable>(_ status: Int, _ v: T) -> HTTPResponse {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        let d = (try? enc.encode(v)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: d)
    }
    public static func error(_ status: Int, _ msg: String) -> HTTPResponse { json(status, ["error": msg]) }

    static func reason(_ s: Int) -> String {
        switch s {
        case 200: return "OK"; case 202: return "Accepted"; case 400: return "Bad Request"
        case 401: return "Unauthorized"; case 403: return "Forbidden"; case 404: return "Not Found"
        case 405: return "Method Not Allowed"; case 409: return "Conflict"; case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"; case 503: return "Service Unavailable"
        default: return "Status"
        }
    }

    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        var h = headers
        h["Content-Length"] = String(body.count)
        h["Connection"] = "close"
        for k in h.keys.sorted() { head += "\(k): \(h[k]!)\r\n" }
        head += "\r\n"
        var d = Data(head.utf8)
        d.append(body)
        return d
    }
}

public enum HTTPParseError: Error, Equatable { case malformed, tooLarge, unsupported }

/// Incremental HTTP/1.1 request parser (Content-Length bodies; no chunked uploads).
public struct HTTPRequestParser: Sendable {
    public var maxHeaderBytes = 16 * 1024
    public var maxBodyBytes = 1024 * 1024
    private var buf = Data()
    public init() {}

    /// Feed bytes; returns a request once complete, nil if more bytes are needed.
    public mutating func feed(_ d: Data) throws -> HTTPRequest? {
        buf.append(d)
        guard let sep = buf.range(of: Data("\r\n\r\n".utf8)) else {
            if buf.count > maxHeaderBytes { throw HTTPParseError.tooLarge }
            return nil
        }
        let headText = String(decoding: buf[buf.startIndex..<sep.lowerBound], as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { throw HTTPParseError.malformed }
        var headers: [String: String] = [:]
        for l in lines where !l.isEmpty {
            guard let c = l.firstIndex(of: ":") else { throw HTTPParseError.malformed }
            headers[l[..<c].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { throw HTTPParseError.unsupported }
        let len = Int(headers["content-length"] ?? "0") ?? -1
        guard len >= 0 else { throw HTTPParseError.malformed }
        guard len <= maxBodyBytes else { throw HTTPParseError.tooLarge }
        let bodyStart = sep.upperBound
        guard buf.count - (bodyStart - buf.startIndex) >= len else { return nil }
        let body = Data(buf[bodyStart..<(bodyStart + len)])
        let target = String(requestLine[1])
        var path = target, query: [String: String] = [:]
        if let comps = URLComponents(string: target) {
            path = comps.path.isEmpty ? "/" : comps.path
            for q in comps.queryItems ?? [] { query[q.name] = q.value ?? "" }
        }
        buf.removeAll()
        return HTTPRequest(method: String(requestLine[0]).uppercased(), path: path, query: query, headers: headers, body: body)
    }
}
