# FlyMac: build prompt

Paste everything below the line into a fresh Claude Code session started in `~/Documents/Workspace/flymac/`.

---

You are building **FlyMac**, a native macOS companion for DJI aircraft: a "DJI Fly for Mac" focused on (1) Quick Transfer and wired media ingest, (2) live video over USB, and (3) camera and telemetry remote functions. I am Micah. I am not an experienced coder, so **make implementation decisions yourself and do as much as possible without asking me.** Ask only when a physical action is required (plug something in, power something on, approve a permission prompt). Keep updates short and show real command output or screenshots as proof.

## Environment (this Mac)
- Apple Silicon, macOS 27, **Swift 6.3 via Command Line Tools only** (no Xcode yet), **no Homebrew**.
- Node lives at `~/.local/node-v24.19.0-darwin-arm64/bin` (add to PATH if you need it). Python 3 is available. `gh` is at `~/.local/bin/gh`, authenticated as ElMagoCT.
- Build with **SwiftPM** first. Only ask me to install Xcode when something truly needs it (camera extension, notarization, an app-bundle icon pipeline). Until then, produce a runnable `.app` bundle with a script (`tools/bundle.sh`).
- Download any third-party binary (e.g. scrcpy) as a release tarball. Tell me the filename, source and size before downloading.

## Hardware I own today
- **DJI Goggles N3**, **DJI Avata 2**, **DJI RC-N2**.
- The RC-N2 is not paired to any drone right now, so it can be enumerated over USB and its sticks and buttons read, but it will not carry video. Do not assume it works with the Avata 2. Verify pairing compatibility and tell me.
- I expect to add other DJI hardware later, so **architect for "works with everything"**: a device-profile system (see below), never hard-coded models.

## Hard rules
1. **No flight control from the Mac.** Do not implement stick, takeoff, land or RTH commands. The Mac is a monitor, camera operator and data tool. The physical RC or goggles stay the only way to fly.
2. **Do not touch** geofencing/NFZ unlocking, Remote ID, activation or account or licence checks. No circumvention of any kind.
3. Interoperability research is for my own hardware only. Protocol notes should cite public sources (dji_rev, samuelsadok/dji_protocol, o-gs/dji-firmware-tools, published security research) and my own captures.
4. Anything public or irreversible (pushing to a public repo, publishing a release, spending money) needs my explicit yes first. Local commits are fine. Create a private GitHub repo `ElMagoCT/flymac` and push each commit as it lands.

## Architecture (decide details yourself, keep this shape)
Swift package with clean layers so hardware discovery can grow without rewrites:

- `FlyCore`: device-profile registry. A profile declares USB VID/PID matches, Wi-Fi SSID patterns, capabilities (`quickTransfer`, `massStorage`, `usbVideo`, `telemetry`, `cameraControl`) and which transport speaks each. Unknown devices get a "generic" profile that only offers what could be probed, plus a one-click **Doctor report** (see below).
- `DUML`: a pure-Swift DUML packet codec (0x55 header, length, CRC8/CRC16, cmd set/id, ack type, payload) with unit tests against packets from the public docs. No hardware needed to test it.
- `USBTransport`: IOKit / IOUSBHost access with hot-plug notifications. Never hold a device exclusively without a clear reason. Handle unplug mid-stream gracefully.
- `QuickTransfer`: Network.framework client. Detect the drone's Wi-Fi hotspot, talk to the drone's HTTP API on port 80 (unauthenticated; confirm actual endpoints by probing and capture, don't guess), list media, and download in parallel with resume, checksums and progress.
- `Ingest`: shared by the wired and wireless paths. Copies into a dated library, pairs `.LRF` proxies, `.SRT` telemetry and original files, skips duplicates, and verifies size and hash.
- `Video`: VideoToolbox H.264/H.265 decode → Metal view, with a latency readout. AVAssetWriter recording.
- `Telemetry`: DUML push messages and `.SRT` parsing → a common model for a HUD and map.
- `App`: SwiftUI macOS app, dark-first, restrained and professional. It must not look vibe-coded: very little text, purposeful motion, real numbers.
- `Fixtures` + `MockDevice`: recorded or synthetic packet streams so the whole UI and pipeline run with **no hardware attached**.

## Build order (finish and verify each phase before the next)

### Phase 0: Discovery on my real hardware (write results to `docs/DISCOVERY.md`)
Do this first. Walk me through plugging things in, one at a time, and record everything.
1. Baseline `system_profiler SPUSBDataType` and `ioreg -p IOUSB -l` with nothing connected.
2. Connect the **RC-N2** by USB-C and capture: VID/PID, interfaces, endpoints, class codes, whether macOS claims it. Then try a read-only DUML handshake and log every response. Verify stick and button reading using only read-only messages.
3. Connect the **Goggles N3** by USB-C, both powered on and off, and capture the same. Note whether it exposes UVC video, mass storage, serial or a custom interface, and whether the goggles' SD card mounts.
4. Connect the **Avata 2** by USB-C. Check whether its SD card mounts as mass storage. Record the folder layout (DCIM/100MEDIA, LRF, SRT).
5. Ask me to enable Quick Transfer on the Avata 2. Join its Wi-Fi from the Mac. Record the gateway IP and probe ports with a small Swift or Python TCP scanner (no nmap is installed). Enumerate the HTTP API. Save real request and response examples as fixtures.
6. If a phone capture helps, give me exact step-by-step instructions for PCAPdroid on an Android phone. Do not ask me to root anything.
7. Finish with a feasibility table: each feature × each device = confirmed / likely / blocked, with evidence.

### Phase 1: Quick Transfer and wired ingest (first shippable version)
Media browser with thumbnails and proxy previews, select and download, parallel transfer with resume, and a library view. Includes a menu-bar item that notices the drone's Wi-Fi or a mounted card and offers to pull new files. Test against the mock and, when possible, the real Avata 2.

### Phase 2: USB live video
Only pursue what Phase 0 proved reachable. Start the stream over the discovered transport, decode, display in Metal, and show latency. Add recording to ProRes or HEVC. If the N3 or RC-N2 won't expose the FPV feed, build the **fallback ladder** instead of stalling:
1. UVC capture-card input (any HDMI source) via AVFoundation.
2. scrcpy-style mirroring of a phone or RC running Fly, wireless ADB, with a setup helper.
Present all input sources in one unified source picker.

### Phase 3: Pro monitor tools
Zebras, focus peaking, waveform, histogram, false-colour, LUT preview, framing guides and anamorphic desqueeze, all rendered in Metal with **live sliders** so I can tune them myself. Output to a virtual camera (CoreMediaIO camera extension, which will need Xcode) and to NDI/Syphon.

### Phase 4: Camera and telemetry remote
Telemetry HUD (battery, GPS, altitude, speed, signal) and a MapKit flight-path view. Camera control (photo, record, mode, exposure settings, gimbal pitch) **only where Phase 0 shows it is safe and reproducible**. Every command must be reversible or idempotent, and every write is logged.

## Cross-cutting requirements
- **Doctor tab / Doctor report:** one button that gathers USB descriptors, Wi-Fi info, probed ports, and the device-profile match into a shareable text bundle, so any new DJI product can be added later from a single report.
- **Everything optional:** every input source and every tool can be turned off entirely in Settings, and "off" means gone from the screen, not just skipped.
- Unit tests for the DUML codec, SRT parser, ingest de-duplication and the device-profile matcher. `swift test` must pass before each commit.
- `README.md` with an honest capability matrix, a `docs/PROTOCOLS.md` of everything learned (with sources and dated captures), and `CLAUDE.md` in the repo with the build, test and run commands and gotchas.
- Small commits with clear messages. Push after each.

## How to work
- Start by reading this file, then create the repo skeleton and the mock-device pipeline so the UI can run today without hardware.
- Then run Phase 0 with me interactively.
- After each phase, run the app and show me proof (screenshot or command output), then state plainly what works, what doesn't, and what you're doing next.
- Never claim something works on real hardware unless you actually saw it work on real hardware; label mock-only results as mock-only.
