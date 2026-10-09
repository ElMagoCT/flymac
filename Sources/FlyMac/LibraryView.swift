import SwiftUI
import AVKit
import MapKit
import FlyCore
import Ingest
import Telemetry

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedID: String?
    @State private var groups: [LibraryGroup] = []

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Library").font(.headline)
                    Text("\(model.library.count) files · \(model.library.totalBytes.bytesString)").font(.caption).foregroundStyle(Theme.dim).monospacedDigit()
                    Spacer()
                    Button { model.revealLibrary() } label: { Image(systemName: "folder") }.controlSize(.small).help(model.library.root.path)
                }.padding(.horizontal, 16).padding(.vertical, 10)
                Divider().overlay(Theme.line)
                if groups.isEmpty {
                    EmptyState(symbol: "books.vertical", title: "Library is empty", detail: "Pull files from an aircraft or card and they show up here, grouped by capture.")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18, pinnedViews: .sectionHeaders) {
                            ForEach(days, id: \.self) { day in
                                Section {
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 10)], spacing: 10) {
                                        ForEach(groups.filter { dayString($0.date) == day }) { g in
                                            LibraryTile(group: g, selected: selectedID == g.id, root: model.library.root, showSource: multipleSources)
                                                .onTapGesture { selectedID = g.id }
                                        }
                                    }.padding(.horizontal, 16)
                                } header: {
                                    Text(day).font(.caption.weight(.semibold)).foregroundStyle(Theme.dim).padding(.horizontal, 16).padding(.vertical, 6)
                                        .frame(maxWidth: .infinity, alignment: .leading).background(Theme.bg)
                                }
                            }
                        }.padding(.vertical, 10)
                    }
                }
            }.frame(minWidth: 420)
            if let g = groups.first(where: { $0.id == selectedID }) {
                LibraryDetail(group: g).frame(minWidth: 360, idealWidth: 460)
            }
        }
        .onAppear { reload() }
        .onChange(of: model.libraryVersion) { _, _ in reload() }
    }

    var days: [String] { var seen: [String] = []; for g in groups { let d = dayString(g.date); if !seen.contains(d) { seen.append(d) } }; return seen }
    func dayString(_ d: Date?) -> String { d.map { $0.formatted(.dateTime.weekday(.wide).month(.wide).day().year()) } ?? "Undated" }
    func reload() { groups = model.library.groups() }
    /// Show which device a capture came from once more than one has been imported.
    var multipleSources: Bool { Set(groups.map(\.sourceID)).count > 1 }
}

struct LibraryTile: View {
    let group: LibraryGroup
    let selected: Bool
    let root: URL
    var showSource = false
    var primary: Ingest.LibraryItem? { group.items.first { $0.kind == .video } ?? group.items.first { $0.kind == .photo } ?? group.items.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Thumb(source: primary.map { .local(root.appendingPathComponent($0.relativePath)) })
                .aspectRatio(16/9, contentMode: .fill).frame(height: 100).clipped().clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.stem).font(.caption.weight(.medium)).monospaced()
                    if showSource { Text(group.sourceID).font(.system(size: 9)).foregroundStyle(Theme.dim).lineLimit(1) }
                }
                Spacer()
                ForEach(group.items, id: \.relativePath) { i in
                    Text((i.originalName as NSString).pathExtension.uppercased()).font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.dim)
                }
            }
        }
        .padding(7)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(selected ? Theme.accent.opacity(0.7) : Theme.line))
    }
}

struct LibraryDetail: View {
    @EnvironmentObject var model: AppModel
    let group: LibraryGroup
    @State private var player: AVPlayer?
    @State private var track: TelemetryTrack?
    @State private var scrubFrame: TelemetryFrame?
    @State private var timeObserver: Any?

    var video: Ingest.LibraryItem? { group.items.first { $0.kind == .video } }
    var proxy: Ingest.LibraryItem? { group.items.first { $0.kind == .proxy } }
    var photo: Ingest.LibraryItem? { group.items.first { $0.kind == .photo } }
    var srt: Ingest.LibraryItem? { group.items.first { $0.kind == .telemetry } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let p = player {
                    VideoPlayer(player: p).aspectRatio(16/9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    if proxy != nil { Text("Playing the LRF proxy").font(.caption2).foregroundStyle(Theme.dim) }
                } else if let ph = photo {
                    Thumb(source: .local(model.library.url(for: ph))).aspectRatio(4/3, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                }
                if let f = scrubFrame ?? track?.frames.first {
                    Panel(title: srt != nil ? "Telemetry at playhead" : "Telemetry") {
                        HStack(spacing: 18) {
                            Stat(label: "Alt", value: f.relativeAltitude.map { String(format: "%.1f", $0) } ?? "–", unit: "m")
                            Stat(label: "Speed", value: f.horizontalSpeed.map { String(format: "%.1f", $0) } ?? "–", unit: "m/s")
                            Stat(label: "ISO", value: f.iso.map(String.init) ?? "–")
                            Stat(label: "Shutter", value: f.shutter ?? "–")
                            Stat(label: "Aperture", value: f.fNumber.map { "f/\($0)" } ?? "–")
                        }
                    }
                }
                if let t = track, t.positioned.count > 1, model.settings.isOn(.flightMap) {
                    FlightMap(frames: t.positioned, cursor: scrubFrame).frame(height: 240).clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    HStack(spacing: 18) {
                        Stat(label: "Distance", value: String(format: "%.0f", t.distance), unit: "m")
                        Stat(label: "Max alt", value: t.maxAltitude.map { String(format: "%.1f", $0) } ?? "–", unit: "m")
                        Stat(label: "Max speed", value: t.maxSpeed.map { String(format: "%.1f", $0) } ?? "–", unit: "m/s")
                        Stat(label: "Frames", value: "\(t.frames.count)")
                    }
                }
                Panel(title: "Files") {
                    ForEach(group.items, id: \.relativePath) { i in
                        HStack {
                            Text(i.originalName).monospaced().font(.callout)
                            Spacer()
                            Text(i.size.bytesString).font(.caption).monospacedDigit().foregroundStyle(Theme.dim)
                            Text(String(i.sha256.prefix(10))).font(.caption2).monospaced().foregroundStyle(Theme.dim).help(i.sha256)
                            Button { NSWorkspace.shared.activateFileViewerSelecting([model.library.url(for: i)]) } label: { Image(systemName: "arrow.up.forward.square") }.buttonStyle(.plain).foregroundStyle(Theme.dim)
                        }
                    }
                }
            }.padding(16)
        }
        .task(id: group.id) { await setup() }
        .onDisappear { player?.pause() }
    }

    func setup() async {
        player?.pause(); player = nil; track = nil; scrubFrame = nil
        if let s = srt, let text = try? String(contentsOf: model.library.url(for: s), encoding: .utf8) { track = SRTParser.parse(text, source: s.originalName) }
        if let v = proxy ?? video {
            let p = AVPlayer(url: model.library.url(for: v))
            p.isMuted = true
            timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { t in
                if let track { scrubFrame = track.frame(at: CMTimeGetSeconds(t)) }
            }
            player = p
        }
    }
}

/// MapKit paths with moving cursors. One track in the library, one per
/// linked device on the Telemetry screen.
struct FlightMap: View {
    struct Track: Identifiable {
        var id: String
        var frames: [TelemetryFrame]
        var cursor: TelemetryFrame?
        var color: Color
        var emphasised = true
    }
    let tracks: [Track]

    init(tracks: [Track]) { self.tracks = tracks }
    init(frames: [TelemetryFrame], cursor: TelemetryFrame?) {
        tracks = [Track(id: "single", frames: frames, cursor: cursor, color: Theme.accent)]
    }

    var body: some View {
        Map(initialPosition: .region(region(tracks.flatMap { $0.frames.map(coord) }))) {
            ForEach(tracks) { t in
                let coords = t.frames.map(coord)
                MapPolyline(coordinates: coords).stroke(t.color.opacity(t.emphasised ? 1 : 0.55), lineWidth: t.emphasised ? 3.5 : 2)
                if let first = coords.first {
                    Annotation("", coordinate: first) {
                        Image(systemName: "house.fill").font(.system(size: 9)).foregroundStyle(.black.opacity(0.8)).padding(4).background(t.color, in: Circle())
                    }
                }
                if let c = t.cursor, c.hasPosition {
                    Annotation("", coordinate: coord(c)) {
                        Image(systemName: "location.north.fill").rotationEffect(.degrees(c.yaw ?? 0)).foregroundStyle(.black.opacity(0.85))
                            .padding(5).background(t.color, in: Circle())
                            .overlay(Circle().stroke(.white.opacity(t.emphasised ? 0.9 : 0), lineWidth: 1.5))
                    }
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControlVisibility(.hidden)
    }

    func coord(_ f: TelemetryFrame) -> CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: f.latitude!, longitude: f.longitude!) }

    func region(_ c: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard !c.isEmpty else { return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 0, longitude: 0), span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1)) }
        let lats = c.map(\.latitude), lons = c.map(\.longitude)
        let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2, longitude: (lons.min()! + lons.max()!) / 2)
        // Pad generously: live tracks keep growing after the first frame.
        let span = MKCoordinateSpan(latitudeDelta: max(0.008, (lats.max()! - lats.min()!) * 1.6), longitudeDelta: max(0.008, (lons.max()! - lons.min()!) * 1.6))
        return MKCoordinateRegion(center: center, span: span)
    }
}
