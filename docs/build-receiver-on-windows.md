# Build the Android receiver (versionCode 10) on Windows

**What you get at the end:** an APK, `app-release.apk`, built from the `mac` branch and installed on the tablet, where
`adb shell dumpsys package com.heysnap.extdisplay` reports `versionCode=10`. You will also have that same file ready to
bundle into the Mac and Windows installers.

How to read this guide: statements without a label were read from a file in the repo (the file is named). Anything
marked **Expectation** is standard Android/Windows behaviour that the repo does not state and that nobody has run for
this project. Anything marked **Unverified** may differ on your machine.

## What you are building

Four changes to the receiver, all in `android-receiver/app/src/main/java/com/heysnap/extdisplay/MainActivity.kt`.
`versionCode` goes from 9 to 10 (`android-receiver/app/build.gradle`); `versionName` stays `0.8.0`, so the app info
screen will still say 0.8.0.

1. **Decode loop.** The loop now waits at most 4 ms for the next piece of video and drains the decoder's output whenever
   it is idle, so a decoded frame is shown at once. Before, the newest frame sat undisplayed until the next piece of
   video arrived. The Mac host only sends frames when the screen changes, so this showed up as a cursor left behind and
   taps that appeared late. The Mac host already works around it (it re-sends the last frame for about 250 ms after the
   screen goes still). This is the receiver-side fix, and it should also remove up to one frame of delay with the
   Windows host.
2. **Status label.** The on-screen label ("Connected (USB/TCP): 127.0.0.1" and similar) now disappears 2.5 seconds after
   video is on screen (`STATUS_LINGER_MS = 2500L`). It comes back when the picture is gone.

3. **Codec switching.** The decoder used to be chosen once, from the first stream, and kept for as long as the app ran.
   If the host then switched between H.264 and HEVC (for example ticking HEVC and pressing Start again), the tablet
   showed no picture until the app was restarted. This was reproduced on the tablet with receiver v9. Now each new host
   connection ends the decode session, and the next session picks the codec again from the new stream's parameter sets
   (`streamGeneration`, `carriedNal`, `startsStream` in `H264TcpReceiver`).

4. **Blank screen when the stream ends.** After the host stopped, the last frame stayed on the tablet and looked like a
   frozen desktop. An opaque black cover (`idleCover`) now sits over the video whenever there is no live picture, with
   the status label on top ("Disconnected — waiting for the computer"). It lifts again on the first decoded frame.

The wire protocol is unchanged, so the v10 receiver works with the existing Windows host and with the Mac host.

**None of these changes has ever been compiled or run.** The Mac they were written on has no JDK or Android SDK. This build is
their first compile. If it fails, the likeliest place is those edits. See [If the build fails](#if-the-build-fails).

The exact diff, if you want to read it first:

```powershell
git diff c3fc542 HEAD -- android-receiver
```

## Requirements

All values below are read from the build files.

| Item | Value | Source |
|---|---|---|
| Gradle | 8.10.2 (downloaded by the wrapper on first build) | `android-receiver/gradle/wrapper/gradle-wrapper.properties` |
| Android Gradle Plugin | 8.6.1 | `android-receiver/build.gradle` |
| Kotlin plugin | 2.0.20 | `android-receiver/build.gradle` |
| compileSdk / targetSdk | 35 | `android-receiver/app/build.gradle` |
| minSdk | 29 | `android-receiver/app/build.gradle` |
| Java/Kotlin target | 17 | `android-receiver/app/build.gradle` |
| JDK | 17 (Android Studio's bundled JDK, `jbr`, is what `INSTALL.md` uses) | `INSTALL.md`, "Prerequisites" |
| Dependencies | none (no `dependencies` block, so no AndroidX or other libraries) | `android-receiver/app/build.gradle` |
| Repositories | Google, Maven Central, Gradle Plugin Portal (needs internet on first build) | `android-receiver/settings.gradle` |

**Expectation:** AGP 8.6.1 needs a recent Android Studio (the Koala Feature Drop 2024.1.2 generation or newer). Android
Studio tells you when it is too old for the plugin. In that case update it. Do not downgrade the project.

You also need the **Android SDK Platform 35** (Android 15) because `compileSdk = 35`. If it is missing, Android Studio
offers to install it (see [Troubleshooting](#troubleshooting)). Its SDK Manager is the other place to get it. The exact
menu wording differs between Android Studio versions.

## 1. Get the code

The receiver changes are on the **`mac`** branch only. They are not on `main`.

The `mac` branch was pushed from the Mac on 2026-11-13 with these changes.

Fresh clone:

```powershell
git clone -b mac https://github.com/Namans12/dual_display.git
```

```powershell
cd dual_display
```

Already have a clone:

```powershell
git fetch origin
```

```powershell
git checkout mac
```

```powershell
git pull
```

Check that you have the changes. The newest commit that touches the receiver should be:

```powershell
git log -1 --oneline -- android-receiver
```

Expected output:

```text
7b03cd8 Receiver: re-detect the codec for each host connection (H.264 <-> HEVC)
```

The other two changes are in `67b51da Receiver: fade the status label once video is showing (versionCode 10)` and
`892d759 Mac: fix stale last frame (ghost cursor, laggy updates) on a still screen`. The branch tip itself will be
later than `7b03cd8`; that is fine.

Check the version number in the source:

```powershell
Select-String versionCode android-receiver\app\build.gradle
```

Expected: `versionCode = 10`.

## 2. Build the APK

Build the **`release`** variant. Both installer scripts look for the release APK first
(`installers/windows/build-payload.ps1`, `installers/mac/build-dmg.sh`). The `debug` variant works too (see
[Signing](#3-signing)).

The Gradle project is in `android-receiver/`, **not** the repo root. `settings.gradle` is in that folder and the repo
root has no Gradle build.

### Option A: Android Studio

1. Open Android Studio, choose **Open**, and select the `android-receiver` folder (the one that contains
   `settings.gradle`).
2. Wait for the Gradle sync to finish. It downloads Gradle 8.10.2, the Android Gradle plugin and the Kotlin plugin. It
   may also offer to install missing SDK pieces (SDK Platform 35, build tools). Accept those. **Unverified:** it may
   also show an "upgrade Android Gradle Plugin" suggestion. Dismiss it. The repo pins AGP 8.6.1 and Gradle 8.10.2.
3. Select the **release** variant: open the **Build Variants** tool window and set the `app` module to `release`.
4. Build the APK from the **Build** menu (an entry named like "Build APK(s)" under "Build Bundle(s) / APK(s)").
   **Unverified:** menu labels vary by Android Studio version. Alternative that does not depend on the menu: in the
   **Gradle** tool window run `app` > `Tasks` > `build` > `assembleRelease`.
5. Success shows a "build successful" message, and a notification may offer to locate the APK.

### Option B: command line (PowerShell)

`gradlew.bat` needs a JDK 17+ and the Android SDK location.

Point `JAVA_HOME` at Android Studio's bundled JDK. This is the path `INSTALL.md` uses. Adjust it if Android Studio is
installed somewhere else:

```powershell
$env:JAVA_HOME = "C:\Program Files\Android\Android Studio\jbr"
```

Point `ANDROID_HOME` at the SDK. `installers/windows/README.md` uses this default location:

```powershell
$env:ANDROID_HOME = "$env:LOCALAPPDATA\Android\Sdk"
```

**Expectation:** if you have already opened the project in Android Studio, it has written `local.properties` with
`sdk.dir`, and `ANDROID_HOME` is not needed. `local.properties` is gitignored.

Build:

```powershell
cd android-receiver
```

```powershell
.\gradlew.bat :app:assembleRelease
```

The first run downloads Gradle and the plugins and takes a while. A successful run ends with `BUILD SUCCESSFUL`
(**Expectation**).

### Where the APK is

Relative to the repo root:

| Variant | Task | Output |
|---|---|---|
| release | `:app:assembleRelease` | `android-receiver\app\build\outputs\apk\release\app-release.apk` |
| debug | `:app:assembleDebug` | `android-receiver\app\build\outputs\apk\debug\app-debug.apk` |

`docs/build.md`, `installers/windows/build-payload.ps1` and `installers/mac/build-dmg.sh` all use exactly these paths.
`android-receiver/app/build/` and `*.apk` are gitignored, so the APK never shows up in `git status`.

## 3. Signing

Read from `android-receiver/app/build.gradle`:

- The **release** build type sets `signingConfig signingConfigs.debug` (and `minifyEnabled false`). A comment in the
  file says why: "PoC distribution: debug-signed so the installer-bundled APK installs without a release keystore".
- The **debug** build type has no signing setting in the file. **Expectation:** Android Gradle Plugin signs debug builds
  with the same debug key by default. If so, both variants carry the same signature.
- There is no `signingConfigs` block, no keystore file and no key properties in the repo. The key is therefore the debug
  keystore of the machine doing the build. **Expectation:** that is `%USERPROFILE%\.android\debug.keystore`, generated
  automatically the first time something on this laptop builds a debug-signed app.
- Both variants use the same `applicationId`, `com.heysnap.extdisplay` (no suffix), so on the tablet they are the same
  app.

Practical consequence. Android only installs an update if it is signed with the same key as the installed copy. The repo
cannot tell you which machine built the APK that is on your tablet now.

- If that APK was signed with this laptop's debug key, `adb install -r` updates it in place and keeps the app's data.
- If it was signed with a different key (another machine's debug keystore), `adb install -r` fails with
  `INSTALL_FAILED_UPDATE_INCOMPATIBLE`. The fix is to uninstall the old app first, then install:

```powershell
& $adb uninstall com.heysnap.extdisplay
```

(`$adb` is defined in the next section.) Uninstalling wipes the app's data. That includes the saved pairing key, which
the app keeps in its private preferences (`MainActivity.kt`: `getSharedPreferences("pairing", ...)`, key `key_b64`).
`allowBackup` is `false` in the manifest, so nothing is restored. If you use **Encrypt**, you must type the pairing code
on the tablet once more. If you do not use Encrypt, nothing is lost that matters.

The same rule applies later to the installers. Any APK you bundle must be signed with the key of the copies already on
your tablets, or the launchers cannot upgrade them (see [section 6](#6-put-the-apk-into-the-installers)).
**Expectation:** copying one `debug.keystore` to every machine that builds the APK avoids this. Nothing in the repo does
that for you.

## 4. Install on the tablet

Tablet: Galaxy Tab S9 Ultra (SM-X910), connected by USB, USB debugging on, and the "Allow USB debugging" prompt
accepted.

**Where `adb.exe` is.** Use any one of these:

- **Android Studio's SDK**: `%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe`. This is the default SDK location used in
  `installers/windows/README.md`. **Expectation:** platform-tools is installed with the SDK. If the path is missing,
  install "Android SDK Platform-Tools" in the SDK Manager.
- **The Windows sender's own copy.** The sender looks for `platform-tools\adb.exe` beside `ExtendedDisplaySender.exe`,
  then `adb.exe` beside it, then on `PATH` (`windows-sender/src/main.cpp`). The installer bundles
  `platform-tools\adb.exe` (`installers/windows/build-payload.ps1`) and installs into `{autopf}\Extended Display`
  (`installers/windows/installer.iss`). So on an installed copy it is normally
  `C:\Program Files\Extended Display\platform-tools\adb.exe`.

The commands below use a variable. Set it to whichever `adb.exe` you have:

```powershell
$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
```

Run the rest from the repo root (the folder that contains `android-receiver`). If you are still in `android-receiver`,
run `cd ..` first.

1. List devices. Your tablet should appear with the state `device`:

```powershell
& $adb devices
```

If it says `unauthorized`, unlock the tablet and tap **Allow** on the USB debugging prompt, then run the command again.

2. Install, replacing the existing app and keeping its data:

```powershell
& $adb install -r android-receiver\app\build\outputs\apk\release\app-release.apk
```

It should end with `Success`. The Windows sender checks for that same word (`windows-sender/src/main.cpp`). If it fails
with `INSTALL_FAILED_UPDATE_INCOMPATIBLE`, see [Signing](#3-signing).

3. Confirm the version on the tablet:

```powershell
& $adb shell dumpsys package com.heysnap.extdisplay | Select-String versionCode
```

Expected: a line containing `versionCode=10` (followed by `minSdk=29 targetSdk=35` on the same line, **Expectation**).
Both hosts parse this same `versionCode=` text to decide whether to upgrade.

4. Start the app (this is the exact command the Windows sender uses):

```powershell
& $adb shell am start -n com.heysnap.extdisplay/.MainActivity
```

Both hosts only install when the app is missing or older than their required version, so they will not replace v10 with
an older build.

## 5. Check that the fixes work

Install is not proof. Look at the tablet. Do the checks over **USB** (TCP) first. Run them with whichever host you have
at hand, and ideally both.

### With the Windows host

Run `ExtendedDisplay.exe` (installed copy, or a build from `windows-sender`), choose USB, and press **Start Streaming**.

| Do this | Expect on the tablet |
|---|---|
| Start streaming | The label shows "Connected (USB/TCP): 127.0.0.1", then "Decoding H.264" (or HEVC) while the picture comes up. |
| Wait about 2.5 s after the desktop appears | The label disappears. Nothing is drawn over the desktop. |
| Press **Stop** in the GUI | The picture goes black (no frozen last frame) and the label comes back: "Disconnected — waiting for the computer", and stays. |
| Start again | "Connected (USB/TCP)..." returns, then fades again after the picture is up. |
| Stop, tick **HEVC**, Start again (do not restart the tablet app); then untick it and Start again | The picture comes up each time, and the label briefly reads "Decoding HEVC" / "Decoding H.264". With v9 the first switch gave a black or frozen picture. |
| Move the mouse cursor onto the tablet display, and back off | It follows immediately. No cursor image is left behind. Tap a window: the click registers without delay. |

**Expectation:** the Windows host keeps sending frames while the desktop is still, so the receiver's idle-drain fix is
mainly a "must not regress" check here. The visible gain is at most one frame less delay.

### With the Mac host

Use `ExtendedDisplay.app` or the manual commands in `docs/mac.md` ("Quick start — manual build / run"). Note that the
Mac app restarts the tablet app on every USB Start (a workaround for v9's codec bug), so to test fix 3 from the Mac use
the manual `MacHost --host 127.0.0.1` command with and without `--hevc`.

| Do this | Expect on the tablet |
|---|---|
| Start streaming | Same label sequence as above, then it fades about 2.5 s after the picture is up. |
| Move the cursor from the Mac's own screen onto the tablet display, then back off | The cursor does not stay frozen on the tablet. It must disappear as soon as it leaves. |
| Click once on something on the tablet | The result shows at once, not one event late. |
| Stop MacHost | "Disconnected — waiting for the computer" returns. |

The Mac host's own 250 ms workaround also hides the old bug, so you will not see a dramatic before-and-after. What you
can check is that nothing is worse and that the label behaviour is right.

### Limits of what these checks cover

- The "Disconnected" label is set only in the TCP connection loop. **Expectation, from reading the code:** over
  Wi-Fi/UDP the label fades after video starts, but it will not come back when the host stops. That is not a bug in this
  build.
- A "Decoder reset: ..." message, if one ever appears while video is showing, is shown for 2.5 s and fades again. It
  does not hold the label up. Only a lost connection or never having had video does. (`showStatus` and `setShowing` in
  `MainActivity.kt`.)
- If Encrypt is on and the tablet has no valid key, no video arrives, so the label simply stays. That is expected.

## 6. Put the APK into the installers

Do this only after the APK has been installed and checked on the tablet (`versionCode=10`). The scripts below do not
check the APK's version for you.

### Getting the file to the Mac

Do **not** commit the APK. `*.apk`, `android-receiver/app/build/`, `installers/windows/payload/` and
`installers/mac/dist/` are all gitignored (`.gitignore`). Copy the file `app-release.apk` to the Mac by any means: cloud
drive, USB stick, or `scp`.

### Mac installer (`installers/mac/build-dmg.sh`)

1. In `installers/mac/build-dmg.sh` change `REQUIRED_APP_VERSION=9` to `REQUIRED_APP_VERSION=10`. Also update the
   comment above it, which still describes v9. The script writes the value into `Info.plist` as `EDRequiredAppVersion`.
   The launcher reads it at run time and installs or upgrades the bundled APK when the tablet's `versionCode` is lower or
   the app is missing (`mac-host/Sources/ExtendedDisplayApp/AppModel.swift`, `Session.swift`).
2. Build the DMG, passing the APK path:

```bash
./installers/mac/build-dmg.sh ~/Downloads/app-release.apk
```

Without an argument the script looks for `android-receiver/app/build/outputs/apk/release/app-release.apk`, then
`.../debug/app-debug.apk`, under the Mac checkout. You can also drop the file at that path instead.

If you skip step 1, the DMG still bundles the v10 APK, but tablets already on v9 are not upgraded.

If a tablet carries an APK signed with a different key, the upgrade fails with `INSTALL_FAILED_UPDATE_INCOMPATIBLE`. The
Mac launcher logs the failure but keeps going with the old receiver whenever one is already installed. It aborts only
when no receiver is installed (`Session.swift`). Uninstall the old app on that tablet first.

### Windows installer

1. Build the release APK (section 2). `installers/windows/build-payload.ps1` then copies
   `android-receiver\app\build\outputs\apk\release\app-release.apk` (or the debug APK if there is no release one) to
   `payload\ExtendedDisplayReceiver.apk`, overwriting any previous copy. It does no version check.
2. The Windows side **does have a version gate, but it is not in the installer scripts.** It is a constant in the C++
   sender: `kRequiredAppVersion = 9` in `windows-sender/src/main.cpp`. It is compiled into
   `ExtendedDisplaySender.exe`. On Start, the sender installs the bundled APK only if the app is missing or the
   installed `versionCode` is lower than that constant. `Launcher.cs` (the GUI) has no APK or adb handling.
3. Consequence: a Windows installer bundling the v10 APK installs v10 on a tablet that has no app, but it will **not
   upgrade a tablet that already has v9**, because the sender still says 9. To make it upgrade, change
   `kRequiredAppVersion` to 10 in `windows-sender/src/main.cpp` and rebuild the sender before running
   `build-payload.ps1`:

```powershell
cmake --build windows-sender\build --config Release
```

The full Windows installer sequence (sender, APK, payload, Inno Setup) is in `installers/windows/README.md`. Whether to
bump the Windows gate is your decision. Keeping it at 9 is harmless because v10 is an improvement, not a requirement.

## If the build fails

1. Copy the **complete compiler error** (the lines starting with `e: file:///.../MainActivity.kt:LINE:COL ...`, from
   Android Studio's Build output or from the end of the `gradlew.bat` output) and send it back. Do not try to fix the
   code blind.
2. The edits are the first suspects. In `MainActivity.kt` they are (search for the names; line numbers move):
   - Status label: the `STATUS_LINGER_MS` constant; `videoShowing`, `hideStatus`, `showStatus` and `setVideoShowing` in
     `MainActivity`; the `showStatus(...)` calls and the `onVideoShowing = ...` argument where `H264TcpReceiver` is
     created; in `H264TcpReceiver` the `onVideoShowing` constructor parameter, `setShowing`, the `setShowing(false)` in
     the TCP loop's `finally` block and `setShowing(true)` in `drainOutput`.
   - Decode loop: the 4 ms `nalQueue.poll` followed by `drainOutput` in `decodeSession`.
   - Blank screen: the `idleCover` view (declared next to `statusView`, created and added in `onCreate`, toggled in
     `setVideoShowing`).
   - Codec switching: `streamGeneration` and `carriedNal` fields, the `nalQueue.clear()` /
     `streamGeneration.incrementAndGet()` pair after `accept()`, `startsStream`, and in `decodeSession` the
     parameter-set wait at the top plus the generation check that sets `carriedNal` and returns.
3. To tell a toolchain problem from a code problem, build the v9 state of the receiver, which does not contain these
   edits, in a separate folder:

```powershell
git worktree add ..\dual_display_v9 c3fc542
```

   If that builds and the `mac` branch does not, the cause is in the edits. If neither builds, it is the toolchain
   (JDK, SDK, network). Remove the extra folder afterwards with `git worktree remove ..\dual_display_v9`.

## Troubleshooting

**Android Studio or Gradle complains about the JDK or Java version.**
AGP 8.6.1 needs Java 17 or newer. **Unverified wording:** typical message is "Android Gradle plugin requires Java 17 to
run. You are currently using Java 11." In Android Studio, set the Gradle JDK to Android Studio's bundled JDK (`jbr`) or
another JDK 17 or newer in the settings: Build, Execution, Deployment > Build Tools > Gradle > Gradle JDK. Then sync
again. On the command line, set `JAVA_HOME` as in section 2.

**Missing SDK platform ("Failed to find target ... android-35", or "SDK location not found").**
Install **Android SDK Platform 35** (Android 15) from the prompt Android Studio shows, or from its SDK Manager. For
"SDK location not found" on the command line, set `ANDROID_HOME` as in section 2, or open the project once in Android
Studio so it writes `local.properties`. Both messages are **Unverified wording**.

**Gradle cannot download Gradle, the plugins or Kotlin.**
The first build needs internet access to `services.gradle.org`, Google's Maven repository, Maven Central and the Gradle
Plugin Portal. A proxy or VPN is the usual cause. The wrapper has a 10-second network timeout
(`networkTimeout=10000`), so a slow connection can fail the first attempt. Run it again.

**`gradlew.bat` fails with odd syntax or "label not found" errors.**
**Expectation:** in the git repository `android-receiver/gradlew.bat` has LF line endings (it is not stored as CRLF, and
there is no `.gitattributes`). Windows batch files can misbehave with LF endings if your Git setting stopped converting
them on checkout. Build from Android Studio instead (Option A), which does not use the `.bat` file, or convert
`gradlew.bat` to CRLF locally.

**`adb` is not recognized.**
It is not on `PATH` by default. Use the full path as in section 4.

**`adb devices` shows nothing, `offline` or `unauthorized`.**
Check that USB debugging is on and that the cable carries data (the Windows sender prints the same advice). Unlock the
tablet and accept the **Allow USB debugging** prompt. For `offline`, unplug and replug the cable. **Unverified:** if the
laptop has never seen this tablet, Windows may need Samsung's USB driver.

**"adb server version (...) doesn't match this client".**
**Expectation:** Android Studio's `adb.exe` and the Windows sender's bundled `adb.exe` can be different versions. The
second one you run restarts the adb server and the command may fail once. Run it again, or use one `adb.exe` for the
whole session.

**`INSTALL_FAILED_UPDATE_INCOMPATIBLE`.**
The APK on the tablet was signed with a different key. See [Signing](#3-signing): uninstall with
`& $adb uninstall com.heysnap.extdisplay`, then install again.

**After a reinstall, the tablet shows the pairing box again, or Encrypt streaming shows no video.**
The uninstall deleted the saved pairing key. If you stream **with Encrypt**, type the host's pairing code into the box
at the top of the tablet screen once. The tablet then remembers it again, and the host retries by itself
(`docs/mac.md`, troubleshooting). The code is shown in the host's window. It is stored in
`%LOCALAPPDATA%\ExtendedDisplay\pairing.code` on Windows and in
`~/Library/Application Support/ExtendedDisplay/pairing.code` on the Mac. If you stream **without Encrypt**, ignore the
box. It tucks away by itself once video starts (`docs/mac.md`).

**The label does not fade.**
First confirm `versionCode=10` on the tablet (section 4). Then check that the app was restarted after the install: run
the `am start` command again. The label only starts fading after a decoded frame is on screen. If no picture ever
appears (for example Encrypt is on but the tablet has no key), it stays.
