# FlyMac — notes for Claude

Read `BUILD-PROMPT.md` for the brief and hard rules. Short version: **never** add flight control (sticks, takeoff, land, RTH), never touch NFZ/Remote ID/activation/account checks, never claim something works on hardware unless it was seen working on hardware. Label mock-only results as mock-only.

## Build / test / run (Command Line Tools only, no Xcode)

```bash
swift build --product FlyMac          # debug binary
tools/bundle.sh [debug|release]       # → build/FlyMac.app (default release)
tools/test.sh                         # swift test — REQUIRED before every commit
swift run flymac-doctor [--scan|--watch|--raw]
FLYMAC_SCREENSHOT_DIR=/tmp/shots build/FlyMac.app/Contents/MacOS/FlyMac   # self-screenshots each screen, then quits
```

## Gotchas

- **XCTest is not in CLT.** Tests use Swift Testing (`import Testing`). `tools/test.sh` adds the `-F`/`-rpath` flags for `/Library/Developer/CommandLineTools/Library/Developer/Frameworks` and `…/usr/lib` (lib_TestingInterop.dylib); plain `swift test` fails to find the module.
- Package uses tools-version 5.10 → Swift 5 language mode on purpose (strict concurrency stays warnings). `FlyMac` target needs `-parse-as-library` for `@main`.
- IOUSBHost refined-for-Swift names: `__sendIORequest(with:bytesTransferred:completionTimeout:)`, `__abort(with:)`. `kUSBHostReturnPipeStalled` is a macro → hard-coded `0xe0005000`.
- `LibraryItem` clashes with SwiftUI's type inside the app target: write `Ingest.LibraryItem`.
- `Bundle.module` in the .app: resource bundles must be copied to `Contents/Resources` (bundle.sh does this).
- `CWWiFiClient.ssid()` returns nil without Location permission. Hotspot detection falls back to gateway heuristic + dialect probe; never rely on SSID alone.
- `system_profiler SPUSBDataType` prints **nothing** on this Mac with no devices attached (Apple Silicon); that is the baseline, not a bug. `ioreg -p IOUSB` shows only root hubs.
- Metal layers don't appear in `cacheDisplay` captures; the screenshotter composites `renderer.snapshot()` over the MTKView rect.
- The mock card is rendered once into `~/Library/Application Support/FlyMac/mock-card` (~45 MB, ~20 s first run). Delete the folder to regenerate.
- Sandboxed Bash in Claude Code can't see USB or run system_profiler usefully; use the app or `flymac-doctor` from a normal shell, or `dangerouslyDisableSandbox`.

## Repo conventions

- Public GitHub: `ElMagoCT/flymac`, branch `main`. Small commits, push after each. Commits end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Every hardware finding goes in `docs/DISCOVERY.md` (dated) and, once understood, `docs/PROTOCOLS.md` with sources. Raw captures in `captures/` (text/JSON; pcaps are gitignored).
- Profiles: `BuiltInProfiles` in `Sources/FlyCore/ProfileRegistry.swift`. Fill PIDs from real descriptors only.
- DUML commands FlyMac may send are whitelisted in `DUMLSession.allowedCommands`. Adding one needs a Phase 0 finding that it is read-only or idempotent.
