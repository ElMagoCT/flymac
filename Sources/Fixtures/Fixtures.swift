import Foundation

/// Access to bundled fixtures: recorded/synthetic DUML packets, SRT files and
/// media lists. Everything here runs without hardware.
public enum Fixtures {
    public static var bundle: Bundle { Bundle.module }

    public static func url(_ name: String, ext: String) -> URL? {
        bundle.url(forResource: name, withExtension: ext, subdirectory: "Resources")
            ?? bundle.url(forResource: name, withExtension: ext)
    }

    public static func data(_ name: String, ext: String) throws -> Data {
        guard let u = url(name, ext: ext) else { throw FixtureError.missing("\(name).\(ext)") }
        return try Data(contentsOf: u)
    }

    public static func string(_ name: String, ext: String) throws -> String {
        String(decoding: try data(name, ext: ext), as: UTF8.self)
    }

    public enum FixtureError: Error { case missing(String) }
}
