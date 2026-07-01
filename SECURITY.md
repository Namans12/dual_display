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
- Platform crypto only, no third-party deps: **Windows BCrypt** (PBKDF2 + AES-GCM)
  on the sender; **javax.crypto** (`PBKDF2WithHmacSHA256`, `AES/GCM/NoPadding`) on
  the receiver.

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
3. **Video channel** — encrypt 5000 (UDP datagrams; route TCP through the sender).
   Verify: paired tablet shows the stream; sniffer/unpaired sees nothing usable.
4. **Polish** — "wrong code" UX, remember pairing (store derived key on the tablet
   so the code is entered once), optional toggle to run open on a trusted LAN.

Opt-in: streams stay open (today's behaviour) unless a pairing code is set, so a
trusted home LAN needn't change. Encryption engages automatically once paired.
