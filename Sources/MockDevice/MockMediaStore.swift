import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import FlyCore
import Telemetry
import Ingest

/// Real files on disk that stand in for an aircraft's card: a few H.264 MP4
/// clips with matching LRF proxies and SRT sidecars, and some JPGs. Generated
/// once into Application Support and reused afterwards.
public final class MockMediaStore: @unchecked Sendable {
    public let root: URL
    public let flight = SyntheticFlight()
    public private(set) var files: [RemoteMediaFile] = []
    public var onProgress: (@Sendable (String) -> Void)?

    public struct Clip { let name: String; let offset: TimeInterval; let length: TimeInterval; let photo: Bool }
    public static let clips: [Clip] = [
        .init(name: "DJI_0001", offset: 0, length: 6, photo: false),
        .init(name: "DJI_0002", offset: 40, length: 8, photo: false),
        .init(name: "DJI_0003", offset: 61, length: 0, photo: true),
        .init(name: "DJI_0004", offset: 95, length: 5, photo: false),
        .init(name: "DJI_0005", offset: 120, length: 0, photo: true),
        .init(name: "DJI_0006", offset: 150, length: 10, photo: false),
        .init(name: "DJI_0007", offset: 200, length: 0, photo: true),
        .init(name: "DJI_0008", offset: 210, length: 7, photo: false),
    ]

    public init(root: URL? = nil) {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FlyMac/mock-card", isDirectory: true)
        self.root = base
    }

    public var mediaFolder: URL { root.appendingPathComponent("DCIM/100MEDIA", isDirectory: true) }
    public var isReady: Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(".complete").path) }

    /// Generate if needed, then index. Safe to call repeatedly.
    public func prepare() async {
        if !isReady {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: root.appendingPathComponent("thumbs"), withIntermediateDirectories: true)
            for c in MockMediaStore.clips {
                onProgress?("Rendering \(c.name)")
                if c.photo { await photo(c) } else { await clip(c) }
            }
            FileManager.default.createFile(atPath: root.appendingPathComponent(".complete").path, contents: Data())
        }
        index()
    }

    func index() {
        files = MediaLibrary.scan(root).filter { $0.path.hasPrefix("DCIM") }.map { f in
            var f = f
            let clip = MockMediaStore.clips.first { $0.name == f.stem }
            if f.kind == .video || f.kind == .proxy { f.duration = clip?.length }
            f.thumbnail = "/thumbs/\(f.stem).jpg"
            f.sha256 = try? Hashing.sha256(of: root.appendingPathComponent(f.path))
            f.modified = clip.map { flight.frame(at: $0.offset, index: 0).date } ?? f.modified
            return f
        }
    }

    // MARK: generation

    func clip(_ c: Clip) async {
        let fps = 30.0
        await writeMovie(to: mediaFolder.appendingPathComponent("\(c.name).MP4"), size: (1920, 1080), bitrate: 12_000_000, fps: fps, clip: c)
        await writeMovie(to: mediaFolder.appendingPathComponent("\(c.name).LRF"), size: (960, 540), bitrate: 2_000_000, fps: fps, clip: c)
        try? flight.srt(offset: c.offset, length: c.length, fps: fps).write(to: mediaFolder.appendingPathComponent("\(c.name).SRT"), atomically: true, encoding: .utf8)
        thumbnail(for: c, size: (480, 270))
    }

    func photo(_ c: Clip) async {
        let r = SceneRenderer(width: 4000, height: 3000)
        guard let pb = r.render(flight.frame(at: c.offset, index: 0), hud: false) else { return }
        writeJPEG(pb, to: mediaFolder.appendingPathComponent("\(c.name).JPG"), quality: 0.9)
        thumbnail(for: c, size: (480, 360))
    }

    func thumbnail(for c: Clip, size: (Int, Int)) {
        let r = SceneRenderer(width: size.0, height: size.1)
        guard let pb = r.render(flight.frame(at: c.offset + 1, index: 0), hud: false) else { return }
        writeJPEG(pb, to: root.appendingPathComponent("thumbs/\(c.name).jpg"), quality: 0.8)
    }

    func writeJPEG(_ pb: CVPixelBuffer, to url: URL, quality: Double) {
        let ci = CIImage(cvPixelBuffer: pb)
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(ci, from: ci.extent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    func writeMovie(to url: URL, size: (Int, Int), bitrate: Int, fps: Double, clip c: Clip) async {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
        let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.0, AVVideoHeightKey: size.1,
                                       AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate, AVVideoMaxKeyFrameIntervalKey: 30,
                                                                         AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        writer.startWriting(); writer.startSession(atSourceTime: .zero)
        let renderer = SceneRenderer(width: size.0, height: size.1)
        let n = Int(c.length * fps)
        for i in 0..<n {
            while !input.isReadyForMoreMediaData { try? await Task.sleep(nanoseconds: 2_000_000) }
            let t = Double(i) / fps
            guard let pb = renderer.render(flight.frame(at: c.offset + t, index: i)) else { continue }
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let d = flight.frame(at: c.offset, index: 0).date { try? FileManager.default.setAttributes([.modificationDate: d], ofItemAtPath: url.path) }
    }
}
import CoreImage
