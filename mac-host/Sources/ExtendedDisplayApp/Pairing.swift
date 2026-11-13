import Foundation

// The pairing code is the shared secret behind the AES-256-GCM link. It lives in
// the same file the old bash launcher read, so existing pairings keep working.
struct PairingStore {
    // No I/O/0/1 — unambiguous when read off a screen and typed on a tablet.
    static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    static let codeLength = 8

    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("pairing.code") }

    static func generateCode<G: RandomNumberGenerator>(using rng: inout G) -> String {
        String((0..<codeLength).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] })
    }

    static func generateCode() -> String {
        var rng = SystemRandomNumberGenerator()
        return generateCode(using: &rng)
    }

    // Deliberately lenient: the bash launcher accepted any non-empty first line,
    // and any string is a valid PBKDF2 input, so a hand-written code must keep
    // working rather than be silently replaced.
    func load() -> String? {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let first = text.split(maxSplits: 1, omittingEmptySubsequences: false, whereSeparator: \.isNewline).first ?? ""
        let code = first.filter { !$0.isWhitespace }
        return code.isEmpty ? nil : String(code)
    }

    // Reuses an existing code; only creates one when there is none.
    func loadOrCreate() throws -> String {
        if let code = load() { return code }
        let code = PairingStore.generateCode()
        try save(code)
        return code
    }

    // Written 0600 from the start (temp file + rename) so the secret is never
    // briefly world-readable. Only called for first creation and the explicit
    // "New code" action.
    func save(_ code: String) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        let tmp = directory.appendingPathComponent(".pairing.code.\(UUID().uuidString)")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw PairingError.io(String(cString: strerror(errno))) }
        let bytes = Array((code + "\n").utf8)
        var written = 0
        while written < bytes.count {
            let n = bytes[written...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n <= 0 {
                let reason = String(cString: strerror(errno))
                close(fd); unlink(tmp.path)
                throw PairingError.io(reason)
            }
            written += n
        }
        fsync(fd)
        close(fd)
        guard rename(tmp.path, fileURL.path) == 0 else {
            let reason = String(cString: strerror(errno))
            unlink(tmp.path)
            throw PairingError.io(reason)
        }
    }
}

enum PairingError: Error, CustomStringConvertible {
    case io(String)
    var description: String {
        switch self {
        case .io(let reason): return "Couldn't save the pairing code: \(reason)"
        }
    }
}
