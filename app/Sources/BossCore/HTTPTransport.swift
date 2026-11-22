import Foundation

public struct HTTPResult: Sendable {
    public var status: Int
    public var body: Data
    public var headers: [String: String]
    public init(status: Int, body: Data, headers: [String: String] = [:]) {
        self.status = status; self.body = body; self.headers = headers
    }
}

/// Injected HTTP so every client is unit-testable.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResult
}

public struct URLSessionTransport: HTTPTransport {
    public let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func send(_ request: URLRequest) async throws -> HTTPResult {
        let (data, resp) = try await session.data(for: request)
        let http = resp as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (k, v) in http?.allHeaderFields ?? [:] { headers[String(describing: k).lowercased()] = String(describing: v) }
        return HTTPResult(status: http?.statusCode ?? 0, body: data, headers: headers)
    }
}
