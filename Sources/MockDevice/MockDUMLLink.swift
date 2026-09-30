import Foundation
import DUML
import Telemetry

/// Behaves like an aircraft on a DUML link: answers ping / get-version for
/// the FC, camera, gimbal and RC, and pushes OSD General at 10 Hz from the
/// synthetic flight. Also pushes an RC "channels" frame at 20 Hz whose word 0-3
/// wobble so the stick-diff view has something to show.
public final class MockDUMLLink: DUMLLink, @unchecked Sendable {
    public let name = "Mock DUML"
    public let incoming: AsyncStream<DUMLPacket>
    private var continuation: AsyncStream<DUMLPacket>.Continuation?
    private var pushTask: Task<Void, Never>?
    public let flight = SyntheticFlight()
    private let started = Date()
    private var seq: UInt16 = 0
    public var speed: Double = 1.0
    private let lock = NSLock()

    public init() {
        var c: AsyncStream<DUMLPacket>.Continuation!
        incoming = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { c = $0 }
        continuation = c
        pushTask = Task.detached(priority: .utility) { [weak self] in
            var i = 0
            while !Task.isCancelled, let self {
                let t = fmod(Date().timeIntervalSince(self.started) * self.speed, self.flight.duration)
                let f = self.flight.frame(at: t, index: i)
                self.emit(set: 3, id: 0x43, from: .flightController, payload: DUMLTelemetry.encodeOSDGeneral(f))
                if i % 2 == 0 {
                    var rc = [UInt8](repeating: 0, count: 12)
                    let a = Int16(1024 + 300 * sin(t / 2)), b = Int16(1024 + 200 * cos(t / 3))
                    rc.writeInt16(a, at: 0); rc.writeInt16(b, at: 2); rc.writeInt16(1024, at: 4); rc.writeInt16(1024 + Int16(f.yaw! * 2), at: 6)
                    self.emit(set: 6, id: 0x05, from: .rc, payload: rc)
                }
                i += 1
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func emit(set: UInt8, id: UInt8, from: DUMLAddress, payload: [UInt8]) {
        lock.lock(); seq &+= 1; let s = seq; lock.unlock()
        continuation?.yield(DUMLPacket(sender: from, receiver: .pc, sequence: s, ackType: .none, commandSet: set, commandID: id, payload: payload))
    }

    public func send(_ packet: DUMLPacket) async throws {
        // Respond after a realistic USB round trip.
        try? await Task.sleep(nanoseconds: 8_000_000)
        guard !packet.isResponse else { return }
        let target = packet.receiver.type
        let responder: DUMLAddress = target == .any ? .flightController : packet.receiver
        var payload: [UInt8] = []
        switch (packet.commandSet, packet.commandID) {
        case (0, 0): payload = [0]
        case (0, 1):
            let name: String
            switch target { case .flightController: name = "WM1605_FC_MOCK"; case .camera: name = "MOCK_CAM"; case .gimbal: name = "MOCK_GMB"
            case .remoteController: name = "RC_MOCK"; default: name = "MOCK" }
            payload = [0, 0] + Array(name.utf8) + [UInt8](repeating: 0, count: max(0, 16 - name.utf8.count)) + [0x02, 0x00, 0x01, 0x03] // trailer v3.1.0.2
        case (0, 0x27): payload = Array("FlyMac mock aircraft".utf8)
        default:
            // Anything else: "unsupported" ack with an error code, like real firmware.
            payload = [0xE0]
        }
        continuation?.yield(DUMLPacket(sender: responder, receiver: packet.sender, sequence: packet.sequence, isResponse: true,
                                       ackType: .none, commandSet: packet.commandSet, commandID: packet.commandID, payload: payload))
    }

    public func close() { pushTask?.cancel(); continuation?.finish() }
}
