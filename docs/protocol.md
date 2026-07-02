# Stream Protocol

Phase 1 uses the simplest possible transport:

- TCP socket.
- Raw H.264 Annex-B byte stream.
- NAL units are separated by standard start codes: `00 00 01` or `00 00 00 01`.

This keeps Android decoding simple because `MediaCodec` can consume Annex-B NAL units directly when SPS/PPS arrive before the first IDR frame.

## Video

Desktop sender:

```text
desktop capture -> H.264/HEVC low-latency encode -> TCP bytes  (default / USB)
                                                  -> UDP packets (--udp, Wi-Fi)
```

Android receiver:

```text
TCP bytes  -> Annex-B NAL splitter ─┐
UDP packets -> reassembler ─────────┴-> NAL queue -> MediaCodec -> SurfaceView
```

The app listens on both TCP and UDP port 5000 and decodes whichever arrives, so
the host picks the transport (USB/TCP for reliability, Wi-Fi/UDP for latency).

### Encrypted video (TCP)

When paired, the sender proxies ffmpeg and sends a 4-byte plaintext marker `EXVE`
(`0x45585645`) first, then length-prefixed AES-GCM frames `[4B BE len][12B nonce]
[ciphertext][16B tag]` (nonce prefix `0x01`). The tablet detects the marker and
reads the pairing key **per frame**: before the code is entered it drains frames
(no garbage decode), and once keyed the next frames decrypt on the same connection
(no reconnect). A plaintext stream instead begins with an Annex-B start code, which
the tablet feeds to the splitter.

### UDP video framing

Each NAL unit is split into datagrams with a 12-byte big-endian header:

```c
struct UdpNalHeader {
  uint32_t magic;     // 'EXUD' = 0x45585544
  uint32_t nalSeq;    // monotonic per NAL unit
  uint16_t fragIndex; // 0-based fragment number
  uint16_t fragCount; // total fragments for this NAL
};                    // followed by the fragment payload (<= 1400 bytes)
```

The receiver reassembles by `nalSeq`; a NAL with a missing fragment is dropped
(moving to a new `nalSeq` discards the incomplete one), so a lost packet causes a
brief glitch that clears on the next keyframe rather than corrupting the decoder.
Touch always stays on TCP (input must not drop) even when video is UDP.

## Discovery (Wi-Fi)

To avoid typing an IP, the host finds the tablet with a UDP broadcast:

- The Android app listens on UDP port `5002` and replies to a query datagram.
- Query payload (host → broadcast): `EXTDISP?v1`
- Reply payload (tablet → host): `EXTDISP!v1|<device name>|<video port>`

The host sends the query to each local interface's **subnet-directed** broadcast
address (e.g. `192.168.1.255`), not just `255.255.255.255` — limited broadcast can
exit the wrong adapter on multi-NIC hosts. It then connects to the responding
tablet's IP over TCP (video `5000`, touch `5001`), the same path as `--host`.

## Touch Uplink (implemented)

A second TCP channel carries touches back to the host. The Android app listens
on port `5001`; the host connects (over USB: `adb forward tcp:<local> tcp:5001`)
and reads fixed 24-byte packets. All fields are **big-endian**:

```c
struct TouchPacket {
  uint32_t magic;        // 'HXTP' = 0x48585450
  uint16_t version;      // 1
  uint16_t type;         // 0=down 1=move 2=up 3=cancel
  float    normalizedX;  // 0.0 - 1.0, relative to the letterboxed video area
  float    normalizedY;  // 0.0 - 1.0
  uint64_t timestampUs;  // sender event time
};
```

The Windows host maps normalized coordinates onto the captured display's
desktop rectangle and injects with `SendInput` (`MOUSEEVENTF_ABSOLUTE |
MOUSEEVENTF_VIRTUALDESK`); down/up become left-button presses, so taps click
and drags move windows. Single pointer in v1; disable with `--no-touch`.

## Desktop Audio (implemented, opt-in `--audio`)

A third channel carries PC playback to the tablet. The Android app listens on TCP
port `5003`; the host (WASAPI loopback of the default render endpoint) connects
(over USB: `adb forward tcp:<local> tcp:5003`) and sends a one-time **plaintext
format header**, then a stream of **length-prefixed packets**. All fields
**big-endian**:

```text
Header (12 bytes, once per connection):
  uint32  magic         // 'EXAU' = 0x45584155
  uint32  sampleRate    // e.g. 48000
  uint16  channels      // 2
  uint16  bitsPerSample // 16  (S16LE, interleaved)

Then, repeated:
  uint32  length        // bytes of payload that follow
  byte[length] payload  // raw S16LE PCM, or an AES-GCM blob when paired
```

When a pairing code is set the payload is `[12B nonce][ciphertext][16B tag]`
(nonce prefix `0x02`); otherwise it is the raw PCM. `flags` bit 0 marks the stream
encrypted, so the tablet stays silent until the code is entered (no noise). After
reading the header the tablet sends a **1-byte ACK** (`0xAC`); the sender waits for
it before streaming, so audio survives the app-launch race (adb-forward accepts the
local socket before the app binds its port). The tablet plays through an
`AudioTrack` (MODE_STREAM), newest-connection-wins. Audio and video are separate
streams with no shared clock, so lip-sync is approximate. `--mute-local` mutes the
PC's own endpoint while streaming (loopback still captures the mix).
