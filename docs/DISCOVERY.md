# Phase 0 — Discovery on real hardware

Hardware on hand: DJI Avata 2, DJI Goggles N3, DJI RC-N2. Mac: Apple Silicon (M1), macOS 27.0 (26A428).

Method: `flymac-doctor --watch` while plugging things in, plus the app's Doctor tab. Raw output in `captures/`.

## Pairing compatibility (from DJI's published specs, before touching anything)

- **Avata 2** is an O4 FPV aircraft. DJI lists it as compatible with **Goggles 3, Goggles N3, RC Motion 3** and the **FPV Remote Controller 3**. It is **not** listed for the RC-N2, and the RC-N2's own compatibility list (Mini 4 Pro, Air 3, Mini 3 / 3 Pro, Mini 4K…) does not include Avata 2. → Expect: RC-N2 cannot be paired to the Avata 2 and will never carry its video. It can still be enumerated on its own.
- **Goggles N3** pair with the Avata 2 directly; the phone connection for live view goes through the goggles' USB-C into DJI Fly.

## 1. Baseline (nothing connected) — 2026-09-29

`captures/00-baseline-nothing-connected.txt`

- `IOUSBHostDevice` matches: **0**.
- `ioreg -p IOUSB -l`: only the root hubs.
- `system_profiler SPUSBDataType`: empty output (normal for Apple Silicon with nothing attached).
- Network: home Wi-Fi, gateway 192.168.1.1. The SSID is not readable by an app without Location permission on this macOS; FlyMac's hotspot detection therefore also requires an HTTP dialect to answer on the gateway before it calls something an aircraft.

## 2. RC-N2 over USB-C

_pending_

## 3. Goggles N3 over USB-C (powered off, then on)

### 3a. 2026-10-08 — goggles on, linked to the Avata 2, Mac-to-goggles USB-C cable

Context: the same cable and goggles give live view in DJI Fly on Micah's iPad.

Observed on the Mac (`captures/02-goggles-n3-watch.log`, `ioreg -p IOAccessory`, `system_profiler SPPowerDataType`):

- **No USB device enumerated.** `IOUSBHostDevice` count 0; `ioreg -p IOUSB` shows only the two root controllers.
- The port is live: `ConnectionActive = Yes`, `TransportsActive = ("CC","USB3","USB2")`.
- The Mac reports **external power from that port: 5000 mV, 500 mA, 3 W, "not charging"** (`AdapterDetails` Watts=3, Current=500, AdapterID 12). Default USB power is what a host/source supplies, so the **goggles took the source/host (DFP) role and the Mac became the sink/device (UFP)**.
- Nothing appears on the Mac's side because macOS has no user-space way to act as a USB device.

Interpretation (likely, not yet proven): toward a phone or tablet the goggles behave like DJI's remote controllers, acting as the **USB host** and treating the phone as the device, the way Android Open Accessory and Apple's iAP2-over-USB accessories work. That is why the iPad works and the Mac does not. Emulating the iPad's side would need the Mac to be a USB device, which a stock Mac cannot do.
Sources: Android Open Accessory protocol (source.android.com, "accessory acts as the USB host"); USB Type-C spec roles (DFP/UFP, Try.SRC).

Next: force the goggles into the *device* role by putting a hub (or USB-A host port) between them and the Mac. Hubs' downstream ports are always hosts, and that is how DJI Assistant 2 normally reaches DJI hardware from a computer.

## 4. Avata 2 over USB-C

_pending_

## 5. Avata 2 Quick Transfer Wi-Fi

_pending_

## 6. Phone capture (PCAPdroid), if needed

_pending_

## 7. Feasibility table

| Feature | Avata 2 | Goggles N3 | RC-N2 | Evidence |
|---|---|---|---|---|
| USB enumeration | | | | |
| Card as mass storage | | n/a? | n/a | |
| DUML handshake (ping/version) | | | | |
| Stick/button read | n/a | n/a | | |
| USB live video | | | | |
| Quick Transfer HTTP API | | n/a | n/a | |
| Telemetry pushes | | | | |
