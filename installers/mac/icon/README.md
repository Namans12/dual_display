`make-icon.swift` draws the app icon (CoreGraphics only) as a full-detail 1024 px PNG plus a bolder variant used for the 16/32/64 px sizes.
`build-icon.sh` runs it, makes every `.iconset` size with `sips` and builds `AppIcon.icns` with `iconutil` (no temp files left behind).
`AppIcon.icns` is the checked-in result, so packaging does not need to regenerate it.
Regenerate with `installers/mac/icon/build-icon.sh` (needs only the Command Line Tools), then commit the new `AppIcon.icns`.
