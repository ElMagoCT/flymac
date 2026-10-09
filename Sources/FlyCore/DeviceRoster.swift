import Foundation

extension DiscoveredDevice {
    /// Identity that survives unplug/replug and reboots: the USB serial when the
    /// device has one, otherwise VID:PID at its port, otherwise the row id.
    /// Two identical goggles always differ here (different serial or port).
    public var stableKey: String {
        if let u = usb {
            if let s = u.serialNumber, !s.isEmpty { return "usb:\(u.vidPid):\(s)" }
            return "usb:\(u.vidPid)@\(String(u.locationID ?? 0, radix: 16))"
        }
        switch origin {
        case .wifi: return "wifi:\(ssid ?? gateway ?? id)"
        case .volume: return "vol:\(volumeURL?.lastPathComponent ?? id)"
        default: return id
        }
    }
}

/// Labels for everything connected at once. When several devices share a
/// profile (two Goggles N3, three Avata 2 cards) each gets a number that stays
/// put while it is connected, plus a colour slot used everywhere it appears
/// (live tile border, telemetry row, map path). A user nickname always wins.
public struct DeviceRoster: Sendable {
    public struct Label: Sendable, Equatable {
        public var name: String
        /// 1-based number among devices of the same profile, nil when it is the only one.
        public var ordinal: Int?
        /// Index into the UI palette, stable for the device while it stays connected.
        public var colorSlot: Int
        public var isNickname: Bool
    }

    public static let paletteSize = 6

    /// stableKey → ordinal, per profile id. Freed on disconnect so a replugged
    /// device takes the lowest free number again.
    private var ordinals: [String: [String: Int]] = [:]
    private var colors: [String: Int] = [:]
    public private(set) var labels: [String: Label] = [:]   // keyed by DiscoveredDevice.id

    public init() {}

    @discardableResult
    public mutating func update(_ devices: [DiscoveredDevice], nicknames: [String: String] = [:]) -> [String: Label] {
        let present = Set(devices.map(\.stableKey))
        // Free numbers and colours of devices that left.
        for (pid, map) in ordinals { ordinals[pid] = map.filter { present.contains($0.key) } }
        colors = colors.filter { present.contains($0.key) }

        // Assign in first-seen order so the earlier device keeps the lower number.
        let ordered = devices.sorted { ($0.firstSeen, $0.stableKey) < ($1.firstSeen, $1.stableKey) }
        for d in ordered {
            let pid = d.match.profile.id, key = d.stableKey
            var map = ordinals[pid] ?? [:]
            if map[key] == nil {
                let used = Set(map.values)
                map[key] = (1...).first { !used.contains($0) }!
            }
            ordinals[pid] = map
            if colors[key] == nil {
                let used = Set(colors.values)
                colors[key] = (0..<DeviceRoster.paletteSize).first { !used.contains($0) } ?? (colors.count % DeviceRoster.paletteSize)
            }
        }

        var out: [String: Label] = [:]
        for d in devices {
            let pid = d.match.profile.id, key = d.stableKey
            let siblings = ordinals[pid]?.count ?? 1
            let n = ordinals[pid]?[key]
            let ordinal = siblings > 1 ? n : nil
            if let nick = nicknames[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !nick.isEmpty {
                out[d.id] = Label(name: nick, ordinal: ordinal, colorSlot: colors[key] ?? 0, isNickname: true)
            } else {
                let base = d.match.profile.displayName
                out[d.id] = Label(name: ordinal.map { "\(base) \($0)" } ?? base, ordinal: ordinal, colorSlot: colors[key] ?? 0, isNickname: false)
            }
        }
        labels = out
        return out
    }

    public func name(for d: DiscoveredDevice) -> String { labels[d.id]?.name ?? d.title }
    public func colorSlot(for id: String) -> Int { labels[id]?.colorSlot ?? 0 }
}
