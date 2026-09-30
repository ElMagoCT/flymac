import Foundation
import VideoToolbox
import CoreMedia

/// VideoToolbox hardware decode. Output is BGRA so the Metal view and the
/// recorder can consume it directly.
public final class VideoDecoder: @unchecked Sendable {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private let lock = NSLock()
    public var onFrame: (@Sendable (VideoFrame) -> Void)?
    public var onError: (@Sendable (String) -> Void)?
    public private(set) var decodedCount = 0

    public init() {}

    public func decode(_ au: AnnexBParser.AccessUnit, formatDescription: CMVideoFormatDescription, arrivedAt: TimeInterval) {
        lock.lock()
        if session == nil || format == nil || !CMFormatDescriptionEqual(format, otherFormatDescription: formatDescription) {
            makeSession(formatDescription)
        }
        guard let session else { lock.unlock(); return }
        lock.unlock()
        var flags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: au.sampleBuffer,
                                                       flags: [._EnableAsynchronousDecompression, ._1xRealTimePlayback],
                                                       infoFlagsOut: &flags) { [weak self] status, _, image, pts, _ in
            guard let self else { return }
            guard status == noErr, let image else {
                if status != noErr { self.onError?("decode error \(status)") }
                return
            }
            self.decodedCount += 1
            self.onFrame?(VideoFrame(pixelBuffer: image, presentation: pts, arrivedAt: arrivedAt, decodedAt: CACurrentMediaTime()))
        }
        if status != noErr {
            onError?("VTDecompressionSessionDecodeFrame \(status)")
            if status == kVTInvalidSessionErr { lock.withLock { invalidate() } }
        }
    }

    private func makeSession(_ fd: CMVideoFormatDescription) {
        invalidate()
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let spec: [CFString: Any] = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true]
        var s: VTDecompressionSession?
        let st = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: fd,
                                              decoderSpecification: spec as CFDictionary,
                                              imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                                              decompressionSessionOut: &s)
        if st == noErr, let s {
            VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            session = s; format = fd
        } else { onError?("VTDecompressionSessionCreate \(st)") }
    }

    private func invalidate() {
        if let s = session { VTDecompressionSessionInvalidate(s) }
        session = nil; format = nil
    }

    public func flush() { if let s = session { VTDecompressionSessionWaitForAsynchronousFrames(s) } }
    deinit { invalidate() }
}

import QuartzCore

/// Glue: raw Annex-B bytes in, decoded frames out. This is what a USB or
/// network transport feeds.
public final class ElementaryStreamSource: VideoSource, @unchecked Sendable {
    public let name: String
    public let frames: AsyncStream<VideoFrame>
    private var continuation: AsyncStream<VideoFrame>.Continuation?
    private var parser: AnnexBParser
    private let decoder = VideoDecoder()
    public let stats = StatsMeter()
    private let queue = DispatchQueue(label: "FlyMac.ESSource")
    public var onError: (@Sendable (String) -> Void)? { get { decoder.onError } set { decoder.onError = newValue } }

    public init(name: String, codec: AnnexBParser.Codec) {
        self.name = name
        parser = AnnexBParser(codec: codec)
        var c: AsyncStream<VideoFrame>.Continuation!
        frames = AsyncStream(bufferingPolicy: .bufferingNewest(2)) { c = $0 }
        continuation = c
        decoder.onFrame = { [weak self] f in self?.continuation?.yield(f) }
    }

    public func start() async throws {}
    public func stop() { continuation?.finish() }

    /// Feed bytes as they arrive from the transport.
    public func push(_ bytes: [UInt8]) {
        let arrived = CACurrentMediaTime()
        stats.noteBytes(bytes.count)
        queue.async { [self] in
            for au in parser.feed(bytes) {
                guard let fd = parser.formatDescription else { continue }
                decoder.decode(au, formatDescription: fd, arrivedAt: arrived)
            }
        }
    }

    public var codec: AnnexBParser.Codec { parser.codec }
}
