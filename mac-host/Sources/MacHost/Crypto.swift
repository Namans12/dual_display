import CommonCrypto  // PBKDF2 — CryptoKit has no KDF
import CryptoKit
import Foundation

// PIN pairing + AES-256-GCM, matching the Windows sender (BCrypt) and the
// Android receiver (javax.crypto) byte-for-byte. See SECURITY.md.
//   KDF:   PBKDF2-HMAC-SHA256, salt "ExtDisplay/v1" (13 bytes, no NUL),
//          200 000 iterations, 32-byte key.
//   Frame: [12B nonce][ciphertext][16B tag]; nonce = 1 domain byte + 3 random
//          bytes (per session) + 8-byte big-endian counter (per message).
//   Domains: touch (tablet→host) 0x00, video 0x01, audio 0x02.
enum PairingCrypto {
    static let saltBytes = Array("ExtDisplay/v1".utf8)  // 13 bytes, no NUL
    static let iterations = 200_000
    static let keyLength = 32

    static func deriveKey(code: String) -> SymmetricKey? {
        let password = Array(code.utf8)
        var derived = [UInt8](repeating: 0, count: keyLength)
        let status = password.withUnsafeBufferPointer { pw in
            saltBytes.withUnsafeBufferPointer { salt in
                derived.withUnsafeMutableBufferPointer { out in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pw.baseAddress, pw.count,
                        salt.baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        out.baseAddress, out.count)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return SymmetricKey(data: Data(derived))
    }

    static func hex(_ key: SymmetricKey) -> String {
        key.withUnsafeBytes { raw in
            raw.map { String(format: "%02x", $0) }.joined()
        }
    }
}

// One per channel/direction: encrypts messages with a monotonic per-message
// nonce (never reused under the key), matching the receiver's Sealer.
final class Sealer {
    private let key: SymmetricKey
    private var prefix: [UInt8]
    private var counter: UInt64 = 0

    init(key: SymmetricKey, domain: UInt8) {
        self.key = key
        var p = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, 3, &p[1])
        p[0] = domain
        prefix = p
    }

    // Returns nonce || ciphertext || tag (CryptoKit's `.combined`, which is
    // exactly the wire frame).
    func seal(_ plaintext: Data) -> Data? {
        counter += 1
        var nonceBytes = prefix
        withUnsafeBytes(of: counter.bigEndian) { nonceBytes.append(contentsOf: $0) }
        guard let nonce = try? AES.GCM.Nonce(data: nonceBytes),
              let box = try? AES.GCM.seal(plaintext, using: key, nonce: nonce) else {
            return nil
        }
        return box.combined
    }

    // Decrypts a [12B nonce][ct][16B tag] frame; nil on auth failure. Static —
    // the receiving side has no per-connection nonce state of its own.
    static func open(_ frame: Data, key: SymmetricKey) -> Data? {
        guard frame.count >= 12 + 16, let box = try? AES.GCM.SealedBox(combined: frame) else {
            return nil
        }
        return try? AES.GCM.open(box, using: key)
    }

    // The 8-byte big-endian counter embedded in a frame's nonce, for the
    // touch replay guard.
    static func nonceCounter(_ frame: Data) -> UInt64? {
        guard frame.count >= 12 else { return nil }
        var value: UInt64 = 0
        for byte in frame[frame.startIndex + 4 ..< frame.startIndex + 12] {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }

    // The 4-byte per-session prefix (domain byte + 3 random). The tablet picks
    // a fresh prefix and resets its counter to 0 every time it re-keys (on the
    // EXVE latch and on entering a code), so the replay guard resets its
    // counter baseline when the prefix changes rather than dropping the whole
    // new session.
    static func noncePrefix(_ frame: Data) -> [UInt8]? {
        guard frame.count >= 4 else { return nil }
        return Array(frame[frame.startIndex ..< frame.startIndex + 4])
    }
}

// Crypto self-test (parity with the Windows `--crypto-selftest`), plus a
// hard-coded golden KDF vector so byte-parity is checked without Windows
// present.
func runCryptoSelfTest() -> Int32 {
    var failures = 0
    func expect(_ condition: Bool, _ label: String) {
        if !condition { print("crypto self-test: \(label) FAILED"); failures += 1 }
    }

    guard let k1 = PairingCrypto.deriveKey(code: "TESTCODE"),
          let k2 = PairingCrypto.deriveKey(code: "TESTCODE"),
          let kWrong = PairingCrypto.deriveKey(code: "WRONGXXX") else {
        print("crypto self-test: KDF FAILED"); return 1
    }
    expect(PairingCrypto.hex(k1) == PairingCrypto.hex(k2), "KDF deterministic")
    expect(PairingCrypto.hex(k1) != PairingCrypto.hex(kWrong), "distinct codes → distinct keys")

    // Golden vector — independently computed:
    //   python3 -c "import hashlib; print(hashlib.pbkdf2_hmac(
    //     'sha256', b'TESTCODE', b'ExtDisplay/v1', 200000, 32).hex())"
    let golden = "3961c9653235be40c2cdf3e04ff57dcd4994fd6a6b40c59452db2b378e66c381"
    expect(PairingCrypto.hex(k1) == golden, "KDF matches golden vector")

    let sealer = Sealer(key: k1, domain: 0x01)
    let message = Data("hello extended display touch+video payload 12345".utf8)
    guard let frame = sealer.seal(message) else {
        print("crypto self-test: encrypt FAILED"); return 1
    }
    expect(Sealer.open(frame, key: k2) == message, "GCM round-trip")
    expect(Sealer.open(frame, key: kWrong) == nil, "wrong key rejected")

    // Touch frame size: 12 nonce + 28 plaintext + 16 tag = 56.
    if let touchFrame = sealer.seal(Data(count: 28)) {
        expect(touchFrame.count == 56, "sealed touch frame is 56 bytes")
    } else {
        expect(false, "seal 28-byte touch packet")
    }

    if failures == 0 {
        print("crypto self-test: OK (KDF deterministic + golden-matched, GCM round-trip, wrong key rejected)")
        return 0
    }
    return 1
}
