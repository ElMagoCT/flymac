import Foundation

/// Something the app has noticed and can act on. One physical device may
/// appear more than once (Avata 2 over USB and over Wi-Fi) — that is fine,
/// each row is one transport.
public struct DiscoveredDevice: Identifiable, Sendable, Hashable {
    public enum Origin: String, Sendable, Codable { case usb, wifi, volume, uvc, mock }

    public var id: String
    public var origin: Origin
    public var match: ProfileMatch
    public var usb: USBDeviceDescriptor?
    public var ssid: String?
    public var gateway: String?
    public var volumeURL: URL?
    public var firstSeen: Date
    public var lastSeen: Date

    public init(id: String, origin: Origin, match: ProfileMatch, usb: USBDeviceDescriptor? = nil, ssid: String? = nil,
                gateway: String? = nil, volumeURL: URL? = nil, firstSeen: Date = Date(), lastSeen: Date = Date()) {
        self.id = id; self.origin = origin; self.match = match; self.usb = usb; self.ssid = ssid
        self.gateway = gateway; self.volumeURL = volumeURL; self.firstSeen = firstSeen; self.lastSeen = lastSeen
    }

    public var title: String { match.profile.displayName }
    public var subtitle: String {
        switch origin {
        case .usb: return usb.map { "USB  \($0.vidPid)" } ?? "USB"
        case .wifi: return "Wi-Fi  \(ssid ?? "")  \(gateway ?? "")"
        case .volume: return "Volume  \(volumeURL?.lastPathComponent ?? "")"
        case .uvc: return "UVC"
        case .mock: return "Mock  no hardware"
        }
    }
}

extension ProfileMatch {
    public func hash(into hasher: inout Hasher) { hasher.combine(profile.id); hasher.combine(score) }
}
