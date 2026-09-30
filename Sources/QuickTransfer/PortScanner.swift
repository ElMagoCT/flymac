import Foundation
import Network

/// Small TCP connect scanner (no nmap on this Mac). Concurrency-limited so a
/// drone's tiny network stack is not flooded.
public struct PortScanResult: Sendable, Hashable, Identifiable {
    public var id: Int { port }
    public var port: Int
    public var open: Bool
    public var latencyMs: Double?
    public var banner: String?
}

public enum PortScanner {
    /// Ports worth trying on an unknown embedded device.
    public static let interestingPorts: [Int] = [
        21, 22, 23, 53, 80, 81, 443, 554, 1935, 2222, 2345, 3000, 5000, 5001, 5353, 5555, 6000, 7000, 7070,
        8000, 8001, 8080, 8081, 8082, 8086, 8088, 8443, 8554, 8888, 9000, 9001, 9090, 9999, 10000, 10001,
        14550, 19001, 19002, 19003, 19004, 19005, 19006, 19007, 19008, 19009, 19010, 19011, 19012, 19013, 19014, 19015, 19016, 19017, 19018, 19019, 19020,
        20000, 30000, 40000, 40001, 40002, 49152, 50000, 61000
    ]

    public static func scan(host: String, ports: [Int] = interestingPorts, timeout: TimeInterval = 0.8,
                            concurrency: Int = 24, grabBanner: Bool = true,
                            progress: (@Sendable (Int, Int) -> Void)? = nil) async -> [PortScanResult] {
        var results: [PortScanResult] = []
        var idx = 0
        var done = 0
        await withTaskGroup(of: PortScanResult.self) { group in
            func addNext() {
                guard idx < ports.count else { return }
                let p = ports[idx]; idx += 1
                group.addTask { await probe(host: host, port: p, timeout: timeout, banner: grabBanner) }
            }
            for _ in 0..<min(concurrency, ports.count) { addNext() }
            for await r in group {
                results.append(r); done += 1
                progress?(done, ports.count)
                addNext()
            }
        }
        return results.sorted { $0.port < $1.port }
    }

    public static func probe(host: String, port: Int, timeout: TimeInterval, banner: Bool) async -> PortScanResult {
        let start = Date()
        let params = NWParameters.tcp
        params.prohibitedInterfaceTypes = [.cellular]
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: params)
        let queue = DispatchQueue(label: "scan.\(port)")
        return await withCheckedContinuation { (c: CheckedContinuation<PortScanResult, Never>) in
            let finished = Locked(false)
            @Sendable func finish(_ r: PortScanResult) {
                guard finished.exchange(true) == false else { return }
                conn.cancel(); c.resume(returning: r)
            }
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    let ms = Date().timeIntervalSince(start) * 1000
                    guard banner else { finish(.init(port: port, open: true, latencyMs: ms)); return }
                    // Poke it like a browser would; many embedded servers only speak when spoken to.
                    let req = "GET / HTTP/1.0\r\nHost: \(host)\r\nUser-Agent: FlyMac-Doctor\r\n\r\n"
                    conn.send(content: Data(req.utf8), completion: .contentProcessed { _ in })
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 512) { data, _, _, _ in
                        let text = data.map { String(decoding: $0.prefix(200), as: UTF8.self).replacingOccurrences(of: "\r", with: "") }
                        finish(.init(port: port, open: true, latencyMs: ms, banner: text?.components(separatedBy: "\n").first))
                    }
                    queue.asyncAfter(deadline: .now() + timeout) { finish(.init(port: port, open: true, latencyMs: ms)) }
                case .failed, .cancelled:
                    finish(.init(port: port, open: false))
                case .waiting:
                    finish(.init(port: port, open: false))
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(.init(port: port, open: false)) }
        }
    }
}

final class Locked<T>: @unchecked Sendable {
    private var v: T; private let l = NSLock()
    init(_ v: T) { self.v = v }
    func exchange(_ n: T) -> T { l.lock(); defer { l.unlock() }; let o = v; v = n; return o }
    var value: T { l.lock(); defer { l.unlock() }; return v }
}
