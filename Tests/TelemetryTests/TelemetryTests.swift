import Testing
import Foundation
@testable import Telemetry
import DUML
import Fixtures

@Suite struct SRTParserTests {
    @Test func parsesBracketedFormat() throws {
        let track = SRTParser.parse(try Fixtures.string("sample-avata2", ext: "SRT"))
        #expect(track.frames.count == 3)
        let f = track.frames[2]
        #expect(f.index == 3)
        #expect(abs(f.time - 0.066) < 0.001)
        #expect(f.iso == 110)
        #expect(f.shutter == "1/1600.0")
        #expect(f.fNumber == 2.8)
        #expect(f.exposureValue == 0.3)
        #expect(f.colorTemperature == 5490)
        #expect(f.focalLength == 24)
        #expect(f.latitude == 33.6103)
        #expect(f.longitude == -112.0085)
        #expect(f.relativeAltitude == 12.3)
        #expect(f.absoluteAltitude == 524.6)
        #expect(f.frameDurationMs == 34)
        #expect(f.date != nil)
        #expect(track.maxAltitude == 12.3)
        #expect(track.distance > 5 && track.distance < 20)
    }

    @Test func parsesLegacyFormat() throws {
        let track = SRTParser.parse(try Fixtures.string("sample-legacy", ext: "SRT"))
        #expect(track.frames.count == 2)
        #expect(track.frames[0].longitude == -112.0741)
        #expect(track.frames[0].latitude == 33.4485)
        #expect(track.frames[0].satellites == 17)
        #expect(track.frames[1].relativeAltitude == 24.1)
        #expect(track.frames[1].time == 1)
    }

    @Test func frameLookupByTime() throws {
        let track = SRTParser.parse(try Fixtures.string("sample-avata2", ext: "SRT"))
        #expect(track.frame(at: 0.05)?.index == 2)
        #expect(track.frame(at: -1)?.index == 1)
        #expect(track.frame(at: 99)?.index == 3)
    }

    @Test func garbageIsIgnored() {
        #expect(SRTParser.parse("").frames.isEmpty)
        #expect(SRTParser.parse("hello\nworld").frames.isEmpty)
    }
}

@Suite struct DUMLTelemetryTests {
    @Test func osdGeneralRoundTrip() {
        var f = TelemetryFrame(index: 0, time: 0)
        f.latitude = 33.61021; f.longitude = -112.00843; f.relativeAltitude = 42.5
        f.horizontalSpeed = 7.2; f.verticalSpeed = -1.5; f.pitch = -3; f.roll = 1.2; f.yaw = 178.4
        f.batteryPercent = 67; f.satellites = 14
        let payload = DUMLTelemetry.encodeOSDGeneral(f)
        let pkt = DUMLPacket(sender: .flightController, receiver: .pc, sequence: 1, ackType: .none,
                             commandSet: 3, commandID: 0x43, payload: payload)
        let back = DUMLTelemetry.decode(try! DUMLPacket.decode(pkt.encode()), index: 5, time: 1.5)!
        #expect(abs(back.latitude! - 33.61021) < 1e-6)
        #expect(abs(back.longitude! + 112.00843) < 1e-6)
        #expect(back.relativeAltitude == 42.5)
        #expect(abs(back.horizontalSpeed! - 7.2) < 0.01)
        #expect(abs(back.verticalSpeed! + 1.5) < 0.01)
        #expect(back.yaw == 178.4)
        #expect(back.batteryPercent == 67)
        #expect(back.satellites == 14)
        #expect(back.index == 5 && back.time == 1.5)
    }

    @Test func ignoresOtherPackets() {
        let pkt = DUMLPacket(sender: .rc, receiver: .pc, sequence: 1, commandSet: 6, commandID: 5, payload: [0, 0])
        #expect(DUMLTelemetry.decode(pkt, index: 0, time: 0) == nil)
        let short = DUMLPacket(sender: .flightController, receiver: .pc, sequence: 1, commandSet: 3, commandID: 0x43, payload: [1, 2])
        #expect(DUMLTelemetry.decode(short, index: 0, time: 0) == nil)
    }

    @Test func rcSnapshotDiff() {
        let a = RCChannelSnapshot(payload: [0x00, 0x04, 0x00, 0x04, 0x00, 0x04])
        let b = RCChannelSnapshot(payload: [0x00, 0x04, 0x10, 0x04, 0x00, 0x04])
        #expect(b.changedWords(from: a) == [1])
        #expect(a.words == [1024, 1024, 1024])
    }
}
