import Foundation
import FlyCore
import CryptoKit

public enum Hashing {
    /// Full SHA-256 of a file, streamed in 4 MB chunks.
    public static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = h.readData(ofLength: 4 << 20)
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Fast duplicate key: size + SHA-256 of the first and last 1 MB. Used to
    /// skip a file before spending a full read; a match is then confirmed by
    /// full hash when `verifyHashes` is on.
    public static func quickKey(of url: URL) throws -> String {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        let window = 1 << 20
        hasher.update(data: h.readData(ofLength: window))
        if size > Int64(2 * window) {
            try h.seek(toOffset: UInt64(size - Int64(window)))
            hasher.update(data: h.readData(ofLength: window))
        }
        return "\(size):" + hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
