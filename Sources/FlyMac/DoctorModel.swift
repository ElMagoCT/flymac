import Foundation
import SwiftUI
import AppKit
import FlyCore
import USBTransport
import QuickTransfer
import DUML

/// Builds the shareable Doctor report. Same gathering code as `flymac-doctor`.
@MainActor
final class DoctorModel: ObservableObject {
    @Published var report: String = ""
    @Published var running = false
    @Published var progress: String = ""
    @Published var events: [String] = []

    func note(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        events.append("\(f.string(from: Date()))  \(s)")
        if events.count > 500 { events.removeFirst() }
    }

    func run(devices: [DiscoveredDevice], registry: ProfileRegistry, handshake: [String], scanGateway: Bool) async {
        running = true; defer { running = false }
        progress = "USB…"
        var sections: [DoctorSection] = []
        sections.append(DoctorSection("Discovered devices", devices.isEmpty ? "(none)" : devices.map { "\($0.origin.rawValue.uppercased())  \($0.title)  \($0.subtitle)  profile=\($0.match.profile.id) score=\($0.match.score)" }.joined(separator: "\n")))
        let usb = await Task.detached { USBEnumerator.allDevices() }.value
        sections.append(DoctorSection("USB devices (\(usb.count))", usb.isEmpty ? "(none attached)" : usb.map { DoctorReport.describe($0, match: registry.match(usb: $0)) }.joined(separator: "\n")))
        progress = "Network…"
        let net = NetworkInfo.snapshot()
        sections.append(DoctorSection("Network", net.summary + "\nhotspot-like: \(NetworkInfo.looksLikeDeviceHotspot(net))"))
        if scanGateway, let gw = net.gateway, NetworkInfo.looksLikeDeviceHotspot(net) {
            progress = "Scanning \(gw)…"
            let open = await PortScanner.scan(host: gw).filter(\.open)
            sections.append(DoctorSection("Open TCP ports on \(gw)", open.isEmpty ? "(none of \(PortScanner.interestingPorts.count) probed)" : open.map { "\($0.port)  \(Int($0.latencyMs ?? 0)) ms  \($0.banner ?? "")" }.joined(separator: "\n")))
            if open.contains(where: { $0.port == 80 }), let base = URL(string: "http://\(gw)/") {
                progress = "HTTP sweep…"
                let ex = await HTTPProbe.sweep(base: base)
                sections.append(DoctorSection("HTTP sweep", ex.map(\.summary).joined(separator: "\n")))
                let saved = DoctorModel.saveFixtures(ex, name: "http-\(gw)")
                sections.append(DoctorSection("Saved fixtures", saved?.path ?? "(not saved)"))
            }
        }
        if !handshake.isEmpty { sections.append(DoctorSection("DUML read-only handshake", handshake.joined(separator: "\n"))) }
        sections.append(DoctorSection("Profiles known", registry.profiles.map { "\($0.id)  \($0.displayName)  \($0.claims.map { "\($0.capability.rawValue)=\($0.evidence.rawValue)" }.joined(separator: " "))" }.joined(separator: "\n")))
        sections.append(DoctorSection("Session events", events.suffix(50).joined(separator: "\n")))
        progress = "ioreg…"
        let ioreg = await Task.detached { USBEnumerator.rawRegistryDump() }.value
        sections.append(DoctorSection("ioreg -p IOUSB -l", ioreg))
        progress = "system_profiler…"
        let sp = await Task.detached { USBEnumerator.systemProfilerDump() }.value
        sections.append(DoctorSection("system_profiler SPUSBDataType", sp))
        report = DoctorReport(appVersion: AppModel.version, sections: sections).text
        progress = ""
    }

    static func saveFixtures(_ ex: [HTTPExchange], name: String) -> URL? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FlyMac/captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let url = dir.appendingPathComponent("\(name)-\(f.string(from: Date()).replacingOccurrences(of: ":", with: "")).json")
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(ex), (try? data.write(to: url)) != nil else { return nil }
        return url
    }

    func copy() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(report, forType: .string) }

    func save() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "FlyMac Doctor.txt"
        p.begin { [report] r in if r == .OK, let u = p.url { try? report.write(to: u, atomically: true, encoding: .utf8) } }
    }
}
