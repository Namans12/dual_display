# Windows hand-off: what is left, and a prompt to do it

Written 2026-11-15 from the Mac. The Mac side is finished, verified on device and released (v0.10.0). All of it is
merged into **`main`** of `https://github.com/Namans12/dual_display.git`.

## What is left for the Windows laptop

1. **Build receiver versionCode 10** and install it on the tablet. Its source carries four changes written on the
   Mac that have never been compiled (the Mac has no Android toolchain): presenting each decoded frame at once,
   the fading status label, re-detecting the codec per host connection, and blanking the screen when the stream
   ends. Build steps: [build-receiver-on-windows.md](build-receiver-on-windows.md).
2. **Give the tablet app a proper pairing prompt** (new work, described in the prompt below).
3. **Confirm the Windows host still works** with the new receiver, and bring the Windows side in line with the Mac.
4. **Publish** the APK and the Windows installer on GitHub Releases next to the Mac DMG.

## Known inconsistencies (found from the Mac; none fixed there)

| Where | What is inconsistent |
|---|---|
| `windows-sender/src/main.cpp` | `kRequiredAppVersion = 9`, so the Windows host will not upgrade a tablet from v9 to v10. |
| `installers/mac/build-dmg.sh` | `REQUIRED_APP_VERSION=9` and a comment describing v9; same effect on the Mac. |
| `android-receiver/app/build.gradle` | `versionCode = 10` but `versionName = "0.8.0"`, while the project is at 0.10.0. |
| `README.md` (Windows section) | Names `ExtendedDisplay-0.7.2-win64.zip` and "bundled app (v8+)"; check against what is actually shipped. |
| `docs/mac.md`, `CHANGELOG.md` | Say the receiver is v9 / "source only"; update once v10 is built. |
| Windows launcher vs Mac launcher | Windows remembers only the pairing code between launches; the Mac app remembers every setting. |
| Windows host, wrong pairing code | The Mac host detects a pairing mismatch (the tablet closes the encrypted stream) and says so; check what the Windows host shows in the same situation. |
| Stop on Windows | With receiver v9 the tablet keeps a frozen last frame after Stop. v10 blanks it; confirm on Windows. |
| Receiver, "Decoder reset" message | While video is showing it appears for 2.5 s and fades; decide whether it should stay until video resumes. |
| Tablet pairing box | Always shows a small "Paired earlier - type a new code to re-pair" box at start, even when no code is needed, and gives no feedback on a wrong code. |

## Prompt for Claude on the Windows laptop

Open a Claude Code session in the cloned repo on Windows and paste this:

```text
You are in a clone of https://github.com/Namans12/dual_display.git on my Windows laptop. Pull `main` first; all the
work is merged there.

Background. This project turns my Samsung Galaxy Tab S9 Ultra (SM-X910) into an extended display for a Windows PC or
a Mac. `android-receiver/` is the tablet app (Kotlin, one file: app/src/main/java/com/heysnap/extdisplay/
MainActivity.kt), `windows-sender/` the Windows host (C++ sender + C# launcher), `mac-host/` the Mac host. The Mac
side was finished and verified on my Mac and is released as v0.10.0. The Windows host worked the last time I used it.
On the Mac, four fixes were written into the tablet app's source and its versionCode was raised from 9 to 10, but the
Mac has no Android toolchain, so NONE of that has ever been compiled or run. This laptop has Android Studio. The
tablet is connected by USB with USB debugging on.

Read before doing anything: docs/windows-handoff.md (what is left and a table of known inconsistencies),
docs/build-receiver-on-windows.md (build/install steps, marked verified vs expected), docs/protocol.md, SECURITY.md,
and `git diff c3fc542 HEAD -- android-receiver` for exactly what changed in the receiver:
  1. decodeSession: 4 ms queue poll + draining decoder output when idle, so a frame is presented at once.
  2. The status label fades ~2.5 s after video is on screen and returns when the host disconnects.
  3. The codec is re-detected for every host connection (streamGeneration, carriedNal, startsStream).
  4. An opaque cover (idleCover) hides the last frame whenever there is no live picture.

Do this, in order:

A. Build and install the receiver.
   Build the release APK (gradlew.bat :app:assembleRelease in android-receiver, JAVA_HOME = Android Studio's bundled
   JDK). If it does not compile, fix it with the smallest change that keeps the behaviour above and tell me what was
   wrong. Install with `adb install -r`, confirm versionCode=10 with `adb shell dumpsys package
   com.heysnap.extdisplay`. If the install fails with INSTALL_FAILED_UPDATE_INCOMPATIBLE, stop and ask me before
   uninstalling (that wipes the tablet's saved pairing key).

B. Verify the four fixes with the Windows host (section 5 of docs/build-receiver-on-windows.md), including turning
   HEVC on and off without restarting the tablet app, and Stop leaving a black screen rather than a frozen frame.
   Then confirm nothing regressed: USB and Wi-Fi streaming, touch and S Pen, desktop audio, encryption on and off.
   Use `adb exec-out screencap -p` screenshots, the on-screen status text and `adb logcat` (tag ExtDisplay) as
   evidence, and ask me to look at the tablet for anything a screenshot cannot show (smoothness, feel).

C. Redesign the tablet's pairing-code prompt. Today a small box titled "Paired earlier - type a new code to re-pair"
   sits at the top of the screen at every start, whether or not a code is needed, and a wrong code gives no feedback
   (the stream just never appears). I want:
     - No prompt at all when the host is not encrypting (plaintext session), and none when the saved key works.
     - A clear, centred prompt only when it is needed: an encrypted stream has arrived (the 'EXVE' marker over TCP,
       or the encrypted flag over UDP) and there is no key, or the saved key fails to decrypt. Say what to do in
       plain words ("Enter the 8-character code shown on your computer"), with a large, easy-to-read field for
       exactly 8 characters from the code alphabet (A-Z and 2-9 without I, O, 0, 1; accept lower case).
     - Immediate feedback: on a wrong code say so and let me retry without restarting anything; on success show
       "Paired" briefly and get out of the way. The host retries on its own, so the picture should appear by itself.
     - A way to forget the saved code and pair again later (for example a long-press on the status label), with a
       confirmation.
   Keep the cryptography, the key derivation and the wire protocol exactly as they are (hosts on both platforms
   depend on them); this is a UI and state change in the receiver only. Note the existing quirk that clearing the
   in-memory key did not clear the saved one; make "forget" really forget. Show me a screenshot of each state.

D. Bring the Windows side in line. Work through the inconsistency table in docs/windows-handoff.md: raise
   kRequiredAppVersion to 10 in windows-sender/src/main.cpp and REQUIRED_APP_VERSION (plus its comment) in
   installers/mac/build-dmg.sh (edit only; do not run that script on Windows); set versionName to match the project
   version; correct the README's Windows file names; check what the Windows host shows when the tablet has a
   different pairing code and make it say so clearly if it does not; decide with me whether the Windows launcher
   should remember all its settings like the Mac one. For anything in the table you decide not to change, tell me
   why. If you find other mismatches between the Windows host, the Mac host and the receiver, list them for me
   before fixing them.

E. Package and publish. Rebuild the Windows sender and installer as described in installers/windows/README.md.
   Update CHANGELOG.md and the docs that still say the receiver is v9 or source-only. Commit on a branch, open a
   pull request into `main`, and after I approve it, attach the receiver APK and the Windows installer to a GitHub
   release (the Mac DMG is on release v0.10.0; ask me whether to add to it or cut a new version). Do not commit
   APKs or other build outputs. Tell me the full path of app-release.apk so I can copy it to the Mac.

Rules:
  - Report what you ran and what you saw. If something was not tested, say so; never describe an untested change as
    working.
  - Find the cause before changing code when something fails; do not stack guesses.
  - Ask before anything that deletes data on the tablet, changes my pairing code, or pushes to `main` directly.
  - Do not change mac-host/ beyond the version gate in installers/mac/build-dmg.sh; if you think the Mac host needs
    a change, write it down for me instead.

Finish with a short report: what was wrong with the build (if anything), what you verified on the tablet and how,
what you could not verify, what you changed for consistency and what you left, the pull request link, and where
the APK and installer are.
```

## After Windows is done (back on the Mac)

1. `git pull` on `main`.
2. Copy `app-release.apk` over and rebuild the package:
   `EXTDISPLAY_INSTALL=1 ./installers/mac/build-dmg.sh /path/to/app-release.apk`. It is signed with the same
   certificate as before, so the permissions already granted keep working.
3. Start once over USB: the app installs v10 on the tablet if it is still on v9.
