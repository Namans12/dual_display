import CVDShim
import CoreGraphics
import Foundation

// Owns the native virtual display (private CGVirtualDisplay API via CVDShim).
//
// macOS 26 lifecycle (all verified on-machine): WindowServer reclaims a virtual
// display when its owning process EXITS — clean quit or kill, gone within a
// second. What does NOT remove it is releasing the object (or applySettings with
// nil/empty modes) while the process keeps running: it stays online as long as
// its owner lives. So MacHost just holds the display for the run and lets process
// exit be the teardown. If a fast restart finds a not-yet-reclaimed instance of
// our own display (matched by vendor/product id) it adopts it rather than making
// a duplicate. `--remove-display` (CGRestorePermanentDisplayConfiguration) is a
// safety valve if one ever lingers.
final class VirtualDisplay {
    // Galaxy Tab S9 Ultra: 2960x1848 (16:10) on a 14.6" panel, up to 120 Hz.
    // At 120 fps the display drops to 1920x1200 — the Windows host's measured
    // sweet spot: native-res 120 overruns the capture+encode+decode pipeline,
    // and the tablet upscales 16:10 cleanly.
    static let nativeWidth = 2960
    static let nativeHeight = 1848
    private static let vendorID: UInt32 = 0x3456
    private static let productID: UInt32 = 0x4544
    private static let sizeMm = CGSize(width: 314.6, height: 196.4)

    static func target(forFps fps: Int) -> (width: Int, height: Int, hz: Double) {
        fps >= 120 ? (1920, 1200, 120.0) : (nativeWidth, nativeHeight, 60.0)
    }

    let width: Int
    let height: Int
    let refreshHz: Double
    private let handle: NSObject?  // nil when adopted from an earlier run
    let displayID: CGDirectDisplayID
    let adopted: Bool

    init?(fps: Int) {
        let target = Self.target(forFps: fps)
        width = target.width
        height = target.height
        refreshHz = target.hz

        // Adopt a not-yet-reclaimed instance from a fast restart — but only if
        // it carries the mode this run needs (we can't applySettings on an
        // adopted display: no object handle).
        if let existing = Self.findExisting(),
           Self.hasMode(existing, width: width, height: height, hz: refreshHz) {
            handle = nil
            displayID = existing
            adopted = true
            return
        }
        guard let created = CVDCreate("Extended Display",
                                      UInt32(width), UInt32(height),
                                      refreshHz, Self.sizeMm, true) else {
            return nil
        }
        handle = created
        displayID = CVDDisplayID(created)
        adopted = false
    }

    private static func findExisting() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first {
            CGDisplayVendorNumber($0) == Self.vendorID &&
            CGDisplayModelNumber($0) == Self.productID
        }
    }

    private static func hasMode(_ id: CGDirectDisplayID, width: Int, height: Int, hz: Double) -> Bool {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] else {
            return false
        }
        return modes.contains {
            $0.pixelWidth == width && $0.pixelHeight == height &&
            abs($0.refreshRate - hz) < 0.5
        }
    }

    // The display registers with WindowServer asynchronously; capture needs it
    // online (and SCShareableContent must be fetched after that).
    func waitUntilOnline(timeoutSeconds: Double) async -> Bool {
        if adopted { return true }
        let deadline = Date(timeIntervalSinceNow: timeoutSeconds)
        while Date() < deadline {
            var ids = [CGDirectDisplayID](repeating: 0, count: 16)
            var count: UInt32 = 0
            if CGGetOnlineDisplayList(16, &ids, &count) == .success,
               ids.prefix(Int(count)).contains(displayID) {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    // macOS brings a fresh virtual display up mirrored (and can even make it
    // the main display). Turn it into a true extension: mirroring off,
    // positioned to the right of the built-in display (the Windows host places
    // its VDD the same way), session-scoped so logout reverts everything.
    // NEVER mirror a virtual display onto the main one — WindowServer matches
    // modes across the mirror set and can drop the built-in panel to the
    // virtual display's resolution (observed: built-in stuck at 320x240).
    func configureAsExtension() {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay)
        let anchor = CGDisplayBounds(CGMainDisplayID())
        CGConfigureDisplayOrigin(config, displayID,
                                 Int32(anchor.maxX.rounded()), Int32(anchor.minY.rounded()))
        CGCompleteDisplayConfiguration(config, .forSession)
    }

    // Ensures the active mode renders at the target pixel size and refresh,
    // preferring the HiDPI variant (points = pixels/2) so UI is readable on
    // the 14.6" panel while the framebuffer — what we capture — stays full-res.
    func selectNativeMode() {
        let current = CGDisplayCopyDisplayMode(displayID)
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
            return
        }
        let candidates = modes.filter {
            $0.pixelWidth == width && $0.pixelHeight == height &&
            abs($0.refreshRate - refreshHz) < 0.5
        }
        guard let best = candidates.first(where: { $0.width < $0.pixelWidth }) ?? candidates.first else {
            return
        }
        if let current, current.pixelWidth == best.pixelWidth, current.width == best.width,
           abs(current.refreshRate - best.refreshRate) < 0.5 {
            return  // already there
        }
        CGDisplaySetDisplayMode(displayID, best, nil)
    }

    // Escape hatch (`--remove-display`): rarely needed since process exit
    // reclaims the display, but if one ever lingers this restores the saved
    // permanent configuration — which clears session virtual displays (including
    // other apps') and session arrangement changes.
    static func removeAllSessionDisplays() {
        CGRestorePermanentDisplayConfiguration()
    }
}
