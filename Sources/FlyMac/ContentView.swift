import SwiftUI
import FlyCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            ZStack(alignment: .bottom) {
                Group {
                    switch model.selection ?? .devices {
                    case .devices: DevicesView()
                    case .media: MediaView()
                    case .library: LibraryView()
                    case .live: LiveView()
                    case .telemetry: TelemetryView()
                    case .doctor: DoctorView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let t = model.toast { ToastView(text: t).padding(.bottom, 16).transition(.move(edge: .bottom).combined(with: .opacity)) }
            }
            .animation(.spring(duration: 0.35), value: model.toast)
            .background(Theme.bg)
        }
        .onChange(of: model.toast) { _, new in
            guard new != nil else { return }
            Task { try? await Task.sleep(nanoseconds: 3_500_000_000); await MainActor.run { if model.toast == new { model.toast = nil } } }
        }
        .toolbar { ToolbarItem(placement: .principal) { EmptyView() } }
    }
}

struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        List(selection: $model.selection) {
            Section {
                ForEach(model.visibleRoutes, id: \.self) { r in
                    Label(r.title, systemImage: r.symbol).tag(r)
                }
            }
            Section("Connected") {
                if model.devices.isEmpty {
                    Text("Nothing yet").foregroundStyle(Theme.dim).font(.callout)
                }
                ForEach(model.devices) { d in
                    Button {
                        model.selectedDeviceID = d.id
                        if model.selection != .media && model.selection != .telemetry { model.selection = .devices }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: d.match.profile.family.symbol).frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(d.title).lineLimit(1)
                                Text(d.subtitle).font(.caption2).foregroundStyle(Theme.dim).lineLimit(1)
                            }
                            Spacer()
                            if model.selectedDeviceID == d.id { Circle().fill(Theme.accent).frame(width: 6, height: 6) }
                        }
                    }
                    .buttonStyle(.plain)
                }
                if !model.mockStatus.isEmpty {
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(model.mockStatus).font(.caption2).foregroundStyle(Theme.dim) }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.panel)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("FlyMac \(AppModel.version)").font(.caption2).foregroundStyle(Theme.dim)
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.plain).foregroundStyle(Theme.dim)
            }.padding(10)
        }
    }
}

struct ToastView: View {
    var text: String
    var body: some View {
        Text(text).font(.callout.weight(.medium))
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Theme.panelRaised, in: Capsule())
            .overlay(Capsule().stroke(Theme.line))
            .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }
}

struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FlyMac").font(.headline)
            if model.devices.isEmpty { Text("No aircraft, card or hotspot noticed.").font(.callout).foregroundStyle(Theme.dim) }
            ForEach(model.devices) { d in
                HStack {
                    Image(systemName: d.match.profile.family.symbol)
                    VStack(alignment: .leading) { Text(d.title); Text(d.subtitle).font(.caption2).foregroundStyle(Theme.dim) }
                    Spacer()
                    if d.match.profile.supports(.quickTransfer, atLeast: .unverified) || d.match.profile.supports(.massStorage, atLeast: .unverified) {
                        Button("Pull new files") {
                            model.selectedDeviceID = d.id; model.selection = .media
                            NSApp.activate(ignoringOtherApps: true)
                        }.controlSize(.small)
                    }
                }
            }
            Divider()
            if let n = model.network { Text(n.summary).font(.caption2).foregroundStyle(Theme.dim).lineLimit(2) }
            HStack {
                Button("Open FlyMac") { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first?.makeKeyAndOrderFront(nil) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }.controlSize(.small)
        }
        .padding(14).frame(width: 320)
    }
}
