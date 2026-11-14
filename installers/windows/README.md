# Building ExtendedDisplaySetup.exe

Reproduction steps (Windows, PowerShell 7):

```powershell
# 1. Build the sender
cmake -S ..\..\windows-sender -B ..\..\windows-sender\build
cmake --build ..\..\windows-sender\build --config Release

# 2. Build the Android APK
cd ..\..\android-receiver
$env:ANDROID_HOME = "$env:LOCALAPPDATA\Android\Sdk"
.\gradlew :app:assembleRelease
cd ..\installers\windows

# 3. Assemble the payload (downloads ffmpeg + platform-tools + VirtualDrivers VDD)
.\build-payload.ps1

# 4. Compile the installer (Inno Setup 6: winget install JRSoftware.InnoSetup)
& "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe" installer.iss
```

Output: `dist\ExtendedDisplaySetup.exe`.

## What the installer does

- Installs the sender, bundled `ffmpeg.exe`, `platform-tools` (adb), and the
  Android receiver APK to `{pf}\Extended Display`.
- With the **virtual display driver** task (on by default), runs `install-vdd.ps1`:
  trusts the VDD signing cert, `pnputil`/`devcon` installs the VirtualDrivers IddCx
  driver, and writes `C:\VirtualDisplayDriver\vdd_settings.xml` (2960x1848 + 120Hz +
  HDR). The VDD monitor stays **inactive** until the sender extends onto it on demand
  (CCD topology) — no phantom display while idle, no run-time elevation.
- Uninstall runs `uninstall-vdd.ps1`: collapses to the primary display and removes the
  VDD device + config.

## Sender flags (set up shortcuts or run manually)

```
ExtendedDisplaySender.exe                 # H.264, native res, auto encoder
ExtendedDisplaySender.exe --hevc          # H.265 (sharper at high res)
ExtendedDisplaySender.exe --hdr           # HDR10 (auto-enables Windows HDR; implies --hevc)
ExtendedDisplaySender.exe --encoder mf    # force the GPU-agnostic Media Foundation path
ExtendedDisplaySender.exe --wifi          # Wi-Fi: auto-discover the tablet on the LAN (no IP)
ExtendedDisplaySender.exe --wifi --udp    # Wi-Fi with low-latency UDP video
ExtendedDisplaySender.exe --host <ip>     # Wi-Fi to a specific IP (manual fallback)
```

## Licensing notes

- FFmpeg is the BtbN **GPL** build, downloaded at packaging time (not stored in the
  repo). Distributing the installer means distributing GPL FFmpeg — include its license.
- The **VirtualDrivers Virtual-Display-Driver** (IddCx, MIT-licensed, SignPath-signed)
  is downloaded at packaging time from its GitHub releases.
- `platform-tools` (adb) is redistributed under the Android SDK terms.
- Requires Windows 10 1903+ for `ddagrab`; HDR needs Windows 11 23H2+.
