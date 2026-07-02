# Extended Display

Turn an Android tablet into a true **extended display** (not a mirror) for a Windows PC or Mac — at the tablet's **native resolution, 120 Hz, with HDR10**, over **USB or Wi-Fi**, with **touch and S Pen** control of the PC and optional **desktop audio**.

Built and verified on a Samsung Galaxy Tab S9 Ultra (2960×1848) + Windows 11.

## For Users — Windows

**📖 Full step-by-step guide: [INSTALL.md](INSTALL.md)** (new-device setup, manual driver steps, packaging, troubleshooting).

Quick version — from the portable ZIP (`ExtendedDisplay-0.7.2-win64.zip`) or the installer:

1. **Install the virtual display driver once:** right-click **`Install-Driver.bat`** → Run as administrator, then **reboot once**. (Or run `ExtendedDisplaySetup.exe` with the driver option ticked.)
2. On the tablet: enable Developer Options → USB debugging (USB path), or sideload `ExtendedDisplayReceiver.apk` (Wi-Fi path).
3. Double-click **`ExtendedDisplay.exe`** — the settings GUI. Pick USB/Wi-Fi, codec, HDR, touch, then **Start Streaming**. **Stop** cleanly removes the virtual display.

The GUI just drives `ExtendedDisplaySender.exe`, which you can also run directly:

```powershell
ExtendedDisplaySender.exe              # auto: USB if plugged, else Wi-Fi
ExtendedDisplaySender.exe --hdr        # HDR10 (10-bit, auto-enables Windows HDR)
ExtendedDisplaySender.exe --hevc       # H.265 (sharper at high resolution)
ExtendedDisplaySender.exe --wifi --udp # wireless, low-latency UDP video
ExtendedDisplaySender.exe --audio      # also play PC sound on the tablet
ExtendedDisplaySender.exe --audio --mute-local  # ...and mute the PC's own speakers
ExtendedDisplaySender.exe --bitrate 40000   # crisper text
```

## For Users — Mac

Build `ExtendedDisplay.dmg` on a Mac with [installers/mac/build-dmg.sh](installers/mac/build-dmg.sh), drag to Applications, plug in the tablet, launch — or run `MacHost` from the CLI over USB/Wi-Fi. The Mac host is at **feature parity** with Windows for everything macOS can express: **native extended display** (CGVirtualDisplay, 2960×1848@60 or 1920×1200@120), **touch-back with S Pen pressure**, **desktop audio** (`--audio`), **Wi-Fi discovery** (`--wifi`), **UDP video** (`--udp`), **PIN pairing + AES-256-GCM** on every channel, and **H.264/HEVC** — same Android app. Still Windows-only: real multi-touch injection and HDR (platform limits). Full guide + feature matrix: [docs/mac.md](docs/mac.md).

## Capabilities

| | |
|---|---|
| **Display** | Clean single virtual monitor at native 2960×1848, **120 Hz**, **HDR10** — via the VirtualDrivers IddCx driver. No phantom monitors, no per-launch elevation. |
| **Codecs** | H.264 + **HEVC** (HDR uses HEVC Main10). Encoder auto-ladder: NVENC → Intel QSV → AMD AMF → **Media Foundation** → x264/x265, so it works on any GPU. |
| **Transport** | **USB** (adb) and **Wi-Fi** with zero-config discovery. Video over reliable TCP or low-latency **UDP**; touch always on reliable TCP. |
| **Input** | Multi-touch, two-finger scroll/pinch, long-press right-click, and **S Pen** with pressure / hover / eraser → injected as real Windows touch + pen. |
| **Audio** | Optional **desktop audio** (PC → tablet) via WASAPI loopback → the tablet's speakers. No extra driver; encrypted with the rest of the link when paired. Optional "Mute PC speakers" makes sound play on the tablet only. |
| **Security** | Optional **PIN pairing + AES-256-GCM** on every channel (video, touch, audio) for untrusted Wi-Fi — see [SECURITY.md](SECURITY.md). |

## How It Works

```text
  ┌─ Windows host ──────────────────────────────────────────────┐
  │  VirtualDrivers VDD (IddCx) → native 2960x1848 / 120Hz / HDR │
  │     ↓ DXGI capture (ddagrab)                                 │
  │  NVENC / QSV / AMF / MF / x264·x265  (H.264 or HEVC Main10)  │
  │     ↓                                                        │
  │  TCP (tcp://tablet:5000)  or  UDP fragments (--udp)          │
  │     ↑ touch/S-Pen, always TCP 5001                           │
  │     ↓ desktop audio (WASAPI loopback), TCP 5003 (--audio)    │
  └──── discovery: UDP broadcast 5002 ; lifecycle: CCD topology ─┘
                          ↕  USB (adb) or Wi-Fi
  ┌─ Android app ───────────────────────────────────────────────┐
  │  TCP splitter + UDP reassembler → MediaCodec → SurfaceView   │
  │  touch/S-Pen uplink (protocol v2) ; AudioTrack playback      │
  │  mDNS-free discovery reply                                   │
  └─────────────────────────────────────────────────────────────┘
```

The virtual display exists **only while streaming**: the sender extends onto it via the Windows CCD topology API on connect and collapses back on exit (no elevation, no leftover monitor). See [docs/protocol.md](docs/protocol.md) for wire formats.

## Project Layout

```text
windows-sender/     C++ host: display discovery, VDD topology, USB/Wi-Fi
                    transport, encoder ladder, ffmpeg supervision, touch inject
windows-sender/launcher/  C# WinForms settings GUI (ExtendedDisplay.exe)
android-receiver/   Kotlin app: MediaCodec decode, TCP/UDP receive, touch uplink
mac-host/           macOS host (ScreenCaptureKit + VideoToolbox)
installers/windows/ Inno Setup installer + payload/VDD-install scripts
installers/mac/     .app bundle + .dmg build script
docs/               protocol, build, extended-display, mac notes
```

## Developer Builds

See [docs/build.md](docs/build.md) for building each component and the full CLI, and [installers/windows/README.md](installers/windows/README.md) for producing the installer.

## Troubleshooting

- **Waiting for a tablet forever** — USB: charge-only cable or USB-debugging off/unauthorized. Wi-Fi: tablet not on the same LAN, or the app isn't open.
- **"No extended display available" (exit 2)** — re-run the installer with the driver option ticked; see [docs/extended-display.md](docs/extended-display.md).
- **"falling back to..."** — normal; the encoder ladder is finding what your GPU supports.
- **Soft/blurry text** — raise `--bitrate` (default 25000).
- **Washed out / over-bright** — the SDR path auto-disables Windows HDR on the virtual display for correct colours; only pass `--hdr` for real HDR content.
- **Touch does nothing** — use the bundled app (v8+); tap directly on windows/icons on the tablet (touch ≠ mouse cursor).
- **ddagrab errors** — needs Windows 10 1903+ and a full GPL FFmpeg (the installer bundles one).

## Roadmap (not yet built)

- QR-scan pairing (today you type the 8-char code; the encryption itself shipped in v0.8.0 — see [SECURITY.md](SECURITY.md)).
- UDP loss resilience: FEC + on-demand keyframes + RTT-adaptive bitrate (needs a receiver→sender feedback channel; deliberately deferred — see [Fixes.md](Fixes.md)).
- Mac: v0.9.0 reached working parity — virtual display, touch-back + S Pen pressure, discovery, pairing/AES-256-GCM, desktop audio, UDP, 120 fps, HEVC. Still open: real multi-touch injection and HDR (macOS platform limits), full eraser semantics, a native settings GUI (see [docs/mac.md](docs/mac.md)).
