import Foundation

public enum DeviceFamily: String, Codable, Sendable, CaseIterable {
    case aircraft, remoteController, goggles, captureCard, phone, unknown

    public var title: String {
        switch self {
        case .aircraft: return "Aircraft"
        case .remoteController: return "Remote controller"
        case .goggles: return "Goggles"
        case .captureCard: return "Capture card"
        case .phone: return "Phone"
        case .unknown: return "Unknown"
        }
    }
    public var symbol: String {
        switch self {
        case .aircraft: return "airplane"
        case .remoteController: return "gamecontroller"
        case .goggles: return "visionpro"
        case .captureCard: return "tv"
        case .phone: return "iphone"
        case .unknown: return "questionmark.square.dashed"
        }
    }
}

/// A USB match rule. `productIDs == nil` matches any PID of the vendor.
public struct USBMatch: Codable, Sendable, Hashable {
    public var vendorID: UInt16
    public var productIDs: [UInt16]?
    /// Case-insensitive substring the USB product string must contain, if set.
    public var productNameContains: String?
    /// Interface class that must be present, if set.
    public var requiresInterfaceClass: UInt8?

    public init(vendorID: UInt16, productIDs: [UInt16]? = nil, productNameContains: String? = nil, requiresInterfaceClass: UInt8? = nil) {
        self.vendorID = vendorID; self.productIDs = productIDs
        self.productNameContains = productNameContains; self.requiresInterfaceClass = requiresInterfaceClass
    }
}

/// Everything FlyMac knows about one kind of device. Profiles are data, never
/// code paths; the app asks a profile what it may try and which transport to use.
public struct DeviceProfile: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var displayName: String
    public var vendor: String
    public var family: DeviceFamily
    public var usbMatches: [USBMatch]
    /// Regular expressions matched against a Wi-Fi SSID (e.g. `^Avata2-`).
    public var wifiSSIDPatterns: [String]
    /// Volume name patterns of a mounted card (e.g. `^DJI`), plus expected folders.
    public var volumeNamePatterns: [String]
    public var mediaFolders: [String]
    public var claims: [CapabilityClaim]
    /// How the Quick Transfer HTTP API is spoken, if at all. Filled from capture.
    public var quickTransferDialect: String?
    public var notes: String
    public var sources: [String]

    public init(id: String, displayName: String, vendor: String, family: DeviceFamily,
                usbMatches: [USBMatch] = [], wifiSSIDPatterns: [String] = [], volumeNamePatterns: [String] = [],
                mediaFolders: [String] = ["DCIM/100MEDIA"], claims: [CapabilityClaim] = [],
                quickTransferDialect: String? = nil, notes: String = "", sources: [String] = []) {
        self.id = id; self.displayName = displayName; self.vendor = vendor; self.family = family
        self.usbMatches = usbMatches; self.wifiSSIDPatterns = wifiSSIDPatterns
        self.volumeNamePatterns = volumeNamePatterns; self.mediaFolders = mediaFolders
        self.claims = claims; self.quickTransferDialect = quickTransferDialect
        self.notes = notes; self.sources = sources
    }

    public var isGeneric: Bool { id.hasPrefix("generic.") }

    public func claim(for capability: Capability) -> CapabilityClaim? {
        claims.filter { $0.capability == capability }.max { $0.evidence < $1.evidence }
    }
    public func supports(_ capability: Capability, atLeast evidence: Evidence = .likely) -> Bool {
        guard let c = claim(for: capability) else { return false }
        return c.evidence >= evidence
    }
    public var capabilities: [Capability] { Capability.allCases.filter { claim(for: $0) != nil } }
}

/// The outcome of matching a physical thing against the registry.
public struct ProfileMatch: Sendable, Hashable {
    public var profile: DeviceProfile
    /// 0…100. Exact VID+PID = 100, VID + name = 80, VID only = 50, generic = 10.
    public var score: Int
    public var reasons: [String]

    public init(profile: DeviceProfile, score: Int, reasons: [String]) {
        self.profile = profile; self.score = score; self.reasons = reasons
    }
}
