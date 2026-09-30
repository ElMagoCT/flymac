import Foundation

/// What a device can do for FlyMac. Every capability is optional and can be
/// hidden entirely in Settings.
public enum Capability: String, Codable, CaseIterable, Sendable, Hashable {
    case quickTransfer   // Wi-Fi media pull from the aircraft's own hotspot
    case massStorage     // SD card mounts as a normal volume over USB
    case usbVideo        // live video reachable over USB (UVC or DUML/bulk)
    case telemetry       // battery / GPS / attitude pushes (DUML) or SRT sidecars
    case cameraControl   // photo / record / exposure / gimbal pitch (never flight)
    case dumlSerial      // a DUML-speaking endpoint exists (needed for telemetry + camera)

    public var title: String {
        switch self {
        case .quickTransfer: return "Quick Transfer"
        case .massStorage:   return "Card as drive"
        case .usbVideo:      return "USB live video"
        case .telemetry:     return "Telemetry"
        case .cameraControl: return "Camera control"
        case .dumlSerial:    return "DUML link"
        }
    }

    public var symbol: String {
        switch self {
        case .quickTransfer: return "wifi"
        case .massStorage:   return "sdcard"
        case .usbVideo:      return "video"
        case .telemetry:     return "gauge.with.dots.needle.33percent"
        case .cameraControl: return "camera.aperture"
        case .dumlSerial:    return "cable.connector"
        }
    }
}

/// How a capability is reached.
public enum TransportKind: String, Codable, CaseIterable, Sendable, Hashable {
    case usbBulk        // vendor-specific bulk endpoints (DUML over USB)
    case usbSerial      // CDC-ACM / serial-over-USB
    case massStorage    // mounted volume
    case uvc            // USB Video Class
    case wifiHTTP       // HTTP on the aircraft's hotspot
    case wifiDUML       // DUML tunnelled over TCP/UDP on the hotspot
    case mock           // MockDevice, no hardware

    public var title: String {
        switch self {
        case .usbBulk: return "USB bulk"
        case .usbSerial: return "USB serial"
        case .massStorage: return "Volume"
        case .uvc: return "UVC"
        case .wifiHTTP: return "Wi-Fi HTTP"
        case .wifiDUML: return "Wi-Fi DUML"
        case .mock: return "Mock"
        }
    }
}

/// How sure we are that a profile's claim is real on actual hardware.
public enum Evidence: String, Codable, Sendable, Comparable {
    case blocked      // tried on hardware and it does not work
    case unverified   // from public docs only, never seen on hardware here
    case likely       // partial evidence (descriptor seen, endpoint present)
    case confirmed    // seen working on real hardware, capture on file

    private var rank: Int {
        switch self { case .blocked: return 0; case .unverified: return 1; case .likely: return 2; case .confirmed: return 3 }
    }
    public static func < (a: Evidence, b: Evidence) -> Bool { a.rank < b.rank }

    public var title: String {
        switch self {
        case .blocked: return "Blocked"
        case .unverified: return "Unverified"
        case .likely: return "Likely"
        case .confirmed: return "Confirmed"
        }
    }
}

public struct CapabilityClaim: Codable, Sendable, Hashable {
    public var capability: Capability
    public var transport: TransportKind
    public var evidence: Evidence
    /// Free text: "seen 2026-09-29, docs/DISCOVERY.md §3" or a URL.
    public var source: String

    public init(_ capability: Capability, via transport: TransportKind, evidence: Evidence = .unverified, source: String = "") {
        self.capability = capability
        self.transport = transport
        self.evidence = evidence
        self.source = source
    }
}
