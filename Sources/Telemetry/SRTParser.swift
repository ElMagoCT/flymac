import Foundation

/// Parses DJI `.SRT` telemetry sidecars. Two public formats are handled:
///
/// 1. Bracketed key/value (Mini 2 onward, Air 2S, Avata, Avata 2, Mini 4 Pro…):
///    ```
///    1
///    00:00:00,000 --> 00:00:00,033
///    <font size="28">SrtCnt : 1, DiffTime : 33ms
///    2025-06-14 10:22:33.123
///    [iso : 100] [shutter : 1/1000.0] [fnum : 280] [ev : 0] [ct : 5500] [color_md : default]
///    [focal_len : 240] [latitude: 33.448400] [longitude: -112.074000] [rel_alt: 12.300 abs_alt: 350.100] </font>
///    ```
/// 2. Older `HOME(...) GPS(...) BAROMETER:` lines (Phantom 4, Mavic Pro).
///
/// Field naming and scaling come from published DJI SRT samples (e.g. the
/// dji-srt-parser project and many user uploads). `fnum : 280` is f/2.8 and
/// `focal_len : 240` is 24 mm; both are divided by 100 and 10 respectively.
public enum SRTParser {
    public static func parse(_ text: String, source: String = "srt") -> TelemetryTrack {
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var frames: [TelemetryFrame] = []
        frames.reserveCapacity(blocks.count)
        for block in blocks {
            if let f = parseBlock(block, fallbackIndex: frames.count + 1) { frames.append(f) }
        }
        return TelemetryTrack(frames: frames, source: source)
    }

    static func parseBlock(_ block: String, fallbackIndex: Int) -> TelemetryFrame? {
        let lines = block.components(separatedBy: "\n")
        guard lines.count >= 2 else { return nil }
        var idx = Int(lines[0].trimmingCharacters(in: .whitespaces)) ?? fallbackIndex
        var timeLine = lines[1]
        var bodyStart = 2
        if !timeLine.contains("-->") {
            // Some files omit the counter line.
            timeLine = lines[0]; bodyStart = 1; idx = fallbackIndex
        }
        guard let start = timeLine.components(separatedBy: "-->").first, let t = parseTimestamp(start) else { return nil }
        var f = TelemetryFrame(index: idx, time: t)
        let body = lines[bodyStart...].joined(separator: " ")
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)

        // Format 1: [key : value] pairs (also "key : value" inside brackets with several pairs).
        for m in matches("\\[([^\\]]+)\\]", in: body) {
            for kv in matches("([A-Za-z_]+)\\s*:\\s*([^\\s\\]]+)", in: m) {
                guard let c = kv.range(of: ":") else { continue }
                apply(key: kv[..<c.lowerBound].trimmingCharacters(in: .whitespaces).lowercased(),
                      value: kv[kv.index(after: c.lowerBound)...].trimmingCharacters(in: .whitespaces), to: &f)
            }
        }
        // Loose "SrtCnt : 1, DiffTime : 33ms" and a date line.
        for kv in matches("(SrtCnt|DiffTime)\\s*:\\s*([0-9]+)", in: body) {
            let parts = kv.components(separatedBy: ":")
            if parts.count == 2 { apply(key: parts[0].trimmingCharacters(in: .whitespaces).lowercased(), value: parts[1].trimmingCharacters(in: .whitespaces), to: &f) }
        }
        if let d = matches("\\d{4}-\\d{2}-\\d{2}[ T]\\d{2}:\\d{2}:\\d{2}(?:[.,]\\d+)?", in: body).first {
            f.date = dateFormatter.date(from: String(d.prefix(19)))
        }
        // Format 2: GPS(lon,lat,n) BAROMETER:x
        if let gps = matches("GPS\\s*\\(([^)]*)\\)", in: body).first {
            let nums = gps.components(separatedBy: CharacterSet(charactersIn: "(),")).compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if nums.count >= 2 { f.longitude = nums[0]; f.latitude = nums[1] }
            if nums.count >= 3 { f.satellites = Int(nums[2]) }
        }
        if let baro = matches("BAROMETER\\s*:\\s*(-?[0-9.]+)", in: body).first,
           let v = Double(baro.components(separatedBy: ":").last!.trimmingCharacters(in: .whitespaces)) { f.relativeAltitude = v }
        if let hd = matches("HOME\\s*\\(([^)]*)\\)", in: body).first { _ = hd }
        return f
    }

    static func apply(key: String, value: String, to f: inout TelemetryFrame) {
        let d = Double(value)
        switch key {
        case "iso": f.iso = Int(value)
        case "shutter": f.shutter = value
        case "fnum": if let d { f.fNumber = d > 50 ? d / 100 : d }
        case "ev": f.exposureValue = d
        case "ct": f.colorTemperature = Int(value)
        case "color_md": f.colorMode = value
        case "focal_len", "focal_length": if let d { f.focalLength = d > 100 ? d / 10 : d }
        case "latitude", "lat": f.latitude = d
        case "longitude", "lon", "long": f.longitude = d
        case "rel_alt", "altitude": f.relativeAltitude = d
        case "abs_alt": f.absoluteAltitude = d
        case "h_speed", "hs": f.horizontalSpeed = d
        case "v_speed", "vs": f.verticalSpeed = d
        case "gps_num", "sat", "satellites": f.satellites = Int(value)
        case "battery", "batt": f.batteryPercent = Int(value.replacingOccurrences(of: "%", with: ""))
        case "signal", "rc_signal": f.signalPercent = Int(value)
        case "srtcnt": f.index = Int(value) ?? f.index
        case "difftime": f.frameDurationMs = Int(value)
        case "home_dist", "dist": f.homeDistance = d
        default: break
        }
    }

    static func parseTimestamp(_ s: String) -> TimeInterval? {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = t.components(separatedBy: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }

    static func matches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
}
