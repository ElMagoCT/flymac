import Foundation

/// Anything that can carry DUML frames: a USB bulk pipe, a TCP socket, the mock.
public protocol DUMLLink: AnyObject, Sendable {
    var name: String { get }
    /// Raw bytes → parsed frames. Ends when the link closes (unplug, error).
    var incoming: AsyncStream<DUMLPacket> { get }
    func send(_ packet: DUMLPacket) async throws
    func close()
}

/// Every write FlyMac makes goes through here and is logged, so any command
/// sent to real hardware can be audited later. Read-only by construction:
/// `allowedCommands` is a whitelist and the flight-controller "control"
/// command set is never on it.
public actor DUMLSession {
    public struct LogEntry: Sendable, Identifiable {
        public let id = UUID()
        public let date: Date
        public let direction: Direction
        public let packet: DUMLPacket
        public enum Direction: String, Sendable { case sent, received, blocked }
    }

    public let link: DUMLLink
    public private(set) var log: [LogEntry] = []
    public var logLimit = 5000
    private var sequence: UInt16 = UInt16.random(in: 1...0x7FFF)
    private var waiters: [UInt16: CheckedContinuation<DUMLPacket, Error>] = [:]
    private var pushListeners: [UUID: (DUMLPacket) -> Void] = [:]
    private var pumpTask: Task<Void, Never>?

    /// (commandSet, commandID) pairs FlyMac may send. Extend per profile, never
    /// with anything that moves the aircraft.
    public var allowedCommands: Set<UInt16> = [
        key(0x00, 0x00),   // general ping
        key(0x00, 0x01),   // general get version
        key(0x00, 0x27),   // general get device info
    ]

    public static func key(_ set: UInt8, _ id: UInt8) -> UInt16 { UInt16(set) << 8 | UInt16(id) }

    public init(link: DUMLLink) {
        self.link = link
    }

    public func start() {
        guard pumpTask == nil else { return }
        pumpTask = Task { [weak self] in
            guard let self else { return }
            for await p in link.incoming {
                await self.receive(p)
            }
            await self.failAll(DUMLError.linkClosed)
        }
    }

    public func stop() {
        pumpTask?.cancel(); pumpTask = nil
        link.close()
    }

    private func receive(_ p: DUMLPacket) {
        append(.received, p)
        if p.isResponse, let w = waiters.removeValue(forKey: p.sequence) {
            w.resume(returning: p)
        } else {
            for l in pushListeners.values { l(p) }
        }
    }

    private func failAll(_ e: Error) {
        for w in waiters.values { w.resume(throwing: e) }
        waiters.removeAll()
    }

    private func append(_ d: LogEntry.Direction, _ p: DUMLPacket) {
        log.append(LogEntry(date: Date(), direction: d, packet: p))
        if log.count > logLimit { log.removeFirst(log.count - logLimit) }
    }

    public func onPush(_ handler: @escaping @Sendable (DUMLPacket) -> Void) -> UUID {
        let id = UUID(); pushListeners[id] = handler; return id
    }
    public func removePush(_ id: UUID) { pushListeners[id] = nil }

    public enum DUMLError: Error, CustomStringConvertible {
        case notAllowed(set: UInt8, id: UInt8)
        case timeout
        case linkClosed
        public var description: String {
            switch self {
            case .notAllowed(let s, let i): return String(format: "command %02x/%02x is not on the read-only whitelist", s, i)
            case .timeout: return "no response"
            case .linkClosed: return "link closed"
            }
        }
    }

    /// Send a request and wait for the matching response.
    public func request(to receiver: DUMLAddress, from sender: DUMLAddress = .pc, set: UInt8, id: UInt8,
                        payload: [UInt8] = [], timeout: TimeInterval = 1.0) async throws -> DUMLPacket {
        guard allowedCommands.contains(DUMLSession.key(set, id)) else {
            let p = DUMLPacket(sender: sender, receiver: receiver, sequence: 0, commandSet: set, commandID: id, payload: payload)
            append(.blocked, p)
            throw DUMLError.notAllowed(set: set, id: id)
        }
        sequence &+= 1
        let seq = sequence
        let p = DUMLPacket(sender: sender, receiver: receiver, sequence: seq, ackType: .afterExecution,
                           commandSet: set, commandID: id, payload: payload)
        append(.sent, p)
        return try await withThrowingTaskGroup(of: DUMLPacket.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<DUMLPacket, Error>) in
                    Task { await self.addWaiter(seq, c) }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
                throw DUMLError.timeout
            }
            try await link.send(p)
            let first = try await group.next()!
            group.cancelAll()
            await removeWaiter(seq)
            return first
        }
    }

    private func addWaiter(_ seq: UInt16, _ c: CheckedContinuation<DUMLPacket, Error>) { waiters[seq] = c }
    private func removeWaiter(_ seq: UInt16) {
        if let w = waiters.removeValue(forKey: seq) { w.resume(throwing: CancellationError()) }
    }

    /// The safest possible handshake: general/ping then general/get-version,
    /// to each plausible device type. Returns the raw responses for the Doctor.
    public func handshake(targets: [DUMLAddress] = [.rc, .flightController, .camera, .gimbal, .any],
                          timeout: TimeInterval = 0.6) async -> [(target: DUMLAddress, command: String, result: Result<DUMLPacket, Error>)] {
        var out: [(DUMLAddress, String, Result<DUMLPacket, Error>)] = []
        for t in targets {
            for (name, id) in [("ping", UInt8(0x00)), ("get version", UInt8(0x01))] {
                do { out.append((t, name, .success(try await request(to: t, set: 0, id: id, timeout: timeout)))) }
                catch { out.append((t, name, .failure(error))) }
            }
        }
        return out
    }
}

/// Parses the general/get-version (0x00/0x01) response payload as documented
/// in comm_dissector general.lua: `unknown[2] name[16?] …` The layout varies by
/// product, so this only pulls printable runs and any `vMM.mm.rr.bb` pattern.
public enum VersionResponse {
    public static func describe(_ payload: [UInt8]) -> String {
        var strings: [String] = []
        var run: [UInt8] = []
        for b in payload {
            if (0x20...0x7E).contains(b) { run.append(b) } else { if run.count >= 3 { strings.append(String(decoding: run, as: UTF8.self)) }; run = [] }
        }
        if run.count >= 3 { strings.append(String(decoding: run, as: UTF8.self)) }
        var s = strings.joined(separator: " | ")
        // Common trailer: 4 version bytes little-endian at the end.
        if payload.count >= 4 {
            let v = payload.suffix(4).reversed().map(String.init).joined(separator: ".")
            s += s.isEmpty ? "trailer \(v)" : "  trailer \(v)"
        }
        return s
    }
}
