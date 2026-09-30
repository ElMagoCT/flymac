import Foundation

/// One moment of aircraft state. Every field is optional because every source
/// (SRT sidecar, DUML push, mock) knows a different subset.
public struct TelemetryFrame: Codable, Sendable, Equatable, Identifiable {
    public var id: Int { index }
    public var index: Int
    /// Seconds from the start of the stream/recording.
    public var time: TimeInterval
    /// Wall-clock time if the source carries one.
    public var date: Date?

    public var latitude: Double?
    public var longitude: Double?
    /// Metres above take-off.
    public var relativeAltitude: Double?
    /// Metres above sea level (barometric or GPS as given).
    public var absoluteAltitude: Double?
    /// Metres per second, horizontal and vertical.
    public var horizontalSpeed: Double?
    public var verticalSpeed: Double?
    public var satellites: Int?
    public var batteryPercent: Int?
    public var batteryVoltage: Double?
    /// 0…100 link quality if known.
    public var signalPercent: Int?
    public var pitch: Double?
    public var roll: Double?
    public var yaw: Double?
    public var homeDistance: Double?

    // Camera
    public var iso: Int?
    public var shutter: String?
    public var fNumber: Double?
    public var exposureValue: Double?
    public var colorTemperature: Int?
    public var colorMode: String?
    /// Focal length as written by the camera (DJI writes it ×10, e.g. 240 = 24 mm).
    public var focalLength: Double?
    public var frameDurationMs: Int?

    public init(index: Int, time: TimeInterval) { self.index = index; self.time = time }

    public var hasPosition: Bool { latitude != nil && longitude != nil && latitude != 0 && longitude != 0 }
}

/// A whole flight (or one clip) of frames plus derived stats.
public struct TelemetryTrack: Sendable, Equatable {
    public var frames: [TelemetryFrame]
    public var source: String

    public init(frames: [TelemetryFrame], source: String) { self.frames = frames; self.source = source }

    public var duration: TimeInterval { frames.last?.time ?? 0 }
    public var positioned: [TelemetryFrame] { frames.filter(\.hasPosition) }
    public var maxAltitude: Double? { frames.compactMap(\.relativeAltitude).max() }
    public var maxSpeed: Double? { frames.compactMap(\.horizontalSpeed).max() }

    /// Total ground distance in metres from the positioned frames (haversine).
    public var distance: Double {
        let p = positioned
        guard p.count > 1 else { return 0 }
        var d = 0.0
        for i in 1..<p.count { d += Geo.distance(p[i-1].latitude!, p[i-1].longitude!, p[i].latitude!, p[i].longitude!) }
        return d
    }

    public func frame(at t: TimeInterval) -> TelemetryFrame? {
        guard !frames.isEmpty else { return nil }
        var lo = 0, hi = frames.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if frames[mid].time <= t { lo = mid } else { hi = mid - 1 }
        }
        return frames[lo]
    }
}

public enum Geo {
    public static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180, dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat/2) * sin(dLat/2) + cos(lat1 * .pi/180) * cos(lat2 * .pi/180) * sin(dLon/2) * sin(dLon/2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }
}
