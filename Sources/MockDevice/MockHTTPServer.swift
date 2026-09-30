import Foundation
import Network
import FlyCore

/// Minimal HTTP/1.1 server on Network.framework that speaks FlyMacJSONDialect.
/// Supports Range so the downloader's resume path is exercised for real.
public final class MockHTTPServer: @unchecked Sendable {
    public let store: MockMediaStore
    private var listener: NWListener?
    public private(set) var port: UInt16 = 0
    private let queue = DispatchQueue(label: "FlyMac.MockHTTP")
    public var base: URL { URL(string: "http://127.0.0.1:\(port)/")! }
    /// For demos: throttle bytes per second (0 = unthrottled).
    public var throttleBytesPerSecond: Int = 0
    public private(set) var requestLog: [String] = []

    public init(store: MockMediaStore) { self.store = store }

    public func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: .any)
        l.newConnectionHandler = { [weak self] c in self?.handle(c) }
        l.stateUpdateHandler = { [weak self] st in
            if case .ready = st, let p = l.port?.rawValue { self?.port = p }
        }
        l.start(queue: queue)
        listener = l
        // Wait for the port.
        let deadline = Date().addingTimeInterval(2)
        while port == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    }

    public func stop() { listener?.cancel(); listener = nil }

    private func handle(_ c: NWConnection) {
        c.start(queue: queue)
        receiveRequest(c, buffer: Data())
    }

    private func receiveRequest(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<r.lowerBound], as: UTF8.self)
                self.respond(c, head: head)
            } else if complete || error != nil { c.cancel() }
            else { self.receiveRequest(c, buffer: buf) }
        }
    }

    private func respond(_ c: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.components(separatedBy: " ") ?? []
        guard parts.count >= 2 else { c.cancel(); return }
        let method = parts[0]
        let path = parts[1].removingPercentEncoding ?? parts[1]
        var headers: [String: String] = [:]
        for l in lines.dropFirst() { if let i = l.firstIndex(of: ":") { headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
        requestLog.append("\(method) \(path)" + (headers["range"].map { " Range: \($0)" } ?? ""))
        if requestLog.count > 200 { requestLog.removeFirst() }

        switch path.split(separator: "?").first.map(String.init) ?? path {
        case "/api/info":
            json(c, ["name": "FlyMac mock aircraft", "model": "MOCK-1", "serial": "MOCK000001", "dialect": "flymac-json"])
        case "/api/media":
            let f = ISO8601DateFormatter()
            let files = store.files.map { m -> [String: Any] in
                var d: [String: Any] = ["path": m.path, "size": m.size]
                if let x = m.modified { d["modified"] = f.string(from: x) }
                if let x = m.duration { d["duration"] = x }
                if let x = m.sha256 { d["sha256"] = x }
                if let x = m.thumbnail { d["thumbnail"] = x }
                return d
            }
            json(c, ["files": files])
        case let p where p.hasPrefix("/files/"):
            file(c, url: store.root.appendingPathComponent(String(p.dropFirst(7))), range: headers["range"], head: method == "HEAD", type: "application/octet-stream")
        case let p where p.hasPrefix("/thumbs/"):
            file(c, url: store.root.appendingPathComponent(String(p.dropFirst(1))), range: nil, head: method == "HEAD", type: "image/jpeg")
        case "/":
            send(c, status: 200, headers: ["Content-Type": "text/plain"], body: Data("FlyMac mock aircraft. Try /api/info\n".utf8))
        default:
            send(c, status: 404, headers: ["Content-Type": "text/plain"], body: Data("not found\n".utf8))
        }
    }

    private func json(_ c: NWConnection, _ obj: Any) {
        let body = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        send(c, status: 200, headers: ["Content-Type": "application/json"], body: body)
    }

    private func file(_ c: NWConnection, url: URL, range: String?, head: Bool, type: String) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let size = (attrs[.size] as? NSNumber)?.int64Value,
              let h = try? FileHandle(forReadingFrom: url) else {
            send(c, status: 404, headers: ["Content-Type": "text/plain"], body: Data("no such file\n".utf8)); return
        }
        var start: Int64 = 0, end = size - 1, status = 200
        var headers: [String: String] = ["Content-Type": type, "Accept-Ranges": "bytes"]
        if let range, range.hasPrefix("bytes=") {
            let spec = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            if spec.count == 2 {
                let s = Int64(spec[0]) ?? 0
                let e = spec[1].isEmpty ? size - 1 : (Int64(spec[1]) ?? size - 1)
                if s <= e, s < size { start = s; end = min(e, size - 1); status = 206
                    headers["Content-Range"] = "bytes \(start)-\(end)/\(size)" }
                else { send(c, status: 416, headers: ["Content-Range": "bytes */\(size)"], body: Data()); return }
            }
        }
        let length = end - start + 1
        headers["Content-Length"] = "\(length)"
        var headText = "HTTP/1.1 \(status) \(status == 206 ? "Partial Content" : "OK")\r\n"
        headers.forEach { headText += "\($0.key): \($0.value)\r\n" }
        headText += "Connection: close\r\n\r\n"
        c.send(content: Data(headText.utf8), completion: .contentProcessed { _ in })
        if head { c.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() }); return }
        try? h.seek(toOffset: UInt64(start))
        stream(c, handle: h, remaining: length)
    }

    private func stream(_ c: NWConnection, handle: FileHandle, remaining: Int64) {
        guard remaining > 0 else { c.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() }); try? handle.close(); return }
        let chunkSize = throttleBytesPerSecond > 0 ? max(16384, throttleBytesPerSecond / 10) : 1 << 20
        let chunk = handle.readData(ofLength: Int(min(Int64(chunkSize), remaining)))
        guard !chunk.isEmpty else { c.cancel(); try? handle.close(); return }
        let delay: TimeInterval = throttleBytesPerSecond > 0 ? Double(chunk.count) / Double(throttleBytesPerSecond) : 0
        c.send(content: chunk, completion: .contentProcessed { [weak self] err in
            guard err == nil, let self else { c.cancel(); try? handle.close(); return }
            let next = { self.stream(c, handle: handle, remaining: remaining - Int64(chunk.count)) }
            if delay > 0 { self.queue.asyncAfter(deadline: .now() + delay, execute: next) } else { next() }
        })
    }

    private func send(_ c: NWConnection, status: Int, headers: [String: String], body: Data) {
        var h = "HTTP/1.1 \(status) \(status == 200 ? "OK" : status == 404 ? "Not Found" : "Error")\r\n"
        headers.forEach { h += "\($0.key): \($0.value)\r\n" }
        h += "Content-Length: \(body.count)\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
        c.send(content: Data(h.utf8) + body, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
    }
}
