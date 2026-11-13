import Foundation

struct StatusLine: Equatable {
    enum Kind { case idle, working, ok, warn, error }
    var kind: Kind
    var text: String
}

struct HostStatus: Equatable {
    var line: StatusLine
    // A second, smaller line for things the user can act on (permissions).
    var hint: String?

    static func make(_ kind: StatusLine.Kind, _ text: String, hint: String? = nil) -> HostStatus {
        HostStatus(line: StatusLine(kind: kind, text: text), hint: hint)
    }
}

// Turns MacHost's stdout/stderr into the one-line live status. The strings
// matched here are MacHost's own print() lines; if one is reworded the status
// degrades to "Starting…" rather than breaking anything (the raw output is still
// in the log). Single-threaded: fed from the child's reader thread.
struct HostStatusParser {
    enum Phase { case starting, displayReady, searching, connecting, unreachable, streaming, reconnecting, stopping }

    let modeLabel: String
    private(set) var phase: Phase = .starting
    private(set) var status = HostStatus.make(.working, "Starting…")

    private var encrypted = false
    private var deviceName: String?
    private var codec: String?
    private var udpStat: String?
    private var udpDropping = false
    private var audioActive = false
    private var accessibilityMissing = false
    private var touchAuthFailed = false
    private var noRoute = false
    private var fatal: String?

    init(modeLabel: String) {
        self.modeLabel = modeLabel
        status = render()
    }

    // Returns true when the visible status changed.
    mutating func consume(_ rawLine: String) -> Bool {
        let before = status
        apply(rawLine.trimmingCharacters(in: .whitespaces))
        status = render()
        return status != before
    }

    private mutating func apply(_ l: String) {
        if l.hasPrefix("Error:") {
            fatal = String(l.dropFirst("Error:".count)).trimmingCharacters(in: .whitespaces)
        } else if l.hasPrefix("Pairing enabled") {
            encrypted = true
        } else if l.hasPrefix("No tablet found") {
            phase = .searching
        } else if l.hasPrefix("Found tablet:") {
            if let m = HostStatusParser.match(#"Found tablet: (.+) at \S+$"#, in: l) { deviceName = m[0] }
            phase = .connecting
        } else if l.hasPrefix("Virtual display") {
            phase = .displayReady
        } else if l.hasPrefix("Encode:") {
            if let m = HostStatusParser.match(#"Encode: (H\.264|HEVC) \S+, (\d+x\d+) @ (\d+) FPS"#, in: l) {
                codec = "\(m[0]) \(m[1]) @ \(m[2]) fps"
            }
        } else if l.hasPrefix("Connecting to") {
            phase = .connecting
        } else if l.hasPrefix("Tablet not reachable") {
            phase = .unreachable
            noRoute = l.contains("No route to host")
        } else if l.hasPrefix("Streaming") || l.hasPrefix("Reconnected. Streaming") {
            phase = .streaming
            noRoute = false
        } else if l.hasPrefix("Stream ended") || l.hasPrefix("Reconnecting to") {
            phase = .reconnecting
            udpStat = nil
        } else if l.hasPrefix("Touch: Accessibility permission not granted") {
            accessibilityMissing = true
        } else if l.hasPrefix("Touch: connected") {
            touchAuthFailed = false
        } else if l.hasPrefix("Touch pairing/auth failed") {
            touchAuthFailed = true
        } else if l.hasPrefix("Audio: streaming") {
            audioActive = true
        } else if l.hasPrefix("UDP:") {
            if let m = HostStatusParser.match(#"UDP: \d+ pkts/s, ([\d.]+) Mbps"#, in: l) { udpStat = "\(m[0]) Mbps" }
            udpDropping = l.contains("dropped")
        } else if l.hasPrefix("UDP send failed") {
            udpDropping = true
        } else if l.hasPrefix("Stopping.") {
            phase = .stopping
        }
    }

    private func render() -> HostStatus {
        if let f = fatal { return HostStatusParser.describeError(f) }

        var hint: String?
        if touchAuthFailed {
            hint = "Touch was rejected: the pairing code on the tablet doesn't match."
        } else if phase == .unreachable && noRoute {
            hint = "Allow Extended Display under System Settings > Privacy & Security > Local Network."
        } else if accessibilityMissing {
            hint = "Touch needs Accessibility: enable Extended Display under System Settings > " +
                   "Privacy & Security > Accessibility, then Stop and Start again."
        } else if udpDropping && phase == .streaming {
            hint = "The network is dropping frames. Try turning off Low-latency UDP."
        }

        let line: StatusLine
        switch phase {
        case .starting:
            line = StatusLine(kind: .working, text: "Starting…  (\(modeLabel))")
        case .displayReady:
            line = StatusLine(kind: .working, text: "Virtual display ready, connecting…")
        case .searching:
            line = StatusLine(kind: .warn, text: "Searching for the tablet…  (same Wi-Fi network? app open?)")
        case .connecting:
            let text = deviceName.map { "Found \($0), connecting…" } ?? "Connecting to the tablet…"
            line = StatusLine(kind: .working, text: text)
        case .unreachable:
            let text = modeLabel == "USB"
                ? "Tablet not reachable. Open the Extended Display app on the tablet."
                : "Tablet not reachable. Open the app on the tablet, same network?"
            line = StatusLine(kind: .warn, text: text)
        case .streaming:
            var parts = ["Streaming", modeLabel]
            if let codec { parts.append(codec) }
            if audioActive { parts.append("audio") }
            if let udpStat { parts.append(udpStat) }
            if encrypted { parts.append("encrypted") }
            line = StatusLine(kind: .ok, text: parts.joined(separator: "  •  "))
        case .reconnecting:
            line = StatusLine(kind: .warn, text: "Reconnecting…  (\(modeLabel))")
        case .stopping:
            line = StatusLine(kind: .working, text: "Stopping…")
        }
        return HostStatus(line: line, hint: hint)
    }

    // Screen Recording is the one failure users hit routinely; ScreenCaptureKit's
    // wording ("declined TCCs", -3801) is opaque, so translate it.
    static func describeError(_ message: String) -> HostStatus {
        if message.contains("TCC") || message.contains("-3801") {
            return .make(.error, "Screen Recording permission is missing.",
                         hint: "Enable Extended Display under System Settings > Privacy & Security > " +
                               "Screen & System Audio Recording, then Start again.")
        }
        return .make(.error, "Error: \(message)")
    }

    private static func match(_ pattern: String, in s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (1..<max(m.numberOfRanges, 1)).compactMap { i in
            Range(m.range(at: i), in: s).map { String(s[$0]) }
        }
    }
}
