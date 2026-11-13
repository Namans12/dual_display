#!/bin/bash
# Regenerates AppIcon.icns from make-icon.swift. Safe to re-run; leaves no temp files behind.
# Usage: installers/mac/icon/build-icon.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/appicon.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"

swift "$HERE/make-icon.swift" "$WORK"
MASTER="$WORK/icon-1024.png"
SMALL="$WORK/icon-small-1024.png"   # bolder variant for tiny sizes

# name:pixels for every file an .iconset needs.
for spec in \
    icon_16x16:16 icon_16x16@2x:32 \
    icon_32x32:32 icon_32x32@2x:64 \
    icon_128x128:128 icon_128x128@2x:256 \
    icon_256x256:256 icon_256x256@2x:512 \
    icon_512x512:512 icon_512x512@2x:1024; do
    name="${spec%%:*}"; px="${spec##*:}"
    src="$MASTER"; [ "$px" -le 64 ] && src="$SMALL"
    sips -z "$px" "$px" "$src" --out "$ICONSET/$name.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$HERE/AppIcon.icns"
echo "wrote $HERE/AppIcon.icns"
