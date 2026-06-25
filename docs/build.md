# Build Notes

## Android Receiver

Open `android-receiver/` in Android Studio, or:

```bash
cd android-receiver
./gradlew :app:assembleRelease     # installable (debug-signed) release APK
./gradlew :app:assembleDebug
```

APKs land in `app/build/outputs/apk/{release,debug}/`. The app is landscape/fullscreen and listens on TCP `5000`.

## Windows Sender

Requirements: Windows 10 1903+, CMake + MSVC Build Tools. (End users get ffmpeg/adb from the installer; for development have `ffmpeg.exe` — full GPL build with `ddagrab` — and `adb.exe` on PATH or beside the exe.)

```powershell
cd windows-sender
cmake -S . -B build
cmake --build build --config Release
```

Run it with no arguments for the full plug-and-play flow:

```powershell
.\build\Release\ExtendedDisplaySender.exe
```

CLI reference:

```text
--port N          Local forward port (default 5000)
--fps N           Frame rate (default 60)
--bitrate KBPS    Encoder bitrate in kbps (default 25000)
--display N       Capture a specific display (see --list-displays)
--list-displays   Print the display table and exit
--width/--height  Scale output (default: captured display's native size)
--encoder NAME    Pin encoder: nvenc | qsv | amf | x264
--no-zerocopy     Disable the GPU-only NVENC path
--no-touch        Disable tablet touch -> mouse injection
--hevc            H.265/HEVC (sharper at high resolution)
--hdr             HDR10 (auto-enables Windows HDR on the virtual display; implies --hevc)
--wifi            Wi-Fi: auto-discover the tablet on the LAN (UDP broadcast), then TCP
--udp             Low-latency UDP video over Wi-Fi (needs --wifi or --host)
--host IP         Wi-Fi to a specific tablet IP (manual fallback), skip adb
```

Behavior: waits for the tablet (USB via adb, or Wi-Fi via UDP discovery — auto-selected), extends onto the VirtualDrivers VDD virtual display (activating it only while streaming), installs/launches the receiver, probes encoders NVENC→QSV→AMF→MF→x264 (HEVC variants with `--hevc`/`--hdr`), streams at the display's native resolution, auto-falls-back on encoder failure, and auto-reconnects on disconnect.

## Mac Host

```bash
cd mac-host
swift build -c release
.build/release/MacHost --host 127.0.0.1 --port 5000   # after: adb forward tcp:5000 tcp:5000
```

See [mac.md](mac.md) for the .app/.dmg packaging and the extended-display setup.

## Installers

- Windows: [installers/windows/README.md](../installers/windows/README.md) — `build-payload.ps1` then `ISCC.exe installer.iss` → `dist/ExtendedDisplaySetup.exe`.
- Mac: run `installers/mac/build-dmg.sh` **on a Mac** → `installers/mac/dist/ExtendedDisplay.dmg`.
