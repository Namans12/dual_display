import AVFoundation
import CoreMedia
import CoreVideo
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
              [--display N] [--no-touch]

    --wifi discovers the tablet on the LAN (UDP broadcast) so no IP is needed;
    --host <ip> connects to a specific address (or 127.0.0.1 with adb forward).

    By default MacHost creates a native virtual display (2960x1848@60, the
    tablet's panel) and streams THAT — a true extended display. Pass
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

    USB-C with ADB:
      adb forward tcp:5000 tcp:5000
      adb forward tcp:5001 tcp:5001
      MacHost --host 127.0.0.1 --port 5000

    The virtual display persists for the login session while idle (macOS can't
    remove one on demand); MacHost parks it out of the cursor's way on stop and
    reuses it on the next run. Logout — or --remove-display — clears it.
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
        case "--remove-display":
            options.removeDisplay = true
        case "--no-touch":
            options.noTouch = true
        case "--selftest":
            options.selfTest = true
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

final class H264AnnexBEncoder {
    private let writer: TcpWriter
    private let width: Int32
    private let height: Int32
    private let fps: Int
    private let bitrate: Int
    private var session: VTCompressionSession?
    private var sentParameterSets = false
    private var frameCount: Int64 = 0

    init(width: Int, height: Int, fps: Int, bitrate: Int, writer: TcpWriter) throws {
        self.writer = writer
        self.width = Int32(width)
        self.height = Int32(height)
        self.fps = fps
        self.bitrate = bitrate

        let callback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
            guard status == noErr, let refcon, let sampleBuffer else { return }
            let encoder = Unmanaged<H264AnnexBEncoder>.fromOpaque(refcon).takeUnretainedValue()
            do {
                try encoder.handleEncodedSample(sampleBuffer)
            } catch {
                fputs("Encode callback error: \(error)\n", stderr)
            }
        }

        let createStatus = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: self.width,
            height: self.height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: callback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )
        guard createStatus == noErr, let session else {
            throw MacHostError.encoder(createStatus)
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: fps))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate))

        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepareStatus == noErr else {
            throw MacHostError.encoder(prepareStatus)
        }
    }

    deinit {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
    }

    func encode(_ imageBuffer: CVImageBuffer) throws {
        guard let session else { return }
        let presentationTime = CMTime(value: frameCount, timescale: CMTimeScale(fps))
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
            try writer.write(packet)
            offset += nalLength
        }
    }

    private func writeParameterSets(_ sampleBuffer: CMSampleBuffer) throws {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return
        }

        var parameterSetCount = 0
        var nalUnitHeaderLength: Int32 = 0
        let countStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            description,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalUnitHeaderLength
        )
        guard countStatus == noErr else { return }

        for index in 0..<parameterSetCount {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                description,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            guard status == noErr, let pointer else { continue }

            var packet = Data([0x00, 0x00, 0x00, 0x01])
            packet.append(pointer, count: size)
            try writer.write(packet)
        }
    }
}

final class ScreenCaptureHost: NSObject, SCStreamOutput {
    private let encoder: H264AnnexBEncoder
    private var stream: SCStream?

    init(encoder: H264AnnexBEncoder) {
        self.encoder = encoder
    }

    func start(display: SCDisplay, width: Int, height: Int, fps: Int) async throws {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = true

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "screen.frames"))
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen else { return }
        guard CMSampleBufferIsValid(sampleBuffer),
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        do {
            try encoder.encode(imageBuffer)
        } catch {
            fputs("Frame encode error: \(error)\n", stderr)
        }
    }
}

// Keeps the process alive until SIGINT/SIGTERM, then returns so callers can tear
// down (virtual display, in-flight sockets) before exiting. RunLoop.run() is
// unavailable from async contexts; frames arrive on their own queues anyway.
func parkUntilSignal() async {
    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func first() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if fired { return false }
            fired = true
            return true
        }
    }
    let once = Once()
    var sources: [DispatchSourceSignal] = []
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                g_stop.set()
                if once.first() { continuation.resume() }
            }
            source.activate()
            sources.append(source)
        }
    }
    withExtendedLifetime(sources) {}
}

@main
struct MacHostMain {
    // Retries until the tablet listener is reachable: covers the receiver-app
    // launch race, brief rebind gaps between sessions, and the one-time macOS
    // Local Network permission grant (first Wi-Fi run).
    static func connectWithRetry(host: String, port: Int) async -> TcpWriter {
        var announced = false
        while true {
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

        guard let virtualDisplay = VirtualDisplay() else {
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
              "\(VirtualDisplay.width)x\(VirtualDisplay.height)@\(Int(VirtualDisplay.refreshHz)) " +
              "(id \(virtualDisplay.displayID))")
        return (display, VirtualDisplay.width, VirtualDisplay.height, virtualDisplay)
    }

    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)  // line-buffered: Finder launches log to a file
        do {
            var options = try parseOptions(CommandLine.arguments)

            if options.selfTest {
                exit(runSelfTests())
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

            print("Connecting to \(options.host):\(options.port)")

            let writer = await connectWithRetry(host: options.host, port: options.port)

            let selection = try await selectDisplay(options)
            let encodeWidth = options.width > 0 ? options.width : selection.nativeWidth
            let encodeHeight = options.height > 0 ? options.height : selection.nativeHeight
            if let index = options.displayIndex {
                print("Capture: ScreenCaptureKit display \(index)")
            } else {
                print("Capture: virtual display (extended desktop)")
            }
            print("Encode: H.264 VideoToolbox, \(encodeWidth)x\(encodeHeight) @ \(options.fps) FPS")

            let encoder = try H264AnnexBEncoder(width: encodeWidth, height: encodeHeight,
                                                fps: options.fps, bitrate: options.bitrate,
                                                writer: writer)
            let host = ScreenCaptureHost(encoder: encoder)
            try await host.start(display: selection.display, width: encodeWidth,
                                 height: encodeHeight, fps: options.fps)

            var touchBridge: TouchBridge?
            if !options.noTouch {
                let port = touchPort(forHost: options.host, videoPort: options.port)
                touchBridge = TouchBridge(host: options.host, port: port,
                                          displayID: selection.display.displayID)
                touchBridge?.start()
            }

            print("Streaming. Press Ctrl+C to stop.")
            await parkUntilSignal()
            touchBridge?.stop()
            await host.stop()
            if let virtualDisplay = selection.virtual {
                // The display can't be removed on macOS 26 — park it out of the
                // cursor's reach; the next run adopts it. Logout removes it.
                virtualDisplay.parkInactive()
                try? await Task.sleep(nanoseconds: 300_000_000)
                print("Virtual display parked (reused on the next run; logout removes " +
                      "it, or run MacHost --remove-display).")
            }
            print("Stopping.")
            exit(0)
        } catch {
            fputs("Error: \(error)\n\n", stderr)
            printUsage()
            exit(1)
        }
    }
}
