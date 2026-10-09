import Foundation

/// Registry of device profiles. Built-in profiles ship with the app; user
/// profiles (JSON in Application Support) can override or add. Matching never
/// returns nil: an unknown device gets a generic profile so the Doctor can
/// still describe it and the UI can still offer what could be probed.
public final class ProfileRegistry: @unchecked Sendable {
    public static let shared = ProfileRegistry()

    private let lock = NSLock()
    private var _profiles: [DeviceProfile]

    public init(profiles: [DeviceProfile] = BuiltInProfiles.all) {
        _profiles = profiles
    }

    public var profiles: [DeviceProfile] { lock.withLock { _profiles } }

    public func register(_ profile: DeviceProfile) {
        lock.withLock {
            _profiles.removeAll { $0.id == profile.id }
            _profiles.append(profile)
        }
    }

    public func profile(id: String) -> DeviceProfile? { profiles.first { $0.id == id } }

    // MARK: USB

    public func match(usb d: USBDeviceDescriptor) -> ProfileMatch {
        var best: ProfileMatch?
        for p in profiles where !p.isGeneric {
            for m in p.usbMatches where m.vendorID == d.vendorID {
                var score = 50
                var reasons = [String(format: "vendor 0x%04x matches %@", d.vendorID, p.vendor)]
                if let pids = m.productIDs {
                    guard pids.contains(d.productID) else { continue }
                    score = 100
                    reasons.append(String(format: "product 0x%04x listed in profile", d.productID))
                }
                if let needle = m.productNameContains {
                    guard let name = d.productName, name.localizedCaseInsensitiveContains(needle) else { continue }
                    score = max(score, 80)
                    reasons.append("product name contains “\(needle)”")
                }
                if let cls = m.requiresInterfaceClass {
                    guard d.interfaces.contains(where: { $0.interfaceClass == cls }) else { continue }
                    reasons.append("has \(USBClass.name(cls)) interface")
                }
                if best == nil || score > best!.score {
                    best = ProfileMatch(profile: p, score: score, reasons: reasons)
                }
            }
        }
        if let best { return best }
        return generic(for: d)
    }

    /// Build a generic profile from what the descriptors alone prove.
    public func generic(for d: USBDeviceDescriptor) -> ProfileMatch {
        var claims: [CapabilityClaim] = []
        var reasons: [String] = []
        let classes = Set(d.interfaces.map(\.interfaceClass))
        if classes.contains(USBClass.massStorage) {
            claims.append(.init(.massStorage, via: .massStorage, evidence: .likely, source: "mass-storage interface present"))
            reasons.append("mass-storage interface")
        }
        if classes.contains(USBClass.video) {
            claims.append(.init(.usbVideo, via: .uvc, evidence: .likely, source: "UVC interface present"))
            reasons.append("UVC interface")
        }
        if classes.contains(USBClass.cdcControl) || classes.contains(USBClass.cdcData) {
            claims.append(.init(.dumlSerial, via: .usbSerial, evidence: .unverified, source: "CDC interface present; may carry DUML"))
            reasons.append("CDC serial interface")
        }
        if d.interfaces.contains(where: { $0.interfaceClass == USBClass.vendorSpecific && $0.endpoints.contains { $0.kind == .bulk } }) {
            claims.append(.init(.dumlSerial, via: .usbBulk, evidence: .unverified, source: "vendor-specific bulk endpoints present"))
            reasons.append("vendor bulk endpoints")
        }
        let isDJI = d.vendorID == USBVendor.dji
        let base = isDJI ? BuiltInProfiles.djiUnknown : BuiltInProfiles.generic
        var p = base
        p.claims = claims
        p.displayName = d.productName ?? base.displayName
        if reasons.isEmpty { reasons.append("no recognisable interface class") }
        return ProfileMatch(profile: p, score: isDJI ? 30 : 10, reasons: reasons)
    }

    // MARK: Wi-Fi

    public func match(ssid: String) -> ProfileMatch? {
        for p in profiles {
            for pattern in p.wifiSSIDPatterns {
                if ssid.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                    return ProfileMatch(profile: p, score: 80, reasons: ["SSID “\(ssid)” matches /\(pattern)/"])
                }
            }
        }
        return nil
    }

    // MARK: Volumes

    public func match(volumeName: String, hasFolders folders: [String]) -> ProfileMatch? {
        for p in profiles {
            for pattern in p.volumeNamePatterns {
                if volumeName.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                    return ProfileMatch(profile: p, score: 70, reasons: ["volume “\(volumeName)” matches /\(pattern)/"])
                }
            }
        }
        if folders.contains(where: { $0.uppercased().hasPrefix("DCIM") }) {
            var p = BuiltInProfiles.generic
            p.displayName = volumeName
            p.claims = [.init(.massStorage, via: .massStorage, evidence: .confirmed, source: "mounted volume with DCIM")]
            return ProfileMatch(profile: p, score: 40, reasons: ["volume has a DCIM folder"])
        }
        return nil
    }
}

/// Profiles that ship in the binary. Evidence levels here are the *starting*
/// point; Phase 0 discovery (docs/DISCOVERY.md) upgrades or blocks them, and
/// the PID lists are filled from real descriptors, never guessed.
public enum BuiltInProfiles {
    public static let dji = "DJI"

    public static let avata2 = DeviceProfile(
        id: "dji.avata2", displayName: "DJI Avata 2", vendor: dji, family: .aircraft,
        usbMatches: [USBMatch(vendorID: USBVendor.dji, productNameContains: "Avata")],
        wifiSSIDPatterns: ["^Avata ?2", "^DJI[-_ ]?Avata"],
        volumeNamePatterns: ["^AVATA", "^DJI"],
        mediaFolders: ["DCIM/100MEDIA", "DCIM/101MEDIA"],
        claims: [
            .init(.massStorage, via: .massStorage, evidence: .unverified, source: "DJI manual: connect to computer to read card"),
            .init(.quickTransfer, via: .wifiHTTP, evidence: .unverified, source: "DJI Fly QuickTransfer feature; endpoints to be captured"),
            .init(.dumlSerial, via: .usbBulk, evidence: .unverified, source: "DJI Assistant 2 talks DUML over USB"),
            .init(.telemetry, via: .usbBulk, evidence: .unverified, source: "DUML FC pushes (dji-firmware-tools comm_dissector)"),
        ],
        notes: "O4 video system. Pairs with Goggles N3 / Goggles 3 and RC Motion 3; does NOT pair with RC-N2.",
        sources: ["https://www.dji.com/avata-2/specs", "https://github.com/o-gs/dji-firmware-tools"])

    public static let gogglesN3 = DeviceProfile(
        id: "dji.goggles-n3", displayName: "DJI Goggles N3", vendor: dji, family: .goggles,
        usbMatches: [USBMatch(vendorID: USBVendor.dji, productIDs: [0x0020]),   // seen 2026-10-08, DISCOVERY 3c
                     USBMatch(vendorID: USBVendor.dji, productNameContains: "Goggles")],
        claims: [
            .init(.massStorage, via: .massStorage, evidence: .unverified, source: "goggles have a microSD slot"),
            .init(.usbVideo, via: .usbBulk, evidence: .unverified, source: "DJI Fly wired live view; transport unknown until captured"),
            .init(.dumlSerial, via: .usbBulk, evidence: .unverified, source: "DJI Assistant 2 talks DUML over USB"),
        ],
        notes: "O4 goggles. Live view to a phone goes through DJI Fly over USB; whether any of that is reachable without the app is a Phase 0 question.",
        sources: ["https://www.dji.com/goggles-n3/specs"])

    public static let rcN2 = DeviceProfile(
        id: "dji.rc-n2", displayName: "DJI RC-N2", vendor: dji, family: .remoteController,
        usbMatches: [USBMatch(vendorID: USBVendor.dji, productNameContains: "RC")],
        claims: [
            .init(.dumlSerial, via: .usbBulk, evidence: .unverified, source: "DJI Assistant 2 firmware updates use DUML over USB"),
            .init(.telemetry, via: .usbBulk, evidence: .unverified, source: "RC pushes stick/button state as DUML cmd-set 6"),
            .init(.usbVideo, via: .usbBulk, evidence: .unverified, source: "RC forwards aircraft video to the phone only while paired"),
        ],
        notes: "Pairs with Mini 4 Pro, Air 3, Mini 3 family. Not compatible with Avata 2 (O4 FPV). Unpaired it can still enumerate and report sticks.",
        sources: ["https://www.dji.com/rc-n2"])

    public static let djiUnknown = DeviceProfile(
        id: "generic.dji", displayName: "DJI device", vendor: dji, family: .unknown,
        usbMatches: [USBMatch(vendorID: USBVendor.dji)],
        notes: "A DJI USB device the registry has no profile for. Run Doctor and add a profile from the report.",
        sources: [])

    public static let uvcCapture = DeviceProfile(
        id: "generic.uvc", displayName: "UVC capture device", vendor: "", family: .captureCard,
        claims: [.init(.usbVideo, via: .uvc, evidence: .confirmed, source: "AVFoundation external camera")],
        notes: "Any HDMI capture card or webcam that speaks UVC. Fallback ladder step 1 for live video.")

    public static let generic = DeviceProfile(
        id: "generic.unknown", displayName: "Unknown device", vendor: "", family: .unknown,
        notes: "Not a known device. Only capabilities proven by its USB descriptors are offered.")

    public static let all: [DeviceProfile] = [avata2, gogglesN3, rcN2, djiUnknown, uvcCapture, generic]
}
