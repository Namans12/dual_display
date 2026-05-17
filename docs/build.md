# Build Notes

## Android Receiver

Open `android-receiver/` in Android Studio, then run the `app` configuration on the tablet.

Command line:

```bash
cd android-receiver
gradle :app:assembleDebug
```

The app is landscape/fullscreen and listens on TCP `5000`.

## Windows Sender

The Phase 1 sender is intentionally a thin native launcher around FFmpeg. It uses FFmpeg's `ddagrab` source by default, which captures through Windows Desktop Duplication, then encodes H.264 for the Android receiver.

Requirements:

- Windows 10/11
- FFmpeg available on `PATH`
- FFmpeg build with `ddagrab` support, or use `--gdi`
- NVIDIA driver with NVENC support, or use `--x264`
- CMake + MSVC Build Tools

Build:

```powershell
cd windows-sender
cmake -S . -B build
cmake --build build --config Release
```

Run over WiFi:

```powershell
.\build\Release\ExtendedDisplaySender.exe --host <tablet-ip> --port 5000 --fps 60 --width 2560 --height 1600
```

Run over USB-C with ADB:

```powershell
adb forward tcp:5000 tcp:5000
.\build\Release\ExtendedDisplaySender.exe --host 127.0.0.1 --port 5000 --fps 60 --width 2560 --height 1600
```

Fallback if NVENC is unavailable:

```powershell
.\build\Release\ExtendedDisplaySender.exe --host <tablet-ip> --x264
```

Fallback if `ddagrab` is unavailable in your FFmpeg build:

```powershell
.\build\Release\ExtendedDisplaySender.exe --host <tablet-ip> --gdi
```

## Mac Sender

See [mac.md](mac.md).
