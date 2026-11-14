import Foundation

// adb helpers: locating the binary and interpreting its output. The process
// plumbing is in ProcessSupport.swift; the orchestration is in Session.swift.

enum AdbState: Equatable {
    case device, unauthorized, offline, none
}

// `adb get-state` prints "device" when a tablet is usable. When it isn't, the
// words differ by adb version ("error: device unauthorized.", "offline",
// "no devices/emulators found"), so match loosely.
func classifyAdbState(status: Int32, output: String) -> AdbState {
    let text = output.lowercased()
    if text.contains("unauthorized") { return .unauthorized }
    if text.contains("offline") { return .offline }
    if status == 0 && output.split(whereSeparator: \.isNewline).contains(where: { $0.trimmingCharacters(in: .whitespaces) == "device" }) {
        return .device
    }
    return .none
}

// First `versionCode=N` in `dumpsys package` output, like the old sed | head -1.
func parseVersionCode(_ dump: String) -> Int? {
    guard let re = try? NSRegularExpression(pattern: #"versionCode=(\d+)"#),
          let m = re.firstMatch(in: dump, range: NSRange(dump.startIndex..., in: dump)),
          let r = Range(m.range(at: 1), in: dump) else { return nil }
    return Int(dump[r])
}

// Bundled adb first (so the packaged app is self-contained), then PATH. A
// Finder-launched app gets a minimal PATH that lacks Homebrew and the Android
// SDK, so the usual install locations are searched as well.
func locateAdb(bundled: URL?, pathEnv: String, home: URL,
               isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
    if let bundled, isExecutable(bundled.path) { return bundled.path }
    var dirs = pathEnv.split(separator: ":").map(String.init)
    dirs += ["/opt/homebrew/bin", "/usr/local/bin",
             home.appendingPathComponent("Library/Android/sdk/platform-tools").path]
    for dir in dirs where !dir.isEmpty {
        let candidate = dir + "/adb"
        if isExecutable(candidate) { return candidate }
    }
    return nil
}
