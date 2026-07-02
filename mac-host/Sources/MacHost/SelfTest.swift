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

    // Discovery reply parsing.
    expect(Discovery.deviceName(fromReply: "EXTDISP!v1|Samsung SM-X910|5000") == "Samsung SM-X910",
           "discovery reply name")
    expect(Discovery.deviceName(fromReply: "EXTDISP!v1|NoPort") == "NoPort",
           "discovery reply name without port")
    expect(Discovery.deviceName(fromReply: "EXTDISP?v1") == nil, "query is not a reply")
    expect(Discovery.deviceName(fromReply: "garbage") == nil, "garbage rejected")

    if failures == 0 {
        print("selftest: OK (touch v2 parse, audio wire format, discovery reply parse)")
        return 0
    }
    print("selftest: \(failures) failure(s)")
    return 1
}
