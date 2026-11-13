#!/bin/bash
# Builds ExtendedDisplay.dmg — run this ON A MAC (needs Xcode CLT + hdiutil).
#
#   ./build-dmg.sh [path-to-ExtendedDisplayReceiver.apk]
#
# Produces dist/ExtendedDisplay.dmg containing ExtendedDisplay.app:
#   - ExtendedDisplay (the native settings/launcher window; Contents/MacOS/ExtendedDisplay)
#     which automates adb (install app, forward ports, start activity) and runs...
#   - MacHost (ScreenCaptureKit + VideoToolbox sender), as a child process
#   - the Android receiver APK + darwin platform-tools (downloaded)
set -euo pipefail

# Receiver APK versionCode this host needs (v9: the touch server re-accepts a
# reconnecting host immediately). Single source of truth: written into
# Info.plist as EDRequiredAppVersion, which the launcher reads at run time to
# decide whether to install/upgrade the bundled APK on the tablet.
REQUIRED_APP_VERSION=9
APP_VERSION="0.9.0"

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

# 2. Build MacHost and the launcher GUI (one SwiftPM package, two products)
echo "Building MacHost + launcher (release)..."
cd "$REPO_ROOT/mac-host"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
MACHOST_BIN="$BIN_DIR/MacHost"
GUI_BIN="$BIN_DIR/ExtendedDisplayApp"
[[ -x "$MACHOST_BIN" ]] || { echo "error: MacHost binary missing" >&2; exit 1; }
[[ -x "$GUI_BIN" ]] || { echo "error: ExtendedDisplayApp binary missing" >&2; exit 1; }

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

cp "$GUI_BIN" "$APP/Contents/MacOS/ExtendedDisplay"
cp "$MACHOST_BIN" "$APP/Contents/MacOS/MacHost"
cp "$APK" "$APP/Contents/Resources/ExtendedDisplayReceiver.apk"
cp -R "$PT_CACHE" "$APP/Contents/Resources/platform-tools"

# Unquoted heredoc on purpose: only $APP_VERSION / $REQUIRED_APP_VERSION expand.
#  - NSPrincipalClass / NSHighResolutionCapable: a normal windowed AppKit app.
#  - NSSupportsSuddenTermination / AutomaticTermination off: macOS must not kill
#    the app without letting it stop MacHost first (no orphaned virtual display).
#  - NSLocalNetworkUsageDescription: the text of macOS 15's Local Network prompt,
#    which MacHost's Wi-Fi connections trigger (attributed to this app).
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleIdentifier</key><string>com.heysnap.extdisplay.host</string>
    <key>CFBundleName</key><string>Extended Display</string>
    <key>CFBundleDisplayName</key><string>Extended Display</string>
    <key>CFBundleExecutable</key><string>ExtendedDisplay</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
    <key>CFBundleVersion</key><string>$APP_VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSLocalNetworkUsageDescription</key><string>Extended Display connects to the tablet on your local network.</string>
    <key>EDRequiredAppVersion</key><integer>$REQUIRED_APP_VERSION</integer>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

chmod +x "$APP/Contents/MacOS/ExtendedDisplay" "$APP/Contents/MacOS/MacHost"

# Fail the build here, not on a user's Mac, if the launcher's own logic is broken
# (argument mapping, pairing file, status parsing; touches no tablet and no stream).
"$APP/Contents/MacOS/ExtendedDisplay" --selftest

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
