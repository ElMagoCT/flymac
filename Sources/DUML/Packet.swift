import Foundation

/// DUML v1 frame, as documented publicly by dji_rev, samuelsadok/dji_protocol and
/// o-gs/dji-firmware-tools. Layout (little-endian):
///
///   0      0x55                       start of frame
///   1..2   ver_length                 bits 0-9 total length, bits 10-15 version (1)
///   3      crc8                       over bytes 0..2, seed 0x77
///   4      sender                     bits 0-4 device type, bits 5-7 index
///   5      receiver                   same encoding
///   6..7   sequence                   uint16
///   8      cmd_type                   bit 7 = response, bits 5-6 ack type, bits 0-2 encryption
///   9      cmd_set
///   10     cmd_id
///   11..   payload
///   last 2 crc16                      over everything before it, seed 0x3692
public struct DUMLPacket: Equatable, Hashable, Sendable, CustomStringConvertible {
    public static let startByte: UInt8 = 0x55
    public static let headerLength = 11
    public static let minimumLength = 13
    public static let maximumLength = 0x3FF

    public var version: UInt8 = 1
    public var sender: DUMLAddress
    public var receiver: DUMLAddress
    public var sequence: UInt16
    public var isResponse: Bool
    public var ackType: AckType
    public var encryption: UInt8
    public var commandSet: UInt8
    public var commandID: UInt8
    public var payload: [UInt8]

    public enum AckType: UInt8, Codable, Sendable, CaseIterable {
        case none = 0, beforeExecution = 1, afterExecution = 2, reserved = 3
    }

    public init(sender: DUMLAddress, receiver: DUMLAddress, sequence: UInt16, isResponse: Bool = false,
                ackType: AckType = .afterExecution, encryption: UInt8 = 0,
                commandSet: UInt8, commandID: UInt8, payload: [UInt8] = []) {
        self.sender = sender; self.receiver = receiver; self.sequence = sequence
        self.isResponse = isResponse; self.ackType = ackType; self.encryption = encryption
        self.commandSet = commandSet; self.commandID = commandID; self.payload = payload
    }

    public var commandType: UInt8 {
        (isResponse ? 0x80 : 0) | (ackType.rawValue << 5) | (encryption & 0x07)
    }

    public var length: Int { DUMLPacket.headerLength + payload.count + 2 }

    // MARK: Encode

    public func encode() -> [UInt8] {
        precondition(length <= DUMLPacket.maximumLength, "DUML payload too large")
        var out = [UInt8]()
        out.reserveCapacity(length)
        out.append(DUMLPacket.startByte)
        let verLen = UInt16(length & 0x3FF) | (UInt16(version) << 10)
        out.append(UInt8(verLen & 0xFF))
        out.append(UInt8(verLen >> 8))
        out.append(DUMLCRC.crc8(out))
        out.append(sender.rawValue)
        out.append(receiver.rawValue)
        out.append(UInt8(sequence & 0xFF))
        out.append(UInt8(sequence >> 8))
        out.append(commandType)
        out.append(commandSet)
        out.append(commandID)
        out.append(contentsOf: payload)
        let crc = DUMLCRC.crc16(out)
        out.append(UInt8(crc & 0xFF))
        out.append(UInt8(crc >> 8))
        return out
    }

    public var data: Data { Data(encode()) }

    // MARK: Decode

    public enum DecodeError: Error, Equatable, CustomStringConvertible {
        case tooShort(Int)
        case badStartByte(UInt8)
        case badHeaderCRC(expected: UInt8, got: UInt8)
        case lengthMismatch(declared: Int, actual: Int)
        case badFrameCRC(expected: UInt16, got: UInt16)

        public var description: String {
            switch self {
            case .tooShort(let n): return "frame too short (\(n) bytes)"
            case .badStartByte(let b): return String(format: "start byte 0x%02x, expected 0x55", b)
            case .badHeaderCRC(let e, let g): return String(format: "header crc8 %02x, expected %02x", g, e)
            case .lengthMismatch(let d, let a): return "declared length \(d) but got \(a) bytes"
            case .badFrameCRC(let e, let g): return String(format: "frame crc16 %04x, expected %04x", g, e)
            }
        }
    }

    /// Decode exactly one frame occupying the whole slice.
    public static func decode<C: Collection>(_ bytes: C) throws -> DUMLPacket where C.Element == UInt8, C.Index == Int {
        let b = Array(bytes)
        guard b.count >= minimumLength else { throw DecodeError.tooShort(b.count) }
        guard b[0] == startByte else { throw DecodeError.badStartByte(b[0]) }
        let hcrc = DUMLCRC.crc8(b[0..<3])
        guard hcrc == b[3] else { throw DecodeError.badHeaderCRC(expected: hcrc, got: b[3]) }
        let verLen = UInt16(b[1]) | (UInt16(b[2]) << 8)
        let declared = Int(verLen & 0x3FF)
        guard declared == b.count else { throw DecodeError.lengthMismatch(declared: declared, actual: b.count) }
        let fcrc = DUMLCRC.crc16(b[0..<(b.count - 2)])
        let got = UInt16(b[b.count - 2]) | (UInt16(b[b.count - 1]) << 8)
        guard fcrc == got else { throw DecodeError.badFrameCRC(expected: fcrc, got: got) }
        var p = DUMLPacket(sender: DUMLAddress(rawValue: b[4]), receiver: DUMLAddress(rawValue: b[5]),
                           sequence: UInt16(b[6]) | (UInt16(b[7]) << 8),
                           isResponse: b[8] & 0x80 != 0,
                           ackType: AckType(rawValue: (b[8] >> 5) & 0x03) ?? .none,
                           encryption: b[8] & 0x07,
                           commandSet: b[9], commandID: b[10],
                           payload: Array(b[11..<(b.count - 2)]))
        p.version = UInt8(verLen >> 10)
        return p
    }

    /// Length a frame claims from its first three bytes, or nil if the header is not valid.
    public static func declaredLength(_ b: ArraySlice<UInt8>) -> Int? {
        guard b.count >= 4, b[b.startIndex] == startByte else { return nil }
        guard DUMLCRC.crc8(b[b.startIndex..<(b.startIndex + 3)]) == b[b.startIndex + 3] else { return nil }
        let verLen = UInt16(b[b.startIndex + 1]) | (UInt16(b[b.startIndex + 2]) << 8)
        return Int(verLen & 0x3FF)
    }

    public var description: String {
        let dir = isResponse ? "←" : "→"
        let cmd = DUMLCommandSet(rawValue: commandSet).map { "\($0)" } ?? String(format: "set%02x", commandSet)
        let hex = payload.map { String(format: "%02x", $0) }.joined(separator: " ")
        return String(format: "%@ %@ seq %d %@/0x%02x ack=%d [%d] %@", "\(sender)\(dir)\(receiver)", isResponse ? "rsp" : "req",
                      sequence, cmd, commandID, ackType.rawValue, payload.count, hex)
    }
}

/// Device address byte: low 5 bits type, high 3 bits index.
public struct DUMLAddress: RawRepresentable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public init(_ type: DUMLDeviceType, index: UInt8 = 0) { rawValue = (type.rawValue & 0x1F) | (index << 5) }

    public var type: DUMLDeviceType { DUMLDeviceType(rawValue: rawValue & 0x1F) ?? .invalid }
    public var index: UInt8 { rawValue >> 5 }
    public var description: String { index == 0 ? "\(type)" : "\(type)#\(index)" }

    public static let pc = DUMLAddress(.pc)
    public static let app = DUMLAddress(.mobileApp)
    public static let camera = DUMLAddress(.camera)
    public static let flightController = DUMLAddress(.flightController)
    public static let gimbal = DUMLAddress(.gimbal)
    public static let rc = DUMLAddress(.remoteController)
    public static let any = DUMLAddress(.any)
}

/// Device types from dji-firmware-tools comm_dissector.
public enum DUMLDeviceType: UInt8, Sendable, CaseIterable, CustomStringConvertible {
    case invalid = 0, camera = 1, mobileApp = 2, flightController = 3, gimbal = 4, centerBoard = 5
    case remoteController = 6, wifiAir = 7, dm36xAir = 8, hdLinkAir = 9, pc = 10, battery = 11, esc = 12
    case dm36xGround = 13, hdLinkGround = 14, serialToParallelGround = 15, serialToParallelAir = 16
    case monocular = 17, binocular = 18, fpgaAir = 19, fpgaGround = 20, simulator = 21, baseStation = 22
    case airborneComputer = 23, rcBattery = 24, imu = 25, gpsRTK = 26, wifiGround = 27, sigCvt = 28
    case pmuAir = 29, pmuGround = 30, any = 31

    public var description: String {
        switch self {
        case .invalid: return "invalid"; case .camera: return "camera"; case .mobileApp: return "app"
        case .flightController: return "fc"; case .gimbal: return "gimbal"; case .centerBoard: return "center"
        case .remoteController: return "rc"; case .wifiAir: return "wifi-air"; case .dm36xAir: return "dm36x-air"
        case .hdLinkAir: return "hdlink-air"; case .pc: return "pc"; case .battery: return "battery"; case .esc: return "esc"
        case .dm36xGround: return "dm36x-gnd"; case .hdLinkGround: return "hdlink-gnd"
        case .serialToParallelGround: return "s2p-gnd"; case .serialToParallelAir: return "s2p-air"
        case .monocular: return "mono"; case .binocular: return "bino"; case .fpgaAir: return "fpga-air"
        case .fpgaGround: return "fpga-gnd"; case .simulator: return "sim"; case .baseStation: return "base"
        case .airborneComputer: return "onboard"; case .rcBattery: return "rc-batt"; case .imu: return "imu"
        case .gpsRTK: return "rtk"; case .wifiGround: return "wifi-gnd"; case .sigCvt: return "sigcvt"
        case .pmuAir: return "pmu-air"; case .pmuGround: return "pmu-gnd"; case .any: return "any"
        }
    }
}

/// Command sets from dji-firmware-tools comm_dissector.
public enum DUMLCommandSet: UInt8, Sendable, CaseIterable, CustomStringConvertible {
    case general = 0, special = 1, camera = 2, flightController = 3, gimbal = 4, centerBoard = 5
    case remoteController = 6, wifi = 7, dm36x = 8, hdLink = 9, mbino = 10, simulator = 11, esc = 12
    case battery = 13, dataLogger = 14, rtk = 15, automation = 16

    public var description: String {
        switch self {
        case .general: return "general"; case .special: return "special"; case .camera: return "camera"
        case .flightController: return "flyc"; case .gimbal: return "gimbal"; case .centerBoard: return "center"
        case .remoteController: return "rc"; case .wifi: return "wifi"; case .dm36x: return "dm36x"
        case .hdLink: return "hdlink"; case .mbino: return "mbino"; case .simulator: return "sim"; case .esc: return "esc"
        case .battery: return "battery"; case .dataLogger: return "log"; case .rtk: return "rtk"; case .automation: return "auto"
        }
    }
}

/// Command IDs FlyMac is allowed to send. This list is deliberately read-only:
/// nothing here moves the aircraft. Sources: comm_dissector general.lua.
public enum DUMLGeneralCommand: UInt8, Sendable {
    case ping = 0x00
    case getVersion = 0x01
    case getDeviceInfo = 0x27   // "Get Device Info" / component info string in comm_dissector
}
