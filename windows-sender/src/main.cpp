#include <array>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

struct Options {
    std::string host = "127.0.0.1";
    int port = 5000;
    int fps = 60;
    int width = 2560;
    int height = 1600;
    bool useNvenc = true;
    bool useDxgiCapture = true;
    int displayIndex = 0;
};

static void printUsage() {
    std::cout
        << "ExtendedDisplaySender Phase 1\n\n"
        << "Usage:\n"
        << "  ExtendedDisplaySender.exe --host <ip> [--port 5000] [--fps 60]\n"
        << "                            [--width 2560] [--height 1600]\n"
        << "                            [--display 0] [--x264] [--gdi]\n\n"
        << "Examples:\n"
        << "  ExtendedDisplaySender.exe --host 192.168.1.50 --port 5000\n"
        << "  ExtendedDisplaySender.exe --host 127.0.0.1 --port 5000 --x264\n";
}

static int readInt(const char* value, const char* name) {
    try {
        return std::stoi(value);
    } catch (...) {
        throw std::runtime_error(std::string("Invalid integer for ") + name);
    }
}

static Options parseArgs(int argc, char** argv) {
    Options options;

    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        auto requireValue = [&](const char* name) -> const char* {
            if (i + 1 >= argc) {
                throw std::runtime_error(std::string("Missing value for ") + name);
            }
            return argv[++i];
        };

        if (arg == "--help" || arg == "-h") {
            printUsage();
            std::exit(0);
        } else if (arg == "--host") {
            options.host = requireValue("--host");
        } else if (arg == "--port") {
            options.port = readInt(requireValue("--port"), "--port");
        } else if (arg == "--fps") {
            options.fps = readInt(requireValue("--fps"), "--fps");
        } else if (arg == "--width") {
            options.width = readInt(requireValue("--width"), "--width");
        } else if (arg == "--height") {
            options.height = readInt(requireValue("--height"), "--height");
        } else if (arg == "--display") {
            options.displayIndex = readInt(requireValue("--display"), "--display");
        } else if (arg == "--x264") {
            options.useNvenc = false;
        } else if (arg == "--gdi") {
            options.useDxgiCapture = false;
        } else {
            throw std::runtime_error("Unknown argument: " + arg);
        }
    }

    if (options.host.empty()) {
        throw std::runtime_error("--host must not be empty");
    }
    if (options.port <= 0 || options.port > 65535) {
        throw std::runtime_error("--port must be between 1 and 65535");
    }
    if (options.fps <= 0 || options.fps > 240) {
        throw std::runtime_error("--fps must be between 1 and 240");
    }
    if (options.width <= 0 || options.height <= 0) {
        throw std::runtime_error("--width and --height must be positive");
    }

    return options;
}

static std::string quote(const std::string& value) {
    std::string out = "\"";
    for (char ch : value) {
        if (ch == '"') {
            out += "\\\"";
        } else {
            out += ch;
        }
    }
    out += "\"";
    return out;
}

static std::string buildFfmpegCommand(const Options& options) {
    const std::string encoder = options.useNvenc ? "h264_nvenc" : "libx264";
    const std::string preset = options.useNvenc ? "p1" : "ultrafast";
    const std::string tune = options.useNvenc ? "ull" : "zerolatency";
    const std::string scale =
        "scale=" + std::to_string(options.width) + ":" +
        std::to_string(options.height) + ":flags=fast_bilinear";

    std::ostringstream cmd;
    cmd << "ffmpeg"
        << " -hide_banner"
        << " -loglevel warning";

    if (options.useDxgiCapture) {
        cmd << " -filter_complex "
            << quote("ddagrab=output_idx=" + std::to_string(options.displayIndex) +
                     ":framerate=" + std::to_string(options.fps) +
                     ",hwdownload,format=bgra," + scale);
    } else {
        cmd << " -f gdigrab"
            << " -framerate " << options.fps
            << " -i desktop"
            << " -vf " << quote(scale);
    }

    cmd << " -an"
        << " -c:v " << encoder;

    if (options.useNvenc) {
        cmd << " -preset " << preset
            << " -tune " << tune
            << " -rc cbr"
            << " -zerolatency 1"
            << " -delay 0"
            << " -bf 0"
            << " -g " << options.fps;
    } else {
        cmd << " -preset " << preset
            << " -tune " << tune
            << " -bf 0"
            << " -g " << options.fps;
    }

    cmd << " -pix_fmt yuv420p"
        << " -f h264"
        << " tcp://" << options.host << ":" << options.port;

    return cmd.str();
}

int main(int argc, char** argv) {
    try {
        const Options options = parseArgs(argc, argv);
        const std::string command = buildFfmpegCommand(options);

        std::cout << "Starting low-latency H.264 stream to "
                  << options.host << ":" << options.port << "\n";
        std::cout << "Resolution: " << options.width << "x" << options.height
                  << " @ " << options.fps << " FPS\n";
        std::cout << "Encoder: " << (options.useNvenc ? "NVENC" : "x264") << "\n\n";
        std::cout << "Capture: " << (options.useDxgiCapture ? "DXGI Desktop Duplication via FFmpeg ddagrab" : "GDI fallback") << "\n\n";
        std::cout << command << "\n\n";

        const int exitCode = std::system(command.c_str());
        if (exitCode != 0) {
            std::cerr << "FFmpeg exited with code " << exitCode << "\n";
        }
        return exitCode;
    } catch (const std::exception& ex) {
        std::cerr << "Error: " << ex.what() << "\n\n";
        printUsage();
        return 1;
    }
}
