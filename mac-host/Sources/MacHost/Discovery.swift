import Darwin
import Foundation

// LAN discovery client (parity with the Windows sender). The tablet's
// DiscoveryResponder listens on UDP 5002 and answers a broadcast query:
//   query  (host → broadcast): "EXTDISP?v1"
//   reply  (tablet → host):    "EXTDISP!v1|<device name>|<video port>"
// We send to each local interface's subnet-directed broadcast address (plus
// the global 255.255.255.255 as a last resort) — limited broadcast alone can
// exit the wrong adapter on a multi-NIC host.
enum Discovery {
    static let port: UInt16 = 5002
    static let query = "EXTDISP?v1"
    static let replyPrefix = "EXTDISP!v1|"

    // Subnet-directed broadcast address for every up, non-loopback IPv4
    // interface (ip | ~mask), from getifaddrs.
    static func broadcastAddresses() -> [in_addr] {
        var out: [in_addr] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return out }
        defer { freeifaddrs(ifap) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cursor {
            defer { cursor = ptr.pointee.ifa_next }
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addrPtr = ptr.pointee.ifa_addr,
                  addrPtr.pointee.sa_family == sa_family_t(AF_INET),
                  let maskPtr = ptr.pointee.ifa_netmask else { continue }
            let addr = addrPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let mask = maskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            if addr == 0 || mask == 0 { continue }
            out.append(in_addr(s_addr: (addr & mask) | ~mask))
        }
        out.append(in_addr(s_addr: INADDR_BROADCAST))
        return out
    }

    // Broadcasts the query and returns the first responding tablet's IP, or nil
    // after `timeoutSeconds`. The caller then connects over TCP as if --host had
    // been given.
    static func findTablet(timeoutSeconds: Double) -> String? {
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return nil }
        defer { close(sock) }

        var broadcast: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 800_000)  // 800 ms recv window
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let targets = broadcastAddresses()
        let queryBytes = Array(query.utf8)
        let deadline = Date(timeIntervalSinceNow: timeoutSeconds)

        while !g_stop.isSet && Date() < deadline {
            for target in targets {
                var dest = sockaddr_in()
                dest.sin_family = sa_family_t(AF_INET)
                dest.sin_port = Discovery.port.bigEndian
                dest.sin_addr = target
                _ = queryBytes.withUnsafeBytes { raw in
                    withUnsafePointer(to: &dest) { destPtr in
                        destPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            sendto(sock, raw.baseAddress, raw.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }

            var buffer = [UInt8](repeating: 0, count: 256)
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                withUnsafeMutablePointer(to: &from) { fromPtr in
                    fromPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        recvfrom(sock, raw.baseAddress, raw.count, 0, sa, &fromLen)
                    }
                }
            }
            if n > 0, let reply = String(bytes: buffer[0..<n], encoding: .utf8),
               let name = deviceName(fromReply: reply) {
                var ipBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &from.sin_addr, &ipBuffer, socklen_t(INET_ADDRSTRLEN))
                let ip = String(cString: ipBuffer)
                print("Found tablet: \(name) at \(ip)")
                return ip
            }
        }
        return nil
    }

    // Parses the device name out of "EXTDISP!v1|<name>|<port>", or nil if the
    // reply doesn't carry the expected prefix.
    static func deviceName(fromReply reply: String) -> String? {
        guard reply.hasPrefix(replyPrefix) else { return nil }
        return String(reply.dropFirst(replyPrefix.count).prefix { $0 != "|" })
    }
}

// Shared stop flag (set on SIGINT/SIGTERM) so discovery's retry loop exits
// promptly during shutdown.
let g_stop = AtomicFlag()
