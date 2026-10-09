import Foundation
import VideoToolbox
import CoreMedia
import Video
import Telemetry

/// Renders the synthetic scene, encodes it to H.264 Annex-B with
/// VideoToolbox, and pushes the bytes through the *real* ElementaryStreamSource
/// (parser → decoder). So the mock exercises the exact path a USB stream will.
public final class MockVideoSource: VideoSource, @unchecked Sendable {
    public let name: String
    public var frames: AsyncStream<VideoFrame> { es.frames }
    public let es: ElementaryStreamSource
    public var stats: StatsMeter { es.stats }
    private let renderer: SceneRenderer
    private var compressor: VTCompressionSession?
    private var task: Task<Void, Never>?
    public let flight: SyntheticFlight
    private let fps: Double
    private let started = CACurrentMediaTime()
    public var latencyBudgetMs: Double = 0   // add artificial delay to test the meter

    public init(width: Int = 1280, height: Int = 720, fps: Double = 30, flight: SyntheticFlight = SyntheticFlight(),
                name: String = "Mock aircraft (H.264)", osdLabel: String = "MOCK") {
        self.flight = flight
        self.name = name
        renderer = SceneRenderer(width: width, height: height)
        renderer.label = osdLabel
        renderer.skyHue = flight.skyHue
        es = ElementaryStreamSource(name: "mock", codec: .h264)
        self.fps = fps
    }

    public func start() async throws {
        guard task == nil else { return }
        var s: VTCompressionSession?
        VTCompressionSessionCreate(allocator: nil, width: Int32(renderer.width), height: Int32(renderer.height), codecType: kCMVideoCodecType_H264,
                                   encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                   outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard let s else { throw NSError(domain: "FlyMac.Mock", code: 1, userInfo: [NSLocalizedDescriptionKey: "no H.264 encoder"]) }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: 6_000_000 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 30 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(s)
        compressor = s
        task = Task.detached(priority: .userInitiated) { [weak self] in
            var i = 0
            while !Task.isCancelled, let self {
                let t = fmod(CACurrentMediaTime() - self.started, self.flight.duration)
                if let pb = self.renderer.render(self.flight.frame(at: t, index: i)) { self.encode(pb, index: i) }
                i += 1
                try? await Task.sleep(nanoseconds: UInt64(1e9 / self.fps))
            }
        }
    }

    private func encode(_ pb: CVPixelBuffer, index: Int) {
        guard let compressor else { return }
        let pts = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))
        VTCompressionSessionEncodeFrame(compressor, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            let bytes = MockVideoSource.annexB(from: sample)
            let push = { self.es.push(bytes) }
            if self.latencyBudgetMs > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + self.latencyBudgetMs / 1000, execute: push) } else { push() }
        }
    }

    /// AVCC sample → Annex-B bytes, emitting SPS/PPS before every keyframe.
    static func annexB(from sample: CMSampleBuffer) -> [UInt8] {
        var out: [UInt8] = []
        let sc: [UInt8] = [0, 0, 0, 1]
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        if !notSync, let fd = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>? = nil; var size = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if let ptr { out += sc; out += Array(UnsafeBufferPointer(start: ptr, count: size)) }
            }
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return out }
        var length = 0; var ptr: UnsafeMutablePointer<CChar>? = nil
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr)
        guard let ptr else { return out }
        let data = UnsafeRawBufferPointer(start: ptr, count: length)
        var off = 0
        while off + 4 <= length {
            let n = Int(data[off]) << 24 | Int(data[off+1]) << 16 | Int(data[off+2]) << 8 | Int(data[off+3])
            off += 4
            guard off + n <= length else { break }
            out += sc; out += Array(data[off..<(off + n)])
            off += n
        }
        return out
    }

    public func stop() {
        task?.cancel(); task = nil
        if let c = compressor { VTCompressionSessionInvalidate(c) }; compressor = nil
        es.stop()
    }
}
import QuartzCore
