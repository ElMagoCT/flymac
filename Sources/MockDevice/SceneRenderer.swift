import Foundation
import CoreGraphics
import CoreVideo
import CoreText
import Telemetry

/// Draws a fake aerial view (horizon that banks and pitches with the flight,
/// a perspective ground grid, sun, a few "buildings") into a BGRA pixel buffer.
/// Pure CoreGraphics so it runs anywhere.
public final class SceneRenderer: @unchecked Sendable {
    public let width: Int, height: Int
    private var pool: CVPixelBufferPool?

    public init(width: Int, height: Int) {
        self.width = width; self.height = height
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                                      kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                                      kCVPixelBufferMetalCompatibilityKey: true,
                                      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
    }

    public func render(_ f: TelemetryFrame, hud: Bool = true) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        draw(in: ctx, frame: f, hud: hud)
        return pb
    }

    func draw(in ctx: CGContext, frame f: TelemetryFrame, hud: Bool) {
        let w = CGFloat(width), h = CGFloat(height)
        let roll = CGFloat((f.roll ?? 0) * .pi / 180)
        let pitch = CGFloat(f.pitch ?? 0)
        let horizonY = h * 0.55 + pitch * h / 60 - CGFloat(f.relativeAltitude ?? 0) * h / 900
        ctx.saveGState()
        ctx.translateBy(x: w / 2, y: h / 2); ctx.rotate(by: roll); ctx.translateBy(x: -w / 2, y: -h / 2)
        let big = CGRect(x: -w, y: -h, width: 3 * w, height: 3 * h)
        // Sky
        let sky = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: [CGColor(red: 0.05, green: 0.10, blue: 0.22, alpha: 1), CGColor(red: 0.45, green: 0.62, blue: 0.85, alpha: 1)] as CFArray,
                             locations: [0, 1])!
        ctx.clip(to: CGRect(x: big.minX, y: horizonY, width: big.width, height: big.maxY - horizonY))
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: horizonY), options: [.drawsAfterEndLocation, .drawsBeforeStartLocation])
        ctx.resetClip()
        // Sun
        ctx.setFillColor(CGColor(red: 1, green: 0.93, blue: 0.75, alpha: 0.95))
        ctx.fillEllipse(in: CGRect(x: w * 0.72, y: horizonY + h * 0.22, width: h * 0.09, height: h * 0.09))
        // Ground
        let ground = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                colors: [CGColor(red: 0.22, green: 0.18, blue: 0.13, alpha: 1), CGColor(red: 0.10, green: 0.09, blue: 0.07, alpha: 1)] as CFArray,
                                locations: [0, 1])!
        ctx.clip(to: CGRect(x: big.minX, y: big.minY, width: big.width, height: horizonY - big.minY))
        ctx.drawLinearGradient(ground, start: CGPoint(x: 0, y: horizonY), end: CGPoint(x: 0, y: 0), options: [.drawsAfterEndLocation, .drawsBeforeStartLocation])
        // Perspective grid scrolling with yaw/time
        ctx.setStrokeColor(CGColor(red: 0.85, green: 0.72, blue: 0.45, alpha: 0.35))
        ctx.setLineWidth(1)
        let offset = CGFloat(fmod(f.time * 40, 100))
        for i in 0..<14 {
            let d = CGFloat(i) * 100 + offset
            let y = horizonY - h * 0.6 * (d / (d + 400))
            ctx.move(to: CGPoint(x: big.minX, y: y)); ctx.addLine(to: CGPoint(x: big.maxX, y: y))
        }
        let yawShift = CGFloat(fmod((f.yaw ?? 0) * 6, 120))
        for i in -14...14 {
            let x = w / 2 + CGFloat(i) * 120 + yawShift
            ctx.move(to: CGPoint(x: x, y: horizonY)); ctx.addLine(to: CGPoint(x: w / 2 + (x - w / 2) * 6, y: horizonY - h * 1.2))
        }
        ctx.strokePath()
        // Buildings
        ctx.setFillColor(CGColor(red: 0.16, green: 0.15, blue: 0.14, alpha: 1))
        for i in 0..<9 {
            let x = w * 0.08 + CGFloat(i) * w * 0.1 + CGFloat(sin(Double(i) * 1.7 + f.time / 30)) * 20
            let bh = h * (0.04 + 0.05 * CGFloat(abs(sin(Double(i) * 2.3))))
            ctx.fill(CGRect(x: x, y: horizonY - 2, width: w * 0.05, height: bh))
        }
        ctx.resetClip()
        ctx.restoreGState()
        guard hud else { return }
        // Corner marks + HUD text baked into the "camera feed" like DJI's OSD.
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.7)); ctx.setLineWidth(2)
        let m: CGFloat = 40, l: CGFloat = 40
        for (x, y, sx, sy) in [(m, m, 1, 1), (w - m, m, -1, 1), (m, h - m, 1, -1), (w - m, h - m, -1, -1)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
            ctx.move(to: CGPoint(x: x, y: y + sy * l)); ctx.addLine(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x + sx * l, y: y))
        }
        ctx.strokePath()
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.85))
        ctx.fillEllipse(in: CGRect(x: w / 2 - 3, y: h / 2 - 3, width: 6, height: 6))
        text(ctx, String(format: "H %.1f m   D %.0f m   %.1f m/s", f.relativeAltitude ?? 0, f.homeDistance ?? 0, f.horizontalSpeed ?? 0), at: CGPoint(x: m + 12, y: h - m - 34), size: h / 36)
        text(ctx, String(format: "%d%%   %d sats   %02d:%02d", f.batteryPercent ?? 0, f.satellites ?? 0, Int(f.time) / 60, Int(f.time) % 60), at: CGPoint(x: m + 12, y: m + 12), size: h / 36)
        text(ctx, "MOCK  ISO \(f.iso ?? 0)  \(f.shutter ?? "")  f/\(f.fNumber ?? 0)", at: CGPoint(x: w * 0.55, y: m + 12), size: h / 40)
    }

    func text(_ ctx: CGContext, _ s: String, at p: CGPoint, size: CGFloat) {
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CGColor(gray: 1, alpha: 0.9)]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        ctx.textPosition = p
        CTLineDraw(line, ctx)
    }
}
