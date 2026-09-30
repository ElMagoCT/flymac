import Foundation
import FlyCore

/// Polls the network every couple of seconds and reports when the Mac joins
/// something that looks like an aircraft hotspot (by SSID pattern when
/// readable, otherwise by gateway heuristic + a dialect answering on it).
public final class HotspotWatcher: @unchecked Sendable {
    public struct Hotspot: Sendable, Equatable {
        public var snapshot: NetworkSnapshot
        public var base: URL
        public var match: ProfileMatch?
        public var dialectID: String?
    }
    public enum Event: Sendable { case joined(Hotspot), left, snapshot(NetworkSnapshot) }

    public let events: AsyncStream<Event>
    private var continuation: AsyncStream<Event>.Continuation?
    private var task: Task<Void, Never>?
    private let registry: ProfileRegistry
    public private(set) var current: Hotspot?
    public private(set) var lastSnapshot: NetworkSnapshot?
    public var interval: TimeInterval = 2.5

    public init(registry: ProfileRegistry = .shared) {
        self.registry = registry
        var c: AsyncStream<Event>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
    }

    public func start() {
        guard task == nil else { return }
        task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled, let self {
                await self.tick()
                try? await Task.sleep(nanoseconds: UInt64(self.interval * 1e9))
            }
        }
    }

    public func stop() { task?.cancel(); task = nil; continuation?.finish() }

    private func tick() async {
        let snap = NetworkInfo.snapshot()
        let changed = snap.gateway != lastSnapshot?.gateway || snap.ssid != lastSnapshot?.ssid
        lastSnapshot = snap
        continuation?.yield(.snapshot(snap))
        guard changed else { return }
        if current != nil { current = nil; continuation?.yield(.left) }
        guard let gw = snap.gateway, let base = URL(string: "http://\(gw)/") else { return }
        let ssidMatch = snap.ssid.flatMap { registry.match(ssid: $0) }
        guard ssidMatch != nil || NetworkInfo.looksLikeDeviceHotspot(snap) else { return }
        let dialect = await DialectRegistry.detect(base: base)
        guard ssidMatch != nil || dialect != nil else { return }
        let h = Hotspot(snapshot: snap, base: base, match: ssidMatch, dialectID: dialect?.id)
        current = h
        continuation?.yield(.joined(h))
    }
}
