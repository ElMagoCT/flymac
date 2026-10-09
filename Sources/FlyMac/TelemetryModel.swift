import Foundation
import SwiftUI
import FlyCore
import DUML
import Telemetry
import USBTransport
import MockDevice

/// Live DUML connection to one device: read-only handshake, telemetry pushes,
/// RC channel diff. Everything sent is whitelisted and logged by DUMLSession.
@MainActor
final class TelemetryModel: ObservableObject {
    let deviceID: String
    init(deviceID: String) { self.deviceID = deviceID }
    @Published var linkName: String?
    @Published var status: String = "Not connected"
    @Published var latest: TelemetryFrame?
    @Published var track: [TelemetryFrame] = []
    @Published var handshake: [String] = []
    @Published var log: [DUMLSession.LogEntry] = []
    @Published var rcWords: [Int16] = []
    @Published var rcChanged: Set<Int> = []
    @Published var pushCounts: [String: Int] = [:]
    private var session: DUMLSession?
    private var lastRC: RCChannelSnapshot?
    private var startTime = Date()
    private var index = 0
    private var pollTask: Task<Void, Never>?

    var isConnected: Bool { session != nil }

    func connect(link: DUMLLink) {
        disconnect(reason: nil)
        let s = DUMLSession(link: link)
        session = s
        linkName = link.name
        status = "Connected, read-only"
        track = []; latest = nil; index = 0; startTime = Date(); pushCounts = [:]
        Task {
            await s.start()
            _ = await s.onPush { [weak self] p in Task { @MainActor in self?.handle(push: p) } }
            let results = await s.handshake()
            var lines: [String] = []
            for r in results {
                switch r.result {
                case .success(let p): lines.append("\(r.target) \(r.command): \(Hex.string(p.payload))  \(VersionResponse.describe(p.payload))")
                case .failure(let e): lines.append("\(r.target) \(r.command): \(e)")
                }
            }
            await MainActor.run { self.handshake = lines }
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, let s = self.session else { return }
                let l = await s.log
                await MainActor.run { self.log = Array(l.suffix(300)) }
            }
        }
    }

    func disconnect(reason: String?) {
        pollTask?.cancel(); pollTask = nil
        if let s = session { Task { await s.stop() } }
        session = nil
        linkName = nil
        if let reason { status = "Disconnected (\(reason))" }
    }

    private func handle(push p: DUMLPacket) {
        let key = String(format: "%@ %02x/%02x", "\(p.sender)", p.commandSet, p.commandID)
        pushCounts[key, default: 0] += 1
        let t = Date().timeIntervalSince(startTime)
        if let f = DUMLTelemetry.decode(p, index: index, time: t) {
            index += 1
            latest = f
            track.append(f)
            if track.count > 3600 { track.removeFirst(track.count - 3600) }
        } else if p.commandSet == 6 {
            let snap = RCChannelSnapshot(payload: p.payload)
            if let last = lastRC { rcChanged = Set(snap.changedWords(from: last)) }
            lastRC = snap
            rcWords = snap.words
        }
    }
}
