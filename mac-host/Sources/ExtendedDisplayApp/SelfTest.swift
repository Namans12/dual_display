import Foundation

// Pure-logic and child-process checks, runnable with `--selftest`. Touches only
// temp files and a throwaway UserDefaults suite — never the real pairing.code,
// the real log, adb, or MacHost.
func runSelfTests() -> Int32 {
    var failures = 0
    func expect(_ condition: Bool, _ label: String) {
        if !condition {
            print("selftest FAIL: \(label)")
            failures += 1
        }
    }
    func args(_ s: LauncherSettings, extra: [String] = []) -> [String] { hostArguments(for: s, extra: extra) }

    // ---- UI state -> MacHost arguments ----
    var s = LauncherSettings()
    expect(args(s) == ["--host", "127.0.0.1", "--port", "5000"], "default = USB balanced, touch on")

    s.quality = .best
    expect(args(s) == ["--host", "127.0.0.1", "--port", "5000", "--bitrate", "40000000"], "best = 40 Mbps in bits/s")
    s.quality = .fast
    expect(args(s) == ["--host", "127.0.0.1", "--port", "5000", "--width", "1920", "--height", "1200"], "fastest response = 1920x1200 capture")
    expect(QualityPreset(rawValue: "smooth") == .fast, "a saved 'smooth' choice maps to fastest response")
    s.quality = .balanced

    s.touch = false; s.hevc = true
    expect(args(s) == ["--host", "127.0.0.1", "--port", "5000", "--no-touch", "--hevc"], "touch off + hevc")
    s = LauncherSettings()

    s.lowLatencyUDP = true
    expect(!args(s).contains("--udp"), "UDP is ignored over USB (adb can't forward UDP)")
    s.connection = .wifi
    expect(args(s) == ["--wifi", "--udp"], "Wi-Fi + blank IP = --wifi, UDP honoured")
    s.tabletIP = "  192.168.1.50 "
    expect(args(s) == ["--host", "192.168.1.50", "--udp"], "Wi-Fi + IP = --host <ip> (trimmed), no --wifi")
    s.lowLatencyUDP = false
    s.tabletIP = ""
    expect(args(s) == ["--wifi"], "Wi-Fi plain")

    s = LauncherSettings()
    s.audio = true
    expect(args(s) == ["--host", "127.0.0.1", "--port", "5000", "--audio", "--audio-delay-ms", "40"], "audio default delay")
    s.muteLocal = true; s.audioDelayMs = 120
    expect(args(s) == ["--host", "127.0.0.1", "--port", "5000", "--audio", "--audio-delay-ms", "120", "--mute-local"], "audio + mute + delay")
    s.audioDelayMs = 9_999
    expect(args(s).contains("500"), "delay clamped to 500")
    s.audioDelayMs = 1
    expect(args(s).contains("20"), "delay clamped to 20")
    s.audio = false
    expect(!args(s).contains("--mute-local") && !args(s).contains("--audio-delay-ms"), "mute/delay need audio")

    s = LauncherSettings()
    s.encrypt = true
    expect(args(s) == ["--host", "127.0.0.1", "--port", "5000"],
           "encrypt adds no argument (the code goes via the environment)")
    expect(args(s, extra: ["--fps", "30"]).suffix(2) == ["--fps", "30"], "legacy options go last")

    // ---- legacy options file ----
    expect(parseLegacyOptions("--audio --mute-local --fps 120\n") == ["--audio", "--mute-local", "--fps", "120"], "legacy options split")
    expect(parseLegacyOptions("--audio\nsecond line ignored\n") == ["--audio"], "legacy options: first line only")
    expect(parseLegacyOptions("") == [] && parseLegacyOptions("\n") == [], "empty legacy options")
    expect(parseLegacyOptions("  --a \t --b\r\n") == ["--a", "--b"], "legacy options whitespace")

    // ---- address validation ----
    expect(isValidTabletAddress("192.168.1.50") && isValidTabletAddress("tablet.local") && isValidTabletAddress("fe80::1"), "valid addresses")
    expect(!isValidTabletAddress("") && !isValidTabletAddress("--hevc") && !isValidTabletAddress("1.2.3.4 --audio") && !isValidTabletAddress("a/b"), "invalid addresses")
    s = LauncherSettings(); s.connection = .wifi; s.tabletIP = "not an ip"
    expect(settingsProblem(s) != nil, "bad IP blocks Start")
    s.connection = .usb
    expect(settingsProblem(s) == nil, "IP is ignored over USB")
    s.connection = .wifi; s.tabletIP = ""
    expect(settingsProblem(s) == nil, "blank IP is fine")

    // ---- uninstall clean-up ----
    let leftovers = Uninstaller.leftovers(bundleID: "com.heysnap.extdisplay.host")
    expect(leftovers.contains("Library/Application Support/ExtendedDisplay"), "uninstall removes the support folder (pairing code)")
    expect(leftovers.contains("Library/Logs/ExtendedDisplay.log"), "uninstall removes the log")
    expect(leftovers.allSatisfy { $0.hasPrefix("Library/") && !$0.contains("..") && $0.count > "Library/".count },
           "uninstall paths stay inside ~/Library and are never a bare folder")
    expect(Uninstaller.isSafeBundleID("com.heysnap.extdisplay.host"), "normal bundle id accepted")
    expect(!Uninstaller.isSafeBundleID("x'; rm -rf ~; '") && !Uninstaller.isSafeBundleID("") &&
           !Uninstaller.isSafeBundleID("../..") && !Uninstaller.isSafeBundleID("a/b"),
           "unsafe bundle ids are rejected")

    // ---- pairing code generation ----
    var seen = Set<String>()
    var alphabetOK = true
    for _ in 0..<2000 {
        let c = PairingStore.generateCode()
        seen.insert(c)
        if c.count != 8 || !c.allSatisfy({ PairingStore.alphabet.contains($0) }) { alphabetOK = false }
    }
    expect(alphabetOK, "codes are 8 chars from the alphabet")
    expect(PairingStore.alphabet.count == 32 && !PairingStore.alphabet.contains(where: { "IO01".contains($0) }), "alphabet excludes I/O/0/1")
    expect(seen.count > 1990, "codes are random")
    var fixed = SystemRandomNumberGenerator()
    _ = PairingStore.generateCode(using: &fixed)

    // ---- pairing file ----
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("extdisplay-selftest-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let store = PairingStore(directory: tmp.appendingPathComponent("ExtendedDisplay"))
    expect(store.load() == nil, "no file → no code")
    var created = ""
    do { created = try store.loadOrCreate() } catch { expect(false, "loadOrCreate threw \(error)") }
    expect(created.count == 8 && store.load() == created, "created code is persisted")
    let attrs = try? FileManager.default.attributesOfItem(atPath: store.fileURL.path)
    expect((attrs?[.posixPermissions] as? NSNumber)?.intValue == 0o600, "pairing.code is mode 0600")
    let dirAttrs = try? FileManager.default.attributesOfItem(atPath: store.directory.path)
    expect((dirAttrs?[.posixPermissions] as? NSNumber)?.intValue == 0o700, "new support dir is 0700")
    expect((try? store.loadOrCreate()) == created, "existing code is reused, never regenerated")
    // The bash launcher's file: any non-empty first line, whitespace stripped.
    try? "AB2CD3EF\n".write(to: store.fileURL, atomically: true, encoding: .utf8)
    expect(store.load() == "AB2CD3EF", "trailing newline stripped")
    try? "  hand written 7\nignored\n".write(to: store.fileURL, atomically: true, encoding: .utf8)
    expect(store.load() == "handwritten7", "legacy non-standard code preserved verbatim")
    expect((try? store.loadOrCreate()) == "handwritten7", "legacy code is not replaced")
    try? "CRLF2345\r\nignored\r\n".write(to: store.fileURL, atomically: true, encoding: .utf8)
    expect(store.load() == "CRLF2345", "CRLF file handled")
    try? "\n".write(to: store.fileURL, atomically: true, encoding: .utf8)
    expect(store.load() == nil, "blank file counts as no code")
    try? store.save("ZZZZ2222")
    expect(store.load() == "ZZZZ2222", "explicit save replaces")
    expect(((try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? []) == ["pairing.code"], "no temp files left behind")

    // ---- settings round trip ----
    let suite = "com.heysnap.extdisplay.host.selftest.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let ss = SettingsStore(defaults: defaults)
    let first = ss.load(encryptDefault: true)
    var expectedFirst = LauncherSettings(); expectedFirst.encrypt = true
    expect(first == expectedFirst, "first launch = defaults (encrypt follows an existing code)")
    expect(ss.load(encryptDefault: false).encrypt == false, "first launch without a code → encrypt off")
    var custom = LauncherSettings()
    custom.connection = .wifi; custom.tabletIP = "10.0.0.7"; custom.lowLatencyUDP = true
    custom.quality = .fast; custom.touch = false; custom.hevc = true
    custom.audio = true; custom.muteLocal = true; custom.audioDelayMs = 75; custom.encrypt = true
    ss.save(custom)
    expect(ss.load(encryptDefault: false) == custom, "settings round-trip")
    defaults.set(9_999, forKey: "settings.audioDelayMs")
    defaults.set("garbage", forKey: "settings.quality")
    let repaired = ss.load(encryptDefault: false)
    expect(repaired.audioDelayMs == 500 && repaired.quality == .balanced, "corrupt stored values fall back safely")
    custom.audio = false
    ss.save(custom)
    expect(ss.load(encryptDefault: false).muteLocal == false, "mute never restored without audio")

    // ---- adb helpers ----
    expect(classifyAdbState(status: 0, output: "device\n") == .device, "adb device")
    expect(classifyAdbState(status: 1, output: "error: no devices/emulators found\n") == .none, "adb none")
    expect(classifyAdbState(status: 1, output: "error: device unauthorized.\n") == .unauthorized, "adb unauthorized")
    expect(classifyAdbState(status: 1, output: "error: device offline\n") == .offline, "adb offline")
    expect(classifyAdbState(status: 0, output: "* daemon started successfully *\ndevice\n") == .device, "adb device after daemon banner")
    expect(parseVersionCode("    versionCode=9 minSdk=26 targetSdk=34\n    versionCode=3\n") == 9, "first versionCode wins")
    expect(parseVersionCode("Unable to find package") == nil, "no versionCode")
    let home = URL(fileURLWithPath: "/Users/x")
    let bundled = URL(fileURLWithPath: "/App/Contents/Resources/platform-tools/adb")
    expect(locateAdb(bundled: bundled, pathEnv: "/usr/bin", home: home, isExecutable: { _ in true }) == bundled.path, "bundled adb preferred")
    expect(locateAdb(bundled: bundled, pathEnv: "/usr/bin:/x/bin", home: home, isExecutable: { $0 == "/x/bin/adb" }) == "/x/bin/adb", "falls back to PATH")
    expect(locateAdb(bundled: nil, pathEnv: "/usr/bin", home: home, isExecutable: { $0 == "/opt/homebrew/bin/adb" }) == "/opt/homebrew/bin/adb", "finds Homebrew adb with a Finder PATH")
    expect(locateAdb(bundled: nil, pathEnv: "", home: home, isExecutable: { _ in false }) == nil, "no adb anywhere")

    // ---- paths ----
    let bundledPaths = AppPaths.resolve(executable: URL(fileURLWithPath: "/A/ExtendedDisplay.app/Contents/MacOS/ExtendedDisplay"))
    expect(bundledPaths.machHost.path == "/A/ExtendedDisplay.app/Contents/MacOS/MacHost", "MacHost is the sibling binary")
    expect(bundledPaths.bundledAdb?.path == "/A/ExtendedDisplay.app/Contents/Resources/platform-tools/adb", "bundled adb path")
    expect(bundledPaths.apk?.lastPathComponent == "ExtendedDisplayReceiver.apk", "bundled apk path")
    let devPaths = AppPaths.resolve(executable: URL(fileURLWithPath: "/repo/mac-host/.build/release/ExtendedDisplayApp"))
    expect(devPaths.resources == nil && devPaths.machHost.path == "/repo/mac-host/.build/release/MacHost", "unbundled dev layout")

    // ---- line splitter ----
    var sp = LineSplitter()
    expect(sp.feed(Data("abc\nde".utf8)) == ["abc"], "splitter holds the partial line")
    expect(sp.feed(Data("f\r\n\ng".utf8)) == ["def", ""], "splitter joins chunks, strips CR, keeps blank lines")
    expect(sp.flush() == "g" && sp.flush() == nil, "splitter flushes the tail once")

    // ---- status parser: MacHost line -> status text ----
    func run(_ mode: String, _ lines: [String]) -> HostStatus {
        var p = HostStatusParser(modeLabel: mode)
        for l in lines { _ = p.consume(l) }
        return p.status
    }
    func text(_ mode: String, _ lines: [String]) -> String { run(mode, lines).line.text }
    expect(text("USB", []) == "Starting…  (USB)", "initial status")
    let usbStream = [
        "Virtual display online: 2960x1848@60 (id 7)",
        "Capture: virtual display (extended desktop)",
        "Encode: H.264 VideoToolbox, 2960x1848 @ 60 FPS",
        "Touch: connected — tablet touches control the Mac.",
        "Connecting to 127.0.0.1:5000",
        "Streaming. Press Ctrl+C to stop.",
    ]
    expect(text("USB", Array(usbStream.prefix(1))) == "Virtual display ready, connecting…", "virtual display line")
    expect(text("USB", Array(usbStream.prefix(5))) == "Connecting to the tablet…", "connecting")
    expect(text("USB", usbStream) == "Streaming  •  USB  •  H.264 2960x1848 @ 60 fps", "streaming over USB")
    expect(run("USB", usbStream).line.kind == .ok && run("USB", usbStream).hint == nil, "streaming is ok, no hint")
    expect(text("USB", usbStream + ["Audio: streaming to the tablet (48000 Hz stereo)."]) == "Streaming  •  USB  •  H.264 2960x1848 @ 60 fps  •  audio", "audio shown")
    expect(text("USB", ["Pairing enabled — encrypting the link (enter the code on the tablet)."] + usbStream).hasSuffix("•  encrypted"), "encrypted shown")
    expect(text("Wi-Fi UDP", ["Encode: HEVC VideoToolbox, 1920x1200 @ 120 FPS", "Streaming over UDP to 10.0.0.2:5000", "UDP: 812 pkts/s, 38.4 Mbps"]) == "Streaming  •  Wi-Fi UDP  •  HEVC 1920x1200 @ 120 fps  •  38.4 Mbps", "UDP stat")
    expect(run("Wi-Fi UDP", ["Streaming over UDP to 10.0.0.2:5000", "UDP: 5 pkts/s, 1.0 Mbps (3 NALs dropped — egress congested)"]).hint?.contains("Low-latency UDP") == true, "UDP drops hint")
    expect(text("Wi-Fi", ["No tablet found yet; retrying. (Same Wi-Fi network? App open?)"]).hasPrefix("Searching for the tablet"), "searching")
    expect(text("Wi-Fi", ["Found tablet: Samsung SM-X910 at 192.168.1.50"]) == "Found Samsung SM-X910, connecting…", "found tablet")
    expect(run("USB", ["Tablet not reachable (Could not connect to 127.0.0.1:5000 — Connection refused); retrying every 2s — is the app open on the tablet?"]).line.kind == .warn, "unreachable warns")
    expect(text("USB", ["Tablet not reachable (x); retrying"]).contains("Open the Extended Display app"), "unreachable over USB")
    expect(run("Wi-Fi", ["Tablet not reachable (Could not connect to 10.0.0.9:5000 — No route to host); retrying"]).hint?.contains("Local Network") == true, "Local Network hint")
    expect(run("Wi-Fi", ["Tablet not reachable (Could not connect — Connection refused); retrying"]).hint == nil, "no Local Network hint for a plain refusal")
    expect(text("USB", usbStream + ["Stream ended (tablet disconnected or app closed). Reconnecting…"]) == "Reconnecting…  (USB)", "stream ended → reconnecting")
    expect(text("USB", usbStream + ["Stream ended (x). Reconnecting…", "Reconnecting to 127.0.0.1:5000…", "Reconnected. Streaming."]).hasPrefix("Streaming"), "reconnected → streaming")
    expect(run("USB", usbStream + ["Touch: Accessibility permission not granted yet — tablet touches will not move the cursor"]).hint?.contains("Accessibility") == true, "Accessibility hint")
    expect(run("USB", usbStream + ["Touch pairing/auth failed - check the code on the tablet."]).hint?.contains("pairing code") == true, "touch auth failure hint")
    let mismatch = "Pairing code mismatch — the tablet keeps closing the encrypted stream. Enter this Mac's pairing code on the tablet (it shows a code box at the top of the screen); MacHost keeps retrying."
    expect(run("USB", usbStream + [mismatch]).line.kind == .error, "pairing mismatch is an error status")
    expect(run("USB", usbStream + [mismatch]).line.text.contains("different pairing code"), "pairing mismatch text")
    expect(run("USB", usbStream + [mismatch, "Reconnected. Streaming."]).line.kind == .ok, "pairing mismatch clears once streaming resumes")
    expect(run("USB", usbStream + ["Touch pairing/auth failed - check the code on the tablet.", "Touch: connected — tablet touches control the Mac (encrypted)."]).hint == nil, "touch auth hint clears when connected")
    expect(text("USB", usbStream + ["Stopping."]) == "Stopping…", "stopping")
    let tcc = run("USB", ["Error: The user declined TCCs for application, window, display capture\n"])
    expect(tcc.line.kind == .error && tcc.line.text.contains("Screen Recording") && tcc.hint?.contains("Screen") == true, "TCC error → Screen Recording message")
    let bad = run("USB", ["Error: Unknown argument: --bogus", "", "MacHost — extended display for an Android tablet", "Usage:"])
    expect(bad.line.text == "Error: Unknown argument: --bogus", "usage text after an error doesn't overwrite it")
    expect(text("USB", ["TRACE   12.0 IN  4", "Desktop audio: Mac output muted (sound plays on the tablet only)."]) == "Starting…  (USB)", "unrelated lines are ignored")
    var changing = HostStatusParser(modeLabel: "USB")
    expect(changing.consume("some noise") == false && changing.consume("Streaming. Press Ctrl+C to stop.") == true, "consume reports changes")

    // ---- real child processes (sh only; no adb, no MacHost) ----
    func spawn(_ script: String, onLine: @escaping (String) -> Void) -> HostProcess? {
        let p = HostProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                            environment: ["PATH": "/usr/bin:/bin"], onLine: onLine)
        do { try p.start(); return p } catch { expect(false, "spawn failed: \(error)"); return nil }
    }
    let box = LockedLines()

    if let p = spawn("echo one; echo two >&2; printf three", onLine: box.add) {
        let exit = p.waitUntilExit()
        expect(box.lines == ["one", "two", "three"], "stdout+stderr merged, tail line flushed (got \(box.lines))")
        expect(exit == ChildExit(status: 0, signaled: false), "clean exit status")
    }

    let env = LockedLines()
    if let p = spawn("echo \"key=${EXTDISPLAY_KEY:-unset}\"", onLine: env.add) {
        _ = p.waitUntilExit()
        expect(env.lines == ["key=unset"], "child environment is exactly what we pass")
    }

    // Graceful stop: SIGINT, child's trap runs, exits 0 — the MacHost path.
    let graceful = LockedLines()
    let ready1 = DispatchSemaphore(value: 0)
    if let p = spawn("trap 'echo got-int; exit 0' INT; echo ready; while :; do sleep 0.05; done", onLine: { l in
        graceful.add(l); if l == "ready" { ready1.signal() } }) {
        expect(ready1.wait(timeout: .now() + 5) == .success, "graceful child became ready")
        let t0 = Date()
        p.requestStop()
        let exit = p.waitUntilExit()
        expect(exit == ChildExit(status: 0, signaled: false), "SIGINT lets the child exit cleanly")
        expect(graceful.lines.contains("got-int"), "child saw SIGINT")
        expect(Date().timeIntervalSince(t0) < 3, "graceful stop is prompt")
    }

    // Stubborn child: ignores INT and TERM, must end by SIGKILL.
    let ready2 = DispatchSemaphore(value: 0)
    if let p = spawn("trap '' INT TERM; echo ready; while :; do sleep 0.05; done", onLine: { l in
        if l == "ready" { ready2.signal() } }) {
        expect(ready2.wait(timeout: .now() + 5) == .success, "stubborn child became ready")
        let t0 = Date()
        p.requestStop(termAfter: 0.3, killAfter: 0.3)
        let exit = p.waitUntilExit()
        expect(exit.signaled && exit.status == SIGKILL, "stubborn child is SIGKILLed after the grace periods")
        expect(Date().timeIntervalSince(t0) < 5, "escalation completes quickly")
        expect(!p.isRunning, "no orphan left")
    }

    // runCommand: output capture, timeout, cancellation.
    let echo = runCommand("/bin/echo", ["hi"], timeout: 5)
    expect(echo.status == 0 && echo.output == "hi\n", "runCommand captures output")
    let t1 = Date()
    let slow = runCommand("/bin/sleep", ["30"], timeout: 0.4)
    expect(slow.timedOut && Date().timeIntervalSince(t1) < 4, "runCommand times out and kills")
    let flag = AtomicFlag()
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { flag.set() }
    let t2 = Date()
    let cancelled = runCommand("/bin/sleep", ["30"], timeout: 30, cancel: flag)
    expect(cancelled.cancelled && Date().timeIntervalSince(t2) < 4, "runCommand honours cancellation")
    expect(runCommand("/nonexistent/adb", [], timeout: 1).status == -1, "missing executable reports failure")

    if failures == 0 {
        print("selftest: OK (argument mapping, legacy options, address validation, pairing code + file, settings round-trip, adb parsing, status parser, line splitter, child stop/escalation)")
        return 0
    }
    print("selftest: \(failures) failure(s)")
    return 1
}

private final class LockedLines {
    private let lock = NSLock()
    private var storage: [String] = []
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    func add(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
}
