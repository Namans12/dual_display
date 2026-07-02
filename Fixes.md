# Fixes & Investigations

A log of non-obvious fixes and dead-ends, for future reference. Complements
`CHANGELOG.md` (what changed) with *why* and *what was measured*.

---

## Desktop audio — WASAPI loopback, raw PCM (not ffmpeg dshow / Opus)

**Choice:** capture the default render endpoint with a **custom WASAPI loopback**
client (`IAudioClient` + `AUDCLNT_STREAMFLAGS_LOOPBACK`) in the sender, convert the
mix to 16-bit stereo, and send **raw PCM** length-prefixed to the tablet's
`AudioTrack`. Encrypted per-packet (AES-GCM, nonce prefix `0x02`) when paired.

**Why not the alternatives:**
- *ffmpeg `-f dshow`/openal:* Windows has no built-in loopback capture device for
  ffmpeg — it needs a virtual cable (VB-Audio, etc.), i.e. a driver install. The
  whole project is "no extra drivers beyond the VDD," so a native `IAudioClient`
  loopback is the right fit (nothing to install).
- *Opus/AAC encode:* raw S16 stereo @48 kHz is only ~1.5 Mbps — trivial next to the
  ~25 Mbps video on USB/5 GHz — and skipping a codec avoids encode/decode latency
  and a dependency. If audio ever rides a constrained link, Opus is the upgrade.

**A/V sync (tunable, not exact):** the `AudioTrack` is built with a small buffer
(`minBuf`) so audio tracks the video closely, and `track.write()` blocks to pace
capture. Audio and video are **independent streams** with no shared clock, so
lip-sync is approximate. Good enough for system sounds / video playback; tightening
it would need PTS timestamps and a shared clock (a larger change). Silent passages:
WASAPI returns no packets, so we send nothing and the tablet's buffer drains to
silence (no click). Note: `AudioTrack.PERFORMANCE_MODE_LOW_LATENCY` made `build()`
throw on the S9 Ultra (silently, so audio never started) — dropped; the small
buffer alone gives the latency win.

**Startup race → 1-byte ACK.** `adb forward` accepts the sender's *local* socket
even before the tablet app has bound its port, so a successful `connect()` doesn't
mean a live receiver. The audio channel is **write-only** (unlike touch, which
reads and thus notices a dead relay), so without a check it streamed into a black
hole during the app-launch race. Fix: the tablet sends a 1-byte ACK after reading
the format header; the sender waits for it (4 s) and reconnects otherwise.

**"Mute PC speakers" is safe — loopback survives endpoint mute.** Measured on the
S9 Ultra host: with the default render endpoint muted (`IAudioEndpointVolume::
SetMute`), WASAPI loopback still captured the full mix (peaks non-zero,
`AUDCLNT_BUFFERFLAGS_SILENT` clear). So muting silences the PC's speakers while the
tablet keeps its audio — the only no-extra-driver way to get "sound follows to the
tablet." `--mute-local` (GUI: "Mute PC speakers") does this, restoring on exit and
self-healing a stuck mute via a marker file if the sender is force-killed.

## Encrypted video showed no picture until reconnect — 'EXVE' marker

The tablet's TCP video loop chose encrypted-vs-plaintext framing **once**, when it
accepted the connection, from whether a pairing key was set. But the user enters
the code *after* the sender has already connected, so the connection was locked
into the plaintext (Annex-B) path and fed the encrypted bytes to the splitter →
garbage → no picture. It only ever worked if the code happened to be entered before
the (stable) connection was accepted.

First attempt — restart/re-accept the receiver on pairing (close the socket to
force a re-accept with the key set) — was fragile: the sender's blocking `send()`
hung on the half-closed socket (stalling ffmpeg to fps≈11), and recreating the
`MediaCodec` on the same surface raced. Reverted.

Fix: the sender prefixes the encrypted stream with a 4-byte plaintext marker
(`EXVE`). The tablet reads it up front, so it knows the stream is encrypted and
reads `videoSealer` **per frame**: before pairing it drains frames (no garbage
decode), and the moment you enter the code the next frames decrypt and the picture
appears — same connection, no reconnect. Plaintext streams (no marker) start with
an Annex-B start code and are pushed back to the splitter unchanged.

---

## Wi-Fi loss resilience — intra-refresh, not adaptive-bitrate/FEC (by design)

**Goal:** reduce Wi-Fi jank/lag (2.4 GHz / 300 Mbps link) where UDP packet loss
corrupts the picture.

**What was implemented:** rolling **intra-refresh** on the UDP path (nvenc
`-intra-refresh 1 -no-scenecut 1`; libx264 `intra-refresh=1:no-scenecut=1`). This
spreads intra-coded blocks across the GOP so a dropped packet self-heals within
one refresh cycle instead of freezing/corrupting until the next full keyframe — and
avoids the bitrate spike a keyframe would cause on a congested link. Verified: the
tablet decodes the intra-refresh stream with no decoder errors. TCP path keeps
normal keyframes (it's reliable, doesn't need this).

**What was NOT implemented, and why:** the original wish-list was *adaptive bitrate
+ FEC + on-demand keyframes*. All three need a **control/feedback channel** from
the tablet back to the sender AND runtime control of the encoder, which the current
**ffmpeg-CLI** architecture can't do (you can't change bitrate or force an IDR mid-
stream via the CLI). Doing them properly means driving libavcodec directly (or a
pipe-control protocol) + a receiver→sender RTT/loss report. That's a sizeable
rearchitecture. Intra-refresh delivers most of the real-world robustness benefit
without any of that, so it was the right first step.
  - If revisited: add a small UDP/TCP feedback message (seq gaps, RTT) from the
    receiver; move encoding to libavcodec so bitrate is reconfigurable and IDRs can
    be forced on a loss report; optionally add XOR/Reed-Solomon FEC in the UDP
    framing layer (`main.cpp` packetizer + `UdpReassembler`).

---

## HDR on the virtual display — why it stays SDR (parked)

**Status:** Parked. SDR is the mode; `--hdr` / the GUI HDR option are experimental.

**Symptoms seen (in order):**
1. `--hdr` looked **washed-out / extra bright** on the tablet.
2. After a colour-conversion fix, still **"not calibrated."**

**What was measured (the key fact):**
Probing what ddagrab captures from the VDD with Windows "HDR" enabled:

```
ffmpeg -init_hw_device d3d11va=dx:1 -filter_hw_device dx \
  -filter_complex "ddagrab=output_idx=0:output_fmt=10bit,hwdownload,format=x2bgr10le,showinfo" \
  -frames:v 2 -f null -
# -> color_range:pc  color_space:gbr  color_primaries:bt709  color_trc:iec61966-2-1 (sRGB)
```

So the virtual display's framebuffer is **10-bit sRGB / BT.709 / full-range — i.e.
SDR**, even with advanced colour "on". The VDD does **not** present a true
PQ/BT.2020 swapchain; Windows composites the (SDR) desktop into a BT.709 buffer.
**There is no real HDR content to send.**

**Root cause of "extra bright":** the old pipeline *re-tagged* the sRGB frames as
`smpte2084` (PQ) without converting them. The tablet then PQ-decodes sRGB-encoded
values, so luminance blows up.

**Fix applied (kept):** the `--hdr` path now *converts* sRGB→PQ/BT.2020 with
`zscale` instead of relabelling, mapping SDR white to 100 nits:

```
ddagrab=...:output_fmt=10bit,hwdownload,format=x2bgr10le,
zscale=p=bt2020:t=smpte2084:m=bt2020nc:r=tv:npl=100,format=p010le
```

This removed the blow-out (`windows-sender/src/main.cpp`, `buildStreamCommand`
HDR branch). Requires an FFmpeg build with `zscale` (libzimg) — the bundled BtbN
GPL build has it.

**Why it still isn't "calibrated HDR":** it's now *correct* SDR synthesised into an
HDR10 container, but it's still SDR — no real specular highlights, BT.709 gamut
stretched to BT.2020. The tablet (Dynamic AMOLED 2X, HDR10+, ~650 nits typical /
930 peak) tone-maps assuming real HDR content and there's none to reveal. No
`npl`/metadata tuning turns an SDR source into calibrated HDR.

**Decision:** SDR is the default and verified-correct mode. HDR stays experimental
for the niche of streaming genuine HDR *video* fullscreen.

**If revisited later (option B — not done):**
- Add HDR10 static metadata so the tablet's tone-mapper stops guessing:
  nvenc HEVC `-master_display "G(...)B(...)R(...)WP(...)L(max,min)"` (peak ~650 nits
  for the S9 Ultra panel) and `-max_cll "100,100"` (MaxCLL/MaxFALL ≈ our 100-nit
  mapping). This only changes how the display *interprets* the signal; it cannot
  add HDR information the SDR source lacks.
- True HDR would need the VDD to advertise a real PQ/BT.2020 HDR EDID (MttVDD
  `EdidCeaOverride` + a CEA HDR block) **and** actual HDR content playing in an
  HDR-aware app — the desktop itself is always SDR. Out of scope.

---

## S Pen eraser — not feasible (Samsung Air Command owns the button)

**Verified working:** S Pen pressure drawing and hover (MS Whiteboard, GoodNotes).

**Eraser: parked.** The Samsung S Pen has no eraser tip (unlike a Surface Pen you
flip). Its side button is the only candidate, but a diagnostic showed:
- The app *does* receive the button as `buttonState=32` (`BUTTON_STYLUS_PRIMARY`)
  with `toolType=2` (stylus) — so it's not invisible to us.
- BUT the button is claimed by **Samsung Air Command** at the system level: a single
  press opens the S Pen side panel, and it does not behave as a held modifier during
  a stroke. Mapping "stylus + button" → eraser therefore didn't erase in Whiteboard
  or GoodNotes (those decide pen-vs-eraser at stroke start), and risked glitchy mixed
  strokes from stray button events.

**Decision:** don't map the S Pen button. We still honour a real `TOOL_TYPE_ERASER`
(e.g. a flipped Surface Pen). Revisiting would require the user to disable Air actions
AND app-specific eraser handling — out of scope. (`MainActivity.kt` `toolCode`.)

## Touch never fired (receiver v8)

`SurfaceView.setOnTouchListener` never received events on this device — even
OS-injected `adb shell input tap` produced **zero** uplink packets. Moved capture
to the Activity's `dispatchTouchEvent`, which sees every touch before any child
view. (`MainActivity.kt`.)

## Touch lost on reconnect (receiver v9)

The touch server held a single connection and only noticed it was dead when it
next tried to *write* — so after a Wi-Fi blip / sender restart, the first
reconnect silently lost touch until a tap failed. Rewrote it "newest-connection-
wins": a dedicated accept loop takes the reconnecting host immediately and
supersedes the stale socket. (`MainActivity.kt`, `TouchUplink`.)

## Stop could drop real external monitors

Releasing the virtual display used `SDC_TOPOLOGY_INTERNAL`, which forces the
laptop's internal panel and would drop any real external monitor. The sender now
deactivates **only** the VDD's CCD path (`SDC_USE_SUPPLIED_DISPLAY_CONFIG`,
identifying the VDD by its `MTT1337` monitor path), and the GUI does a device-only
`Disable-PnpDevice`. Both are non-elevated-safe and leave real monitors alone.
(`windows-sender/src/main.cpp` `detachVirtualDisplay`; `launcher/Launcher.cs`.)

## Ghost monitor after crash / force-kill

A force-kill skips the sender's cleanup, leaving the VDD extended. The GUI now
auto-clears any leftover virtual display on open (device-only disable, background
worker so it can't crash the form). (`launcher/Launcher.cs` `OnShown`.)

## Colour washout in SDR (earlier)

Capturing an SDR stream while Windows HDR was enabled on the VDD looked washed
out. The SDR path now disables Windows Advanced Color on the VDD at start
(`setAdvancedColor(name, false)`); `--hdr` enables it. (`windows-sender/src/main.cpp`.)
