import Foundation
import Network
import BossCore

/// 127.0.0.1:8789 debug control (only with BOSS_DEBUG_CONTROL=1 or defaults debugControl=YES).
@MainActor
final class DebugServer {
    private var listener: NWListener?
    private let router: DebugControlRouter
    private(set) var listening = false

    init(router: DebugControlRouter) { self.router = router }

    func start(port: UInt16 = UInt16(Ports.debugControl)) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in self?.accept(conn) }
        }
        l.stateUpdateHandler = { [weak self] st in
            Task { @MainActor in
                switch st {
                case .ready: self?.listening = true
                case .failed(let e): self?.listening = false; NSLog("Boss: debug control failed: \(e)")
                default: break
                }
            }
        }
        l.start(queue: .main)
        listener = l
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .main)
        var parser = HTTPRequestParser()
        func receive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
                MainActor.assumeIsolated {
                    guard let self else { conn.cancel(); return }
                    if let data, !data.isEmpty {
                        do {
                            if let req = try parser.feed(data) {
                                Task { @MainActor in
                                    let resp = await self.router.route(req)
                                    conn.send(content: resp.serialized(), completion: .contentProcessed { _ in conn.cancel() })
                                }
                                return
                            }
                        } catch {
                            conn.send(content: HTTPResponse.error(400, "bad request").serialized(),
                                      completion: .contentProcessed { _ in conn.cancel() })
                            return
                        }
                    }
                    if done || err != nil { conn.cancel(); return }
                    receive()
                }
            }
        }
        receive()
    }
}
