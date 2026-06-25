# Mac Host

The Mac host shares the Android receiver and the H.264-Annex-B-over-TCP protocol with the Windows host.

```text
macOS ScreenCaptureKit -> VideoToolbox H.264 -> TCP over adb USB -> Android MediaCodec
```

## Packaging (.app + .dmg)

On a Mac (Xcode command line tools required):

```bash
./installers/mac/build-dmg.sh
```

This builds `MacHost` (release), wraps it in `ExtendedDisplay.app` with a launcher that automates adb (waits for the tablet, installs the bundled APK if needed, sets up `adb forward tcp:5000 tcp:5000`, starts the receiver activity), bundles darwin platform-tools, ad-hoc signs the bundle, and produces `installers/mac/dist/ExtendedDisplay.dmg`.

First run: right-click → Open (ad-hoc signature), and grant **Screen Recording** permission when macOS asks. The launcher logs to `~/Library/Logs/ExtendedDisplay.log`.

> The packaging script is authored and syntax-checked but has not been executed on a Mac in this repo — report issues if a step fails.

## Getting an Extended (Not Mirrored) Display on macOS

The host captures an existing display. For a true extended display without second hardware:

- Create a virtual display with **BetterDisplay** (or similar), set it to your tablet's resolution, then run the app — it captures the first non-builtin display it finds, or pass `--display N`.
- A native `CGVirtualDisplay`-based virtual display (no third-party app) is the next Mac milestone — see Next Phases in the README.

## Manual Build / Run

```bash
cd mac-host
swift build -c release
adb forward tcp:5000 tcp:5000
.build/release/MacHost --host 127.0.0.1 --port 5000 --fps 60 --width 2560 --height 1600
```

## Current Limitations

- H.264 only (HEVC needs codec negotiation in the protocol).
- Virtual display creation requires a third-party tool for now.
- The TCP write happens on the encoder callback thread; severe network backpressure stalls encoding (harmless over USB).
