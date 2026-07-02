# Mac Host

The Mac host turns the same Android tablet + receiver app into a second screen
for a Mac. It shares the Android APK and the plaintext H.264-Annex-B-over-TCP
video protocol with the Windows host, but it is an earlier, **video-only** phase
of the project:

```text
macOS ScreenCaptureKit → VideoToolbox H.264 → TCP :5000 (USB via adb, or Wi-Fi)
                                                → Android MediaCodec → screen
```

## Mac vs Windows — what works where

| Capability | Windows host (v0.8.0) | Mac host |
|---|---|---|
| Video to the tablet | ✅ H.264/HEVC, TCP + UDP | ✅ H.264, TCP only |
| Auto virtual display (true extend) | ✅ bundled IddCx driver | ➖ mirror by default; extend needs a third-party virtual display (below) |
| Tablet discovery | ✅ UDP broadcast | ➖ manual `--host <ip>` (or USB adb forward) |
| Touch / S Pen → host | ✅ | ❌ (tablet is display-only) |
| Desktop audio → tablet | ✅ | ❌ |
| PIN pairing + AES-256-GCM encryption | ✅ all channels | ❌ (stream is plaintext) |
| 120 fps mode switch, HDR | ✅ | ❌ (fixed capture size, SDR) |
| Settings GUI | ✅ | ➖ CLI + a DMG launcher that automates USB |

The current receiver app (versionCode 9) stays fully compatible with the Mac
host: a plaintext TCP stream has no `EXVE` marker, so the app feeds it straight
to its Annex-B splitter and decodes. Tablet touches simply go nowhere (nothing
connects to the touch port), and the pairing box can be ignored — it tucks away
on its own once video starts.

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

## Mirror vs extended

`MacHost` captures an **existing** display — `--display 0` (the default) is
usually the built-in panel, i.e. a **mirror**. For a true extended display:

- Create a virtual display with a tool like **BetterDisplay**, set it to a
  16:10 resolution (the tablet is 2960×1848), then pass its index:
  `--display 1` (indexes follow ScreenCaptureKit's display list order; try 1, 2…).
- Or capture a second physical display if one is attached.
- A native, no-third-party virtual display (`CGVirtualDisplay`) is the next Mac
  milestone — on Windows this is what the bundled IddCx driver already does.

## Flags

```text
--host <ip>      tablet IP (or 127.0.0.1 with adb forward)   [127.0.0.1]
--port N         tablet video port                            [5000]
--fps N          capture/encode frame rate                    [60]
--width N        encoded width                                [2560]
--height N       encoded height                               [1600]
--bitrate N      H.264 bitrate, bits/sec                      [25000000]
--display N      ScreenCaptureKit display index               [0]
```

Match `--width/--height` to the captured display's **aspect ratio** or the
image gets squeezed: MacBook panels are 16:10, so the 2560×1600 default is
right; for a 16:9 external display use e.g. `--width 2560 --height 1440` (the
tablet letterboxes automatically).

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
- Video-only: no touch-back, no audio, no encryption, no discovery — those live
  in the Windows host (see [SECURITY.md](../SECURITY.md) and the README feature
  table).
- Virtual display creation requires a third-party tool for now.
- Fixed capture size; no 120 fps auto-mode-switch, no HDR.
