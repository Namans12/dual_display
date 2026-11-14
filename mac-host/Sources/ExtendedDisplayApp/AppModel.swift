import AppKit
import Combine
import Foundation

enum RunState: Equatable {
    case idle
    case running    // adb preparation or MacHost; Stop is available
    case stopping
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var settings: LauncherSettings {
        didSet {
            if oldValue == settings { return }
            // Same rule as the Windows GUI: no audio, no mute.
            if !settings.audio && settings.muteLocal { settings.muteLocal = false }
            settings.audioDelayMs = LauncherSettings.clampDelay(settings.audioDelayMs)
            store.save(settings)
            if settings.encrypt && !oldValue.encrypt { loadPairingCode() }
        }
    }
    @Published var confirmingNewCode = false
    @Published var confirmingUninstall = false
    @Published private(set) var permissions = Permissions.current()
    // Set once the user has gone through the Screen Recording prompt: macOS
    // only applies that grant to a fresh process, so we offer to reopen.
    @Published private(set) var askedForScreenRecording = false
    private var permissionTimer: Timer?
    @Published private(set) var pairingCode: String?
    @Published private(set) var state: RunState = .idle
    @Published private(set) var status = HostStatus.make(.idle, "Ready.")

    private let store: SettingsStore
    private let pairing = PairingStore(directory: AppPaths.supportDirectory)
    private let paths: AppPaths
    private let log = LogFile(url: AppPaths.logFile)
    private let requiredAppVersion: Int
    private var session: LaunchSession?
    private var terminationWaiters: [() -> Void] = []

    private init() {
        store = SettingsStore(defaults: .standard)
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        paths = AppPaths.resolve(executable: exe)
        // Set by build-dmg.sh from its REQUIRED_APP_VERSION. Missing (dev build)
        // → 1, i.e. install the receiver only if it's absent.
        requiredAppVersion = (Bundle.main.object(forInfoDictionaryKey: "EDRequiredAppVersion") as? NSNumber)?.intValue ?? 1

        let hasCode = pairing.load() != nil
        settings = store.load(encryptDefault: hasCode)
        if settings.encrypt { loadPairingCode() }
        if !FileManager.default.isExecutableFile(atPath: paths.machHost.path) {
            status = .make(.error, "MacHost was not found next to this app.")
        }
    }

    var isIdle: Bool { state == .idle }

    // The window polls while it is up: Accessibility flips live when the user
    // toggles it in System Settings, and this is how the checklist notices.
    func startWatchingPermissions() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            MainActor.assumeIsolated { AppModel.shared.refreshPermissions() }
        }
        refreshPermissions()
    }

    func refreshPermissions() {
        let now = Permissions.current()
        if now != permissions { permissions = now }
    }

    func grantScreenRecording() {
        Permissions.requestScreenRecording()
        askedForScreenRecording = true
        refreshPermissions()
    }

    func grantAccessibility() {
        Permissions.requestAccessibility()
        refreshPermissions()
    }

    func reopenApp() {
        shutdown { Permissions.relaunch() }
    }

    // Stops any stream first so no MacHost (and no virtual display) is left behind.
    func uninstall() {
        shutdown {
            if let problem = Uninstaller.run() {
                AppModel.shared.status = .make(.error, problem)
            }
        }
    }

    // Reuses the saved code; only creates one when there is none.
    private func loadPairingCode() {
        do { pairingCode = try pairing.loadOrCreate() } catch {
            pairingCode = nil
            status = .make(.error, "\(error)")
        }
    }

    // Rotating the key invalidates the tablet's stored one, so the UI confirms first.
    func generateNewCode() {
        guard isIdle else { return }
        let code = PairingStore.generateCode()
        do {
            try pairing.save(code)
            pairingCode = code
            status = .make(.idle, "New code. Enter it on the tablet on the next Start.")
        } catch {
            status = .make(.error, "\(error)")
        }
    }

    func start() {
        guard isIdle else { return }
        if let problem = settingsProblem(settings) {
            status = .make(.error, problem)
            return
        }
        var code: String?
        if settings.encrypt {
            if pairingCode == nil { loadPairingCode() }
            guard let c = pairingCode else { return }  // loadPairingCode set the error status
            code = c
        }
        let legacy = (try? String(contentsOf: AppPaths.legacyOptionsFile, encoding: .utf8))
            .map(parseLegacyOptions) ?? []
        let config = SessionConfig(settings: settings, pairingCode: code, extraArguments: legacy,
                                   paths: paths, requiredAppVersion: requiredAppVersion, adbPath: nil)
        let session = LaunchSession(
            config: config, log: log,
            emit: { status in DispatchQueue.main.async { MainActor.assumeIsolated { AppModel.shared.apply(status) } } },
            finished: { result in DispatchQueue.main.async { MainActor.assumeIsolated { AppModel.shared.finish(result) } } })
        self.session = session
        state = .running
        status = .make(.working, "Starting…  (\(modeLabel(for: settings)))")
        session.start()
    }

    func stop() {
        guard let session, state == .running else { return }
        state = .stopping
        status = .make(.working, "Stopping…")
        session.stop()
    }

    private func apply(_ s: HostStatus) {
        if state == .running { status = s }
    }

    private func finish(_ result: SessionResult) {
        session = nil
        state = .idle
        switch result {
        case .stopped:
            status = .make(.idle, "Stopped. The virtual display is gone.")
        case .failed(let s):
            status = s
        case .exited(let code):
            status = .make(.warn, "MacHost stopped on its own (exit \(code)).",
                           hint: "Details: ~/Library/Logs/ExtendedDisplay.log")
        }
        let waiters = terminationWaiters
        terminationWaiters = []
        waiters.forEach { $0() }
    }

    // For quit / window close: stop the child and call back once it's gone, so
    // no MacHost outlives the app. A hard deadline backstops a wedged child.
    func shutdown(completion: @escaping () -> Void) {
        guard let session else { completion(); return }
        terminationWaiters.append(completion)
        if state == .running { stop() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.session != nil else { return }
            session.forceKill()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self else { return }
            let waiters = self.terminationWaiters
            self.terminationWaiters = []
            waiters.forEach { $0() }
        }
    }

    // Last line of defence from applicationWillTerminate.
    func killChildNow() { session?.forceKill() }
}
