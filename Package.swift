// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "FlyMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FlyMac", targets: ["FlyMac"]),
        .executable(name: "flymac-doctor", targets: ["flymac-doctor"]),
        .library(name: "FlyCore", targets: ["FlyCore"]),
        .library(name: "DUML", targets: ["DUML"]),
    ],
    targets: [
        // Pure model + device-profile registry. No hardware.
        .target(name: "FlyCore"),
        // Pure-Swift DUML codec. No hardware.
        .target(name: "DUML"),
        // Telemetry model, SRT parser, DUML push decoders.
        .target(name: "Telemetry", dependencies: ["DUML"]),
        // IOKit / IOUSBHost discovery, hot-plug, bulk I/O.
        .target(name: "USBTransport", dependencies: ["FlyCore", "DUML"],
                linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("IOUSBHost")]),
        // Wi-Fi hotspot detection, port scan, HTTP media API client, resumable downloads.
        .target(name: "QuickTransfer", dependencies: ["FlyCore"],
                linkerSettings: [.linkedFramework("CoreWLAN"), .linkedFramework("Network"), .linkedFramework("SystemConfiguration")]),
        // Library on disk: copy, pair, dedupe, verify.
        .target(name: "Ingest", dependencies: ["FlyCore", "Telemetry"]),
        // VideoToolbox decode → Metal, AVAssetWriter record, UVC capture.
        .target(name: "Video", dependencies: ["FlyCore"],
                linkerSettings: [.linkedFramework("VideoToolbox"), .linkedFramework("Metal"), .linkedFramework("MetalKit"), .linkedFramework("AVFoundation")]),
        // Recorded / synthetic packets and media for hardware-free runs.
        .target(name: "Fixtures", resources: [.copy("Resources")]),
        // Fake aircraft: HTTP media server, DUML telemetry stream, synthetic H.264 video.
        .target(name: "MockDevice", dependencies: ["FlyCore", "DUML", "Telemetry", "Fixtures", "QuickTransfer", "Video"]),
        // The SwiftUI app.
        .executableTarget(name: "FlyMac",
                          dependencies: ["FlyCore", "DUML", "USBTransport", "QuickTransfer", "Ingest", "Video", "Telemetry", "MockDevice", "Fixtures"],
                          swiftSettings: [.unsafeFlags(["-parse-as-library"])]),
        // Headless Doctor report for the terminal (same code as the Doctor tab).
        .executableTarget(name: "flymac-doctor", dependencies: ["FlyCore", "USBTransport", "QuickTransfer"]),

        .testTarget(name: "DUMLTests", dependencies: ["DUML", "Fixtures"]),
        .testTarget(name: "TelemetryTests", dependencies: ["Telemetry", "Fixtures"]),
        .testTarget(name: "IngestTests", dependencies: ["Ingest", "FlyCore"]),
        .testTarget(name: "FlyCoreTests", dependencies: ["FlyCore"]),
    ]
)
