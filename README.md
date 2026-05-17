# Extended Display PoC

Phase 1 proof of concept for a low-latency Windows-to-Android extended-display pipeline.

This first slice proves:

- Windows captures the desktop and encodes H.264.
- Android receives an H.264 Annex-B stream over TCP.
- Android decodes with `MediaCodec` and renders directly to a `SurfaceView`.
- The same socket path can later be carried over USB with `adb reverse` / `adb forward`.

## Project Layout

```text
windows-sender/       Windows sender launcher for FFmpeg capture + H.264 encode
mac-host/             macOS sender using ScreenCaptureKit + VideoToolbox
android-receiver/     Kotlin Android receiver app using MediaCodec
docs/                 Protocol and build notes
```

## Phase 1 Run Path

1. Install FFmpeg on Windows with NVENC support.
2. Build and install the Android app on the tablet.
3. Start the Android receiver. It listens on TCP port `5000`.
4. On Windows, run the sender with the tablet IP:

```powershell
ExtendedDisplaySender.exe --host 192.168.1.50 --port 5000 --fps 60 --width 2560 --height 1600
```

For USB-C using ADB port forwarding, run:

```powershell
adb forward tcp:5000 tcp:5000
ExtendedDisplaySender.exe --host 127.0.0.1 --port 5000 --fps 60 --width 2560 --height 1600
```

## Next Phases

- Replace the FFmpeg launcher with native DXGI Desktop Duplication + NVENC.
- Add the Microsoft Indirect Display Driver so Windows exposes the tablet as a real monitor.
- Add a Mac virtual display source, then capture it with the existing Mac host path.
- Add Android touch event uplink and Windows `SendInput` injection.

## Platform Hosts

- Windows: DXGI Desktop Duplication through FFmpeg `ddagrab`, H.264 via NVENC/x264.
- Mac: `ScreenCaptureKit`, H.264 via `VideoToolbox`.
- Android: shared receiver, unchanged across Windows/Mac hosts.
