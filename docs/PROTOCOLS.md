# Protocol notes

Everything FlyMac knows about how DJI hardware talks, with where it came from. Only public sources and our own captures of our own hardware. Nothing here is about circumventing anything.

## DUML v1 frame (implemented in `Sources/DUML`)

| Offset | Field | Notes |
|---|---|---|
| 0 | `0x55` | start of frame |
| 1–2 | ver/length | little-endian; bits 0–9 total frame length, bits 10–15 version (1) |
| 3 | CRC-8 | over bytes 0–2, poly 0x31 (reflected 0x8C), seed **0x77** |
| 4 | sender | bits 0–4 device type, bits 5–7 index |
| 5 | receiver | same |
| 6–7 | sequence | little-endian |
| 8 | cmd type | bit 7 response, bits 5–6 ack type (0 none, 1 before exec, 2 after exec), bits 0–2 encryption |
| 9 | cmd set | 0 general, 1 special, 2 camera, 3 flight controller, 4 gimbal, 5 center board, 6 RC, 7 Wi-Fi, 8 DM36x, 9 HD link, 10 mbino, 11 sim, 12 ESC, 13 battery, 14 data logger, 15 RTK, 16 automation |
| 10 | cmd id | |
| 11… | payload | |
| last 2 | CRC-16 | over everything before, poly 0x1021 (reflected 0x8408, KERMIT table), seed **0x3692** |

Device types (sender/receiver low 5 bits): 1 camera, 2 mobile app, 3 flight controller, 4 gimbal, 6 remote controller, 10 PC, 11 battery, 12 ESC, 31 any. Full list in `DUMLDeviceType`.

Verified without hardware: our CRC tables match the published table heads (`00 5e bc e2…`, `0000 1189 2312 329b…`), the header `55 0d 04` yields CRC-8 `0x33` as in public captures, and encode/decode agree with an independent Python implementation (`tools/duml_ref.py`, fixtures in `Sources/Fixtures/Resources/duml-reference.json`).

Sources:
- o-gs/dji-firmware-tools, `comm_dissector/` (Wireshark Lua dissectors) and `comm_mkdupc.py`
- samuelsadok/dji_protocol README
- dji_rev wiki ("DUML" pages)

### Commands FlyMac sends (read-only whitelist, `DUMLSession.allowedCommands`)

| set/id | Name | Why it is safe |
|---|---|---|
| 0x00/0x00 | ping | no side effects |
| 0x00/0x01 | get version | read |
| 0x00/0x27 | get device info | read |

### Pushes FlyMac decodes

- **flyc 0x03/0x43 OSD General** — leading fields per comm_dissector: lon/lat as doubles in radians, relative height int16 ×0.1 m, vgx/vgy/vgz int16 ×0.1 m/s, pitch/roll/yaw int16 ×0.1°. Later bytes (battery, satellite count) vary by firmware and are treated as opportunistic. **Unverified on our hardware.**
- **rc 0x06/0x05** — raw 16-bit words shown as a diff view; the stick mapping is to be established by moving sticks on the RC-N2 (Phase 0 §2).

## DJI `.SRT` telemetry sidecars (implemented in `Telemetry/SRTParser`)

Bracketed format (Mini 2 onward, Avata series): `[iso : 100] [shutter : 1/1000.0] [fnum : 280] [ev : 0] [ct : 5500] [color_md : default] [focal_len : 240] [latitude: …] [longitude: …] [rel_alt: 12.300 abs_alt: 350.100]`. `fnum` is ×100, `focal_len` is ×10. A `SrtCnt : n, DiffTime : 33ms` line and a wall-clock line precede it. Legacy `HOME(...) GPS(lon,lat,sats) BAROMETER:x` also parsed. Source: many public sample files; verified against fixtures only until a real Avata 2 SRT is captured.

## Quick Transfer (Wi-Fi)

**Not yet captured.** FlyMac has a dialect protocol (`QuickTransferDialect`); only the mock dialect exists. Phase 0 §5 will record the real gateway, open ports and HTTP exchanges as JSON fixtures in `captures/`.

## USB

See `docs/DISCOVERY.md` for descriptors as they are captured. DJI vendor ID is `0x2CA3`.
