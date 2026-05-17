# Mac Host Support

The Mac host uses the same Android receiver and the same H.264 Annex-B over TCP protocol as the Windows host.

```text
macOS ScreenCaptureKit -> VideoToolbox H.264 -> TCP/ADB -> Android MediaCodec
```

## Why Mac Is Simpler

Phase 1 does not need a kernel-level display driver on macOS:

- `ScreenCaptureKit` captures a display efficiently.
- `VideoToolbox` provides hardware H.264 now, with room to add HEVC after codec negotiation is added.
- `CGEvent` can inject input later for touch/mouse.

For a true virtual/extended display, this branch keeps the capture/encode/transport path isolated so a later virtual display provider can be swapped in. Practical options:

- Use a virtual display created by BetterDisplay/BetterDummy-style display plumbing, then capture that display.
- Use DisplayLink or another virtual display provider, then capture the resulting display.

## Build

Requirements:

- macOS 13+
- Xcode command line tools
- Screen Recording permission granted to Terminal or the built app

Build:

```bash
cd mac-host
swift build -c release
```

Run over WiFi:

```bash
.build/release/MacHost --host <tablet-ip> --port 5000 --fps 60 --width 2560 --height 1600
```

Run over USB-C with ADB:

```bash
adb forward tcp:5000 tcp:5000
.build/release/MacHost --host 127.0.0.1 --port 5000 --fps 60 --width 2560 --height 1600
```

## Current Limitations

- The Android receiver currently expects H.264. HEVC should be added with explicit codec negotiation.
- The host captures an existing display. True virtual display creation is the next Mac-specific milestone.
- macOS will prompt for Screen Recording permission the first time capture starts.
