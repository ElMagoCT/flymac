import Foundation
import SwiftUI
import AVFoundation
import Video
import MockDevice
import FlyCore

/// The live-view pipeline: one selected VideoSource → Metal renderer, stats, recorder.
@MainActor
final class LiveModel: ObservableObject {
    struct SourceOption: Identifiable, Hashable {
        enum Kind: Hashable { case mock, uvc(String) }
        var id: String
        var title: String
        var kind: Kind
        var subtitle: String
    }

    @Published var options: [SourceOption] = []
    @Published var selected: SourceOption?
    @Published var stats = StreamStats()
    @Published var isRunning = false
    @Published var error: String?
    @Published var recording: Recorder?
    @Published var recordingSeconds: TimeInterval = 0
    @Published var uniforms = MetalVideoRenderer.MonitorUniforms() { didSet { renderer?.uniforms = uniforms } }
    @Published var artificialLatencyMs: Double = 0

    let renderer = MetalVideoRenderer()
    private var source: (any VideoSource)?
    private var frameTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var meter: StatsMeter? { didSet { sink.meter = meter } }
    /// Touched from the Metal render thread, so it lives outside the main actor.
    private let sink = FrameSink()

    final class FrameSink: @unchecked Sendable {
        private let lock = NSLock()
        private var _meter: StatsMeter?; private var _recorder: Recorder?
        var meter: StatsMeter? { get { lock.withLock { _meter } } set { lock.withLock { _meter = newValue } } }
        var recorder: Recorder? { get { lock.withLock { _recorder } } set { lock.withLock { _recorder = newValue } } }
        func displayed(_ f: VideoFrame) { meter?.noteDisplayed(f); recorder?.append(f) }
    }

    func refreshOptions(settings: AppSettings) {
        var o: [SourceOption] = []
        if settings.isOn(.mockDevice) { o.append(.init(id: "mock", title: "Mock aircraft", kind: .mock, subtitle: "H.264 encode → decode, no hardware")) }
        if settings.isOn(.uvcCapture) {
            for d in UVCSource.devices() { o.append(.init(id: "uvc:\(d.uniqueID)", title: d.localizedName, kind: .uvc(d.uniqueID), subtitle: d.manufacturer.isEmpty ? "UVC" : d.manufacturer)) }
        }
        options = o
        if let s = selected, !o.contains(s) { stop(); selected = nil }
    }

    func start(_ opt: SourceOption) async {
        stop()
        selected = opt
        error = nil
        let src: any VideoSource
        switch opt.kind {
        case .mock:
            let m = MockVideoSource(); m.latencyBudgetMs = artificialLatencyMs; src = m; meter = m.stats
        case .uvc(let id):
            guard let d = UVCSource.devices().first(where: { $0.uniqueID == id }) else { error = "device gone"; return }
            let u = UVCSource(device: d); src = u; meter = u.stats
        }
        source = src
        guard let renderer else { error = "Metal unavailable"; return }
        renderer.uniforms = uniforms
        let sink = self.sink
        renderer.onDisplayed = { f in sink.displayed(f) }
        do { try await src.start() } catch { self.error = error.localizedDescription; return }
        isRunning = true
        frameTask = Task { [weak self] in
            for await f in src.frames { self?.renderer?.submit(f) }
        }
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self else { return }
                if let m = self.meter { self.stats = m.stats }
                if let r = self.recording { self.recordingSeconds = r.duration }
            }
        }
    }

    func stop() {
        frameTask?.cancel(); statsTask?.cancel()
        source?.stop(); source = nil
        isRunning = false
        stats = StreamStats()
        if recording != nil { Task { await stopRecording() } }
    }

    func startRecording(codec: String) {
        let c = Recorder.Codec(rawValue: codec) ?? .hevc
        let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("FlyMac Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = dir.appendingPathComponent("FlyMac \(f.string(from: Date())).\(c == .hevc ? "mp4" : "mov")")
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
    @Published var lastRecording: URL?
}
