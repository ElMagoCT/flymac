import Testing
import Foundation
@testable import Ingest
import FlyCore

private func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("flymac-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}
private func write(_ dir: URL, _ name: String, _ bytes: Int, seed: UInt8 = 7) -> URL {
    let u = dir.appendingPathComponent(name)
    try! FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &+ Int(seed)) }).write(to: u)
    return u
}

@Suite struct MediaGroupingTests {
    @Test func groupsSidecarsByStem() {
        let files = [
            RemoteMediaFile(path: "DCIM/100MEDIA/DJI_0007.MP4", size: 100, modified: Date(timeIntervalSince1970: 200)),
            RemoteMediaFile(path: "DCIM/100MEDIA/DJI_0007.LRF", size: 10, modified: Date(timeIntervalSince1970: 200)),
            RemoteMediaFile(path: "DCIM/100MEDIA/DJI_0007.SRT", size: 1),
            RemoteMediaFile(path: "DCIM/100MEDIA/DJI_0008.JPG", size: 50, modified: Date(timeIntervalSince1970: 300)),
            RemoteMediaFile(path: "DCIM/100MEDIA/DJI_0009.SRT", size: 2),
        ]
        let g = MediaGroup.group(files)
        #expect(g.count == 3)
        #expect(g[0].stem == "DJI_0008")            // newest first
        let seven = g.first { $0.stem == "DJI_0007" }!
        #expect(seven.primary?.kind == .video)
        #expect(seven.proxy?.name == "DJI_0007.LRF")
        #expect(seven.telemetry?.name == "DJI_0007.SRT")
        #expect(seven.totalSize == 111)
        #expect(MediaKind.of("x.dng") == .photo)
        #expect(MediaKind.of("x.txt") == .other)
    }
}

@Suite struct LibraryImportTests {
    @Test func importsVerifiesAndDedupes() throws {
        let src = tempDir(), root = tempDir()
        let a = write(src, "DCIM/100MEDIA/DJI_0001.MP4", 3_000_000)
        _ = write(src, "DCIM/100MEDIA/DJI_0001.SRT", 500)
        _ = write(src, "DCIM/100MEDIA/notes.txt", 5)

        let lib = MediaLibrary(root: root)
        let cap = Date(timeIntervalSince1970: 1_758_400_000)   // 2025-09-20 UTC-ish
        var seen: [Int64] = []
        let r = lib.importFile(at: a, sourceID: "test", captured: cap, progress: { d, _ in seen.append(d) })
        guard case .imported(let item) = r else { Issue.record("expected import, got \(r)"); return }
        #expect(item.size == 3_000_000)
        #expect(item.kind == .video)
        #expect(item.relativePath.hasSuffix("/DJI_0001.MP4"))
        #expect(seen.last == 3_000_000)
        #expect(FileManager.default.fileExists(atPath: lib.url(for: item).path))
        #expect(try Hashing.sha256(of: lib.url(for: item)) == item.sha256)

        // Same content again (even under a different name) is a duplicate.
        let copy = write(src, "elsewhere/RENAMED.MP4", 3_000_000)
        #expect(lib.importFile(at: copy, sourceID: "test", captured: cap) == .duplicate(item))

        // Same name, different content gets a suffixed name, not overwritten.
        let other = write(src, "other/DJI_0001.MP4", 1000, seed: 99)
        guard case .imported(let item2) = lib.importFile(at: other, sourceID: "test", captured: cap) else { Issue.record("expected import"); return }
        #expect(item2.relativePath.hasSuffix("/DJI_0001-1.MP4"))

        // Folder import skips .txt and the already-imported video.
        let results = lib.importFolder(src.appendingPathComponent("DCIM"), sourceID: "card")
        #expect(results.count == 2)
        #expect(results.filter { if case .duplicate = $0 { return true } else { return false } }.count == 1)
        #expect(results.filter { if case .imported = $0 { return true } else { return false } }.count == 1)
        #expect(lib.count == 3)

        // Index persists.
        let reopened = MediaLibrary(root: root)
        #expect(reopened.count == 3)
        #expect(reopened.contains(sha256: item.sha256))
        #expect(reopened.looksImported(name: "dji_0001.mp4", size: 3_000_000))
        #expect(reopened.groups().count == 2)   // SRT imported today; both MP4s share stem + 2025 day
        #expect(reopened.groups().contains { $0.items.count == 2 })
    }

    @Test func rejectsWrongExpectedHash() {
        let src = tempDir(), root = tempDir()
        let a = write(src, "DJI_0002.MP4", 100)
        let r = MediaLibrary(root: root).importFile(at: a, sourceID: "t", captured: nil, expectedSHA256: "deadbeef")
        guard case .failed(let msg) = r else { Issue.record("expected failure"); return }
        #expect(msg.contains("hash mismatch"))
    }

    @Test func quickKeyDistinguishesFiles() throws {
        let d = tempDir()
        let a = write(d, "a.bin", 3 << 20), b = write(d, "b.bin", 3 << 20, seed: 8), c = write(d, "c.bin", 3 << 20)
        #expect(try Hashing.quickKey(of: a) == Hashing.quickKey(of: c))
        #expect(try Hashing.quickKey(of: a) != Hashing.quickKey(of: b))
        #expect(Hashing.sha256(of: Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
