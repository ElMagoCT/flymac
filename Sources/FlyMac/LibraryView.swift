import SwiftUI
import AVKit
import MapKit
import FlyCore
import Ingest
import Telemetry

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedStem: String?
    @State private var groups: [(stem: String, date: Date?, items: [Ingest.LibraryItem])] = []

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
                                        ForEach(groups.filter { dayString($0.date) == day }, id: \.stem) { g in
                                            LibraryTile(group: g, selected: selectedStem == g.stem, root: model.library.root).onTapGesture { selectedStem = g.stem }
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
            if let g = groups.first(where: { $0.stem == selectedStem }) {
                LibraryDetail(group: g).frame(minWidth: 360, idealWidth: 460)
            }
        }
        .onAppear { reload() }
        .onChange(of: model.libraryVersion) { _, _ in reload() }
    }

    var days: [String] { var seen: [String] = []; for g in groups { let d = dayString(g.date); if !seen.contains(d) { seen.append(d) } }; return seen }
    func dayString(_ d: Date?) -> String { d.map { $0.formatted(.dateTime.weekday(.wide).month(.wide).day().year()) } ?? "Undated" }
    func reload() { groups = model.library.groups() }
}

struct LibraryTile: View {
    let group: (stem: String, date: Date?, items: [Ingest.LibraryItem])
    let selected: Bool
    let root: URL
    var primary: Ingest.LibraryItem? { group.items.first { $0.kind == .video } ?? group.items.first { $0.kind == .photo } ?? group.items.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Thumb(source: primary.map { .local(root.appendingPathComponent($0.relativePath)) })
                .aspectRatio(16/9, contentMode: .fill).frame(height: 100).clipped().clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            HStack {
                Text(group.stem).font(.caption.weight(.medium)).monospaced()
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
    let group: (stem: String, date: Date?, items: [Ingest.LibraryItem])
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
        .task(id: group.stem) { await setup() }
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

/// MapKit path with a moving cursor. Shared by the library and the live HUD.
struct FlightMap: View {
    let frames: [TelemetryFrame]
    var cursor: TelemetryFrame?
    var body: some View {
        let coords = frames.map { CLLocationCoordinate2D(latitude: $0.latitude!, longitude: $0.longitude!) }
        Map(initialPosition: .region(region(coords))) {
            MapPolyline(coordinates: coords).stroke(Theme.accent, lineWidth: 3)
            if let first = coords.first { Annotation("Home", coordinate: first) { Image(systemName: "house.fill").foregroundStyle(.white).padding(4).background(Theme.ok, in: Circle()) } }
            if let c = cursor, c.hasPosition {
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: c.latitude!, longitude: c.longitude!)) {
                    Image(systemName: "location.north.fill").rotationEffect(.degrees(c.yaw ?? 0)).foregroundStyle(.white).padding(5).background(Theme.accent, in: Circle())
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControlVisibility(.hidden)
    }
    func region(_ c: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        let lats = c.map(\.latitude), lons = c.map(\.longitude)
        let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2, longitude: (lons.min()! + lons.max()!) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.002, (lats.max()! - lats.min()!) * 1.5), longitudeDelta: max(0.002, (lons.max()! - lons.min()!) * 1.5))
        return MKCoordinateRegion(center: center, span: span)
    }
}
