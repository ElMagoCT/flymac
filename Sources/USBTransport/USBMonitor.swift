import Foundation
import IOKit
import IOKit.usb
import FlyCore

/// Hot-plug watcher. Emits the current device list on start and again on every
/// attach/detach. Runs its own thread with a CFRunLoop for the IOKit
/// notification port.
public final class USBMonitor: @unchecked Sendable {
    public enum Event: Sendable {
        case attached(USBDeviceDescriptor)
        case detached(USBDeviceDescriptor)
        case snapshot([USBDeviceDescriptor])
    }

    private var port: IONotificationPortRef?
    private var addedIter: io_iterator_t = 0
    private var removedIter: io_iterator_t = 0
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private let lock = NSLock()
    private var known: [UInt64: USBDeviceDescriptor] = [:]   // io_registry_entry_id → descriptor
    private var continuation: AsyncStream<Event>.Continuation?
    public private(set) var events: AsyncStream<Event>

    public init() {
        var c: AsyncStream<Event>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
    }

    public var devices: [USBDeviceDescriptor] { lock.withLock { Array(known.values) } }

    public func start() {
        guard thread == nil else { return }
        let t = Thread { [weak self] in self?.threadMain() }
        t.name = "FlyMac.USBMonitor"
        t.qualityOfService = .utility
        thread = t
        t.start()
    }

    public func stop() {
        if let rl = runLoop { CFRunLoopStop(rl) }
        continuation?.finish()
    }

    private func threadMain() {
        runLoop = CFRunLoopGetCurrent()
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        CFRunLoopAddSource(runLoop, IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let matchingAdd = IOServiceMatching(USBEnumerator.deviceClassName)
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, matchingAdd, { ctx, iter in
            Unmanaged<USBMonitor>.fromOpaque(ctx!).takeUnretainedValue().drainAdded(iter)
        }, selfPtr, &addedIter)
        let matchingRemove = IOServiceMatching(USBEnumerator.deviceClassName)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, matchingRemove, { ctx, iter in
            Unmanaged<USBMonitor>.fromOpaque(ctx!).takeUnretainedValue().drainRemoved(iter)
        }, selfPtr, &removedIter)

        // Arm both iterators (this also enumerates what is already attached).
        drainAdded(addedIter, initial: true)
        drainRemoved(removedIter)
        continuation?.yield(.snapshot(devices))
        CFRunLoopRun()
        IONotificationPortDestroy(port)
    }

    private func drainAdded(_ iter: io_iterator_t, initial: Bool = false) {
        while case let s = IOIteratorNext(iter), s != 0 {
            defer { IOObjectRelease(s) }
            // Interfaces can take a moment to appear after the device does.
            if !initial { Thread.sleep(forTimeInterval: 0.35) }
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(s, &entryID)
            if let d = USBEnumerator.describe(service: s) {
                lock.withLock { known[entryID] = d }
                if !initial { continuation?.yield(.attached(d)) }
            }
        }
    }

    private func drainRemoved(_ iter: io_iterator_t) {
        while case let s = IOIteratorNext(iter), s != 0 {
            defer { IOObjectRelease(s) }
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(s, &entryID)
            if let d = lock.withLock({ known.removeValue(forKey: entryID) }) {
                continuation?.yield(.detached(d))
            }
        }
    }
}
