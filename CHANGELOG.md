# Changelog

## v0.7 — current

A complete plug-and-play extended-display system: native-resolution, 120 Hz,
HDR10, wired + wireless, touch + S Pen, on any GPU.

### Display
- Migrated from the Amyuni `usbmmidd` driver (4-port device, grey phantom
  monitors, per-launch elevation) to the **VirtualDrivers IddCx VDD** — one clean
  monitor at the tablet's **native 2960×1848 @ 120 Hz** with **HDR10**.
- Session-scoped lifecycle via the Windows **CCD topology API** (extend on
  connect, collapse on exit/crash) — no elevation at run time, no idle phantom
  display. Replaced the earlier SYSTEM-watcher/flag-file scheme entirely.
- One-click HDR: `--hdr` auto-enables Windows Advanced Color on the virtual display.

### Codecs & GPUs
- H.264 and **HEVC** (HDR = HEVC Main10, BT.2020 PQ).
- Encoder auto-ladder **NVENC → QSV → AMF → Media Foundation → x264/x265**, so
  hardware encoding works on NVIDIA, Intel, and AMD (MF covers AMD where AMF
  can't bind across the VDD's adapter). Proven config cached per machine.

### Transport
- **USB** (adb) and **Wi-Fi** (zero-config UDP-broadcast discovery, subnet-directed).
- **Auto USB→Wi-Fi**: no-flags launch uses USB if plugged, else discovers over Wi-Fi.
- Video over reliable **TCP** or low-latency **UDP** (`--udp`); custom UDP NAL
  framing with reassembly + frame-drop recovery. Touch always on reliable TCP.

### Input
- Protocol-v2 uplink: multi-touch, two-finger scroll/pinch, long-press
  right-click, and **S Pen** (pressure / hover / eraser) → real Windows
  `InjectTouchInput` + synthetic pen.

### Packaging
- `ExtendedDisplaySetup.exe` (Inno Setup) bundles the sender, ffmpeg (GPL),
  adb, the VDD driver, and the Android APK; idempotent VDD install/uninstall.
- Sender static-links the CRT — no VC++ redistributable needed.

### Hardening (from an adversarial code review)
- Fixed an atomic `g_child` handle race, Winsock leaks, an O(n²) UDP NAL
  splitter, exit-code-gated encoder caching, prompt touch-thread shutdown, and a
  crash-time display-release filter.
- Android: decode thread is sole owner of the MediaCodec (no release race);
  UDP reassembler bounds allocations and drops stale sequences; Wi-Fi
  `MulticastLock` for reliable discovery on power-save devices.

## Earlier phases (pre-0.7)
- Phase 1: FFmpeg-launcher PoC, H.264 over TCP, MediaCodec receiver.
- Mac host (ScreenCaptureKit + VideoToolbox).
- Phase 2: native DXGI + encoder ladder, plug-and-play orchestration.
- Phase 3: touch uplink → SendInput.
