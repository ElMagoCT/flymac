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
                if r == .live { model.live.refreshOptions(settings: model.settings) }
                if r == .live, let o = model.live.options.first { await model.live.start(o); try? await Task.sleep(nanoseconds: 2_500_000_000) }
                if r == .telemetry, let m = model.mock { model.telemetry.connect(link: m.makeDUMLLink()); try? await Task.sleep(nanoseconds: 3_000_000_000) }
                if r == .media {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    // Pull everything from the mock over HTTP so the library screenshot has content.
                    if let d = model.devices.first(where: { $0.origin == .mock }), let src = model.mediaSource(for: d), let m = model.mock {
                        model.download(m.store.files, from: src)
                        for _ in 0..<60 { try? await Task.sleep(nanoseconds: 500_000_000); if !model.downloads.isEmpty, model.downloads.allSatisfy({ if case .done = $0.state { return true }; if case .failed = $0.state { return true }; return false }) { break } }
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                capture(window, to: "\(dir)/\(name).png")
            }
            NSApp.terminate(nil)
        }
    }
    @MainActor static func findModel(_ v: NSView) -> AppModel? { ScreenshotBridge.model }
    @MainActor static func findMTK(_ v: NSView) -> NSView? {
        if String(describing: type(of: v)) == "MTKView" { return v }
        for c in v.subviews { if let m = findMTK(c) { return m } }
        return nil
    }
    @MainActor static func capture(_ w: NSWindow, to path: String) {
        guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        // CAMetalLayer content is not part of cacheDisplay; paste the latest decoded frame where the MTKView sits.
        if let mtk = findMTK(v), let cg = ScreenshotBridge.model?.live.renderer?.snapshot(), let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
            let r = mtk.convert(mtk.bounds, to: v)
            let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            let scale = min(r.width / CGFloat(cg.width), r.height / CGFloat(cg.height))
            let sz = NSSize(width: CGFloat(cg.width) * scale, height: CGFloat(cg.height) * scale)
            img.draw(in: NSRect(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2, width: sz.width, height: sz.height))
            NSGraphicsContext.restoreGraphicsState()
        }
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: path)) }
    }
}
enum ScreenshotBridge { @MainActor static var model: AppModel? }
