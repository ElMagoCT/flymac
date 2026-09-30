import Foundation

/// Transport-independent snapshot of a USB device. Filled by USBTransport on
/// real hardware, by MockDevice for tests, and embedded in Doctor reports.
public struct USBDeviceDescriptor: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(locationID ?? 0):\(String(vendorID, radix: 16)):\(String(productID, radix: 16)):\(serialNumber ?? "")" }

    public var vendorID: UInt16
    public var productID: UInt16
    public var vendorName: String?
    public var productName: String?
    public var serialNumber: String?
    public var deviceClass: UInt8?
    public var deviceSubClass: UInt8?
    public var deviceProtocol: UInt8?
    public var bcdDevice: UInt16?
    public var usbVersion: UInt16?
    public var speed: String?
    public var locationID: UInt32?
    /// The kernel driver that matched the *device* (e.g. AppleUSBHostCompositeDevice).
    public var claimedBy: String?
    public var interfaces: [USBInterfaceDescriptor]

    public init(vendorID: UInt16, productID: UInt16, vendorName: String? = nil, productName: String? = nil,
                serialNumber: String? = nil, deviceClass: UInt8? = nil, deviceSubClass: UInt8? = nil,
                deviceProtocol: UInt8? = nil, bcdDevice: UInt16? = nil, usbVersion: UInt16? = nil,
                speed: String? = nil, locationID: UInt32? = nil, claimedBy: String? = nil,
                interfaces: [USBInterfaceDescriptor] = []) {
        self.vendorID = vendorID; self.productID = productID; self.vendorName = vendorName
        self.productName = productName; self.serialNumber = serialNumber; self.deviceClass = deviceClass
        self.deviceSubClass = deviceSubClass; self.deviceProtocol = deviceProtocol; self.bcdDevice = bcdDevice
        self.usbVersion = usbVersion; self.speed = speed; self.locationID = locationID; self.claimedBy = claimedBy
        self.interfaces = interfaces
    }

    public var vidPid: String { String(format: "%04x:%04x", vendorID, productID) }
}

public struct USBInterfaceDescriptor: Codable, Sendable, Hashable {
    public var number: UInt8
    public var alternateSetting: UInt8
    public var interfaceClass: UInt8
    public var interfaceSubClass: UInt8
    public var interfaceProtocol: UInt8
    public var name: String?
    /// Kernel driver bound to this interface, if any (AppleUSBCDCACMData, IOUSBMassStorageInterfaceNub, …).
    public var claimedBy: String?
    public var endpoints: [USBEndpointDescriptor]

    public init(number: UInt8, alternateSetting: UInt8 = 0, interfaceClass: UInt8, interfaceSubClass: UInt8 = 0,
                interfaceProtocol: UInt8 = 0, name: String? = nil, claimedBy: String? = nil,
                endpoints: [USBEndpointDescriptor] = []) {
        self.number = number; self.alternateSetting = alternateSetting; self.interfaceClass = interfaceClass
        self.interfaceSubClass = interfaceSubClass; self.interfaceProtocol = interfaceProtocol
        self.name = name; self.claimedBy = claimedBy; self.endpoints = endpoints
    }

    public var className: String { USBClass.name(interfaceClass, sub: interfaceSubClass, proto: interfaceProtocol) }
}

public struct USBEndpointDescriptor: Codable, Sendable, Hashable {
    public enum Direction: String, Codable, Sendable { case `in`, out }
    public enum Kind: String, Codable, Sendable { case control, isochronous, bulk, interrupt }
    public var address: UInt8
    public var direction: Direction
    public var kind: Kind
    public var maxPacketSize: UInt16
    public var interval: UInt8

    public init(address: UInt8, direction: Direction, kind: Kind, maxPacketSize: UInt16, interval: UInt8 = 0) {
        self.address = address; self.direction = direction; self.kind = kind
        self.maxPacketSize = maxPacketSize; self.interval = interval
    }

    /// Endpoint number without the direction bit.
    public var number: UInt8 { address & 0x0F }
}

public enum USBClass {
    public static let vendorSpecific: UInt8 = 0xFF
    public static let massStorage: UInt8 = 0x08
    public static let video: UInt8 = 0x0E
    public static let cdcControl: UInt8 = 0x02
    public static let cdcData: UInt8 = 0x0A
    public static let hid: UInt8 = 0x03
    public static let audio: UInt8 = 0x01
    public static let imaging: UInt8 = 0x06   // PTP / MTP
    public static let miscellaneous: UInt8 = 0xEF

    public static func name(_ cls: UInt8, sub: UInt8 = 0, proto: UInt8 = 0) -> String {
        switch cls {
        case 0x00: return "Per-interface"
        case 0x01: return "Audio"
        case 0x02: return "CDC control" + (sub == 0x02 ? " (ACM)" : "")
        case 0x03: return "HID"
        case 0x06: return sub == 0x01 ? "Still image (PTP/MTP)" : "Imaging"
        case 0x07: return "Printer"
        case 0x08: return "Mass storage" + (proto == 0x50 ? " (BOT)" : proto == 0x62 ? " (UAS)" : "")
        case 0x09: return "Hub"
        case 0x0A: return "CDC data"
        case 0x0E: return sub == 0x01 ? "Video control (UVC)" : sub == 0x02 ? "Video streaming (UVC)" : "Video"
        case 0x10: return "Audio/Video"
        case 0xE0: return "Wireless controller"
        case 0xEF: return sub == 0x02 && proto == 0x01 ? "Interface association" : "Miscellaneous"
        case 0xFE: return "Application-specific"
        case 0xFF: return "Vendor-specific"
        default: return String(format: "Class 0x%02x", cls)
        }
    }
}

/// Well-known vendor IDs.
public enum USBVendor {
    public static let dji: UInt16 = 0x2CA3
}
