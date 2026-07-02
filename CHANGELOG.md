# Changelog

## v0.9.0 — 2026-07-03

Mac host: from video-only phase 1 toward Windows parity. Verified on macOS 26
(Apple silicon, M4) against receiver v9 on a Galaxy Tab S9 Ultra.

- **Stage 1 — existing host + DMG verified on a real Mac (USB + Wi-Fi).**
  - USB (`adb forward` + `--host 127.0.0.1`) and Wi-Fi (`--host <tablet-ip>`)
    streaming verified end-to-end (tablet decodes H.264 at 60 works/s). Wi-Fi
    needs the one-time macOS Local Network grant; the deny surfaces as instant
    `EHOSTUNREACH` while Apple-signed tools connect fine — hence the
    retry+errno fixes below.
  - Fixed: `RunLoop.run()` (unavailable from async contexts — Swift 6) replaced
    with a SIGINT/SIGTERM-driven lifetime; clean "Stopping." teardown verified.
  - Fixed: one-shot connect → **retry every 2 s** until the tablet listener is
    reachable (covers the app-launch race, session rebind gaps, and the one-time
    macOS **Local Network** grant). Socket errors now include errno text.
  - Fixed: stdout is line-buffered so Finder launches actually log to
    `~/Library/Logs/ExtendedDisplay.log` in real time.
  - `build-dmg.sh` executed for the first time on a real Mac; fixed the missing
    executable bit and a relative-APK-path break (the build `cd`s into
    `mac-host/`). DMG verified: mount → launcher → adb forward → app launch →
    streaming, `codesign -v --deep` clean.
  - Docs: macOS 15+ Local Network permission requirement (Wi-Fi), AirPlay
    Receiver-on-:5000 gotcha (a missing adb forward "connects" anyway and video
    goes nowhere), updated troubleshooting.

- **Stage 2 — native virtual display (no more BetterDisplay).** By default the
  Mac host now creates a **CGVirtualDisplay** at the tablet's native
  2960x1848@60 (16:10, HiDPI — UI renders at 1480x924@2x so the framebuffer
  stays at native tablet pixels) and captures *that*: a true extended display.
  `--display N` keeps the old capture-an-existing-display path (mirror).
  Verified on-device over USB and Wi-Fi: tablet shows the extended desktop
  (own wallpaper/menu bar, full-bleed 16:10, crisp HiDPI text).
  - All private-API contact is confined to a tiny ObjC shim target (`CVDShim`,
    resolved via `NSClassFromString` — nothing private at link time). HiDPI
    recipe on macOS 26: declare BOTH the full pixel mode and its half; with
    `hiDPI=2` WindowServer pairs them into the Retina mode and defaults to it.
  - Lifecycle (macOS 26, empirically verified): WindowServer reclaims the
    virtual display when MacHost **exits** (clean quit or kill — gone within a
    second), so the host just holds it for the run and lets exit be the
    teardown. What does *not* remove it is releasing the object while the
    process keeps running, so a fast restart may find the previous instance
    still online — the host **adopts** its own display (vendor/product match)
    rather than making a duplicate. Fresh displays come up **mirrored** (even
    as main) and are switched to extend + positioned right of the main display
    automatically. `--remove-display`
    (`CGRestorePermanentDisplayConfiguration`) is a rarely-needed safety valve.
  - `--width/--height` now default to the captured display's native pixel
    size (matching the Windows sender), so the virtual display streams
    pixel-perfect without flags.

- **Stage 3 — touch-back (tablet → Mac).** The host connects to the tablet's
  touch port (5001), parses the **28-byte protocol-v2** packets (big-endian
  `HXTP`, normalized coords, pressure, tool type incl. stylus/eraser, hover),
  and injects the Mac cursor via `CGEvent` posted to the HID tap: down/up →
  left-button press (taps click, quick repeats double-click via manual
  click-state), move → drag, S Pen hover → cursor move. Single-pointer for now
  (stylus/eraser ride the mouse path; real pen/pressure is a later milestone).
  `--no-touch` disables it.
  - Reconnects forever with a 2 s backoff (like the Windows bridge) and
    resyncs on the packet magic after a mid-stream connect; releases a stuck
    button if the tablet drops mid-drag.
  - Needs macOS **Accessibility** permission (CGEvent injection silently
    no-ops without it — surfaced with the system prompt at start).
  - USB adds `adb forward tcp:5001 tcp:5001` (the DMG launcher now does this);
    Wi-Fi connects to the tablet's :5001 directly. Verified on-device: tablet
    taps land pixel-exact on the computed display coordinate (center →
    2209.5,461.5; 0.1,0.1 → 1617.9,92.3), drags track exactly.
  - New `--selftest` runs pure-logic protocol tests (touch v2 parse, golden
    vector byte-matched to the receiver's writer) — the CLT-only-Mac stand-in
    for the Windows `--crypto-selftest` (no XCTest available).
  - docs/protocol.md touch section corrected to protocol v2 (was documented as
    the retired 24-byte v1).

- **Stage 4a — `--wifi` LAN discovery (parity with Windows).** `MacHost --wifi`
  broadcasts `EXTDISP?v1` on UDP 5002 to every up/non-loopback interface's
  subnet-directed address (`ip | ~mask`, plus 255.255.255.255) and connects to
  the first tablet that answers `EXTDISP!v1|<name>|<port>` — no IP typing.
  Verified on-device: found `samsung SM-X910 at 192.168.1.19` and streamed
  (video + touch) over Wi-Fi. `--selftest` gained a reply-parser check.

- **Stage 4b — PIN pairing + AES-256-GCM (video + touch).** Set a code in the
  `EXTDISPLAY_KEY` env var (not argv) and the Mac host encrypts video and touch
  exactly like the Windows host. KDF is **byte-identical** across platforms —
  `CommonCrypto` `CCKeyDerivationPBKDF` (PBKDF2-HMAC-SHA256, salt
  `ExtDisplay/v1`, 200 000 iters) + `CryptoKit` `AES.GCM` — verified against an
  independent vector (`--derive-key TESTCODE` → `3961c9…c381`) and the Windows
  output. `--crypto-selftest` (KDF deterministic + golden-matched, GCM
  round-trip, wrong-key rejected) mirrors the Windows self-test.
  - Video: sends the 4-byte `EXVE` marker, then each NAL as
    `[4B len][12B nonce][ct][16B tag]` (nonce domain `0x01`).
  - Touch: reads 56-byte sealed frames, drops the connection on auth failure
    (wrong code → no cursor injection). Replay guard rebases on a new nonce
    prefix, so the tablet re-keying its Sealer (on the EXVE latch or a code
    entry) doesn't stall touch.
  - Verified on-device (USB): correct code → video decodes and touch injects
    pixel-exact through the encrypted path; wrong code → no video, touch
    auth-fails and is rejected. Plaintext still works unchanged (the tablet's
    saved-key mismatch auto-detect displays it and unseals touch).
- **Fixed: the Mac host no longer crashes when the tablet disconnects.** A write
  to the closed video socket raised **SIGPIPE**, killing the process (exit 141)
  — any tablet-side disconnect (app closed, Wi-Fi blip, wrong-key drain) took
  the host down. SIGPIPE is now ignored process-wide, and the video stream runs
  under a **supervisor loop** that reconnects on disconnect (like the Windows
  host restarting the stream), setting up the virtual display and touch bridge
  once. Verified: killing the tablet app mid-stream → host survives → reconnects
  and resumes when the app reopens.

- **Stage 4c — HEVC (`--hevc`).** The encoder can emit H.265/HEVC
  (`kCMVideoCodecType_HEVC`, Main profile, VPS/SPS/PPS parameter sets as
  Annex-B); the receiver auto-detects the codec from the first NAL, so no
  negotiation. Verified on-device: `--hevc` → tablet spins up
  `c2.qti.hevc.decoder` and shows "Decoding HEVC"; `--hevc` + `EXTDISPLAY_KEY`
  → encrypted HEVC decodes (full-desktop frame) with touch still pixel-exact.

The Mac host is no longer "video-only": it now does a native extended display,
touch-back, LAN discovery, PIN pairing + AES-256-GCM, and HEVC. Remaining
Windows-only: desktop audio, real multi-touch / pen pressure, UDP transport,
120 fps mode-switch, HDR.

## v0.8.0 — 2026-07-02

Improvements (Wi-Fi robustness + usability + security + desktop audio).

- **Pairing is now one-time.** The tablet stores the derived key after a
  successful pair and re-applies it on every launch; the PC GUI persists the
  pairing code (`%LOCALAPPDATA%\ExtendedDisplay\pairing.code`) and reuses it, with
  a "new code" link to rotate. If the PC later streams unencrypted, the tablet
  auto-detects (TCP `EXVE` marker / UDP first-packet latch) and unseals its touch
  channel for that session — no silent breakage on mismatch. Verified on-device:
  pair once → app restart auto-pairs ("Paired from saved key") with video, touch
  and audio working untyped; plaintext session with a saved key decodes with zero
  touch auth failures. Details + trade-offs in [SECURITY.md](SECURITY.md).
- **Fixed: encrypted-TCP sessions now survive the tablet app restarting.** When
  the peer dropped, the sender's pipe loop exited but then waited on ffmpeg
  forever — and ffmpeg was blocked writing the undrained pipe (deadlock; the
  stream froze until the sender was killed). The sender now kills ffmpeg on peer
  disconnect and reconnects; a disconnect keeps its uptime so the proven encoder
  isn't blamed.

- **Desktop audio (PC → tablet).** New opt-in "Desktop audio" checkbox (CLI:
  `--audio`) streams whatever the PC is playing to the tablet's speakers. The
  sender captures the default render endpoint via **WASAPI loopback** (no extra
  driver), converts the mix to 16-bit stereo, and sends it length-prefixed over a
  dedicated channel (TCP 5003; adb-forwarded on USB). The tablet plays it through
  an `AudioTrack` (newest-connection-wins, like touch). When encryption is on the
  audio is **AES-256-GCM** too (nonce prefix `0x02`, domain-separated from video
  `0x01` / touch `0x00`); a 16-byte plaintext format header carries rate/channels
  and an "encrypted" flag so the tablet stays **silent until you pair** (no
  static-noise while typing the code). A 1-byte ACK handshake makes the sender wait
  for a live receiver, so audio survives the app-launch race (adb-forward accepts
  the local socket before the app binds its port). Verified on-device (USB): open →
  `Audio: playing 48000Hz 2ch`; paired → continuous decrypted playback, stable.
  - **"Mute PC speakers" sub-option** (CLI: `--mute-local`) silences the PC's own
    output so sound comes only from the tablet. WASAPI loopback still captures the
    muted mix (verified), so the tablet keeps audio. A marker file self-heals a
    stuck mute if the sender is force-killed (the next launch un-mutes).
  - Latency: the `AudioTrack` uses a small buffer so audio tracks the video closely
    (A/V sync is approximate — no shared clock; tunable). See [Fixes.md](Fixes.md).

- **Encrypted video now displays reliably regardless of when you pair.** The
  tablet chose encrypted-vs-plaintext once at connect, so entering the code *after*
  the sender connected left it decoding ciphertext as plaintext (no picture). The
  sender now prefixes the encrypted stream with a plaintext `EXVE` marker; the
  tablet recognises it, **drains frames until you key in, then decrypts on the same
  connection** — no reconnect, no garbage. Verified: with Desktop audio *and*
  Encrypt on, the desktop appears on the tablet right after the code is entered.

- **Security — PIN pairing + encrypted link (stages 1–3).** Opt-in "Encrypt" in
  the GUI mints an 8-char pairing code; you type it on the tablet once. Both derive
  the same AES-256 key via PBKDF2-HMAC-SHA256 (verified byte-identical across
  Windows BCrypt and Android javax.crypto). **All channels are now AES-256-GCM
  encrypted + authenticated:** the touch/input channel (with a replay guard) and
  the **video channel on both transports** — UDP (per-NAL, then fragment) *and*
  TCP (the sender proxies ffmpeg and length-prefixes each encrypted NAL). Nonces
  are domain-separated (video `0x01` / touch `0x00`). Verified on-device: correct
  code → touch injects and video decodes at 2960×1848 on both TCP and UDP; wrong
  code → touch rejected and no video. Encrypted Wi-Fi now keeps TCP's smoothness
  (**no longer forced onto UDP**). Design, threat model, and remaining polish in
  [SECURITY.md](SECURITY.md).
  - Pairing entry on the tablet is a boxed, monospaced, letter-spaced field (reads
    like blocks), 8-char capped/auto-caps. Auto-apply on the 8th char is deferred a
    frame so the final character renders before the panel tucks away (it used to
    pair but the last char appeared to "not show").
  - The pairing box no longer grabs focus/keyboard on launch and **auto-hides once
    video is decoding** — so with encryption off it no longer lingers/blocks the
    screen (previously it hung until a stop/reconnect). GUI code label trimmed to
    just "Pairing code:  XXXXXXXX".
- **S Pen:** pressure drawing and hover work (verified in MS Whiteboard/GoodNotes).
  **Eraser is a known limitation** — the S Pen has no eraser tip, and its side button
  is owned by Samsung Air Command at the system level (a press opens the S Pen panel),
  so it can't serve as a reliable hold-to-erase modifier. We map a real eraser tip
  (`TOOL_TYPE_ERASER`, e.g. a flipped Surface Pen) but deliberately don't map the S
  Pen button (it only produced glitchy mixed strokes). See [Fixes.md](Fixes.md).

- **Smooth 120 fps.** At native 2960×1848, 120 Hz overruns the capture+encode
  throughput (~656 Mpix/s — past 4K60), so frames back up and even the cursor
  drags. When 120 fps is selected the sender now drops the virtual display to
  **1920×1200** (the tablet upscales); native resolution is restored automatically
  for ≤60 fps. 2560×1600@120 was measured too — ffmpeg held fps=120 at 0.997× —
  but it was *perceptibly* less smooth on-device (the encoder stat can't see
  decode/render headroom), so the smoothest mode won.
- **GUI simplified.** The FPS / encoder / bitrate knobs are replaced by one
  **Quality** preset — *Best resolution* (native@60, 40 Mbps), *Balanced*
  (native@60, 25 Mbps, recommended) or *Smooth motion* (120 fps @1920×1200) — and
  every option is now a short label with an ⓘ info marker (hover for the wrapped
  description; the old inline descriptions clipped at the window edge). Encoder
  selection always uses the auto-ladder; fine-grained control stays on the CLI.
- **UDP path robustness:** a bigger socket send buffer (4 MB) so a keyframe's
  fragment burst isn't dropped by the OS/Wi-Fi driver. (Intra-refresh was tried but
  **reverted** — removing periodic IDRs left the decoder with nothing to resync on
  after Wi-Fi loss, causing a permanent freeze; periodic IDR recovers in ~1s.) On a
  good 5 GHz link **TCP is smoother** than UDP (no dropped frames); UDP mainly helps
  on lossy/high-latency links. Full adaptive-bitrate/FEC/on-demand-keyframes need a
  feedback channel + library encoder — see [Fixes.md](Fixes.md).
- **Manual tablet IP** in the GUI (and `--host` on the CLI) for networks that
  block the discovery broadcast (AP isolation, guest Wi-Fi). Empty = auto-discover.
- **Live status line** in the GUI — the sender emits ffmpeg `-stats`, and the GUI
  captures its output to show connection state + live fps
  (`Streaming • Wi-Fi UDP • 59 fps`, `Reconnecting…`, `Searching for tablet…`).
  (End-to-end latency isn't shown — it needs the receiver→sender feedback channel
  noted in [Fixes.md](Fixes.md).)

## v0.7.2

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
- **HDR: real colour-conversion fix, but kept experimental.** The `--hdr` path
  was *re-tagging* the captured frames as PQ without converting them, so the
  tablet PQ-decoded sRGB values and blew out ("extra bright"). It now genuinely
  converts sRGB/BT.709 → PQ/BT.2020 via `zscale` (SDR white → 100 nits). However,
  the VDD framebuffer is measurably **SDR** (ddagrab tags it bt709/sRGB even with
  HDR on), so there is no real HDR content to deliver and it can't look
  "calibrated". SDR stays the default/recommended mode; `--hdr` and the GUI HDR
  option remain **experimental** (for genuine HDR video only). Full write-up in
  [Fixes.md](Fixes.md).

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
