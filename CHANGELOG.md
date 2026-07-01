# Changelog

## v0.7.2 — current

Reliability fixes from continued field testing.

- **Touch survives reconnects.** The receiver's touch server held one connection
  and only noticed it was dead when it next tried to *write* — so after a Wi-Fi
  blip or sender restart, the first reconnect silently lost touch until a tap
  failed. Rewrote it "newest-connection-wins": a dedicated accept loop takes the
  reconnecting host immediately and supersedes the stale socket. Receiver v9.
- **Stop no longer risks real monitors.** Releasing the virtual display used
  `SDC_TOPOLOGY_INTERNAL`, which forces the laptop panel and would drop a real
  external monitor. The sender now deactivates *only* the VDD's CCD path
  (`SDC_USE_SUPPLIED_DISPLAY_CONFIG`), and the GUI does a device-only disable —
  both leave real monitors untouched. Non-elevated, so the CLI path works too.
- **HDR marked experimental.** Capturing the (mostly SDR) Windows desktop with
  HDR on reads as over-bright on the tablet — inherent to SDR-in-HDR, not a
  pipeline bug. SDR stays the default and is the recommended mode; `--hdr` /
  the GUI HDR option are labelled experimental (useful only for HDR video).

## v0.7.1

Field-testing fixes on real hardware (Galaxy Tab S9 Ultra, wired USB).

- **Touch fixed.** The Android receiver captured touches with a
  `SurfaceView.setOnTouchListener`, which never fired (verified: even OS-injected
  taps produced zero uplink packets). Moved capture to the Activity's
  `dispatchTouchEvent`, which sees every touch before any child view. Receiver is
  now **versionCode 8**; sender requires ≥ 8.
- **HDR washout fixed.** Capturing an SDR stream while Windows HDR was enabled on
  the virtual display looked washed-out / over-bright. The SDR path now explicitly
  turns Windows Advanced Color **off** on the VDD at start (`setAdvancedColor`),
  and `--hdr` turns it on — so colours are correct in both modes regardless of the
  display's prior HDR state.
- Receiver hardened against duplicate/relaunched instances: `launchMode=singleTask`
  plus a broader `configChanges` set (a second instance used to steal the touch
  port from the foreground one).
- Added **`windows-sender/launcher/`** — a compiled WinForms settings GUI
  (`ExtendedDisplay.exe`, elevation-manifested) to pick connection/codec/HDR/touch
  options and start/stop streaming; disables the VDD device on stop so no ghost
  monitor lingers. On open it also **auto-clears any leftover virtual display**
  from a prior crash/force-kill (device-only disable, so real monitors are
  untouched).

## v0.7

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
