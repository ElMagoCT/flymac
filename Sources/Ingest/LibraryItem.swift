import Foundation
import FlyCore

/// A file that has been imported into the library.
public struct LibraryItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String { relativePath }
    public var relativePath: String      // inside the library root
    public var originalName: String
    public var sourcePath: String        // where it came from
    public var sourceID: String          // profile id / volume name / ssid
    public var size: Int64
    public var sha256: String
    public var importedAt: Date
    public var captured: Date?
    public var kind: MediaKind
    public var stem: String

    public init(relativePath: String, originalName: String, sourcePath: String, sourceID: String, size: Int64, sha256: String,
                importedAt: Date = Date(), captured: Date?, kind: MediaKind, stem: String) {
        self.relativePath = relativePath; self.originalName = originalName; self.sourcePath = sourcePath; self.sourceID = sourceID
        self.size = size; self.sha256 = sha256; self.importedAt = importedAt; self.captured = captured; self.kind = kind; self.stem = stem
    }
}
