import SwiftUI
import FlyCore
import Video

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            Form {
                Section("Input sources") {
                    Text("Off means gone: the source disappears from every screen.").font(.caption).foregroundStyle(Theme.dim)
                    ForEach(AppSettings.Source.allCases) { s in
                        Toggle(isOn: Binding(get: { model.settings.isOn(s) }, set: { on in if on { model.settings.enabledSources.insert(s) } else { model.settings.enabledSources.remove(s) } })) {
                            VStack(alignment: .leading) { Text(s.title); Text(s.detail).font(.caption).foregroundStyle(Theme.dim) }
                        }.disabled(s == .phoneMirror)   // Phase 2 fallback, not built yet
                    }
                }
            }.formStyle(.grouped).tabItem { Label("Sources", systemImage: "cable.connector") }

            Form {
                Section("Tools") {
                    ForEach(AppSettings.Tool.allCases) { t in
                        Toggle(t.title, isOn: Binding(get: { model.settings.isOn(t) }, set: { on in if on { model.settings.enabledTools.insert(t) } else { model.settings.enabledTools.remove(t) } }))
                    }
                }
            }.formStyle(.grouped).tabItem { Label("Tools", systemImage: "slider.horizontal.3") }

            Form {
                Section("Library") {
                    HStack {
                        Text(model.settings.libraryPath).font(.caption).monospaced().lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose…") {
                            let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                            if p.runModal() == .OK, let u = p.url { model.settings.libraryPath = u.path; model.toast = "Library path applies after relaunch" }
                        }
                    }
                    Stepper("Parallel transfers: \(model.settings.parallelDownloads)", value: $model.settings.parallelDownloads, in: 1...8)
                    Toggle("Verify SHA-256 after every copy", isOn: $model.settings.verifyHashes)
                    Toggle("Pull LRF proxies with videos", isOn: $model.settings.pairProxies)
                    Toggle("Jump to Media when a card or hotspot appears", isOn: $model.settings.autoOfferOnDetect)
                }
                Section("Recording") {
                    Picker("Codec", selection: $model.settings.recordingCodec) {
                        ForEach(Recorder.Codec.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }
                }
            }.formStyle(.grouped).tabItem { Label("Library", systemImage: "books.vertical") }
        }
        .frame(width: 520, height: 460)
    }
}
