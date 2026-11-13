import Foundation

// Pure mapping from UI state to MacHost's command line. Kept free of UI and
// process code so --selftest can pin the whole table.

enum Ports {
    static let video = 5000
    static let touch = 5001
    static let audio = 5003
    // The three adb forwards the old bash launcher set up (audio is only used
    // with --audio, but forwarding it unconditionally costs nothing).
    static let usbForwards = [video, touch, audio]
}

enum Quality {
    // MacHost's --bitrate is bits/second (the Windows sender takes kbps).
    static let bestBitrate = 40_000_000
    // "Fastest response": the capture is scaled to 1920x1200 (the tablet
    // upscales). Measured on an M4 over USB against Balanced: encode 7.6 ms vs
    // 14.5 ms per frame, a touch reaching the wire in 16 ms vs 24 ms, text at
    // ~72% of the sharpness. It replaced a 120 fps preset that only ever
    // delivered 60 real frames/s on a 60 Hz Mac.
    static let fastWidth = 1920
    static let fastHeight = 1200
}

// Hostnames and IPv4/IPv6 literals only. Nothing that could be mistaken for a
// flag, and no whitespace (the value is one argv element, but a typo with a
// space would otherwise fail deep inside getaddrinfo).
func isValidTabletAddress(_ s: String) -> Bool {
    guard !s.isEmpty, s.count <= 253, !s.hasPrefix("-") else { return false }
    return s.unicodeScalars.allSatisfy { c in
        (c.value >= 0x30 && c.value <= 0x39) || (c.value >= 0x41 && c.value <= 0x5A) ||
        (c.value >= 0x61 && c.value <= 0x7A) || c == "." || c == ":" || c == "-" || c == "_"
    }
}

// Returns a user-facing problem that should block Start, or nil.
func settingsProblem(_ s: LauncherSettings) -> String? {
    if s.connection == .wifi {
        let ip = s.tabletIP.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ip.isEmpty && !isValidTabletAddress(ip) {
            return "The tablet IP \"\(ip)\" doesn't look like an address. Clear it to auto-discover."
        }
    }
    return nil
}

// `extra` is the legacy `options` file (see parseLegacyOptions); it goes last so
// it can override, exactly like the old launcher's EXTRA_ARGS.
func hostArguments(for s: LauncherSettings, extra: [String] = []) -> [String] {
    var a: [String] = []
    switch s.connection {
    case .usb:
        a += ["--host", "127.0.0.1", "--port", String(Ports.video)]
    case .wifi:
        let ip = s.tabletIP.trimmingCharacters(in: .whitespacesAndNewlines)
        // A manual IP connects directly and skips the discovery broadcast.
        a += ip.isEmpty ? ["--wifi"] : ["--host", ip]
        // adb can't forward UDP, so --udp is Wi-Fi only (MacHost rejects it otherwise).
        if s.lowLatencyUDP { a.append("--udp") }
    }
    switch s.quality {
    case .best: a += ["--bitrate", String(Quality.bestBitrate)]
    case .balanced: break  // MacHost's defaults (60 fps, 25 Mbps)
    case .fast: a += ["--width", String(Quality.fastWidth), "--height", String(Quality.fastHeight)]
    }
    if !s.touch { a.append("--no-touch") }
    if s.hevc { a.append("--hevc") }
    if s.audio {
        a.append("--audio")
        a += ["--audio-delay-ms", String(LauncherSettings.clampDelay(s.audioDelayMs))]
        if s.muteLocal { a.append("--mute-local") }
    }
    return a + extra
}

// The old launcher did `head -1 options` and word-split it.
func parseLegacyOptions(_ contents: String) -> [String] {
    // isNewline, not "\n": Swift treats "\r\n" as one Character that != "\n".
    let firstLine = contents.split(maxSplits: 1, omittingEmptySubsequences: false, whereSeparator: \.isNewline).first ?? ""
    return firstLine.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).map(String.init)
}

func modeLabel(for s: LauncherSettings) -> String {
    switch s.connection {
    case .usb: return "USB"
    case .wifi: return s.lowLatencyUDP ? "Wi-Fi UDP" : "Wi-Fi"
    }
}
