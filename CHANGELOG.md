# Changelog

## v0.8.0 — 2026-07-02

Improvements (Wi-Fi robustness + usability + security + desktop audio).

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
