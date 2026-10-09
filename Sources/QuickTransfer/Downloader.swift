import Foundation
import CryptoKit
import FlyCore

/// Resumable, parallel HTTP downloads with progress. Each file goes to
/// `<staging>/<name>.partial`; an interrupted job resumes with a Range header.
/// The finished file is handed back for Ingest to verify and file away.
public actor Downloader {
    public struct Job: Identifiable, Sendable, Equatable {
        public enum State: Sendable, Equatable { case queued, running, paused, done(URL), failed(String), cancelled }
        public let id: String
        public let file: RemoteMediaFile
        public let url: URL
        /// Which device this came from. Two devices can hold the same path.
        public let sourceKey: String
        public let sourceName: String
        public var state: State = .queued
        public var received: Int64 = 0
        public var bytesPerSecond: Double = 0
        public var sha256: String?
        public var progress: Double { file.size > 0 ? Double(received) / Double(file.size) : 0 }
    }

    public private(set) var jobs: [Job] = []
    public var maxParallel: Int
    private let staging: URL
    private var running: [String: Task<Void, Never>] = [:]
    private var listeners: [UUID: @Sendable ([Job]) -> Void] = [:]
    private let session: URLSession

    public init(staging: URL, maxParallel: Int = 3) {
        self.staging = staging
        self.maxParallel = maxParallel
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.httpMaximumConnectionsPerHost = 6
        c.waitsForConnectivity = true
        session = URLSession(configuration: c)
    }

    public func observe(_ f: @escaping @Sendable ([Job]) -> Void) -> UUID { let id = UUID(); listeners[id] = f; f(jobs); return id }
    public func unobserve(_ id: UUID) { listeners[id] = nil }
    private func notify() { let j = jobs; for l in listeners.values { l(j) } }

    public static func jobID(sourceKey: String, path: String) -> String { "\(sourceKey)|\(path)" }

    public func enqueue(_ file: RemoteMediaFile, from url: URL, sourceKey: String = "default", sourceName: String = "") {
        let id = Downloader.jobID(sourceKey: sourceKey, path: file.path)
        guard !jobs.contains(where: { $0.id == id }) else { return }
        jobs.append(Job(id: id, file: file, url: url, sourceKey: sourceKey, sourceName: sourceName))
        notify(); pump()
    }

    public func cancel(_ id: String) {
        running[id]?.cancel(); running[id] = nil
        if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].state = .cancelled }
        notify(); pump()
    }

    public func pause(_ id: String) {
        running[id]?.cancel(); running[id] = nil
        if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].state = .paused }
        notify(); pump()
    }

    public func resume(_ id: String) {
        if let i = jobs.firstIndex(where: { $0.id == id }), case .paused = jobs[i].state { jobs[i].state = .queued }
        notify(); pump()
    }

    public func clearFinished() {
        jobs.removeAll { if case .done = $0.state { return true }; if case .cancelled = $0.state { return true }; return false }
        notify()
    }

    private func pump() {
        while running.count < maxParallel, let i = jobs.firstIndex(where: { $0.state == .queued }) {
            let job = jobs[i]
            jobs[i].state = .running
            running[job.id] = Task { [weak self] in await self?.run(job) }
        }
        notify()
    }

    private func update(_ id: String, _ f: (inout Job) -> Void) {
        if let i = jobs.firstIndex(where: { $0.id == id }) { f(&jobs[i]) }
        notify()
    }

    private func run(_ job: Job) async {
        // One staging folder per source so identical names never collide.
        let fm = FileManager.default
        let dir = staging.appendingPathComponent(Downloader.safeFolder(job.sourceKey), isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let partial = dir.appendingPathComponent(job.file.name + ".partial")
        let final = dir.appendingPathComponent(job.file.name)
        var offset: Int64 = 0
        if let attrs = try? fm.attributesOfItem(atPath: partial.path) { offset = (attrs[.size] as? NSNumber)?.int64Value ?? 0 }
        if offset >= job.file.size, job.file.size > 0 { offset = 0; try? fm.removeItem(at: partial) }

        var req = URLRequest(url: job.url)
        if offset > 0 { req.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        do {
            let (bytes, resp) = try await session.bytes(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            if http.statusCode != 206 { offset = 0; try? fm.removeItem(at: partial) }   // server ignored Range
            if !fm.fileExists(atPath: partial.path) { fm.createFile(atPath: partial.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: partial)
            try handle.seekToEnd()
            defer { try? handle.close() }

            var received = offset
            var hasher = SHA256()
            var hashValid = offset == 0   // resumed downloads are hashed after completion instead
            var chunk = Data(); chunk.reserveCapacity(256 << 10)
            var lastTick = Date(); var lastBytes = received
            for try await b in bytes {
                chunk.append(b)
                if chunk.count >= 256 << 10 {
                    handle.write(chunk); received += Int64(chunk.count)
                    if hashValid { hasher.update(data: chunk) }
                    chunk.removeAll(keepingCapacity: true)
                    let now = Date()
                    if now.timeIntervalSince(lastTick) > 0.25 {
                        let bps = Double(received - lastBytes) / now.timeIntervalSince(lastTick)
                        lastTick = now; lastBytes = received
                        update(job.id) { $0.received = received; $0.bytesPerSecond = bps }
                    }
                }
                try Task.checkCancellation()
            }
            if !chunk.isEmpty { handle.write(chunk); received += Int64(chunk.count); if hashValid { hasher.update(data: chunk) } }
            try handle.close()
            if job.file.size > 0, received != job.file.size {
                throw NSError(domain: "FlyMac.Downloader", code: 1, userInfo: [NSLocalizedDescriptionKey: "got \(received) of \(job.file.size) bytes"])
            }
            let hash: String
            if hashValid { hash = hasher.finalize().map { String(format: "%02x", $0) }.joined() }
            else { hash = try fullHash(partial); hashValid = true }
            if let expected = job.file.sha256, expected.lowercased() != hash {
                try? fm.removeItem(at: partial)
                throw NSError(domain: "FlyMac.Downloader", code: 2, userInfo: [NSLocalizedDescriptionKey: "checksum mismatch"])
            }
            try? fm.removeItem(at: final)
            try fm.moveItem(at: partial, to: final)
            if let m = job.file.modified { try? fm.setAttributes([.modificationDate: m], ofItemAtPath: final.path) }
            update(job.id) { $0.received = received; $0.sha256 = hash; $0.state = .done(final) }
        } catch is CancellationError {
            // leave .partial in place for resume
        } catch {
            update(job.id) { $0.state = .failed(error.localizedDescription) }
        }
        running[job.id] = nil
        pump()
    }

    static func safeFolder(_ key: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let s = String(key.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return s.isEmpty ? "default" : String(s.prefix(80))
    }

    private nonisolated func fullHash(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
        var hasher = SHA256()
        while true { let d = h.readData(ofLength: 4 << 20); if d.isEmpty { break }; hasher.update(data: d) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
