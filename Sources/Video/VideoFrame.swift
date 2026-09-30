import Foundation
import CoreVideo
import CoreMedia

/// A decoded picture plus the timestamps needed for a latency readout.
public struct VideoFrame: @unchecked Sendable {
    public var pixelBuffer: CVPixelBuffer
    /// Presentation time from the stream, if the source has one.
    public var presentation: CMTime
    /// Host time (seconds, `CACurrentMediaTime` base) when the *encoded* data
    /// for this picture arrived. Latency = display time − this.
    public var arrivedAt: TimeInterval
    /// Host time when decoding finished.
    public var decodedAt: TimeInterval

    public init(pixelBuffer: CVPixelBuffer, presentation: CMTime, arrivedAt: TimeInterval, decodedAt: TimeInterval) {
        self.pixelBuffer = pixelBuffer; self.presentation = presentation; self.arrivedAt = arrivedAt; self.decodedAt = decodedAt
    }

    public var width: Int { CVPixelBufferGetWidth(pixelBuffer) }
    public var height: Int { CVPixelBufferGetHeight(pixelBuffer) }
}

/// Anything that produces pictures: a decoder fed from USB, a UVC capture
/// card, the mock generator. All sources look the same to the viewer.
public protocol VideoSource: AnyObject, Sendable {
    var name: String { get }
    var frames: AsyncStream<VideoFrame> { get }
    func start() async throws
    func stop()
}

/// Rolling latency + fps statistics for the HUD.
public struct StreamStats: Sendable, Equatable {
    public var fps: Double = 0
    public var latencyMs: Double = 0      // arrival → display, averaged
    public var decodeMs: Double = 0
    public var width = 0, height = 0
    public var frames = 0
    public var dropped = 0
    public var bitrateKbps: Double = 0

    public init() {}
}

public final class StatsMeter: @unchecked Sendable {
    private var times: [TimeInterval] = []
    private var latencies: [Double] = []
    private var decodes: [Double] = []
    private var bytes: [(TimeInterval, Int)] = []
    private let lock = NSLock()
    public private(set) var stats = StreamStats()

    public init() {}

    public func noteBytes(_ n: Int) {
        lock.withLock { bytes.append((now(), n)); bytes.removeAll { $0.0 < now() - 2 } }
    }

    public func noteDisplayed(_ f: VideoFrame) {
        lock.withLock {
            let t = now()
            times.append(t); times.removeAll { $0 < t - 2 }
            latencies.append((t - f.arrivedAt) * 1000); if latencies.count > 60 { latencies.removeFirst() }
            decodes.append((f.decodedAt - f.arrivedAt) * 1000); if decodes.count > 60 { decodes.removeFirst() }
            stats.frames += 1
            stats.width = f.width; stats.height = f.height
            stats.fps = times.count > 1 ? Double(times.count - 1) / max(0.001, times.last! - times.first!) : 0
            stats.latencyMs = latencies.reduce(0, +) / Double(max(1, latencies.count))
            stats.decodeMs = decodes.reduce(0, +) / Double(max(1, decodes.count))
            let span = max(0.5, (bytes.last?.0 ?? t) - (bytes.first?.0 ?? t))
            stats.bitrateKbps = Double(bytes.reduce(0) { $0 + $1.1 }) * 8 / span / 1000
        }
    }

    public func noteDropped() { lock.withLock { stats.dropped += 1 } }
    public func reset() { lock.withLock { times = []; latencies = []; decodes = []; bytes = []; stats = StreamStats() } }

    func now() -> TimeInterval { CACurrentMediaTime() }
}
import QuartzCore
