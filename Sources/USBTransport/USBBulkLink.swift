import Foundation
import IOKit
import IOUSBHost
import DUML
import FlyCore

/// DUML over a vendor-specific bulk interface. Opens *one interface* (the
/// smallest exclusive claim possible), reads bulk-IN continuously and writes
/// bulk-OUT on demand. Unplug ends `incoming` cleanly.
public final class USBBulkLink: DUMLLink, @unchecked Sendable {
    public let name: String
    public let incoming: AsyncStream<DUMLPacket>
    private var continuation: AsyncStream<DUMLPacket>.Continuation?
    private let interface: IOUSBHostInterface
    private let inPipe: IOUSBHostPipe
    private let outPipe: IOUSBHostPipe
    private let inMax: Int
    private var readThread: Thread?
    private var closed = false
    private let lock = NSLock()
    /// Every raw chunk read, for the Doctor when nothing parses as DUML.
    public private(set) var rawLog: [(Date, [UInt8])] = []
    public var rawLogLimit = 200

    /// kUSBHostReturnPipeStalled (a C macro, so not imported).
    static let pipeStalled: UInt32 = 0xe0005000

    public enum LinkError: Error, CustomStringConvertible {
        case noServiceForDevice, noVendorInterface, noBulkPipes, open(String)
        public var description: String {
            switch self {
            case .noServiceForDevice: return "device is no longer attached"
            case .noVendorInterface: return "no vendor-specific interface with bulk endpoints"
            case .noBulkPipes: return "interface has no bulk IN + OUT pair"
            case .open(let s): return "could not open interface: \(s)"
            }
        }
    }

    /// Pick the first vendor-specific interface with a bulk IN and OUT pair,
    /// or the interface number given.
    public init(device: USBDeviceDescriptor, interfaceNumber: UInt8? = nil) throws {
        guard let devService = USBEnumerator.service(for: device) else { throw LinkError.noServiceForDevice }
        defer { IOObjectRelease(devService) }
        let candidates = device.interfaces.filter { i in
            (interfaceNumber == nil ? i.interfaceClass == USBClass.vendorSpecific : i.number == interfaceNumber!)
            && i.endpoints.contains { $0.kind == .bulk && $0.direction == .in }
            && i.endpoints.contains { $0.kind == .bulk && $0.direction == .out }
        }
        guard let chosen = candidates.first else { throw LinkError.noVendorInterface }
        let services = USBEnumerator.interfaceServices(under: devService)
        defer { services.forEach { IOObjectRelease($0.service) } }
        guard let svc = services.first(where: { $0.number == chosen.number })?.service else { throw LinkError.noVendorInterface }

        let iface: IOUSBHostInterface
        do { iface = try IOUSBHostInterface(__ioService: svc, options: [], queue: nil, interestHandler: nil) }
        catch { throw LinkError.open(error.localizedDescription) }
        let inEP = chosen.endpoints.first { $0.kind == .bulk && $0.direction == .in }!
        let outEP = chosen.endpoints.first { $0.kind == .bulk && $0.direction == .out }!
        do {
            inPipe = try iface.copyPipe(withAddress: Int(inEP.address))
            outPipe = try iface.copyPipe(withAddress: Int(outEP.address))
        } catch { iface.destroy(); throw LinkError.noBulkPipes }
        interface = iface
        inMax = max(Int(inEP.maxPacketSize), 512) * 8
        name = "\(device.productName ?? device.vidPid) if\(chosen.number) ep\(String(format: "%02x", inEP.address))/\(String(format: "%02x", outEP.address))"
        var c: AsyncStream<DUMLPacket>.Continuation!
        incoming = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
        startReading()
    }

    private func startReading() {
        let t = Thread { [weak self] in self?.readLoop() }
        t.name = "FlyMac.USBBulkLink.read"
        readThread = t
        t.start()
    }

    private func readLoop() {
        var parser = DUMLParser()
        let buf = NSMutableData(length: inMax)!
        while !isClosed {
            var n: UInt = 0
            do {
                try inPipe.__sendIORequest(with: buf, bytesTransferred: &n, completionTimeout: 1.0)
            } catch let e as NSError {
                // Timeout is normal when the device is quiet; anything else is a dead link.
                if e.code == Int(kIOReturnTimeout) { continue }
                if e.code == Int(USBBulkLink.pipeStalled) { try? inPipe.clearStall(); continue }
                if e.code == Int(kIOReturnAborted) && isClosed { break }
                if e.code == Int(kIOReturnNotResponding) || e.code == Int(kIOReturnNoDevice) || e.code == Int(kIOReturnNotAttached) { break }
                continue
            }
            guard n > 0 else { continue }
            let bytes = [UInt8](UnsafeBufferPointer(start: buf.bytes.assumingMemoryBound(to: UInt8.self), count: Int(n)))
            lock.withLock { rawLog.append((Date(), bytes)); if rawLog.count > rawLogLimit { rawLog.removeFirst() } }
            for p in parser.feed(bytes) { continuation?.yield(p) }
        }
        continuation?.finish()
    }

    private var isClosed: Bool { lock.withLock { closed } }

    public func send(_ packet: DUMLPacket) async throws {
        let data = NSMutableData(data: packet.data)
        var n: UInt = 0
        try outPipe.__sendIORequest(with: data, bytesTransferred: &n, completionTimeout: 1.0)
    }

    public func close() {
        lock.withLock { closed = true }
        try? inPipe.__abort(with: .synchronous)
        interface.destroy()
        continuation?.finish()
    }

    deinit { close() }
}
