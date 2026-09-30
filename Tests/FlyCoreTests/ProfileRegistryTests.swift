import Testing
@testable import FlyCore

@Suite struct ProfileRegistryTests {
    let reg = ProfileRegistry()

    @Test func djiVendorWithAvataNameMatchesAvata2() {
        let d = USBDeviceDescriptor(vendorID: 0x2CA3, productID: 0x0001, productName: "DJI Avata 2")
        let m = reg.match(usb: d)
        #expect(m.profile.id == "dji.avata2")
        #expect(m.score == 80)
    }

    @Test func djiVendorUnknownNameFallsBackToDJIGeneric() {
        let d = USBDeviceDescriptor(vendorID: 0x2CA3, productID: 0x9999, productName: "Mystery",
                                    interfaces: [USBInterfaceDescriptor(number: 0, interfaceClass: USBClass.massStorage)])
        let m = reg.match(usb: d)
        #expect(m.profile.id == "generic.dji")
        #expect(m.profile.supports(.massStorage))
        #expect(!m.profile.supports(.usbVideo))
    }

    @Test func nonDJIWithUVCGetsGenericVideo() {
        let d = USBDeviceDescriptor(vendorID: 0x534D, productID: 0x2109, productName: "USB Video",
                                    interfaces: [USBInterfaceDescriptor(number: 0, interfaceClass: USBClass.video, interfaceSubClass: 1)])
        let m = reg.match(usb: d)
        #expect(m.profile.id == "generic.unknown")
        #expect(m.profile.claim(for: .usbVideo)?.transport == .uvc)
    }

    @Test func exactPIDBeatsNameMatch() {
        var p = BuiltInProfiles.rcN2
        p.usbMatches = [USBMatch(vendorID: 0x2CA3, productIDs: [0x0040])]
        let reg = ProfileRegistry(profiles: [BuiltInProfiles.avata2, p, BuiltInProfiles.generic, BuiltInProfiles.djiUnknown])
        let d = USBDeviceDescriptor(vendorID: 0x2CA3, productID: 0x0040, productName: "DJI Avata 2")
        #expect(reg.match(usb: d).profile.id == "dji.rc-n2")
        #expect(reg.match(usb: d).score == 100)
    }

    @Test func ssidMatch() {
        #expect(reg.match(ssid: "Avata2-ABC123")?.profile.id == "dji.avata2")
        #expect(reg.match(ssid: "HomeWiFi") == nil)
    }

    @Test func volumeWithDCIMIsGenericCard() throws {
        let m = try #require(reg.match(volumeName: "NO NAME", hasFolders: ["DCIM", "MISC"]))
        #expect(m.profile.id == "generic.unknown")
        #expect(m.profile.supports(.massStorage, atLeast: .confirmed))
    }

    @Test func registerOverridesByID() {
        let reg = ProfileRegistry()
        var p = BuiltInProfiles.avata2
        p.displayName = "Renamed"
        reg.register(p)
        #expect(reg.profile(id: "dji.avata2")?.displayName == "Renamed")
        #expect(reg.profiles.filter { $0.id == "dji.avata2" }.count == 1)
    }

    @Test func settingsRoundTrip() throws {
        var s = AppSettings.default
        s.enabledSources.remove(.uvcCapture)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(back == s)
        #expect(!back.isOn(.uvcCapture))
    }
}
import Foundation
