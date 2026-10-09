import Foundation
import SwiftUI
import AVFoundation
import Video
import MockDevice
import FlyCore

/// Something that can feed a live tile. Built by AppModel from what is
/// connected (mock aircraft, each pair of goggles, each UVC card).
struct LiveSourceOption: Identifiable, Hashable {
    enum Kind: Hashable { case mockAircraft, mockGoggles(Int), uvc(String) }
    var id: String
    var title: String
    var subtitle: String
    var kind: Kind
    /// DiscoveredDevice.id when the source is a known device; drives the colour.
    var deviceID: String?
}

/// One live view: a single source → its own Metal renderer, stats and recorder.
/// Several tiles run side by side on the LiveWall.
@MainActor
final class LiveTile: ObservableObject, Identifiable {
    let id = UUID()
    @Published var selected: LiveSourceOption?
    @Published var stats = StreamStats()
    @Published var isRunning = false
    @Published var error: String?
    @Published var recording: Recorder?
    @Published var recordingSeconds: TimeInterval = 0
    @Published var lastRecording: URL?
    @Published var uniforms = MetalVideoRenderer.MonitorUniforms() { didSet { renderer?.uniforms = uniforms } }

    let renderer = MetalVideoRenderer()
    private var source: (any VideoSource)?
    private var frameTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    /// Touched from the Metal render thread, so it lives outside the main actor.
    private let sink = FrameSink()

    final class FrameSink: @unchecked Sendable {
        private let lock = NSLock()
        private var _meter: StatsMeter?; private var _recorder: Recorder?
        var meter: StatsMeter? { get { lock.withLock { _meter } } set { lock.withLock { _meter = newValue } } }
        var recorder: Recorder? { get { lock.withLock { _recorder } } set { lock.withLock { _recorder = newValue } } }
        func displayed(_ f: VideoFrame) { meter?.noteDisplayed(f); recorder?.append(f) }
    }

    func start(_ opt: LiveSourceOption, source src: any VideoSource, meter: StatsMeter) async {
        stop()
        selected = opt
        error = nil
        source = src
        sink.meter = meter
        guard let renderer else { error = "Metal unavailable"; return }
        renderer.uniforms = uniforms
        renderer.countOnSubmit = ScreenshotBridge.stillFrames
        let sink = self.sink
        renderer.onDisplayed = { f in sink.displayed(f) }
        do { try await src.start() } catch { self.error = error.localizedDescription; return }
        isRunning = true
        frameTask = Task { [weak self] in
            for await f in src.frames { self?.renderer?.submit(f) }
            // Stream ended on its own: unplug or source failure.
            await MainActor.run { if self?.source === src { self?.isRunning = false; self?.error = "source ended" } }
        }
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self else { return }
                self.stats = meter.stats
                if let r = self.recording { self.recordingSeconds = r.duration }
            }
        }
    }

    func stop() {
        frameTask?.cancel(); statsTask?.cancel()
        let old = source
        source = nil
        old?.stop()
        sink.meter = nil
        isRunning = false
        stats = StreamStats()
        if recording != nil { Task { await stopRecording() } }
    }

    func clear() { stop(); selected = nil; error = nil }

    func startRecording(codec: String, stamp: String) {
        guard isRunning, recording == nil else { return }
        let c = Recorder.Codec(rawValue: codec) ?? .hevc
        let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("FlyMac Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let label = (selected?.title ?? "Live").replacingOccurrences(of: "/", with: "-")
        let url = dir.appendingPathComponent("FlyMac \(stamp) \(label).\(c == .hevc ? "mp4" : "mov")")
        recording = Recorder(url: url, codec: c)
        sink.recorder = recording
    }

    func stopRecording() async {
        guard let r = recording else { return }
        recording = nil; sink.recorder = nil
        await r.finish()
        recordingSeconds = 0
        lastRecording = r.url
    }
}

/// The Live screen: up to four tiles at once, so several pairs of goggles (or
/// goggles + a capture card) can be watched and recorded together.
@MainActor
final class LiveWall: ObservableObject {
    static let maxTiles = 4

    @Published var options: [LiveSourceOption] = []
    @Published private(set) var tiles: [LiveTile] = [LiveTile()]
    @Published var focusedTileID: UUID?
    @Published var artificialLatencyMs: Double = 0
    /// When true, monitor-tool edits apply to every tile.
    var linkTools = true
    /// AppModel supplies the actual sources (it owns the mock goggles etc.).
    var makeSource: ((LiveSourceOption, Double) -> (source: any VideoSource, meter: StatsMeter)?)?

    var focused: LiveTile { tiles.first { $0.id == focusedTileID } ?? tiles[0] }
    var runningCount: Int { tiles.filter(\.isRunning).count }
    var isRecordingAny: Bool { tiles.contains { $0.recording != nil } }

    func setOptions(_ o: [LiveSourceOption]) {
        options = o
        for t in tiles {
            guard let s = t.selected else { continue }
            if let fresh = o.first(where: { $0.id == s.id }) { t.selected = fresh }   // picks up renamed devices
            else { t.clear() }
        }
        objectWillChange.send()
    }

    /// Which tile currently shows this source, if any.
    func tile(showing id: String) -> LiveTile? { tiles.first { $0.selected?.id == id } }

    func assign(_ opt: LiveSourceOption?, to tile: LiveTile) async {
        guard let opt else { tile.clear(); objectWillChange.send(); return }
        // A source has one frame stream, so it can only feed one tile.
        if let other = self.tile(showing: opt.id), other !== tile { other.clear() }
        guard let made = makeSource?(opt, artificialLatencyMs) else { tile.error = "source unavailable"; return }
        await tile.start(opt, source: made.source, meter: made.meter)
        focusedTileID = tile.id
        objectWillChange.send()
    }

    /// Put a source on screen: reuse its tile, else an empty tile, else add one.
    func show(_ opt: LiveSourceOption) async {
        if let t = tile(showing: opt.id) { focusedTileID = t.id; return }
        let target = tiles.first { $0.selected == nil } ?? addTile()
        guard let target else { return }
        await assign(opt, to: target)
    }

    @discardableResult
    func addTile() -> LiveTile? {
        guard tiles.count < LiveWall.maxTiles else { return nil }
        let t = LiveTile()
        if linkTools { t.uniforms = focused.uniforms }
        tiles.append(t)
        focusedTileID = t.id
        return t
    }

    func removeTile(_ t: LiveTile) {
        t.clear()
        if tiles.count > 1 { tiles.removeAll { $0 === t } }
        if focusedTileID == t.id { focusedTileID = tiles.first?.id }
    }

    /// Fill the wall with every available source, up to four.
    func showAll() async {
        for opt in options.prefix(LiveWall.maxTiles) { await show(opt) }
    }

    func stopAll() {
        for t in tiles { t.clear() }
        while tiles.count > 1 { tiles.removeLast() }
        focusedTileID = tiles.first?.id
    }

    /// Start recording every running tile with one shared timestamp so the
    /// files line up when edited together.
    func recordAll(codec: String) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stamp = f.string(from: Date())
        for t in tiles where t.isRunning { t.startRecording(codec: codec, stamp: stamp) }
        objectWillChange.send()
    }

    func stopAllRecordings() async {
        for t in tiles { await t.stopRecording() }
        objectWillChange.send()
    }

    /// Monitor-tool binding target: the focused tile, mirrored to all when linked.
    var uniforms: MetalVideoRenderer.MonitorUniforms {
        get { focused.uniforms }
        set {
            if linkTools { for t in tiles { t.uniforms = newValue } } else { focused.uniforms = newValue }
            objectWillChange.send()
        }
    }

    func syncUniformsToAll() { let u = focused.uniforms; for t in tiles { t.uniforms = u } }
}
