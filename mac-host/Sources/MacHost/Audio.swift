import CoreAudio
import CoreMedia
import CryptoKit
import Darwin
import Foundation

// Desktop audio → tablet (opt-in `--audio`), matching the Windows WASAPI
// loopback sender's wire format. ScreenCaptureKit captures the system mix
// (float32 PCM); we convert to interleaved S16LE stereo and send it on the
// audio channel (TCP 5003; over USB the adb forward is video port + 3):
//
//   Header (16 bytes, once per connection, plaintext):
//     'EXAU' | u32 BE rate | u16 BE channels=2 | u8 bits=16 |
//     u8 flags (bit0 = AES-GCM per frame) | u16 BE delayMs | u16 reserved
//   Then per capture packet: [4B BE len][payload], payload = raw PCM or a
//   sealed [12B nonce][ct][16B tag] blob (nonce domain 0x02).
//
// After the header the receiver replies with a 1-byte ACK (0xAC); we wait for
// it so the stream survives the app-launch race (an adb forward accepts the
// local socket before the app binds its port). Reconnects forever like the
// touch bridge; the newest connection wins on the receiver.

func audioHeader(rate: UInt32, encrypted: Bool, delayMs: Int) -> Data {
    let clamped = UInt16(min(max(delayMs, 0), 1000))
    var header = Data([0x45, 0x58, 0x41, 0x55])  // 'EXAU'
    header.append(contentsOf: [UInt8(rate >> 24), UInt8((rate >> 16) & 0xff),
                               UInt8((rate >> 8) & 0xff), UInt8(rate & 0xff)])
    header.append(contentsOf: [0x00, 0x02])      // channels = 2
    header.append(0x10)                          // bits = 16
    header.append(encrypted ? 0x01 : 0x00)       // flags
    header.append(contentsOf: [UInt8(clamped >> 8), UInt8(clamped & 0xff)])
    header.append(contentsOf: [0x00, 0x00])      // reserved
    return header
}

// Converts float channel planes to interleaved S16LE stereo. Mono duplicates
// into both channels; extra channels are ignored (SCK is configured for 2).
func floatBuffersToS16Stereo(_ channels: [[Float]]) -> Data {
    guard let left = channels.first, !left.isEmpty else { return Data() }
    let right = channels.count >= 2 ? channels[1] : left
    let frames = min(left.count, right.count)
    func s16(_ value: Float) -> Int16 {
        Int16(max(-32768.0, min(32767.0, value * 32767.0)))
    }
    var out = Data(capacity: frames * 4)
    for i in 0..<frames {
        withUnsafeBytes(of: s16(left[i]).littleEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: s16(right[i]).littleEndian) { out.append(contentsOf: $0) }
    }
    return out
}

final class AudioBridge {
    private let host: String
    private let port: Int
    private let key: SymmetricKey?
    private let delayMs: Int
    private let muteLocal: Bool
    private let stopped = AtomicFlag()
    private var currentFd: Int32 = -1

    // Small bounded queue between the SCK callback (must never block) and the
    // socket thread; drops the oldest packet when full (stale audio is worse
    // than a brief gap). `lock` also guards `observedRate`.
    private let lock = NSCondition()
    private var pending: [Data] = []
    private let maxPending = 96
    private var observedRate: UInt32 = 48000

    private var sampleRate: UInt32 {
        lock.lock()
        defer { lock.unlock() }
        return observedRate
    }

    init(host: String, port: Int, key: SymmetricKey?, delayMs: Int, muteLocal: Bool) {
        self.host = host
        self.port = port
        self.key = key
        self.delayMs = delayMs
        self.muteLocal = muteLocal
    }

    func start() {
        if muteLocal {
            if LocalMute.set(true) {
                LocalMute.writeMarker()
                print("Desktop audio: Mac output muted (sound plays on the tablet only).")
            }
        }
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "audio-bridge"
        thread.start()
    }

    func stop() {
        stopped.set()
        lock.lock()
        lock.signal()
        lock.unlock()
        if currentFd >= 0 {
            shutdown(currentFd, SHUT_RDWR)
        }
        if muteLocal {
            _ = LocalMute.set(false)
            LocalMute.removeMarker()
            print("Desktop audio: Mac output un-muted.")
        }
    }

    // Called on the SCK audio queue with the raw float sample buffer.
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard !stopped.isSet else { return }
        guard let (rate, channels) = Self.extractFloatChannels(sampleBuffer) else { return }
        let pcm = floatBuffersToS16Stereo(channels)
        guard !pcm.isEmpty else { return }
        lock.lock()
        observedRate = rate
        if pending.count >= maxPending {
            pending.removeFirst()
        }
        pending.append(pcm)
        lock.signal()
        lock.unlock()
    }

    // Pulls the float planes out of a CMSampleBuffer. SCK delivers LPCM
    // float32; planar (non-interleaved) by default, but handle both.
    static func extractFloatChannels(_ sampleBuffer: CMSampleBuffer) -> (UInt32, [[Float]])? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            return nil
        }
        let rate = UInt32(asbd.mSampleRate)
        let channelCount = max(1, Int(asbd.mChannelsPerFrame))
        let planar = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0

        // Two inline AudioBuffers is enough for the planar-stereo case.
        let ablBytes = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size
        let ablRaw = UnsafeMutableRawPointer.allocate(byteCount: ablBytes,
                                                      alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ablRaw.deallocate() }
        let ablPtr = ablRaw.assumingMemoryBound(to: AudioBufferList.self)
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablPtr,
            bufferListSize: ablBytes,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard status == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(ablPtr)

        var channels: [[Float]] = []
        if planar {
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let floats = data.assumingMemoryBound(to: Float.self)
                channels.append(Array(UnsafeBufferPointer(start: floats, count: count)))
                if channels.count == 2 { break }
            }
        } else if let buffer = buffers.first, let data = buffer.mData {
            let total = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let floats = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: total)
            let frames = total / channelCount
            var left = [Float](repeating: 0, count: frames)
            var right = [Float](repeating: 0, count: frames)
            for i in 0..<frames {
                left[i] = floats[i * channelCount]
                right[i] = channelCount >= 2 ? floats[i * channelCount + 1] : left[i]
            }
            channels = [left, right]
        }
        guard !channels.isEmpty else { return nil }
        return (rate, channels)
    }

    private func run() {
        var announced = false
        var lastMuteAssert = Date()
        while !stopped.isSet {
            guard let fd = connectTcp() else {
                if !announced {
                    print("Audio: waiting for the tablet's audio port \(host):\(port)…")
                    announced = true
                }
                sleepInterruptible(2.0)
                continue
            }
            currentFd = fd
            announced = false

            let sealer = key.map { Sealer(key: $0, domain: 0x02) }
            let header = audioHeader(rate: sampleRate, encrypted: sealer != nil, delayMs: delayMs)
            guard sendAll(fd, header) else {
                close(fd); currentFd = -1
                sleepInterruptible(1.0)
                continue
            }
            // ACK: a live receiver actually read the header (see file comment).
            var tv = timeval(tv_sec: 4, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var ack: UInt8 = 0
            guard recv(fd, &ack, 1, 0) == 1 && ack == 0xAC else {
                close(fd); currentFd = -1
                sleepInterruptible(1.0)
                continue
            }
            print("Audio: streaming to the tablet (\(sampleRate) Hz stereo" +
                  "\(sealer != nil ? ", encrypted" : "")).")

            // Drop anything captured while unconnected — start fresh.
            lock.lock()
            pending.removeAll()
            lock.unlock()

            var alive = true
            while alive && !stopped.isSet {
                lock.lock()
                while pending.isEmpty && !stopped.isSet {
                    lock.wait(until: Date(timeIntervalSinceNow: 0.5))
                    break
                }
                let packet = pending.isEmpty ? nil : pending.removeFirst()
                lock.unlock()

                // Volume keys un-mute the endpoint; re-assert like Windows.
                if muteLocal, Date().timeIntervalSince(lastMuteAssert) > 0.5 {
                    lastMuteAssert = Date()
                    _ = LocalMute.set(true)
                }

                guard let packet else { continue }
                var payload = packet
                if let sealer {
                    guard let sealed = sealer.seal(packet) else { alive = false; break }
                    payload = sealed
                }
                let n = UInt32(payload.count)
                var frame = Data([UInt8(n >> 24), UInt8((n >> 16) & 0xff),
                                  UInt8((n >> 8) & 0xff), UInt8(n & 0xff)])
                frame.append(payload)
                if !sendAll(fd, frame) {
                    alive = false  // tablet closed — reconnect
                }
            }
            close(fd)
            currentFd = -1
            if !stopped.isSet {
                sleepInterruptible(1.0)
            }
        }
    }

    private func connectTcp() -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return nil }
        var noDelay: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
                             ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var results: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &results) == 0, let first = results else {
            close(fd)
            return nil
        }
        defer { freeaddrinfo(first) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let candidate = cursor {
            if Darwin.connect(fd, candidate.pointee.ai_addr, candidate.pointee.ai_addrlen) == 0 {
                return fd
            }
            cursor = candidate.pointee.ai_next
        }
        close(fd)
        return nil
    }

    private func sendAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            var sent = 0
            while sent < raw.count {
                let n = write(fd, base.advanced(by: sent), raw.count - sent)
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    return false
                }
                sent += n
            }
            return true
        }
    }

    private func sleepInterruptible(_ seconds: Double) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while !stopped.isSet && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}

// Mute/unmute the default output device (CoreAudio), with a marker file so a
// force-killed host doesn't leave the Mac silent: written while muted, deleted
// on restore, checked at next startup by restoreLocalMuteIfNeeded().
enum LocalMute {
    private static var markerURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("ExtendedDisplay", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("local-muted.flag")
    }

    private static func defaultOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    @discardableResult
    static func set(_ mute: Bool) -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = mute ? 1 : 0
        return AudioObjectSetPropertyData(device, &address, 0, nil,
                                          UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    static func writeMarker() {
        try? Data().write(to: markerURL)
    }

    static func removeMarker() {
        try? FileManager.default.removeItem(at: markerURL)
    }

    // Self-heal: if a prior run muted the Mac and died before restoring.
    static func restoreIfNeeded() {
        guard FileManager.default.fileExists(atPath: markerURL.path) else { return }
        _ = set(false)
        removeMarker()
        print("Desktop audio: restored the Mac's muted output from a previous run.")
    }
}

// USB runs through adb forwards on loopback where the audio forward is the
// video port + 3 (Windows local-port convention); direct Wi-Fi connects to
// the tablet's real listener on 5003.
func audioPort(forHost host: String, videoPort: Int) -> Int {
    let isLoopback = host == "127.0.0.1" || host == "localhost" || host == "::1"
    return isLoopback ? videoPort + 3 : 5003
}
