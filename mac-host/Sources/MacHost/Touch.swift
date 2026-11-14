import ApplicationServices
import CoreGraphics
import CryptoKit
import Darwin
import Carbon.HIToolbox  // kVK_ANSI_* virtual keycodes (constants only)
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

// --eraser-key: name → macOS virtual keycode. macOS can't inject a real ink
// eraser (synthetic tablet-proximity events aren't correlated by AppKit), so an
// eraser-tool contact instead holds a key that drawing apps typically bind to
// their eraser tool. These are the ANSI virtual keycodes, which are
// *positional* (the physical key at that spot on a US layout), not
// layout-aware: on e.g. AZERTY, "a" presses whatever key sits where QWERTY has A.
enum EraserKey {
    static let table: [String: CGKeyCode] = [
        "a": CGKeyCode(kVK_ANSI_A), "b": CGKeyCode(kVK_ANSI_B), "c": CGKeyCode(kVK_ANSI_C),
        "d": CGKeyCode(kVK_ANSI_D), "e": CGKeyCode(kVK_ANSI_E), "f": CGKeyCode(kVK_ANSI_F),
        "g": CGKeyCode(kVK_ANSI_G), "h": CGKeyCode(kVK_ANSI_H), "i": CGKeyCode(kVK_ANSI_I),
        "j": CGKeyCode(kVK_ANSI_J), "k": CGKeyCode(kVK_ANSI_K), "l": CGKeyCode(kVK_ANSI_L),
        "m": CGKeyCode(kVK_ANSI_M), "n": CGKeyCode(kVK_ANSI_N), "o": CGKeyCode(kVK_ANSI_O),
        "p": CGKeyCode(kVK_ANSI_P), "q": CGKeyCode(kVK_ANSI_Q), "r": CGKeyCode(kVK_ANSI_R),
        "s": CGKeyCode(kVK_ANSI_S), "t": CGKeyCode(kVK_ANSI_T), "u": CGKeyCode(kVK_ANSI_U),
        "v": CGKeyCode(kVK_ANSI_V), "w": CGKeyCode(kVK_ANSI_W), "x": CGKeyCode(kVK_ANSI_X),
        "y": CGKeyCode(kVK_ANSI_Y), "z": CGKeyCode(kVK_ANSI_Z),
        "0": CGKeyCode(kVK_ANSI_0), "1": CGKeyCode(kVK_ANSI_1), "2": CGKeyCode(kVK_ANSI_2),
        "3": CGKeyCode(kVK_ANSI_3), "4": CGKeyCode(kVK_ANSI_4), "5": CGKeyCode(kVK_ANSI_5),
        "6": CGKeyCode(kVK_ANSI_6), "7": CGKeyCode(kVK_ANSI_7), "8": CGKeyCode(kVK_ANSI_8),
        "9": CGKeyCode(kVK_ANSI_9),
        "delete": CGKeyCode(kVK_Delete),  // the Backspace-style key above Return
        "forwarddelete": CGKeyCode(kVK_ForwardDelete),
        "space": CGKeyCode(kVK_Space),
        "tab": CGKeyCode(kVK_Tab),
        "escape": CGKeyCode(kVK_Escape),
    ]

    static let acceptedDescription = "a-z, 0-9, delete, forwarddelete, space, tab, escape"

    // Case-insensitive; nil for anything not in the table.
    static func keyCode(forName name: String) -> CGKeyCode? {
        table[name.lowercased()]
    }
}

// Where MouseInjector's output goes. The real one posts CGEvents to the HID
// tap; --selftest swaps in a recorder so the press/release ordering can be
// checked without sending anything to the (in-use) system.
protocol EventPoster {
    func mouse(_ type: CGEventType, at point: CGPoint, clickState: Int64, pressure: Double?)
    func key(_ code: CGKeyCode, down: Bool)
    // Pixel scroll, in the direction the content should move: +dy = content
    // moves down (follows a finger moving down), +dx = content moves right.
    func scroll(dx: Int32, dy: Int32)
}

struct SystemEventPoster: EventPoster {
    func mouse(_ type: CGEventType, at point: CGPoint, clickState: Int64, pressure: Double?) {
        let button: CGMouseButton = (type == .rightMouseDown || type == .rightMouseUp) ? .right : .left
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: button) else { return }
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

    func key(_ code: CGKeyCode, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { return }
        event.post(tap: .cghidEventTap)
    }

    func scroll(dx: Int32, dy: Int32) {
        // wheel1 is vertical (positive = content moves down), wheel2 horizontal.
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.post(tap: .cghidEventTap)
    }
}

// Maps normalized tablet coordinates onto the captured display and turns
// touches into mouse input via CGEvent (the SendInput equivalent). macOS has no
// public way to inject real multi-touch, so gestures are translated:
//
//   one finger   tap = click (double tap = double-click); press and move, or
//                hold still for a moment, = drag (select, move windows)
//   two fingers  move = scroll the window under them; tap = right-click
//   S Pen        acts at once: down = press, move = drag (with pressure);
//                the eraser end optionally also holds `eraserKey`
//
// A finger's mouse-down is therefore NOT sent the instant it lands: until it
// moves, lifts or has rested for `holdDelay`, a second finger can still turn
// the gesture into a scroll. Sending it at once (the old behaviour) made
// every touch a press-and-drag, so there was no way to scroll.
//
// All state is confined to `queue` (packets arrive on the touch thread, the
// hold timer fires on the queue, stop() comes from another thread).
final class MouseInjector {
    private enum Gesture {
        case idle
        case pending(id: Int, point: CGPoint, token: Int)  // finger down, mouse-down not sent yet
        case dragging(id: Int)                             // button is down
        case scrolling                                     // two fingers
        case spent                                         // gesture resolved; waiting for fingers to lift
    }

    static let holdDelay: TimeInterval = 0.15   // rest this long and it becomes a press
    static let dragSlop: CGFloat = 6            // points a finger may wander and still be a tap
    static let twoFingerTapTime: TimeInterval = 0.35

    private let displayID: CGDirectDisplayID
    private let eraserKey: CGKeyCode?  // nil = eraser behaves exactly like stylus
    private let poster: EventPoster
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let queue = DispatchQueue(label: "touch.injector")

    private var gesture = Gesture.idle
    private var fingers: [Int: CGPoint] = [:]  // finger contacts currently down
    private var nextToken = 0
    private var heldEraserKey: CGKeyCode?  // key currently down for the dragging contact
    private var lastPoint = CGPoint.zero
    private var lastUpTime = Date.distantPast
    private var lastUpPoint = CGPoint.zero
    private var clickState: Int64 = 1
    // Scroll bookkeeping.
    private var lastCentroid = CGPoint.zero
    private var scrollRemainder = CGPoint.zero  // sub-pixel carry
    private var scrollTravel: CGFloat = 0
    private var scrollStart = Date.distantPast

    // `schedule` exists so --selftest can fire the hold timer by hand.
    init(displayID: CGDirectDisplayID, eraserKey: CGKeyCode? = nil,
         poster: EventPoster = SystemEventPoster(),
         schedule: ((TimeInterval, @escaping () -> Void) -> Void)? = nil) {
        self.displayID = displayID
        self.eraserKey = eraserKey
        self.poster = poster
        let queue = self.queue
        self.schedule = schedule ?? { delay, work in queue.asyncAfter(deadline: .now() + delay, execute: work) }
    }

    private func mapToGlobal(_ nx: Float, _ ny: Float) -> CGPoint {
        let bounds = CGDisplayBounds(displayID)
        return CGPoint(x: bounds.minX + CGFloat(nx) * (bounds.width - 1),
                       y: bounds.minY + CGFloat(ny) * (bounds.height - 1))
    }

    private func post(_ type: CGEventType, _ point: CGPoint, clickState: Int64 = 0,
                      pressure: Double? = nil) {
        poster.mouse(type, at: point, clickState: clickState, pressure: pressure)
    }

    // Key-up always follows the mouse-up so the app sees the stroke end while
    // the eraser tool is still selected.
    private func releaseEraserKey() {
        guard let code = heldEraserKey else { return }
        heldEraserKey = nil
        poster.key(code, down: false)
    }

    // Synthetic events carry their own click count — the OS only computes it
    // for hardware clicks. Same spot + quick succession must count up or
    // double-click never works from the tablet.
    private func pressButton(at point: CGPoint, pressure: Double?) {
        if Date().timeIntervalSince(lastUpTime) < 0.4,
           hypot(point.x - lastUpPoint.x, point.y - lastUpPoint.y) < 8 {
            clickState += 1
        } else {
            clickState = 1
        }
        post(.leftMouseDown, point, clickState: clickState, pressure: pressure)
    }

    private func releaseButton(at point: CGPoint, pressure: Double?) {
        lastUpTime = Date()
        lastUpPoint = point
        post(.leftMouseUp, point, clickState: clickState, pressure: pressure)
        releaseEraserKey()
    }

    private func centroid() -> CGPoint {
        let n = CGFloat(max(fingers.count, 1))
        return CGPoint(x: fingers.values.reduce(0) { $0 + $1.x } / n,
                       y: fingers.values.reduce(0) { $0 + $1.y } / n)
    }

    func handle(_ packet: TouchPacket) {
        queue.sync { handleOnQueue(packet) }
    }

    private func handleOnQueue(_ packet: TouchPacket) {
        diagTrace("TOUCH \(packet.type) tool=\(packet.tool)")
        let point = mapToGlobal(packet.nx, packet.ny)
        lastPoint = point
        let id = Int(packet.pointerId)
        let isFinger = packet.tool == 0
        // Stylus/eraser carry pressure (0..1024 → 0..1) while in contact.
        let penPressure: Double? = isFinger ? nil : Double(packet.pressure) / 1024.0

        switch packet.type {
        case .down:
            if !isFinger {
                // The pen acts immediately (drawing must not lag) and only when
                // nothing else owns the pointer.
                guard case .idle = gesture else { return }
                if packet.tool == 2, let eraserKey {
                    // Before the mouse-down, so the app switches tool before the stroke.
                    heldEraserKey = eraserKey
                    poster.key(eraserKey, down: true)
                }
                pressButton(at: point, pressure: penPressure)
                gesture = .dragging(id: id)
                return
            }
            fingers[id] = point
            switch gesture {
            case .idle:
                nextToken += 1
                let token = nextToken
                gesture = .pending(id: id, point: point, token: token)
                schedule(Self.holdDelay) { [weak self] in self?.holdElapsed(token: token) }
            case .pending:
                // A second finger before the first became a press: scroll.
                gesture = .scrolling
                lastCentroid = centroid()
                scrollRemainder = .zero
                scrollTravel = 0
                scrollStart = Date()
                // Scroll events go to the window under the cursor.
                post(.mouseMoved, lastCentroid)
            case .dragging, .scrolling, .spent:
                break  // extra fingers don't change a gesture already under way
            }

        case .move:
            if isFinger, fingers[id] != nil { fingers[id] = point }
            switch gesture {
            case .dragging(let owner) where owner == id:
                post(.leftMouseDragged, point, clickState: clickState, pressure: penPressure)
            case .pending(let owner, let start, _) where owner == id:
                if hypot(point.x - start.x, point.y - start.y) > Self.dragSlop {
                    // Press where the finger landed, then drag to where it is now.
                    pressButton(at: start, pressure: nil)
                    gesture = .dragging(id: id)
                    post(.leftMouseDragged, point, clickState: clickState)
                }
            case .scrolling where isFinger && fingers.count >= 2:
                let now = centroid()
                let dx = now.x - lastCentroid.x + scrollRemainder.x
                let dy = now.y - lastCentroid.y + scrollRemainder.y
                scrollTravel += hypot(now.x - lastCentroid.x, now.y - lastCentroid.y)
                lastCentroid = now
                let stepX = dx.rounded(.towardZero), stepY = dy.rounded(.towardZero)
                scrollRemainder = CGPoint(x: dx - stepX, y: dy - stepY)
                if stepX != 0 || stepY != 0 {
                    poster.scroll(dx: Int32(stepX), dy: Int32(stepY))
                }
            case .idle:
                post(.mouseMoved, point)
            default:
                break
            }

        case .up, .cancel:
            if isFinger { fingers[id] = nil }
            switch gesture {
            case .dragging(let owner) where owner == id:
                releaseButton(at: point, pressure: isFinger ? nil : 0.0)
                gesture = fingers.isEmpty ? .idle : .spent
            case .pending(let owner, let start, _) where owner == id:
                if packet.type == .up {  // a tap: click where the finger landed
                    pressButton(at: start, pressure: nil)
                    releaseButton(at: start, pressure: nil)
                }
                gesture = fingers.isEmpty ? .idle : .spent
            case .scrolling where isFinger:
                // Two fingers that barely moved and left quickly: right-click.
                if packet.type == .up, scrollTravel < Self.dragSlop,
                   Date().timeIntervalSince(scrollStart) < Self.twoFingerTapTime {
                    post(.rightMouseDown, lastCentroid, clickState: 1)
                    post(.rightMouseUp, lastCentroid, clickState: 1)
                }
                gesture = fingers.isEmpty ? .idle : .spent
            case .spent where fingers.isEmpty:
                gesture = .idle
            default:
                break
            }

        case .hoverMove:
            if case .idle = gesture {  // S Pen hovering; don't disturb a gesture
                post(.mouseMoved, point)
            }
        case .hoverExit:
            break  // a mouse never leaves range
        }
    }

    // The finger has rested without moving: treat it as a press (so a
    // press-and-hold, or a drag that starts very slowly, still works).
    private func holdElapsed(token: Int) {
        guard case .pending(let id, let point, let current) = gesture, current == token else { return }
        pressButton(at: point, pressure: nil)
        gesture = .dragging(id: id)
    }

    // The tablet disconnected mid-gesture: don't leave the button (or the
    // eraser key) stuck down, and forget any half-finished gesture.
    func releaseStuckButton() {
        queue.sync {
            if case .dragging = gesture {
                post(.leftMouseUp, lastPoint)
                releaseEraserKey()
            }
            gesture = .idle
            fingers.removeAll()
            nextToken += 1  // cancels a hold timer still in flight
        }
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

    init(host: String, port: Int, displayID: CGDirectDisplayID, key: SymmetricKey? = nil,
         eraserKey: CGKeyCode? = nil) {
        self.host = host
        self.port = port
        self.injector = MouseInjector(displayID: displayID, eraserKey: eraserKey)
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
