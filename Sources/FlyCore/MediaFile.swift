import Foundation

/// Kinds of files DJI aircraft write.
public enum MediaKind: String, Codable, Sendable, CaseIterable {
    case video      // .MP4 / .MOV
    case proxy      // .LRF  (low-res H.264 in an MP4 container)
    case telemetry  // .SRT
    case photo      // .JPG / .DNG
    case audio      // .WAV (some goggles)
    case other

    public static func of(_ name: String) -> MediaKind {
        switch (name as NSString).pathExtension.uppercased() {
        case "MP4", "MOV": return .video
        case "LRF": return .proxy
        case "SRT": return .telemetry
        case "JPG", "JPEG", "DNG", "HEIF", "HEIC": return .photo
        case "WAV", "M4A": return .audio
        default: return .other
        }
    }
}

/// A file as seen on a source (card, Quick Transfer listing, mock). Nothing
/// has been copied yet.
public struct RemoteMediaFile: Codable, Sendable, Hashable, Identifiable {
    public var id: String { path }
    /// Path relative to the source root, e.g. `DCIM/100MEDIA/DJI_0007.MP4`.
    public var path: String
    public var size: Int64
    public var modified: Date?
    /// Duration for videos, if the source reports it.
    public var duration: TimeInterval?
    /// Where a thumbnail can be fetched (URL or file path), if any.
    public var thumbnail: String?
    /// Hash the source publishes, if any (Quick Transfer may; cards never do).
    public var sha256: String?

    public init(path: String, size: Int64, modified: Date? = nil, duration: TimeInterval? = nil, thumbnail: String? = nil, sha256: String? = nil) {
        self.path = path; self.size = size; self.modified = modified; self.duration = duration; self.thumbnail = thumbnail; self.sha256 = sha256
    }

    public var name: String { (path as NSString).lastPathComponent }
    public var kind: MediaKind { MediaKind.of(name) }
    /// `DJI_0007` for `DJI_0007.MP4`, `DJI_0007.LRF`, `DJI_0007.SRT`.
    public var stem: String { (name as NSString).deletingPathExtension }
}

/// One capture: the original plus its sidecars, grouped by stem.
public struct MediaGroup: Identifiable, Sendable, Hashable {
    public var id: String { stem }
    public var stem: String
    public var files: [RemoteMediaFile]

    public init(stem: String, files: [RemoteMediaFile]) { self.stem = stem; self.files = files.sorted { $0.name < $1.name } }

    public var primary: RemoteMediaFile? { files.first { $0.kind == .video } ?? files.first { $0.kind == .photo } ?? files.first }
    public var proxy: RemoteMediaFile? { files.first { $0.kind == .proxy } }
    public var telemetry: RemoteMediaFile? { files.first { $0.kind == .telemetry } }
    public var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }
    public var kind: MediaKind { primary?.kind ?? .other }
    public var date: Date? { files.compactMap(\.modified).min() }

    /// Group a flat listing into captures. Sidecars without an original stay in their own group.
    public static func group(_ files: [RemoteMediaFile]) -> [MediaGroup] {
        var byStem: [String: [RemoteMediaFile]] = [:]
        for f in files { byStem[f.stem, default: []].append(f) }
        return byStem.map { MediaGroup(stem: $0.key, files: $0.value) }
            .sorted { ($0.date ?? .distantPast, $0.stem) > ($1.date ?? .distantPast, $1.stem) }
    }
}
