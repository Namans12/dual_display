import CVDShim
import CoreGraphics
import Foundation

// Owns the native virtual display (private CGVirtualDisplay API via CVDShim).
//
// macOS 26 lifecycle reality (all verified on-machine): once created, a virtual
// display cannot be individually removed — releasing the object, process exit,
// and applySettings with nil/empty modes all leave it online. Only
// CGRestorePermanentDisplayConfiguration() clears session virtual displays, and
// that resets every session display change (including other apps'). So instead
// of create/destroy per run, MacHost adopts an existing instance of its own
// display (matched by vendor/product id) when one survives from an earlier run,
// and on graceful stop parks it corner-adjacent to the desktop where the cursor
// cannot wander into it. Logout (WindowServer restart) removes it for real;
// `--remove-display` is the explicit escape hatch.
final class VirtualDisplay {
    // Galaxy Tab S9 Ultra: 2960x1848 (16:10) on a 14.6" panel.
    static let width = 2960
    static let height = 1848
    static let refreshHz = 60.0
    private static let vendorID: UInt32 = 0x3456
    private static let productID: UInt32 = 0x4544
    private static let sizeMm = CGSize(width: 314.6, height: 196.4)

    private let handle: NSObject?  // nil when adopted from an earlier run
    let displayID: CGDirectDisplayID
    let adopted: Bool

    init?() {
        if let existing = Self.findExisting() {
            handle = nil
            displayID = existing
            adopted = true
            return
        }
        guard let created = CVDCreate("Extended Display",
                                      UInt32(Self.width), UInt32(Self.height),
                                      Self.refreshHz, Self.sizeMm, true) else {
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

    // Ensures the active mode renders at native tablet pixels (2960x1848),
    // preferring the HiDPI variant (1480x924 points @2x) so UI is readable on
    // the 14.6" panel while the framebuffer — what we capture — stays native.
    func selectNativeMode() {
        let current = CGDisplayCopyDisplayMode(displayID)
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
            return
        }
        let candidates = modes.filter { $0.pixelWidth == Self.width && $0.pixelHeight == Self.height }
        guard let best = candidates.first(where: { $0.width < $0.pixelWidth }) ?? candidates.first else {
            return
        }
        if let current, current.pixelWidth == best.pixelWidth, current.width == best.width {
            return  // already there
        }
        CGDisplaySetDisplayMode(displayID, best, nil)
    }

    // Parks the (unremovable) display diagonally at the desktop's bottom-right
    // corner: with no shared edge the cursor cannot cross into it while idle.
    // The next run adopts it and moves it back beside the desktop.
    func parkInactive() {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        let anchor = CGDisplayBounds(CGMainDisplayID())
        CGConfigureDisplayOrigin(config, displayID,
                                 Int32(anchor.maxX.rounded()), Int32(anchor.maxY.rounded()))
        CGCompleteDisplayConfiguration(config, .forSession)
    }

    // Escape hatch (`--remove-display`): macOS 26 offers no per-display removal,
    // so this restores the saved permanent configuration — which clears session
    // virtual displays (including other apps') and session arrangement changes.
    static func removeAllSessionDisplays() {
        CGRestorePermanentDisplayConfiguration()
    }
}
