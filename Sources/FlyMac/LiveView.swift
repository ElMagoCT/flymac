import SwiftUI
import Video

struct LiveView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { LiveWallView(wall: model.live) }
}

private struct LiveWallView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var wall: LiveWall
    @State private var showTools = true

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                toolbar
                Divider().overlay(Theme.line)
                grid.background(Color.black)
            }
            .frame(minWidth: 560)
            if showTools && model.settings.isOn(.monitorTools) {
                MonitorToolsPanel(wall: wall).frame(width: 260)
            }
        }
        .onAppear { model.refreshLiveOptions() }
    }

    var toolbar: some View {
        HStack(spacing: 10) {
            Text("Live").font(.headline)
            if wall.runningCount > 0 {
                Text("\(wall.runningCount) of \(wall.options.count) sources").font(.caption).foregroundStyle(Theme.dim).monospacedDigit()
            }
            Spacer()
            if wall.options.count > 1 {
                Button { Task { await wall.showAll() } } label: { Label("Show all", systemImage: "square.grid.2x2") }
                    .controlSize(.small).disabled(wall.options.allSatisfy { wall.tile(showing: $0.id) != nil })
            }
            Button { wall.addTile() } label: { Image(systemName: "plus.rectangle.on.rectangle") }
                .controlSize(.small).disabled(wall.tiles.count >= LiveWall.maxTiles).help("Add a view (up to \(LiveWall.maxTiles))")
            if wall.runningCount > 0 {
                if wall.isRecordingAny {
                    Button { Task { await wall.stopAllRecordings() } } label: {
                        HStack(spacing: 6) { Circle().fill(Theme.bad).frame(width: 8, height: 8); Text("Stop all") }
                    }.buttonStyle(.borderedProminent).tint(Theme.bad.opacity(0.8)).controlSize(.small)
                } else {
                    Button { wall.recordAll(codec: model.settings.recordingCodec) } label: {
                        Label(wall.runningCount > 1 ? "Record all" : "Record", systemImage: "record.circle")
                    }.controlSize(.small).help("One file per view, \(Recorder.Codec(rawValue: model.settings.recordingCodec)?.title ?? ""), shared timestamp")
                }
            }
            if model.settings.isOn(.monitorTools) {
                Button { withAnimation(.easeOut(duration: 0.2)) { showTools.toggle() } } label: { Image(systemName: "slider.horizontal.3") }.controlSize(.small)
            }
        }.padding(.horizontal, 14).padding(.vertical, 8)
    }

    @ViewBuilder var grid: some View {
        let tiles = wall.tiles
        if wall.options.isEmpty && tiles.allSatisfy({ $0.selected == nil }) {
            EmptyState(symbol: "dot.radiowaves.left.and.right", title: "No live sources",
                       detail: "Turn on the mock aircraft or mock goggles in Settings, or plug in a UVC capture card. Real goggles video over USB is pending discovery.")
        } else {
            GeometryReader { geo in
                let cols = tiles.count == 1 ? 1 : 2
                let rows = Int(ceil(Double(tiles.count) / Double(cols)))
                let gap: CGFloat = tiles.count == 1 ? 0 : 4
                let w = (geo.size.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
                let h = (geo.size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
                VStack(spacing: gap) {
                    ForEach(0..<rows, id: \.self) { r in
                        HStack(spacing: gap) {
                            ForEach(tiles[(r * cols)..<min(tiles.count, r * cols + cols)]) { t in
                                LiveTileView(tile: t, wall: wall, focused: wall.focusedTileID == t.id || (wall.focusedTileID == nil && t === tiles[0]),
                                             compact: tiles.count > 1)
                                    .frame(width: w, height: h)
                            }
                            // Odd count: keep the last row's tile the same width as the others.
                            if r == rows - 1, tiles.count % cols != 0 { Color.clear.frame(width: w, height: h) }
                        }
                    }
                }
            }
            .animation(.spring(duration: 0.35), value: tiles.count)
        }
    }
}

private struct LiveTileView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var tile: LiveTile
    @ObservedObject var wall: LiveWall
    let focused: Bool
    let compact: Bool

    var color: Color { model.color(forID: tile.selected?.deviceID) }

    var body: some View {
        ZStack {
            Color.black
            if let r = tile.renderer, tile.isRunning {
                if ScreenshotBridge.stillFrames { StillFrameView(renderer: r) } else { MetalVideoView(renderer: r) }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: tile.selected == nil ? "rectangle.dashed" : "exclamationmark.triangle").font(.system(size: 26, weight: .light)).foregroundStyle(Theme.dim)
                    if let e = tile.error { Text(e).font(.caption).foregroundStyle(Theme.warn) }
                    sourceMenu(prominent: true)
                }
            }
            VStack {
                HStack(spacing: 8) {
                    if tile.selected != nil { sourceMenu(prominent: false) }
                    Spacer()
                    if tile.recording != nil {
                        HStack(spacing: 5) {
                            Circle().fill(Theme.bad).frame(width: 7, height: 7)
                            Text(tile.recordingSeconds.clock).font(.caption.weight(.medium)).monospacedDigit()
                        }.padding(.horizontal, 8).padding(.vertical, 4).background(.black.opacity(0.55), in: Capsule())
                    }
                    if compact {
                        Button { wall.removeTile(tile) } label: { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                            .buttonStyle(.plain).padding(6).background(.black.opacity(0.55), in: Circle()).help("Close this view")
                    }
                }
                Spacer()
                if tile.isRunning { stats }
            }
            .padding(10)
        }
        .overlay(
            RoundedRectangle(cornerRadius: compact ? 6 : 0, style: .continuous)
                .stroke(focused && compact ? color.opacity(0.9) : .clear, lineWidth: 2)
        )
        .clipShape(RoundedRectangle(cornerRadius: compact ? 6 : 0, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { wall.focusedTileID = tile.id }
        .animation(.easeOut(duration: 0.15), value: focused)
    }

    func sourceMenu(prominent: Bool) -> some View {
        // The colour dot sits outside the Menu: macOS menu labels drop shapes.
        HStack(spacing: 6) {
            Circle().fill(tile.selected == nil ? Theme.dim : color).frame(width: 7, height: 7)
            Menu {
                ForEach(wall.options) { o in
                    Button {
                        Task { await wall.assign(o, to: tile) }
                    } label: {
                        if let other = wall.tile(showing: o.id), other !== tile { Text("\(o.title)  (moves here)") } else { Text(o.title) }
                    }
                }
                if tile.selected != nil {
                    Divider()
                    Button("Off") { Task { await wall.assign(nil, to: tile) } }
                }
            } label: {
                Text(tile.selected?.title ?? "Choose a source").font(prominent ? .callout : .caption.weight(.medium)).lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, prominent ? 12 : 8).padding(.vertical, prominent ? 7 : 4)
        .background(prominent ? AnyShapeStyle(Theme.panelRaised) : AnyShapeStyle(.black.opacity(0.55)), in: Capsule())
    }

    @ViewBuilder var stats: some View {
        let s = tile.stats
        HStack(spacing: compact ? 12 : 16) {
            Stat(label: "fps", value: String(format: "%.0f", s.fps))
            Stat(label: "latency", value: String(format: "%.0f", s.latencyMs), unit: "ms", color: s.latencyMs > 120 ? Theme.warn : Theme.text)
            if !compact {
                Stat(label: "decode", value: String(format: "%.1f", s.decodeMs), unit: "ms")
                Stat(label: "size", value: "\(s.width)×\(s.height)")
                if s.bitrateKbps > 0 { Stat(label: "bitrate", value: String(format: "%.1f", s.bitrateKbps / 1000), unit: "Mb/s") }
            }
            Spacer(minLength: 0)
            if let u = tile.lastRecording, tile.recording == nil {
                Button { NSWorkspace.shared.activateFileViewerSelecting([u]) } label: { Image(systemName: "film") }.buttonStyle(.plain).help(u.lastPathComponent)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .scaleEffect(compact ? 0.85 : 1, anchor: .bottomLeading)
    }
}

/// Live sliders for the shader stages. With several views they edit the
/// focused view, or every view when "Apply to all" is on.
struct MonitorToolsPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var wall: LiveWall

    var u: Binding<MetalVideoRenderer.MonitorUniforms> { Binding(get: { wall.uniforms }, set: { wall.uniforms = $0 }) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Monitor").font(.headline)
                    Spacer()
                    if wall.tiles.count > 1, !model.settings.linkMonitorTools, let s = wall.focused.selected {
                        HStack(spacing: 5) { Circle().fill(model.color(forID: s.deviceID)).frame(width: 7, height: 7); Text(s.title).font(.caption).lineLimit(1) }
                            .foregroundStyle(Theme.dim)
                    }
                }
                if wall.tiles.count > 1 {
                    Toggle("Apply to all views", isOn: $model.settings.linkMonitorTools).toggleStyle(.switch).controlSize(.small)
                }
                Panel(title: "Exposure") {
                    ToggleRow("Zebras", u.zebraOn)
                    SliderRow("Level", u.zebraLevel, 0.5...1.0, "%.2f")
                    ToggleRow("False colour", u.falseColorOn)
                    SliderRow("Gain", u.exposureGain, 0.25...4, "%.2f×")
                }
                Panel(title: "Focus") {
                    ToggleRow("Peaking", u.peakingOn)
                    SliderRow("Threshold", u.peakingThreshold, 0.05...0.6, "%.2f")
                }
                Panel(title: "Framing") {
                    ToggleRow("Thirds", u.guidesOn)
                    SliderRow("Desqueeze", u.desqueeze, 1.0...2.0, "%.2f×")
                }
                Panel(title: "Test") {
                    SliderRow("Added delay", Binding(get: { Float(wall.artificialLatencyMs) }, set: { wall.artificialLatencyMs = Double($0) }), 0...500, "%.0f ms")
                    Text("Applies when a source next starts").font(.caption2).foregroundStyle(Theme.dim)
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

/// Screenshot-mode stand-in for the Metal view (see ScreenshotBridge).
private struct StillFrameView: View {
    let renderer: MetalVideoRenderer
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            if let cg = renderer.snapshot() {
                Image(decorative: cg, scale: 1).resizable().aspectRatio(contentMode: .fit)
            }
        }
    }
}
