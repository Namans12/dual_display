import CoreGraphics
import Foundation

// Pure-logic self-tests, runnable anywhere with `--selftest` — the Mac
// counterpart of the Windows sender's `--crypto-selftest` pattern (this
// machine class has no XCTest: CommandLineTools-only Macs can't `swift test`).
func runSelfTests() -> Int32 {
    var failures = 0
    func expect(_ condition: Bool, _ label: String) {
        if !condition {
            print("selftest FAIL: \(label)")
            failures += 1
        }
    }

    // Touch v2 golden vector — byte-for-byte what MainActivity's
    // TouchUplink.send() emits (big-endian ByteBuffer):
    // down, stylus, pointer 0 of 1, pressure 512, nx 0.5, ny 0.25, ts 0x12345678.
    let golden: [UInt8] = [
        0x48, 0x58, 0x54, 0x50,             // 'HXTP'
        0x00, 0x02,                         // version 2
        0x00,                               // type = down
        0x01,                               // tool = stylus
        0x00,                               // pointerId
        0x01,                               // pointerCount
        0x02, 0x00,                         // pressure 512
        0x3F, 0x00, 0x00, 0x00,             // nx 0.5f
        0x3E, 0x80, 0x00, 0x00,             // ny 0.25f
        0x00, 0x00, 0x00, 0x00, 0x12, 0x34, 0x56, 0x78,  // timestampUs
    ]
    if let packet = parseTouchPacket(golden) {
        expect(packet.type == .down, "touch type")
        expect(packet.tool == 1, "touch tool")
        expect(packet.pointerId == 0, "touch pointerId")
        expect(packet.pointerCount == 1, "touch pointerCount")
        expect(packet.pressure == 512, "touch pressure")
        expect(packet.nx == 0.5, "touch nx")
        expect(packet.ny == 0.25, "touch ny")
        expect(packet.timestampUs == 0x1234_5678, "touch timestamp")
    } else {
        expect(false, "golden touch packet must parse")
    }

    var wrongMagic = golden
    wrongMagic[0] = 0x00
    expect(parseTouchPacket(wrongMagic) == nil, "wrong magic rejected")

    var wrongVersion = golden
    wrongVersion[5] = 0x01
    expect(parseTouchPacket(wrongVersion) == nil, "v1 packet rejected")

    expect(parseTouchPacket(Array(golden.dropLast())) == nil, "short packet rejected")

    var overPressure = golden
    overPressure[10] = 0x07
    overPressure[11] = 0xD0  // 2000
    expect(parseTouchPacket(overPressure)?.pressure == 1024, "pressure clamped to 1024")

    // Audio wire format: header layout and float→S16 conversion.
    let header = audioHeader(rate: 48000, encrypted: true, delayMs: 40)
    expect(header.count == 16, "audio header is 16 bytes")
    expect(Array(header.prefix(4)) == [0x45, 0x58, 0x41, 0x55], "audio magic EXAU")
    expect(Array(header[4..<8]) == [0x00, 0x00, 0xBB, 0x80], "audio rate 48000 BE")
    expect(Array(header[8..<10]) == [0x00, 0x02], "audio channels 2")
    expect(header[10] == 0x10, "audio bits 16")
    expect(header[11] == 0x01, "audio encrypted flag")
    expect(Array(header[12..<14]) == [0x00, 0x28], "audio delayMs 40 BE")
    let pcm = floatBuffersToS16Stereo([[0.5, 2.0, -3.0], [-0.5, 1.0, 0.0]])
    expect(pcm.count == 12, "3 stereo frames = 12 bytes")
    let samples = pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    expect(samples[0] == 16383 && samples[1] == -16383, "0.5/-0.5 scale")
    expect(samples[2] == 32767 && samples[4] == -32768, "clamped at rails")

    // UDP fragmentation: 3000-byte blob → 1400 + 1400 + 200, EXUD headers BE.
    let frags = Udp.fragments(of: Data(repeating: 0xAB, count: 3000), nalSeq: 0x0102_0304)
    expect(frags.count == 3, "3000B → 3 fragments")
    if frags.count == 3 {
        expect(frags[0].count == 12 + 1400 && frags[2].count == 12 + 200, "fragment sizes")
        expect(Array(frags[0].prefix(4)) == [0x45, 0x58, 0x55, 0x44], "EXUD magic")
        expect(Array(frags[1][4..<8]) == [0x01, 0x02, 0x03, 0x04], "nalSeq BE")
        expect(Array(frags[1][8..<10]) == [0x00, 0x01], "fragIndex 1")
        expect(Array(frags[1][10..<12]) == [0x00, 0x03], "fragCount 3")
        expect(frags[2][12] == 0xAB, "payload bytes")
    }
    expect(Udp.fragments(of: Data([0x01]), nalSeq: 0).count == 1, "1B → 1 fragment")
    expect(Udp.fragments(of: Data(), nalSeq: 0).isEmpty, "empty → none")

    // Discovery reply parsing.
    expect(Discovery.deviceName(fromReply: "EXTDISP!v1|Samsung SM-X910|5000") == "Samsung SM-X910",
           "discovery reply name")
    expect(Discovery.deviceName(fromReply: "EXTDISP!v1|NoPort") == "NoPort",
           "discovery reply name without port")
    expect(Discovery.deviceName(fromReply: "EXTDISP?v1") == nil, "query is not a reply")
    expect(Discovery.deviceName(fromReply: "garbage") == nil, "garbage rejected")

    // --eraser-key name table. Expected values are the literal macOS virtual
    // keycodes (not the kVK_* constants the table is built from) so a typo in
    // the table can't pass by being compared against itself.
    expect(EraserKey.keyCode(forName: "a") == 0, "eraser key a = 0x00")
    expect(EraserKey.keyCode(forName: "e") == 14, "eraser key e = 0x0E")
    expect(EraserKey.keyCode(forName: "z") == 6, "eraser key z = 0x06")
    expect(EraserKey.keyCode(forName: "0") == 29, "eraser key 0 = 0x1D")
    expect(EraserKey.keyCode(forName: "1") == 18, "eraser key 1 = 0x12")
    expect(EraserKey.keyCode(forName: "9") == 25, "eraser key 9 = 0x19")
    expect(EraserKey.keyCode(forName: "delete") == 51, "eraser key delete = 0x33")
    expect(EraserKey.keyCode(forName: "forwarddelete") == 117, "eraser key forwarddelete = 0x75")
    expect(EraserKey.keyCode(forName: "space") == 49, "eraser key space = 0x31")
    expect(EraserKey.keyCode(forName: "tab") == 48, "eraser key tab = 0x30")
    expect(EraserKey.keyCode(forName: "escape") == 53, "eraser key escape = 0x35")
    expect(EraserKey.keyCode(forName: "E") == EraserKey.keyCode(forName: "e"), "eraser key case-insensitive (E)")
    expect(EraserKey.keyCode(forName: "Escape") == 53, "eraser key case-insensitive (Escape)")
    expect(EraserKey.table.count == 41, "eraser key table has 26 letters + 10 digits + 5 named")
    expect(Set(EraserKey.table.values).count == EraserKey.table.count, "eraser keycodes are distinct")
    for bad in ["", "ee", "f1", "enter", "return", "shift", " e", "é"] {
        expect(EraserKey.keyCode(forName: bad) == nil, "eraser key '\(bad)' rejected")
    }
    do {
        _ = try parseOptions(["MacHost", "--eraser-key", "f13"])
        expect(false, "--eraser-key f13 must throw")
    } catch MacHostError.invalidArgument(let message) {
        expect(message.contains("f13") && message.contains("forwarddelete"),
               "--eraser-key error names the bad value and lists accepted names")
    } catch {
        expect(false, "--eraser-key f13 must throw invalidArgument")
    }
    expect((try? parseOptions(["MacHost", "--eraser-key", "E"]))?.eraserKey == 14, "--eraser-key E parses to 0x0E")
    expect((try? parseOptions(["MacHost"]))?.eraserKey == nil, "--eraser-key unset by default")
    do {
        _ = try parseOptions(["MacHost", "--eraser-key"])
        expect(false, "--eraser-key without a value must throw")
    } catch {}

    // Eraser key press/release ordering, against a recording poster (nothing
    // is posted to the system).
    final class Recorder: EventPoster {
        var log: [String] = []
        func mouse(_ type: CGEventType, at point: CGPoint, clickState: Int64, pressure: Double?) {
            switch type {
            case .leftMouseDown: log.append("mouseDown")
            case .leftMouseUp: log.append("mouseUp")
            case .leftMouseDragged: log.append("drag")
            case .mouseMoved: log.append("move")
            default: log.append("mouse?")
            }
        }
        func key(_ code: CGKeyCode, down: Bool) { log.append("key\(code)\(down ? "Down" : "Up")") }
    }
    func pkt(_ type: TouchPacket.EventType, tool: UInt8, id: UInt8 = 0) -> TouchPacket {
        TouchPacket(type: type, tool: tool, pointerId: id, pointerCount: 1,
                    pressure: type == .hoverMove || type == .hoverExit ? 0 : 512,
                    nx: 0.5, ny: 0.5, timestampUs: 0)
    }
    func run(eraserKey: CGKeyCode?, _ body: (MouseInjector) -> Void) -> [String] {
        let recorder = Recorder()
        body(MouseInjector(displayID: CGMainDisplayID(), eraserKey: eraserKey, poster: recorder))
        return recorder.log
    }
    let eKey: CGKeyCode = 14

    expect(run(eraserKey: eKey) { i in
        i.handle(pkt(.down, tool: 2)); i.handle(pkt(.move, tool: 2)); i.handle(pkt(.up, tool: 2))
    } == ["key14Down", "mouseDown", "drag", "mouseUp", "key14Up"], "eraser: key down, mouse down … mouse up, key up")
    expect(run(eraserKey: eKey) { i in
        i.handle(pkt(.down, tool: 2)); i.handle(pkt(.cancel, tool: 2))
    } == ["key14Down", "mouseDown", "mouseUp", "key14Up"], "eraser cancel releases key after mouse up")
    expect(run(eraserKey: eKey) { i in
        i.handle(pkt(.down, tool: 1)); i.handle(pkt(.move, tool: 1)); i.handle(pkt(.up, tool: 1))
    } == ["mouseDown", "drag", "mouseUp"], "stylus never presses the key")
    expect(run(eraserKey: eKey) { i in
        i.handle(pkt(.down, tool: 0)); i.handle(pkt(.up, tool: 0))
    } == ["mouseDown", "mouseUp"], "finger never presses the key")
    expect(run(eraserKey: eKey) { i in
        i.handle(pkt(.hoverMove, tool: 2)); i.handle(pkt(.hoverMove, tool: 2)); i.handle(pkt(.hoverExit, tool: 2))
    } == ["move", "move"], "eraser hover never presses the key")
    expect(run(eraserKey: eKey) { i in
        i.handle(pkt(.down, tool: 2)); i.releaseStuckButton(); i.releaseStuckButton()
    } == ["key14Down", "mouseDown", "mouseUp", "key14Up"], "disconnect mid-contact releases the key once")
    expect(run(eraserKey: eKey) { i in
        i.releaseStuckButton()
    }.isEmpty, "releaseStuckButton with nothing held posts nothing")
    expect(run(eraserKey: eKey) { i in
        i.handle(pkt(.down, tool: 0, id: 0)); i.handle(pkt(.down, tool: 2, id: 1))
        i.handle(pkt(.up, tool: 2, id: 1)); i.handle(pkt(.up, tool: 0, id: 0))
    } == ["mouseDown", "mouseUp"], "eraser contact that doesn't own the pointer presses no key")
    expect(run(eraserKey: eKey) { i in
        i.handle(pkt(.down, tool: 2, id: 0)); i.handle(pkt(.up, tool: 2, id: 1))
    } == ["key14Down", "mouseDown"], "up from a non-owner pointer leaves the key held")
    expect(run(eraserKey: eKey) { i in
        i.handle(pkt(.down, tool: 2)); i.handle(pkt(.up, tool: 2))
        i.handle(pkt(.down, tool: 1)); i.handle(pkt(.up, tool: 1))
        i.handle(pkt(.down, tool: 2)); i.handle(pkt(.up, tool: 2))
    } == ["key14Down", "mouseDown", "mouseUp", "key14Up", "mouseDown", "mouseUp",
          "key14Down", "mouseDown", "mouseUp", "key14Up"], "key state resets between contacts")
    expect(run(eraserKey: nil) { i in
        i.handle(pkt(.down, tool: 2)); i.handle(pkt(.move, tool: 2)); i.handle(pkt(.up, tool: 2))
        i.handle(pkt(.down, tool: 2)); i.releaseStuckButton()
    } == ["mouseDown", "drag", "mouseUp", "mouseDown", "mouseUp"], "without --eraser-key the eraser acts like stylus")

    if failures == 0 {
        print("selftest: OK (touch v2 parse, audio wire format, UDP fragmentation, discovery reply parse, eraser key)")
        return 0
    }
    print("selftest: \(failures) failure(s)")
    return 1
}
