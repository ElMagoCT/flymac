import Foundation
import AVFoundation

/// Any UVC device (HDMI capture card, webcam) through AVFoundation.
/// Fallback-ladder step 1 for live video.
public final class UVCSource: NSObject, VideoSource, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public let name: String
    public let frames: AsyncStream<VideoFrame>
    private var continuation: AsyncStream<VideoFrame>.Continuation?
    private let device: AVCaptureDevice
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "FlyMac.UVC")
    public let stats = StatsMeter()

    public static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .builtInWideAngleCamera, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    public init(device: AVCaptureDevice) {
        self.device = device
        name = device.localizedName
        var c: AsyncStream<VideoFrame>.Continuation!
        frames = AsyncStream(bufferingPolicy: .bufferingNewest(2)) { c = $0 }
        continuation = c
        super.init()
    }

    public func start() async throws {
        if AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw NSError(domain: "FlyMac.UVC", code: 1, userInfo: [NSLocalizedDescriptionKey: "camera access denied"]) }
        }
        session.beginConfiguration()
        session.sessionPreset = .high
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw NSError(domain: "FlyMac.UVC", code: 2, userInfo: [NSLocalizedDescriptionKey: "cannot add input"]) }
        session.addInput(input)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                kCVPixelBufferMetalCompatibilityKey as String: true]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw NSError(domain: "FlyMac.UVC", code: 3, userInfo: [NSLocalizedDescriptionKey: "cannot add output"]) }
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()
    }

    public func stop() { session.stopRunning(); continuation?.finish() }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = CACurrentMediaTime()
        continuation?.yield(VideoFrame(pixelBuffer: pb, presentation: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), arrivedAt: now, decodedAt: now))
    }
}
