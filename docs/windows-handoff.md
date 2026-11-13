# Windows hand-off: what is left, and a prompt to do it

Written 2026-11-13 from the Mac. Everything below is on the **`mac`** branch of
`https://github.com/Namans12/dual_display.git` (not on `main`).

## What the Mac could not do

The Mac has no JDK or Android SDK, so the Android receiver could not be built there. These are waiting for the
Windows laptop (Android Studio installed, tablet on USB):

1. **Build receiver versionCode 10** from `android-receiver/` and install it on the tablet. It carries three source
   changes that have never been compiled: the idle decoder drain, the fading status label, and re-detecting the codec
   on every host connection. Step-by-step: [build-receiver-on-windows.md](build-receiver-on-windows.md).
2. **Fix whatever does not compile** in those changes (all in `MainActivity.kt`), keeping their behaviour.
3. **Check the three fixes on the tablet** with the Windows host (section 5 of the guide), and check nothing regressed:
   USB and Wi-Fi streaming, touch, pairing, audio.
4. **Raise the version gates to 10** so both launchers upgrade tablets that still have v9:
   `kRequiredAppVersion` in `windows-sender/src/main.cpp` (then rebuild the sender and the Windows installer
   payload), and `REQUIRED_APP_VERSION` in `installers/mac/build-dmg.sh` (edit only; the DMG is built on the Mac).
5. **Bring the APK back to the Mac** (it is gitignored: copy the file, do not commit it) so the Mac app can bundle it,
   and push the source changes.

Not Windows work, listed so nobody looks for it here: the Mac launcher app, the Mac host's 60 fps / low-latency
changes and the Mac permissions are done or handled on the Mac (see `docs/mac.md` and `CHANGELOG.md`).

## Prompt for Claude on the Windows laptop

Open a Claude Code session in the cloned repo on Windows and paste this:

```text
You are in a clone of https://github.com/Namans12/dual_display.git on my Windows laptop. Check out and pull the
`mac` branch first; all the work below is on that branch, not on `main`.

Background. This project turns my Samsung Galaxy Tab S9 Ultra (SM-X910) into an extended display for a Windows PC
or a Mac. `android-receiver/` is the tablet app, `windows-sender/` the Windows host, `mac-host/` the Mac host. On
my Mac, three fixes were written into the tablet app's source
(android-receiver/app/src/main/java/com/heysnap/extdisplay/MainActivity.kt) and its versionCode was raised from 9
to 10, but the Mac has no Android toolchain, so NONE of it has ever been compiled or run. This laptop has Android
Studio. The tablet is connected by USB with USB debugging on.

Read these before doing anything: docs/windows-handoff.md, docs/build-receiver-on-windows.md (the build and install
steps, with what is verified and what is only expected), then `git diff c3fc542 HEAD -- android-receiver` to see
exactly what changed in the receiver. The three changes are:
  1. decodeSession: a 4 ms queue poll and draining decoder output when idle, so a decoded frame is presented at
     once instead of when the next NAL arrives.
  2. The on-screen status label fades about 2.5 s after video is on screen and returns when the host disconnects
     (showStatus / setVideoShowing / onVideoShowing / setShowing, STATUS_LINGER_MS).
  3. The codec is re-detected for every host connection (streamGeneration, carriedNal, startsStream), so switching
     the host between H.264 and HEVC no longer leaves a dead picture.

What I want you to do, in this order:
  1. Build the release APK (`gradlew.bat :app:assembleRelease` in android-receiver, with JAVA_HOME pointing at
     Android Studio's bundled JDK). If it does not compile, fix the errors with the smallest change that keeps the
     behaviour described above, and tell me what was wrong. Do not rewrite the decode loop or change the wire
     protocol.
  2. Install it on the tablet with `adb install -r` and confirm `versionCode=10` with
     `adb shell dumpsys package com.heysnap.extdisplay`. If the install fails with
     INSTALL_FAILED_UPDATE_INCOMPATIBLE, stop and ask me before uninstalling: uninstalling wipes the saved pairing
     key on the tablet.
  3. Verify the three fixes on the tablet using the Windows host, following section 5 of
     docs/build-receiver-on-windows.md, including the HEVC on/off switch without restarting the tablet app. Use
     `adb exec-out screencap -p` screenshots and the tablet's on-screen status text as evidence; watch
     `adb logcat` (tag ExtDisplay) for decoder errors. Also confirm nothing regressed: USB and Wi-Fi streaming,
     touch, the pairing code, and desktop audio if I use it. Ask me to look at the tablet for anything a
     screenshot cannot show (for example whether motion feels smooth).
  4. Raise the version gates to 10: `kRequiredAppVersion` in windows-sender/src/main.cpp (rebuild the sender, then
     the installer payload as described in installers/windows/README.md), and `REQUIRED_APP_VERSION` plus its
     comment in installers/mac/build-dmg.sh (edit only; do not try to run that script on Windows).
  5. Update CHANGELOG.md ("Unreleased" section) and docs/mac.md where they still say the receiver is source-only or
     versionCode 9, to say what was actually built and verified.
  6. Commit on the `mac` branch with clear messages and push. Do not commit APKs or other build outputs (they are
     gitignored on purpose). Tell me the full path of app-release.apk so I can copy it to the Mac.

Rules:
  - Report what you ran and what you saw. If something was not tested, say so; do not describe an untested fix as
    working.
  - Find the cause before changing code when something fails; do not stack guesses.
  - Ask before anything that deletes data on the tablet, changes the pairing code, or touches the `main` branch.
  - Do not change the Mac host (mac-host/) beyond the one-line version gate in installers/mac/build-dmg.sh.

Finish with a short report: what was wrong with the build (if anything), what you verified on the tablet and how,
what you could not verify, the commits you pushed, and where the APK is.
```

## After Windows is done (back on the Mac)

1. `git pull` on the `mac` branch.
2. Copy `app-release.apk` over and rebuild the app: `./installers/mac/build-dmg.sh /path/to/app-release.apk`, then
   replace `/Applications/ExtendedDisplay.app` with `installers/mac/staging/ExtendedDisplay.app`. A rebuilt app is
   re-signed, so macOS asks for Screen Recording and Accessibility again.
3. Start once over USB: the app installs v10 on the tablet if it is still on v9.
