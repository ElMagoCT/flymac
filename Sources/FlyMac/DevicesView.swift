import SwiftUI
import FlyCore
import USBTransport
import MockDevice

struct DevicesView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.devices.isEmpty {
            EmptyState(symbol: "cable.connector.horizontal", title: "Plug something in",
                       detail: "USB-C to an aircraft, controller or goggles. Or join the aircraft's Quick Transfer Wi-Fi. Or enable the mock aircraft in Settings.")
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 14)], alignment: .leading, spacing: 14) {
                    ForEach(model.devices) { d in DeviceCard(device: d).onTapGesture { model.selectedDeviceID = d.id } }
                }.padding(18)
            }
        }
    }
}

struct DeviceCard: View {
    @EnvironmentObject var model: AppModel
    let device: DiscoveredDevice
    @State private var showReasons = false
    @State private var connecting = false

    var profile: DeviceProfile { device.match.profile }
    var selected: Bool { model.selectedDeviceID == device.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: profile.family.symbol).font(.system(size: 26, weight: .light)).foregroundStyle(Theme.accent).frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.title).font(.title3.weight(.semibold))
                    Text(device.subtitle).font(.caption).foregroundStyle(Theme.dim).monospaced()
                }
                Spacer()
                Chip(text: "\(device.match.score)", symbol: profile.isGeneric ? "questionmark" : "checkmark", color: device.match.score >= 80 ? Theme.ok : device.match.score >= 50 ? Theme.warn : Theme.dim)
                    .help(device.match.reasons.joined(separator: "\n"))
            }
            // Capabilities, coloured by evidence. Unverified stays grey on purpose.
            FlowLayout(spacing: 6) {
                ForEach(Capability.allCases, id: \.self) { c in
                    if let claim = profile.claim(for: c) {
                        Chip(text: c.title, symbol: c.symbol, color: Theme.color(for: claim.evidence)).help("\(claim.evidence.title) via \(claim.transport.title)\n\(claim.source)")
                    }
                }
                if profile.claims.isEmpty { Chip(text: "nothing proven yet", symbol: "questionmark.circle") }
            }
            if let u = device.usb {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(u.interfaces, id: \.self) { i in
                        HStack(spacing: 8) {
                            Text(String(format: "if %d", i.number)).monospaced()
                            Text(i.className)
                            Text(i.endpoints.map { String(format: "%@%02x", $0.direction == .in ? "↑" : "↓", $0.address) }.joined(separator: " ")).monospaced().foregroundStyle(Theme.dim)
                            Spacer()
                            if let c = i.claimedBy { Text(c).foregroundStyle(Theme.dim).lineLimit(1) }
                        }.font(.caption)
                    }
                    if u.interfaces.isEmpty { Text("no interfaces visible").font(.caption).foregroundStyle(Theme.dim) }
                }
            }
            HStack(spacing: 8) {
                if model.mediaSource(for: device) != nil {
                    Button { model.selectedDeviceID = device.id; model.selection = .media } label: { Label("Media", systemImage: "photo.on.rectangle.angled") }
                }
                if canConnectDUML {
                    Button { connectDUML() } label: {
                        if connecting { ProgressView().controlSize(.small) } else { Label("Read-only link", systemImage: "waveform.path.ecg") }
                    }.disabled(connecting)
                }
                Spacer()
                Button { model.selection = .doctor } label: { Label("Doctor", systemImage: "stethoscope") }
            }
            .controlSize(.small)
        }
        .padding(16)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(selected ? Theme.accent.opacity(0.6) : Theme.line, lineWidth: selected ? 1.5 : 1))
        .animation(.easeOut(duration: 0.2), value: selected)
    }

    var canConnectDUML: Bool {
        if device.origin == .mock { return true }
        guard let u = device.usb else { return false }
        return u.interfaces.contains { $0.interfaceClass == USBClass.vendorSpecific && $0.endpoints.contains { $0.kind == .bulk } }
    }

    func connectDUML() {
        connecting = true
        defer { connecting = false }
        if device.origin == .mock, let m = model.mock {
            model.telemetry.connect(link: m.makeDUMLLink())
        } else if let u = device.usb {
            do { model.telemetry.connect(link: try USBBulkLink(device: u)) }
            catch { model.toast = "\(error)"; model.doctor.note("DUML link failed: \(error)"); return }
        }
        model.selection = .telemetry
    }
}

/// Simple wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > w, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
        return CGSize(width: w, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}
