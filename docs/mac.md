# Mac Host

The Mac host turns the same Android tablet + receiver app into a true
**extended display** for a Mac. It shares the Android APK and the
H.264-Annex-B-over-TCP video protocol with the Windows host:

```text
native virtual display (CGVirtualDisplay, 2960x1848@60 HiDPI)
  → ScreenCaptureKit → VideoToolbox H.264 → TCP :5000 (USB via adb, or Wi-Fi)
  → Android MediaCodec → screen
```

## Mac vs Windows — what works where

| Capability | Windows host (v0.8.0) | Mac host |
|---|---|---|
| Video to the tablet | ✅ H.264/HEVC, TCP + UDP | ✅ H.264, TCP only |
| Auto virtual display (true extend) | ✅ bundled IddCx driver | ✅ native CGVirtualDisplay, 2960x1848@60 HiDPI (default) |
| Tablet discovery | ✅ UDP broadcast | ➖ manual `--host <ip>` (or USB adb forward) |
| Touch / S Pen → host | ✅ multi-touch + pen | ✅ single-pointer mouse (stylus rides the mouse path) |
| Desktop audio → tablet | ✅ | ❌ |
| PIN pairing + AES-256-GCM encryption | ✅ all channels | ❌ (stream is plaintext) |
| 120 fps mode switch, HDR | ✅ | ❌ (fixed capture size, SDR) |
| Settings GUI | ✅ | ➖ CLI + a DMG launcher that automates USB |

The current receiver app (versionCode 9) stays fully compatible with the Mac
host: a plaintext TCP stream has no `EXVE` marker, so the app feeds it straight
to its Annex-B splitter and decodes. Tablet touches now drive the Mac cursor
(the host connects to the tablet's touch port), and the pairing box can be
ignored — it tucks away on its own once video starts.

## Requirements

- macOS **13 (Ventura) or newer** (ScreenCaptureKit; `Package.swift` targets
  `.v13`). Verified on macOS 26 (Apple silicon).
- Xcode Command Line Tools (`xcode-select --install`) for `swift build`.
- The receiver app on the tablet — sideload `ExtendedDisplayReceiver.apk`, or
  let the DMG launcher install it over USB (needs USB debugging enabled).
- **Screen Recording permission**: macOS prompts on first capture
  (System Settings → Privacy & Security → Screen Recording). Until granted,
  capture fails with a TCC error (`SCStreamErrorDomain -3801`) or delivers
  black frames.
- **Accessibility permission** (for touch-back): macOS prompts on first launch
  with touch enabled (System Settings → Privacy & Security → Accessibility).
  Until granted, `CGEvent` injection silently no-ops — tablet touches won't
  move the cursor. Grant the app that launches MacHost, then relaunch.
- **Local Network permission** (Wi-Fi only, macOS 15+): the first LAN connect
  prompts; if it was dismissed, toggle the app that launches MacHost (Terminal,
  ExtendedDisplay.app, …) under System Settings → Privacy & Security → Local
  Network. Until granted, LAN connects fail with *No route to host* — MacHost
  keeps retrying every 2 s, so granting it mid-run recovers on its own. USB
  (127.0.0.1) is exempt.

## Quick start — packaged (.dmg, USB automated)

On a Mac, from the repo root:

```bash
./installers/mac/build-dmg.sh          # optionally: path to the receiver APK
```

This builds `MacHost` (release), wraps it into `ExtendedDisplay.app` with a
launcher that automates the USB path (waits for the tablet on adb, installs the
bundled APK if missing, runs `adb forward tcp:5000 tcp:5000`, starts the
receiver activity, then runs `MacHost --host 127.0.0.1`), bundles darwin
platform-tools, ad-hoc signs the bundle, and emits
`installers/mac/dist/ExtendedDisplay.dmg`.

First run: right-click → **Open** (ad-hoc signature), grant Screen Recording.
The launcher logs to `~/Library/Logs/ExtendedDisplay.log`.

> Verified end-to-end on macOS 26 (Apple silicon): build → mount → launcher →
> adb forward → streaming, receiver v9.

## Quick start — manual build / run

```bash
cd mac-host
swift build -c release
```

**USB** (tablet plugged in, USB debugging on, receiver app installed):

```bash
adb forward tcp:5000 tcp:5000
adb shell am start -n com.heysnap.extdisplay/.MainActivity
.build/release/MacHost --host 127.0.0.1 --port 5000
```

**Wi-Fi** (no adb needed): open the app on the tablet — its status line shows
the tablet's IP (`Ready • Wi-Fi 192.168.x.x`), then:

```bash
.build/release/MacHost --host 192.168.x.x --port 5000
```

Both machines must be on the same network; guest/AP-isolated Wi-Fi blocks this.

## Extended by default (mirror on request)

By default `MacHost` creates a **native virtual display** — no BetterDisplay,
no dummy plug — sized to the tablet's panel: 2960×1848@60, HiDPI (UI renders
at 1480×924@2x, the framebuffer stays at native tablet pixels), positioned to
the right of the built-in display, and captures *that*. Drag windows off the
right edge of your Mac and they appear on the tablet.

- `--display N` skips the virtual display and captures an existing display by
  ScreenCaptureKit index instead — `--display 0` is the built-in panel, i.e. a
  **mirror**.
- Virtual-display lifecycle (macOS can't remove a virtual display on demand):
  while streaming it sits right of the main display; on stop MacHost **parks**
  it corner-adjacent (no shared edge, so the cursor can't wander into it) and
  **reuses** it on the next run. Logging out removes it for real, and
  `MacHost --remove-display` is the explicit escape hatch (note: it restores
  the saved display configuration, which also clears other apps' session
  virtual displays).

## Flags

```text
--host <ip>       tablet IP (or 127.0.0.1 with adb forward)   [127.0.0.1]
--port N          tablet video port                            [5000]
--fps N           capture/encode frame rate                    [60]
--width N         encoded width                                [0 = native]
--height N        encoded height                               [0 = native]
--bitrate N       H.264 bitrate, bits/sec                      [25000000]
--display N       capture existing SCK display N (mirror)      [off = virtual]
--remove-display  clear session virtual displays and exit
```

`--width/--height` default to the captured display's native pixel size (the
virtual display is 16:10 like the tablet, so nothing to match). When capturing
a 16:9 display with `--display N`, pass e.g. `--width 2560 --height 1440` to
keep the aspect ratio — the tablet letterboxes automatically.

## Troubleshooting

- **Black video on the tablet** → Screen Recording permission not granted;
  grant it and relaunch MacHost.
- **`Could not connect … — No route to host` over Wi-Fi** → macOS Local
  Network permission (see Requirements). MacHost retries every 2 s and
  recovers as soon as it's granted.
- **`Could not connect to <ip>:5000`** → app not open on the tablet, wrong IP,
  or different network. Over USB: re-run `adb forward tcp:5000 tcp:5000`.
  MacHost keeps retrying every 2 s until the listener appears.
- **"Streaming." but the tablet stays on "Waiting…" (USB)** → the adb forward
  isn't in place, and macOS's **AirPlay Receiver** (Control Center) also
  listens on port 5000 — so MacHost's connect *succeeds* against the wrong
  listener and streams into it. Re-run `adb forward tcp:5000 tcp:5000` (the
  forward's specific 127.0.0.1 bind takes precedence over AirPlay's wildcard
  bind, so both can coexist).
- **App stays on "Waiting…"** → MacHost isn't reaching the tablet — verify with
  `nc -vz <tablet-ip> 5000`.
- **Choppy / lagging** → lower `--fps` (30) or `--bitrate`; the TCP write runs
  on the encoder callback thread, so severe Wi-Fi backpressure stalls encoding
  (harmless over USB).
- **Tablet touches do nothing** → expected; touch injection is Windows-only.

## Limitations (honest)

- H.264 only (HEVC needs codec negotiation the Mac phase never grew).
- Touch is single-pointer mouse (no real multi-touch or pen pressure yet); no
  audio, no encryption, no discovery — those live in the Windows host (see
  [SECURITY.md](../SECURITY.md) and the README feature table).
- The idle virtual display persists (parked) until logout or
  `--remove-display` — macOS offers no per-display removal (verified: object
  release, process death and empty-mode applySettings can all leave it online).
- Fixed capture size; no 120 fps auto-mode-switch, no HDR.
