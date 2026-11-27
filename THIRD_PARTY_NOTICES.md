# Third-party components

DualSlate's own code is in this repository. The Windows installer also bundles the
components below, unmodified, each under its own license. None of them is part of
DualSlate's source.

| Component | Used for | License | Source |
|---|---|---|---|
| **Virtual Display Driver** by VirtualDrivers (IddCx, signed via SignPath) | The extra screen on Windows | MIT | https://github.com/VirtualDrivers/Virtual-Display-Driver |
| **FFmpeg** (the "gpl" Windows build by BtbN, `ffmpeg.exe`) | Screen capture and video encoding | GPL-3.0-or-later (this build includes x264/x265) | https://ffmpeg.org/download.html and https://github.com/BtbN/FFmpeg-Builds (build scripts) |
| **Android SDK Platform-Tools** (`adb`) | The USB connection to the tablet | Android Software Development Kit License; adb source is Apache-2.0 | https://developer.android.com/tools/releases/platform-tools |
| **Inno Setup** | Builds the Windows installer (not shipped as a component) | Inno Setup License | https://jrsoftware.org/isinfo.php |

Notes:
- **FFmpeg** is a separate program that DualSlate runs, not a library it links. Its
  complete corresponding source is available from the links above. The exact build
  is the one named `ffmpeg-master-latest-win64-gpl` at the time the installer was
  built (installers/windows/build-payload.ps1).
- **The Virtual Display Driver** is installed by installers/windows/install-vdd.ps1.
  Its signing certificate is added to the machine's TrustedPublisher and Root stores
  so the install needs no prompt. The uninstaller removes the driver.
- **The macOS app** uses only Apple system frameworks (ScreenCaptureKit, VideoToolbox,
  CoreGraphics) and bundles adb in the same way.

Thanks to the authors of all of these projects.
