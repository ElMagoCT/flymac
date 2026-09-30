import Foundation

/// Byte-stream framer. Feed it whatever arrives from a USB pipe or a socket;
/// it re-syncs on 0x55 + valid header CRC and hands back whole packets.
public struct DUMLParser: Sendable {
    private var buffer: [UInt8] = []
    public private(set) var droppedBytes = 0
    public private(set) var badFrames = 0

    public init() {}

    public mutating func feed<C: Collection>(_ bytes: C) -> [DUMLPacket] where C.Element == UInt8 {
        buffer.append(contentsOf: bytes)
        var out: [DUMLPacket] = []
        var i = 0
        while i < buffer.count {
            guard buffer[i] == DUMLPacket.startByte else { i += 1; droppedBytes += 1; continue }
            guard buffer.count - i >= 4 else { break }
            guard let len = DUMLPacket.declaredLength(buffer[i...]), len >= DUMLPacket.minimumLength else {
                i += 1; droppedBytes += 1; continue
            }
            guard buffer.count - i >= len else { break }
            let slice = Array(buffer[i..<(i + len)])
            if let p = try? DUMLPacket.decode(slice) {
                out.append(p)
                i += len
            } else {
                badFrames += 1
                i += 1; droppedBytes += 1
            }
        }
        buffer.removeFirst(i)
        return out
    }

    public var pendingBytes: Int { buffer.count }
    public mutating func reset() { buffer.removeAll() }
}

/// Hex helpers used by tests, fixtures and the Doctor.
public enum Hex {
    public static func bytes(_ s: String) -> [UInt8] {
        let clean = s.filter { !$0.isWhitespace && $0 != ":" }
        var out: [UInt8] = []
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let next = clean.index(idx, offsetBy: 2, limitedBy: clean.endIndex) ?? clean.endIndex
            if let b = UInt8(clean[idx..<next], radix: 16) { out.append(b) }
            idx = next
        }
        return out
    }
    public static func string<C: Collection>(_ b: C, separator: String = " ") -> String where C.Element == UInt8 {
        b.map { String(format: "%02x", $0) }.joined(separator: separator)
    }
}
