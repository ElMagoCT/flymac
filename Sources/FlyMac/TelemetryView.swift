import SwiftUI
import DUML
import Telemetry

struct TelemetryView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { TelemetryBody(t: model.telemetry) }
}

private struct TelemetryBody: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var t: TelemetryModel
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle().fill(t.isConnected ? Theme.ok : Theme.dim).frame(width: 8, height: 8)
                Text(t.linkName ?? "No link").font(.headline)
                Text(t.status).font(.caption).foregroundStyle(Theme.dim)
                Spacer()
                if t.isConnected { Button("Disconnect") { t.disconnect(reason: "user") }.controlSize(.small) }
                Toggle("Packet log", isOn: $showLog).toggleStyle(.checkbox).font(.caption)
            }.padding(.horizontal, 16).padding(.vertical, 10)
            Divider().overlay(Theme.line)
            if !t.isConnected {
                EmptyState(symbol: "gauge.with.dots.needle.50percent", title: "No telemetry link",
                           detail: "Open a read-only link from a device card. FlyMac only sends ping and version queries; it never sends control.")
            } else {
                HSplitView {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if model.settings.isOn(.telemetryHUD) { hud }
                            if model.settings.isOn(.flightMap), t.track.filter(\.hasPosition).count > 1 {
                                FlightMap(frames: t.track.filter(\.hasPosition), cursor: t.latest).frame(height: 280).clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                            }
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
                        }.padding(16)
                    }
                    if showLog { PacketLog(entries: t.log).frame(minWidth: 380) }
                }
            }
        }
    }

    var hud: some View {
        let f = t.latest
        return Panel(title: "Live") {
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
