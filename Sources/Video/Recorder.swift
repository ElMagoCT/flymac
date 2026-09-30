import Foundation
import AVFoundation

/// Records decoded frames to a movie with AVAssetWriter.
public final class Recorder: @unchecked Sendable {
    public enum Codec: String, CaseIterable, Sendable {
        case hevc, prores422, prores422LT
        public var title: String {
            switch self { case .hevc: return "HEVC"; case .prores422: return "ProRes 422"; case .prores422LT: return "ProRes 422 LT" }
        }
        var avCodec: AVVideoCodecType {
            switch self { case .hevc: return .hevc; case .prores422: return .proRes422; case .prores422LT: return .proRes422LT }
        }
    }

    public let url: URL
    public let codec: Codec
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var start: CMTime?
    private var lastPTS: CMTime = .zero
    private let lock = NSLock()
    public private(set) var frameCount = 0
    public private(set) var error: String?

    public init(url: URL, codec: Codec) { self.url = url; self.codec = codec }

    public var isRecording: Bool { lock.withLock { writer?.status == .writing } }
    public var duration: TimeInterval { lock.withLock { start.map { CMTimeGetSeconds(lastPTS - $0) } ?? 0 } }

    public func append(_ frame: VideoFrame) {
        lock.lock(); defer { lock.unlock() }
        if writer == nil { setup(width: frame.width, height: frame.height) }
        guard let writer, let input, let adaptor, writer.status == .writing else { return }
        // Use host time so live sources with no PTS still get monotonic timestamps.
        let pts = CMTime(seconds: frame.decodedAt, preferredTimescale: 600)
        if start == nil { start = pts; writer.startSession(atSourceTime: pts) }
        guard pts > lastPTS || frameCount == 0, input.isReadyForMoreMediaData else { return }
        if adaptor.append(frame.pixelBuffer, withPresentationTime: pts) { frameCount += 1; lastPTS = pts }
        else { error = writer.error?.localizedDescription ?? "append failed" }
    }

    private func setup(width: Int, height: Int) {
        do {
            try? FileManager.default.removeItem(at: url)
            let w = try AVAssetWriter(outputURL: url, fileType: codec == .hevc ? .mp4 : .mov)
            var settings: [String: Any] = [AVVideoCodecKey: codec.avCodec, AVVideoWidthKey: width, AVVideoHeightKey: height]
            if codec == .hevc {
                settings[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: max(8_000_000, width * height * 6),
                                                             AVVideoExpectedSourceFrameRateKey: 60,
                                                             AVVideoAllowFrameReorderingKey: false]
            }
            let i = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            i.expectsMediaDataInRealTime = true
            let a = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: i, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
            guard w.canAdd(i) else { error = "cannot add input"; return }
            w.add(i)
            guard w.startWriting() else { error = w.error?.localizedDescription; return }
            writer = w; input = i; adaptor = a
        } catch { self.error = error.localizedDescription }
    }

    public func finish() async {
        let (w, i) = lock.withLock { (writer, input) }
        guard let w, w.status == .writing else { return }
        i?.markAsFinished()
        await w.finishWriting()
        lock.withLock { writer = nil; input = nil; adaptor = nil }
    }
}
