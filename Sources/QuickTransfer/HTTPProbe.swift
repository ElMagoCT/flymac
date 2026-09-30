import Foundation

/// Records an HTTP exchange verbatim so it can be saved as a fixture and cited
/// in docs/PROTOCOLS.md.
public struct HTTPExchange: Codable, Sendable, Identifiable, Hashable {
    public var id: String { "\(method) \(url)" }
    public var date: Date
    public var method: String
    public var url: String
    public var requestHeaders: [String: String]
    public var status: Int?
    public var responseHeaders: [String: String]
    public var bodyPreview: String      // first 4 KB, text or hex
    public var bodyBytes: Int
    public var error: String?
    public var elapsedMs: Double

    public var summary: String {
        if let error { return "\(method) \(url) → error \(error)" }
        return "\(method) \(url) → \(status ?? 0) \(responseHeaders["Content-Type"] ?? "") \(bodyBytes) B \(Int(elapsedMs)) ms"
    }
}

public enum HTTPProbe {
    /// Candidate paths on an unknown device. These are *guesses to try*, and
    /// only a 200 with a real body counts as evidence.
    public static let candidatePaths: [String] = [
        "/", "/index.html", "/api", "/api/v1", "/api/media", "/media", "/files", "/list", "/DCIM/", "/DCIM/100MEDIA/",
        "/mnt/sdcard/", "/sdcard/", "/upnp", "/description.xml", "/status", "/info", "/version", "/device",
        "/cgi-bin/", "/robots.txt", "/favicon.ico",
    ]

    public static func fetch(_ url: URL, method: String = "GET", headers: [String: String] = [:],
                             timeout: TimeInterval = 4) async -> HTTPExchange {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = method
        var reqHeaders = ["User-Agent": "FlyMac/0.1 (Doctor)", "Accept": "*/*"]
        headers.forEach { reqHeaders[$0.key] = $0.value }
        reqHeaders.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        let start = Date()
        var ex = HTTPExchange(date: start, method: method, url: url.absoluteString, requestHeaders: reqHeaders,
                              status: nil, responseHeaders: [:], bodyPreview: "", bodyBytes: 0, error: nil, elapsedMs: 0)
        do {
            let (data, resp) = try await session.data(for: req)
            ex.elapsedMs = Date().timeIntervalSince(start) * 1000
            if let h = resp as? HTTPURLResponse {
                ex.status = h.statusCode
                for (k, v) in h.allHeaderFields { ex.responseHeaders["\(k)"] = "\(v)" }
            }
            ex.bodyBytes = data.count
            ex.bodyPreview = preview(data)
        } catch {
            ex.elapsedMs = Date().timeIntervalSince(start) * 1000
            ex.error = error.localizedDescription
        }
        return ex
    }

    public static func sweep(base: URL, paths: [String] = candidatePaths) async -> [HTTPExchange] {
        var out: [HTTPExchange] = []
        for p in paths {
            guard let u = URL(string: p, relativeTo: base)?.absoluteURL else { continue }
            out.append(await fetch(u))
        }
        return out
    }

    static func preview(_ data: Data) -> String {
        let slice = data.prefix(4096)
        if let s = String(data: slice, encoding: .utf8), !s.contains("\0") { return s }
        return slice.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.waitsForConnectivity = false
        c.timeoutIntervalForRequest = 5
        c.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: c)
    }()
}
