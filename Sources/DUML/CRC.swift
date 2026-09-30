import Foundation

/// DJI's two checksums. Both are reflected table CRCs with non-standard seeds.
/// Sources: o-gs/dji-firmware-tools `comm_dissector/dji-dumlv1-proto.lua`
/// (crc8 table begins 00 5e bc e2, crc16 table begins 0000 1189 2312 329b);
/// samuelsadok/dji_protocol README (CRC-8 poly 0x31 seed 0x77; CRC-16 poly
/// 0x1021 reflected (0x8408) seed 0x3692).
public enum DUMLCRC {
    /// Reflected polynomial 0x31 → 0x8C.
    public static let crc8Table: [UInt8] = (0..<256).map { i -> UInt8 in
        var c = UInt8(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0x8C : c >> 1 }
        return c
    }

    /// Reflected polynomial 0x1021 → 0x8408 (same table as CRC-16/KERMIT).
    public static let crc16Table: [UInt16] = (0..<256).map { i -> UInt16 in
        var c = UInt16(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0x8408 : c >> 1 }
        return c
    }

    public static let crc8Seed: UInt8 = 0x77
    public static let crc16Seed: UInt16 = 0x3692

    public static func crc8<C: Collection>(_ bytes: C, seed: UInt8 = crc8Seed) -> UInt8 where C.Element == UInt8 {
        var c = seed
        for b in bytes { c = crc8Table[Int(c ^ b)] }
        return c
    }

    public static func crc16<C: Collection>(_ bytes: C, seed: UInt16 = crc16Seed) -> UInt16 where C.Element == UInt8 {
        var c = seed
        for b in bytes { c = crc16Table[Int((c ^ UInt16(b)) & 0xFF)] ^ (c >> 8) }
        return c
    }
}
