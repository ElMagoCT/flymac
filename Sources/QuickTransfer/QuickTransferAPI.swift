import Foundation
import FlyCore

/// How a media source is spoken to over HTTP. The real DJI dialect is filled in
/// from Phase 0 captures; until then only the mock dialect exists and the UI
/// is written against this protocol so nothing above it has to change.
public protocol QuickTransferDialect: Sendable {
    var id: String { get }
    var displayName: String { get }
    /// Cheap check: does `base` speak this dialect? Used after a hotspot is noticed.
    func detect(base: URL) async -> Bool
    func listMedia(base: URL) async throws -> [RemoteMediaFile]
    func downloadURL(base: URL, file: RemoteMediaFile) -> URL
    func thumbnailURL(base: URL, file: RemoteMediaFile) -> URL?
    /// Some dialects need a keep-alive or an "I am a client" call. Optional.
    func connect(base: URL) async throws
}

public extension QuickTransferDialect {
    func connect(base: URL) async throws {}
    func thumbnailURL(base: URL, file: RemoteMediaFile) -> URL? { nil }
}

/// All known dialects. Detection tries each in order.
public enum DialectRegistry {
    nonisolated(unsafe) public static var all: [any QuickTransferDialect] = [FlyMacJSONDialect()]

    public static func detect(base: URL) async -> (any QuickTransferDialect)? {
        for d in all where await d.detect(base: base) { return d }
        return nil
    }
    public static func dialect(id: String) -> (any QuickTransferDialect)? { all.first { $0.id == id } }
}

/// FlyMac's own simple JSON dialect. Spoken by MockDevice and usable by any
/// future bridge (e.g. a phone app relaying a real drone):
///
///   GET /api/info                → {"name","model","serial"}
///   GET /api/media               → {"files":[{"path","size","modified","duration","sha256","thumbnail"}]}
///   GET /files/<path>            → bytes, supports Range
///   GET /thumbs/<path>.jpg       → JPEG
public struct FlyMacJSONDialect: QuickTransferDialect {
    public let id = "flymac-json"
    public let displayName = "FlyMac JSON"
    public init() {}

    struct Info: Decodable { var name: String; var model: String?; var serial: String? }
    struct Listing: Decodable {
        struct F: Decodable { var path: String; var size: Int64; var modified: Date?; var duration: Double?; var sha256: String?; var thumbnail: String? }
        var files: [F]
    }

    public func detect(base: URL) async -> Bool {
        let ex = await HTTPProbe.fetch(base.appendingPathComponent("api/info"), timeout: 2)
        return ex.status == 200 && ex.bodyPreview.contains("\"name\"")
    }

    public func listMedia(base: URL) async throws -> [RemoteMediaFile] {
        let (data, _) = try await HTTPProbe.session.data(from: base.appendingPathComponent("api/media"))
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try dec.decode(Listing.self, from: data).files.map {
            RemoteMediaFile(path: $0.path, size: $0.size, modified: $0.modified, duration: $0.duration,
                            thumbnail: $0.thumbnail, sha256: $0.sha256)
        }
    }

    public func downloadURL(base: URL, file: RemoteMediaFile) -> URL {
        base.appendingPathComponent("files").appendingPathComponent(file.path)
    }

    public func thumbnailURL(base: URL, file: RemoteMediaFile) -> URL? {
        file.thumbnail.flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }
    }
}
