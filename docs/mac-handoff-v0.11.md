# Mac hand-off prompt (after v0.11.0 / DualSlate)

Paste everything below the line into Claude Code on the Mac, in a clone of
`Namans12/dual_display`.

---

You are working on DualSlate (formerly "Extended Display"): a Galaxy Tab S9 Ultra used as a
true extended display for a Windows PC or a Mac. Repo: this checkout of Namans12/dual_display.
Read README.md, CHANGELOG.md (the v0.11.0 entry), docs/mac.md and docs/protocol.md first.

## What changed on the Windows side (already done, verified on the tablet)
- The app is now named **DualSlate**. The tablet idle screen shows "DualSlate" with "Extended
  Display" beneath. The Android app label is DualSlate. The package id `com.heysnap.extdisplay`,
  versionCode **10** and versionName 0.11.0 are unchanged.
- The tablet app (receiver v10) was reworked:
  - immersive full screen;
  - a gradient idle screen and a new icon;
  - Forget pairing is a button on the idle screen;
  - the decoder is reused across connections;
  - touches on the idle screen are no longer sent to the computer.
- The wire protocol, pairing, KDF and nonce domains are unchanged (checked by an independent
  review).
- Decoder reuse needs each keyframe to be preceded by its parameter sets: SPS/PPS for H.264,
  VPS/SPS/PPS for HEVC. MacHost.swift's `AnnexBEncoder` already writes them before every keyframe.
- User-facing text uses plain hyphens, not em or en dashes.

## Known Mac items to fix (from the Windows session)
- **The Mac app still says "Extended Display".** Rename it to **DualSlate** everywhere a user sees
  it (task 2). That includes the installed application itself: the `.app` in /Applications,
  the name under its Dock icon, the menu bar title, and the DMG volume name must all read
  DualSlate. On Windows the app is now `DualSlate.exe` with "DualSlate" shortcuts.
- **Its pairing hint says the code box is "at the top".** The tablet now shows a centred code
  prompt, so the text must say that (task 3).
- **An APK built on the Mac won't install over the Windows-built one.** Each computer signs the
  tablet app with its own debug key. Don't uninstall the tablet app to get around it: that wipes
  the saved pairing. Copy the Windows debug key to the Mac first (see "APK signing" under Rules).
- **Upside-down landscape.** The tablet app now follows a 180-degree flip (sensorLandscape).
  Check that touch and the S Pen still land correctly with the tablet flipped, with the Mac
  host too.

## Tasks (in this order; report what you ran and what you saw; never call something untested "working")
1. **Compatibility check, no code changes.** Build and run the Mac app against the tablet with
   receiver v10 (0.11.0) installed. Check:
   - USB and Wi-Fi;
   - the picture appears, and Stop returns the tablet to the gradient idle screen with no
     frozen frame;
   - touch, the two-finger scroll and right-click;
   - S Pen pressure and hover;
   - desktop audio, if the Mac host has it;
   - encrypted pairing with a wrong code, the right code, and a saved code.
   If anything breaks, find the cause before changing code.
2. **Rename the Mac app to DualSlate:** the display name, the bundle display name, the window
   titles, the DMG name (`DualSlate-<version>.dmg`) and the README/docs/mac.md wording.
   - Keep the bundle identifier unless changing it is required. Changing it resets macOS
     privacy permissions (Screen Recording, Accessibility).
   - Use plain hyphens in user-facing text.
3. **Fix the stale pairing-mismatch text.** It says the code box is "at the top"; the tablet
   now shows a centred prompt.
4. **Versions in installers/mac/build-dmg.sh:** set APP_VERSION to 0.11.0. REQUIRED_APP_VERSION
   is already 10.
5. Build the DMG. Then, only after I approve, attach it to the GitHub release v0.11.0.
6. Update CHANGELOG.md (v0.11.0: the Mac section) and docs/mac.md.

## Rules
- Work on a branch and open a PR; never push to `main` directly.
- Ask before anything that deletes data on the tablet or changes my pairing code. Uninstalling
  the tablet app wipes the saved pairing key.
- **APK signing:** there is now one shared release key (docs/signing.md).
  - The build uses it automatically when `~/.dualslate/signing.properties` exists. I will copy
    my `.dualslate` folder from the Windows PC to `~/.dualslate/` on the Mac.
  - Before building an APK on the Mac, check the folder is there. Then check the result with
    `apksigner verify --print-certs`: it must say `CN=DualSlate`, not `CN=Android Debug`.
  - If `adb install -r` fails with INSTALL_FAILED_UPDATE_INCOMPATIBLE, do not uninstall to get
    around it: stop and ask me. Uninstalling wipes the saved pairing code.
- Do not commit build outputs (APK, DMG).
