import Foundation

// UI state of the launcher window. Everything here except the pairing code is
// persisted in UserDefaults; the code lives in its own 0600 file (Pairing.swift)
// so it stays shared with the old bash launcher and never sits in a plist.

enum ConnectionMode: String, CaseIterable {
    case usb, wifi
}

enum QualityPreset: String, CaseIterable {
    // "smooth" is the stored value of the old "Smooth motion (120 fps)" preset,
    // which this one replaced; keeping it lets a saved choice carry over.
    case best, balanced, fast = "smooth"
}

struct LauncherSettings: Equatable {
    static let audioDelayRange = 20...500
    static let defaultAudioDelayMs = 40

    var connection: ConnectionMode = .usb
    var tabletIP = ""
    var lowLatencyUDP = false
    var quality: QualityPreset = .balanced
    var touch = true
    var hevc = false
    var audio = false
    var muteLocal = false
    var audioDelayMs = LauncherSettings.defaultAudioDelayMs
    var encrypt = false

    static func clampDelay(_ ms: Int) -> Int {
        min(max(ms, audioDelayRange.lowerBound), audioDelayRange.upperBound)
    }
}

struct SettingsStore {
    let defaults: UserDefaults

    private enum Key {
        static let connection = "settings.connection"
        static let tabletIP = "settings.tabletIP"
        static let udp = "settings.lowLatencyUDP"
        static let quality = "settings.quality"
        static let touch = "settings.touch"
        static let hevc = "settings.hevc"
        static let audio = "settings.audio"
        static let mute = "settings.muteLocal"
        static let delay = "settings.audioDelayMs"
        static let encrypt = "settings.encrypt"
    }

    // `encryptDefault` only applies to a first launch: a Mac that already has a
    // pairing.code was being encrypted by the old launcher, so keep doing so.
    func load(encryptDefault: Bool) -> LauncherSettings {
        var s = LauncherSettings()
        s.encrypt = encryptDefault
        if let raw = defaults.string(forKey: Key.connection), let v = ConnectionMode(rawValue: raw) { s.connection = v }
        if let v = defaults.string(forKey: Key.tabletIP) { s.tabletIP = v }
        if let v = defaults.object(forKey: Key.udp) as? Bool { s.lowLatencyUDP = v }
        if let raw = defaults.string(forKey: Key.quality), let v = QualityPreset(rawValue: raw) { s.quality = v }
        if let v = defaults.object(forKey: Key.touch) as? Bool { s.touch = v }
        if let v = defaults.object(forKey: Key.hevc) as? Bool { s.hevc = v }
        if let v = defaults.object(forKey: Key.audio) as? Bool { s.audio = v }
        if let v = defaults.object(forKey: Key.mute) as? Bool { s.muteLocal = v }
        if let v = defaults.object(forKey: Key.delay) as? Int { s.audioDelayMs = LauncherSettings.clampDelay(v) }
        if let v = defaults.object(forKey: Key.encrypt) as? Bool { s.encrypt = v }
        if !s.audio { s.muteLocal = false }
        return s
    }

    func save(_ s: LauncherSettings) {
        defaults.set(s.connection.rawValue, forKey: Key.connection)
        defaults.set(s.tabletIP, forKey: Key.tabletIP)
        defaults.set(s.lowLatencyUDP, forKey: Key.udp)
        defaults.set(s.quality.rawValue, forKey: Key.quality)
        defaults.set(s.touch, forKey: Key.touch)
        defaults.set(s.hevc, forKey: Key.hevc)
        defaults.set(s.audio, forKey: Key.audio)
        defaults.set(s.muteLocal, forKey: Key.mute)
        defaults.set(s.audioDelayMs, forKey: Key.delay)
        defaults.set(s.encrypt, forKey: Key.encrypt)
    }
}
