import Foundation
import SwiftUI
import AppKit
import FlyCore
import DUML
import USBTransport
import QuickTransfer
import Ingest
import Video
import Telemetry
import MockDevice

/// One object that owns every service and publishes what the views need.
@MainActor
final class AppModel: ObservableObject {
    static let version = "0.1.0"

    @Published var settings: AppSettings { didSet { settings.save(); applySettings(from: oldValue) } }
    @Published var devices: [DiscoveredDevice] = []
    @Published var selection: Route? = .devices
    @Published var selectedDeviceID: String?
    @Published var network: NetworkSnapshot?
    @Published var mockStatus: String = ""
    @Published var toast: String?

    let registry = ProfileRegistry.shared
    let library: MediaLibrary
    let downloader: Downloader
    let usb = USBMonitor()
    let hotspot = HotspotWatcher()
    var mock: MockAircraft?
    let telemetry = TelemetryModel()
    let live = LiveModel()
    let doctor = DoctorModel()
    private var tasks: [Task<Void, Never>] = []
    private var volumeObservers: [NSObjectProtocol] = []

    enum Route: Hashable {
        case devices, media, library, live, telemetry, doctor
        var title: String {
            switch self {
            case .devices: return "Devices"; case .media: return "Media"; case .library: return "Library"
            case .live: return "Live"; case .telemetry: return "Telemetry"; case .doctor: return "Doctor"
            }
        }
        var symbol: String {
            switch self {
            case .devices: return "cable.connector.horizontal"; case .media: return "photo.on.rectangle.angled"; case .library: return "books.vertical"
            case .live: return "dot.radiowaves.left.and.right"; case .telemetry: return "gauge.with.dots.needle.50percent"; case .doctor: return "stethoscope"
            }
        }
    }

    init() {
        let s = AppSettings.load()
        settings = s
        library = MediaLibrary(root: URL(fileURLWithPath: s.libraryPath))
        downloader = Downloader(staging: FileManager.default.temporaryDirectory.appendingPathComponent("FlyMac-staging"), maxParallel: s.parallelDownloads)
        registry.register(MockAircraft.profile)
        start()
        live.refreshOptions(settings: s)
    }

    var visibleRoutes: [Route] {
        var r: [Route] = [.devices]
        if settings.isOn(.quickTransfer) || settings.isOn(.mountedCards) || settings.isOn(.mockDevice) { r.append(.media) }
        if settings.isOn(.library) { r.append(.library) }
        if settings.isOn(.liveView) { r.append(.live) }
        if settings.isOn(.telemetryHUD) || settings.isOn(.flightMap) { r.append(.telemetry) }
        if settings.isOn(.doctor) { r.append(.doctor) }
        return r
    }

    var selectedDevice: DiscoveredDevice? { devices.first { $0.id == selectedDeviceID } ?? devices.first }

    // MARK: lifecycle

    private func start() {
        if settings.isOn(.usbDevices) { startUSB() }
        if settings.isOn(.quickTransfer) { startHotspot() }
        if settings.isOn(.mountedCards) { startVolumes() }
        if settings.isOn(.mockDevice) { startMock() }
        tasks.append(Task { [weak self] in
            guard let self else { return }
            _ = await downloader.observe { jobs in Task { @MainActor in self.handleDownloads(jobs) } }
        })
    }

    private func applySettings(from old: AppSettings) {
        if old.isOn(.usbDevices) != settings.isOn(.usbDevices) { settings.isOn(.usbDevices) ? startUSB() : stopUSB() }
        if old.isOn(.quickTransfer) != settings.isOn(.quickTransfer) { settings.isOn(.quickTransfer) ? startHotspot() : stopHotspot() }
        if old.isOn(.mountedCards) != settings.isOn(.mountedCards) { settings.isOn(.mountedCards) ? startVolumes() : stopVolumes() }
        if old.isOn(.mockDevice) != settings.isOn(.mockDevice) { settings.isOn(.mockDevice) ? startMock() : stopMock() }
        if old.parallelDownloads != settings.parallelDownloads { Task { await downloader.setParallel(settings.parallelDownloads) } }
        if !visibleRoutes.contains(selection ?? .devices) { selection = .devices }
        live.refreshOptions(settings: settings)
    }

    private func upsert(_ d: DiscoveredDevice) {
        if let i = devices.firstIndex(where: { $0.id == d.id }) { devices[i] = d } else { devices.append(d) }
        if selectedDeviceID == nil { selectedDeviceID = d.id }
    }
    private func remove(id: String) {
        devices.removeAll { $0.id == id }
        if selectedDeviceID == id { selectedDeviceID = devices.first?.id }
    }

    // MARK: USB

    private func startUSB() {
        usb.start()
        tasks.append(Task { [weak self] in
            guard let self else { return }
            for await ev in usb.events {
                switch ev {
                case .snapshot(let list): for d in list { self.upsert(self.discovered(usb: d)) }
                case .attached(let d):
                    let dd = self.discovered(usb: d); self.upsert(dd)
                    self.toast = "\(dd.title) connected"
                    self.doctor.note("USB attach: \(d.productName ?? d.vidPid)")
                case .detached(let d):
                    self.remove(id: "usb:\(d.id)")
                    self.telemetry.disconnect(reason: "unplugged")
                    self.doctor.note("USB detach: \(d.productName ?? d.vidPid)")
                }
            }
        })
    }
    private func stopUSB() { usb.stop(); devices.removeAll { $0.origin == .usb } }

    private func discovered(usb d: USBDeviceDescriptor) -> DiscoveredDevice {
        DiscoveredDevice(id: "usb:\(d.id)", origin: .usb, match: registry.match(usb: d), usb: d)
    }

    // MARK: Wi-Fi

    private func startHotspot() {
        hotspot.start()
        tasks.append(Task { [weak self] in
            guard let self else { return }
            for await ev in hotspot.events {
                switch ev {
                case .snapshot(let s): self.network = s
                case .joined(let h):
                    var p = h.match ?? ProfileMatch(profile: BuiltInProfiles.generic, score: 20, reasons: ["hotspot-like gateway answering HTTP"])
                    if let id = h.dialectID { p.profile.quickTransferDialect = id }
                    self.upsert(DiscoveredDevice(id: "wifi:\(h.snapshot.gateway ?? "")", origin: .wifi, match: p, ssid: h.snapshot.ssid, gateway: h.snapshot.gateway))
                    self.toast = "Joined \(h.snapshot.ssid ?? "an aircraft hotspot")"
                case .left:
                    self.devices.removeAll { $0.origin == .wifi }
                }
            }
        })
    }
    private func stopHotspot() { hotspot.stop(); devices.removeAll { $0.origin == .wifi } }

    // MARK: Volumes

    private func startVolumes() {
        let nc = NSWorkspace.shared.notificationCenter
        volumeObservers.append(nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] n in
            guard let url = n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { @MainActor in self?.checkVolume(url, announce: true) }
        })
        volumeObservers.append(nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] n in
            guard let url = n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { @MainActor in self?.remove(id: "vol:\(url.path)") }
        })
        for url in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsRemovableKey], options: [.skipHiddenVolumes]) ?? [] {
            checkVolume(url, announce: false)
        }
    }
    private func stopVolumes() {
        volumeObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        volumeObservers.removeAll(); devices.removeAll { $0.origin == .volume }
    }

    private func checkVolume(_ url: URL, announce: Bool) {
        guard url.path != "/" else { return }
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        guard let m = registry.match(volumeName: url.lastPathComponent, hasFolders: folders) else { return }
        upsert(DiscoveredDevice(id: "vol:\(url.path)", origin: .volume, match: m, volumeURL: url))
        if announce { toast = "Card mounted: \(url.lastPathComponent)"; if settings.autoOfferOnDetect { selection = .media; selectedDeviceID = "vol:\(url.path)" } }
    }

    // MARK: Mock

    private func startMock() {
        let m = MockAircraft(); mock = m
        tasks.append(Task { [weak self] in
            do {
                try await m.start { msg in Task { @MainActor in self?.mockStatus = msg } }
                await MainActor.run {
                    self?.mockStatus = ""
                    self?.upsert(m.discovered)
                }
            } catch { await MainActor.run { self?.mockStatus = "mock failed: \(error.localizedDescription)" } }
        })
    }
    private func stopMock() { mock?.stop(); mock = nil; remove(id: "mock"); telemetry.disconnect(reason: "mock off") }

    // MARK: Downloads → library

    private var imported: Set<String> = []
    private func handleDownloads(_ jobs: [Downloader.Job]) {
        for j in jobs {
            if case .done(let url) = j.state, !imported.contains(j.id) {
                imported.insert(j.id)
                let lib = library, id = selectedDevice?.match.profile.id ?? "unknown", verify = settings.verifyHashes, file = j.file
                Task.detached {
                    let r = lib.importFile(at: url, originalName: file.name, sourceID: id, captured: file.modified, verify: verify, expectedSHA256: file.sha256)
                    try? FileManager.default.removeItem(at: url)
                    await MainActor.run { self.libraryVersion += 1; if case .failed(let m) = r { self.toast = m } }
                }
            }
        }
        downloads = jobs
    }
    @Published var downloads: [Downloader.Job] = []
    @Published var libraryVersion = 0

    /// Where to download from / import from for the selected device.
    func mediaSource(for d: DiscoveredDevice) -> MediaSourceKind? {
        switch d.origin {
        case .mock: return mock.map { .http(base: $0.base, dialect: FlyMacJSONDialect()) }
        case .wifi:
            guard let gw = d.gateway, let base = URL(string: "http://\(gw)/") else { return nil }
            let dialect = d.match.profile.quickTransferDialect.flatMap { DialectRegistry.dialect(id: $0) }
            return .http(base: base, dialect: dialect)
        case .volume: return d.volumeURL.map { .folder($0) }
        case .usb: return nil
        case .uvc: return nil
        }
    }

    enum MediaSourceKind { case http(base: URL, dialect: (any QuickTransferDialect)?); case folder(URL) }

    func download(_ files: [RemoteMediaFile], from source: MediaSourceKind) {
        switch source {
        case .http(let base, let dialect):
            guard let dialect else { toast = "No known API for this device yet. Run Doctor."; return }
            Task { for f in files { await downloader.enqueue(f, from: dialect.downloadURL(base: base, file: f)) } }
        case .folder(let root):
            let lib = library, id = selectedDevice?.match.profile.id ?? "card", verify = settings.verifyHashes
            Task.detached {
                for f in files {
                    _ = lib.importFile(at: root.appendingPathComponent(f.path), sourceID: id, captured: f.modified, verify: verify)
                    await MainActor.run { self.libraryVersion += 1 }
                }
            }
        }
    }

    func revealLibrary() { NSWorkspace.shared.activateFileViewerSelecting([library.root]) }
}

extension Downloader {
    func setParallel(_ n: Int) { maxParallel = max(1, n) }
}
