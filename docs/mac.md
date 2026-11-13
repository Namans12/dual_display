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
| Auto virtual display (true extend) | ✅ bundled IddCx driver | ✅ native CGVirtualDisplay, 2960x1848 HiDPI, 60 fps (default) |
| Tablet discovery | ✅ UDP broadcast | ✅ `--wifi` (UDP broadcast), or `--host <ip>` |
| Touch / S Pen → host | ✅ multi-touch + pen | ✅ single-pointer mouse + S Pen pressure (tablet-point events) |
| Desktop audio → tablet | ✅ WASAPI loopback | ✅ ScreenCaptureKit system audio (`--audio`) |
| PIN pairing + AES-256-GCM encryption | ✅ all channels | ✅ video + touch (audio n/a) |
| 120 fps mode switch | ✅ 1920x1200@120 | ✅ 1920x1200@120 (`--fps 120`) |
| HDR | ✅ HDR10 via VDD | ❌ (virtual display is SDR — see Limitations) |
| Settings GUI | ✅ | ✅ native window (SwiftUI) in ExtendedDisplay.app |

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

## Quick start — packaged (.dmg)

Download `ExtendedDisplay-<version>.dmg` from the repository's Releases page (or build it, below), open it, and
drag **Extended Display** to **Applications**.

1. **First open:** right-click the app → **Open** (it is signed with a self-signed certificate, not an Apple
   Developer ID, so macOS warns once; on recent macOS you may instead need System Settings → Privacy & Security →
   **Open Anyway**).
2. **Permissions:** the window shows a **Permissions needed** list until both are granted. Press **Grant…** next to
   *Screen Recording* and switch the app on in the list macOS opens, then press **Reopen app** (macOS only applies
   that permission to a freshly opened app). Press **Grant…** next to *Accessibility* and switch it on (needed for
   touch and pen). Over Wi-Fi, macOS also asks once for *Local Network* on the first Start.
3. **Start Streaming.** Over USB the app waits for the tablet, installs or upgrades the receiver app if needed and
   opens it; over Wi-Fi open the receiver app on the tablet first.

**Uninstall:** use **Uninstall…** at the bottom of the window (or the app menu). It stops streaming, moves the app to
the Trash and removes its privacy entries, settings, pairing code and log. Dragging the app to the Trash by hand
leaves all of those behind — macOS does not clean up after a deleted app.

**Why the app is signed the way it is.** macOS matches a privacy grant against the app's signature. An unsigned
("ad-hoc") build is a different app to macOS after every rebuild: the old grant stops working but stays in the list,
still switched on, and each build adds confusion. Every release is therefore signed with the same self-signed
certificate (`installers/mac/make-signing-cert.sh` creates it once, in the login keychain), so a grant survives
updates and each list has one entry. **Grant…** also clears a stale entry of its own before asking, which recovers
from builds made before this.

### Building the DMG

```bash
./installers/mac/make-signing-cert.sh              # once per build machine
./installers/mac/build-dmg.sh path/to/receiver.apk # -> installers/mac/dist/ExtendedDisplay-<version>.dmg
```

`build-dmg.sh` builds MacHost and the launcher window (release), bundles them with the receiver APK, darwin
platform-tools and the app icon, runs the launcher's `--selftest`, signs the bundle and writes the DMG. It leaves no
second copy of the app on disk (a stray copy shows up twice in Launchpad and in the privacy panes' "+" picker).
`EXTDISPLAY_INSTALL=1` also installs the result into /Applications. Without the certificate it falls back to ad-hoc
signing and says so. To keep releasing updates that inherit users' grants, keep that certificate's private key.

The window offers **Connection** (USB, or Wi-Fi with an optional tablet IP and
Low-latency UDP), **Quality** (Best resolution / Balanced / Fastest response),
**Options** (Touch input, HEVC, Desktop audio with Mute Mac speakers and A/V
sync delay, Encrypt link), the **pairing code** with *New code*, **Start
Streaming / Stop**, and a live status line. Settings are remembered between
launches.

Start waits for the tablet over USB, installs or upgrades the bundled receiver
if needed, sets up the adb forwards, opens the receiver, and runs MacHost as a
child process. Stop (or quitting) shuts MacHost down cleanly, which removes the
virtual display. MacHost's output goes to `~/Library/Logs/ExtendedDisplay.log`.

Quality presets: **Best resolution** adds `--bitrate 40000000`; **Balanced** is MacHost's default (2960x1848,
60 fps, 25 Mbps ceiling); **Fastest response** scales the capture to 1920x1200 (`--width 1920 --height 1200`) —
measured over USB it halves the encode time (7.6 vs 14.5 ms) and puts a touch on the wire in 16 ms instead of 24,
with text at about 72% of Balanced's sharpness.

MacHost runs as a background process, so it has no Dock icon of its own (it used to appear as a second, bouncing
"Extended Display" icon while streaming). On USB, Stop closes the tablet app so no frozen picture is left on it; over
Wi-Fi the tablet app stays open to be found again, and from receiver v10 it blanks its own screen when the stream ends.

On USB, Start restarts the tablet app: receivers up to v9 keep the decoder of their first stream, so switching
H.264 ↔ HEVC otherwise gave no picture (fixed in the receiver source for v10).

> Status (2026-11-13, macOS 27). Verified by running: the app builds, signs with the certificate and passes its
> self-tests; Start finds the tablet, sets up USB, launches MacHost and reports a missing Screen Recording
> permission clearly; **Uninstall…** on a copy removed the app, settings, pairing code, log and saved window state.
> Not verified yet: a full stream through the app after granting its permissions, Stop/quit with a live stream,
> and that the privacy entries disappear from System Settings after Uninstall (only visible on screen).

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

## Launcher files

The launcher window keeps two files in
`~/Library/Application Support/ExtendedDisplay/`:

- `pairing.code` (mode 0600) — the pairing code shown in the window, passed to
  MacHost as `EXTDISPLAY_KEY`. An existing code is reused, never overwritten
  silently (Windows-GUI parity: `%LOCALAPPDATA%\ExtendedDisplay\pairing.code`).
- `options` — optional extra MacHost arguments on one line, appended after the
  window's choices, e.g. `--eraser-key e`.

## Smoothness: how the 60 fps is achieved

Two things about macOS shape the video path (both measured on macOS 27, M4,
with a window drawing at 60 fps on the virtual display):

- **The virtual display is declared at 120 Hz, even for a 60 fps stream.**
  Declared at 60 Hz, ScreenCaptureKit only delivered ~30 frames/s from it
  (evenly 33 ms apart); declared at 120 Hz it delivers a steady 60 at the full
  2960x1848. `--fps 120` (1920x1200) did not deliver more than 60 real frames/s
  on that Mac, so it currently trades resolution for nothing there.
- **ScreenCaptureKit sends a frame only when the screen changes**, and the
  receiver (≤ v9) presents a decoded frame only when the next one arrives. So
  MacHost re-submits the last frame for ~250 ms after the screen goes still;
  without that the newest frame (the cursor leaving the tablet, the result of
  a tap) stayed undisplayed until something else changed.

H.264 is encoded with VideoToolbox's low-latency rate control (about 15 ms per frame instead of 21 at
2960x1848@60 on an M4, same fidelity against the Mac's framebuffer). Measured end to end with scrolling text at
full resolution, the tablet presented 58–59 frames/s over both USB and Wi-Fi; the video socket's round trip was
about 1 ms over USB and 7 ms over Wi-Fi, with no send backlog building up.

Over TCP a keyframe is sent every 4 s (every 1 s over UDP, where it is the only
loss recovery). `EXTDISP_TRACE=1` logs every frame in/out of the encoder, every
re-submission and every touch packet to stderr for latency work.

Colour was checked with 16 sRGB patches drawn on the virtual display and read
back from a tablet screenshot: every patch matched within 1/255. If the tablet
still looks more saturated than the Mac, that is the tablet's own display mode
(Samsung: Settings → Display → Screen mode → **Natural** instead of Vivid).

## Touch gestures

macOS has no public way to inject real multi-touch, so the host translates gestures into mouse input:

| On the tablet | On the Mac |
|---|---|
| One-finger tap (twice quickly) | Click (double-click) |
| One finger, press and move — or rest ~0.15 s, then move | Drag: select text, move windows |
| Two fingers moving | Scroll the window under the fingers, 1:1 with the fingers |
| Two-finger tap | Right-click |
| S Pen | Presses and drags at once, with pressure; hovering moves the pointer |

A finger's press is not sent the instant it lands: until it moves, lifts or has rested briefly, a second finger can
still turn the gesture into a scroll. (Before this, every touch was an immediate press-and-drag, so there was no way
to scroll.) The gesture logic is covered by `MacHost --selftest`; scrolling with real fingers on the tablet is the one
part that was not exercised when this was written.

## S Pen eraser key (`--eraser-key`)

`--eraser-key <name>` holds a key on the Mac while a stylus's eraser end is
touching (pressed just before the mouse-down, released just after the
mouse-up; never while hovering; released if the tablet disconnects
mid-stroke). macOS offers no way to inject a real ink eraser, so set this to
the key your drawing app binds to its eraser tool. Names (case-insensitive):
`a`–`z`, `0`–`9`, `delete`, `forwarddelete`, `space`, `tab`, `escape` — these
are US-layout key positions. Off by default. The key logic is covered by
`--selftest`; it has not been tried with a real eraser-tip stylus (the S Pen
has none).

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
- **`Pairing code mismatch — the tablet keeps closing the encrypted stream`**
  (older builds: an endless `Socket write failed` / `Reconnecting…` loop) →
  the tablet holds a different pairing code than this Mac. Type the Mac's code
  (launcher window, or `pairing.code`) into the code box at the top of the
  tablet's screen; MacHost keeps retrying and resumes on its own.
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
  respond. There is no true eraser: by default the eraser end draws like the
  pen tip; `--eraser-key` approximates it with a key press (see above).
- **No HDR**: the virtual display's framebuffer is SDR — the known
  CGVirtualDisplay surface exposes no EDR capability (Windows gets HDR from
  its VDD driver). Capturing a real HDR-capable display could grow this later.
- The virtual display can't be removed *without* exiting MacHost — releasing
  it while the process runs leaves it online (macOS 26). It is removed on exit,
  so in practice this only matters if you wanted to drop it mid-session.
- Audio/video are separate streams with no shared clock (lip-sync approximate,
  tune `--audio-delay-ms`) — same as the Windows host.
- The receiver fix that presents each frame as soon as it is decoded is in
  the source but not yet in a built APK (v9 is what ships); the Mac host's
  frame re-submission covers it meanwhile.
