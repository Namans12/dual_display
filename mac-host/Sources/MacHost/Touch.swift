import ApplicationServices
import CoreGraphics
import CryptoKit
import Darwin
import Foundation

// Touch protocol v2 — fixed 28-byte big-endian packets from the tablet's
// TouchUplink (port 5001), one packet per pointer per event:
//   u32 magic 'HXTP' | u16 version=2
//   u8 type (0=down 1=move 2=up 3=cancel 4=hover-move 5=hover-exit)
//   u8 tool (0=finger 1=stylus 2=eraser) | u8 pointerId | u8 pointerCount
//   u16 pressure (0..1024, 0 while hovering)
//   f32 nx, f32 ny (normalized to the letterboxed video area)
//   u64 timestampUs
struct TouchPacket {
    static let byteCount = 28
    static let magic: UInt32 = 0x4858_5450  // 'HXTP'
    static let version: UInt16 = 2

    enum EventType: UInt8 {
        case down = 0, move = 1, up = 2, cancel = 3, hoverMove = 4, hoverExit = 5
    }

    var type: EventType
    var tool: UInt8
    var pointerId: UInt8
    var pointerCount: UInt8
    var pressure: UInt16
    var nx: Float
    var ny: Float
    var timestampUs: UInt64
}

func beU16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
}

func beU32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 |
    UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
}

func beU64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
    UInt64(beU32(bytes, offset)) << 32 | UInt64(beU32(bytes, offset + 4))
}

func parseTouchPacket(_ bytes: [UInt8]) -> TouchPacket? {
    guard bytes.count == TouchPacket.byteCount,
          beU32(bytes, 0) == TouchPacket.magic,
          beU16(bytes, 4) == TouchPacket.version,
          let type = TouchPacket.EventType(rawValue: bytes[6]) else {
        return nil
    }
    return TouchPacket(
        type: type,
        tool: bytes[7],
        pointerId: bytes[8],
        pointerCount: bytes[9],
        pressure: min(beU16(bytes, 10), 1024),
        nx: Float(bitPattern: beU32(bytes, 12)),
        ny: Float(bitPattern: beU32(bytes, 16)),
        timestampUs: beU64(bytes, 20)
    )
}

// Maps normalized tablet coordinates onto the captured display and drives the
// mouse via CGEvent posted to the HID tap (the SendInput equivalent).
// Single-pointer semantics, like the Windows host's v1 fallback path: the
// first contact down owns the cursor until it lifts; other pointers are
// ignored meanwhile. Stylus and eraser ride the same mouse path for now
// (pen/pressure injection is a later milestone).
final class MouseInjector {
    private let displayID: CGDirectDisplayID
    private var ownerPointerId = -1  // -1 = button not down
    private var lastPoint = CGPoint.zero
    private var lastUpTime = Date.distantPast
    private var lastUpPoint = CGPoint.zero
    private var clickState: Int64 = 1

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }

    private func mapToGlobal(_ nx: Float, _ ny: Float) -> CGPoint {
        let bounds = CGDisplayBounds(displayID)
        return CGPoint(x: bounds.minX + CGFloat(nx) * (bounds.width - 1),
                       y: bounds.minY + CGFloat(ny) * (bounds.height - 1))
    }

    private func post(_ type: CGEventType, _ point: CGPoint, clickState: Int64 = 0,
                      pressure: Double? = nil) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left) else { return }
        if clickState > 0 {
            event.setIntegerValueField(.mouseEventClickState, value: clickState)
        }
        if let pressure {
            // Stylus/eraser: mark the event as a tablet point and carry the pen
            // pressure so pressure-aware apps (drawing tools) respond to the
            // S Pen. Plain mouse consumers ignore the subtype.
            event.setIntegerValueField(.mouseEventSubtype, value: 1)  // tablet point
            event.setDoubleValueField(.mouseEventPressure, value: pressure)
            event.setDoubleValueField(.tabletEventPointPressure, value: pressure)
        }
        event.post(tap: .cghidEventTap)
    }

    func handle(_ packet: TouchPacket) {
        let point = mapToGlobal(packet.nx, packet.ny)
        lastPoint = point
        // tool 0 = finger (plain mouse semantics); 1/2 = stylus/eraser, which
        // carry pressure (0..1024 → 0..1) while in contact.
        let penPressure: Double? = packet.tool != 0 ? Double(packet.pressure) / 1024.0 : nil
        switch packet.type {
        case .down:
            guard ownerPointerId < 0 else { return }  // single-pointer: ignore extra fingers
            ownerPointerId = Int(packet.pointerId)
            // Synthetic events carry their own click count — the OS only
            // computes it for hardware clicks. Same spot + quick succession
            // must count up or double-click never works from the tablet.
            if Date().timeIntervalSince(lastUpTime) < 0.4,
               hypot(point.x - lastUpPoint.x, point.y - lastUpPoint.y) < 8 {
                clickState += 1
            } else {
                clickState = 1
            }
            post(.leftMouseDown, point, clickState: clickState, pressure: penPressure)
        case .move:
            if Int(packet.pointerId) == ownerPointerId {
                post(.leftMouseDragged, point, clickState: clickState, pressure: penPressure)
            } else if ownerPointerId < 0 {
                post(.mouseMoved, point)
            }
        case .up, .cancel:
            guard Int(packet.pointerId) == ownerPointerId else { return }
            ownerPointerId = -1
            lastUpTime = Date()
            lastUpPoint = point
            post(.leftMouseUp, point, clickState: clickState,
                 pressure: packet.tool != 0 ? 0.0 : nil)
        case .hoverMove:
            if ownerPointerId < 0 {  // S Pen hovering; don't disturb a drag
                post(.mouseMoved, point)
            }
        case .hoverExit:
            break  // a mouse never leaves range
        }
    }

    // The tablet disconnected mid-gesture: don't leave the button stuck down.
    func releaseStuckButton() {
        guard ownerPointerId >= 0 else { return }
        ownerPointerId = -1
        post(.leftMouseUp, lastPoint)
    }
}

// Connects to the tablet's touch listener and feeds packets to the injector.
// Reconnects forever (2 s backoff) like the Windows bridge: the app may not be
// up yet, and Wi-Fi blips or app restarts must not end touch for the session.
final class TouchBridge {
    private let host: String
    private let port: Int
    private let injector: MouseInjector
    private let key: SymmetricKey?  // nil = plaintext
    private let stopped = AtomicFlag()
    private var currentFd: Int32 = -1

    init(host: String, port: Int, displayID: CGDirectDisplayID, key: SymmetricKey? = nil) {
        self.host = host
        self.port = port
        self.injector = MouseInjector(displayID: displayID)
        self.key = key
    }

    func start() {
        // CGEvent posting silently no-ops without Accessibility; surface it
        // once, with the system prompt, instead of "touch mysteriously dead".
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            print("Touch: Accessibility permission not granted yet — tablet touches " +
                  "will not move the cursor until it is (System Settings > Privacy & " +
                  "Security > Accessibility; grant the app that launched MacHost).")
        }
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "touch-bridge"
        thread.start()
    }

    func stop() {
        stopped.set()
        if currentFd >= 0 {
            shutdown(currentFd, SHUT_RDWR)  // unblock the recv
        }
        injector.releaseStuckButton()
    }

    private func run() {
        var announced = false
        while !stopped.isSet {
            guard let fd = connect() else {
                if !announced {
                    print("Touch: waiting for the tablet's touch port \(host):\(port)…")
                    announced = true
                }
                sleepInterruptible(2.0)
                continue
            }
            currentFd = fd
            print("Touch: connected — tablet touches control the Mac\(key != nil ? " (encrypted)" : "").")
            announced = false
            if key != nil {
                encryptedReadLoop(fd)
            } else {
                readLoop(fd)
            }
            close(fd)
            currentFd = -1
            injector.releaseStuckButton()
            if !stopped.isSet {
                sleepInterruptible(1.0)
            }
        }
    }

    private func connect() -> Int32? {
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

    private func readLoop(_ fd: Int32) {
        var packet = [UInt8](repeating: 0, count: TouchPacket.byteCount)
        while !stopped.isSet {
            guard recvFull(fd, &packet, TouchPacket.byteCount) else { return }
            // Resync: a mid-stream connect can land between packet boundaries;
            // slide one byte at a time until the magic lines up.
            while beU32(packet, 0) != TouchPacket.magic {
                packet.removeFirst()
                packet.append(0)
                var last = [UInt8](repeating: 0, count: 1)
                guard recvFull(fd, &last, 1) else { return }
                packet[TouchPacket.byteCount - 1] = last[0]
            }
            guard let parsed = parseTouchPacket(packet) else { continue }  // e.g. version skew
            injector.handle(parsed)
        }
    }

    // Paired: each packet is a 56-byte AES-GCM frame [12B nonce][28B ct][16B
    // tag]. TCP keeps us frame-aligned from the first byte; an auth failure
    // means a wrong pairing code (or tampering) — nothing to resync to, so drop
    // the connection (no injection from strangers). Replay guard: the 8-byte
    // big-endian nonce counter must strictly increase.
    private func encryptedReadLoop(_ fd: Int32) {
        guard let key else { return }
        let frameSize = 12 + TouchPacket.byteCount + 16  // 56
        var frameBytes = [UInt8](repeating: 0, count: frameSize)
        var lastCounter: UInt64 = 0
        var lastPrefix: [UInt8]? = nil
        while !stopped.isSet {
            guard recvFull(fd, &frameBytes, frameSize) else { return }
            let frame = Data(frameBytes)
            guard let plain = Sealer.open(frame, key: key), plain.count == TouchPacket.byteCount else {
                print("Touch pairing/auth failed - check the code on the tablet.")
                return  // drop the connection
            }
            // Replay guard, per nonce prefix: within one prefix the counter must
            // strictly increase; a new prefix is a legitimate re-key (the tablet
            // resets its counter to 0), so accept and rebase.
            if let prefix = Sealer.noncePrefix(frame), let counter = Sealer.nonceCounter(frame) {
                if prefix == lastPrefix {
                    if counter <= lastCounter { continue }  // replay / reorder
                } else {
                    lastPrefix = prefix
                }
                lastCounter = counter
            }
            guard let parsed = parseTouchPacket([UInt8](plain)) else { continue }
            injector.handle(parsed)
        }
    }

    private func recvFull(_ fd: Int32, _ buffer: inout [UInt8], _ length: Int) -> Bool {
        var got = 0
        while got < length {
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                recv(fd, raw.baseAddress!.advanced(by: got), length - got, 0)
            }
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                return false
            }
            got += n
        }
        return true
    }

    private func sleepInterruptible(_ seconds: Double) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while !stopped.isSet && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}

// Tiny lock-wrapped flag (no third-party atomics).
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
    func clear() {
        lock.lock()
        value = false
        lock.unlock()
    }
}

// USB runs through adb forwards on loopback, where the touch forward is the
// video port + 1 (the Windows host uses the same local-port convention);
// direct Wi-Fi connects to the tablet's real touch listener on 5001.
func touchPort(forHost host: String, videoPort: Int) -> Int {
    let isLoopback = host == "127.0.0.1" || host == "localhost" || host == "::1"
    return isLoopback ? videoPort + 1 : 5001
}
