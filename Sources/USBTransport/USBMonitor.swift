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
        pollBlocked(initial: true)
        continuation?.yield(.snapshot(devices))
        // Blocked devices raise no matching notifications, so poll for them.
        // 4 Hz is enough to catch a device that only lives for a few seconds.
        let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 0.25, 0.25, 0, 0) { [weak self] _ in
            self?.pollBlocked(initial: false)
        }
        CFRunLoopAddTimer(runLoop, timer, .defaultMode)
        CFRunLoopRun()
        IONotificationPortDestroy(port)
    }

    private var blocked: [UInt64: USBDeviceDescriptor] = [:]

    private func pollBlocked(initial: Bool) {
        // Exclude only properly registered devices; blocked ones must stay visible to the walk.
        let registered = lock.withLock { Set(known.keys) }.subtracting(blocked.keys)
        let now = USBEnumerator.blockedDevices(excluding: registered)
        let nowIDs = Set(now.map(\.id))
        for (id, d) in now where blocked[id] == nil {
            blocked[id] = d
            lock.withLock { known[id] = d }
            if !initial { continuation?.yield(.attached(d)) }
        }
        for (id, d) in blocked where !nowIDs.contains(id) {
            blocked[id] = nil
            // It either vanished or macOS let it through (then it re-registers normally).
            lock.withLock { known[id] = nil }
            continuation?.yield(.detached(d))
        }
    }

    private func drainAdded(_ iter: io_iterator_t, initial: Bool = false) {
        while case let s = IOIteratorNext(iter), s != 0 {
            defer { IOObjectRelease(s) }
            // Interfaces can take a moment to appear after the device does.
            if !initial { Thread.sleep(forTimeInterval: 0.35) }
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(s, &entryID)
            if let d = USBEnumerator.describe(service: s) {
                // A device macOS just let through: it was already reported as blocked.
                let wasBlocked = blocked.removeValue(forKey: entryID) != nil
                lock.withLock { known[entryID] = d }
                if wasBlocked { continuation?.yield(.detached(d)) }
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
