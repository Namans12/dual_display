import AppKit
import Foundation

// "Uninstall Extended Display…": dragging a Mac app to the Trash leaves its
// privacy entries (Screen Recording, Accessibility, Local Network, System
// Audio), preferences, pairing code and log behind — the entries keep showing
// in System Settings for an app that no longer exists. This removes all of it.
//
// Everything happens in this process, before it exits. (A detached clean-up
// script was tried first: launched from the real app it was killed the moment
// the app quit, so nothing got removed.)
enum Uninstaller {
    // Everything of ours outside the bundle, relative to the home directory.
    // The preferences plist is handled through the defaults system, not as a file.
    static func leftovers(bundleID: String) -> [String] {
        [
            "Library/Application Support/ExtendedDisplay",
            "Library/Logs/ExtendedDisplay.log",
            "Library/Saved Application State/\(bundleID).savedState",
            "Library/Caches/\(bundleID)",
            "Library/HTTPStorages/\(bundleID)",
        ]
    }

    // Reverse-DNS characters only: the id is passed to tccutil and used in paths.
    static func isSafeBundleID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 155 && !id.hasPrefix(".") && !id.contains("..") &&
        id.unicodeScalars.allSatisfy {
            ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x41 && $0.value <= 0x5A) ||
            ($0.value >= 0x61 && $0.value <= 0x7A) || $0 == "." || $0 == "-"
        }
    }

    // Returns a message when it cannot proceed; on success it does not return
    // (the process exits). Call with no session running.
    @MainActor
    static func run() -> String? {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app", let bundleID = Bundle.main.bundleIdentifier,
              isSafeBundleID(bundleID) else {
            return "Uninstall only works from the installed app (this copy isn't an app bundle)."
        }
        let fm = FileManager.default
        // Check we can actually remove the app before touching anything else,
        // so a failure leaves a working, still-configured app behind.
        guard fm.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path) else {
            return "Can't remove the app from \(bundleURL.deletingLastPathComponent().path). " +
                   "Drag it to the Trash yourself; nothing was changed."
        }

        // 1. Privacy entries — while macOS still knows this bundle id (tccutil
        //    refuses an id whose app is already gone).
        _ = runCommand("/usr/bin/tccutil", ["reset", "All", bundleID], timeout: 15)

        // 2. The app itself.
        do {
            try fm.trashItem(at: bundleURL, resultingItemURL: nil)
        } catch {
            return "Couldn't move the app to the Trash: \(error.localizedDescription). " +
                   "Its permissions were reset; drag it to the Trash yourself."
        }

        // 3. Settings, pairing code, log, caches.
        for path in leftovers(bundleID: bundleID) {
            try? fm.removeItem(at: AppPaths.home.appendingPathComponent(path))
        }
        // Preferences last, three ways: clearing the domain from inside the app
        // left an empty plist on disk (measured), so also go through the
        // `defaults` tool and then delete the file itself.
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        UserDefaults.standard.synchronize()
        _ = runCommand("/usr/bin/defaults", ["delete", bundleID], timeout: 10)
        // The defaults system can leave an empty plist behind; remove the file too.
        try? fm.removeItem(at: AppPaths.home.appendingPathComponent("Library/Preferences/\(bundleID).plist"))

        // 4. Leave at once and without running any exit handlers: AppKit's
        //    normal quit would save the window position and recreate the
        //    preferences we just removed.
        _exit(0)
    }
}
