# Future features

Ideas we discussed and parked. Each entry says what it is, how it would work and what it
touches, so it can be picked up later without re-deriving the design.

## Auto-start and tray icon (Windows)

**What the user gets.**
- A small DualSlate icon sits in the notification area (next to the clock) from the moment
  Windows starts.
- Plugging in the tablet with USB-C (or opening the tablet app on the same Wi-Fi) starts
  streaming by itself. Unplugging the tablet, or closing the tablet app, stops it.
- The main window is only needed to change settings.

**How it would work.**
- **Tray icon:** the launcher gets a `NotifyIcon` with a small menu: Open, Start/Stop, the
  current status, and Quit. Closing the window hides it to the tray instead of quitting.
- **Watching for the tablet:** the launcher already keeps the driver loaded while it runs. It
  would also run a light watcher:
  - USB: `adb get-state` every 2 s, or better, a device-arrival notification;
  - Wi-Fi: the existing discovery broadcast, every few seconds, only when Wi-Fi is selected.
  When the tablet appears it presses Start itself; the sender already switches the screen off
  5 s after the tablet goes away.
- **Starting with Windows:** the launcher needs admin rights to load the display driver, so a
  plain "Startup" shortcut would show a UAC prompt at every sign-in. Instead, the installer
  registers a Scheduled Task "at log on, run with highest privileges" for DualSlate.exe
  `--tray`. That is the standard way to auto-start an elevated app without a prompt.
- **Settings:** two checkboxes, "Start with Windows" and "Connect automatically when the tablet
  is plugged in", saved in settings.ini. The installer gets a matching option.

**Touches.** windows-sender/launcher/Launcher.cs (tray, watcher, `--tray`),
installers/windows/installer.iss (scheduled task on install, removed on uninstall), and the
docs. The sender and the tablet app are unchanged.

**Cost while idle.** An adb poll every 2 s is about 1 % of one CPU core for a few ms; the
driver costs nothing measurable (measured 0.000 % CPU, 14 MB with its screen off). It should
be measured again when this is built.

## Portrait mode

The tablet held upright as a tall screen.
- The PC creates a portrait virtual screen (1848x2960, or a lighter 1200x1920 for 120 fps).
  vdd_settings.xml must list those modes.
- The tablet app allows portrait when the host says the stream is portrait.
- Touch mapping stays normalised, so it needs no change.
- Both hosts (Windows and Mac) need it. The user said it is not wanted for now.

## Tablet-side ideas
- **Keep the screen awake while streaming, and dim it after Stop.** Not requested.
- **Show the computer's name on the idle screen once paired.**
