import Darwin
import Foundation

// Where things live, both inside the bundle (Contents/MacOS + Contents/Resources)
// and in the user's Library. Resolved from the executable path rather than
// Bundle.main so it also behaves when run straight out of .build/ during development.
struct AppPaths {
    let machHost: URL
    let resources: URL?   // nil when not running from a .app bundle

    var bundledAdb: URL? { resources?.appendingPathComponent("platform-tools/adb") }
    var apk: URL? { resources?.appendingPathComponent("ExtendedDisplayReceiver.apk") }

    static func resolve(executable: URL) -> AppPaths {
        let dir = executable.deletingLastPathComponent()
        let machHost = dir.appendingPathComponent("MacHost")
        var resources: URL?
        if dir.lastPathComponent == "MacOS", dir.deletingLastPathComponent().lastPathComponent == "Contents" {
            resources = dir.deletingLastPathComponent().appendingPathComponent("Resources")
        }
        return AppPaths(machHost: machHost, resources: resources)
    }

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    // Same locations the bash launcher used, so files carry over.
    static var supportDirectory: URL { home.appendingPathComponent("Library/Application Support/ExtendedDisplay") }
    static var legacyOptionsFile: URL { supportDirectory.appendingPathComponent("options") }
    static var logFile: URL { home.appendingPathComponent("Library/Logs/ExtendedDisplay.log") }
}

// Append-only log, shared by the launcher's own steps and the child's raw output.
// POSIX O_APPEND rather than FileHandle: no ObjC exceptions on a full disk.
final class LogFile {
    private let lock = NSLock()
    private var fd: Int32

    init(url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    }

    deinit { if fd >= 0 { close(fd) } }

    func write(_ line: String) {
        guard fd >= 0 else { return }
        let bytes = Array((line + "\n").utf8)
        lock.lock()
        _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        lock.unlock()
    }

    func note(_ message: String) { write("[launcher] \(message)") }
}
