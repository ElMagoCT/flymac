import SwiftUI
import QuickLookThumbnailing
import FlyCore
import Ingest
import QuickTransfer

/// Browse a source (Quick Transfer hotspot, mounted card, mock), pick captures,
/// pull them into the library. One grid, one queue.
struct MediaView: View {
    @EnvironmentObject var model: AppModel
    @State private var files: [RemoteMediaFile] = []
    @State private var groups: [MediaGroup] = []
    @State private var selected: Set<String> = []
    @State private var loading = false
    @State private var error: String?
    @State private var loadedFor: String?
    @State private var hideImported = false

    var device: DiscoveredDevice? { model.devices.first { $0.id == model.selectedDeviceID && model.mediaSource(for: $0) != nil } ?? model.devices.first { model.mediaSource(for: $0) != nil } }

    var body: some View {
        Group {
            if let d = device, let src = model.mediaSource(for: d) {
                HSplitView {
                    grid(d, src).frame(minWidth: 520)
                    TransferQueue().frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
                }
                .task(id: d.id) { await load(d, src) }
            } else {
                EmptyState(symbol: "photo.on.rectangle.angled", title: "No media source", detail: "Join the aircraft's Quick Transfer Wi-Fi, mount its card, or turn on the mock aircraft.")
            }
        }
    }

    func grid(_ d: DiscoveredDevice, _ src: AppModel.MediaSourceKind) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: d.match.profile.family.symbol).foregroundStyle(Theme.accent)
                Text(d.title).font(.headline)
                Text("\(groups.count) captures · \(files.reduce(0) { $0 + $1.size }.bytesString)").font(.caption).foregroundStyle(Theme.dim).monospacedDigit()
                Spacer()
                Toggle("Hide imported", isOn: $hideImported).toggleStyle(.checkbox).font(.caption)
                Button("All new") { selected = Set(visibleGroups.filter { !isImported($0) }.map(\.id)) }.controlSize(.small)
                Button("None") { selected = [] }.controlSize(.small).disabled(selected.isEmpty)
                Button { pull(src) } label: { Label(selected.isEmpty ? "Pull" : "Pull \(selected.count) · \(selectedBytes.bytesString)", systemImage: "arrow.down.to.line") }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small).disabled(selected.isEmpty)
                Button { Task { await load(d, src) } } label: { Image(systemName: "arrow.clockwise") }.controlSize(.small)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider().overlay(Theme.line)
            if loading && groups.isEmpty { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let error { EmptyState(symbol: "exclamationmark.triangle", title: "Couldn't list media", detail: error) }
            else if groups.isEmpty { EmptyState(symbol: "tray", title: "Nothing on the card") }
            else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 12)], spacing: 12) {
                        ForEach(visibleGroups) { g in
                            CaptureTile(group: g, thumbnail: thumb(g, src), imported: isImported(g), selected: selected.contains(g.id))
                                .onTapGesture { toggle(g.id) }
                        }
                    }.padding(16)
                }
            }
        }
    }

    var visibleGroups: [MediaGroup] { hideImported ? groups.filter { !isImported($0) } : groups }
    var selectedBytes: Int64 { groups.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.totalSize } }
    func isImported(_ g: MediaGroup) -> Bool { g.primary.map { model.library.looksImported(name: $0.name, size: $0.size) } ?? false }
    func toggle(_ id: String) { if selected.contains(id) { selected.remove(id) } else { selected.insert(id) } }

    func thumb(_ g: MediaGroup, _ src: AppModel.MediaSourceKind) -> ThumbSource? {
        guard let p = g.primary else { return nil }
        switch src {
        case .http(let base, let dialect): return dialect?.thumbnailURL(base: base, file: p).map { .remote($0) }
        case .folder(let root): return .local(root.appendingPathComponent((g.proxy ?? p).path))
        }
    }

    func load(_ d: DiscoveredDevice, _ src: AppModel.MediaSourceKind) async {
        loading = true; error = nil; defer { loading = false }
        do {
            switch src {
            case .http(let base, let dialect):
                guard let dialect else { error = "This device's Quick Transfer API is not known yet. Run Doctor while connected and send the report."; files = []; groups = []; return }
                files = try await dialect.listMedia(base: base)
            case .folder(let root):
                files = await Task.detached { MediaLibrary.scan(root) }.value
            }
            groups = MediaGroup.group(files)
            if loadedFor != d.id { selected = []; loadedFor = d.id }
        } catch { self.error = error.localizedDescription }
    }

    func pull(_ src: AppModel.MediaSourceKind) {
        let chosen = groups.filter { selected.contains($0.id) }.flatMap(\.files).filter { model.settings.pairProxies || $0.kind != .proxy }
        model.download(chosen, from: src)
        selected = []
    }
}

enum ThumbSource: Hashable { case remote(URL), local(URL) }

struct CaptureTile: View {
    let group: MediaGroup
    let thumbnail: ThumbSource?
    let imported: Bool
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Thumb(source: thumbnail).aspectRatio(16/9, contentMode: .fill).frame(height: 120).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                HStack(spacing: 4) {
                    if let d = group.primary?.duration { Chip(text: d.clock, color: .white) }
                    if group.kind == .photo { Chip(text: "PHOTO", color: .white) }
                }.padding(6)
                if imported {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok).padding(6).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.accent, lineWidth: 2)
                    Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.white, Theme.accent).padding(6).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            HStack {
                Text(group.stem).font(.callout.weight(.medium)).monospaced()
                Spacer()
                Text(group.totalSize.bytesString).font(.caption).foregroundStyle(Theme.dim).monospacedDigit()
            }
            HStack(spacing: 4) {
                ForEach(group.files, id: \.path) { f in
                    Text((f.name as NSString).pathExtension.uppercased()).font(.system(size: 9, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(Theme.dim)
                }
                Spacer()
                if let d = group.date { Text(d, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.caption2).foregroundStyle(Theme.dim) }
            }
        }
        .padding(8)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.line))
        .opacity(imported && !selected ? 0.55 : 1)
        .scaleEffect(selected ? 1.0 : 0.985)
        .animation(.spring(duration: 0.25), value: selected)
    }
}

/// Thumbnail from a URL (mock/Quick Transfer) or generated by QuickLook (card/library).
struct Thumb: View {
    let source: ThumbSource?
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            Theme.panelRaised
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
            else { Image(systemName: "photo").foregroundStyle(Theme.dim) }
        }
        .task(id: source) { await load() }
    }
    func load() async {
        image = nil
        switch source {
        case .remote(let u):
            if let (d, _) = try? await URLSession.shared.data(from: u) { image = NSImage(data: d) }
        case .local(let u):
            let req = QLThumbnailGenerator.Request(fileAt: u, size: CGSize(width: 480, height: 270), scale: 2, representationTypes: .thumbnail)
            if let r = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { image = r.nsImage }
        case nil: break
        }
    }
}

struct TransferQueue: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transfers").font(.headline)
                Spacer()
                let active = model.downloads.filter { $0.state == .running }
                if !active.isEmpty { Text(active.reduce(0.0) { $0 + $1.bytesPerSecond }.bytesPerSecondString).font(.caption).monospacedDigit().foregroundStyle(Theme.accent) }
                Button("Clear") { Task { await model.downloader.clearFinished() } }.controlSize(.small).disabled(model.downloads.isEmpty)
            }.padding(.horizontal, 14).padding(.vertical, 10)
            Divider().overlay(Theme.line)
            if model.downloads.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.dotted").font(.title).foregroundStyle(Theme.dim)
                    Text("Pulled files land in the library").font(.caption).foregroundStyle(Theme.dim)
                    Button("Show library") { model.selection = .library }.controlSize(.small)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.downloads) { j in JobRow(job: j) }.listStyle(.plain).scrollContentBackground(.hidden)
            }
        }
        .background(Theme.panel)
    }
}

struct JobRow: View {
    @EnvironmentObject var model: AppModel
    let job: Downloader.Job
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(job.file.name).font(.callout).monospaced().lineLimit(1)
                Spacer()
                switch job.state {
                case .queued: Chip(text: "queued")
                case .running: Text(job.bytesPerSecond.bytesPerSecondString).font(.caption2).monospacedDigit().foregroundStyle(Theme.dim)
                case .paused: Chip(text: "paused", color: Theme.warn)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                case .failed(let m): Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.bad).help(m)
                case .cancelled: Chip(text: "cancelled")
                }
            }
            ProgressView(value: job.progress).tint(job.state == .running ? Theme.accent : Theme.dim).controlSize(.small)
            HStack {
                Text("\(job.received.bytesString) / \(job.file.size.bytesString)").font(.caption2).monospacedDigit().foregroundStyle(Theme.dim)
                Spacer()
                if job.state == .running { Button("Pause") { Task { await model.downloader.pause(job.id) } }.controlSize(.mini) }
                if job.state == .paused { Button("Resume") { Task { await model.downloader.resume(job.id) } }.controlSize(.mini) }
                if job.state == .running || job.state == .queued || job.state == .paused { Button("Cancel") { Task { await model.downloader.cancel(job.id) } }.controlSize(.mini) }
                if case .failed = job.state { Button("Retry") { Task { await model.downloader.cancel(job.id); await model.downloader.clearFinished(); await model.downloader.enqueue(job.file, from: job.url) } }.controlSize(.mini) }
            }
        }.padding(.vertical, 4)
    }
}
