import Foundation
import CoreWLAN
import SystemConfiguration

/// What the Mac's network looks like right now. SSID needs Location permission
/// on modern macOS; when it is nil we still have the gateway, which is enough
/// to notice a drone hotspot (they hand out 192.168.x.1-style gateways and
/// answer on port 80).
public struct NetworkSnapshot: Sendable, Equatable {
    public var interface: String?
    public var ssid: String?
    public var bssid: String?
    public var ipAddress: String?
    public var gateway: String?
    public var rssi: Int?
    public var channel: Int?
    public var takenAt: Date

    public var summary: String {
        var parts: [String] = []
        if let ssid { parts.append("SSID \(ssid)") } else { parts.append("SSID unavailable (Location permission)") }
        if let ipAddress { parts.append("ip \(ipAddress)") }
        if let gateway { parts.append("gw \(gateway)") }
        if let rssi { parts.append("\(rssi) dBm") }
        if let channel { parts.append("ch \(channel)") }
        return parts.joined(separator: "  ")
    }
}

public enum NetworkInfo {
    public static func snapshot() -> NetworkSnapshot {
        var s = NetworkSnapshot(takenAt: Date())
        if let wifi = CWWiFiClient.shared().interface() {
            s.interface = wifi.interfaceName
            s.ssid = wifi.ssid()
            s.bssid = wifi.bssid()
            let r = wifi.rssiValue(); if r != 0 { s.rssi = r }
            s.channel = wifi.wlanChannel()?.channelNumber
        }
        if let store = SCDynamicStoreCreate(nil, "FlyMac" as CFString, nil, nil) {
            if let g = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
                s.gateway = g["Router"] as? String
                if s.interface == nil { s.interface = g["PrimaryInterface"] as? String }
            }
            if let iface = s.interface,
               let v = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(iface)/IPv4" as CFString) as? [String: Any] {
                s.ipAddress = (v["Addresses"] as? [String])?.first
                if s.gateway == nil { s.gateway = (v["Router"] as? String) }
            }
        }
        return s
    }

    /// True when this looks like a device hotspot rather than home Wi-Fi:
    /// a private /24 gateway ending in .1 and no DNS-looking upstream is the
    /// weak heuristic; the SSID pattern (if readable) is the strong one.
    public static func looksLikeDeviceHotspot(_ s: NetworkSnapshot) -> Bool {
        guard let gw = s.gateway else { return false }
        let parts = gw.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        let isPrivate = parts[0] == 192 && parts[1] == 168 || parts[0] == 10 || parts[0] == 172 && (16...31).contains(parts[1])
        return isPrivate && parts[3] == 1
    }
}
