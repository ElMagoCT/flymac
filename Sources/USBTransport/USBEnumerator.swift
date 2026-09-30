import Foundation
import IOKit
import IOKit.usb
import IOUSBHost
import FlyCore

/// Reads the IORegistry for every attached USB device. Nothing is opened, so
/// this never disturbs a device or a kernel driver.
public enum USBEnumerator {
    public static let deviceClassName = "IOUSBHostDevice"
    public static let interfaceClassName = "IOUSBHostInterface"

    public static func allDevices() -> [USBDeviceDescriptor] {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(deviceClassName), &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        var out: [USBDeviceDescriptor] = []
        while case let s = IOIteratorNext(it), s != 0 {
            defer { IOObjectRelease(s) }
            if let d = describe(service: s) { out.append(d) }
        }
        return out
    }

    /// Full descriptor for one device service, including interfaces and (when
    /// the device can be opened non-exclusively) endpoints.
    public static func describe(service s: io_service_t) -> USBDeviceDescriptor? {
        guard let vid: Int = prop(s, "idVendor"), let pid: Int = prop(s, "idProduct") else { return nil }
        var d = USBDeviceDescriptor(vendorID: UInt16(vid), productID: UInt16(pid))
        d.vendorName = prop(s, "USB Vendor Name")
        d.productName = prop(s, "USB Product Name")
        d.serialNumber = prop(s, "USB Serial Number")
        d.deviceClass = (prop(s, "bDeviceClass") as Int?).map(UInt8.init(truncatingIfNeeded:))
        d.deviceSubClass = (prop(s, "bDeviceSubClass") as Int?).map(UInt8.init(truncatingIfNeeded:))
        d.deviceProtocol = (prop(s, "bDeviceProtocol") as Int?).map(UInt8.init(truncatingIfNeeded:))
        d.bcdDevice = (prop(s, "bcdDevice") as Int?).map(UInt16.init(truncatingIfNeeded:))
        d.usbVersion = (prop(s, "bcdUSB") as Int?).map(UInt16.init(truncatingIfNeeded:))
        d.locationID = (prop(s, "locationID") as Int?).map(UInt32.init(truncatingIfNeeded:))
        if let speed: Int = prop(s, "Device Speed") {
            d.speed = ["low 1.5 Mb/s", "full 12 Mb/s", "high 480 Mb/s", "super 5 Gb/s", "super+ 10 Gb/s", "super+ 20 Gb/s"][safe: speed] ?? "speed \(speed)"
        }

        // Children: interfaces, and any driver that matched the device itself.
        var interfaces: [USBInterfaceDescriptor] = []
        forEachChild(of: s) { child, cls in
            if IOObjectConformsTo(child, interfaceClassName) != 0 {
                interfaces.append(describeInterface(child))
            } else if d.claimedBy == nil {
                d.claimedBy = cls
                // Composite driver inserts a layer; interfaces live under it.
                forEachChild(of: child) { grand, _ in
                    if IOObjectConformsTo(grand, interfaceClassName) != 0 { interfaces.append(describeInterface(grand)) }
                }
            }
        }
        d.interfaces = interfaces.sorted { ($0.number, $0.alternateSetting) < ($1.number, $1.alternateSetting) }
        fillEndpoints(&d, service: s)
        return d
    }

    static func describeInterface(_ s: io_service_t) -> USBInterfaceDescriptor {
        var i = USBInterfaceDescriptor(number: UInt8(truncatingIfNeeded: prop(s, "bInterfaceNumber") as Int? ?? 0),
                                       alternateSetting: UInt8(truncatingIfNeeded: prop(s, "bAlternateSetting") as Int? ?? 0),
                                       interfaceClass: UInt8(truncatingIfNeeded: prop(s, "bInterfaceClass") as Int? ?? 0),
                                       interfaceSubClass: UInt8(truncatingIfNeeded: prop(s, "bInterfaceSubClass") as Int? ?? 0),
                                       interfaceProtocol: UInt8(truncatingIfNeeded: prop(s, "bInterfaceProtocol") as Int? ?? 0))
        i.name = prop(s, "USB Interface Name")
        forEachChild(of: s) { _, cls in if i.claimedBy == nil { i.claimedBy = cls } }
        return i
    }

    /// Endpoints are not in the registry; parse the configuration descriptor
    /// through IOUSBHost. Opening the *device* object is shared (not exclusive),
    /// so this does not fight kernel drivers. Failures are silent: the
    /// descriptor stays useful without endpoints.
    static func fillEndpoints(_ d: inout USBDeviceDescriptor, service s: io_service_t) {
        guard let dev = try? IOUSBHostDevice(__ioService: s, options: [], queue: nil, interestHandler: nil),
              let cfg = dev.configurationDescriptor else { return }
        defer { dev.destroy() }
        var ifd: UnsafePointer<IOUSBInterfaceDescriptor>? = nil
        while let next = IOUSBGetNextInterfaceDescriptor(cfg, UnsafeRawPointer(ifd)?.assumingMemoryBound(to: IOUSBDescriptorHeader.self)) {
            ifd = next
            let num = next.pointee.bInterfaceNumber, alt = next.pointee.bAlternateSetting
            var eps: [USBEndpointDescriptor] = []
            var epd: UnsafePointer<IOUSBEndpointDescriptor>? = nil
            while let e = IOUSBGetNextEndpointDescriptor(cfg, next, UnsafeRawPointer(epd)?.assumingMemoryBound(to: IOUSBDescriptorHeader.self)) {
                epd = e
                let addr = e.pointee.bEndpointAddress
                let kind: USBEndpointDescriptor.Kind = [.control, .isochronous, .bulk, .interrupt][Int(e.pointee.bmAttributes & 0x03)]
                eps.append(USBEndpointDescriptor(address: addr, direction: addr & 0x80 != 0 ? .in : .out, kind: kind,
                                                 maxPacketSize: e.pointee.wMaxPacketSize & 0x07FF, interval: e.pointee.bInterval))
            }
            if let idx = d.interfaces.firstIndex(where: { $0.number == num && $0.alternateSetting == alt }) {
                d.interfaces[idx].endpoints = eps
            } else {
                d.interfaces.append(USBInterfaceDescriptor(number: num, alternateSetting: alt, interfaceClass: next.pointee.bInterfaceClass,
                                                           interfaceSubClass: next.pointee.bInterfaceSubClass,
                                                           interfaceProtocol: next.pointee.bInterfaceProtocol, endpoints: eps))
            }
        }
        d.interfaces.sort { ($0.number, $0.alternateSetting) < ($1.number, $1.alternateSetting) }
    }

    /// Find the io_service for a descriptor (by locationID) so it can be opened.
    public static func service(for d: USBDeviceDescriptor) -> io_service_t? {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(deviceClassName), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        while case let s = IOIteratorNext(it), s != 0 {
            if let loc: Int = prop(s, "locationID"), UInt32(truncatingIfNeeded: loc) == d.locationID,
               let vid: Int = prop(s, "idVendor"), UInt16(vid) == d.vendorID { return s }
            IOObjectRelease(s)
        }
        return nil
    }

    /// Interface services under a device service, with their interface numbers.
    public static func interfaceServices(under device: io_service_t) -> [(number: UInt8, service: io_service_t)] {
        var out: [(UInt8, io_service_t)] = []
        forEachChild(of: device, retain: true) { child, _ in
            if IOObjectConformsTo(child, interfaceClassName) != 0 {
                out.append((UInt8(truncatingIfNeeded: prop(child, "bInterfaceNumber") as Int? ?? 0), child))
            } else {
                forEachChild(of: child, retain: true) { g, _ in
                    if IOObjectConformsTo(g, interfaceClassName) != 0 { out.append((UInt8(truncatingIfNeeded: prop(g, "bInterfaceNumber") as Int? ?? 0), g)) }
                    else { IOObjectRelease(g) }
                }
                IOObjectRelease(child)
            }
        }
        return out
    }

    // MARK: helpers

    static func prop<T>(_ s: io_service_t, _ key: String) -> T? {
        guard let v = IORegistryEntryCreateCFProperty(s, key as CFString, kCFAllocatorDefault, 0) else { return nil }
        return v.takeRetainedValue() as? T
    }

    static func className(_ s: io_service_t) -> String {
        var name = [CChar](repeating: 0, count: 128)
        IOObjectGetClass(s, &name)
        return String(cString: name)
    }

    static func forEachChild(of s: io_service_t, retain: Bool = false, _ body: (io_service_t, String) -> Void) {
        var it: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(s, kIOServicePlane, &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        while case let c = IOIteratorNext(it), c != 0 {
            body(c, className(c))
            if !retain { IOObjectRelease(c) }
        }
    }

    /// `ioreg`-style dump of the whole USB plane, for the Doctor.
    public static func rawRegistryDump() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        p.arguments = ["-p", "IOUSB", "-l", "-w0"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return "ioreg failed: \(error)" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    public static func systemProfilerDump() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPUSBDataType", "-detailLevel", "full"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return "system_profiler failed: \(error)" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }
