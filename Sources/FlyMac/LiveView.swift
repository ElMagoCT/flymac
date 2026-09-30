import SwiftUI
import Video

struct LiveView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { LiveBody(live: model.live) }
}

private struct LiveBody: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var live: LiveModel
    @State private var showTools = true

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                toolbar
                Divider().overlay(Theme.line)
                ZStack {
                    if let r = live.renderer, live.isRunning { MetalVideoView(renderer: r) }
                    else {
                        EmptyState(symbol: "dot.radiowaves.left.and.right", title: live.options.isEmpty ? "No live sources" : "Pick a source",
                                   detail: live.options.isEmpty ? "Enable the mock aircraft or plug in a UVC capture card. Aircraft USB video is a Phase 2 item, pending discovery." : "")
                    }
                    if let e = live.error { Text(e).font(.callout).padding(10).background(Theme.bad.opacity(0.2), in: RoundedRectangle(cornerRadius: 8)).frame(maxHeight: .infinity, alignment: .top).padding() }
                    if live.isRunning { statsOverlay.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(14) }
                }
                .background(Color.black)
            }
            .frame(minWidth: 560)
            if showTools && model.settings.isOn(.monitorTools) { MonitorToolsPanel(live: live).frame(width: 260) }
        }
        .onAppear { live.refreshOptions(settings: model.settings) }
        .onChange(of: model.settings) { _, s in live.refreshOptions(settings: s) }
    }

    var toolbar: some View {
        HStack(spacing: 10) {
            Picker("Source", selection: Binding(get: { live.selected?.id ?? "" }, set: { id in
                if let o = live.options.first(where: { $0.id == id }) { Task { await live.start(o) } } else { live.stop(); live.selected = nil }
            })) {
                Text("Off").tag("")
                ForEach(live.options) { o in Text(o.title).tag(o.id) }
            }.frame(maxWidth: 260)
            if let s = live.selected { Text(s.subtitle).font(.caption).foregroundStyle(Theme.dim).lineLimit(1) }
            Spacer()
            if live.isRunning {
                if live.recording != nil {
                    Button { Task { await live.stopRecording() } } label: {
                        HStack(spacing: 6) { Circle().fill(Theme.bad).frame(width: 8, height: 8); Text(live.recordingSeconds.clock).monospacedDigit(); Text("Stop") }
                    }.buttonStyle(.borderedProminent).tint(Theme.bad.opacity(0.8)).controlSize(.small)
                } else {
                    Button { live.startRecording(codec: model.settings.recordingCodec) } label: { Label("Record \(Recorder.Codec(rawValue: model.settings.recordingCodec)?.title ?? "")", systemImage: "record.circle") }.controlSize(.small)
                }
                if let u = live.lastRecording { Button { NSWorkspace.shared.activateFileViewerSelecting([u]) } label: { Image(systemName: "film") }.controlSize(.small).help(u.lastPathComponent) }
            }
            if model.settings.isOn(.monitorTools) {
                Button { withAnimation { showTools.toggle() } } label: { Image(systemName: "slider.horizontal.3") }.controlSize(.small)
            }
        }.padding(.horizontal, 14).padding(.vertical, 8)
    }

    var statsOverlay: some View {
        HStack(spacing: 16) {
            Stat(label: "fps", value: String(format: "%.0f", live.stats.fps))
            Stat(label: "latency", value: String(format: "%.0f", live.stats.latencyMs), unit: "ms", color: live.stats.latencyMs > 120 ? Theme.warn : Theme.text)
            Stat(label: "decode", value: String(format: "%.1f", live.stats.decodeMs), unit: "ms")
            Stat(label: "size", value: "\(live.stats.width)×\(live.stats.height)")
            if live.stats.bitrateKbps > 0 { Stat(label: "bitrate", value: String(format: "%.1f", live.stats.bitrateKbps / 1000), unit: "Mb/s") }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
}

/// Phase 3 preview: the shader already has these stages, so expose sliders now.
struct MonitorToolsPanel: View {
    @ObservedObject var live: LiveModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Monitor").font(.headline)
                Panel(title: "Exposure") {
                    ToggleRow("Zebras", $live.uniforms.zebraOn)
                    SliderRow("Level", $live.uniforms.zebraLevel, 0.5...1.0, "%.2f")
                    ToggleRow("False colour", $live.uniforms.falseColorOn)
                    SliderRow("Gain", $live.uniforms.exposureGain, 0.25...4, "%.2f×")
                }
                Panel(title: "Focus") {
                    ToggleRow("Peaking", $live.uniforms.peakingOn)
                    SliderRow("Threshold", $live.uniforms.peakingThreshold, 0.05...0.6, "%.2f")
                }
                Panel(title: "Framing") {
                    ToggleRow("Thirds", $live.uniforms.guidesOn)
                    SliderRow("Desqueeze", $live.uniforms.desqueeze, 1.0...2.0, "%.2f×")
                }
                Panel(title: "Test") {
                    SliderRow("Added delay", Binding(get: { Float(live.artificialLatencyMs) }, set: { live.artificialLatencyMs = Double($0) }), 0...500, "%.0f ms")
                    Text("Restart the source to apply").font(.caption2).foregroundStyle(Theme.dim)
                }
            }.padding(14)
        }
        .background(Theme.panel)
    }
}

struct ToggleRow: View {
    let title: String; @Binding var value: Float
    init(_ t: String, _ v: Binding<Float>) { title = t; _value = v }
    var body: some View { Toggle(title, isOn: Binding(get: { value > 0.5 }, set: { value = $0 ? 1 : 0 })).toggleStyle(.switch).controlSize(.small) }
}

struct SliderRow: View {
    let title: String; @Binding var value: Float; let range: ClosedRange<Float>; let fmt: String
    init(_ t: String, _ v: Binding<Float>, _ r: ClosedRange<Float>, _ f: String) { title = t; _value = v; range = r; fmt = f }
    var body: some View {
        VStack(spacing: 2) {
            HStack { Text(title).font(.caption); Spacer(); Text(String(format: fmt, value)).font(.caption).monospacedDigit().foregroundStyle(Theme.dim) }
            Slider(value: $value, in: range).controlSize(.small).tint(Theme.accent)
        }
    }
}
