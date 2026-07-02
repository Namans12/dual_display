# Security design — PIN pairing + encrypted LAN streams

Status: **in progress.** Threat model, design, and staging for encrypting the
Wi-Fi/USB link so it's safe on an untrusted LAN.

## Threat model

On an untrusted LAN (café, office, dorm) the open/plaintext streams allow:
1. **Unauthorized input injection** — anyone who reaches touch port 5001 can
   drive the PC (move the cursor, click, type via the pen path). *Highest risk.*
2. **Screen eavesdropping** — anyone can connect to video port 5000, or sniff the
   Wi-Fi, and watch the desktop.
3. **Rogue host** — a fake "PC" could feed the tablet content.

Goals: (a) only a **paired** tablet can connect/control, (b) the streams are
**encrypted** so a sniffer sees nothing useful.

## Design

**Pairing (PIN):**
- On Start, the PC generates a fresh random **pairing code** (8 chars, A–Z2–9,
  ambiguous chars removed → ~40 bits) and shows it in the GUI.
- The tablet has a one-time **code entry** field. The user types the code.
- Both derive the same 256-bit key: `key = PBKDF2-HMAC-SHA256(code, salt, 200k)`
  with a fixed app salt (`"ExtDisplay/v1"`). No key material crosses the network.
- The GUI passes the code to the sender via an **environment variable**
  (`EXTDISPLAY_KEY`), not the command line, so it never shows in a process list.

**Encryption (per message, AES-256-GCM):**
- Every message is framed `[12B nonce][ciphertext][16B tag]`.
  - Nonce = 4-byte random prefix (per connection) + 8-byte counter (per message),
    never reused under a key.
  - GCM tag authenticates: a wrong key (wrong code) or tampered bytes → auth
    failure → the receiver **drops** the message. That is also the access-control
    check — an unpaired peer simply can't produce valid frames.
- **Touch (TCP 5001):** each 28-byte protocol-v2 packet is encrypted → 56 bytes on
  the wire. Sender decrypts; drops on auth failure (no injection from strangers).
- **Video (5000):** encrypt the H.264/HEVC NALs the sender emits.
  - UDP: encrypt each datagram payload (after the EXUD fragment header, or wrap it).
  - TCP: with encryption on, route ffmpeg → sender → encrypt → tablet (today ffmpeg
    connects to the tablet directly; encryption requires the sender to sit in the
    middle, like the UDP path already does).
- **Audio (TCP 5003):** encrypt each captured PCM packet. Nonce prefix `0x02`
  domain-separates audio from video (`0x01`) and touch (`0x00`). The 16-byte
  format header (sample rate / channels) stays plaintext — it carries no secret.
- Platform crypto only, no third-party deps: **Windows BCrypt** (PBKDF2 + AES-GCM)
  on the Windows sender; **CommonCrypto** (`CCKeyDerivationPBKDF`) + **CryptoKit**
  (`AES.GCM`) on the Mac sender; **javax.crypto** (`PBKDF2WithHmacSHA256`,
  `AES/GCM/NoPadding`) on the receiver. All three derive a byte-identical key
  (verified: `--derive-key TESTCODE` → `3961c9…c381` on Windows and Mac).

**Handshake:** first framed message is an encrypted known magic; if the receiver
can't authenticate it, it reports "wrong pairing code" and disconnects.

## Limitations (honest)

- An 8-char code is ~40 bits; with a slow KDF this resists casual offline cracking
  of captured ciphertext, but it is not a substitute for a full PAKE. Fine for
  home/office; regenerate the code per session. A future upgrade is SPAKE2/ECDH so
  a short PIN yields a strong key.
- No forward secrecy (static per-session key). Acceptable for this use.

## Staging (implement + verify each)

1. **Crypto foundation** — BCrypt (C++) + javax.crypto (Kotlin) PBKDF2/AES-GCM
   helpers with a round-trip self-test. ✅ **Done** — KDF verified byte-identical
   across both platforms (`--crypto-selftest` / `--derive-key`).
2. **Touch channel** — encrypt/authenticate port 5001 + code entry on the tablet +
   code display in the GUI. ✅ **Done + verified**: correct code → touch decrypts
   and injects; wrong code → auth fails → rejected (no injection). Replay guard via
   a monotonic nonce counter.
3. **Video channel** — ✅ **Done + verified on both transports.** The sender
   AES-256-GCM-encrypts each NAL; nonce prefix `0x01` domain-separates video from
   touch (`0x00`) under the shared key.
   - **UDP:** encrypt each NAL, then fragment (EXUD header stays plaintext for
     reassembly); the tablet reassembles then decrypts.
   - **TCP:** the sender proxies ffmpeg's output and sends each encrypted NAL
     length-prefixed (`[4B len][12B nonce][ct][16B tag]`); the tablet reads frames
     and decrypts. So encrypted Wi-Fi keeps TCP's no-dropped-frames smoothness (no
     longer forced onto UDP).
   Verified on-device: correct code → video decodes at 2960×1848 on both TCP and
   UDP; wrong code → no video. Over USB the same encrypted TCP framing rides the
   adb link.
   - **Audio channel** (v0.8.0) — the optional desktop-audio stream (TCP 5003) uses
     the same per-packet AES-GCM framing, nonce prefix `0x02`. Verified on-device:
     paired (correct code) → continuous decrypted playback with a stable connection
     (a wrong key fails `open()` on the first frame and drops the link, same as the
     other channels).
4. **Polish** — **remember pairing ✅ done** (v0.8.0): the tablet stores the
   *derived key* (app-private preferences) after a successful pair and re-applies
   it on launch; the PC GUI persists the pairing code per-user under
   `%LOCALAPPDATA%\ExtendedDisplay\pairing.code` and reuses it across launches. So
   the code is typed on the tablet **once, ever** — the GUI's "new code" link
   rotates it (re-enter on the tablet after rotating).
   - **Mismatch auto-detect:** if the PC later streams *unencrypted* while the
     tablet holds a saved key, the tablet detects it (TCP: no `EXVE` marker;
     UDP: first-packet latch) and disables its touch sealing for that session, so
     nothing silently breaks. Trade-off (deliberate): a paired tablet will still
     *display* a plaintext stream — display spoofing on the LAN remains possible
     when the sender isn't enforcing encryption. The **input** direction stays
     strict: a paired sender never accepts plaintext touch.
   - Storage caveat: the key sits in app-private storage (sandboxed, not
     hardware-backed). Fine for this threat model (LAN attacker, not a
     compromised device); Android Keystore wrapping would be the upgrade.
   Remaining polish (todo): richer "wrong code" UX in the GUI, optional
   open-LAN toggle.

Opt-in: streams stay open (today's behaviour) unless a pairing code is set, so a
trusted home LAN needn't change. Encryption engages automatically once paired.

**Mac host parity (v0.9.0):** the Mac sender implements the same pairing and
encryption for the channels it has — **video** (`EXVE` marker + length-prefixed
AES-GCM NALs, nonce prefix `0x01`) and **touch** (56-byte sealed v2 packets,
nonce prefix `0x00`, monotonic-counter replay guard that rebases on a new nonce
prefix so a tablet re-key doesn't stall). It has no desktop-audio channel yet,
so there's nothing on `0x02` to encrypt. Verified on-device: correct code →
video decodes and touch injects; wrong code → no video, touch auth-fails and is
dropped (no injection).
