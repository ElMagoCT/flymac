import Foundation

/// One section of a Doctor report. Sections are plain text so a report can be
/// pasted into an issue and turned into a profile later.
public struct DoctorSection: Sendable, Hashable {
    public var title: String
    public var body: String
    public init(_ title: String, _ body: String) { self.title = title; self.body = body }
}

public struct DoctorReport: Sendable {
    public var generatedAt: Date
    public var appVersion: String
    public var sections: [DoctorSection]

    public init(appVersion: String, sections: [DoctorSection], generatedAt: Date = Date()) {
        self.appVersion = appVersion; self.sections = sections; self.generatedAt = generatedAt
    }

    public var text: String {
        let f = ISO8601DateFormatter()
        var out = "FlyMac Doctor report\nGenerated: \(f.string(from: generatedAt))\nApp: \(appVersion)\n"
        out += "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        for s in sections {
            out += "\n== \(s.title) ==\n\(s.body.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }
        return out
    }

    /// Render a USB descriptor + its profile match the way the report expects.
    public static func describe(_ d: USBDeviceDescriptor, match: ProfileMatch) -> String {
        var s = "\(d.productName ?? "(no product string)")  \(d.vidPid)\n"
        s += "  vendor: \(d.vendorName ?? "?")  serial: \(d.serialNumber ?? "?")  speed: \(d.speed ?? "?")\n"
        if let c = d.deviceClass { s += String(format: "  device class %02x/%02x/%02x", c, d.deviceSubClass ?? 0, d.deviceProtocol ?? 0) }
        if let b = d.bcdDevice { s += String(format: "  bcdDevice %04x", b) }
        if let u = d.usbVersion { s += String(format: "  usb %x.%02x", u >> 8, u & 0xff) }
        s += "\n  claimed by: \(d.claimedBy ?? "nothing")\n"
        for i in d.interfaces {
            s += String(format: "  if %d alt %d  class %02x/%02x/%02x %@%@\n", i.number, i.alternateSetting,
                        i.interfaceClass, i.interfaceSubClass, i.interfaceProtocol, i.className,
                        i.claimedBy.map { "  driver: \($0)" } ?? "")
            for e in i.endpoints {
                s += String(format: "     ep 0x%02x %@ %@ max %d int %d\n", e.address, e.direction.rawValue.uppercased(),
                            e.kind.rawValue, e.maxPacketSize, e.interval)
            }
        }
        s += "  profile: \(match.profile.id) (\(match.profile.displayName)) score \(match.score)\n"
        for r in match.reasons { s += "    - \(r)\n" }
        for c in match.profile.claims {
            s += "    \(c.capability.title) via \(c.transport.title): \(c.evidence.title)\n"
        }
        return s
    }
}
