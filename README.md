# renpho-scale

Native Swift CLI tools for capturing and decoding Bluetooth data from a **Renpho Elis 1C** smart scale on macOS — without the official app and without sending data to anyone's cloud.

## Why

I bought a Renpho Elis 1C and wanted to log my weight and body composition locally on my Mac. The official Renpho app is fine, but it phones home and stores everything on their servers. This project reverse-engineers the BLE protocol from scratch, in pure Swift with CoreBluetooth, so the data lives only where I tell it to live.

The work is split into incremental phases. Each phase produces a working artifact and the data needed to design the next phase, so we don't speculate about the protocol — we observe it.

## Status

| Phase | Tool | What it does | Status |
|-------|------|--------------|--------|
| 1.0 | `renpho-recon` | Scans BLE advertisements, dumps frames with byte-diff highlighting to reverse-engineer the ad payload | ✅ Complete |
| 1.1 | `renpho-explore` | Connects via GATT, discovers services + characteristics, subscribes to notifications, dumps everything | ✅ Complete |
| 1.2 | `renpho-scale` (TBD) | Productive client: connects, parses weight + impedance from notifications, computes body composition, logs JSONL | 🚧 Not started |
| 1.3 | — | Validate composition formulas vs official Renpho app | 🚧 Not started |

## Findings so far

- The Elis 1C **does not** emit weight or impedance in BLE advertisements — those are constant for the lifetime of the device. The advertisement only carries a fixed manufacturer-data envelope with the device MAC.
- All measurement data flows over **GATT** via a notify characteristic on a Renpho-proprietary service (`0x1A10`, char `0x2A10`). No write commands required — passive subscription is enough.
- Frame format on the notify characteristic:
  ```
  55 aa  14 00  07  FL FL  WW WW  II II  CK
  ```
  - `55 aa` = sync header
  - `14 00` = message type 0x0014 (measurement)
  - `07` = payload length
  - `FL FL` = flags (byte 0 bit 0 set when impedance is ready)
  - `WW WW` = weight, big-endian, factor `0.01 kg` (10 g resolution)
  - `II II` = impedance, big-endian, ohms (zero until flag fires)
  - `CK` = checksum (algorithm TBD in 1.2)
- Standard services exposed too: Device Information (`0x180A`), Battery (`0x180F`), and Nordic DFU (`0xFE59`) — readable values like manufacturer name (`"LeFu Scale"`), model (`"38400"`), firmware revision, battery level, and the raw MAC.

Full notes: see `docs/superpowers/notes/`.

## Project layout

```
renpho-scale/
├── Package.swift                                # 2 executable targets, no external deps
├── Resources/Info.plist                         # NSBluetoothAlwaysUsageDescription, embedded via linker flag
├── Sources/
│   ├── renpho-recon/                            # Phase 1.0 — advertisement-level recon
│   │   ├── main.swift
│   │   ├── Scanner.swift                        # BLEScanner exposing AsyncStream<AdvertisementFrame>
│   │   ├── Formatter.swift                      # ANSI byte-diff console formatter
│   │   └── Recorder.swift                       # JSONL append
│   └── renpho-explore/                          # Phase 1.1 — GATT recon
│       ├── main.swift
│       ├── Explorer.swift                       # BLEExplorer: scan, connect, discover, read, subscribe
│       └── EventLogger.swift                    # Console + JSONL + summary
└── docs/superpowers/
    ├── specs/                                   # Design docs
    ├── plans/                                   # Implementation plans (task-by-task)
    └── notes/                                   # Empirical findings from each phase
```

Both tools share the same `Resources/Info.plist`, which is embedded into each binary via SwiftPM linker `unsafeFlags`. Without this, CoreBluetooth refuses to operate on macOS Big Sur+.

## Tech stack

- Swift 5.9+
- CoreBluetooth, Foundation
- macOS 11 (Big Sur) or later
- No external dependencies

## Build

```sh
swift build
```

This produces both binaries under `.build/debug/`.

## Run

### Phase 1.0 — advertisement recon

Identify your scale among nearby BLE devices:

```sh
swift run renpho-recon --duration 30 --verbose
```

Capture all advertisements from your scale during a weighing:

```sh
swift run renpho-recon --filter "renpho" --duration 90 --verbose --out captura.jsonl
```

Renpho Elis 1C scales typically advertise as `R-A033`. The first run on a fresh Mac will trigger the macOS Bluetooth permission prompt — approve in System Settings → Privacy & Security → Bluetooth.

### Phase 1.1 — GATT recon

```sh
swift run renpho-explore --filter "R-A033" --duration 90 --verbose --out gatt.jsonl
```

Step on the scale when you see `--- Listening for notifications ---` in the output. The session captures the full GATT tree plus all notifications during your weighing, then exits when the scale auto-disconnects (~30 s after the impedance reading).

Both tools accept `--help` for full flag reference.

## Caveats

- This is a personal reverse-engineering project, not a polished product. APIs and file formats can change between phases.
- The `*.jsonl` capture files contain device-specific data (your scale's MAC, your weight, your impedance). They are excluded from version control via `.gitignore` and should stay that way.
- Renpho's protocol is not officially documented; the byte layout decoded here may differ in other Renpho models or firmware revisions.
- This project does not interact with Renpho's cloud, does not register the scale with Renpho's servers, and does not need a Renpho account.

## References

- [openScale](https://github.com/oliexdev/openScale) — open-source Android app with reverse-engineered parsers for many smart scales, including several Renpho models. Useful reference when porting body-composition formulas in Phase 1.2.
- [Apple CoreBluetooth documentation](https://developer.apple.com/documentation/corebluetooth)

## License

No license declared. If you want to use any of this, open an issue first.
