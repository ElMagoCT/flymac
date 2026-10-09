import Foundation
import Telemetry

/// A deterministic fake flight: take off, climb, fly a wide loop, come home.
/// Used for the mock SRT, the mock DUML pushes and the mock video's HUD, so
/// all three agree with each other.
public struct SyntheticFlight: Sendable {
    public var home = (lat: 33.610210, lon: -112.008430)
    public var duration: TimeInterval = 240
    public var maxAltitude = 88.0
    public var radius = 260.0   // metres
    /// Seconds added to every lookup so several mocks are not in lockstep.
    public var phase: TimeInterval = 0
    /// Sky tint for the rendered scene, so mock feeds are easy to tell apart.
    public var skyHue: Double = 0

    public init() {}

    /// A distinct but deterministic flight per index (0 = the mock aircraft's own).
    public init(variant: Int) {
        let v = Double(variant)
        home = (33.610210 + 0.0021 * sin(v * 2.1), -112.008430 + 0.0024 * cos(v * 1.7))
        duration = 240 + 35 * v
        maxAltitude = 88 - 14 * v + (variant % 2 == 0 ? 0 : 20)
        radius = 260 - 45 * v
        phase = 23 * v
        skyHue = [0, 0.09, -0.07, 0.16, -0.12][variant % 5]
    }

    public func frame(at time: TimeInterval, index: Int) -> TelemetryFrame {
        let t = fmod(time + phase, duration)
        var f = TelemetryFrame(index: index, time: time)
        let p = max(0, min(1, t / duration))
        // altitude: climb 0-15%, cruise, descend last 15%
        let alt: Double
        if p < 0.15 { alt = maxAltitude * smooth(p / 0.15) }
        else if p > 0.85 { alt = maxAltitude * smooth((1 - p) / 0.15) }
        else { alt = maxAltitude + 6 * sin(t / 7) }
        f.relativeAltitude = alt
        f.absoluteAltitude = alt + 512.3
        // position: loop around home
        let a = p * 2 * .pi
        let r = radius * sin(min(1, p / 0.15) * .pi / 2) * (p > 0.85 ? sin((1 - p) / 0.15 * .pi / 2) : 1)
        let dx = r * cos(a), dy = r * sin(a)
        f.latitude = home.lat + dy / 111_320
        f.longitude = home.lon + dx / (111_320 * cos(home.lat * .pi / 180))
        let speed = 2 * .pi * r / duration
        f.horizontalSpeed = (p > 0.02 && p < 0.98) ? speed + 0.8 * sin(t / 3) : 0
        f.verticalSpeed = p < 0.15 ? maxAltitude / (duration * 0.15) : p > 0.85 ? -maxAltitude / (duration * 0.15) : 0.3 * cos(t / 7)
        f.yaw = fmod(a * 180 / .pi + 90, 360) - 180
        f.roll = 12 * sin(t / 4)
        f.pitch = -8 + 3 * sin(t / 5)
        f.batteryPercent = Int((96 - 60 * p).rounded())
        f.batteryVoltage = 17.2 - 2.4 * p
        f.satellites = 14 + Int(3 * sin(t / 11))
        f.signalPercent = max(40, min(100, Int(100 - 25 * (r / radius) + 4 * sin(t / 2))))
        f.homeDistance = r
        f.iso = 100 + Int(20 * abs(sin(t / 9)))
        f.shutter = "1/\(Int(1600 + 400 * sin(t / 13)))"
        f.fNumber = 2.8
        f.exposureValue = 0
        f.colorTemperature = 5500
        f.colorMode = "default"
        f.focalLength = 24
        f.frameDurationMs = 33
        f.date = Date(timeIntervalSince1970: 1_790_000_000 + t)
        return f
    }

    public func track(fps: Double = 30, source: String = "mock") -> TelemetryTrack {
        let n = Int(duration * fps)
        return TelemetryTrack(frames: (0..<n).map { frame(at: Double($0) / fps, index: $0 + 1) }, source: source)
    }

    /// DJI-style SRT text for a clip starting at `offset` lasting `length` seconds.
    public func srt(offset: TimeInterval, length: TimeInterval, fps: Double = 30) -> String {
        var out = ""
        let n = Int(length * fps)
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; df.locale = Locale(identifier: "en_US_POSIX")
        for i in 0..<n {
            let t0 = Double(i) / fps, t1 = Double(i + 1) / fps
            let f = frame(at: offset + t0, index: i + 1)
            out += "\(i + 1)\n\(ts(t0)) --> \(ts(t1))\n"
            out += "<font size=\"28\">SrtCnt : \(i + 1), DiffTime : 33ms\n\(df.string(from: f.date!))\n"
            out += String(format: "[iso : %d] [shutter : %@] [fnum : %d] [ev : %g] [ct : %d] [color_md : %@] [focal_len : %d] [latitude: %.6f] [longitude: %.6f] [rel_alt: %.3f abs_alt: %.3f] </font>\n\n",
                          f.iso!, f.shutter!, Int(f.fNumber! * 100), f.exposureValue!, f.colorTemperature!, f.colorMode!,
                          Int(f.focalLength! * 10), f.latitude!, f.longitude!, f.relativeAltitude!, f.absoluteAltitude!)
        }
        return out
    }

    func ts(_ t: TimeInterval) -> String {
        let h = Int(t) / 3600, m = Int(t) % 3600 / 60, s = Int(t) % 60, ms = Int((t - floor(t)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    func smooth(_ x: Double) -> Double { x * x * (3 - 2 * x) }
}
