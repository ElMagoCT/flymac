import Foundation
import FlyCore

/// A simulated pair of Goggles N3 watching its own simulated aircraft. Several
/// can run at once so multi-goggles support is testable without hardware.
/// Everything it reports is fake; it never claims real Goggles N3 behaviour.
public final class MockGoggles: @unchecked Sendable {
    public static let profile = DeviceProfile(
        id: "mock.goggles", displayName: "Goggles N3 (mock)", vendor: "FlyMac", family: .goggles,
        claims: [
            .init(.usbVideo, via: .mock, evidence: .confirmed, source: "MockDevice"),
            .init(.telemetry, via: .mock, evidence: .confirmed, source: "MockDevice"),
            .init(.dumlSerial, via: .mock, evidence: .confirmed, source: "MockDevice"),
        ],
        notes: "Simulated goggles. Real Goggles N3 USB video is unverified until Phase 0.")

    public let index: Int          // 1-based
    public let flight: SyntheticFlight
    public let firstSeen = Date()
    public private(set) var duml: MockDUMLLink?
    public private(set) var video: MockVideoSource?

    public init(index: Int) {
        self.index = index
        flight = SyntheticFlight(variant: index)
    }

    public var id: String { "mock-goggles-\(index)" }
    public var serial: String { String(format: "MOCKG%05d", index) }

    public func makeVideoSource() -> MockVideoSource {
        let v = MockVideoSource(width: 960, height: 540, fps: 30, flight: flight, name: "Mock goggles \(index) (H.264)", osdLabel: "MOCK G\(index)")
        video = v
        return v
    }

    public func makeDUMLLink() -> MockDUMLLink {
        let l = MockDUMLLink(flight: flight, name: "Mock goggles \(index) DUML")
        duml = l
        return l
    }

    public func stop() { duml?.close(); video?.stop() }

    public var discovered: DiscoveredDevice {
        // A fake USB descriptor so the roster keys it by serial like real goggles.
        let usb = USBDeviceDescriptor(vendorID: 0xF1F1, productID: 0x0003, vendorName: "FlyMac", productName: "Goggles N3 (mock)",
                                      serialNumber: serial, locationID: UInt32(0xF000_0000 + index))
        return DiscoveredDevice(id: id, origin: .mock, match: ProfileMatch(profile: MockGoggles.profile, score: 100, reasons: ["mock goggles enabled in Settings"]),
                                usb: usb, firstSeen: firstSeen)
    }
}
