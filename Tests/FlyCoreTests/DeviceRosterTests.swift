import Testing
import Foundation
@testable import FlyCore

private func goggles(loc: UInt32, serial: String? = nil, seen: TimeInterval) -> DiscoveredDevice {
    let usb = USBDeviceDescriptor(vendorID: 0x2CA3, productID: 0x0020, productName: "DJI Goggles N3", serialNumber: serial, locationID: loc)
    let m = ProfileMatch(profile: BuiltInProfiles.gogglesN3, score: 80, reasons: [])
    return DiscoveredDevice(id: "usb:\(usb.id)", origin: .usb, match: m, usb: usb, firstSeen: Date(timeIntervalSince1970: seen))
}

@Suite struct DeviceRosterTests {
    @Test func singleDeviceHasNoNumber() {
        var r = DeviceRoster()
        let g = goggles(loc: 0x100000, serial: "AAA", seen: 1)
        let l = r.update([g])
        #expect(l[g.id]?.name == "DJI Goggles N3")
        #expect(l[g.id]?.ordinal == nil)
    }

    @Test func identicalGogglesGetStableNumbersAndColours() {
        var r = DeviceRoster()
        let a = goggles(loc: 0x100000, serial: "AAA", seen: 1)
        let b = goggles(loc: 0x200000, serial: "BBB", seen: 2)
        let l = r.update([b, a])                       // order of the array must not matter
        #expect(l[a.id]?.name == "DJI Goggles N3 1")
        #expect(l[b.id]?.name == "DJI Goggles N3 2")
        #expect(l[a.id]?.colorSlot != l[b.id]?.colorSlot)

        // Unplug #1: #2 keeps its number, and is the only one so loses the suffix.
        let l2 = r.update([b])
        #expect(l2[b.id]?.name == "DJI Goggles N3")
        #expect(r.labels[b.id]?.colorSlot == l[b.id]?.colorSlot)

        // A third pair arrives while #2 is still here: takes the free number 1.
        let c = goggles(loc: 0x300000, serial: "CCC", seen: 3)
        let l3 = r.update([b, c])
        #expect(l3[b.id]?.name == "DJI Goggles N3 2")
        #expect(l3[c.id]?.name == "DJI Goggles N3 1")
    }

    @Test func noSerialFallsBackToPort() {
        let a = goggles(loc: 0x100000, seen: 1), b = goggles(loc: 0x200000, seen: 1)
        #expect(a.stableKey != b.stableKey)
        var r = DeviceRoster()
        let l = r.update([a, b])
        #expect(Set([l[a.id]!.name, l[b.id]!.name]) == ["DJI Goggles N3 1", "DJI Goggles N3 2"])
    }

    @Test func nicknameWins() {
        var r = DeviceRoster()
        let a = goggles(loc: 0x100000, serial: "AAA", seen: 1)
        let b = goggles(loc: 0x200000, serial: "BBB", seen: 2)
        let l = r.update([a, b], nicknames: [b.stableKey: "  Jake's goggles "])
        #expect(l[b.id]?.name == "Jake's goggles")
        #expect(l[b.id]?.isNickname == true)
        #expect(l[a.id]?.name == "DJI Goggles N3 1")
    }

    @Test func differentProfilesNumberSeparately() {
        var r = DeviceRoster()
        let g = goggles(loc: 0x100000, serial: "AAA", seen: 1)
        let rc = DiscoveredDevice(id: "usb:rc", origin: .usb, match: ProfileMatch(profile: BuiltInProfiles.rcN2, score: 80, reasons: []),
                                  usb: USBDeviceDescriptor(vendorID: 0x2CA3, productID: 0x1020, serialNumber: "R1", locationID: 0x400000))
        let l = r.update([g, rc])
        #expect(l[g.id]?.ordinal == nil)
        #expect(l[rc.id]?.name == "DJI RC-N2")
    }

    @Test func oldSettingsFileStillDecodes() throws {
        // A settings file written before multi-device fields existed.
        let old = #"{"enabledSources":["mockDevice"],"enabledTools":["library"],"libraryPath":"/x","parallelDownloads":2,"verifyHashes":true,"pairProxies":true,"autoOfferOnDetect":false,"recordingCodec":"hevc"}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        #expect(s.parallelDownloads == 2)
        #expect(s.mockGoggles == 0)
        #expect(s.deviceNicknames.isEmpty)
        #expect(s.linkMonitorTools)
    }
}
