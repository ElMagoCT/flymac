# FlyMac — notes for Claude

Read `BUILD-PROMPT.md` for the brief and hard rules. Short version: **never** add flight control (sticks, takeoff, land, RTH), never touch NFZ/Remote ID/activation/account checks, never claim something works on hardware unless it was seen working on hardware. Label mock-only results as mock-only.

## Build / test / run (Command Line Tools only, no Xcode)

```bash
swift build --product FlyMac          # debug binary
tools/bundle.sh [debug|release]       # → build/FlyMac.app (default release)
tools/test.sh                         # swift test — REQUIRED before every commit
swift run flymac-doctor [--scan|--watch|--raw]
FLYMAC_SCREENSHOT_DIR=/tmp/shots build/FlyMac.app/Contents/MacOS/FlyMac   # self-screenshots each screen, then quits
# extra env for that run: FLYMAC_MOCK_GOGGLES=3 (simulated goggles, not saved to settings),
# FLYMAC_SCREENSHOT_RECORD=1 (Record all for 3 s, writes recordings.txt; files land in ~/Movies/FlyMac Recordings — trash them after)
```

## Gotchas

- **XCTest is not in CLT.** Tests use Swift Testing (`import Testing`). `tools/test.sh` adds the `-F`/`-rpath` flags for `/Library/Developer/CommandLineTools/Library/Developer/Frameworks` and `…/usr/lib` (lib_TestingInterop.dylib); plain `swift test` fails to find the module.
- Package uses tools-version 5.10 → Swift 5 language mode on purpose (strict concurrency stays warnings). `FlyMac` target needs `-parse-as-library` for `@main`.
- IOUSBHost refined-for-Swift names: `__sendIORequest(with:bytesTransferred:completionTimeout:)`, `__abort(with:)`. `kUSBHostReturnPipeStalled` is a macro → hard-coded `0xe0005000`.
- `LibraryItem` clashes with SwiftUI's type inside the app target: write `Ingest.LibraryItem`.
- `Bundle.module` in the .app: resource bundles must be copied to `Contents/Resources` (bundle.sh does this).
- `CWWiFiClient.ssid()` returns nil without Location permission. Hotspot detection falls back to gateway heuristic + dialect probe; never rely on SSID alone.
- `system_profiler SPUSBDataType` prints **nothing** on this Mac with no devices attached (Apple Silicon); that is the baseline, not a bug. `ioreg -p IOUSB` shows only root hubs.
- Metal layers don't appear in `cacheDisplay` captures; see "Multiple devices" below for how screenshot mode works around it.
- The mock card is rendered once into `~/Library/Application Support/FlyMac/mock-card` (~45 MB, ~20 s first run). Delete the folder to regenerate.
- Sandboxed Bash in Claude Code can't see USB or run system_profiler usefully; use the app or `flymac-doctor` from a normal shell, or `dangerouslyDisableSandbox`.

## Multiple devices

- Identity is `DiscoveredDevice.stableKey` (USB serial, else VID:PID@port). Names/numbers/colours come from `DeviceRoster` (FlyCore, unit-tested); nicknames live in `settings.deviceNicknames` keyed by stableKey. Never key per-device state by profile id.
- Per-device state: `AppModel.sessions[deviceID]` (telemetry), `LiveWall.tiles` (≤4, one source per tile; assigning a source already on screen moves it), download jobs keyed `sourceKey|path` with one staging folder per source, library groups keyed `source|day|stem`.
- USB detach must only tear down that device's session/tile.
- Screenshot mode swaps MTKView for a still-image view (`ScreenshotBridge.stillFrames`) and counts frames on submit, because Metal layers are invisible to `cacheDisplay`.
- `AppSettings` has a hand-written tolerant decoder: add new fields there with a default, or old settings files reset to defaults.

## Repo conventions

- Public GitHub: `ElMagoCT/flymac`, branch `main`. Small commits, push after each. Commits end with the Co-Authored-By line for the model doing the work.
- Every hardware finding goes in `docs/DISCOVERY.md` (dated) and, once understood, `docs/PROTOCOLS.md` with sources. Raw captures in `captures/` (text/JSON; pcaps are gitignored).
- Profiles: `BuiltInProfiles` in `Sources/FlyCore/ProfileRegistry.swift`. Fill PIDs from real descriptors only.
- DUML commands FlyMac may send are whitelisted in `DUMLSession.allowedCommands`. Adding one needs a Phase 0 finding that it is read-only or idempotent.
