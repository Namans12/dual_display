import Foundation

enum SessionResult: Equatable {
    case stopped                 // the user asked for it
    case failed(HostStatus)      // couldn't prepare / MacHost reported an error
    case exited(Int32)           // MacHost ended on its own without an error line
}

struct SessionConfig {
    var settings: LauncherSettings
    var pairingCode: String?     // only set when encryption is on
    var extraArguments: [String]
    var paths: AppPaths
    var requiredAppVersion: Int  // receiver APK versionCode this host needs
    var adbPath: String?         // nil → locate (bundled, then PATH)
}

// One Start..Stop run: (USB only) adb preparation, then the MacHost child. All of
// it happens on a background thread so the UI never blocks; `emit` and `finished`
// are called from that thread.
final class LaunchSession {
    static let receiverPackage = "com.heysnap.extdisplay"
    static let receiverActivity = "com.heysnap.extdisplay/.MainActivity"

    private let config: SessionConfig
    private let log: LogFile
    private let emitStatus: (HostStatus) -> Void
    private let onFinished: (SessionResult) -> Void

    private let cancel = AtomicFlag()
    private var usbAdb: String?   // set once the USB path is prepared
    private let lock = NSLock()
    private var child: HostProcess?

    init(config: SessionConfig, log: LogFile,
         emit: @escaping (HostStatus) -> Void, finished: @escaping (SessionResult) -> Void) {
        self.config = config
        self.log = log
        self.emitStatus = emit
        self.onFinished = finished
    }

    func start() {
        let thread = Thread { [self] in
            let result = run()
            onFinished(result)
        }
        thread.name = "launch-session"
        thread.start()
    }

    // Non-blocking. During adb preparation it aborts the wait; once MacHost is
    // running it sends SIGINT and lets HostProcess escalate if needed.
    func stop() {
        cancel.set()
        lock.lock(); let c = child; lock.unlock()
        c?.requestStop()
    }

    func forceKill() {
        cancel.set()
        lock.lock(); let c = child; lock.unlock()
        c?.forceKill()
    }

    private func emit(_ status: HostStatus) {
        // Once Stop is pressed the UI shows "Stopping…"; late child lines mustn't overwrite it.
        if !cancel.isSet { emitStatus(status) }
    }

    private func working(_ text: String) { emit(.make(.working, text)) }

    private func pause(_ seconds: TimeInterval) {
        var left = seconds
        while left > 0 && !cancel.isSet { usleep(100_000); left -= 0.1 }
    }

    private func fail(_ text: String, hint: String? = nil) -> SessionResult {
        log.note("failed: \(text)")
        return .failed(.make(.error, text, hint: hint))
    }

    private func run() -> SessionResult {
        let s = config.settings
        let args = hostArguments(for: s, extra: config.extraArguments)
        log.write("=== Extended Display launch \(ISO8601DateFormatter().string(from: Date())) ===")
        log.note("MacHost arguments: \(args.joined(separator: " "))\(config.pairingCode != nil ? " (EXTDISPLAY_KEY set)" : "")")

        if s.connection == .usb {
            if let failure = prepareUsb() { return failure }
        }
        if cancel.isSet { return .stopped }

        guard FileManager.default.isExecutableFile(atPath: config.paths.machHost.path) else {
            return fail("MacHost was not found next to this app (\(config.paths.machHost.path)).")
        }

        // The code travels in the environment only; it must never reach argv,
        // where `ps` could show it. An ambient EXTDISPLAY_KEY is dropped so that
        // "Encrypt off" really means off.
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "EXTDISPLAY_KEY")
        if let code = config.pairingCode { env["EXTDISPLAY_KEY"] = code }

        var parser = HostStatusParser(modeLabel: modeLabel(for: s))
        let parserLock = NSLock()
        let host = HostProcess(executable: config.paths.machHost, arguments: args, environment: env) { [self] line in
            log.write(line)
            parserLock.lock()
            let changed = parser.consume(line)
            let status = parser.status
            parserLock.unlock()
            if changed { emit(status) }
        }
        working("Starting…  (\(modeLabel(for: s)))")
        do { try host.start() } catch {
            return fail("Couldn't start MacHost: \(error.localizedDescription)")
        }
        log.note("MacHost started (pid \(host.processIdentifier))")

        lock.lock(); child = host; lock.unlock()
        if cancel.isSet { host.requestStop() }  // Stop raced the launch

        let exit = host.waitUntilExit()
        lock.lock(); child = nil; lock.unlock()
        closeReceiver()
        log.note("MacHost exited: status \(exit.status)\(exit.signaled ? " (signal)" : "")")

        if cancel.isSet { return .stopped }
        parserLock.lock(); let last = parser.status; parserLock.unlock()
        if last.line.kind == .error { return .failed(last) }
        return .exited(exit.status)
    }

    // The stream is over. Receivers up to v9 keep showing the last frame, which
    // looks like a frozen desktop, so over USB close the tablet app (the next
    // Start opens it again). Over Wi-Fi there is no adb; the tablet app has to
    // stay open to be found, and from v10 it blanks its own screen instead.
    private func closeReceiver() {
        guard config.settings.connection == .usb, let adb = usbAdb else { return }
        _ = runCommand(adb, ["shell", "am", "force-stop", Self.receiverPackage], timeout: 10)
    }

    // Returns nil when the tablet is ready, or the terminal result. Mirrors the
    // old bash launcher step for step.
    private func prepareUsb() -> SessionResult? {
        let paths = config.paths
        let adb = config.adbPath ?? locateAdb(bundled: paths.bundledAdb,
                                              pathEnv: ProcessInfo.processInfo.environment["PATH"] ?? "",
                                              home: AppPaths.home)
        guard let adb else {
            return fail("adb was not found.",
                        hint: "Install Android platform-tools (brew install android-platform-tools) or use the packaged app.")
        }
        log.note("adb: \(adb)")
        usbAdb = adb

        // 1. Wait for an authorised tablet.
        var lastState: AdbState?
        while !cancel.isSet {
            let r = runCommand(adb, ["get-state"], timeout: 20, cancel: cancel)
            if cancel.isSet { return .stopped }
            let state = classifyAdbState(status: r.status, output: r.output)
            if state == .device { break }
            if state != lastState {
                lastState = state
                switch state {
                case .unauthorized:
                    emit(.make(.warn, "Tablet found but not authorised.",
                               hint: "Accept the \"Allow USB debugging\" prompt on the tablet."))
                case .offline:
                    emit(.make(.warn, "Tablet is offline.", hint: "Unplug and replug the USB cable."))
                default:
                    emit(.make(.warn, "Waiting for tablet over USB. Enable USB debugging.",
                               hint: "Settings > Developer options > USB debugging, then plug the tablet in."))
                }
                log.note("adb get-state: \(state) \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            pause(2)
        }
        if cancel.isSet { return .stopped }

        // 2. Install / upgrade the receiver when missing or older than this host needs.
        let dump = runCommand(adb, ["shell", "dumpsys", "package", Self.receiverPackage], timeout: 30, cancel: cancel)
        if cancel.isSet { return .stopped }
        let installed = parseVersionCode(dump.output)
        if installed == nil || installed! < config.requiredAppVersion {
            if let apk = paths.apk, FileManager.default.fileExists(atPath: apk.path) {
                working("Installing the receiver app on the tablet…")
                log.note("installing receiver (installed: \(installed.map(String.init) ?? "none"), need \(config.requiredAppVersion))")
                let r = runCommand(adb, ["install", "-r", apk.path], timeout: 180, cancel: cancel)
                if cancel.isSet { return .stopped }
                log.note("adb install: \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))")
                if r.status != 0 {
                    // An older receiver may still work; with none installed there is nothing to stream to.
                    if installed == nil {
                        return fail("Installing the receiver app failed.",
                                    hint: "Check the tablet for an install prompt, or sideload ExtendedDisplayReceiver.apk.")
                    }
                }
            } else if installed == nil {
                return fail("The receiver app isn't installed on the tablet and no APK is bundled.")
            } else {
                log.note("receiver is older than required but no APK is bundled; continuing")
            }
        }

        // 3. Ports and the receiver activity.
        working("Setting up the USB connection…")
        for port in Ports.usbForwards {
            let r = runCommand(adb, ["forward", "tcp:\(port)", "tcp:\(port)"], timeout: 20, cancel: cancel)
            if cancel.isSet { return .stopped }
            if r.status != 0 {
                return fail("adb couldn't forward port \(port).",
                            hint: r.output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        // Restart the receiver rather than just raising it: receivers up to v9
        // choose their decoder once and keep it, so after switching H.264 <->
        // HEVC here the tablet showed no picture until the app was restarted
        // (measured). The saved pairing key survives a force-stop.
        _ = runCommand(adb, ["shell", "am", "force-stop", Self.receiverPackage], timeout: 20, cancel: cancel)
        if cancel.isSet { return .stopped }
        let start = runCommand(adb, ["shell", "am", "start", "-n", Self.receiverActivity], timeout: 20, cancel: cancel)
        if cancel.isSet { return .stopped }
        if start.status != 0 { log.note("am start: \(start.output)") }
        pause(1.5)  // let the receiver bind its listeners before MacHost connects
        return nil
    }
}
