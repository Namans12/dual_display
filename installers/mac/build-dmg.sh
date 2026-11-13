#!/bin/bash
# Builds ExtendedDisplay.dmg — run this ON A MAC (needs Xcode CLT + hdiutil).
#
#   ./build-dmg.sh [path-to-ExtendedDisplayReceiver.apk]
#
# Environment:
#   EXTDISPLAY_SIGN_IDENTITY  code-signing identity (default: "Extended Display
#                             Self-Signed", created by make-signing-cert.sh).
#                             Falls back to ad-hoc signing, with a warning, if
#                             the identity is not in the keychain.
#   EXTDISPLAY_INSTALL=1      also install the built app into /Applications.
#
# Produces dist/ExtendedDisplay-<version>.dmg containing ExtendedDisplay.app:
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
APP_VERSION="0.10.0"

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
cp "$SCRIPT_DIR/icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

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
    <key>CFBundleIconFile</key><string>AppIcon</string>
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

# Sign with the stable self-signed identity when it exists. macOS matches a
# privacy grant (Screen Recording, Accessibility, Local Network) against the
# app's signature: with one certificate every build is the same app to macOS, so
# a grant survives updates and each privacy list has a single entry. An ad-hoc
# signature is tied to the exact build — every rebuild then leaves a dead entry
# that still shows as switched on. Gatekeeper treats both the same (right-click >
# Open on first run); only notarization with a paid Developer ID changes that.
SIGN_IDENTITY="${EXTDISPLAY_SIGN_IDENTITY:-Extended Display Self-Signed}"
if security find-certificate -c "$SIGN_IDENTITY" >/dev/null 2>&1; then
    echo "Signing with \"$SIGN_IDENTITY\"..."
    codesign --force --deep --timestamp=none -s "$SIGN_IDENTITY" "$APP"
else
    echo "WARNING: signing identity \"$SIGN_IDENTITY\" not found — ad-hoc signing instead." >&2
    echo "         Permissions granted to this build will NOT carry over to the next one." >&2
    echo "         Run installers/mac/make-signing-cert.sh once to create the identity." >&2
    codesign --force --deep -s - "$APP"
fi
codesign --verify --deep --strict "$APP"

# 5. DMG
mkdir -p "$DIST"
ln -sfn /Applications "$STAGING/Applications"
DMG="$DIST/$APP_NAME-$APP_VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Extended Display" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null

# 6. Optional local install (replaces an existing copy; quit it first).
if [[ "${EXTDISPLAY_INSTALL:-0}" == "1" ]]; then
    pkill -x ExtendedDisplay 2>/dev/null && sleep 2 || true
    rm -rf "/Applications/$APP_NAME.app"
    ditto "$APP" "/Applications/$APP_NAME.app"
    echo "Installed /Applications/$APP_NAME.app"
fi

# The DMG is the only artifact: a second ExtendedDisplay.app left in staging
# shows up twice in Launchpad, Spotlight and the privacy panes' "+" picker.
rm -rf "$STAGING"

echo "Done: $DMG"
echo "First launch: right-click > Open, then use the app's \"Permissions needed\" list."
