import SwiftUI

struct DoctorView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { DoctorBody(d: model.doctor) }
}

private struct DoctorBody: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var d: DoctorModel
    @State private var scan = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Doctor").font(.headline)
                Text("Everything needed to add a new device from one report.").font(.caption).foregroundStyle(Theme.dim)
                Spacer()
                Toggle("Scan hotspot ports", isOn: $scan).toggleStyle(.checkbox).font(.caption)
                Button {
                    Task { await d.run(devices: model.devices, registry: model.registry, handshake: model.allHandshakes, scanGateway: scan) }
                } label: {
                    if d.running { HStack(spacing: 6) { ProgressView().controlSize(.small); Text(d.progress) } } else { Label("Run", systemImage: "stethoscope") }
                }.buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small).disabled(d.running)
                Button("Copy") { d.copy() }.controlSize(.small).disabled(d.report.isEmpty)
                Button("Save…") { d.save() }.controlSize(.small).disabled(d.report.isEmpty)
            }.padding(.horizontal, 16).padding(.vertical, 10)
            Divider().overlay(Theme.line)
            if d.report.isEmpty {
                VStack(spacing: 14) {
                    EmptyState(symbol: "stethoscope", title: "Run the Doctor", detail: "Gathers USB descriptors, network, open ports, HTTP probes, profile matches and the DUML handshake into one text file you can paste anywhere.")
                    if !d.events.isEmpty {
                        Panel(title: "Session events") { ForEach(d.events.suffix(12), id: \.self) { Text($0).font(.caption).monospaced() } }.padding(.horizontal, 60).padding(.bottom, 30)
                    }
                }
            } else {
                ScrollView {
                    Text(d.report).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
            }
        }
    }
}
