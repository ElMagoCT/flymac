import Foundation

/// Every input source and tool is optional. "Off" means the UI removes it.
public struct AppSettings: Codable, Sendable, Equatable {
    public enum Source: String, Codable, CaseIterable, Sendable, Identifiable {
        case mockDevice, usbDevices, quickTransfer, mountedCards, uvcCapture, phoneMirror
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .mockDevice: return "Mock aircraft"
            case .usbDevices: return "USB devices"
            case .quickTransfer: return "Quick Transfer (Wi-Fi)"
            case .mountedCards: return "Mounted cards"
            case .uvcCapture: return "UVC capture card"
            case .phoneMirror: return "Phone / RC mirroring"
            }
        }
        public var detail: String {
            switch self {
            case .mockDevice: return "A simulated aircraft with media, telemetry and video. No hardware needed."
            case .usbDevices: return "Watch for DJI hardware over USB-C."
            case .quickTransfer: return "Notice the aircraft's Wi-Fi hotspot and pull media."
            case .mountedCards: return "Notice an SD card or aircraft volume and offer to import."
            case .uvcCapture: return "Any HDMI capture card or webcam as a live source."
            case .phoneMirror: return "Mirror a phone or RC running DJI Fly over wireless ADB."
            }
        }
    }

    public enum Tool: String, Codable, CaseIterable, Sendable, Identifiable {
        case library, liveView, monitorTools, telemetryHUD, flightMap, cameraControl, doctor, menuBar
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .library: return "Library"
            case .liveView: return "Live view"
            case .monitorTools: return "Monitor tools"
            case .telemetryHUD: return "Telemetry HUD"
            case .flightMap: return "Flight map"
            case .cameraControl: return "Camera control"
            case .doctor: return "Doctor"
            case .menuBar: return "Menu bar item"
            }
        }
    }

    public var enabledSources: Set<Source>
    public var enabledTools: Set<Tool>
    public var libraryPath: String
    public var parallelDownloads: Int
    public var verifyHashes: Bool
    public var pairProxies: Bool
    public var autoOfferOnDetect: Bool
    public var recordingCodec: String   // "hevc" | "prores422" | "prores422lt"

    public static let `default` = AppSettings(
        enabledSources: [.mockDevice, .usbDevices, .quickTransfer, .mountedCards, .uvcCapture],
        enabledTools: Set(Tool.allCases),
        libraryPath: NSString("~/Movies/FlyMac Library").expandingTildeInPath,
        parallelDownloads: 3, verifyHashes: true, pairProxies: true, autoOfferOnDetect: true,
        recordingCodec: "hevc")

    public init(enabledSources: Set<Source>, enabledTools: Set<Tool>, libraryPath: String, parallelDownloads: Int,
                verifyHashes: Bool, pairProxies: Bool, autoOfferOnDetect: Bool, recordingCodec: String) {
        self.enabledSources = enabledSources; self.enabledTools = enabledTools; self.libraryPath = libraryPath
        self.parallelDownloads = parallelDownloads; self.verifyHashes = verifyHashes; self.pairProxies = pairProxies
        self.autoOfferOnDetect = autoOfferOnDetect; self.recordingCodec = recordingCodec
    }

    public func isOn(_ s: Source) -> Bool { enabledSources.contains(s) }
    public func isOn(_ t: Tool) -> Bool { enabledTools.contains(t) }

    public static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FlyMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }

    public static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return .default }
        return s
    }

    public func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: AppSettings.fileURL, options: .atomic)
    }
}
