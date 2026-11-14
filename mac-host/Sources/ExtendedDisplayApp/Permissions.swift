import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// The two privacy permissions the stream needs. Both are granted to THIS app
// (the "responsible process"); MacHost, as its child, is covered by the same
// grant — which is why the launcher, not MacHost, asks for them.
struct PermissionState: Equatable {
    var screenRecording: Bool   // capture the extended display
    var accessibility: Bool     // inject touch / pen as mouse events

    var allGranted: Bool { screenRecording && accessibility }
}

enum Permissions {
    // nil when run straight from .build/ (no bundle): macOS then attributes
    // the permissions to the terminal that launched us, so there is nothing
    // of ours to reset.
    static var bundleID: String? { Bundle.main.bundleIdentifier }

    static func current() -> PermissionState {
        PermissionState(screenRecording: CGPreflightScreenCaptureAccess(),
                        accessibility: AXIsProcessTrusted())
    }

    // macOS keeps one entry per app in each privacy list and matches it against
    // the app's signature. An entry left by a differently-signed build (an old
    // ad-hoc build, a copy run from another folder) still shows as switched on
    // but no longer applies — and while it exists macOS will not ask again.
    // So before asking, drop our own entry for that one permission. This only
    // runs when the permission is NOT currently effective, so nothing valid is lost.
    private static func clearStaleEntry(_ service: String) {
        guard let bundleID else { return }
        _ = runCommand("/usr/bin/tccutil", ["reset", service, bundleID], timeout: 10)
    }

    // Shows the system prompt ("…would like to record this computer's screen"),
    // which adds the app to the list; the user then switches it on. macOS only
    // applies the grant after the app is reopened.
    static func requestScreenRecording() {
        guard !CGPreflightScreenCaptureAccess() else { return }
        clearStaleEntry("ScreenCapture")
        _ = CGRequestScreenCaptureAccess()
    }

    static func requestAccessibility() {
        guard !AXIsProcessTrusted() else { return }
        clearStaleEntry("Accessibility")
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openPane(_ pane: String) {
        if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
    }

    // Screen Recording only takes effect in a fresh process.
    static func relaunch() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this instance to be gone, then open the bundle again.
        task.arguments = ["-c", "sleep 0.8; /usr/bin/open \"$1\"", "sh", Bundle.main.bundleURL.path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
