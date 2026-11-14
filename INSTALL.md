# Extended Display — Install, Run & Package Guide

Turn a Samsung Galaxy Tab S9 Ultra (or any Android tablet) into a **true extended
second monitor** for a Windows PC — native **2960×1848 @ 120 Hz**, over **USB‑C or
Wi‑Fi**, with **touch + S Pen** controlling the PC.

This guide has three parts:

- **[Part 1 — Install on a new PC](#part-1--install-on-a-new-pc)** (for users)
- **[Part 2 — Manual VDD setup](#part-2--manual-vdd-setup)** (if the one‑click install fails)
- **[Part 3 — Build from source & package](#part-3--build-from-source--package)** (for developers)

---

## What's in the package

The distributable (`ExtendedDisplay-0.7.2-win64.zip`) contains everything — no
runtimes to install:

| File | Purpose |
|------|---------|
| `ExtendedDisplay.exe` | **Settings GUI** — the app you run. Picks options, starts/stops streaming, manages the virtual display. |
| `ExtendedDisplaySender.exe` | The streaming engine (the GUI launches this; can also be run directly with flags). |
| `ffmpeg.exe` | GPU capture + H.264/HEVC encode (full GPL build with `ddagrab`). |
| `platform-tools\adb.exe` | Talks to the tablet over USB. |
| `VDD\` | The virtual display driver (VirtualDrivers IddCx, signed) + `devcon.exe` + `vdd_settings.xml`. |
| `ExtendedDisplayReceiver.apk` | The Android app for the tablet. |
| `Install-Driver.bat` | One‑click virtual‑display‑driver install. |
| `install-vdd.ps1` / `uninstall-vdd.ps1` | Driver install/remove scripts. |
| `QUICKSTART.txt` | The short version of this guide. |

Requirements: Windows 10 1903+ / Windows 11, x64. A GPU with NVENC/QSV/AMF is
ideal but not required (there's a CPU x264 fallback).

---

## Part 1 — Install on a new PC

### Step 1 — Install the virtual display driver (once per PC)

The virtual display driver (**VDD**) is the one component that must be installed
into Windows. Everything else just runs.

1. Extract the ZIP anywhere (e.g. `C:\ExtendedDisplay`).
2. **Right‑click `Install-Driver.bat` → Run as administrator** (or double‑click and
   approve the UAC prompt).
3. **Reboot once** after this first install — the driver reads its 2960×1848
   resolution list at boot, so the first extend after a reboot is at the correct
   native size.

> If the `.bat` fails for any reason, do it manually — see **[Part 2](#part-2--manual-vdd-setup)**.

### Step 2 — Install the tablet app

**Over USB (easiest):**
1. On the tablet: Settings → About → tap *Build number* 7× to enable Developer
   options, then Developer options → enable **USB debugging**.
2. Plug the tablet into the PC with USB‑C and tap **Allow** on the debugging prompt.
3. Just run `ExtendedDisplay.exe` and Start — the sender installs and launches the
   app automatically.

**Wi‑Fi only (no USB debugging):**
1. Copy `ExtendedDisplayReceiver.apk` to the tablet (email, USB drive, cloud).
2. Tap it on the tablet, allow "install from this source", install.
3. Open the **Extended Display** app on the tablet.

### Step 3 — Run it

1. Double‑click **`ExtendedDisplay.exe`** and approve the UAC prompt. The settings
   window opens:

   - **Connection:** USB (default) or Wi‑Fi
   - **Low‑latency UDP:** tick for Wi‑Fi if it feels laggy
   - **Touch input, HDR, HEVC, FPS, Bitrate** as desired
2. Click **Start Streaming**.
   - *USB:* tablet plugged in, USB debugging on.
   - *Wi‑Fi:* PC and tablet on the **same network**, app open on the tablet.
3. Drag windows onto the tablet. **Touch works like a touchscreen** — tap = click,
   drag = move/scroll. Tap directly on windows/icons shown on the tablet.
4. Click **Stop** when done — the virtual display disappears cleanly (no ghost
   monitor).

### Wired vs wireless — which to use

| | USB‑C | Wi‑Fi |
|--|-------|-------|
| Latency | Lowest | Good on 5 GHz; higher on 2.4 GHz |
| Setup | Needs USB debugging | Sideload APK, same network |
| Best for | Precision work, drawing | Convenience, no cable |

For Wi‑Fi, tick **Low‑latency UDP** and prefer a **5 GHz** network close to the
router — that's the single biggest latency factor.

### Command line (optional)

The GUI just runs `ExtendedDisplaySender.exe` with flags. You can run it directly:

```
ExtendedDisplaySender.exe                 # USB, auto-detect, SDR, H.264, 60fps
ExtendedDisplaySender.exe --wifi          # discover tablet on the LAN (TCP)
ExtendedDisplaySender.exe --wifi --udp    # low-latency UDP over Wi-Fi
ExtendedDisplaySender.exe --hdr           # HDR10 (HEVC Main10)
ExtendedDisplaySender.exe --fps 120 --bitrate 15000
ExtendedDisplaySender.exe --no-touch
ExtendedDisplaySender.exe --list-displays
```

### Uninstall

- Remove the driver: right‑click `uninstall-vdd.ps1` → Run with PowerShell (as
  admin), or run it from an elevated PowerShell. Then delete the folder.
- On the tablet: uninstall the **Extended Display** app normally.

---

## Part 2 — Manual VDD setup

Use this if `Install-Driver.bat` fails, or you prefer to see each step. Run an
**elevated** PowerShell (Win+X → *Terminal (Admin)*), `cd` into the extracted
folder, then:

```powershell
# 1. Trust the driver's signing certificate (makes the install non-interactive)
$dll  = ".\VDD\MttVDD.dll"
$cert = (Get-AuthenticodeSignature $dll).SignerCertificate
foreach ($s in 'TrustedPublisher','Root') {
    $store = Get-Item "Cert:\LocalMachine\$s"; $store.Open('ReadWrite')
    if (-not ($store.Certificates | ? Thumbprint -eq $cert.Thumbprint)) { $store.Add($cert) }
    $store.Close()
}

# 2. Deploy the display config (2960x1848@120 + resolutions the tablet supports)
New-Item -ItemType Directory -Force 'C:\VirtualDisplayDriver' | Out-Null
Copy-Item '.\VDD\vdd_settings.xml' 'C:\VirtualDisplayDriver\vdd_settings.xml' -Force

# 3. Add the driver to the Windows driver store
pnputil /add-driver ".\VDD\MttVDD.inf" /install

# 4. Create the virtual display device node (only if it doesn't already exist)
.\VDD\devcon.exe install ".\VDD\MttVDD.inf" "Root\MttVDD"

# 5. Verify — you should see "Virtual Display Driver", status OK
Get-PnpDevice -FriendlyName '*Virtual Display Driver*' | Format-Table Status, FriendlyName
```

Then **reboot once**. The monitor is created *inactive* — the sender extends onto
it on demand, so there's no phantom display while idle.

**To change the resolutions/refresh rates offered:** edit
`C:\VirtualDisplayDriver\vdd_settings.xml` (first `<resolution>` is the default/
native) and reboot. HDR is controlled per‑run by the sender, not this file.

**If the driver ever gets wedged** (e.g. after many install/remove cycles): run
`uninstall-vdd.ps1` elevated, reboot, then `Install-Driver.bat` again. In rare
cases a corrupted driver store needs `DISM /Online /Cleanup-Image /RestoreHealth`
followed by `sfc /scannow`, then reboot.

---

## Part 3 — Build from source & package

### Prerequisites

- **Visual Studio 2022** (or Build Tools) with the C++ workload + CMake
- **Android Studio** (for its bundled JDK at `…\Android Studio\jbr`) or JDK 17
- Internet access (the packager downloads ffmpeg, adb, and the VDD driver)

### Build the Windows sender

```powershell
cd windows-sender
cmake -B build -G "Visual Studio 17 2022" -A x64
cmake --build build --config Release
# -> windows-sender\build\Release\ExtendedDisplaySender.exe
```

### Build the settings GUI

```powershell
windows-sender\launcher\build.ps1
# -> windows-sender\launcher\ExtendedDisplay.exe  (uses csc from .NET Framework)
```

### Build the Android app

```powershell
$env:JAVA_HOME = "C:\Program Files\Android\Android Studio\jbr"
cd android-receiver
.\gradlew.bat assembleRelease      # -> app\build\outputs\apk\release\app-release.apk
```

### Assemble the payload + package

```powershell
cd installers\windows
.\build-payload.ps1                 # gathers sender, GUI, apk, ffmpeg, adb, VDD -> payload\
```

Then either:

- **Portable ZIP** (no extra tools): stage `payload\*` plus `install-vdd.ps1`,
  `uninstall-vdd.ps1`, `Install-Driver.bat`, `QUICKSTART.txt` into a folder and zip
  it. (This is what `dist\ExtendedDisplay-0.7.2-win64.zip` is.)
- **`.exe` installer** (needs [Inno Setup 6](https://jrsoftware.org/isdl.php)):
  ```powershell
  & "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer.iss
  # -> dist\ExtendedDisplaySetup.exe
  ```
  The installer bundles the payload, installs the VDD (optional task), and creates
  Start‑menu/desktop shortcuts to `ExtendedDisplay.exe`.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| "No extended display found" | VDD not installed or disabled → run `Install-Driver.bat`, reboot. Check `Get-PnpDevice -FriendlyName '*Virtual Display Driver*'`. |
| Black bars on the tablet | Resolution mismatch. After the first driver install, **reboot** so 2960×1848 loads. |
| Washed‑out / over‑bright video | The SDR path auto‑disables Windows HDR on the virtual display; if you launched with `--hdr` on an SDR desktop, drop `--hdr`. |
| Touch does nothing | Use app **v8+** (bundled here). Tap directly on a window/icon shown on the tablet (touch ≠ mouse cursor). |
| Wi‑Fi: tablet not found | PC + tablet on the **same** subnet; app open on the tablet; Wi‑Fi (not just USB) enabled on the tablet. |
| Laggy over Wi‑Fi | Tick **Low‑latency UDP**; move to **5 GHz**; lower the bitrate (e.g. 15000). |
| Encoder errors | Update GPU drivers; try `--encoder x264` (CPU) to isolate. |

See `README.md` and `docs/` for architecture and protocol details.
