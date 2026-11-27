# Signing the tablet app with one shared key

Android only installs an update of an app if the new APK is signed with the **same key** as the
installed one. Until now every machine signed the APK with its own automatic debug key, so an
APK built on the Mac could not update one built on the Windows PC. The only way round was to
uninstall, which also deletes the saved pairing code.

The fix is one **release key** that every build machine uses.
- The key and its password live in a private folder, `~/.dualslate/`, **outside the repo**.
  Nothing secret is ever committed (`.gitignore` blocks `*.jks` and `signing.properties` too).
- `android-receiver/app/build.gradle` uses the key automatically when that folder exists.
  Without it, it falls back to the machine's debug key, as before.
  (Tested: with a throwaway key the APK was signed by that key; without the folder, by
  "Android Debug".)

## One-time setup (Windows, once)

1. Open PowerShell in the repo and run:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\android-receiver\make-signing-key.ps1
   ```
   It asks for a password twice. It creates `%USERPROFILE%\.dualslate\` containing:
   - `dualslate-release.jks`, the key;
   - `signing.properties`, its location and password, readable only by you.
   It then prints the key's SHA-256 fingerprint.
2. **Back up the whole `%USERPROFILE%\.dualslate` folder** somewhere safe, for example a
   password manager attachment or a USB stick, and keep the password with it. If the key is
   lost, future APKs can't update installed copies.
3. **Mac:** copy the folder to `~/.dualslate/` on the Mac, then run
   `chmod 700 ~/.dualslate && chmod 600 ~/.dualslate/*`. Mac builds then sign with the same key.

## The switch-over (once per tablet)

The tablet currently has a copy signed with the old debug key. The first APK signed with the
new key cannot install over it:
- the PC sender reports `INSTALL_FAILED_UPDATE_INCOMPATIBLE` and says what to do;
- the fix is to uninstall the old app once and install the new one;
- this **forgets the saved pairing code**, so type the code on the tablet once more.

From then on, every build from any machine with `~/.dualslate/` updates it cleanly.

People who installed the v0.11.0 APK from GitHub (debug-signed) need the same one-time
uninstall when they move to the first release signed with this key. Say so in that release's
notes.

## Check which key an APK has
```powershell
& "$env:LOCALAPPDATA\Android\Sdk\build-tools\<version>\apksigner.bat" verify --print-certs android-receiver\app\build\outputs\apk\release\app-release.apk
```
`CN=DualSlate` means the shared key; `CN=Android Debug` means the debug fallback.
