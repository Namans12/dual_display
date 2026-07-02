# Mac Host Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (inline; this
> session runs autonomously with hardware in the loop, so subagent-per-task review gates are
> not applicable). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the Mac host from video-only phase 1 to near-parity with the Windows host:
verified build/stream/DMG, native CGVirtualDisplay extended display, touch-back injection,
then UDP discovery, AES-256-GCM pairing parity, and HEVC — each stage verified on the real
Galaxy Tab S9 Ultra before the next begins.

**Architecture:** One SPM executable (`MacHost`) plus a tiny ObjC shim target (`CVDShim`)
that confines all contact with the private `CGVirtualDisplay*` API. Video stays
ScreenCaptureKit → VideoToolbox → TCP Annex-B (with optional EXVE/AES-GCM framing and HEVC).
Touch is a TCP client to the tablet's :5001 that parses 28-byte protocol-v2 packets and
injects CGEvents. Crypto is CommonCrypto (PBKDF2) + CryptoKit (AES-GCM) — platform-only.

**Tech Stack:** Swift 6.3 (swift-tools 5.9, Swift-5 language mode), ScreenCaptureKit,
VideoToolbox, CoreGraphics (incl. private CGVirtualDisplay via shim), CryptoKit,
CommonCrypto, Darwin sockets. No third-party dependencies anywhere.

## Global Constraints

- **Android app is the compatibility contract** — `MainActivity.kt` (receiver versionCode 9)
  must not change; every wire byte must match what it already parses/emits.
- **No third-party dependencies** — platform frameworks only (matches project style).
- Package platform floor stays `.macOS(.v13)` unless an API forces higher; anything
  version-gated uses `if #available`.
- Touch protocol v2, 28-byte big-endian packets, magic `HXTP` 0x48585450, version 2
  (docs/protocol.md's 24-byte v1 section is stale; SECURITY.md + both reference
  implementations agree on v2 = 28B; fix protocol.md as part of Stage 3 docs).
- KDF: PBKDF2-HMAC-SHA256, salt `"ExtDisplay/v1"` (13 bytes, no NUL), 200 000 iterations,
  32-byte key. AES-256-GCM frame `[12B nonce][ct][16B tag]`, nonce = 1 domain byte +
  3 random bytes + 8-byte BE counter. Domains: touch (tablet→host) 0x00, video 0x01,
  audio 0x02.
- Virtual display: 2960x1848@60 (16:10), HiDPI, name "Extended Display".
- Update `docs/mac.md` + `CHANGELOG.md` (new v0.9.0 section) as each stage lands; commit
  per stage on the current branch (`Updated`).
- **Testing style:** no XCTest/Swift Testing (CLT-only Mac — verified `swift test` fails:
  "no such module 'Testing'"). Pure logic is verified via a built-in `--selftest`
  (mirrors the Windows `--crypto-selftest` pattern); everything else is verified live on
  the tablet (serial R52W80ET3WM, Wi-Fi 192.168.1.19, receiver v9 installed, Android 16).

## Machine ground truth (2026-07-03)

- macOS 26.5.1 (M4), Swift 6.3.3, **CommandLineTools only** (no Xcode, no XCTest/Testing).
- `swift build -c release` of the current code **succeeds** (warnings only: `RunLoop.run()`
  unavailable-in-async — fix in Stage 1).
- adb at `installers/mac/.cache/platform-tools/adb` (pre-downloaded; build-dmg.sh reuses
  this exact cache path). Tablet SM-X910 attached over USB; receiver v9 installed
  (`adb shell pm path com.heysnap.extdisplay` → base.apk pullable for the DMG).
- No APK in the repo and no Android SDK on this Mac → **pull the installed APK from the
  tablet** for build-dmg.sh.
- **Control Center (AirPlay Receiver) listens on \*:5000.** `adb forward tcp:5000` still
  binds (127.0.0.1 specific bind beats the wildcard) so the USB flow works, BUT with no
  forward in place a connect to 127.0.0.1:5000 "succeeds" against AirPlay and streams into
  a black hole. Worth a troubleshooting note in docs/mac.md.
- **TCC:** Screen Recording + Accessibility attribute to the responsible app (Claude.app,
  `com.anthropic.claudefordesktop` in this session; ExtendedDisplay.app when Finder-launched).
  Both prompts have been triggered; on-device verification steps below block until the user
  grants them. Non-capture work proceeds meanwhile.
- Tablet holds a **saved pairing key** from the Windows host. Plaintext Mac streams are safe
  (the app's mismatch auto-detect unseals touch for plaintext sessions). Stage 4b's
  encrypted verify re-pairs the tablet to a known test code (`MACPAIR7`) via adb UI input —
  this **invalidates the Windows PC's stored pairing**; the final report must tell the user
  to rotate/re-enter the code on the Windows side (documented recovery, GUI "new code").

## File Structure

```
mac-host/Package.swift                        modify: add CVDShim target, CoreGraphics link
mac-host/Sources/CVDShim/include/CVDShim.h    create: private CGVirtualDisplay* interfaces + factory decl
mac-host/Sources/CVDShim/CVDShim.m            create: NSClassFromString-based factory (all private-API contact)
mac-host/Sources/MacHost/main.swift           modify: options, signal-based lifetime, flow orchestration
mac-host/Sources/MacHost/Net.swift            create: TcpWriter (moved), recvFull/sendAll helpers
mac-host/Sources/MacHost/Encoder.swift        create: AnnexBEncoder (H.264 moved + HEVC), VideoSender (plain/EXVE framing)
mac-host/Sources/MacHost/Capture.swift        create: ScreenCaptureHost (moved; captures by CGDirectDisplayID)
mac-host/Sources/MacHost/VirtualDisplay.swift create: VirtualDisplay wrapper (create/wait/teardown)
mac-host/Sources/MacHost/Touch.swift          create: TouchPacket parse, MouseInjector (CGEvent), bridge loop
mac-host/Sources/MacHost/Discovery.swift      create: UDP broadcast discovery client
mac-host/Sources/MacHost/Crypto.swift         create: deriveKey (PBKDF2), Sealer/opener (AES-GCM)
mac-host/Sources/MacHost/SelfTest.swift       create: --selftest / --crypto-selftest bodies
installers/mac/build-dmg.sh                   modify: whatever the real run breaks + forward :5001 + version
docs/mac.md                                   modify per stage (feature matrix, flags, troubleshooting)
docs/protocol.md                              modify in Stage 3 (touch v2 packet layout)
CHANGELOG.md                                  modify per stage (one growing v0.9.0 section)
README.md                                     modify at the end (Mac paragraph + roadmap line)
```

CLI surface when done (Windows-parity naming):

```
--host <ip>        tablet IP; 127.0.0.1 with adb forward          [127.0.0.1]
--port N           video port                                     [5000]
--fps N            capture/encode rate                            [60]
--width/--height N encode size; 0 = captured display native px    [0]
--bitrate N        bits/sec                                       [25000000]
--display N        capture existing SCK display N (skip virtual)  [off → virtual display]
--wifi             discover the tablet via UDP :5002, then TCP
--hevc             HEVC instead of H.264
--no-touch         disable touch bridge
--selftest         run all pure-logic self-tests, exit
--crypto-selftest  Windows-parity crypto self-test, exit
--derive-key CODE  print PBKDF2 key hex (parity with Windows), exit
EXTDISPLAY_KEY     env var: pairing code → AES-256-GCM video + touch
```

Touch port rule: connect to `host:5001`, except when host is loopback the local forward is
`--port + 1` (USB flow forwards `tcp:5001 tcp:5001`, which with the default port is the
same number — matches the Windows `options.port + 1` local-forward convention).

---

## Stage 1 — Verify the existing host + DMG on a real Mac

### Task 1.1: Replace `RunLoop.current.run()` with signal-driven lifetime

**Files:** Modify `mac-host/Sources/MacHost/main.swift:413-435`

**Why:** `RunLoop.run()` is unavailable-from-async (warning today, error in Swift 6 mode),
and Stages 2/3 need orderly teardown (virtual display + mouse-up) on Ctrl+C/TERM anyway.

**Interfaces produced:** `func parkUntilSignal() async` — returns when SIGINT/SIGTERM
arrives; callers run cleanup after it returns, then `exit(0)`.

- [ ] **Step 1:** In main.swift, add above `MacHostMain`:

```swift
// Blocks (asynchronously) until SIGINT/SIGTERM so `defer`/post-await teardown runs.
func parkUntilSignal() async {
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        let handle = { (sig: Int32) -> DispatchSourceSignal in
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { cont.resume() }
            src.activate()
            return src
        }
        _ = (handle(SIGINT), handle(SIGTERM))  // kept alive by the closure capture below
    }
}
```

(Note: resuming a continuation twice traps — guard with a flag if both signals can fire;
use an atomic Bool.)

- [ ] **Step 2:** Replace `RunLoop.current.run()` with `await parkUntilSignal()` followed by
`print("Stopping.")` and `exit(0)`.
- [ ] **Step 3:** `swift build -c release 2>&1 | grep -c warning` → expect 0.
Run `.build/release/MacHost --host 127.0.0.1 --port 9`, expect immediate connect error
(unchanged behavior). Commit: `Mac: signal-driven lifetime replaces RunLoop.run()`.

### Task 1.2: Verify USB streaming end-to-end (needs Screen Recording grant)

- [ ] `adb forward tcp:5000 tcp:5000 && adb shell am start -n com.heysnap.extdisplay/.MainActivity`
- [ ] Run `MacHost --host 127.0.0.1 --port 5000` in background; evidence of success:
  - MacHost stdout reaches "Streaming."
  - `adb logcat -d | grep -E "ExtDisplay|MediaCodec"` shows a video decoder created.
  - `adb exec-out screencap -p > tablet.png` twice, 3s apart → images differ from the
    receiver's idle screen (decoded frames present) — spot-check pixels/size.
- [ ] Fix anything macOS-26-related that surfaces. Expected risk points: TCC (block until
  granted), SCStreamConfiguration defaults, VT session params.

### Task 1.3: Verify Wi-Fi streaming

- [ ] Remove the adb video forward (`adb forward --remove tcp:5000`), keep the app open,
  run `MacHost --host 192.168.1.19 --port 5000` (Mac is 192.168.1.24 — same /24).
- [ ] Same logcat/screencap evidence; note backpressure behavior in docs if it stutters.

### Task 1.4: Run installers/mac/build-dmg.sh and fix what breaks

- [ ] Pull the receiver APK from the tablet:
  `adb pull "$(adb shell pm path com.heysnap.extdisplay | sed 's/^package://;s/\r$//')" installers/mac/.cache/receiver-v9.apk`
- [ ] Run `./installers/mac/build-dmg.sh installers/mac/.cache/receiver-v9.apk`; fix
  failures in-place (candidates: `codesign --deep` behavior on macOS 26, hdiutil,
  `swift build --show-bin-path` quoting). Re-run until DMG is emitted.
- [ ] Verify: `hdiutil attach dist/ExtendedDisplay.dmg`, `codesign -v` the app, run the
  bundled launcher binary directly with the tablet attached → it must forward, launch the
  app, and stream (same logcat evidence); then `hdiutil detach`.
- [ ] Fold in launcher fixes discovered here; keep `.cache` reuse (already primed).
- [ ] Docs: mac.md quick-start corrections + AirPlay-on-:5000 troubleshooting bullet;
  CHANGELOG v0.9.0 section started ("Mac host verified on macOS 26 (M4); DMG pipeline
  fixed: <list>"). Commit: `Mac: stage 1 — verified USB/Wi-Fi streaming + working DMG`.

---

## Stage 2 — Native virtual display (CGVirtualDisplay)

### Task 2.1: CVDShim target (all private-API contact in one file)

**Files:** Create `mac-host/Sources/CVDShim/include/CVDShim.h`, `mac-host/Sources/CVDShim/CVDShim.m`;
modify `mac-host/Package.swift`.

**Interfaces produced (consumed by Task 2.2):**
`CVDCreate(name, widthPx, heightPx, hz, mmSize, hiDPI) -> NSObject*` (retained opaque
display object, nil on failure), `CVDDisplayID(display) -> uint32_t`.

- [ ] **Step 1:** `CVDShim.h`:

```objc
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
// Creates a CGVirtualDisplay (private CoreGraphics API) with one pixel mode.
// Returns the retained display object (keep it alive; releasing it — or process
// exit — removes the display), or nil if the API is unavailable/refused.
NSObject * _Nullable CVDCreate(NSString * _Nonnull name,
                               uint32_t widthPx, uint32_t heightPx, double hz,
                               CGSize sizeMm, BOOL hiDPI);
uint32_t CVDDisplayID(NSObject * _Nonnull display);
```

- [ ] **Step 2:** `CVDShim.m` — declare the private interfaces *locally*, instantiate via
`NSClassFromString` (no link-time symbols):

```objc
#import "CVDShim.h"

@interface CGVirtualDisplayDescriptor : NSObject
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, copy) NSString *name;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) CGPoint redPrimary;
@property(nonatomic) CGPoint greenPrimary;
@property(nonatomic) CGPoint bluePrimary;
@property(nonatomic) CGPoint whitePoint;
@property(nonatomic, copy) id terminationHandler;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int vendorID;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)w height:(unsigned int)h refreshRate:(double)hz;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic, strong) NSArray *modes;
@property(nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
@property(nonatomic, readonly) uint32_t displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

NSObject *CVDCreate(NSString *name, uint32_t w, uint32_t h, double hz,
                    CGSize sizeMm, BOOL hiDPI) {
    Class descC = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class modeC = NSClassFromString(@"CGVirtualDisplayMode");
    Class settC = NSClassFromString(@"CGVirtualDisplaySettings");
    Class dispC = NSClassFromString(@"CGVirtualDisplay");
    if (!descC || !modeC || !settC || !dispC) return nil;

    CGVirtualDisplayDescriptor *desc = [[descC alloc] init];
    desc.name = name;
    desc.maxPixelsWide = w;
    desc.maxPixelsHigh = h;
    desc.sizeInMillimeters = sizeMm;
    desc.productID = 0x4544;   // 'ED'
    desc.vendorID = 0x3456;
    desc.serialNum = 0x0001;
    desc.queue = dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);
    // sRGB-ish primaries; without them some builds reject the descriptor.
    desc.redPrimary = CGPointMake(0.64, 0.33);
    desc.greenPrimary = CGPointMake(0.30, 0.60);
    desc.bluePrimary = CGPointMake(0.15, 0.06);
    desc.whitePoint = CGPointMake(0.3127, 0.3290);

    CGVirtualDisplay *display = [[dispC alloc] initWithDescriptor:desc];
    if (!display) return nil;

    CGVirtualDisplaySettings *settings = [[settC alloc] init];
    settings.hiDPI = hiDPI ? 1 : 0;
    settings.modes = @[ [[modeC alloc] initWithWidth:w height:h refreshRate:hz] ];
    if (![display applySettings:settings]) return nil;
    return (NSObject *)display;
}

uint32_t CVDDisplayID(NSObject *display) {
    return ((CGVirtualDisplay *)display).displayID;
}
```

(If macOS 26 renamed properties/selectors, the probe in Step 4 fails → adapt using
`class_copyPropertyList` dump of the real classes, still confined to this file.)

- [ ] **Step 3:** Package.swift: add `.target(name: "CVDShim")` and make MacHost depend on
it; add `.linkedFramework("CoreGraphics")`.
- [ ] **Step 4 (probe):** temporary `--probe-virtual` flag: create 2960x1848@60, print
displayID, poll `CGGetOnlineDisplayList` until it appears (≤5 s), print SCK display list,
sleep on signal. Expect the new display in both lists. This is the macOS-26 go/no-go for
the private API. Remove the flag once integrated.

### Task 2.2: Integrate: create → wait → capture → teardown

**Files:** Create `VirtualDisplay.swift`; modify `main.swift`, `Capture.swift`.

**Interfaces:** `final class VirtualDisplay { init?(name:String, width:Int, height:Int,
hz:Double); var displayID: CGDirectDisplayID; func awaitOnline(timeout:TimeInterval) async -> Bool }`
— holds the shim object; deinit/process-exit removes the display (WindowServer reclaims
virtual displays of dead processes — that's the session scoping; Windows needed explicit
`collapseToInternal()`, the Mac gets it structurally).

- [ ] Default flow (no `--display`): create VirtualDisplay 2960x1848@60 HiDPI ("Extended
Display"), await online, capture *that* CGDirectDisplayID via
`SCShareableContent.displays.first { $0.displayID == id }`; encode default = mode pixels.
`--display N` keeps today's index behavior (mirror path), encode default = that display's
pixel size via `CGDisplayCopyDisplayMode().pixelWidth/Height`.
- [ ] Teardown on `parkUntilSignal()` return; also on stream-start failure.
- [ ] On-tablet verify (USB): stream shows the *virtual* desktop (wallpaper, no windows) —
screencap the tablet, confirm it differs from the Mac's main display capture; System
Settings > Displays lists "Extended Display"; `CGDisplayBounds` of the ID is non-zero.
Cursor moved onto the extended space (`CGWarpMouseCursorPosition` into its bounds) shows up
in the tablet screencap.
- [ ] Docs (mac.md: matrix ✅ auto virtual display, flags, BetterDisplay note removed /
"no longer needed"), CHANGELOG bullet. Commit: `Mac: native CGVirtualDisplay extended display`.

---

## Stage 3 — Touch-back (tablet → Mac injection)

### Task 3.1: TouchPacket parse + selftest

**Files:** Create `Touch.swift`, `SelfTest.swift`; modify `main.swift` (flag).

**Interfaces:** `struct TouchPacket { type,tool,pointerId,pointerCount: UInt8; pressure: UInt16;
nx,ny: Float; timestampUs: UInt64 }`, `parseTouchPacket(_ b: [UInt8]) -> TouchPacket?`
(validates magic+version+length=28), `runSelfTests() -> Int32`.

- [ ] Golden vector self-test: bytes built per MainActivity's `TouchUplink.send` layout
(`48 58 54 50 | 00 02 | 00 | 01 | 00 | 01 | 02 00 | 3F 00 00 00 | 3E 80 00 00 | …u64…`)
must parse to (type 0, tool 1=stylus, pressure 512, nx 0.5, ny 0.25). Wrong magic/version
→ nil. Wire `--selftest` to run and exit; run: expect `selftest: OK`.

### Task 3.2: MouseInjector (CGEvent) + bridge loop

**Files:** Modify `Touch.swift`, `main.swift`, `Net.swift` (recvFull).

- [ ] MouseInjector: maps (nx,ny) into `CGDisplayBounds(capturedDisplayID)` (points, global
space): `x = bounds.minX + nx * (bounds.width - 1)`. Single-pointer state machine
(mouse-first per plan): down → `leftMouseDown` (owner = pointerId; ignore other pointers
while owned), move(owner) → `leftMouseDragged`, move(unowned)/hover-move → `mouseMoved`,
up/cancel(owner) → `leftMouseUp` + release; hover-exit → no-op. Manual click counting for
double-click: reuse clickState 2/3 when a down lands <0.4 s and <8 px from the previous up
(`CGEventSetIntegerValueField(.mouseEventClickState)` on down AND up). Post to
`CGEventTapLocation.cgSessionEventTap`... **decision: `.cghidEventTap`** (SendInput
equivalent). Stylus/eraser tools ride the same mouse path for now (pen/pressure later,
matching the task brief).
- [ ] Bridge loop (Thread/DispatchQueue): resolve touch host/port (rule above), connect,
`recvFull` 28B, slide-by-one resync on magic mismatch (Windows-style), skip version ≠ 2,
inject; on EOF/error → release stuck button, reconnect after 2 s (loop until stop).
`AXIsProcessTrustedWithOptions(prompt)` once at bridge start; warn if untrusted (events
would silently no-op). `--no-touch` skips the bridge.
- [ ] On-tablet verify (USB, stream running): baseline cursor pos via
`CGEventCreate(nil).location`; `adb shell input tap 800 600` on the tablet; assert the Mac
cursor jumped to the *computed* expected global point (tap → normalized against the
letterboxed SurfaceView → display bounds mapping; tolerance ±2 px). Drag check:
`adb shell input swipe`. Evidence printed, not eyeballed.
- [ ] Docs: mac.md (matrix ✅ touch/S Pen → mouse; Accessibility permission bullet),
protocol.md touch section rewritten to v2 (28B layout incl. hover/tool/pressure),
CHANGELOG. Commit: `Mac: touch-back — protocol v2 → CGEvent mouse injection`.

---

## Stage 4 — Stretch: discovery, pairing parity, HEVC (in this order)

### Task 4a: UDP discovery client (`--wifi`)

**Files:** Create `Discovery.swift`; modify `main.swift`.

- [ ] `discoverTablet(timeout:) -> String?`: getifaddrs → per up/non-loopback AF_INET
iface add subnet-directed broadcast (`addr | ~mask`), plus 255.255.255.255; SO_BROADCAST
socket; send `"EXTDISP?v1"` to each `:5002`; recv 800 ms; accept reply prefixed
`"EXTDISP!v1|"`, log `name`, return sender IP. Loop like Windows (15 s rounds with
"No tablet found yet; retrying…"). `--wifi` fills `options.host` before connect.
- [ ] Verify on LAN: app foregrounded via adb, Wi-Fi forward removed → `MacHost --wifi`
finds 192.168.1.19 and streams (logcat evidence). Self-test: reply-string parser vector.
- [ ] Docs + CHANGELOG. Commit: `Mac: --wifi UDP discovery (EXTDISP?v1 parity)`.

### Task 4b: Pairing + AES-256-GCM parity

**Files:** Create `Crypto.swift`; modify `Encoder.swift` (VideoSender framing),
`Touch.swift` (encrypted read path), `main.swift` (env + flags), `SelfTest.swift`.

- [ ] `Crypto.swift`:

```swift
import CommonCrypto  // PBKDF2 (CryptoKit has none)
import CryptoKit

enum PairingCrypto {
    static let salt = Array("ExtDisplay/v1".utf8)  // 13 bytes, no NUL — matches BCrypt/javax
    static func deriveKey(code: String) -> SymmetricKey? {
        var out = [UInt8](repeating: 0, count: 32)
        let pw = Array(code.utf8)
        let rc = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
            code, pw.count, salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 200_000, &out, out.count)
        return rc == kCCSuccess ? SymmetricKey(data: Data(out)) : nil
    }
}

// One per channel/direction. Frame = [12B nonce][ct][16B tag]; nonce = domain byte +
// 3 random + 8B BE counter (never reused under a key).
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
    func seal(_ plain: Data) -> Data? {
        counter += 1
        var nonce = Data(prefix)
        withUnsafeBytes(of: counter.bigEndian) { nonce.append(contentsOf: $0) }
        guard let n = try? AES.GCM.Nonce(data: nonce),
              let box = try? AES.GCM.seal(plain, using: key, nonce: n) else { return nil }
        return box.combined  // nonce || ct || tag — exactly the wire format
    }
    static func open(_ frame: Data, key: SymmetricKey) -> Data? {
        guard frame.count >= 28, let box = try? AES.GCM.SealedBox(combined: frame) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }
}
```

(`CCKeyDerivationPBKDF` takes the password as `String` directly (`code`) — it reads
`strlen`-independent length `pw.count`; pass `pw` via `code` pointer carefully: use the
byte-array form `pw.withUnsafeBufferPointer` if the String overload misbehaves.)

- [ ] Flags: `--derive-key CODE` (print 64-hex, exit 0), `--crypto-selftest` mirroring
Windows checks (deterministic, round-trip, wrong-key rejected) **plus a golden KDF vector**
computed independently: `python3 -c "import hashlib;print(hashlib.pbkdf2_hmac('sha256',b'TESTCODE',b'ExtDisplay/v1',200000,32).hex())"`
hard-coded so parity is byte-checked without Windows present.
- [ ] `EXTDISPLAY_KEY` env (same name as Windows): derive key at startup, print
"Pairing enabled — encrypting the link…".
- [ ] Video: when paired, `VideoSender` sends 4B `EXVE` after connect, then per Annex-B NAL
(start code included, exactly the unit the plaintext path writes):
`[4B BE len][seal(nal, domain 0x01)]`.
- [ ] Touch: when paired, read fixed 56-byte frames (12+28+16), `Sealer.open`; on auth
failure print `Touch pairing/auth failed - check the code on the tablet.` and drop the
connection; replay guard: 8-byte BE counter from nonce must be monotonic (drop stale).
- [ ] Self-test additions: seal→open round trip, wrong-key nil, touch frame = 56 B.
- [ ] On-tablet verify (USB): `EXTDISPLAY_KEY=MACPAIR7 MacHost …` → tablet drains (no video)
until the code is typed; type it via adb (`uiautomator dump` to find the EditText bounds →
`input tap` → `input text MACPAIR7`) → video decodes (logcat) **and** touch still injects
(cursor assertion again, now through the encrypted path). Negative test: restart MacHost
with `EXTDISPLAY_KEY=WRONGXX2` → no video (auth-drop loop), no touch injection.
- [ ] ⚠ Record loudly in the final report: tablet is now paired to `MACPAIR7`; Windows PC
must rotate/re-enter its code.
- [ ] Docs (matrix ✅ pairing/encryption; SECURITY.md gains a "Mac host" line in the
platform-crypto bullet: CommonCrypto/CryptoKit), CHANGELOG. Commit:
`Mac: PIN pairing + AES-256-GCM (KDF byte-parity, EXVE video, sealed touch)`.

### Task 4c: HEVC (`--hevc`)

**Files:** Modify `Encoder.swift`, `main.swift`.

- [ ] Encoder: `codecType: kCMVideoCodecType_HEVC`, profile
`kVTProfileLevel_HEVC_Main_AutoLevel`, parameter sets via
`CMVideoFormatDescriptionGetHEVCParameterSetAtIndex` (count first, then 0..n → VPS/SPS/PPS,
each `[00 00 00 01] + set`); rest of the pipeline unchanged (receiver auto-detects HEVC
from the first NAL header).
- [ ] Verify (USB): `--hevc` → logcat shows an HEVC decoder (`video/hevc` / `c2.*hevc*`);
combined run `--hevc` + `EXTDISPLAY_KEY` (encrypted HEVC) decodes too.
- [ ] Docs (matrix: H.264+HEVC ✅ TCP; flags), CHANGELOG; README Mac paragraph + roadmap
line refreshed; bundle CFBundleShortVersionString → 0.9.0. Commit:
`Mac: HEVC encode option + docs/version alignment`.

---

## Self-Review (done at write time)

- Spec coverage: 1→build/USB/WiFi/DMG ✓, 2→CGVirtualDisplay 2960x1848@60 + capture-that ✓,
  3→:5001 v2 28B parse + CGEvent mouse ✓, 4→discovery/pairing-KDF-parity/HEVC in order ✓,
  constraints (no 3rd-party, Android untouched, docs+changelog per stage, on-device verify
  per stage) ✓.
- Placeholders: none — every code step has real code; runtime-gated steps carry exact
  commands + expected evidence instead.
- Type consistency: `parkUntilSignal`, `VirtualDisplay.displayID`, `TouchPacket`,
  `Sealer.seal/open`, `CVDCreate/CVDDisplayID` used consistently across tasks.
- Known risks called out: TCC gating (both permissions), CGVirtualDisplay availability on
  macOS 26 (probe step 2.1.4 is the go/no-go), tablet re-pair side effect (documented),
  AirPlay :5000 (doc note).
