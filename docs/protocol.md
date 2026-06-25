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
