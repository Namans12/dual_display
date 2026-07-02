# Mac Host

The Mac host turns the same Android tablet + receiver app into a true
**extended display** for a Mac. It shares the Android APK and the
Annex-B-over-TCP video protocol with the Windows host:

```text
native virtual display (CGVirtualDisplay, 2960x1848@60 HiDPI)
  → ScreenCaptureKit → VideoToolbox H.264/HEVC → TCP :5000 (USB via adb, or Wi-Fi)
  → Android MediaCodec → screen
```

Video (TCP + UDP, H.264 + HEVC, up to 120 fps), a native extended display,
tablet-touch control with S Pen pressure, desktop audio, LAN discovery, and
PIN pairing with AES-256-GCM encryption all work. Remaining Windows-only:
real multi-touch injection and HDR (see the matrix and Limitations).

## Mac vs Windows — what works where

| Capability | Windows host (v0.8.0) | Mac host |
|---|---|---|
| Video to the tablet | ✅ H.264/HEVC, TCP + UDP | ✅ H.264 + HEVC, TCP + UDP |
| Auto virtual display (true extend) | ✅ bundled IddCx driver | ✅ native CGVirtualDisplay, 2960x1848@60 HiDPI (default) |
| Tablet discovery | ✅ UDP broadcast | ✅ `--wifi` (UDP broadcast), or `--host <ip>` |
| Touch / S Pen → host | ✅ multi-touch + pen | ✅ single-pointer mouse + S Pen pressure (tablet-point events) |
| Desktop audio → tablet | ✅ WASAPI loopback | ✅ ScreenCaptureKit system audio (`--audio`) |
| PIN pairing + AES-256-GCM encryption | ✅ all channels | ✅ video + touch (audio n/a) |
| 120 fps mode switch | ✅ 1920x1200@120 | ✅ 1920x1200@120 (`--fps 120`) |
| HDR | ✅ HDR10 via VDD | ❌ (virtual display is SDR — see Limitations) |
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
adb forward tcp:5001 tcp:5001              # touch uplink (tablet → Mac input)
adb shell am start -n com.heysnap.extdisplay/.MainActivity
.build/release/MacHost --host 127.0.0.1 --port 5000
```

**Wi-Fi** (no adb needed): open the app on the tablet, then let MacHost find it
on the LAN:

```bash
.build/release/MacHost --wifi
```

Or connect to a specific IP (the tablet's status line shows it —
`Ready • Wi-Fi 192.168.x.x`): `MacHost --host 192.168.x.x`.

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
- `--fps 120` creates the virtual display at **1920×1200@120** instead — the
  same trade the Windows host makes: native-res 120 overruns the
  capture/encode/decode pipeline, and the tablet upscales 16:10 cleanly.
- Virtual-display lifecycle: the display exists only while MacHost runs and is
  **removed when it exits** (WindowServer reclaims a virtual display when its
  owner exits — verified for both quit and kill). A fast restart that finds the
  previous instance still online adopts it instead of making a duplicate.
  `MacHost --remove-display` is a rarely-needed safety valve (it restores the
  saved display configuration, which also clears other apps' session virtual
  displays).

## Flags

```text
--host <ip>       tablet IP (or 127.0.0.1 with adb forward)   [127.0.0.1]
--port N          tablet video port                            [5000]
--fps N           capture/encode frame rate                    [60]
--width N         encoded width                                [0 = native]
--height N        encoded height                               [0 = native]
--bitrate N       H.264 bitrate, bits/sec                      [25000000]
--display N       capture existing SCK display N (mirror)      [off = virtual]
--hevc            encode HEVC/H.265 instead of H.264 (sharper at high res)
--wifi            discover the tablet on the LAN (UDP :5002), then TCP
--udp             low-latency UDP video (needs --wifi or --host; not USB)
--no-touch        disable tablet touch → Mac cursor injection
--audio           stream Mac audio to the tablet (see below)
--mute-local      with --audio: mute the Mac's own speakers
--audio-delay-ms  tablet audio buffer for A/V sync            [40]
--remove-display  clear session virtual displays and exit
--selftest        run protocol self-tests and exit
```

`--width/--height` default to the captured display's native pixel size (the
virtual display is 16:10 like the tablet, so nothing to match). When capturing
a 16:9 display with `--display N`, pass e.g. `--width 2560 --height 1440` to
keep the aspect ratio — the tablet letterboxes automatically.

## Desktop audio (optional)

`--audio` streams whatever the Mac is playing to the tablet's speakers —
ScreenCaptureKit captures the system mix (the same Screen Recording permission
covers it), converted to 16-bit stereo and sent on its own channel (TCP 5003;
adb-forwarded over USB). When paired, audio frames are AES-GCM-sealed like
everything else, and the tablet stays silent until the code is entered.

- `--mute-local` silences the Mac's own speakers while streaming (re-asserted
  if volume keys un-mute; restored on stop, self-healing if force-killed).
- `--audio-delay-ms N` (default 40) sizes the tablet's audio buffer — raise it
  if audio leads the video.
- Audio and video are separate streams with no shared clock; lip-sync is
  approximate (same as the Windows host).

## DMG launcher settings (no GUI needed)

The packaged launcher reads two optional files from
`~/Library/Application Support/ExtendedDisplay/`:

- `pairing.code` — an 8-char pairing code; exported as `EXTDISPLAY_KEY` so the
  launcher's stream is encrypted (Windows-GUI parity: its persisted code lives
  in `%LOCALAPPDATA%\ExtendedDisplay\pairing.code`).
- `options` — extra MacHost arguments on one line, e.g.
  `--audio --mute-local --fps 120`.

## Pairing + encryption (optional)

For an untrusted LAN, the Mac host encrypts the **video and touch** channels
with AES-256-GCM, exactly like the Windows host. Set a pairing code in the
`EXTDISPLAY_KEY` environment variable (never on the command line, so it can't
show in a process listing) and enter the same code on the tablet:

```bash
EXTDISPLAY_KEY=AB2CD3EF .build/release/MacHost --host 127.0.0.1
```

Both sides derive the same key — `PBKDF2-HMAC-SHA256(code, "ExtDisplay/v1",
200000)` — so no key material crosses the network. The tablet remembers the
derived key, so you type the code **once, ever**. Video is sent as the
`EXVE`-marked encrypted stream over TCP (the tablet shows nothing until you
enter the code, then decrypts on the same connection) or as sealed NALs behind
the plaintext `EXUD` header over UDP; touch packets are sealed 56-byte frames
the host rejects on a wrong code (no cursor injection from strangers); audio
frames are sealed with their own nonce domain (`0x02`).

Verify the KDF matches the other platforms byte-for-byte:

```bash
.build/release/MacHost --derive-key TESTCODE   # 3961c9…c381 (same as Windows --derive-key)
.build/release/MacHost --crypto-selftest       # KDF + GCM round-trip + wrong-key rejection
```

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
- **`--udp` shows a black or frozen picture** → your Wi-Fi path can't carry
  the keyframe bursts (a keyframe is dozens of datagrams; if any one drops,
  that keyframe is lost and video only recovers on the next complete one —
  UDP has no retransmission). Watch the periodic `UDP: N pkts/s` line, lower
  `--bitrate`/`--width/--height`, or just use TCP (the default), which is
  immune. The Mac host paces large bursts and never blocks encoding on a
  congested link (drops instead).
- **App stays on "Waiting…"** → MacHost isn't reaching the tablet — verify with
  `nc -vz <tablet-ip> 5000`.
- **Choppy / lagging** → lower `--fps` (30) or `--bitrate`; the TCP write runs
  on the encoder callback thread, so severe Wi-Fi backpressure stalls encoding
  (harmless over USB).
- **Tablet touches do nothing** → the Accessibility permission isn't granted
  (see Requirements); MacHost prints a warning at start when that's the case.
  `--no-touch` also disables injection deliberately.

## Limitations (honest)

- Touch is single-pointer (macOS has no public API to inject real multi-touch
  into arbitrary apps — Windows has `InjectTouchInput`). S Pen **pressure** is
  carried on the mouse events as tablet-point data, so pressure-aware apps
  respond; full eraser semantics need tablet *proximity* events (future).
- **No HDR**: the virtual display's framebuffer is SDR — the known
  CGVirtualDisplay surface exposes no EDR capability (Windows gets HDR from
  its VDD driver). Capturing a real HDR-capable display could grow this later.
- The virtual display can't be removed *without* exiting MacHost — releasing
  it while the process runs leaves it online (macOS 26). It is removed on exit,
  so in practice this only matters if you wanted to drop it mid-session.
- Audio/video are separate streams with no shared clock (lip-sync approximate,
  tune `--audio-delay-ms`) — same as the Windows host.
- No settings GUI — the DMG launcher plus the `pairing.code`/`options` files
  cover the plug-and-play story (see above).
