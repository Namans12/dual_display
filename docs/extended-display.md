# Extended Display Setup & Troubleshooting

## Display Lifecycle (how it stays clean)

The virtual display exists **only while a session is active**. After the tablet
connects, the sender extends the Windows desktop onto the VirtualDrivers VDD
monitor via the CCD topology API (`SetDisplayConfig` EXTEND); on exit — including
Ctrl+C, window close, and even an unexpected fault — it collapses back to the
primary display (`SetDisplayConfig` INTERNAL). No elevation is needed at run time
and no phantom monitor is left behind when idle.

The sender is extended-only: it captures the first **non-primary** display.

## The Normal Path (automatic)

`ExtendedDisplaySetup.exe` installs the **VirtualDrivers Virtual-Display-Driver**
(an IddCx indirect display driver) and writes `C:\VirtualDisplayDriver\vdd_settings.xml`
with the tablet's native modes (2960×1848 / 2560×1600 / 1920×1200, all at 120 Hz,
HDR enabled). The driver's monitor stays **inactive** until the sender extends
onto it on demand — so nothing to configure and no idle phantom display.

`--hdr` additionally turns on Windows Advanced Color (HDR) for the virtual
display automatically before streaming.

## Alternative — HDMI Dummy Plug (zero software)

A $5–10 "headless display / EDID emulator" dongle in an unused HDMI port gives
Windows a real second monitor with no driver. Set it to *Extend*; the sender
picks the non-primary display automatically.

## Diagnosing "No extended display available" (exit 2)

1. Run `ExtendedDisplaySender.exe --list-displays`. After the sender has tried to
   activate it you want a non-`primary` row (the VDD shows as `Virtual Display Driver`).
2. Driver not installed? Re-run the installer with the **virtual display driver**
   task ticked (it runs `install-vdd.ps1`: trusts the cert, `pnputil`/`devcon`
   installs the driver, writes the config).
3. Both screens show the same picture? Windows is in *Duplicate* — the sender
   forces *Extend* via topology, but you can also use Win+P → Extend.
4. Force a specific display with `--display N` (index from `--list-displays`).

## If the Tablet Shows Your Taskbar Instead of an Extension

The virtual display became the **primary** monitor. *Settings → System → Display*
→ select your laptop's display → **Make this my main display**, and drag the
virtual monitor's rectangle to the side where you want the mouse to cross.

## HDR Notes

- HDR needs **Windows 11 23H2+** and an HEVC-capable decoder on the tablet
  (the S9 Ultra's Snapdragon 8 Gen 2 qualifies).
- `--hdr` implies HEVC Main10 and auto-enables Windows HDR on the virtual display.
- An `adb`/remote screenshot of the tablet tone-maps to SDR, so it can't *show*
  the HDR brightness even when the pipeline is HDR end-to-end.

## Verifying True Extension

- Drag a window off the edge of your laptop screen — it appears on the tablet **only**.
- The mouse travels between screens at the edge set in Display Settings.
