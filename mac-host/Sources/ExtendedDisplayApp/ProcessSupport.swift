import Darwin
import Foundation

final class AtomicFlag {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

// Splits a byte stream into lines. Child output arrives in arbitrary chunks, so a
// line can straddle two reads; the tail is held back until its newline (or EOF).
struct LineSplitter {
    private var pending = Data()

    mutating func feed(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            lines.append(LineSplitter.decode(pending[pending.startIndex..<nl]))
            pending.removeSubrange(pending.startIndex...nl)
        }
        return lines
    }

    mutating func flush() -> String? {
        defer { pending.removeAll() }
        return pending.isEmpty ? nil : LineSplitter.decode(pending)
    }

    private static func decode(_ bytes: Data) -> String {
        var b = bytes
        if b.last == 0x0D { b.removeLast() }
        return String(decoding: b, as: UTF8.self)
    }
}

// Blocking reader on its own thread. The thread owns the Pipe: if a grandchild
// (adb's server daemon) keeps the write end open after the child exits, we stop
// waiting but the fd stays valid until that thread ends — closing it early could
// let the fd number be reused and read from the wrong file.
final class PipeReader {
    private let done = DispatchSemaphore(value: 0)

    init(pipe: Pipe, onData: @escaping (Data) -> Void) {
        let thread = Thread { [done] in
            let fd = pipe.fileHandleForReading.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n > 0 {
                    onData(Data(buffer[0..<n]))
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            done.signal()
        }
        thread.name = "child-output"
        thread.start()
    }

    @discardableResult
    func waitForEOF(timeout: TimeInterval) -> Bool {
        done.wait(timeout: .now() + timeout) == .success
    }
}

struct ChildExit: Equatable {
    var status: Int32
    var signaled: Bool
}

// The MacHost child: output streamed line by line, graceful stop with escalation.
final class HostProcess {
    private let process = Process()
    private let pipe = Pipe()
    private let exited = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var reader: PipeReader?
    private var splitter = LineSplitter()
    private let onLine: (String) -> Void
    private var stopRequested = false

    init(executable: URL, arguments: [String], environment: [String: String],
         onLine: @escaping (String) -> Void) {
        self.onLine = onLine
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
    }

    func start() throws {
        process.terminationHandler = { [exited] _ in exited.signal() }
        try process.run()
        // Our copy of the write end must close, or the reader never sees EOF.
        try? pipe.fileHandleForWriting.close()
        reader = PipeReader(pipe: pipe) { [weak self] data in
            guard let self else { return }
            // Only the reader thread touches the splitter until it hits EOF.
            for line in self.splitter.feed(data) { self.onLine(line) }
        }
    }

    var isRunning: Bool { process.isRunning }
    var processIdentifier: Int32 { process.processIdentifier }

    // SIGINT first: MacHost tears down cleanly (removes its virtual display,
    // un-mutes the Mac). Escalates to SIGTERM, then SIGKILL, if it doesn't exit.
    // Non-blocking and idempotent.
    func requestStop(termAfter: TimeInterval = 4, killAfter: TimeInterval = 3) {
        lock.lock()
        if stopRequested { lock.unlock(); return }
        stopRequested = true
        lock.unlock()
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        kill(pid, SIGINT)
        DispatchQueue.global().asyncAfter(deadline: .now() + termAfter) { [process] in
            guard process.isRunning else { return }
            kill(pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + killAfter) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    // Immediate SIGKILL: the last-resort path when the app itself is going away.
    func forceKill() {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    // Blocks until the child has exited and its output is fully delivered.
    func waitUntilExit() -> ChildExit {
        exited.wait()
        reader?.waitForEOF(timeout: 2)
        if let tail = splitter.flush() { onLine(tail) }
        return ChildExit(status: process.terminationStatus,
                         signaled: process.terminationReason == .uncaughtSignal)
    }
}

struct CommandResult {
    var status: Int32
    var output: String
    var timedOut = false
    var cancelled = false
}

// Runs a short helper (adb) to completion with a deadline and cooperative
// cancellation, so Stop works even while waiting on a missing tablet.
func runCommand(_ executable: String, _ arguments: [String], timeout: TimeInterval,
                cancel: AtomicFlag? = nil) -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do { try process.run() } catch {
        return CommandResult(status: -1, output: "\(error)")
    }
    try? pipe.fileHandleForWriting.close()

    let lock = NSLock()
    var collected = Data()
    let reader = PipeReader(pipe: pipe) { data in
        lock.lock(); collected.append(data); lock.unlock()
    }

    let deadline = Date().addingTimeInterval(timeout)
    var terminatedAt: Date?
    var result = CommandResult(status: 0, output: "")
    while exited.wait(timeout: .now() + 0.1) == .timedOut {
        if terminatedAt == nil {
            if cancel?.isSet == true { result.cancelled = true }
            else if Date() > deadline { result.timedOut = true }
            if result.cancelled || result.timedOut {
                process.terminate()
                terminatedAt = Date()
            }
        } else if Date().timeIntervalSince(terminatedAt!) > 1 {
            // Ignored SIGTERM is possible: SIG_IGN dispositions survive exec.
            kill(process.processIdentifier, SIGKILL)
        }
    }
    reader.waitForEOF(timeout: 1)
    result.status = process.terminationStatus
    lock.lock()
    result.output = String(decoding: collected, as: UTF8.self)
    lock.unlock()
    return result
}
