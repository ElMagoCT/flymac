import AppKit
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
    @State private var renaming = false
    @State private var draftName = ""

    var profile: DeviceProfile { device.match.profile }
    var selected: Bool { model.selectedDeviceID == device.id }
    var color: Color { model.color(forID: device.id) }
    var linked: Bool { model.session(for: device.id) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: profile.family.symbol).font(.system(size: 26, weight: .light)).foregroundStyle(color).frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.name(for: device)).font(.title3.weight(.semibold))
                        Button { draftName = model.labels[device.id]?.isNickname == true ? model.name(for: device) : ""; renaming = true } label: {
                            Image(systemName: "pencil").font(.caption)
                        }
                        .buttonStyle(.plain).foregroundStyle(Theme.dim).help("Name this device (remembered by serial)")
                        .popover(isPresented: $renaming, arrowEdge: .bottom) { renamePopover }
                    }
                    Text(subtitle).font(.caption).foregroundStyle(Theme.dim).monospaced()
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
            if device.usb?.blockedByMacOS == true {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.shield").foregroundStyle(Theme.warn)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("macOS is blocking this accessory").font(.callout.weight(.medium))
                        Text("Allow it when macOS asks, or in System Settings → Privacy & Security → Allow accessories to connect.")
                            .font(.caption).foregroundStyle(Theme.dim)
                    }
                    Spacer()
                    Button("Open") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")!) }.controlSize(.small)
                }
                .padding(10).background(Theme.warn.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
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
                if let opt = model.liveOption(forDevice: device.id), model.settings.isOn(.liveView) {
                    Button {
                        Task { await model.live.show(opt) }
                        model.selection = .live
                    } label: { Label(model.live.tile(showing: opt.id) != nil ? "On screen" : "Watch live", systemImage: "play.rectangle") }
                }
                if model.canLinkTelemetry(device) {
                    if linked {
                        Button { model.focusedSessionID = device.id; model.selection = .telemetry } label: {
                            HStack(spacing: 5) { Circle().fill(Theme.ok).frame(width: 6, height: 6); Text("Linked") }
                        }
                        Button { model.disconnectTelemetry(device.id, reason: "user") } label: { Image(systemName: "xmark.circle") }.help("Close the read-only link")
                    } else {
                        Button { model.connectTelemetry(device); if model.session(for: device.id) != nil { model.selection = .telemetry } } label: {
                            Label("Read-only link", systemImage: "waveform.path.ecg")
                        }
                    }
                }
                Spacer()
                Button { model.selection = .doctor } label: { Label("Doctor", systemImage: "stethoscope") }
            }
            .controlSize(.small)
        }
        .padding(16)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(selected ? color.opacity(0.6) : Theme.line, lineWidth: selected ? 1.5 : 1))
        .animation(.easeOut(duration: 0.2), value: selected)
    }

    /// Model name under a nickname, serial tail for telling identical units apart.
    var subtitle: String {
        var parts = [device.subtitle]
        if model.labels[device.id]?.isNickname == true { parts.insert(device.title, at: 0) }
        if let s = device.usb?.serialNumber, !s.isEmpty, model.labels[device.id]?.ordinal != nil { parts.append("…" + String(s.suffix(4))) }
        return parts.joined(separator: "  ")
    }

    var renamePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Name").font(.headline)
            TextField(device.title, text: $draftName).textFieldStyle(.roundedBorder).frame(width: 220)
                .onSubmit { model.setNickname(draftName, for: device); renaming = false }
            HStack {
                if model.labels[device.id]?.isNickname == true {
                    Button("Reset") { model.setNickname("", for: device); renaming = false }
                }
                Spacer()
                Button("Save") { model.setNickname(draftName, for: device); renaming = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(14)
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
