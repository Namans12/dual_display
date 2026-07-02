#!/bin/bash
# Builds ExtendedDisplay.dmg — run this ON A MAC (needs Xcode CLT + hdiutil).
#
#   ./build-dmg.sh [path-to-ExtendedDisplayReceiver.apk]
#
# Produces dist/ExtendedDisplay.dmg containing ExtendedDisplay.app:
#   - MacHost (ScreenCaptureKit + VideoToolbox sender)
#   - a launcher that automates adb (install app, forward port, start activity)
#   - the Android receiver APK + darwin platform-tools (downloaded)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
APP_NAME="ExtendedDisplay"
STAGING="$SCRIPT_DIR/staging"
DIST="$SCRIPT_DIR/dist"
APP="$STAGING/$APP_NAME.app"

# 1. Receiver APK
APK="${1:-}"
if [[ -z "$APK" ]]; then
    for candidate in \
        "$REPO_ROOT/android-receiver/app/build/outputs/apk/release/app-release.apk" \
        "$REPO_ROOT/android-receiver/app/build/outputs/apk/debug/app-debug.apk"; do
        [[ -f "$candidate" ]] && APK="$candidate" && break
    done
fi
if [[ -z "$APK" || ! -f "$APK" ]]; then
    echo "error: receiver APK not found; build it (gradlew :app:assembleRelease) or pass its path" >&2
    exit 1
fi
# Absolute path: the build cd's into mac-host/ below, which would break a
# relative APK argument at the copy step.
APK="$(cd "$(dirname "$APK")" && pwd)/$(basename "$APK")"

# 2. Build MacHost
echo "Building MacHost (release)..."
cd "$REPO_ROOT/mac-host"
swift build -c release
MACHOST_BIN="$(swift build -c release --show-bin-path)/MacHost"
[[ -x "$MACHOST_BIN" ]] || { echo "error: MacHost binary missing" >&2; exit 1; }

# 3. darwin platform-tools (adb)
PT_CACHE="$SCRIPT_DIR/.cache/platform-tools"
if [[ ! -x "$PT_CACHE/adb" ]]; then
    echo "Downloading platform-tools for macOS..."
    mkdir -p "$SCRIPT_DIR/.cache"
    curl -fsSL -o "$SCRIPT_DIR/.cache/pt.zip" \
        "https://dl.google.com/android/repository/platform-tools-latest-darwin.zip"
    unzip -qo "$SCRIPT_DIR/.cache/pt.zip" -d "$SCRIPT_DIR/.cache"
    rm -f "$SCRIPT_DIR/.cache/pt.zip"
fi

# 4. Assemble the .app bundle
echo "Assembling $APP_NAME.app..."
rm -rf "$STAGING"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$MACHOST_BIN" "$APP/Contents/MacOS/MacHost"
cp "$APK" "$APP/Contents/Resources/ExtendedDisplayReceiver.apk"
cp -R "$PT_CACHE" "$APP/Contents/Resources/platform-tools"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.heysnap.extdisplay.host</string>
    <key>CFBundleName</key><string>Extended Display</string>
    <key>CFBundleExecutable</key><string>ExtendedDisplay</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.9.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
PLIST

# Launcher: adb plumbing, then MacHost. Logs to ~/Library/Logs since Finder
# launches have no terminal.
cat > "$APP/Contents/MacOS/ExtendedDisplay" <<'LAUNCHER'
#!/bin/bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RES="$DIR/../Resources"
LOG="$HOME/Library/Logs/ExtendedDisplay.log"
exec >> "$LOG" 2>&1
echo "=== Extended Display launch $(date) ==="

ADB="$RES/platform-tools/adb"
command -v adb >/dev/null 2>&1 && ADB="$(command -v adb)"

echo "Waiting for tablet over USB (enable USB debugging)..."
until [[ "$("$ADB" get-state 2>/dev/null)" == "device" ]]; do sleep 2; done

# Install the receiver if missing, or update it when older than the version
# this host needs (v9: touch server re-accepts a reconnecting host immediately).
REQUIRED_APP_VERSION=9
INSTALLED=$("$ADB" shell dumpsys package com.heysnap.extdisplay 2>/dev/null \
    | sed -n 's/.*versionCode=\([0-9]*\).*/\1/p' | head -1)
if [[ -z "$INSTALLED" || "$INSTALLED" -lt "$REQUIRED_APP_VERSION" ]]; then
    echo "Installing receiver app (installed: ${INSTALLED:-none})..."
    "$ADB" install -r "$RES/ExtendedDisplayReceiver.apk"
fi
"$ADB" forward tcp:5000 tcp:5000
"$ADB" forward tcp:5001 tcp:5001    # touch uplink (tablet -> Mac input)
"$ADB" forward tcp:5003 tcp:5003    # desktop audio (only used with --audio)
"$ADB" shell am start -n com.heysnap.extdisplay/.MainActivity
sleep 1.5

# Settings without a GUI (parity with the Windows GUI's persisted state):
#   pairing.code — the 8-char pairing code; exported as EXTDISPLAY_KEY so the
#                  stream is encrypted (never passed on the command line).
#   options      — extra MacHost arguments, e.g.: --audio --mute-local --fps 120
CFG="$HOME/Library/Application Support/ExtendedDisplay"
if [[ -s "$CFG/pairing.code" ]]; then
    EXTDISPLAY_KEY="$(head -1 "$CFG/pairing.code" | tr -d '[:space:]')"
    export EXTDISPLAY_KEY
    echo "Pairing code loaded from pairing.code — link will be encrypted."
fi
EXTRA_ARGS=()
if [[ -s "$CFG/options" ]]; then
    # shellcheck disable=SC2207
    EXTRA_ARGS=($(head -1 "$CFG/options"))
    echo "Extra options: ${EXTRA_ARGS[*]}"
fi

exec "$DIR/MacHost" --host 127.0.0.1 --port 5000 "${EXTRA_ARGS[@]}"
LAUNCHER
chmod +x "$APP/Contents/MacOS/ExtendedDisplay" "$APP/Contents/MacOS/MacHost"

# Ad-hoc sign so Gatekeeper treats the bundle consistently (right-click > Open on first run).
codesign --force --deep -s - "$APP"

# 5. DMG
mkdir -p "$DIST"
ln -sfn /Applications "$STAGING/Applications"
rm -f "$DIST/$APP_NAME.dmg"
hdiutil create -volname "Extended Display" -srcfolder "$STAGING" -ov -format UDZO \
    "$DIST/$APP_NAME.dmg"
echo "Done: $DIST/$APP_NAME.dmg"
echo "Note: macOS will ask for Screen Recording permission on first capture."
