import Testing
import Foundation
@testable import DUML
import Fixtures

@Suite struct CRCTests {
    @Test func tablesMatchPublishedHeads() {
        // dji-firmware-tools comm_dissector tables.
        #expect(Array(DUMLCRC.crc8Table[0..<8]) == [0x00, 0x5e, 0xbc, 0xe2, 0x61, 0x3f, 0xdd, 0x83])
        #expect(Array(DUMLCRC.crc16Table[0..<8]) == [0x0000, 0x1189, 0x2312, 0x329b, 0x4624, 0x57ad, 0x6536, 0x74bf])
    }

    @Test func knownHeaderCRC() {
        // "55 0d 04 33" is the header of a 13-byte v1 frame as seen in public captures.
        #expect(DUMLCRC.crc8([0x55, 0x0d, 0x04]) == 0x33)
    }
}

struct Ref: Decodable {
    struct P: Decodable {
        var name: String; var sender: UInt8; var receiver: UInt8; var sequence: UInt16
        var commandSet: UInt8; var commandID: UInt8; var payload: String; var isResponse: Bool
        var ackType: UInt8; var frame: String
    }
    var crc8_table_head: [UInt8]; var crc16_table_head: [UInt16]
    var crc8_of_55_0d_04: UInt8; var packets: [P]

    static func load() throws -> Ref {
        try JSONDecoder().decode(Ref.self, from: try Fixtures.data("duml-reference", ext: "json"))
    }
}

@Suite struct PacketCodecTests {
    @Test func encodeMatchesPythonReference() throws {
        let ref = try Ref.load()
        #expect(ref.crc8_of_55_0d_04 == DUMLCRC.crc8([0x55, 0x0d, 0x04]))
        #expect(ref.packets.count >= 6)
        for p in ref.packets {
            let pkt = DUMLPacket(sender: .init(rawValue: p.sender), receiver: .init(rawValue: p.receiver),
                                 sequence: p.sequence, isResponse: p.isResponse,
                                 ackType: .init(rawValue: p.ackType)!, commandSet: p.commandSet,
                                 commandID: p.commandID, payload: Hex.bytes(p.payload))
            #expect(Hex.string(pkt.encode(), separator: "") == p.frame, "\(p.name)")
        }
    }

    @Test func decodeMatchesPythonReference() throws {
        for p in try Ref.load().packets {
            let pkt = try DUMLPacket.decode(Hex.bytes(p.frame))
            #expect(pkt.sender.rawValue == p.sender, "\(p.name)")
            #expect(pkt.receiver.rawValue == p.receiver, "\(p.name)")
            #expect(pkt.sequence == p.sequence, "\(p.name)")
            #expect(pkt.commandSet == p.commandSet, "\(p.name)")
            #expect(pkt.commandID == p.commandID, "\(p.name)")
            #expect(pkt.isResponse == p.isResponse, "\(p.name)")
            #expect(pkt.ackType.rawValue == p.ackType, "\(p.name)")
            #expect(Hex.string(pkt.payload, separator: "") == p.payload, "\(p.name)")
            #expect(pkt.version == 1)
        }
    }

    @Test func roundTripRandom() throws {
        for _ in 0..<200 {
            let n = Int.random(in: 0..<400)
            let p = DUMLPacket(sender: .init(rawValue: .random(in: 0...255)), receiver: .init(rawValue: .random(in: 0...255)),
                               sequence: .random(in: 0...65535), isResponse: .random(),
                               ackType: DUMLPacket.AckType.allCases.randomElement()!, encryption: .random(in: 0...7),
                               commandSet: .random(in: 0...255), commandID: .random(in: 0...255),
                               payload: (0..<n).map { _ in UInt8.random(in: 0...255) })
            #expect(try DUMLPacket.decode(p.encode()) == p)
        }
    }

    @Test func addressEncoding() {
        let a = DUMLAddress(.camera, index: 1)
        #expect(a.rawValue == 0x21)
        #expect(a.type == .camera)
        #expect(a.index == 1)
        #expect("\(a)" == "camera#1")
        #expect(DUMLAddress.pc.rawValue == 0x0A)
    }

    @Test func commandTypeBits() {
        var p = DUMLPacket(sender: .pc, receiver: .rc, sequence: 0, isResponse: true, ackType: .beforeExecution, encryption: 3, commandSet: 0, commandID: 0)
        #expect(p.commandType == 0x80 | 0x20 | 0x03)
        p.isResponse = false; p.ackType = .afterExecution; p.encryption = 0
        #expect(p.commandType == 0x40)
    }

    @Test func rejectsCorruption() throws {
        let good = DUMLPacket(sender: .pc, receiver: .rc, sequence: 9, commandSet: 0, commandID: 1, payload: [1, 2, 3]).encode()
        var bad = good; bad[0] = 0x54
        #expect(throws: DUMLPacket.DecodeError.badStartByte(0x54)) { try DUMLPacket.decode(bad) }
        bad = good; bad[3] ^= 0xFF
        #expect(throws: DUMLPacket.DecodeError.self) { try DUMLPacket.decode(bad) }
        bad = good; bad[12] ^= 0x01
        #expect(throws: DUMLPacket.DecodeError.self) { try DUMLPacket.decode(bad) }
        #expect(throws: DUMLPacket.DecodeError.tooShort(12)) { try DUMLPacket.decode(Array(good.prefix(12))) }
        #expect(throws: DUMLPacket.DecodeError.self) { try DUMLPacket.decode(good + [0x00]) }
    }
}

@Suite struct ParserTests {
    @Test func resyncsThroughGarbageAndSplits() {
        let a = DUMLPacket(sender: .rc, receiver: .pc, sequence: 1, commandSet: 6, commandID: 5, payload: [9, 9]).encode()
        let b = DUMLPacket(sender: .flightController, receiver: .pc, sequence: 2, commandSet: 3, commandID: 0x43, payload: Array(repeating: 0xAB, count: 50)).encode()
        let stream = [0x00, 0x55, 0x12] + a + [0xFF, 0x55] + b + [0x55, 0x0d]
        var parser = DUMLParser()
        var got: [DUMLPacket] = []
        for byte in stream { got += parser.feed([byte]) }
        #expect(got.count == 2)
        #expect(got[0].sequence == 1)
        #expect(got[1].payload.count == 50)
        #expect(parser.droppedBytes > 0)
        #expect(parser.pendingBytes == 2)
    }

    @Test func hexHelpers() {
        #expect(Hex.bytes("55 0d:04 33") == [0x55, 0x0d, 0x04, 0x33])
        #expect(Hex.string([0x55, 0x0d]) == "55 0d")
    }
}
