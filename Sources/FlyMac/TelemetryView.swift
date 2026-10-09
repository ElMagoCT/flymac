import SwiftUI
import DUML
import Telemetry

struct TelemetryView: View {
    @EnvironmentObject var model: AppModel
    @State private var showLog = false

    var ids: [String] { model.sessions.keys.sorted { model.name(forID: $0) < model.name(forID: $1) } }
    var focusedID: String? { model.focusedSessionID.flatMap { model.sessions[$0] != nil ? $0 : nil } ?? ids.first }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if ids.isEmpty { Text("Telemetry").font(.headline) }
                // One chip per linked device; click to focus.
                ForEach(ids, id: \.self) { id in
                    Button { model.focusedSessionID = id } label: {
                        HStack(spacing: 6) {
                            Circle().fill(model.color(forID: id)).frame(width: 7, height: 7)
                            Text(model.name(forID: id)).font(.callout.weight(focusedID == id ? .semibold : .regular)).lineLimit(1)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(focusedID == id ? Theme.panelRaised : .clear, in: Capsule())
                        .overlay(Capsule().stroke(focusedID == id ? model.color(forID: id).opacity(0.5) : Theme.line))
                    }.buttonStyle(.plain)
                }
                Spacer()
                if let id = focusedID { Button("Disconnect") { model.disconnectTelemetry(id, reason: "user") }.controlSize(.small) }
                Toggle("Packet log", isOn: $showLog).toggleStyle(.checkbox).font(.caption).disabled(ids.isEmpty)
            }.padding(.horizontal, 16).padding(.vertical, 10)
            Divider().overlay(Theme.line)
            if let id = focusedID, let t = model.sessions[id] {
                HSplitView {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if ids.count > 1, model.settings.isOn(.telemetryHUD) { FleetPanel(ids: ids) }
                            if model.settings.isOn(.flightMap) { FleetMap(ids: ids, focused: id) }
                            SessionDetail(t: t)
                        }.padding(16)
                    }
                    if showLog { SessionLog(t: t).frame(minWidth: 380) }
                }
                .id(id)
            } else {
                EmptyState(symbol: "gauge.with.dots.needle.50percent", title: "No telemetry link",
                           detail: "Open a read-only link from a device card. Several devices can be linked at once. FlyMac only sends ping and version queries; it never sends control.")
            }
        }
    }
}

/// One row per linked device: the numbers you glance at with several pilots up.
/// Columns no source reports (e.g. signal over DUML OSD) are left out.
private struct FleetPanel: View {
    @EnvironmentObject var model: AppModel
    let ids: [String]

    struct Column { let title: String; let value: (TelemetryFrame) -> String?; var warn: (TelemetryFrame) -> Bool = { _ in false } }
    static let columns: [Column] = [
        Column(title: "Battery", value: { $0.batteryPercent.map { "\($0)%" } }, warn: { ($0.batteryPercent ?? 100) < 25 }),
        Column(title: "Sats", value: { $0.satellites.map(String.init) }),
        Column(title: "Alt", value: { $0.relativeAltitude.map { String(format: "%.1f m", $0) } }),
        Column(title: "Speed", value: { $0.horizontalSpeed.map { String(format: "%.1f m/s", $0) } }),
        Column(title: "Signal", value: { $0.signalPercent.map { "\($0)%" } }, warn: { ($0.signalPercent ?? 100) < 50 }),
        Column(title: "Home", value: { $0.homeDistance.map { String(format: "%.0f m", $0) } }),
    ]

    var body: some View {
        let frames = ids.compactMap { model.sessions[$0]?.latest }
        let cols = FleetPanel.columns.filter { c in frames.contains { c.value($0) != nil } }
        Panel(title: "All linked (\(ids.count))") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    Text("")
                    ForEach(cols.indices, id: \.self) { i in
                        Text(cols[i].title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(Theme.dim)
                    }
                }
                ForEach(ids, id: \.self) { id in
                    if let t = model.sessions[id] { FleetRow(id: id, t: t, columns: cols) }
                }
            }
        }
    }
}

private struct FleetRow: View {
    @EnvironmentObject var model: AppModel
    let id: String
    @ObservedObject var t: TelemetryModel
    let columns: [FleetPanel.Column]
    var body: some View {
        GridRow {
            Button { model.focusedSessionID = id } label: {
                HStack(spacing: 6) {
                    Circle().fill(model.color(forID: id)).frame(width: 7, height: 7)
                    Text(model.name(forID: id)).lineLimit(1)
                }
            }.buttonStyle(.plain)
            ForEach(columns.indices, id: \.self) { i in
                let f = t.latest
                Text(f.flatMap(columns[i].value) ?? "–").font(.system(.callout, design: .rounded)).monospacedDigit()
                    .foregroundStyle(f.map(columns[i].warn) == true ? Theme.warn : Theme.text)
                    .contentTransition(.numericText())
            }
        }
    }
}

/// Every linked device's path on one map, each in its own colour.
private struct FleetMap: View {
    @EnvironmentObject var model: AppModel
    let ids: [String]
    let focused: String
    var body: some View {
        let tracks = ids.compactMap { id -> FlightMap.Track? in
            guard let t = model.sessions[id] else { return nil }
            let pts = t.track.filter(\.hasPosition)
            guard pts.count > 1 else { return nil }
            return FlightMap.Track(id: id, frames: pts, cursor: t.latest, color: model.color(forID: id), emphasised: id == focused)
        }
        if !tracks.isEmpty {
            FlightMap(tracks: tracks).frame(height: 280).clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        }
    }
}

private struct SessionDetail: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var t: TelemetryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle().fill(t.isConnected ? Theme.ok : Theme.dim).frame(width: 8, height: 8)
                Text(t.linkName ?? "No link").font(.callout.weight(.medium))
                Text(t.status).font(.caption).foregroundStyle(Theme.dim)
            }
            if model.settings.isOn(.telemetryHUD) { hud }
            Panel(title: "Handshake (read-only)") {
                if t.handshake.isEmpty { HStack { ProgressView().controlSize(.small); Text("pinging…").font(.caption).foregroundStyle(Theme.dim) } }
                ForEach(t.handshake, id: \.self) { Text($0).font(.caption).monospaced().textSelection(.enabled) }
            }
            if !t.rcWords.isEmpty {
                Panel(title: "RC channel words (raw)") {
                    Text("Move a stick: the word that changes lights up. That is how the layout gets mapped on real hardware.").font(.caption2).foregroundStyle(Theme.dim)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 6) {
                        ForEach(Array(t.rcWords.enumerated()), id: \.offset) { i, w in
                            VStack(spacing: 2) {
                                Text("w\(i)").font(.system(size: 9)).foregroundStyle(Theme.dim)
                                Text("\(w)").font(.callout).monospacedDigit().foregroundStyle(t.rcChanged.contains(i) ? Theme.accent : Theme.text)
                            }.padding(6).background(t.rcChanged.contains(i) ? Theme.accent.opacity(0.15) : Theme.panelRaised, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
            Panel(title: "Pushes seen") {
                ForEach(t.pushCounts.sorted { $0.key < $1.key }, id: \.key) { k, v in
                    HStack { Text(k).monospaced().font(.caption); Spacer(); Text("\(v)").monospacedDigit().font(.caption).foregroundStyle(Theme.dim) }
                }
            }
        }
    }

    var hud: some View {
        let f = t.latest
        return Panel(title: model.name(forID: t.deviceID)) {
            HStack(spacing: 22) {
                Stat(label: "Battery", value: f?.batteryPercent.map(String.init) ?? "–", unit: "%", color: (f?.batteryPercent ?? 100) < 25 ? Theme.warn : Theme.text)
                Stat(label: "Sats", value: f?.satellites.map(String.init) ?? "–")
                Stat(label: "Alt", value: f?.relativeAltitude.map { String(format: "%.1f", $0) } ?? "–", unit: "m")
                Stat(label: "H speed", value: f?.horizontalSpeed.map { String(format: "%.1f", $0) } ?? "–", unit: "m/s")
                Stat(label: "V speed", value: f?.verticalSpeed.map { String(format: "%+.1f", $0) } ?? "–", unit: "m/s")
                Stat(label: "Signal", value: f?.signalPercent.map(String.init) ?? "–", unit: "%")
                Stat(label: "Heading", value: f?.yaw.map { String(format: "%.0f", ($0 + 360).truncatingRemainder(dividingBy: 360)) } ?? "–", unit: "°")
            }
            if let f, f.hasPosition { Text(String(format: "%.6f, %.6f", f.latitude!, f.longitude!)).font(.caption).monospaced().foregroundStyle(Theme.dim).textSelection(.enabled) }
        }
    }
}

private struct SessionLog: View {
    @ObservedObject var t: TelemetryModel
    var body: some View { PacketLog(entries: t.log) }
}

struct PacketLog: View {
    let entries: [DUMLSession.LogEntry]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("DUML log").font(.headline).padding(12)
            Divider().overlay(Theme.line)
            ScrollViewReader { proxy in
                List(entries) { e in
                    HStack(alignment: .top, spacing: 8) {
                        Text(e.date, format: .dateTime.hour().minute().second().secondFraction(.fractional(3))).font(.caption2).monospaced().foregroundStyle(Theme.dim)
                        Image(systemName: e.direction == .sent ? "arrow.up" : e.direction == .blocked ? "nosign" : "arrow.down").font(.caption2)
                            .foregroundStyle(e.direction == .sent ? Theme.accent : e.direction == .blocked ? Theme.bad : Theme.dim)
                        Text("\(e.packet)").font(.caption2).monospaced().textSelection(.enabled)
                    }.id(e.id)
                }.listStyle(.plain).scrollContentBackground(.hidden)
                .onChange(of: entries.count) { _, _ in if let l = entries.last { proxy.scrollTo(l.id) } }
            }
        }.background(Theme.panel)
    }
}
