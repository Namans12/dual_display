import CryptoKit
import Darwin
import Foundation

// Low-latency UDP video (--udp, Wi-Fi): each Annex-B NAL — AES-GCM-sealed
// first when paired (the EXUD header must stay plaintext for reassembly) — is
// split into datagrams behind a 12-byte big-endian header:
//   u32 magic 'EXUD' | u32 nalSeq | u16 fragIndex | u16 fragCount
// with payloads capped at 1400 bytes to stay under a ~1500 MTU. The receiver
// reassembles by nalSeq and drops incomplete NALs; loss shows as a brief
// glitch that clears on the next keyframe. Touch/audio stay on TCP.
enum Udp {
    static let magic: [UInt8] = [0x45, 0x58, 0x55, 0x44]  // 'EXUD'
    static let payloadMax = 1400
    static let headerSize = 12

    // Pure so --selftest can pin the wire format.
    static func fragments(of blob: Data, nalSeq: UInt32) -> [Data] {
        guard !blob.isEmpty else { return [] }
        let count = (blob.count + payloadMax - 1) / payloadMax
        guard count <= 0xFFFF else { return [] }  // absurd NAL; drop
        var out: [Data] = []
        out.reserveCapacity(count)
        for index in 0..<count {
            let start = index * payloadMax
            let end = min(start + payloadMax, blob.count)
            var packet = Data(capacity: headerSize + (end - start))
            packet.append(contentsOf: magic)
            packet.append(contentsOf: [UInt8(nalSeq >> 24), UInt8((nalSeq >> 16) & 0xff),
                                       UInt8((nalSeq >> 8) & 0xff), UInt8(nalSeq & 0xff)])
            packet.append(contentsOf: [UInt8(index >> 8), UInt8(index & 0xff)])
            packet.append(contentsOf: [UInt8(count >> 8), UInt8(count & 0xff)])
            packet.append(blob[blob.startIndex + start ..< blob.startIndex + end])
            out.append(packet)
        }
        return out
    }
}

final class UdpVideoSender {
    private let fd: Int32
    private var destination = sockaddr_in()
    private let sealer: Sealer?
    private var nalSeq: UInt32 = 0
    private var warnedSendFailure = false
    // Periodic throughput line (ffmpeg -stats equivalent) — also the tell for a
    // silently stalled pipeline.
    private var statPackets = 0
    private var statBytes = 0
    private var statDroppedNals = 0
    private var statStart = Date()

    init(host: String, port: Int, key: SymmetricKey?) throws {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            throw MacHostError.socket("UDP socket() failed")
        }
        // A keyframe bursts dozens of fragments at once; a big send buffer keeps
        // the OS from dropping them on the floor.
        var sendBuffer: Int32 = 4 << 20
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout<Int32>.size))
        // Non-blocking: this is called on the VideoToolbox callback thread, and a
        // blocking sendto against a congested Wi-Fi egress stalls the whole
        // encoder (observed: pipeline froze ~1 s in against a power-saving
        // tablet). Real-time video would rather drop than wait.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = in_port_t(UInt16(port).bigEndian)
        guard inet_pton(AF_INET, host, &destination.sin_addr) == 1 else {
            close(fd)
            throw MacHostError.socket("--udp needs a numeric IPv4 tablet address (got \(host))")
        }
        sealer = key.map { Sealer(key: $0, domain: 0x01) }
    }

    deinit {
        close(fd)
    }

    // Called serially from the VideoToolbox output callback.
    func send(nal: Data) {
        var blob = nal
        if let sealer {
            guard let sealed = sealer.seal(nal) else { return }
            blob = sealed
        }
        let packets = Udp.fragments(of: blob, nalSeq: nalSeq)
        nalSeq &+= 1
        // Keyframes burst dozens-to-hundreds of fragments back-to-back, and a NAL
        // missing one fragment never reassembles — on Wi-Fi (especially slow or
        // mesh paths) the tail of a big burst is exactly what gets dropped. Pace
        // large NALs: 1 ms every 8 fragments (a 36-fragment IDR spreads over
        // ~4 ms; a 300-fragment one over ~37 ms) — small P-frames go unpaced.
        let paceEvery = packets.count > 16 ? 8 : 0
        for (index, packet) in packets.enumerated() {
            if paceEvery > 0 && index > 0 && index % paceEvery == 0 {
                usleep(1000)
            }
            let sent = packet.withUnsafeBytes { raw -> Int in
                withUnsafePointer(to: &destination) { dest in
                    dest.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        sendto(fd, raw.baseAddress, raw.count, 0, sa,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if sent > 0 {
                statPackets += 1
                statBytes += sent
            } else if sent < 0 {
                if errno == EAGAIN || errno == ENOBUFS {
                    // Egress full: the rest of this NAL is dead anyway (a NAL
                    // missing one fragment never reassembles) — drop it whole
                    // and let the next keyframe recover. Never block encoding.
                    statDroppedNals += 1
                    break
                }
                if !warnedSendFailure {
                    warnedSendFailure = true
                    fputs("UDP send failed (\(String(cString: strerror(errno)))) — continuing.\n", stderr)
                }
            }
        }
        let elapsed = Date().timeIntervalSince(statStart)
        if elapsed >= 5 {
            let mbps = Double(statBytes) * 8 / elapsed / 1_000_000
            var line = String(format: "UDP: %.0f pkts/s, %.1f Mbps", Double(statPackets) / elapsed, mbps)
            if statDroppedNals > 0 {
                line += " (\(statDroppedNals) NALs dropped — egress congested)"
            }
            print(line)
            statPackets = 0
            statBytes = 0
            statDroppedNals = 0
            statStart = Date()
        }
    }
}
