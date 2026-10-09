import SwiftUI
import AppKit

@main
struct FlyMacApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    init() { }

    var body: some Scene {
        WindowGroup("FlyMac") {
            ContentView()
                .environmentObject(model)
                .onAppear { ScreenshotBridge.model = model }
                .preferredColorScheme(.dark)
                .frame(minWidth: 1040, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { CommandGroup(replacing: .newItem) {} }

        Settings {
            SettingsView().environmentObject(model).preferredColorScheme(.dark)
        }

        MenuBarExtra(isInserted: Binding(get: { model.settings.isOn(.menuBar) }, set: { _ in })) {
            MenuBarView().environmentObject(model)
        } label: {
            Image(systemName: model.devices.contains { $0.origin != .mock } ? "airplane.circle.fill" : "airplane.circle")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        if let dir = ProcessInfo.processInfo.environment["FLYMAC_SCREENSHOT_DIR"] { Screenshotter.run(dir: dir) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Debug aid: renders the main window to PNGs (one per screen) without needing
/// Screen Recording permission, then quits. Used for README shots and proof.
enum Screenshotter {
    static func run(dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            // Wait for the mock aircraft (first run renders its card, which takes a while).
            for _ in 0..<120 { if ScreenshotBridge.model?.devices.isEmpty == false { break }; try? await Task.sleep(nanoseconds: 500_000_000) }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let model = (window.contentViewController?.view ?? window.contentView).flatMap(findModel) else { NSApp.terminate(nil); return }
            window.setContentSize(NSSize(width: 1280, height: 780))
            let routes: [(AppModel.Route, String)] = [(.devices, "devices"), (.media, "media"), (.library, "library"), (.live, "live"), (.telemetry, "telemetry"), (.doctor, "doctor")]
            for (r, name) in routes {
                model.selection = r
                if r == .live {
                    model.refreshLiveOptions()
                    await model.live.showAll()
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
                if r == .telemetry {
                    for d in model.devices where d.origin == .mock && model.canLinkTelemetry(d) { model.connectTelemetry(d) }
                    model.focusedSessionID = model.devices.first(where: { $0.id != "mock" && $0.origin == .mock })?.id ?? "mock"
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                }
                if r == .media {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    // Pull everything from the mock over HTTP so the library screenshot has content.
                    if let d = model.devices.first(where: { $0.id == "mock" }), let src = model.mediaSource(for: d), let m = model.mock {
                        model.download(m.store.files, from: src, device: d)
                        for _ in 0..<60 { try? await Task.sleep(nanoseconds: 500_000_000); if !model.downloads.isEmpty, model.downloads.allSatisfy({ if case .done = $0.state { return true }; if case .failed = $0.state { return true }; return false }) { break } }
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                capture(window, to: "\(dir)/\(name).png")
                if r == .live, ProcessInfo.processInfo.environment["FLYMAC_SCREENSHOT_RECORD"] != nil {
                    model.live.recordAll(codec: "hevc")
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    await model.live.stopAllRecordings()
                    let files = model.live.tiles.map { t in t.lastRecording?.path ?? "MISSING \(t.selected?.title ?? "-") running=\(t.isRunning) err=\(t.error ?? "-")" }
                    try? files.joined(separator: "\n").write(toFile: "\(dir)/recordings.txt", atomically: true, encoding: .utf8)
                }
            }
            NSApp.terminate(nil)
        }
    }
    @MainActor static func findModel(_ v: NSView) -> AppModel? { ScreenshotBridge.model }
    @MainActor static func capture(_ w: NSWindow, to path: String) {
        guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: path)) }
    }
}
enum ScreenshotBridge {
    @MainActor static var model: AppModel?
    /// Metal layers are invisible to cacheDisplay, so in screenshot mode live
    /// tiles draw their latest frame as an ordinary image instead.
    static let stillFrames = ProcessInfo.processInfo.environment["FLYMAC_SCREENSHOT_DIR"] != nil
}
