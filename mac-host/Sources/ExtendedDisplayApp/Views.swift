import AppKit
import SwiftUI

enum Help {
    static let usb = "Connect the tablet with a USB-C cable and turn on USB debugging. The app installs the receiver on the tablet and sets up the ports for you."
    static let wifi = "Stream over the local network. The tablet and this Mac must be on the same Wi-Fi; guest and AP-isolated networks block this."
    static let ip = "Optional. Enter the tablet's IP if auto-discovery fails (guest or AP-isolated networks). Leave blank to find it automatically."
    static let udp = "Send video over UDP for lower latency on Wi-Fi. Helps on lossy links; on a good 5 GHz link plain TCP is usually smoother. Not available over USB."
    static let best = "Sharpest picture: native 2960x1848 at 60 fps with a higher 40 Mbps bitrate. Best for reading and coding. Prefers USB or strong 5 GHz Wi-Fi."
    static let balanced = "Native 2960x1848 at 60 fps, 25 Mbps. The proven default, right for almost everything."
    static let fast = "Quickest reaction to touch and pen: the picture is sent at 1920x1200 and the tablet enlarges it, which roughly halves the encoding time. Text looks softer than Balanced."
    static let touch = "Tablet touches and the S Pen control the Mac cursor: tap = click, drag = move. Needs the Accessibility permission."
    static let hevc = "H.265: better compression, so motion looks cleaner at the same bitrate. Barely visible on a still desktop. Needs tablet HEVC decode."
    static let audio = "Play the Mac's sound on the tablet over the same link. Covered by the Screen Recording permission."
    static let mute = "Sound plays only on the tablet; the Mac's speakers stay silent while streaming (restored when you Stop)."
    static let delay = "Audio buffer on the tablet for lip-sync, 20 to 500 ms. Higher = audio plays later; lower it if audio lags the video."
    static let encrypt = "Require a pairing code on the tablet and encrypt video, touch and audio with AES-256. Use it on untrusted Wi-Fi. You type the code on the tablet once; New code rotates it."
    static let newCode = "Generate a fresh pairing code. You'll need to enter it on the tablet on the next Start."
}

struct RadioRow: View {
    let title: String
    let help: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundColor(selected ? .accentColor : .secondary)
            Text(title)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let grant: () -> Void
    let pane: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundColor(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            if !granted {
                // Grant shows the system prompt (and adds the app to the list);
                // Settings jumps to the list for when the prompt was dismissed.
                Button("Grant…", action: grant).controlSize(.small)
                Button("Settings") { Permissions.openPane(pane) }.controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct Section<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        GroupBox(label: Text(title).font(.headline)) {
            VStack(alignment: .leading, spacing: 8) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        }
    }
}

struct ContentView: View {
    // No @State anywhere: with only the Command Line Tools installed, the SwiftUI
    // macro plugin (SwiftUIMacros) is missing, and @State is a macro in this SDK.
    // @ObservedObject/@Published are plain property wrappers and compile fine, so
    // view-local flags live on the model.
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.permissions.allGranted { permissionsSection }

            // Settings are read when Start is pressed, so lock them while running
            // rather than let the user change controls that have no effect.
            Group {
                connection
                quality
                options
            }
            .disabled(!model.isIdle)

            pairing
            statusArea
            buttons
            footer
        }
        .padding(16)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .background(WindowConfigurator())
    }

    // Shown only while something is missing, so a set-up app has no clutter.
    private var permissionsSection: some View {
        Section(title: "Permissions needed") {
            PermissionRow(title: "Screen Recording",
                          detail: "to show the Mac's extended desktop on the tablet",
                          granted: model.permissions.screenRecording,
                          grant: { model.grantScreenRecording() },
                          pane: PrivacyPane.screenRecording)
            if model.askedForScreenRecording && !model.permissions.screenRecording {
                HStack(spacing: 8) {
                    Text("Switched it on? macOS applies it after the app is reopened.")
                        .font(.caption).foregroundColor(.secondary)
                    Spacer(minLength: 0)
                    Button("Reopen app") { model.reopenApp() }.controlSize(.small)
                }
                .padding(.leading, 24)
            }
            PermissionRow(title: "Accessibility",
                          detail: "so touch and pen on the tablet control the Mac",
                          granted: model.permissions.accessibility,
                          grant: { model.grantAccessibility() },
                          pane: PrivacyPane.accessibility)
        }
    }

    private var footer: some View {
        HStack {
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .font(.caption).foregroundColor(.secondary)
            Spacer()
            Button("Uninstall…") { model.confirmingUninstall = true }
                .buttonStyle(.link)
                .font(.caption)
                .help("Remove the app together with its permissions, settings, pairing code and log.")
        }
        .alert("Uninstall Extended Display?", isPresented: $model.confirmingUninstall) {
            Button("Uninstall", role: .destructive) { model.uninstall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This stops streaming, moves the app to the Trash and removes its permissions " +
                 "(Screen Recording, Accessibility, Local Network), settings, pairing code and log. " +
                 "The app on the tablet is not removed.")
        }
    }

    private var connection: some View {
        Section(title: "Connection") {
            RadioRow(title: "USB  (auto-detect)", help: Help.usb, selected: model.settings.connection == .usb) {
                model.settings.connection = .usb
            }
            RadioRow(title: "Wi-Fi", help: Help.wifi, selected: model.settings.connection == .wifi) {
                model.settings.connection = .wifi
            }
            let wifi = model.settings.connection == .wifi
            HStack {
                Text("Tablet IP (optional):")
                TextField("auto-discover", text: $model.settings.tabletIP)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .disableAutocorrection(true)
            }
            .padding(.leading, 22)
            .disabled(!wifi)
            .help(Help.ip)
            Toggle("Low-latency UDP", isOn: $model.settings.lowLatencyUDP)
                .toggleStyle(.checkbox)
                .padding(.leading, 22)
                .disabled(!wifi)
                .help(Help.udp)
        }
    }

    private var quality: some View {
        Section(title: "Quality") {
            RadioRow(title: "Best resolution", help: Help.best, selected: model.settings.quality == .best) {
                model.settings.quality = .best
            }
            RadioRow(title: "Balanced  (recommended)", help: Help.balanced, selected: model.settings.quality == .balanced) {
                model.settings.quality = .balanced
            }
            RadioRow(title: "Fastest response  (softer picture)", help: Help.fast, selected: model.settings.quality == .fast) {
                model.settings.quality = .fast
            }
        }
    }

    private var options: some View {
        Section(title: "Options") {
            Toggle("Touch input", isOn: $model.settings.touch).help(Help.touch)
            Toggle("HEVC / H.265", isOn: $model.settings.hevc).help(Help.hevc)
            Toggle("Desktop audio", isOn: $model.settings.audio).help(Help.audio)
            let audio = model.settings.audio
            Toggle("Mute Mac speakers", isOn: $model.settings.muteLocal)
                .padding(.leading, 22)
                .disabled(!audio)
                .help(Help.mute)
            Stepper(value: $model.settings.audioDelayMs, in: LauncherSettings.audioDelayRange, step: 5) {
                Text("A/V sync delay: \(model.settings.audioDelayMs) ms")
            }
            .padding(.leading, 22)
            .disabled(!audio)
            .help(Help.delay)
            Toggle("Encrypt link", isOn: $model.settings.encrypt).help(Help.encrypt)
        }
        .toggleStyle(.checkbox)
    }

    // Fixed height so showing/hiding the code never resizes the window.
    private var pairing: some View {
        HStack {
            if model.settings.encrypt, let code = model.pairingCode {
                Text("Pairing code:")
                Text(code)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundColor(.accentColor)
                    .textSelection(.enabled)
                Spacer()
                Button("New code") { model.confirmingNewCode = true }
                    .disabled(!model.isIdle)
                    .help(Help.newCode)
            }
        }
        .frame(height: 24)
        .alert("Generate a new pairing code?", isPresented: $model.confirmingNewCode) {
            Button("Generate", role: .destructive) { model.generateNewCode() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The tablet stores the current code, so you will have to enter the new one on it.")
        }
    }

    private var statusArea: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(color(model.status.line.kind)).frame(width: 9, height: 9)
                Text(model.status.line.text)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                // Permission problems can only be fixed in System Settings, so
                // take the user straight to the right pane.
                if let pane = model.status.settingsPane, let url = URL(string: pane) {
                    Button("Open Settings") { NSWorkspace.shared.open(url) }
                        .controlSize(.small)
                }
            }
            Text(model.status.hint ?? " ")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .frame(height: 30, alignment: .topLeading)
                .padding(.leading, 15)
        }
        .frame(height: 56, alignment: .topLeading)
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            Button(action: { model.start() }) {
                Text("Start Streaming").frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .disabled(!model.isIdle)
            Button(action: { model.stop() }) {
                Text("Stop").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(model.state != .running)
        }
    }

    private func color(_ kind: StatusLine.Kind) -> Color {
        switch kind {
        case .idle: return .gray
        case .working: return .blue
        case .ok: return .green
        case .warn: return .orange
        case .error: return .red
        }
    }
}

// Fixed-size window: no resize, no zoom. (.windowResizability(.contentSize)
// fixes the size; this also greys the green button and keeps the window unmaximisable.)
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.styleMask.remove(.resizable)
            w.standardWindowButton(.zoomButton)?.isEnabled = false
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
