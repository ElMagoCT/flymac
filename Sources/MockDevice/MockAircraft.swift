import Foundation
import FlyCore
import DUML
import QuickTransfer

/// The whole fake aircraft: profile, HTTP media server, DUML link, video.
public final class MockAircraft: @unchecked Sendable {
    public static let profile = DeviceProfile(
        id: "mock.aircraft", displayName: "Mock aircraft", vendor: "FlyMac", family: .aircraft,
        wifiSSIDPatterns: ["^FlyMac-Mock"],
        claims: [
            .init(.quickTransfer, via: .mock, evidence: .confirmed, source: "MockDevice"),
            .init(.massStorage, via: .mock, evidence: .confirmed, source: "MockDevice"),
            .init(.usbVideo, via: .mock, evidence: .confirmed, source: "MockDevice"),
            .init(.telemetry, via: .mock, evidence: .confirmed, source: "MockDevice"),
            .init(.dumlSerial, via: .mock, evidence: .confirmed, source: "MockDevice"),
        ],
        quickTransferDialect: "flymac-json",
        notes: "Synthetic aircraft so the app runs without hardware. Everything it reports is fake.")

    public let store: MockMediaStore
    public let server: MockHTTPServer
    public private(set) var duml: MockDUMLLink?
    public private(set) var video: MockVideoSource?

    public init(storeRoot: URL? = nil) {
        store = MockMediaStore(root: storeRoot)
        server = MockHTTPServer(store: store)
    }

    public var base: URL { server.base }

    public func start(progress: (@Sendable (String) -> Void)? = nil) async throws {
        store.onProgress = progress
        await store.prepare()
        try server.start()
    }

    public func makeDUMLLink() -> MockDUMLLink { let l = MockDUMLLink(); duml = l; return l }
    public func makeVideoSource() -> MockVideoSource { let v = MockVideoSource(); video = v; return v }

    public func stop() { server.stop(); duml?.close(); video?.stop() }

    public var discovered: DiscoveredDevice {
        DiscoveredDevice(id: "mock", origin: .mock, match: ProfileMatch(profile: MockAircraft.profile, score: 100, reasons: ["mock device enabled in Settings"]),
                         ssid: "FlyMac-Mock", gateway: "127.0.0.1:\(server.port)", volumeURL: store.root)
    }
}
