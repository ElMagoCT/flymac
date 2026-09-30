import Foundation
import FlyCore

/// The on-disk library:
///
///     <root>/
///       library.json                      index of everything imported
///       2026-09-20/                       capture date (falls back to import date)
///         DJI_0007.MP4  DJI_0007.LRF  DJI_0007.SRT  DJI_0008.JPG …
///
/// Imports are copy-then-verify: the file is written to `.partial`, hashed,
/// compared with the source, then renamed into place. Duplicates are detected
/// by size + hash, not by name, so re-importing a card is a no-op.
public final class MediaLibrary: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()
    private var index: [LibraryItem]
    private var byHash: [String: LibraryItem]

    public init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let idx = (try? Data(contentsOf: root.appendingPathComponent("library.json")))
            .flatMap { try? JSONDecoder.library.decode([LibraryItem].self, from: $0) } ?? []
        index = idx
        byHash = Dictionary(idx.map { ($0.sha256, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public var items: [LibraryItem] { lock.withLock { index } }
    public var count: Int { lock.withLock { index.count } }
    public var totalBytes: Int64 { lock.withLock { index.reduce(0) { $0 + $1.size } } }

    public func url(for item: LibraryItem) -> URL { root.appendingPathComponent(item.relativePath) }

    public func contains(sha256: String) -> Bool { lock.withLock { byHash[sha256] != nil } }
    public func item(sha256: String) -> LibraryItem? { lock.withLock { byHash[sha256] } }

    /// Fast pre-check used by the media browser to grey out what's already here.
    public func looksImported(name: String, size: Int64) -> Bool {
        lock.withLock { index.contains { $0.originalName.caseInsensitiveCompare(name) == .orderedSame && $0.size == size } }
    }

    /// Captures grouped by stem, newest first.
    public func groups() -> [(stem: String, date: Date?, items: [LibraryItem])] {
        var by: [String: [LibraryItem]] = [:]
        for i in items { by["\(i.captured.map { dayFolder(for: $0) } ?? "")/\(i.stem)", default: []].append(i) }
        return by.map { (stem: $0.value[0].stem, date: $0.value.compactMap(\.captured).min(), items: $0.value.sorted { $0.originalName < $1.originalName }) }
            .sorted { ($0.date ?? .distantPast, $0.stem) > ($1.date ?? .distantPast, $1.stem) }
    }

    public enum ImportResult: Sendable, Equatable {
        case imported(LibraryItem)
        case duplicate(LibraryItem)
        case failed(String)
    }

    /// Copy `source` into the library. `captured` picks the day folder.
    public func importFile(at source: URL, originalName: String? = nil, sourceID: String, captured: Date?,
                           verify: Bool = true, expectedSHA256: String? = nil,
                           progress: ((Int64, Int64) -> Void)? = nil) -> ImportResult {
        let fm = FileManager.default
        let name = originalName ?? source.lastPathComponent
        do {
            let attrs = try fm.attributesOfItem(atPath: source.path)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = attrs[.modificationDate] as? Date
            let day = dayFolder(for: captured ?? mtime ?? Date())

            // Duplicate check on content, never on name.
            let sourceHash = try Hashing.sha256(of: source)
            if let e = expectedSHA256, e.lowercased() != sourceHash { return .failed("source hash mismatch (expected \(e.prefix(12))…)") }
            if let existing = item(sha256: sourceHash), fm.fileExists(atPath: url(for: existing).path) { return .duplicate(existing) }

            let dir = root.appendingPathComponent(day, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var dest = dir.appendingPathComponent(name)
            var n = 1
            while fm.fileExists(atPath: dest.path) {   // same name, different content
                dest = dir.appendingPathComponent("\((name as NSString).deletingPathExtension)-\(n).\((name as NSString).pathExtension)")
                n += 1
            }
            let partial = dest.appendingPathExtension("partial")
            try? fm.removeItem(at: partial)
            try copy(source, to: partial, total: size, progress: progress)

            if verify {
                let h = try Hashing.sha256(of: partial)
                guard h == sourceHash else { try? fm.removeItem(at: partial); return .failed("copy verification failed for \(name)") }
            }
            try fm.moveItem(at: partial, to: dest)
            if let mtime { try? fm.setAttributes([.modificationDate: mtime], ofItemAtPath: dest.path) }

            let item = LibraryItem(relativePath: "\(day)/\(dest.lastPathComponent)", originalName: name, sourcePath: source.path,
                                   sourceID: sourceID, size: size, sha256: sourceHash, captured: captured ?? mtime,
                                   kind: MediaKind.of(name), stem: (name as NSString).deletingPathExtension)
            lock.withLock { index.append(item); byHash[sourceHash] = item }
            save()
            return .imported(item)
        } catch {
            return .failed("\(name): \(error.localizedDescription)")
        }
    }

    /// Import a whole folder tree (a mounted card). Returns results in order.
    public func importFolder(_ folder: URL, sourceID: String, only: Set<MediaKind>? = nil,
                             progress: ((String, Int, Int) -> Void)? = nil) -> [ImportResult] {
        let files = MediaLibrary.scan(folder).filter { only?.contains($0.kind) ?? true }
        var results: [ImportResult] = []
        for (i, f) in files.enumerated() {
            progress?(f.name, i, files.count)
            results.append(importFile(at: folder.appendingPathComponent(f.path), sourceID: sourceID, captured: f.modified))
        }
        return results
    }

    /// List media files under a root (recursively), as relative paths.
    public static func scan(_ folder: URL) -> [RemoteMediaFile] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
                                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [RemoteMediaFile] = []
        let base = folder.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  v.isRegularFile == true else { continue }
            let kind = MediaKind.of(u.lastPathComponent)
            guard kind != .other else { continue }
            let comps = u.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            let rel = comps.count > base.count ? comps[base.count...].joined(separator: "/") : u.lastPathComponent
            out.append(RemoteMediaFile(path: rel, size: Int64(v.fileSize ?? 0), modified: v.contentModificationDate))
        }
        return out.sorted { $0.path < $1.path }
    }

    public func remove(_ item: LibraryItem, deleteFile: Bool) throws {
        if deleteFile { try FileManager.default.trashItem(at: url(for: item), resultingItemURL: nil) }
        lock.withLock { index.removeAll { $0.relativePath == item.relativePath }; byHash[item.sha256] = nil }
        save()
    }

    // MARK: -

    func dayFolder(for d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f.string(from: d)
    }

    private func copy(_ src: URL, to dst: URL, total: Int64, progress: ((Int64, Int64) -> Void)?) throws {
        guard let progress else { try FileManager.default.copyItem(at: src, to: dst); return }
        let input = try FileHandle(forReadingFrom: src)
        FileManager.default.createFile(atPath: dst.path, contents: nil)
        let output = try FileHandle(forWritingTo: dst)
        defer { try? input.close(); try? output.close() }
        var done: Int64 = 0
        while true {
            let chunk = autoreleasepool { input.readData(ofLength: 8 << 20) }
            if chunk.isEmpty { break }
            output.write(chunk)
            done += Int64(chunk.count)
            progress(done, total)
        }
    }

    private func save() {
        let items = lock.withLock { index }
        try? JSONEncoder.library.encode(items).write(to: root.appendingPathComponent("library.json"), options: .atomic)
    }
}

extension JSONEncoder { static var library: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e } }
extension JSONDecoder { static var library: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d } }
