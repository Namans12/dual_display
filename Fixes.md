# Fixes & Investigations

A log of non-obvious fixes and dead-ends, for future reference. Complements
`CHANGELOG.md` (what changed) with *why* and *what was measured*.

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
