# Stream Protocol

Phase 1 uses the simplest possible transport:

- TCP socket.
- Raw H.264 Annex-B byte stream.
- NAL units are separated by standard start codes: `00 00 01` or `00 00 00 01`.

This keeps Android decoding simple because `MediaCodec` can consume Annex-B NAL units directly when SPS/PPS arrive before the first IDR frame.

## Video

Windows sender:

```text
desktop capture -> H.264 low-latency encode -> TCP bytes
```

Android receiver:

```text
TCP bytes -> Annex-B NAL splitter -> MediaCodec input buffers -> SurfaceView
```

## Touch Uplink, Phase 3

Use a second TCP connection from Android to Windows:

```c
struct TouchPacket {
  uint32_t magic;      // 'HXTP'
  uint16_t version;    // 1
  uint16_t type;       // down/move/up/cancel
  float normalizedX;   // 0.0 - 1.0
  float normalizedY;   // 0.0 - 1.0
  uint64_t timestampUs;
};
```

Windows maps normalized coordinates to the virtual display rectangle, then injects via `SendInput`.
