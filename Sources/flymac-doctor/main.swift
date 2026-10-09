import Foundation
import FlyCore
import USBTransport
import QuickTransfer

// Headless Doctor: same data as the app's Doctor tab, printed to stdout.
//   flymac-doctor            USB + network + profiles
//   flymac-doctor --scan     also port-scan the current gateway and sweep HTTP
//   flymac-doctor --watch    print USB attach/detach events until Ctrl-C
setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered so --watch logs stream to a file
let args = CommandLine.arguments.dropFirst()
let registry = ProfileRegistry.shared

if args.contains("--watch") {
    let mon = USBMonitor()
    mon.start()
    print("watching USB… (Ctrl-C to stop)")
    let task = Task {
        for await ev in mon.events {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
            switch ev {
            case .snapshot(let l): print("[\(f.string(from: Date()))] \(l.count) device(s) present"); for d in l { print(DoctorReport.describe(d, match: registry.match(usb: d))) }
            case .attached(let d): print("[\(f.string(from: Date()))] ATTACHED"); print(DoctorReport.describe(d, match: registry.match(usb: d)))
            case .detached(let d): print("[\(f.string(from: Date()))] DETACHED \(d.productName ?? d.vidPid)")
            }
        }
    }
    _ = task
    RunLoop.main.run()
}

var sections: [DoctorSection] = []
let usb = USBEnumerator.allDevices()
sections.append(DoctorSection("USB devices (\(usb.count))", usb.isEmpty ? "(none attached)" : usb.map { DoctorReport.describe($0, match: registry.match(usb: $0)) }.joined(separator: "\n")))
let net = NetworkInfo.snapshot()
sections.append(DoctorSection("Network", net.summary + "\nhotspot-like: \(NetworkInfo.looksLikeDeviceHotspot(net))"))

if args.contains("--scan"), let gw = net.gateway {
    let sem = DispatchSemaphore(value: 0)
    Task {
        let res = await PortScanner.scan(host: gw) { done, total in if done % 10 == 0 { FileHandle.standardError.write(Data("\rscanning \(gw) \(done)/\(total)".utf8)) } }
        FileHandle.standardError.write(Data("\n".utf8))
        let open = res.filter(\.open)
        sections.append(DoctorSection("Open TCP ports on \(gw)", open.isEmpty ? "(none)" : open.map { "\($0.port)  \(Int($0.latencyMs ?? 0)) ms  \($0.banner ?? "")" }.joined(separator: "\n")))
        if open.contains(where: { $0.port == 80 }), let base = URL(string: "http://\(gw)/") {
            let ex = await HTTPProbe.sweep(base: base)
            sections.append(DoctorSection("HTTP sweep", ex.map(\.summary).joined(separator: "\n")))
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
            let out = URL(fileURLWithPath: "captures/http-\(gw)-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.createDirectory(atPath: "captures", withIntermediateDirectories: true)
            if let d = try? enc.encode(ex) { try? d.write(to: out); sections.append(DoctorSection("Saved fixtures", out.path)) }
        }
        sem.signal()
    }
    sem.wait()
}
sections.append(DoctorSection("Profiles known", registry.profiles.map { "\($0.id)  \($0.displayName)" }.joined(separator: "\n")))
if args.contains("--raw") {
    sections.append(DoctorSection("ioreg -p IOUSB -l", USBEnumerator.rawRegistryDump()))
    sections.append(DoctorSection("system_profiler SPUSBDataType", USBEnumerator.systemProfilerDump()))
}
print(DoctorReport(appVersion: "flymac-doctor", sections: sections).text)
