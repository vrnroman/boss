import Foundation

public struct SSEMessage: Equatable, Sendable {
    public var id: String?
    public var event: String
    public var data: String
    public init(id: String?, event: String, data: String) { self.id = id; self.event = event; self.data = data }
}

/// Incremental Server-Sent Events parser (WHATWG rules): handles CRLF / CR / LF line endings
/// split across chunks, multi-line `data:`, `id:`, `event:`, `retry:`, comment lines and
/// UTF-8 sequences split across chunks.
public struct SSEParser: Sendable {
    private var bytes: [UInt8] = []
    private var lastWasCR = false
    private var dataLines: [String] = []
    private var eventType = ""
    private var pendingID: String?
    private var sawField = false
    /// The last event id seen (persists across events, like EventSource.lastEventId).
    public private(set) var lastEventID: String?
    /// Server-requested reconnect delay in ms.
    public private(set) var retryMs: Int?
    /// Count of comment lines (keepalives) seen.
    public private(set) var comments = 0

    public init() {}

    public mutating func feed(_ data: Data) -> [SSEMessage] { feed([UInt8](data)) }
    public mutating func feed(_ s: String) -> [SSEMessage] { feed(Array(s.utf8)) }

    public mutating func feed(_ chunk: [UInt8]) -> [SSEMessage] {
        var out: [SSEMessage] = []
        for b in chunk {
            if b == 0x0A { // LF
                if lastWasCR { lastWasCR = false; continue } // second half of CRLF
                if let m = line() { out.append(m) }
            } else if b == 0x0D { // CR
                lastWasCR = true
                if let m = line() { out.append(m) }
            } else {
                lastWasCR = false
                bytes.append(b)
            }
        }
        return out
    }

    private mutating func line() -> SSEMessage? {
        let l = String(decoding: bytes, as: UTF8.self)
        bytes.removeAll(keepingCapacity: true)
        if l.isEmpty { return dispatch() }
        if l.hasPrefix(":") { comments += 1; return nil }
        var field = l, value = ""
        if let c = l.firstIndex(of: ":") {
            field = String(l[..<c])
            value = String(l[l.index(after: c)...])
            if value.hasPrefix(" ") { value.removeFirst() }
        }
        switch field {
        case "data": dataLines.append(value); sawField = true
        case "event": eventType = value
        case "id": if !value.contains("\u{0}") { pendingID = value; lastEventID = value }
        case "retry": if let v = Int(value), v >= 0 { retryMs = v }
        default: break
        }
        return nil
    }

    private mutating func dispatch() -> SSEMessage? {
        defer { dataLines = []; eventType = ""; pendingID = nil; sawField = false }
        guard sawField else { return nil }
        return SSEMessage(id: pendingID ?? lastEventID, event: eventType.isEmpty ? "message" : eventType,
                          data: dataLines.joined(separator: "\n"))
    }
}

/// Exponential reconnect backoff: 0.5, 1, 2, 4 … capped, reset after a good connection.
public struct Backoff: Sendable {
    public var base: Double, cap: Double
    public private(set) var attempt = 0
    public init(base: Double = 0.5, cap: Double = 15) { self.base = base; self.cap = cap }
    public mutating func next() -> Double {
        let d = min(cap, base * pow(2, Double(attempt)))
        attempt += 1
        return d
    }
    public mutating func reset() { attempt = 0 }
}

/// A byte stream source for SSE (real: URLSession; tests: canned chunks).
public protocol SSEStreamSource: Sendable {
    /// Open `GET /events`, passing `lastEventID` as `Last-Event-ID`. Yields raw chunks.
    func open(lastEventID: String?) async throws -> AsyncThrowingStream<Data, Error>
}

public struct URLSessionSSESource: SSEStreamSource {
    public var url: URL
    public var token: @Sendable () -> String?
    public init(url: URL, token: @escaping @Sendable () -> String?) { self.url = url; self.token = token }

    public func open(lastEventID: String?) async throws -> AsyncThrowingStream<Data, Error> {
        var req = URLRequest(url: url, timeoutInterval: 60 * 60 * 24)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let t = token() { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        if let id = lastEventID { req.setValue(id, forHTTPHeaderField: "Last-Event-ID") }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 45   // keepalive ping every 15 s; 45 s of silence = dead
        cfg.timeoutIntervalForResource = 60 * 60 * 24 * 7
        let session = URLSession(configuration: cfg)
        let (bytes, resp) = try await session.bytes(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw TranscriberError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, "events")
        }
        return AsyncThrowingStream { cont in
            let task = Task {
                var buf = Data()
                do {
                    for try await b in bytes {
                        buf.append(b)
                        if b == 0x0A || buf.count >= 4096 { cont.yield(buf); buf.removeAll(keepingCapacity: true) }
                    }
                    if !buf.isEmpty { cont.yield(buf) }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
                session.invalidateAndCancel()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}

/// Keeps an SSE connection alive: parses, reconnects with Last-Event-ID and backoff.
public final class SSEClient: @unchecked Sendable {
    public enum Status: Equatable, Sendable { case connecting, open, closed(String) }
    private let source: SSEStreamSource
    private let sleep: @Sendable (Double) async -> Void
    private var task: Task<Void, Never>?
    public private(set) var lastEventID: String?
    public var onMessage: (@Sendable (SSEMessage) -> Void)?
    public var onStatus: (@Sendable (Status) -> Void)?

    public init(source: SSEStreamSource, lastEventID: String? = nil,
                sleep: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }) {
        self.source = source; self.lastEventID = lastEventID; self.sleep = sleep
    }

    public func start(maxConnections: Int = .max) {
        task?.cancel()
        task = Task { [weak self] in await self?.run(maxConnections: maxConnections) }
    }
    public func stop() { task?.cancel(); task = nil }

    /// Runs until cancelled (or `maxConnections` attempts, for tests).
    public func run(maxConnections: Int = .max) async {
        var backoff = Backoff()
        var n = 0
        while !Task.isCancelled && n < maxConnections {
            n += 1
            onStatus?(.connecting)
            var reason = "ended"
            do {
                let stream = try await source.open(lastEventID: lastEventID)
                onStatus?(.open)
                var parser = SSEParser()
                var gotData = false
                for try await chunk in stream {
                    if !gotData { gotData = true; backoff.reset() }
                    for m in parser.feed(chunk) {
                        if let id = m.id { lastEventID = id }
                        onMessage?(m)
                    }
                    if let r = parser.retryMs { backoff.base = max(0.1, Double(r) / 1000) }
                }
            } catch {
                reason = error.localizedDescription
            }
            onStatus?(.closed(reason))
            if Task.isCancelled || n >= maxConnections { break }
            await sleep(backoff.next())
        }
    }
}
