import Foundation
import DUML

/// Decoders for DUML push messages that carry telemetry. Field layouts come
/// from o-gs/dji-firmware-tools `comm_dissector/dji-dumlv1-flyc.lua`
/// ("OSD General" 0x43). Only the leading, well-attested fields are decoded;
/// everything is marked so the Doctor can show raw bytes for the rest.
/// Nothing here sends anything.
public enum DUMLTelemetry {
    public static let flycOSDGeneral: (set: UInt8, id: UInt8) = (0x03, 0x43)
    public static let flycOSDHome: (set: UInt8, id: UInt8) = (0x03, 0x44)
    public static let rcPushParam: (set: UInt8, id: UInt8) = (0x06, 0x05)

    /// Returns a frame if `packet` is a known telemetry push, else nil.
    public static func decode(_ packet: DUMLPacket, index: Int, time: TimeInterval) -> TelemetryFrame? {
        if packet.commandSet == flycOSDGeneral.set && packet.commandID == flycOSDGeneral.id {
            return decodeOSDGeneral(packet.payload, index: index, time: time)
        }
        return nil
    }

    /// OSD General (flyc 0x43). Layout from comm_dissector:
    ///   0  longitude  double (radians)
    ///   8  latitude   double (radians)
    ///  16  relative_height int16 (0.1 m)
    ///  18  vgx int16 (0.1 m/s)   20 vgy   22 vgz (positive = down)
    ///  24  pitch int16 (0.1°)  26 roll  28 yaw
    ///  30  ctrl_info byte   31 flight_action   32 motor_start_failed_cause   33 non_gps_cause
    ///  34  battery byte? (varies by firmware — decoded only when ≤100)
    ///  … gps_num at 41 on many firmwares (uint8) — decoded opportunistically.
    public static func decodeOSDGeneral(_ p: [UInt8], index: Int, time: TimeInterval) -> TelemetryFrame? {
        guard p.count >= 30 else { return nil }
        var f = TelemetryFrame(index: index, time: time)
        let lonRad = p.readDouble(0), latRad = p.readDouble(8)
        if lonRad.isFinite, latRad.isFinite, abs(lonRad) <= .pi, abs(latRad) <= .pi / 2 {
            f.longitude = lonRad * 180 / .pi
            f.latitude = latRad * 180 / .pi
        }
        f.relativeAltitude = Double(p.readInt16(16)) / 10
        let vx = Double(p.readInt16(18)) / 10, vy = Double(p.readInt16(20)) / 10, vz = Double(p.readInt16(22)) / 10
        f.horizontalSpeed = (vx * vx + vy * vy).squareRoot()
        f.verticalSpeed = -vz
        f.pitch = Double(p.readInt16(24)) / 10
        f.roll = Double(p.readInt16(26)) / 10
        f.yaw = Double(p.readInt16(28)) / 10
        if p.count > 34, p[34] <= 100 { f.batteryPercent = Int(p[34]) }
        if p.count > 41, p[41] <= 40 { f.satellites = Int(p[41]) }
        return f
    }

    /// Build an OSD General payload (used by MockDevice and tests).
    public static func encodeOSDGeneral(_ f: TelemetryFrame) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 48)
        p.writeDouble((f.longitude ?? 0) * .pi / 180, at: 0)
        p.writeDouble((f.latitude ?? 0) * .pi / 180, at: 8)
        p.writeInt16(Int16(((f.relativeAltitude ?? 0) * 10).rounded()), at: 16)
        p.writeInt16(Int16(((f.horizontalSpeed ?? 0) * 10).rounded()), at: 18)
        p.writeInt16(0, at: 20)
        p.writeInt16(Int16((-(f.verticalSpeed ?? 0) * 10).rounded()), at: 22)
        p.writeInt16(Int16(((f.pitch ?? 0) * 10).rounded()), at: 24)
        p.writeInt16(Int16(((f.roll ?? 0) * 10).rounded()), at: 26)
        p.writeInt16(Int16(((f.yaw ?? 0) * 10).rounded()), at: 28)
        p[34] = UInt8(clamping: f.batteryPercent ?? 0)
        p[41] = UInt8(clamping: f.satellites ?? 0)
        return p
    }
}

/// Raw RC channel snapshot. Which bytes are the sticks is established on real
/// hardware in Phase 0 by watching what changes; until then this is just a
/// diff-friendly view of the payload.
public struct RCChannelSnapshot: Sendable, Equatable {
    public var payload: [UInt8]
    public var words: [Int16] { stride(from: 0, to: payload.count - 1, by: 2).map { payload.readInt16($0) } }
    public init(payload: [UInt8]) { self.payload = payload }

    /// Indices of 16-bit words that differ from `other`.
    public func changedWords(from other: RCChannelSnapshot) -> [Int] {
        let a = words, b = other.words
        return (0..<min(a.count, b.count)).filter { a[$0] != b[$0] }
    }
}

extension Array where Element == UInt8 {
    public func readInt16(_ o: Int) -> Int16 { Int16(bitPattern: UInt16(self[o]) | (UInt16(self[o+1]) << 8)) }
    public func readUInt16(_ o: Int) -> UInt16 { UInt16(self[o]) | (UInt16(self[o+1]) << 8) }
    public func readUInt32(_ o: Int) -> UInt32 { (0..<4).reduce(0) { $0 | (UInt32(self[o + $1]) << (8 * UInt32($1))) } }
    public func readDouble(_ o: Int) -> Double {
        var bits: UInt64 = 0
        for i in 0..<8 { bits |= UInt64(self[o + i]) << (8 * UInt64(i)) }
        return Double(bitPattern: bits)
    }
    public mutating func writeInt16(_ v: Int16, at o: Int) { let u = UInt16(bitPattern: v); self[o] = UInt8(u & 0xFF); self[o+1] = UInt8(u >> 8) }
    public mutating func writeDouble(_ v: Double, at o: Int) { let b = v.bitPattern; for i in 0..<8 { self[o + i] = UInt8((b >> (8 * UInt64(i))) & 0xFF) } }
}
