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
    var width = 2560
    var height = 1600
    var bitrate = 25_000_000
    var displayIndex = 0
}

enum MacHostError: Error, CustomStringConvertible {
    case invalidArgument(String)
    case noDisplays
    case displayIndexOutOfRange(Int)
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
    MacHost Phase 1

    Usage:
      MacHost --host <ip> [--port 5000] [--fps 60]
              [--width 2560] [--height 1600] [--bitrate 25000000]
              [--display 0]

    Examples:
      MacHost --host 192.168.1.50 --port 5000
      MacHost --host 127.0.0.1 --port 5000 --fps 60 --width 2560 --height 1600

    USB-C with ADB:
      adb forward tcp:5000 tcp:5000
      MacHost --host 127.0.0.1 --port 5000
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
    guard options.width > 0, options.height > 0 else {
        throw MacHostError.invalidArgument("--width and --height must be positive")
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
            close(fd)
            throw MacHostError.socket("Could not connect to \(host):\(port)")
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

    init(options: Options, writer: TcpWriter) throws {
        self.writer = writer
        self.width = Int32(options.width)
        self.height = Int32(options.height)
        self.fps = options.fps
        self.bitrate = options.bitrate

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
            width: width,
            height: height,
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
    private let options: Options
    private let encoder: H264AnnexBEncoder
    private var stream: SCStream?

    init(options: Options, encoder: H264AnnexBEncoder) {
        self.options = options
        self.encoder = encoder
    }

    func start() async throws {
        let content = try await SCShareableContent.current
        let displays = content.displays
        guard !displays.isEmpty else {
            throw MacHostError.noDisplays
        }
        guard displays.indices.contains(options.displayIndex) else {
            throw MacHostError.displayIndexOutOfRange(options.displayIndex)
        }

        let display = displays[options.displayIndex]
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = options.width
        configuration.height = options.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = true

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "screen.frames"))
        try await stream.startCapture()
        self.stream = stream
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

@main
struct MacHostMain {
    static func main() async {
        do {
            let options = try parseOptions(CommandLine.arguments)
            print("Connecting to \(options.host):\(options.port)")
            print("Capture: ScreenCaptureKit display \(options.displayIndex)")
            print("Encode: H.264 VideoToolbox, \(options.width)x\(options.height) @ \(options.fps) FPS")

            let writer = try TcpWriter(host: options.host, port: options.port)
            let encoder = try H264AnnexBEncoder(options: options, writer: writer)
            let host = ScreenCaptureHost(options: options, encoder: encoder)
            try await host.start()

            print("Streaming. Press Ctrl+C to stop.")
            RunLoop.current.run()
        } catch {
            fputs("Error: \(error)\n\n", stderr)
            printUsage()
            exit(1)
        }
    }
}
