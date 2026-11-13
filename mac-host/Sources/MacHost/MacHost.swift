import AVFoundation
import CoreMedia
import CoreVideo
import CryptoKit
import Darwin
import Foundation
import ScreenCaptureKit
import VideoToolbox

struct Options {
    var host = "127.0.0.1"
    var port = 5000
    var fps = 60
    var width = 0    // 0 = native pixel size of the captured display
    var height = 0
    var bitrate = 25_000_000
    var displayIndex: Int?  // nil = create the native virtual display
    var removeDisplay = false
    var noTouch = false
    var selfTest = false
    var wifi = false
    var hostExplicit = false  // --host given → skip discovery
    var cryptoSelfTest = false
    var deriveKeyCode: String?
    var hevc = false
    var audio = false
    var muteLocal = false
    var audioDelayMs = 40
    var udp = false
    var eraserKey: CGKeyCode?  // nil = eraser acts like stylus
}

enum MacHostError: Error, CustomStringConvertible {
    case invalidArgument(String)
    case noDisplays
    case displayIndexOutOfRange(Int)
    case virtualDisplay(String)
    case socket(String)
    case encoder(OSStatus)
    case sampleBufferMissingImage

    var description: String {
        switch self {
        case .invalidArgument(let message):
            return message
        case .noDisplays:
            return "No capturable displays were found."
        case .displayIndexOutOfRange(let index):
            return "Display index \(index) is out of range."
        case .virtualDisplay(let message):
            return message
        case .socket(let message):
            return message
        case .encoder(let status):
            return "VideoToolbox error: \(status)"
        case .sampleBufferMissingImage:
            return "ScreenCaptureKit delivered a frame without a pixel buffer."
        }
    }
}

func printUsage() {
    print("""
    MacHost — extended display for an Android tablet

    Usage:
      MacHost [--wifi | --host <ip>] [--port 5000] [--fps 60]
              [--width N --height N] [--bitrate 25000000]
              [--display N] [--hevc] [--udp] [--no-touch]
              [--eraser-key <name>]
              [--audio [--mute-local] [--audio-delay-ms 40]]

    --wifi discovers the tablet on the LAN (UDP broadcast) so no IP is needed;
    --host <ip> connects to a specific address (or 127.0.0.1 with adb forward).

    By default MacHost creates a native virtual display (2960x1848, the
    tablet's panel, streamed at 60 fps) and streams THAT — a true extended display. Pass
    --display N to capture an existing display instead (0 = built-in panel,
    i.e. a mirror). --width/--height default to the captured display's native
    pixel size.

    Examples:
      MacHost --host 192.168.1.50 --port 5000
      MacHost --host 127.0.0.1 --display 0        # mirror the built-in panel
      MacHost --remove-display                    # clear session virtual displays
      MacHost --selftest                          # protocol self-tests, then exit

    Touch: tablet touches and S Pen drive the Mac cursor (down/drag/up, taps
    click, double taps double-click; hover moves the pointer). Needs the
    Accessibility permission. Disable with --no-touch.
    --eraser-key <name> holds that key while the S Pen eraser end touches
    (macOS can't inject a real eraser; many drawing apps bind a key to it).
    Names: \(EraserKey.acceptedDescription) (US-layout positions).

    USB-C with ADB:
      adb forward tcp:5000 tcp:5000
      adb forward tcp:5001 tcp:5001
      MacHost --host 127.0.0.1 --port 5000

    The virtual display exists while MacHost runs and is removed when it exits
    (WindowServer reclaims it). --remove-display is a rarely-needed safety valve.
    """)
}

func parseOptions(_ args: [String]) throws -> Options {
    var options = Options()
    var index = 1

    func requireValue(_ name: String) throws -> String {
        guard index + 1 < args.count else {
            throw MacHostError.invalidArgument("Missing value for \(name)")
        }
        index += 1
        return args[index]
    }

    func readInt(_ name: String) throws -> Int {
        guard let value = Int(try requireValue(name)) else {
            throw MacHostError.invalidArgument("Invalid \(name)")
        }
        return value
    }

    while index < args.count {
        let arg = args[index]
        switch arg {
        case "--help", "-h":
            printUsage()
            exit(0)
        case "--host":
            options.host = try requireValue(arg)
            options.hostExplicit = true
        case "--wifi":
            options.wifi = true
        case "--udp":
            options.udp = true
        case "--port":
            options.port = try readInt(arg)
        case "--fps":
            options.fps = try readInt(arg)
        case "--width":
            options.width = try readInt(arg)
        case "--height":
            options.height = try readInt(arg)
        case "--bitrate":
            options.bitrate = try readInt(arg)
        case "--display":
            options.displayIndex = try readInt(arg)
        case "--hevc":
            options.hevc = true
        case "--audio":
            options.audio = true
        case "--mute-local":
            options.muteLocal = true
        case "--audio-delay-ms":
            options.audioDelayMs = try readInt(arg)
        case "--remove-display":
            options.removeDisplay = true
        case "--no-touch":
            options.noTouch = true
        case "--eraser-key":
            let name = try requireValue(arg)
            guard let code = EraserKey.keyCode(forName: name) else {
                throw MacHostError.invalidArgument(
                    "Unknown --eraser-key '\(name)'. Accepted: \(EraserKey.acceptedDescription)")
            }
            options.eraserKey = code
        case "--selftest":
            options.selfTest = true
        case "--crypto-selftest":
            options.cryptoSelfTest = true
        case "--derive-key":
            options.deriveKeyCode = try requireValue(arg)
        default:
            throw MacHostError.invalidArgument("Unknown argument: \(arg)")
        }
        index += 1
    }

    guard !options.host.isEmpty else {
        throw MacHostError.invalidArgument("--host must not be empty")
    }
    guard (1...65535).contains(options.port) else {
        throw MacHostError.invalidArgument("--port must be between 1 and 65535")
    }
    guard (1...240).contains(options.fps) else {
        throw MacHostError.invalidArgument("--fps must be between 1 and 240")
    }
    guard options.width >= 0, options.height >= 0,
          (options.width > 0) == (options.height > 0) else {
        throw MacHostError.invalidArgument("--width and --height must be positive and given together")
    }
    guard options.bitrate > 0 else {
        throw MacHostError.invalidArgument("--bitrate must be positive")
    }
    if options.udp {
        // adb can't forward UDP, so loopback is never a valid UDP target.
        let loopback = options.host == "127.0.0.1" || options.host == "localhost" || options.host == "::1"
        guard options.wifi || (options.hostExplicit && !loopback) else {
            throw MacHostError.invalidArgument(
                "--udp needs a network target: add --wifi or --host <tablet-ip> " +
                "(UDP can't ride an adb forward)")
        }
    }

    return options
}

final class TcpWriter {
    private let fd: Int32

    init(host: String, port: Int) throws {
        fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else {
            throw MacHostError.socket("socket() failed")
        }

        var noDelay: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))

        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var results: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &results)
        guard status == 0, let first = results else {
            close(fd)
            throw MacHostError.socket("getaddrinfo() failed for \(host):\(port)")
        }
        defer { freeaddrinfo(first) }

        var connected = false
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let candidate = cursor {
            if connect(fd, candidate.pointee.ai_addr, candidate.pointee.ai_addrlen) == 0 {
                connected = true
                break
            }
            cursor = candidate.pointee.ai_next
        }

        guard connected else {
            let reason = String(cString: strerror(errno))
            close(fd)
            // "No route to host" on a LAN peer usually means macOS Local Network
            // privacy (System Settings > Privacy & Security > Local Network).
            throw MacHostError.socket("Could not connect to \(host):\(port) — \(reason)")
        }
    }

    deinit {
        close(fd)
    }

    // Smoothed round-trip time and bytes still queued in the kernel send buffer
    // (a growing backlog is latency the tablet has not seen yet). For the trace.
    func linkStats() -> (rttMs: Int, queuedBytes: Int)? {
        var info = tcp_connection_info()
        var length = socklen_t(MemoryLayout<tcp_connection_info>.size)
        guard getsockopt(fd, IPPROTO_TCP, TCP_CONNECTION_INFO, &info, &length) == 0 else { return nil }
        return (Int(info.tcpi_srtt), Int(info.tcpi_snd_sbbytes))
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var sent = 0
            while sent < rawBuffer.count {
                let written = Darwin.write(fd, base.advanced(by: sent), rawBuffer.count - sent)
                if written <= 0 {
                    throw MacHostError.socket("Socket write failed")
                }
                sent += written
            }
        }
    }
}

// Sends encoded NAL units to the tablet over the chosen transport.
//
// TCP plaintext: each Annex-B NAL (start code included) goes straight to the
// socket — an Annex-B byte stream the receiver's splitter consumes.
// TCP encrypted (paired): the 4-byte 'EXVE' marker once, then each NAL as
// [4B BE length][12B nonce][ct][16B tag] (nonce domain 0x01) — the Windows
// encrypted-TCP wire format.
// UDP (--udp): each NAL (sealed first when paired) fragmented behind the
// plaintext EXUD header — see Udp.swift. UDP has no connection to lose, so
// `alive` never clears in that mode.
//
// A TCP write failure (the tablet closed the connection) sets `alive` false so
// the supervisor loop can reconnect. SIGPIPE is ignored process-wide, so the
// failing write returns an error here instead of killing the process.
final class VideoSender {
    private enum Transport {
        case tcp(TcpWriter, Sealer?)
        case udp(UdpVideoSender)
    }

    private let transport: Transport
    let alive = AtomicFlag()

    init(writer: TcpWriter, key: SymmetricKey?) throws {
        let sealer = key.map { Sealer(key: $0, domain: 0x01) }
        transport = .tcp(writer, sealer)
        alive.set()
        if sealer != nil {
            try writer.write(Data([0x45, 0x58, 0x56, 0x45]))  // 'EXVE'
        }
    }

    init(udp: UdpVideoSender) {
        transport = .udp(udp)
        alive.set()
    }

    func linkStats() -> (rttMs: Int, queuedBytes: Int)? {
        if case .tcp(let writer, _) = transport { return writer.linkStats() }
        return nil
    }

    // Called serially from the VideoToolbox output callback.
    func send(nal: Data) throws {
        switch transport {
        case .udp(let sender):
            sender.send(nal: nal)
        case .tcp(let writer, let sealer):
            do {
                guard let sealer else {
                    try writer.write(nal)
                    return
                }
                guard let frame = sealer.seal(nal) else {
                    throw MacHostError.socket("Failed to encrypt a video frame")
                }
                let n = UInt32(frame.count)
                var out = Data([UInt8(n >> 24), UInt8((n >> 16) & 0xff),
                                UInt8((n >> 8) & 0xff), UInt8(n & 0xff)])
                out.append(frame)
                try writer.write(out)
            } catch {
                alive.clear()  // tablet dropped — supervisor reconnects
                throw error
            }
        }
    }
}

// The video codec MacHost encodes. The receiver auto-detects H.264 vs HEVC from
// the first NAL header, so no negotiation is needed — the host just picks.
enum VideoCodec {
    case h264, hevc
    var cmType: CMVideoCodecType {
        self == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
    }
}

// Debugging aid: EXTDISP_TRACE=1 logs every frame into the encoder (IN), out
// of it (OUT, with size) and every idle re-submission (REPEAT) to stderr.
let diagTraceOn = ProcessInfo.processInfo.environment["EXTDISP_TRACE"] == "1"
let diagTraceStart = DispatchTime.now().uptimeNanoseconds
func diagTrace(_ message: @autoclosure () -> String) {
    guard diagTraceOn else { return }
    let start = diagTraceStart  // read first: the lazy global must initialise before "now"
    let ms = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000
    fputs("TRACE \(String(format: "%9.1f", ms)) \(message())\n", stderr)
}

final class AnnexBEncoder {
    private let sender: VideoSender
    private let codec: VideoCodec
    private let width: Int32
    private let height: Int32
    private let fps: Int
    private let bitrate: Int
    private var session: VTCompressionSession?
    private var sentParameterSets = false
    private var frameCount: Int64 = 0
    fileprivate var reportedSendError = false
    var quietErrors = false  // set while the supervisor is already reporting a pairing mismatch

    init(codec: VideoCodec, width: Int, height: Int, fps: Int, bitrate: Int,
         keyframeEverySeconds: Int = 1, sender: VideoSender) throws {
        self.sender = sender
        self.codec = codec
        self.width = Int32(width)
        self.height = Int32(height)
        self.fps = fps
        self.bitrate = bitrate

        let callback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
            guard status == noErr, let refcon, let sampleBuffer else { return }
            let encoder = Unmanaged<AnnexBEncoder>.fromOpaque(refcon).takeUnretainedValue()
            do {
                try encoder.handleEncodedSample(sampleBuffer)
            } catch {
                // Every frame still in flight fails the same way once the socket
                // is gone — one line per connection is enough.
                if !encoder.reportedSendError && !encoder.quietErrors {
                    fputs("Encode callback error: \(error)\n", stderr)
                }
                encoder.reportedSendError = true
            }
        }

        // H.264 uses VideoToolbox's low-latency rate control: measured on an M4
        // at 2960x1848@60 it cut encode time from ~21 ms to ~15 ms per frame with
        // no loss of fidelity (same PSNR against the Mac's framebuffer, same text
        // sharpness while scrolling). If an encoder refuses the option we fall
        // back to the default mode rather than fail.
        let lowLatency = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue] as CFDictionary
        var createStatus: OSStatus = -1
        for specification in (codec == .h264 ? [lowLatency, nil] : [nil]) as [CFDictionary?] {
            createStatus = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: self.width,
                height: self.height,
                codecType: codec.cmType,
                encoderSpecification: specification,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: callback,
                refcon: Unmanaged.passUnretained(self).toOpaque(),
                compressionSessionOut: &session
            )
            if createStatus == noErr { break }
        }
        guard createStatus == noErr, let session else {
            throw MacHostError.encoder(createStatus)
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: NSNumber(value: fps * max(keyframeEverySeconds, 1)))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate))
        if codec == .hevc {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                                 value: kVTProfileLevel_HEVC_Main_AutoLevel)
        }

        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepareStatus == noErr else {
            throw MacHostError.encoder(prepareStatus)
        }
    }

    deinit {
        finish()
    }

    // Flushes and tears down the compression session. Called explicitly between
    // reconnects (after capture has stopped, so no new frames race the callback)
    // and again from deinit. Idempotent.
    func finish() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            self.session = nil
        }
    }

    func encode(_ imageBuffer: CVImageBuffer) throws {
        guard let session else { return }
        let presentationTime = CMTime(value: frameCount, timescale: CMTimeScale(fps))
        diagTrace("IN  \(frameCount)")
        frameCount += 1

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: presentationTime,
            duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        guard status == noErr else {
            throw MacHostError.encoder(status)
        }
    }

    private func handleEncodedSample(_ sampleBuffer: CMSampleBuffer) throws {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
              CFArrayGetCount(attachments) > 0 else {
            return
        }

        let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
        let notSync = CFDictionaryContainsKey(
            attachment,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
        )
        let isKeyframe = !notSync
        diagTrace("OUT \(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).value) " +
                  "bytes=\(CMSampleBufferGetTotalSampleSize(sampleBuffer))\(isKeyframe ? " key" : "")")

        if isKeyframe || !sentParameterSets {
            try writeParameterSets(sampleBuffer)
            sentParameterSets = true
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &length,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == noErr, let dataPointer else {
            throw MacHostError.encoder(status)
        }

        var offset = 0
        while offset + 4 <= totalLength {
            let nalLength = dataPointer.withMemoryRebound(to: UInt8.self, capacity: totalLength) { pointer in
                (Int(pointer[offset]) << 24) |
                (Int(pointer[offset + 1]) << 16) |
                (Int(pointer[offset + 2]) << 8) |
                Int(pointer[offset + 3])
            }
            offset += 4
            guard nalLength > 0, offset + nalLength <= totalLength else { break }

            var packet = Data([0x00, 0x00, 0x00, 0x01])
            packet.append(UnsafeRawPointer(dataPointer.advanced(by: offset)).assumingMemoryBound(to: UInt8.self), count: nalLength)
            try sender.send(nal: packet)
            offset += nalLength
        }
    }

    // Reads one parameter set (SPS/PPS for H.264; VPS/SPS/PPS for HEVC) from the
    // format description, dispatching to the codec-specific accessor.
    private func getParameterSet(_ description: CMFormatDescription, index: Int,
                                 pointer: inout UnsafePointer<UInt8>?, size: inout Int,
                                 count: inout Int) -> OSStatus {
        if codec == .hevc {
            return CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                description, parameterSetIndex: index,
                parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        }
        return CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            description, parameterSetIndex: index,
            parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
    }

    private func writeParameterSets(_ sampleBuffer: CMSampleBuffer) throws {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return
        }

        var parameterSetCount = 0
        var ignoredPointer: UnsafePointer<UInt8>?
        var ignoredSize = 0
        let countStatus = getParameterSet(description, index: 0,
                                          pointer: &ignoredPointer, size: &ignoredSize,
                                          count: &parameterSetCount)
        guard countStatus == noErr else { return }

        for index in 0..<parameterSetCount {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            var ignoredCount = 0
            let status = getParameterSet(description, index: index,
                                         pointer: &pointer, size: &size,
                                         count: &ignoredCount)
            guard status == noErr, let pointer else { continue }

            var packet = Data([0x00, 0x00, 0x00, 0x01])
            packet.append(pointer, count: size)
            try sender.send(nal: packet)
        }
    }
}

final class ScreenCaptureHost: NSObject, SCStreamOutput {
    private let encoder: AnnexBEncoder
    private let audioSink: ((CMSampleBuffer) -> Void)?
    private var stream: SCStream?

    // ScreenCaptureKit only delivers a frame when the screen changes, so a
    // still desktop sends nothing. Two things go wrong if we leave it there:
    //  - the tablet's decoder only presents a decoded frame when the NEXT one
    //    arrives, so the newest frame (the cursor leaving, the result of a tap)
    //    stays undisplayed until something else changes;
    //  - the last frame of a burst of motion is the blurriest one the encoder
    //    made, and nothing ever sharpens it.
    // So after the screen goes still we re-submit the last frame a few times at
    // the normal frame rate (what a constant-frame-rate sender — the Windows
    // host's ffmpeg — does all the time). Identical frames cost a few hundred
    // bytes each. All of this state lives on `frameQueue`.
    private let frameQueue = DispatchQueue(label: "screen.frames")
    private var repeatTimer: DispatchSourceTimer?
    private var lastBuffer: CVImageBuffer?
    private var lastSubmitNs: UInt64 = 0
    private var repeatsLeft = 0
    private var repeatBudget = 0
    private var frameIntervalNs: UInt64 = 16_666_667

    init(encoder: AnnexBEncoder, audioSink: ((CMSampleBuffer) -> Void)? = nil) {
        self.encoder = encoder
        self.audioSink = audioSink
    }

    func start(display: SCDisplay, width: Int, height: Int, fps: Int) async throws {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        // One more than before: we keep the newest frame alive for re-submission.
        configuration.queueDepth = fps >= 120 ? 6 : 4
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = true
        if audioSink != nil {
            // System-audio mix (the display filter excludes nothing, so this is
            // everything the Mac plays — the WASAPI-loopback equivalent).
            configuration.capturesAudio = true
            configuration.sampleRate = 48000
            configuration.channelCount = 2
            configuration.excludesCurrentProcessAudio = true
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
        if audioSink != nil {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "audio.frames"))
        }
        try await stream.startCapture()
        self.stream = stream
        startRepeatTimer(fps: fps)
    }

    func stop() async {
        frameQueue.sync {
            repeatTimer?.cancel()
            repeatTimer = nil
            lastBuffer = nil
            repeatsLeft = 0
        }
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
    }

    private func startRepeatTimer(fps: Int) {
        frameQueue.sync {
            frameIntervalNs = UInt64(1_000_000_000 / max(fps, 1))
            repeatBudget = max(fps / 4, 2)  // ~250 ms of repeats after the last change
            let timer = DispatchSource.makeTimerSource(queue: frameQueue)
            timer.schedule(deadline: .now() + .nanoseconds(Int(frameIntervalNs)),
                           repeating: .nanoseconds(Int(frameIntervalNs)),
                           leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.repeatLastFrameIfIdle() }
            timer.resume()
            repeatTimer = timer
        }
    }

    // Runs on frameQueue once per frame interval.
    private func repeatLastFrameIfIdle() {
        guard repeatsLeft > 0, let buffer = lastBuffer else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        // Capture jitters by up to a frame while content is moving, so the first
        // repeat waits for ~2 silent intervals (otherwise we'd wedge duplicates
        // between live frames and double the encoder's load); after that, one
        // repeat per interval.
        let firstRepeat = repeatsLeft == repeatBudget
        let quiet = firstRepeat ? frameIntervalNs * 2 - frameIntervalNs / 4
                                : frameIntervalNs - frameIntervalNs / 4
        guard now &- lastSubmitNs >= quiet else { return }
        repeatsLeft -= 1
        lastSubmitNs = now
        if repeatsLeft == 0 { lastBuffer = nil }  // hand the surface back once we're done
        diagTrace("REPEAT left=\(repeatsLeft)")
        do {
            try encoder.encode(buffer)
        } catch {
            fputs("Frame encode error: \(error)\n", stderr)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        if outputType == .audio {
            audioSink?(sampleBuffer)
            return
        }
        guard outputType == .screen,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        lastBuffer = imageBuffer
        lastSubmitNs = DispatchTime.now().uptimeNanoseconds
        repeatsLeft = repeatBudget
        do {
            try encoder.encode(imageBuffer)
        } catch {
            fputs("Frame encode error: \(error)\n", stderr)
        }
    }
}

// Signal sources are retained for the whole process; SIGINT/SIGTERM set the
// shared stop flag so the supervisor loop exits and runs its teardown (park the
// virtual display, stop the touch bridge). RunLoop.run() is unavailable from
// async contexts, and the loop polls g_stop between short sleeps anyway.
var g_signalSources: [DispatchSourceSignal] = []

func installSignalHandlers() {
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler { g_stop.set() }
        source.activate()
        g_signalSources.append(source)
    }
}

@main
struct MacHostMain {
    // Retries until the tablet listener is reachable: covers the receiver-app
    // launch race, brief rebind gaps between sessions, and the one-time macOS
    // Local Network permission grant (first Wi-Fi run).
    static func connectWithRetry(host: String, port: Int) async -> TcpWriter? {
        var announced = false
        while !g_stop.isSet {
            do {
                return try TcpWriter(host: host, port: port)
            } catch {
                if !announced {
                    print("Tablet not reachable (\(error)); retrying every 2s — " +
                          "is the app open on the tablet? Over Wi-Fi, also allow this " +
                          "app under System Settings > Privacy & Security > Local Network.")
                    announced = true
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        return nil  // stopping
    }

    // Picks what to capture: --display N captures an existing display (index
    // into ScreenCaptureKit's list, phase-1 behavior); the default creates the
    // native virtual display sized to the tablet's panel — a true extended
    // display, no third-party tool. Returns the SCDisplay, its native pixel
    // size, and the VirtualDisplay handle to keep alive (nil for --display).
    static func selectDisplay(_ options: Options) async throws
        -> (display: SCDisplay, nativeWidth: Int, nativeHeight: Int, virtual: VirtualDisplay?) {
        if let index = options.displayIndex {
            let content = try await SCShareableContent.current
            let displays = content.displays
            guard !displays.isEmpty else { throw MacHostError.noDisplays }
            guard displays.indices.contains(index) else {
                throw MacHostError.displayIndexOutOfRange(index)
            }
            let display = displays[index]
            // SCDisplay reports points; the display mode has the pixel size.
            if let mode = CGDisplayCopyDisplayMode(display.displayID) {
                return (display, mode.pixelWidth, mode.pixelHeight, nil)
            }
            return (display, display.width, display.height, nil)
        }

        guard let virtualDisplay = VirtualDisplay(fps: options.fps) else {
            throw MacHostError.virtualDisplay(
                "Could not create the virtual display (private CGVirtualDisplay API " +
                "unavailable?). Pass --display N to capture an existing display.")
        }
        guard await virtualDisplay.waitUntilOnline(timeoutSeconds: 5.0) else {
            throw MacHostError.virtualDisplay(
                "Virtual display did not come online. Pass --display N to capture an " +
                "existing display.")
        }
        virtualDisplay.configureAsExtension()
        virtualDisplay.selectNativeMode()
        // Let WindowServer settle the new arrangement before capturing.
        try? await Task.sleep(nanoseconds: 500_000_000)
        // Fetch shareable content only now — a snapshot taken before the display
        // registered would not include it.
        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == virtualDisplay.displayID }) else {
            throw MacHostError.virtualDisplay(
                "Virtual display is online but ScreenCaptureKit does not list it.")
        }
        print("Virtual display \(virtualDisplay.adopted ? "adopted from an earlier run" : "online"): " +
              "\(virtualDisplay.width)x\(virtualDisplay.height)@\(Int(virtualDisplay.refreshHz)) " +
              "(id \(virtualDisplay.displayID))")
        return (display, virtualDisplay.width, virtualDisplay.height, virtualDisplay)
    }

    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)  // line-buffered: Finder launches log to a file
        signal(SIGPIPE, SIG_IGN)  // a dead-socket write must return an error, not kill us
        installSignalHandlers()   // SIGINT/SIGTERM → g_stop → clean teardown
        LocalMute.restoreIfNeeded()  // self-heal a mute left by a force-killed run
        do {
            var options = try parseOptions(CommandLine.arguments)

            if options.selfTest {
                exit(runSelfTests())
            }
            if options.cryptoSelfTest {
                exit(runCryptoSelfTest())
            }
            if let code = options.deriveKeyCode {
                guard let key = PairingCrypto.deriveKey(code: code) else {
                    fputs("derive failed\n", stderr); exit(1)
                }
                print(PairingCrypto.hex(key))
                exit(0)
            }

            // Pairing: EXTDISPLAY_KEY (env, not argv, so it never shows in a
            // process listing) → derive the shared key and encrypt the link.
            var pairKey: SymmetricKey?
            if let code = ProcessInfo.processInfo.environment["EXTDISPLAY_KEY"], !code.isEmpty {
                guard let key = PairingCrypto.deriveKey(code: code) else {
                    fputs("Error: could not derive the pairing key from EXTDISPLAY_KEY\n", stderr)
                    exit(1)
                }
                pairKey = key
                print("Pairing enabled — encrypting the link (enter the code on the tablet).")
            }

            if options.removeDisplay {
                print("Restoring the permanent display configuration. This removes " +
                      "session virtual displays (including other apps') and any " +
                      "unsaved display arrangement changes.")
                VirtualDisplay.removeAllSessionDisplays()
                exit(0)
            }

            // --wifi: find the tablet on the LAN (unless --host pinned an IP).
            if options.wifi && !options.hostExplicit {
                var announced = false
                while !g_stop.isSet {
                    if let ip = Discovery.findTablet(timeoutSeconds: 15) {
                        options.host = ip
                        break
                    }
                    if !announced {
                        print("No tablet found yet; retrying. (Same Wi-Fi network? App open?)")
                        announced = true
                    }
                }
                if g_stop.isSet { exit(0) }
            }

            // Display + touch are set up once; the video connection restarts on
            // its own below.
            let selection = try await selectDisplay(options)
            let encodeWidth = options.width > 0 ? options.width : selection.nativeWidth
            let encodeHeight = options.height > 0 ? options.height : selection.nativeHeight
            if let index = options.displayIndex {
                print("Capture: ScreenCaptureKit display \(index)")
            } else {
                print("Capture: virtual display (extended desktop)")
            }
            let codec: VideoCodec = options.hevc ? .hevc : .h264
            print("Encode: \(options.hevc ? "HEVC" : "H.264") VideoToolbox, " +
                  "\(encodeWidth)x\(encodeHeight) @ \(options.fps) FPS")

            var touchBridge: TouchBridge?
            if !options.noTouch {
                let port = touchPort(forHost: options.host, videoPort: options.port)
                touchBridge = TouchBridge(host: options.host, port: port,
                                          displayID: selection.display.displayID,
                                          key: pairKey,
                                          eraserKey: options.eraserKey)
                touchBridge?.start()
            }

            var audioBridge: AudioBridge?
            if options.audio {
                let port = audioPort(forHost: options.host, videoPort: options.port)
                audioBridge = AudioBridge(host: options.host, port: port, key: pairKey,
                                          delayMs: options.audioDelayMs,
                                          muteLocal: options.muteLocal)
                audioBridge?.start()
                print("Desktop audio bridge active (Mac audio plays on the tablet).")
            }

            // Supervisor loop: connect, stream until the tablet drops (SIGPIPE is
            // ignored process-wide, so a dead-socket write returns an error and
            // clears the sender's `alive` flag), then reconnect — like the
            // Windows host restarting the stream on disconnect.
            var reconnecting = false
            // A tablet holding a DIFFERENT pairing key closes the encrypted
            // stream on the first frame it can't authenticate, so the host sees
            // connect → write failure → reconnect, forever. Two such short-lived
            // connections in a row and we say what it is (once), then retry
            // quietly and slower until a connection survives.
            var shortDrops = 0
            var mismatchReported = false
            while !g_stop.isSet {
                let videoSender: VideoSender
                if options.udp {
                    // Connectionless: stream blind (loss shows as a brief glitch
                    // that clears on the next keyframe). One pass; Ctrl+C ends it.
                    print("Streaming over UDP to \(options.host):\(options.port)")
                    videoSender = VideoSender(udp: try UdpVideoSender(host: options.host,
                                                                      port: options.port,
                                                                      key: pairKey))
                } else {
                    if !mismatchReported {
                        print(reconnecting ? "Reconnecting to \(options.host):\(options.port)…"
                                           : "Connecting to \(options.host):\(options.port)")
                    }
                    guard let writer = await connectWithRetry(host: options.host, port: options.port) else {
                        break  // stopping
                    }
                    videoSender = try VideoSender(writer: writer, key: pairKey)
                }

                // TCP never loses data, and every (re)connection starts a fresh
                // encoder with its own keyframe, so periodic keyframes only cost
                // bits there: at one per second they were ~half of everything
                // sent while scrolling text (≈490 KB each vs ≈9 KB per frame).
                // UDP keeps one per second — it is the only loss recovery it has.
                let encoder = try AnnexBEncoder(codec: codec, width: encodeWidth, height: encodeHeight,
                                                fps: options.fps, bitrate: options.bitrate,
                                                keyframeEverySeconds: options.udp ? 1 : 4,
                                                sender: videoSender)
                encoder.quietErrors = mismatchReported
                let host = ScreenCaptureHost(
                    encoder: encoder,
                    audioSink: audioBridge.map { bridge in { bridge.enqueue($0) } })
                try await host.start(display: selection.display, width: encodeWidth,
                                     height: encodeHeight, fps: options.fps)
                let connectedAt = Date()
                let survivedAfter = 3.0  // seconds a connection must last to count as healthy
                if !mismatchReported {
                    print(reconnecting ? "Reconnected. Streaming." : "Streaming. Press Ctrl+C to stop.")
                }

                // Wait until the tablet drops the stream (TCP only) or the user quits.
                while !g_stop.isSet && videoSender.alive.isSet {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    if diagTraceOn, let link = videoSender.linkStats() {
                        diagTrace("NET rtt=\(link.rttMs)ms queued=\(link.queuedBytes)B")
                    }
                    if mismatchReported && Date().timeIntervalSince(connectedAt) >= survivedAfter {
                        // The tablet accepted the stream: the code was fixed.
                        mismatchReported = false
                        shortDrops = 0
                        encoder.quietErrors = false
                        print("Reconnected. Streaming.")
                    }
                }
                await host.stop()
                encoder.finish()  // flush the session before its reference drops
                if !g_stop.isSet {
                    let lived = Date().timeIntervalSince(connectedAt)
                    shortDrops = (pairKey != nil && !options.udp && lived < survivedAfter) ? shortDrops + 1 : 0
                    if shortDrops >= 2 && !mismatchReported {
                        mismatchReported = true
                        print("Pairing code mismatch — the tablet keeps closing the encrypted stream. " +
                              "Enter this Mac's pairing code on the tablet (it shows a code box at the " +
                              "top of the screen); MacHost keeps retrying.")
                    } else if !mismatchReported {
                        print("Stream ended (tablet disconnected or app closed). Reconnecting…")
                    }
                    reconnecting = true
                    // Gentle backoff; slower while we already know why it fails.
                    try? await Task.sleep(nanoseconds: mismatchReported ? 3_000_000_000 : 1_000_000_000)
                }
            }

            touchBridge?.stop()
            audioBridge?.stop()  // also un-mutes the Mac if --mute-local was on
            // Hold the reference until here so the display lives for the whole run;
            // exiting (below) is what removes it — WindowServer reclaims a virtual
            // display when its owner exits.
            _ = selection.virtual
            print("Stopping.")
            exit(0)
        } catch {
            fputs("Error: \(error)\n\n", stderr)
            printUsage()
            exit(1)
        }
    }
}
