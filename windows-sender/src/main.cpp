// ExtendedDisplaySender — plug-and-play extended-display host for Windows.
//
// Flow (no arguments needed):
//   1. Find ffmpeg.exe and adb.exe (beside this exe, then PATH).
//   2. Enumerate displays across ALL DXGI adapters; pick the first attached
//      non-primary output (the extended display). If none, try to enable the
//      Amyuni virtual display driver, else instruct the user.
//   3. Wait for the tablet over USB (adb), install/launch the receiver app,
//      set up adb forward.
//   4. Probe encoders (NVENC -> QSV -> AMF -> x264) and stream with the best
//      one, falling back automatically. Restart the stream on disconnect.

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>
#include <windows.h>
#include <shellapi.h>
#include <dxgi.h>

#include <atomic>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {

constexpr int kRemotePort = 5000;       // video listener inside the Android app
constexpr int kRemoteTouchPort = 5001;  // touch uplink listener inside the app
constexpr int kDiscoveryPort = 5002;    // UDP discovery port on the tablet
constexpr ULONGLONG kProvenUptimeMs = 5000;

// UDP video framing (low-latency Wi-Fi path). Each NAL unit is split into
// datagrams with a 12-byte big-endian header: magic, nalSeq, fragIndex,
// fragCount. The receiver reassembles by nalSeq and drops incomplete NALs.
constexpr uint32_t kUdpMagic = 0x45585544;  // 'EXUD'
constexpr int kUdpPayloadMax = 1400;        // keep total datagram under ~1500 MTU
constexpr int kUdpHeaderSize = 12;

std::atomic<bool> g_stop{false};
std::atomic<HANDLE> g_child{nullptr};

struct Options {
    int port = 5000;          // local forward port
    int fps = 60;
    int bitrateKbps = 25000;
    int displayOverride = -1; // flat index from --list-displays
    int width = 0;            // 0 = native resolution of the captured display
    int height = 0;
    std::string host;         // non-empty = direct TCP (WiFi), skip adb
    std::string encoderOverride; // nvenc|qsv|amf|x264
    bool noZeroCopy = false;
    bool noTouch = false;
    bool hevc = false;           // H.265 instead of H.264 (better at high res)
    bool hdr = false;            // HDR10 (10-bit BT.2020 PQ); implies hevc
    bool wifi = false;           // discover the tablet over the LAN, skip adb
    bool udp = false;            // low-latency UDP video (needs --wifi or --host)
    bool listDisplays = false;
};

struct DisplayInfo {
    int adapterIndex = 0;
    int outputIndex = 0;
    std::string name;
    int left = 0;   // desktop coordinates, needed for touch injection
    int top = 0;
    int width = 0;
    int height = 0;
    bool primary = false;
    bool attached = false;
};

struct Attempt {
    std::string encoder;  // h264_nvenc, h264_qsv, h264_amf, libx264
    bool zeroCopy = false;
};

// ---------------------------------------------------------------- utilities

std::string quote(const std::string& value) {
    return "\"" + value + "\"";
}

bool fileExists(const std::string& path) {
    const DWORD attrs = GetFileAttributesA(path.c_str());
    return attrs != INVALID_FILE_ATTRIBUTES && !(attrs & FILE_ATTRIBUTE_DIRECTORY);
}

std::string exeDirectory() {
    char buffer[MAX_PATH] = {};
    GetModuleFileNameA(nullptr, buffer, MAX_PATH);
    std::string path(buffer);
    const size_t slash = path.find_last_of("\\/");
    return slash == std::string::npos ? "." : path.substr(0, slash);
}

std::string searchPathFor(const std::string& name) {
    char buffer[MAX_PATH] = {};
    if (SearchPathA(nullptr, name.c_str(), nullptr, MAX_PATH, buffer, nullptr) > 0) {
        return std::string(buffer);
    }
    return {};
}

std::string trim(const std::string& s) {
    const auto begin = s.find_first_not_of(" \t\r\n");
    if (begin == std::string::npos) return {};
    const auto end = s.find_last_not_of(" \t\r\n");
    return s.substr(begin, end - begin + 1);
}

void sleepInterruptible(DWORD ms) {
    const ULONGLONG deadline = GetTickCount64() + ms;
    while (!g_stop.load() && GetTickCount64() < deadline) {
        Sleep(100);
    }
}

void collapseToInternal();  // defined below; needed by the ctrl handler

BOOL WINAPI consoleCtrlHandler(DWORD type) {
    if (type == CTRL_C_EVENT || type == CTRL_BREAK_EVENT || type == CTRL_CLOSE_EVENT ||
        type == CTRL_LOGOFF_EVENT || type == CTRL_SHUTDOWN_EVENT) {
        g_stop.store(true);
        // Atomically claim the handle so we never race main's CloseHandle.
        HANDLE child = g_child.exchange(nullptr);
        if (child) {
            TerminateProcess(child, 1);
        }
        // On close/logoff the process dies when this handler returns, so the
        // display must be released here, not in main().
        collapseToInternal();
        return TRUE;
    }
    return FALSE;
}

// Last-resort: if the process faults, still collapse the virtual display so it
// isn't left extended onto a non-existent tablet.
LONG WINAPI crashHandler(EXCEPTION_POINTERS*) {
    collapseToInternal();
    return EXCEPTION_EXECUTE_HANDLER;
}

// --------------------------------------------------------- process plumbing

struct CaptureResult {
    DWORD exitCode = static_cast<DWORD>(-1);
    std::string output;
};

// Runs a command, captures stdout+stderr, waits for exit. Reads the pipe
// while the child runs so a full pipe can never deadlock the child.
CaptureResult runCapture(const std::string& command, const std::string& cwd = {}) {
    CaptureResult result;

    SECURITY_ATTRIBUTES sa{};
    sa.nLength = sizeof(sa);
    sa.bInheritHandle = TRUE;

    HANDLE readPipe = nullptr;
    HANDLE writePipe = nullptr;
    if (!CreatePipe(&readPipe, &writePipe, &sa, 0)) {
        return result;
    }
    SetHandleInformation(readPipe, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOA si{};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdOutput = writePipe;
    si.hStdError = writePipe;
    si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);

    PROCESS_INFORMATION pi{};
    std::string mutableCmd = command;
    const BOOL ok = CreateProcessA(
        nullptr, mutableCmd.data(), nullptr, nullptr, TRUE,
        CREATE_NO_WINDOW, nullptr,
        cwd.empty() ? nullptr : cwd.c_str(), &si, &pi);

    CloseHandle(writePipe);

    if (!ok) {
        CloseHandle(readPipe);
        return result;
    }

    char buffer[4096];
    DWORD bytesRead = 0;
    while (ReadFile(readPipe, buffer, sizeof(buffer), &bytesRead, nullptr) && bytesRead > 0) {
        result.output.append(buffer, bytesRead);
    }
    CloseHandle(readPipe);

    WaitForSingleObject(pi.hProcess, INFINITE);
    GetExitCodeProcess(pi.hProcess, &result.exitCode);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return result;
}

// Launches a long-running child that shares this console (output visible).
bool spawnProcess(const std::string& command, PROCESS_INFORMATION& pi) {
    STARTUPINFOA si{};
    si.cb = sizeof(si);
    std::string mutableCmd = command;
    return CreateProcessA(nullptr, mutableCmd.data(), nullptr, nullptr, FALSE,
                          0, nullptr, nullptr, &si, &pi) != 0;
}

// ----------------------------------------------------------------- displays

std::vector<DisplayInfo> enumerateDisplays() {
    std::vector<DisplayInfo> displays;

    IDXGIFactory1* factory = nullptr;
    if (FAILED(CreateDXGIFactory1(__uuidof(IDXGIFactory1),
                                  reinterpret_cast<void**>(&factory)))) {
        return displays;
    }

    IDXGIAdapter1* adapter = nullptr;
    for (UINT a = 0; factory->EnumAdapters1(a, &adapter) != DXGI_ERROR_NOT_FOUND; ++a) {
        IDXGIOutput* output = nullptr;
        for (UINT o = 0; adapter->EnumOutputs(o, &output) != DXGI_ERROR_NOT_FOUND; ++o) {
            DXGI_OUTPUT_DESC desc{};
            if (SUCCEEDED(output->GetDesc(&desc))) {
                DisplayInfo info;
                info.adapterIndex = static_cast<int>(a);
                info.outputIndex = static_cast<int>(o);
                info.attached = desc.AttachedToDesktop != 0;
                for (WCHAR wc : desc.DeviceName) {
                    if (wc == 0) break;
                    info.name += static_cast<char>(wc);
                }
                if (info.attached) {
                    info.left = desc.DesktopCoordinates.left;
                    info.top = desc.DesktopCoordinates.top;
                    info.width = desc.DesktopCoordinates.right - desc.DesktopCoordinates.left;
                    info.height = desc.DesktopCoordinates.bottom - desc.DesktopCoordinates.top;
                    MONITORINFO mi{};
                    mi.cbSize = sizeof(mi);
                    if (desc.Monitor && GetMonitorInfoW(desc.Monitor, &mi)) {
                        info.primary = (mi.dwFlags & MONITORINFOF_PRIMARY) != 0;
                    }
                }
                displays.push_back(info);
            }
            output->Release();
        }
        adapter->Release();
    }
    factory->Release();
    return displays;
}

void printDisplays(const std::vector<DisplayInfo>& displays) {
    std::cout << "Idx  Adapter  Output  Name           Resolution   Flags\n";
    for (size_t i = 0; i < displays.size(); ++i) {
        const DisplayInfo& d = displays[i];
        std::ostringstream res;
        if (d.attached) {
            res << d.width << "x" << d.height;
        } else {
            res << "-";
        }
        std::cout << "  " << i
                  << "      " << d.adapterIndex
                  << "       " << d.outputIndex
                  << "      " << d.name;
        for (size_t pad = d.name.size(); pad < 15; ++pad) std::cout << ' ';
        std::cout << res.str();
        for (size_t pad = res.str().size(); pad < 13; ++pad) std::cout << ' ';
        if (d.primary) std::cout << "primary ";
        if (!d.attached) std::cout << "detached";
        std::cout << "\n";
    }
}

std::optional<DisplayInfo> pickExtendedDisplay(const std::vector<DisplayInfo>& displays,
                                               int overrideIndex) {
    if (overrideIndex >= 0) {
        if (overrideIndex < static_cast<int>(displays.size()) &&
            displays[overrideIndex].attached) {
            return displays[overrideIndex];
        }
        return std::nullopt;
    }
    for (const DisplayInfo& d : displays) {
        if (d.attached && !d.primary) {
            return d;
        }
    }
    return std::nullopt;
}

// Virtual display lifecycle via the VirtualDrivers VDD (IddCx) + the Windows
// CCD topology API. The VDD's monitor exists once the driver is installed but
// stays INACTIVE until we extend onto it; collapsing back to INTERNAL detaches
// it. Both transitions run in the user session with NO elevation, and there is
// no phantom display while idle. This replaces the old Amyuni enable + SYSTEM
// watcher + flag-file design entirely.
//
// SDC flags (winuser.h): SDC_APPLY 0x80, SDC_TOPOLOGY_INTERNAL 0x01,
// SDC_TOPOLOGY_EXTEND 0x04. Topology flags must NOT be combined with
// SDC_SAVE_TO_DATABASE/SDC_ALLOW_CHANGES (returns ERROR_INVALID_PARAMETER).
std::atomic<bool> g_vddExtended{false};

// Deactivates ONLY the virtual display's CCD path, leaving every real monitor
// active. This is the safe way to release the VDD: SDC_TOPOLOGY_INTERNAL forces
// the laptop's internal panel and would drop any real external monitor the user
// has attached. Non-elevated (a path change needs no admin), so it also works
// when the sender is run directly from the CLI.
bool detachVirtualDisplay() {
    UINT32 numPath = 0, numMode = 0;
    if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &numPath, &numMode) != ERROR_SUCCESS) {
        return false;
    }
    std::vector<DISPLAYCONFIG_PATH_INFO> paths(numPath);
    std::vector<DISPLAYCONFIG_MODE_INFO> modes(numMode);
    if (QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &numPath, paths.data(),
                           &numMode, modes.data(), nullptr) != ERROR_SUCCESS) {
        return false;
    }

    bool found = false;
    for (UINT32 i = 0; i < numPath; ++i) {
        DISPLAYCONFIG_TARGET_DEVICE_NAME tgt{};
        tgt.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
        tgt.header.size = sizeof(tgt);
        tgt.header.adapterId = paths[i].targetInfo.adapterId;
        tgt.header.id = paths[i].targetInfo.id;
        if (DisplayConfigGetDeviceInfo(&tgt.header) != ERROR_SUCCESS) continue;
        // The VirtualDrivers VDD monitor reports hardware id "MTT1337" in its
        // device path and "VDD" in its friendly name.
        const std::wstring devPath = tgt.monitorDevicePath;
        const std::wstring friendly = tgt.monitorFriendlyDeviceName;
        if (devPath.find(L"MTT1337") != std::wstring::npos ||
            friendly.find(L"VDD") != std::wstring::npos) {
            paths[i].flags &= ~DISPLAYCONFIG_PATH_ACTIVE;  // detach only this path
            found = true;
        }
    }
    if (!found) return false;
    return SetDisplayConfig(numPath, paths.data(), numMode, modes.data(),
                            SDC_APPLY | SDC_USE_SUPPLIED_DISPLAY_CONFIG |
                            SDC_ALLOW_CHANGES) == ERROR_SUCCESS;
}

void collapseToInternal() {
    if (g_vddExtended.exchange(false)) {
        // Detach only the VDD (keeps real external monitors). Fall back to
        // internal-only if the VDD path can't be located for some reason.
        if (!detachVirtualDisplay()) {
            SetDisplayConfig(0, nullptr, 0, nullptr, SDC_APPLY | SDC_TOPOLOGY_INTERNAL);
        }
        std::cout << "Virtual display released.\n";
    }
}

std::optional<DisplayInfo> pickExtendedDisplay(const std::vector<DisplayInfo>& displays,
                                               int overrideIndex);

// Turns Windows Advanced Color (HDR) on or off for the display with the given
// GDI name (e.g. "\\.\DISPLAY5"). HDR must be ON for a 10-bit HDR10 capture, and
// must be OFF for a normal SDR capture — capturing an HDR framebuffer as SDR
// looks washed-out/over-bright, so the SDR path explicitly disables it.
// Uses the CCD API with the SDK's own struct definitions.
bool setAdvancedColor(const std::string& gdiName, bool enable) {
    UINT32 numPath = 0, numMode = 0;
    if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &numPath, &numMode) != ERROR_SUCCESS) {
        return false;
    }
    std::vector<DISPLAYCONFIG_PATH_INFO> paths(numPath);
    std::vector<DISPLAYCONFIG_MODE_INFO> modes(numMode);
    if (QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &numPath, paths.data(),
                           &numMode, modes.data(), nullptr) != ERROR_SUCCESS) {
        return false;
    }

    for (UINT32 i = 0; i < numPath; ++i) {
        DISPLAYCONFIG_SOURCE_DEVICE_NAME src{};
        src.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
        src.header.size = sizeof(src);
        src.header.adapterId = paths[i].sourceInfo.adapterId;
        src.header.id = paths[i].sourceInfo.id;
        if (DisplayConfigGetDeviceInfo(&src.header) != ERROR_SUCCESS) continue;

        std::string name;  // GDI device names are ASCII ("\\.\DISPLAYn")
        for (wchar_t wc : src.viewGdiDeviceName) {
            if (wc == 0) break;
            name += static_cast<char>(wc);
        }
        if (gdiName != name) continue;

        DISPLAYCONFIG_SET_ADVANCED_COLOR_STATE set{};
        set.header.type = DISPLAYCONFIG_DEVICE_INFO_SET_ADVANCED_COLOR_STATE;
        set.header.size = sizeof(set);
        set.header.adapterId = paths[i].targetInfo.adapterId;
        set.header.id = paths[i].targetInfo.id;
        set.enableAdvancedColor = enable ? TRUE : FALSE;
        return DisplayConfigSetDeviceInfo(&set.header) == ERROR_SUCCESS;
    }
    return false;
}

// Sets the VDD monitor to its native mode and positions it right of the primary.
void configureVirtualDisplay(const DisplayInfo& display) {
    DISPLAY_DEVICEA dd{};
    dd.cb = sizeof(dd);
    for (DWORD i = 0; EnumDisplayDevicesA(nullptr, i, &dd, 0); ++i) {
        if (display.name != dd.DeviceName) continue;
        if (!(dd.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP)) return;

        DEVMODEA mode{};
        mode.dmSize = sizeof(mode);
        if (!EnumDisplaySettingsA(dd.DeviceName, ENUM_CURRENT_SETTINGS, &mode)) return;
        mode.dmPosition.x = GetSystemMetrics(SM_CXSCREEN);  // right of primary
        mode.dmPosition.y = 0;
        mode.dmFields = DM_POSITION;
        ChangeDisplaySettingsExA(dd.DeviceName, &mode, nullptr,
                                 CDS_UPDATEREGISTRY | CDS_NORESET, nullptr);
        ChangeDisplaySettingsExA(nullptr, nullptr, nullptr, 0, nullptr);
        return;
    }
}

// Extends the desktop onto the VDD monitor (activating it) and returns it.
bool tryEnableVirtualDisplay(const std::string& /*exeDir*/) {
    std::cout << "Activating the virtual display...\n";
    const LONG rc = SetDisplayConfig(0, nullptr, 0, nullptr,
                                     SDC_APPLY | SDC_TOPOLOGY_EXTEND);
    if (rc != ERROR_SUCCESS) {
        std::cerr << "Could not extend onto the virtual display (code " << rc << ").\n"
                     "Is the Virtual Display Driver installed? (re-run the installer)\n";
        return false;
    }
    g_vddExtended.store(true);
    for (int waited = 0; waited < 10 && !g_stop.load(); ++waited) {
        Sleep(500);
        if (auto d = pickExtendedDisplay(enumerateDisplays(), -1)) {
            configureVirtualDisplay(*d);
            std::cout << "Virtual display active: " << d->width << "x" << d->height << "\n";
            return true;
        }
    }
    collapseToInternal();
    return false;
}

// ---------------------------------------------------------------------- adb

bool adbWaitForDevice(const std::string& adb) {
    bool announced = false;
    while (!g_stop.load()) {
        const CaptureResult r = runCapture(quote(adb) + " get-state");
        if (trim(r.output) == "device") {
            if (announced) std::cout << "Tablet connected.\n";
            return true;
        }
        if (!announced) {
            std::cout << "Waiting for tablet over USB... "
                         "(enable USB debugging; use a data-capable cable)\n";
            announced = true;
        }
        sleepInterruptible(2000);
    }
    return false;
}

// Minimum receiver versionCode this sender needs. v8 moved touch capture to the
// Activity's dispatchTouchEvent (the SurfaceView OnTouchListener never fired);
// v9 made the touch server re-accept a reconnecting host immediately.
constexpr int kRequiredAppVersion = 9;

void adbEnsureAppInstalled(const std::string& adb, const std::string& exeDir) {
    bool needInstall = true;
    const CaptureResult check =
        runCapture(quote(adb) + " shell pm path com.heysnap.extdisplay");
    if (check.output.find("package:") != std::string::npos) {
        needInstall = false;
        const CaptureResult dump = runCapture(
            quote(adb) + " shell dumpsys package com.heysnap.extdisplay");
        const size_t pos = dump.output.find("versionCode=");
        if (pos != std::string::npos) {
            const int installed = std::atoi(dump.output.c_str() + pos + 12);
            if (installed < kRequiredAppVersion) {
                std::cout << "Receiver app is outdated (v" << installed
                          << " < v" << kRequiredAppVersion << "); updating...\n";
                needInstall = true;
            }
        }
    }
    if (!needInstall) return;

    const std::string apk = exeDir + "\\ExtendedDisplayReceiver.apk";
    if (!fileExists(apk)) {
        std::cout << "Receiver app missing/outdated and " << apk << " not found.\n"
                  << "Install the app on the tablet manually, then reconnect.\n";
        return;
    }
    std::cout << "Installing receiver app on the tablet...\n";
    const CaptureResult install = runCapture(quote(adb) + " install -r " + quote(apk));
    if (install.output.find("Success") == std::string::npos) {
        std::cout << "APK install may have failed:\n" << install.output << "\n";
    }
}

bool adbSetup(const std::string& adb, const std::string& exeDir, int localPort) {
    if (!adbWaitForDevice(adb)) return false;
    adbEnsureAppInstalled(adb, exeDir);

    const std::string forwardCmd = quote(adb) + " forward tcp:" +
        std::to_string(localPort) + " tcp:" + std::to_string(kRemotePort);
    if (runCapture(forwardCmd).exitCode != 0) {
        std::cout << "adb forward failed; retrying on next attempt.\n";
        return false;
    }

    runCapture(quote(adb) +
               " shell am start -n com.heysnap.extdisplay/.MainActivity");
    std::cout << "Receiver app launched (make sure the tablet screen is on and unlocked).\n";
    Sleep(1500);
    return true;
}

// ------------------------------------------------------- encoder cache

// Remembers the last proven encoder config so subsequent launches skip the
// fallback cycling (probes can pass on configs that fail with real frames,
// e.g. NVENC on hybrid-GPU laptops whose display is driven by the iGPU).
std::string cachePath(const std::string& exeDir) {
    // Program Files isn't writable for non-admin users; prefer LOCALAPPDATA.
    char localAppData[MAX_PATH] = {};
    DWORD len = GetEnvironmentVariableA("LOCALAPPDATA", localAppData, MAX_PATH);
    if (len > 0 && len < MAX_PATH) {
        const std::string dir = std::string(localAppData) + "\\ExtendedDisplay";
        CreateDirectoryA(dir.c_str(), nullptr);
        return dir + "\\encoder.cache";
    }
    return exeDir + "\\encoder.cache";
}

std::optional<Attempt> loadCachedAttempt(const std::string& exeDir) {
    FILE* f = nullptr;
    if (fopen_s(&f, cachePath(exeDir).c_str(), "r") != 0 || !f) return std::nullopt;
    char encoder[32] = {};
    int zeroCopy = 0;
    const int fields = fscanf_s(f, "%31s %d", encoder, (unsigned)sizeof(encoder), &zeroCopy);
    fclose(f);
    if (fields != 2) return std::nullopt;
    return Attempt{encoder, zeroCopy != 0};
}

void saveCachedAttempt(const std::string& exeDir, const Attempt& attempt) {
    FILE* f = nullptr;
    if (fopen_s(&f, cachePath(exeDir).c_str(), "w") != 0 || !f) return;
    fprintf(f, "%s %d\n", attempt.encoder.c_str(), attempt.zeroCopy ? 1 : 0);
    fclose(f);
}

// ------------------------------------------------------------------ ffmpeg

bool probeEncoder(const std::string& ffmpeg, const std::string& encoder) {
    const std::string cmd = quote(ffmpeg) +
        " -v error -f lavfi -i color=c=black:s=640x360:r=30"
        " -frames:v 8 -pix_fmt yuv420p -c:v " + encoder + " -f null -";
    return runCapture(cmd).exitCode == 0;
}

std::vector<Attempt> buildLadder(const std::string& ffmpeg, const Options& options) {
    struct Candidate { const char* flag; const char* encoder; };
    // Order matters: the virtual display lives on its own adapter, so the
    // CPU-fed encoders (nvenc/qsv/mf, which upload from system memory) work
    // regardless of which GPU drives the display, while AMF can only bind to
    // its own GPU's D3D11 device and fails on the VDD. So try the
    // cross-adapter-safe encoders first and keep AMF as a late fallback.
    const Candidate all[] = {
        {"nvenc", options.hevc ? "hevc_nvenc" : "h264_nvenc"},
        {"qsv",   options.hevc ? "hevc_qsv"   : "h264_qsv"},
        // Media Foundation: GPU-agnostic HW path; works where AMF can't bind
        // across the VDD's own adapter. MF's HEVC needs the Store extension.
        {"mf",    options.hevc ? ""           : "h264_mf"},
        {"amf",   options.hevc ? "hevc_amf"   : "h264_amf"},
        {"x264",  options.hevc ? "libx265"    : "libx264"},
    };

    std::vector<Attempt> ladder;
    for (const Candidate& c : all) {
        if (c.encoder[0] == '\0') continue;  // codec not available via this backend
        if (!options.encoderOverride.empty() && options.encoderOverride != c.flag) {
            continue;
        }
        std::cout << "Probing " << c.encoder << "... ";
        if (!probeEncoder(ffmpeg, c.encoder)) {
            std::cout << "not available\n";
            continue;
        }
        std::cout << "ok\n";
        ladder.push_back({c.encoder, false});  // plain CPU-fed path first (always works)
        // The NVENC GPU zero-copy path is lower-latency but only works when the
        // display is on the NVIDIA adapter (never the VDD), so try it AFTER plain.
        if (std::string(c.flag) == "nvenc" && !options.noZeroCopy && !options.hevc) {
            ladder.push_back({c.encoder, true});
        }
    }
    return ladder;
}

std::string buildStreamCommand(const std::string& ffmpeg, const Options& options,
                               const DisplayInfo& display, const Attempt& attempt,
                               const std::string& host) {
    const bool scaled = options.width > 0 && options.height > 0;
    const std::string widthStr = std::to_string(scaled ? options.width : display.width);
    const std::string heightStr = std::to_string(scaled ? options.height : display.height);
    const std::string bitrate = std::to_string(options.bitrateKbps) + "k";

    // Encoder pixel format. nv12 is the native HW-encoder format (converting the
    // large BGRA surface to yuv420p OOMs swscale at high resolution); HDR uses
    // 10-bit p010le.
    const std::string encPixFmt = options.hdr ? "p010le" : "nv12";

    std::string graph =
        "ddagrab=output_idx=" + std::to_string(display.outputIndex) +
        ":framerate=" + std::to_string(options.fps);
    if (options.hdr) {
        graph += ":output_fmt=10bit";  // capture the HDR10 framebuffer
    }
    if (attempt.zeroCopy) {
        graph += ",hwmap=derive_device=cuda";
        graph += scaled ? (",scale_cuda=" + widthStr + ":" + heightStr + ":format=nv12")
                        : ",scale_cuda=format=nv12";
    } else if (options.hdr) {
        // ddagrab captures the VDD's HDR framebuffer as 10-bit sRGB/BT.709 (that's
        // where Windows composites the desktop). It must be COLOR-CONVERTED to
        // PQ/BT.2020 — merely re-tagging it as smpte2084 makes the tablet PQ-decode
        // sRGB values and blow the picture out ("extra bright"). zscale does the
        // real conversion; npl=100 maps SDR reference white to 100 nits.
        graph += ",hwdownload,format=x2bgr10le,"
                 "zscale=p=bt2020:t=smpte2084:m=bt2020nc:r=tv:npl=100,format=p010le";
        if (scaled) {
            graph += ",scale=" + widthStr + ":" + heightStr + ":flags=lanczos";
        }
    } else {
        graph += ",hwdownload,format=bgra";
        if (scaled) {
            graph += ",scale=" + widthStr + ":" + heightStr + ":flags=lanczos";
        }
    }

    const bool isHevc = options.hevc;
    std::ostringstream cmd;
    cmd << quote(ffmpeg)
        << " -hide_banner -loglevel warning"
        << " -init_hw_device d3d11va=dx:" << display.adapterIndex
        << " -filter_hw_device dx"
        << " -filter_complex " << quote(graph)
        << " -an -c:v " << attempt.encoder;

    // Encoder-family rate control / low-latency tuning.
    if (attempt.encoder.rfind("h264_nvenc", 0) == 0 ||
        attempt.encoder.rfind("hevc_nvenc", 0) == 0) {
        cmd << " -preset p1 -tune ull -rc cbr"
            << " -b:v " << bitrate << " -maxrate " << bitrate << " -bufsize " << bitrate
            << " -zerolatency 1 -delay 0 -bf 0 -g " << options.fps;
        if (options.hdr) cmd << " -profile:v main10";
    } else if (attempt.encoder.rfind("h264_qsv", 0) == 0 ||
               attempt.encoder.rfind("hevc_qsv", 0) == 0) {
        cmd << " -preset veryfast"
            << " -b:v " << bitrate << " -maxrate " << bitrate << " -bufsize " << bitrate
            << " -bf 0 -g " << options.fps << " -async_depth 1";
        if (options.hdr) cmd << " -profile:v main10";
    } else if (attempt.encoder.rfind("h264_amf", 0) == 0 ||
               attempt.encoder.rfind("hevc_amf", 0) == 0) {
        cmd << " -usage ultralowlatency -rc cbr"
            << " -b:v " << bitrate << " -maxrate " << bitrate << " -bufsize " << bitrate
            << " -bf 0 -g " << options.fps;
        if (options.hdr) cmd << " -profile_tier high -profile:v main10";
    } else if (attempt.encoder.rfind("h264_mf", 0) == 0) {
        // Media Foundation: CBR, force hardware, low-latency scenario.
        cmd << " -rate_control cbr -b:v " << bitrate << " -maxrate " << bitrate
            << " -hw_encoding true -scenario display_remoting -g " << options.fps;
    } else {  // libx264 / libx265
        cmd << " -preset ultrafast -tune zerolatency"
            << " -b:v " << bitrate << " -maxrate " << bitrate << " -bufsize " << bitrate
            << " -bf 0 -g " << options.fps;
        if (options.hdr) cmd << " -profile:v main10";
    }

    if (!attempt.zeroCopy) {
        cmd << " -pix_fmt " << encPixFmt;
    }

    // HDR10 signalling: BT.2020 primaries + PQ transfer so the tablet renders HDR.
    if (options.hdr) {
        cmd << " -colorspace bt2020nc -color_primaries bt2020 -color_trc smpte2084";
    }

    // UDP path: emit Annex-B to stdout; the sender packetizes it onto UDP.
    // TCP path: ffmpeg connects to the tablet's listener directly.
    if (options.udp) {
        cmd << " -f " << (isHevc ? "hevc" : "h264") << " pipe:1";
    } else {
        cmd << " -f " << (isHevc ? "hevc" : "h264")
            << " tcp://" << host << ":" << options.port;
    }
    return cmd.str();
}

// ------------------------------------------------------------- touch bridge

// Protocol v2: fixed 28-byte big-endian packets from the Android app (port
// 5001), one packet per pointer per event:
//   uint32 magic 'HXTP'    uint16 version=2
//   uint8  type  (0=down 1=move 2=up 3=cancel 4=hover-move 5=hover-exit)
//   uint8  tool  (0=finger 1=stylus 2=eraser)
//   uint8  pointerId       uint8  pointerCount
//   uint16 pressure (0..1024, 0 while hovering)
//   float  nx, ny (normalized to the letterboxed video area)
//   uint64 timestampUs
// Finger packets become real multi-touch frames via InjectTouchInput; stylus
// and eraser packets drive a synthetic pen device (pressure, hover, eraser,
// native press-and-hold right-click). When either API is unavailable the
// v1-style single-pointer SendInput mouse path is used as a fallback.
constexpr uint32_t kTouchMagic = 0x48585450;
constexpr int kTouchPacketSize = 28;
constexpr uint16_t kTouchProtocolVersion = 2;
constexpr UINT32 kMaxTouchContacts = 10;

enum : uint8_t {
    kTouchDown = 0,
    kTouchMove = 1,
    kTouchUp = 2,
    kTouchCancel = 3,
    kTouchHoverMove = 4,
    kTouchHoverExit = 5,
};

uint32_t readBe32(const unsigned char* p) {
    return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) |
           (uint32_t(p[2]) << 8) | uint32_t(p[3]);
}

uint16_t readBe16(const unsigned char* p) {
    return static_cast<uint16_t>((uint16_t(p[0]) << 8) | p[1]);
}

float readBeF32(const unsigned char* p) {
    const uint32_t bits = readBe32(p);
    float value = 0.0f;
    std::memcpy(&value, &bits, 4);
    return value;
}

struct TouchPacket {
    uint8_t type = 0;
    uint8_t tool = 0;        // 0=finger 1=stylus 2=eraser
    uint8_t pointerId = 0;   // Android pointer id, stable per contact
    uint8_t pointerCount = 0;
    uint16_t pressure = 0;   // 0..1024
    float nx = 0.0f;
    float ny = 0.0f;
};

// Assumes magic and version were already validated by the read loop.
TouchPacket parseTouchPacket(const unsigned char* p) {
    TouchPacket pkt;
    pkt.type = p[6];
    pkt.tool = p[7];
    pkt.pointerId = p[8];
    pkt.pointerCount = p[9];
    pkt.pressure = readBe16(p + 10);
    if (pkt.pressure > 1024) pkt.pressure = 1024;
    pkt.nx = readBeF32(p + 12);
    pkt.ny = readBeF32(p + 16);
    // bytes 20..27: timestampUs (unused on this side)
    return pkt;
}

// v1-style single-pointer mouse injection, kept as the fallback when real
// touch/pen injection is unavailable.
void injectMouseFallback(uint8_t type, POINT pt) {
    if (type == kTouchHoverExit) return;  // a mouse never leaves range

    const int vsLeft = GetSystemMetrics(SM_XVIRTUALSCREEN);
    const int vsTop = GetSystemMetrics(SM_YVIRTUALSCREEN);
    const int vsWidth = GetSystemMetrics(SM_CXVIRTUALSCREEN);
    const int vsHeight = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    if (vsWidth <= 1 || vsHeight <= 1) return;

    INPUT input{};
    input.type = INPUT_MOUSE;
    input.mi.dx = (pt.x - vsLeft) * 65535 / (vsWidth - 1);
    input.mi.dy = (pt.y - vsTop) * 65535 / (vsHeight - 1);
    input.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
    if (type == kTouchDown) input.mi.dwFlags |= MOUSEEVENTF_LEFTDOWN;
    if (type == kTouchUp || type == kTouchCancel) input.mi.dwFlags |= MOUSEEVENTF_LEFTUP;
    SendInput(1, &input, sizeof(INPUT));
}

// Owns the Windows injection state for the bridge thread: a table of real
// multi-touch contacts (InjectTouchInput) plus a synthetic pen device.
class TouchInjector {
public:
    void initialize() {
        touchReady_ =
            InitializeTouchInjection(kMaxTouchContacts, TOUCH_FEEDBACK_DEFAULT) != FALSE;
        if (!touchReady_) {
            std::cout << "Warning: touch injection unavailable (error " << GetLastError()
                      << "); finger input falls back to single-pointer mouse.\n";
        }
        pen_ = CreateSyntheticPointerDevice(PT_PEN, 1, POINTER_FEEDBACK_DEFAULT);
        if (!pen_) {
            std::cout << "Warning: synthetic pen device unavailable (needs Windows 10 "
                         "1809+); stylus input falls back to single-pointer mouse.\n";
        }
    }

    void shutdown() {
        releaseAllContacts();
        if (pen_) {
            DestroySyntheticPointerDevice(pen_);
            pen_ = nullptr;
        }
    }

    void handle(const TouchPacket& pkt, const DisplayInfo& display) {
        POINT pt{};
        pt.x = display.left + static_cast<LONG>(pkt.nx * (display.width - 1));
        pt.y = display.top + static_cast<LONG>(pkt.ny * (display.height - 1));
        if (pkt.tool == 0) {
            handleFinger(pkt, pt);
        } else {
            handlePen(pkt, pt);
        }
    }

    // Lifts any contacts still down (e.g. the tablet disconnected mid-gesture).
    void releaseAllContacts() {
        if (touchReady_) {
            POINTER_TOUCH_INFO frame[kMaxTouchContacts];
            UINT32 count = 0;
            for (UINT32 i = 0; i < kMaxTouchContacts; ++i) {
                if (!contacts_[i].active) continue;
                frame[count] = makeTouchInfo(i, POINTER_FLAG_UP);
                ++count;
            }
            if (count > 0) {
                InjectTouchInput(count, frame);
            }
        }
        for (Contact& c : contacts_) c.active = false;
    }

private:
    struct Contact {
        bool active = false;
        uint8_t pointerId = 0;  // Android pointer id this slot is bound to
        POINT pt{};
        uint16_t pressure = 0;
    };

    POINTER_TOUCH_INFO makeTouchInfo(UINT32 slot, POINTER_FLAGS flags) const {
        POINTER_TOUCH_INFO ti{};
        ti.pointerInfo.pointerType = PT_TOUCH;
        ti.pointerInfo.pointerId = slot;
        ti.pointerInfo.pointerFlags = flags;
        ti.pointerInfo.ptPixelLocation = contacts_[slot].pt;
        ti.touchMask = TOUCH_MASK_NONE;
        return ti;
    }

    void handleFinger(const TouchPacket& pkt, POINT pt) {
        if (!touchReady_) {
            injectMouseFallback(pkt.type, pt);
            return;
        }
        if (pkt.type == kTouchHoverMove || pkt.type == kTouchHoverExit) {
            return;  // finger hover has no touch-injection equivalent
        }

        // Bind the Android pointer id to a slot (the Windows pointer id).
        int slot = -1;
        for (UINT32 i = 0; i < kMaxTouchContacts; ++i) {
            if (contacts_[i].active && contacts_[i].pointerId == pkt.pointerId) {
                slot = static_cast<int>(i);
                break;
            }
        }
        if (slot < 0) {
            if (pkt.type != kTouchDown) return;  // move/up for an unknown contact
            for (UINT32 i = 0; i < kMaxTouchContacts; ++i) {
                if (!contacts_[i].active) {
                    slot = static_cast<int>(i);
                    break;
                }
            }
            if (slot < 0) return;  // contact table full
            contacts_[slot].active = true;
            contacts_[slot].pointerId = pkt.pointerId;
        }
        contacts_[slot].pt = pt;
        contacts_[slot].pressure = pkt.pressure;

        POINTER_FLAGS transitionFlags = 0;
        switch (pkt.type) {
            case kTouchDown:
                transitionFlags =
                    POINTER_FLAG_DOWN | POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT;
                break;
            case kTouchMove:
                transitionFlags =
                    POINTER_FLAG_UPDATE | POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT;
                break;
            case kTouchUp:
                transitionFlags = POINTER_FLAG_UP;
                break;
            case kTouchCancel:
                transitionFlags = POINTER_FLAG_UP | POINTER_FLAG_CANCELED;
                break;
            default:
                return;
        }

        // Every injected frame must list ALL active contacts, including the
        // one whose final UP this packet carries.
        POINTER_TOUCH_INFO frame[kMaxTouchContacts];
        UINT32 count = 0;
        for (UINT32 i = 0; i < kMaxTouchContacts; ++i) {
            if (!contacts_[i].active) continue;
            const POINTER_FLAGS flags =
                (static_cast<int>(i) == slot)
                    ? transitionFlags
                    : (POINTER_FLAG_UPDATE | POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT);
            frame[count] = makeTouchInfo(i, flags);
            ++count;
        }

        const BOOL ok = InjectTouchInput(count, frame);
        if (pkt.type == kTouchUp || pkt.type == kTouchCancel) {
            contacts_[slot].active = false;
        }
        if (!ok) {
            // Windows invalidates the whole frame state on a failed injection.
            for (Contact& c : contacts_) c.active = false;
        }
    }

    void handlePen(const TouchPacket& pkt, POINT pt) {
        if (!pen_) {
            injectMouseFallback(pkt.type, pt);
            return;
        }

        POINTER_TYPE_INFO ti{};
        ti.type = PT_PEN;
        POINTER_PEN_INFO& penInfo = ti.penInfo;
        penInfo.pointerInfo.pointerType = PT_PEN;
        penInfo.pointerInfo.ptPixelLocation = pt;
        if (pkt.tool == 2) {
            penInfo.penFlags |= PEN_FLAG_INVERTED | PEN_FLAG_ERASER;
        }

        switch (pkt.type) {
            case kTouchDown:
                penInfo.pointerInfo.pointerFlags =
                    POINTER_FLAG_DOWN | POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT;
                penInfo.pressure = pkt.pressure;
                penInfo.penMask = PEN_MASK_PRESSURE;
                break;
            case kTouchMove:
                penInfo.pointerInfo.pointerFlags =
                    POINTER_FLAG_UPDATE | POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT;
                penInfo.pressure = pkt.pressure;
                penInfo.penMask = PEN_MASK_PRESSURE;
                break;
            case kTouchUp:
            case kTouchCancel:
                penInfo.pointerInfo.pointerFlags = POINTER_FLAG_UP;
                break;
            case kTouchHoverMove:
                penInfo.pointerInfo.pointerFlags =
                    POINTER_FLAG_UPDATE | POINTER_FLAG_INRANGE;
                break;
            case kTouchHoverExit:
                penInfo.pointerInfo.pointerFlags = POINTER_FLAG_UPDATE;  // leaves range
                break;
            default:
                return;
        }
        InjectSyntheticPointerInput(pen_, &ti, 1);
    }

    bool touchReady_ = false;
    HSYNTHETICPOINTERDEVICE pen_ = nullptr;
    Contact contacts_[kMaxTouchContacts]{};
};

bool recvFull(SOCKET sock, unsigned char* buffer, int length) {
    int got = 0;
    while (got < length) {
        const int n = recv(sock, reinterpret_cast<char*>(buffer) + got, length - got, 0);
        if (n == SOCKET_ERROR) {
            // A recv timeout (set so we can poll g_stop) is not an error: keep
            // waiting unless we're shutting down. Any other error is fatal.
            if (WSAGetLastError() == WSAETIMEDOUT && !g_stop.load()) continue;
            return false;
        }
        if (n == 0) return false;  // peer closed
        got += n;
    }
    return true;
}

void runTouchBridge(const std::string adb, const std::string host, int localPort,
                    bool adbMode, const DisplayInfo display) {
    WSADATA wsa{};
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return;

    TouchInjector injector;
    injector.initialize();

    const std::string connectHost = adbMode ? "127.0.0.1" : host;
    const int connectPort = adbMode ? localPort : kRemoteTouchPort;

    while (!g_stop.load()) {
        if (adbMode) {
            runCapture(quote(adb) + " forward tcp:" + std::to_string(localPort) +
                       " tcp:" + std::to_string(kRemoteTouchPort));
        }

        SOCKET sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (sock == INVALID_SOCKET) break;
        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_port = htons(static_cast<u_short>(connectPort));
        inet_pton(AF_INET, connectHost.c_str(), &addr.sin_addr);

        if (connect(sock, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
            closesocket(sock);
            sleepInterruptible(2000);
            continue;
        }
        BOOL noDelay = TRUE;
        setsockopt(sock, IPPROTO_TCP, TCP_NODELAY,
                   reinterpret_cast<char*>(&noDelay), sizeof(noDelay));
        // Bound blocking recv so the thread notices g_stop and exits promptly
        // instead of hanging in recv on shutdown.
        DWORD rcvTimeout = 500;
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO,
                   reinterpret_cast<char*>(&rcvTimeout), sizeof(rcvTimeout));

        unsigned char packet[kTouchPacketSize];
        bool connected = true;
        while (connected && !g_stop.load()) {
            if (!recvFull(sock, packet, kTouchPacketSize)) break;
            // Resync: a mid-stream connect can land between packet boundaries;
            // slide one byte at a time until the magic lines up.
            while (readBe32(packet) != kTouchMagic) {
                std::memmove(packet, packet + 1, kTouchPacketSize - 1);
                if (!recvFull(sock, packet + kTouchPacketSize - 1, 1)) {
                    connected = false;
                    break;
                }
            }
            if (!connected) break;
            if (readBe16(packet + 4) != kTouchProtocolVersion) continue;  // drop
            injector.handle(parseTouchPacket(packet), display);
        }
        closesocket(sock);
        injector.releaseAllContacts();  // don't leave fingers stuck down
        sleepInterruptible(1000);
    }
    injector.shutdown();
    WSACleanup();
}

// ----------------------------------------------------------------- discovery

// Subnet-directed broadcast addresses for every local IPv4 interface, plus the
// global 255.255.255.255 as a last resort. Limited broadcast alone is unreliable
// on multi-NIC hosts (it can exit the wrong adapter, e.g. a VM host-only NIC),
// so we target each interface's own subnet broadcast (ip | ~mask).
std::vector<sockaddr_in> broadcastTargets() {
    std::vector<sockaddr_in> targets;
    auto add = [&](ULONG netOrderAddr) {
        sockaddr_in s{};
        s.sin_family = AF_INET;
        s.sin_port = htons(static_cast<u_short>(kDiscoveryPort));
        s.sin_addr.s_addr = netOrderAddr;
        targets.push_back(s);
    };

    ULONG size = 0;
    GetAdaptersInfo(nullptr, &size);
    std::vector<BYTE> buf(size);
    auto* info = reinterpret_cast<IP_ADAPTER_INFO*>(buf.data());
    if (size > 0 && GetAdaptersInfo(info, &size) == NO_ERROR) {
        for (auto* a = info; a; a = a->Next) {
            for (auto* ip = &a->IpAddressList; ip; ip = ip->Next) {
                in_addr addr{}, mask{};
                if (inet_pton(AF_INET, ip->IpAddress.String, &addr) != 1) continue;
                if (inet_pton(AF_INET, ip->IpMask.String, &mask) != 1) continue;
                if (addr.s_addr == 0 || mask.s_addr == 0) continue;
                add((addr.s_addr & mask.s_addr) | ~mask.s_addr);  // subnet broadcast
            }
        }
    }
    add(INADDR_BROADCAST);
    return targets;
}

// Broadcasts a UDP discovery query on the LAN and returns the first tablet that
// answers (its IP). The Android app's DiscoveryResponder replies with
// "EXTDISP!v1|<name>|<port>". No mDNS dependency; works on a flat LAN.
std::optional<std::string> discoverTablet(int timeoutMs) {
    WSADATA wsa{};
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return std::nullopt;

    SOCKET sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (sock == INVALID_SOCKET) { WSACleanup(); return std::nullopt; }

    BOOL broadcast = TRUE;
    setsockopt(sock, SOL_SOCKET, SO_BROADCAST,
               reinterpret_cast<char*>(&broadcast), sizeof(broadcast));
    DWORD recvTimeout = 800;
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO,
               reinterpret_cast<char*>(&recvTimeout), sizeof(recvTimeout));

    const std::vector<sockaddr_in> targets = broadcastTargets();
    const char query[] = "EXTDISP?v1";
    std::optional<std::string> found;
    const ULONGLONG deadline = GetTickCount64() + timeoutMs;

    std::cout << "Searching for the tablet on the network "
                 "(make sure the Extended Display app is open)...\n";
    while (!g_stop.load() && GetTickCount64() < deadline) {
        for (const sockaddr_in& dest : targets) {
            sendto(sock, query, sizeof(query) - 1, 0,
                   reinterpret_cast<const sockaddr*>(&dest), sizeof(dest));
        }

        char buf[256];
        sockaddr_in from{};
        int fromLen = sizeof(from);
        const int n = recvfrom(sock, buf, sizeof(buf) - 1, 0,
                               reinterpret_cast<sockaddr*>(&from), &fromLen);
        if (n > 0) {
            buf[n] = '\0';
            if (std::string(buf).rfind("EXTDISP!v1|", 0) == 0) {
                char ip[INET_ADDRSTRLEN] = {};
                inet_ntop(AF_INET, &from.sin_addr, ip, sizeof(ip));
                const char* namePart = buf + 11;  // after "EXTDISP!v1|"
                std::string name(namePart);
                const size_t bar = name.find('|');
                if (bar != std::string::npos) name = name.substr(0, bar);
                std::cout << "Found tablet: " << name << " at " << ip << "\n";
                found = ip;
                break;
            }
        }
    }

    closesocket(sock);
    WSACleanup();
    return found;
}

// --------------------------------------------------------------------- CLI

void printUsage() {
    std::cout <<
        "ExtendedDisplaySender — plug-and-play extended display over USB\n\n"
        "Just run it with no arguments:\n"
        "  - finds the extended display (enables the virtual display driver if needed)\n"
        "  - waits for the tablet over USB, installs and launches the receiver app\n"
        "  - picks the best encoder for this machine and streams; reconnects automatically\n\n"
        "Options:\n"
        "  --port N          Local forward port (default 5000)\n"
        "  --fps N           Frame rate (default 60)\n"
        "  --bitrate KBPS    Encoder bitrate in kbps (default 25000)\n"
        "  --display N       Capture a specific display (see --list-displays)\n"
        "  --list-displays   Print the display table and exit\n"
        "  --width N         Scale output width (default: native)\n"
        "  --height N        Scale output height (default: native)\n"
        "  --encoder NAME    Pin encoder: nvenc | qsv | amf | mf | x264\n"
        "  --no-zerocopy     Disable the GPU-only NVENC path\n"
        "  --hevc            Use H.265/HEVC (sharper at high resolution)\n"
        "  --hdr             HDR10 output (10-bit BT.2020 PQ; implies --hevc)\n"
        "  --no-touch        Disable tablet touch -> mouse injection\n"
        "  --wifi            Stream over Wi-Fi: auto-discover the tablet on the LAN\n"
        "  --udp             Low-latency UDP video over Wi-Fi (needs --wifi or --host)\n"
        "  --host IP         Advanced: stream straight to IP (WiFi), skip adb\n"
        "  --help            Show this help\n";
}

int readInt(const char* value, const char* name) {
    try {
        return std::stoi(value);
    } catch (...) {
        throw std::runtime_error(std::string("Invalid integer for ") + name);
    }
}

Options parseArgs(int argc, char** argv) {
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
        } else if (arg == "--port") {
            options.port = readInt(requireValue("--port"), "--port");
        } else if (arg == "--fps") {
            options.fps = readInt(requireValue("--fps"), "--fps");
        } else if (arg == "--bitrate") {
            options.bitrateKbps = readInt(requireValue("--bitrate"), "--bitrate");
        } else if (arg == "--display") {
            options.displayOverride = readInt(requireValue("--display"), "--display");
        } else if (arg == "--list-displays") {
            options.listDisplays = true;
        } else if (arg == "--width") {
            options.width = readInt(requireValue("--width"), "--width");
        } else if (arg == "--height") {
            options.height = readInt(requireValue("--height"), "--height");
        } else if (arg == "--encoder") {
            options.encoderOverride = requireValue("--encoder");
        } else if (arg == "--no-zerocopy") {
            options.noZeroCopy = true;
        } else if (arg == "--hevc") {
            options.hevc = true;
        } else if (arg == "--hdr") {
            options.hdr = true;
            options.hevc = true;       // HDR10 requires a Main10 (HEVC) stream
            options.noZeroCopy = true; // HDR uses the 10-bit CPU capture path
        } else if (arg == "--no-touch") {
            options.noTouch = true;
        } else if (arg == "--wifi") {
            options.wifi = true;
        } else if (arg == "--udp") {
            options.udp = true;
        } else if (arg == "--host") {
            options.host = requireValue("--host");
        } else {
            throw std::runtime_error("Unknown argument: " + arg);
        }
    }

    if (options.port <= 0 || options.port > 65535) {
        throw std::runtime_error("--port must be between 1 and 65535");
    }
    if (options.fps <= 0 || options.fps > 240) {
        throw std::runtime_error("--fps must be between 1 and 240");
    }
    if (options.bitrateKbps < 500 || options.bitrateKbps > 200000) {
        throw std::runtime_error("--bitrate must be between 500 and 200000");
    }
    if ((options.width > 0) != (options.height > 0)) {
        throw std::runtime_error("--width and --height must be given together");
    }
    if (!options.encoderOverride.empty() &&
        options.encoderOverride != "nvenc" && options.encoderOverride != "qsv" &&
        options.encoderOverride != "amf" && options.encoderOverride != "mf" &&
        options.encoderOverride != "x264") {
        throw std::runtime_error("--encoder must be one of: nvenc qsv amf mf x264");
    }
    if (options.udp && !options.wifi && options.host.empty()) {
        throw std::runtime_error("--udp needs a network target: add --wifi or --host <ip>");
    }
    return options;
}

// ------------------------------------------------------------- udp streaming

// Runs one ffmpeg attempt that writes Annex-B to a pipe; the bytes are split
// into NAL units and each NAL is fragmented onto UDP. Returns the ffmpeg
// uptime in ms (so the ladder's fast-fail logic works exactly as for TCP).
ULONGLONG runUdpAttempt(const std::string& cmd, const std::string& host, int udpPort) {
    WSADATA wsa{};
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return 0;
    SOCKET sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (sock == INVALID_SOCKET) { WSACleanup(); return 0; }
    sockaddr_in dest{};
    dest.sin_family = AF_INET;
    dest.sin_port = htons(static_cast<u_short>(udpPort));
    inet_pton(AF_INET, host.c_str(), &dest.sin_addr);

    SECURITY_ATTRIBUTES sa{};
    sa.nLength = sizeof(sa);
    sa.bInheritHandle = TRUE;
    HANDLE readPipe = nullptr, writePipe = nullptr;
    if (!CreatePipe(&readPipe, &writePipe, &sa, 1 << 20)) {
        closesocket(sock);
        WSACleanup();
        return 0;
    }
    SetHandleInformation(readPipe, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOA si{};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdOutput = writePipe;
    si.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);

    PROCESS_INFORMATION pi{};
    std::string mutableCmd = cmd;
    if (!CreateProcessA(nullptr, mutableCmd.data(), nullptr, nullptr, TRUE,
                        CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi)) {
        CloseHandle(readPipe);
        CloseHandle(writePipe);
        closesocket(sock);
        WSACleanup();
        return 0;
    }
    CloseHandle(writePipe);
    g_child.store(pi.hProcess);
    const ULONGLONG started = GetTickCount64();

    uint32_t nalSeq = 0;
    auto sendNal = [&](const unsigned char* nal, size_t len) {
        if (len == 0) return;
        const uint16_t fragCount = static_cast<uint16_t>(
            (len + kUdpPayloadMax - 1) / kUdpPayloadMax);
        unsigned char pkt[kUdpHeaderSize + kUdpPayloadMax];
        for (uint16_t f = 0; f < fragCount; ++f) {
            const size_t off = static_cast<size_t>(f) * kUdpPayloadMax;
            const size_t chunk = (len - off < static_cast<size_t>(kUdpPayloadMax))
                                     ? (len - off) : static_cast<size_t>(kUdpPayloadMax);
            auto b = [](uint32_t v) { return static_cast<unsigned char>(v & 0xFF); };
            pkt[0] = b(kUdpMagic >> 24); pkt[1] = b(kUdpMagic >> 16);
            pkt[2] = b(kUdpMagic >> 8);  pkt[3] = b(kUdpMagic);
            pkt[4] = b(nalSeq >> 24); pkt[5] = b(nalSeq >> 16);
            pkt[6] = b(nalSeq >> 8);  pkt[7] = b(nalSeq);
            pkt[8] = b(f >> 8);          pkt[9] = b(f);
            pkt[10] = b(fragCount >> 8); pkt[11] = b(fragCount);
            memcpy(pkt + kUdpHeaderSize, nal + off, chunk);
            sendto(sock, reinterpret_cast<char*>(pkt),
                   static_cast<int>(kUdpHeaderSize + chunk), 0,
                   reinterpret_cast<sockaddr*>(&dest), sizeof(dest));
        }
        ++nalSeq;
    };

    // Streaming Annex-B splitter: emit a NAL once the next start code arrives.
    auto startCodeLen = [](const std::vector<unsigned char>& b, size_t i) -> int {
        if (i + 3 <= b.size() && b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1) return 3;
        if (i + 4 <= b.size() && b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 0 &&
            b[i + 3] == 1) return 4;
        return 0;
    };
    auto nextStart = [&](const std::vector<unsigned char>& b, size_t from) -> size_t {
        for (size_t i = from; i + 3 <= b.size(); ++i) {
            if (b[i] == 0 && b[i + 1] == 0 &&
                (b[i + 2] == 1 || (b[i + 2] == 0 && i + 3 < b.size() && b[i + 3] == 1))) {
                return i;
            }
        }
        return std::string::npos;
    };

    std::vector<unsigned char> buf;
    buf.reserve(1 << 20);
    unsigned char chunk[65536];
    DWORD got = 0;
    size_t base = std::string::npos;  // index of the current NAL's start code
    while (!g_stop.load() &&
           ReadFile(readPipe, chunk, sizeof(chunk), &got, nullptr) && got > 0) {
        buf.insert(buf.end(), chunk, chunk + got);
        if (base == std::string::npos) base = nextStart(buf, 0);
        if (base == std::string::npos) continue;  // no start code seen yet
        // Emit every complete NAL, advancing a cursor (no per-NAL erase).
        size_t next = nextStart(buf, base + startCodeLen(buf, base));
        while (next != std::string::npos) {
            sendNal(buf.data() + base, next - base);
            base = next;
            next = nextStart(buf, base + startCodeLen(buf, base));
        }
        // Compact once per read: drop everything before the trailing partial NAL.
        if (base > 0) {
            buf.erase(buf.begin(), buf.begin() + base);
            base = 0;
        }
    }

    WaitForSingleObject(pi.hProcess, g_stop.load() ? 0 : INFINITE);
    if (g_stop.load()) TerminateProcess(pi.hProcess, 1);
    ULONGLONG uptime = GetTickCount64() - started;
    // Don't let a non-zero ffmpeg exit count as a "proven" config.
    DWORD exitCode = 0;
    if (GetExitCodeProcess(pi.hProcess, &exitCode) && exitCode != 0 && exitCode != STILL_ACTIVE) {
        uptime = 0;
    }
    g_child.exchange(nullptr);  // claim before close so the ctrl handler can't race
    CloseHandle(readPipe);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    closesocket(sock);
    WSACleanup();
    return uptime;
}

// Quick TCP reachability probe to the tablet's listener (works for USB via the
// adb-forwarded 127.0.0.1 and for Wi-Fi direct). Distinguishes "tablet gone"
// from "encoder failed" so a disconnect doesn't get blamed on the encoder.
bool tabletReachable(const std::string& host, int port, int timeoutMs) {
    WSADATA wsa{};
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return false;
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) { WSACleanup(); return false; }
    u_long nonBlocking = 1;
    ioctlsocket(s, FIONBIO, &nonBlocking);
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(static_cast<u_short>(port));
    inet_pton(AF_INET, host.c_str(), &addr.sin_addr);
    connect(s, reinterpret_cast<sockaddr*>(&addr), sizeof(addr));
    fd_set writeable;
    FD_ZERO(&writeable);
    FD_SET(s, &writeable);
    timeval tv{ timeoutMs / 1000, (timeoutMs % 1000) * 1000 };
    const int r = select(0, nullptr, &writeable, nullptr, &tv);
    bool ok = false;
    if (r > 0) {
        int err = 0;
        int len = sizeof(err);
        getsockopt(s, SOL_SOCKET, SO_ERROR, reinterpret_cast<char*>(&err), &len);
        ok = (err == 0);
    }
    closesocket(s);
    WSACleanup();
    return ok;
}

// -------------------------------------------------------------- supervision

int runSupervised(const Options& options, const std::string& ffmpeg,
                  const std::string& adb, const std::string& exeDir,
                  const DisplayInfo& display) {
    const bool adbMode = options.host.empty();
    const std::string host = adbMode ? "127.0.0.1" : options.host;

    std::vector<Attempt> ladder = buildLadder(ffmpeg, options);
    // A previously proven config jumps the queue (probe success != real success).
    if (options.encoderOverride.empty()) {
        if (const auto cached = loadCachedAttempt(exeDir)) {
            for (size_t i = 0; i < ladder.size(); ++i) {
                if (ladder[i].encoder == cached->encoder &&
                    ladder[i].zeroCopy == cached->zeroCopy) {
                    if (i > 0) {
                        std::cout << "Using previously proven encoder: "
                                  << cached->encoder
                                  << (cached->zeroCopy ? " (GPU zero-copy)" : "") << "\n";
                        const Attempt front = ladder[i];
                        ladder.erase(ladder.begin() + i);
                        ladder.insert(ladder.begin(), front);
                    }
                    break;
                }
            }
        }
    }
    if (ladder.empty()) {
        std::cerr << "No usable H.264 encoder found. Your FFmpeg build may be "
                     "broken — install the full GPL build (ffmpeg.org or gyan.dev).\n";
        return 3;
    }

    size_t idx = 0;
    bool proven = false;
    int fastFails = 0;

    while (!g_stop.load()) {
        if (idx >= ladder.size()) {
            std::cerr << "All encoder configurations failed.\n"
                         "Hints: update GPU drivers; ensure your FFmpeg build has "
                         "ddagrab (Windows 10 1903+, full GPL build); try --encoder x264.\n";
            return 4;
        }
        const Attempt& attempt = ladder[idx];

        if (adbMode && !adbSetup(adb, exeDir, options.port)) {
            if (g_stop.load()) break;
            sleepInterruptible(1000);
            continue;
        }

        const std::string cmd = buildStreamCommand(ffmpeg, options, display, attempt, host);
        std::cout << "\nStreaming " << display.name
                  << " with " << attempt.encoder
                  << (attempt.zeroCopy ? " (GPU zero-copy)" : "")
                  << (options.udp ? " over UDP" : "")
                  << " -> " << host << ":" << options.port << "\n";

        ULONGLONG uptime = 0;
        if (options.udp) {
            uptime = runUdpAttempt(cmd, host, options.port);
        } else {
            PROCESS_INFORMATION pi{};
            if (!spawnProcess(cmd, pi)) {
                std::cerr << "Failed to launch ffmpeg.\n";
                return 5;
            }
            g_child.store(pi.hProcess);
            const ULONGLONG started = GetTickCount64();
            WaitForSingleObject(pi.hProcess, INFINITE);
            uptime = GetTickCount64() - started;
            DWORD exitCode = 0;
            if (GetExitCodeProcess(pi.hProcess, &exitCode) && exitCode != 0) {
                uptime = 0;  // a failed ffmpeg must not be cached as "proven"
            }
            g_child.exchange(nullptr);  // claim before close (ctrl-handler race)
            CloseHandle(pi.hThread);
            CloseHandle(pi.hProcess);
        }

        // Persist the proven config even when we're exiting via Ctrl+C, so the
        // next launch skips the fallback cycling.
        if (uptime >= kProvenUptimeMs && !proven) {
            saveCachedAttempt(exeDir, attempt);
            proven = true;
        }

        if (g_stop.load()) break;

        if (uptime >= kProvenUptimeMs) {
            fastFails = 0;
            std::cout << "Stream ended (tablet unplugged or app closed). Reconnecting...\n";
            continue;
        }

        // A fast-fail with an unreachable tablet is a disconnect (app closed,
        // screen locked, Wi-Fi blip), NOT an encoder problem — so wait for the
        // tablet to return and retry the SAME config instead of walking the
        // ladder and giving up. (USB also re-waits via adbSetup at the top.)
        if (!tabletReachable(host, options.port, 1000)) {
            std::cout << "Tablet not reachable; waiting to reconnect...\n";
            fastFails = 0;
            sleepInterruptible(1500);
            continue;
        }

        ++fastFails;
        if (!proven && fastFails >= 2) {
            std::cout << attempt.encoder << (attempt.zeroCopy ? " zero-copy" : "")
                      << " failed to start; falling back...\n";
            ++idx;
            fastFails = 0;
            continue;
        }
        if (proven && fastFails >= 5) {
            std::cerr << "Stream keeps failing immediately; giving up. "
                         "Check the tablet connection and try again.\n";
            return 6;
        }
        sleepInterruptible(1500);
    }
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    // Without DPI awareness, DesktopCoordinates come back scaled (e.g. a
    // 2560x1600 panel at 150% reports 1536x960) and we'd encode at the wrong size.
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    try {
        Options options = parseArgs(argc, argv);  // host may be filled by --wifi discovery
        SetConsoleCtrlHandler(consoleCtrlHandler, TRUE);
        SetUnhandledExceptionFilter(crashHandler);

        const std::string exeDir = exeDirectory();

        if (options.listDisplays) {
            printDisplays(enumerateDisplays());
            return 0;
        }

        // Tools.
        std::string ffmpeg = exeDir + "\\ffmpeg.exe";
        if (!fileExists(ffmpeg)) ffmpeg = searchPathFor("ffmpeg.exe");
        if (ffmpeg.empty()) {
            std::cerr << "ffmpeg.exe not found (looked beside this exe and on PATH).\n";
            return 1;
        }
        std::string adb = exeDir + "\\platform-tools\\adb.exe";
        if (!fileExists(adb)) adb = exeDir + "\\adb.exe";
        if (!fileExists(adb)) adb = searchPathFor("adb.exe");
        if (options.host.empty() && !options.wifi && adb.empty()) {
            std::cerr << "adb.exe not found (looked beside this exe and on PATH). "
                         "Use --wifi or --host <tablet-ip> for Wi-Fi instead.\n";
            return 1;
        }

        // Wi-Fi mode: discover the tablet's IP on the LAN, then stream straight
        // to it over TCP (same path as an explicit --host, just auto-found).
        if (options.wifi && options.host.empty()) {
            while (!g_stop.load()) {
                if (auto ip = discoverTablet(15000)) {
                    options.host = *ip;
                    break;
                }
                std::cout << "No tablet found yet; retrying. (Same Wi-Fi network? "
                             "App open?)\n";
            }
            if (g_stop.load()) return 0;
        }

        // Auto mode (no --wifi, no --host): prefer USB if a tablet is on adb,
        // otherwise fall back to Wi-Fi discovery — so one shortcut works either
        // way. Leaving host empty selects the USB/adb path downstream.
        if (options.host.empty() && !options.wifi) {
            bool announced = false;
            while (!g_stop.load()) {
                if (!adb.empty() &&
                    trim(runCapture(quote(adb) + " get-state").output) == "device") {
                    std::cout << "Tablet found over USB.\n";
                    break;  // USB path
                }
                if (auto ip = discoverTablet(3000)) {
                    options.host = *ip;  // Wi-Fi path
                    break;
                }
                if (!announced) {
                    std::cout << "Waiting for a tablet — plug in USB, or open the app "
                                 "on the same Wi-Fi...\n";
                    announced = true;
                }
            }
            if (g_stop.load()) return 0;
        }

        // Display.
        auto displays = enumerateDisplays();
        auto selected = pickExtendedDisplay(displays, options.displayOverride);
        if (!selected && options.displayOverride < 0) {
            if (tryEnableVirtualDisplay(exeDir)) {
                displays = enumerateDisplays();
                selected = pickExtendedDisplay(displays, -1);
            }
        }
        if (!selected) {
            std::cerr << "No extended display available.\n"
                         "Either re-run the installer and enable the virtual display "
                         "driver option, plug in an HDMI dummy, or see "
                         "docs/extended-display.md.\nDisplays found:\n";
            printDisplays(displays);
            return 2;
        }

        std::cout << "Extended display: " << selected->name << " "
                  << selected->width << "x" << selected->height
                  << " (adapter " << selected->adapterIndex
                  << ", output " << selected->outputIndex << ")\n";

        if (options.hdr) {
            if (setAdvancedColor(selected->name, true)) {
                std::cout << "HDR enabled on the virtual display.\n";
                Sleep(1500);  // let the framebuffer switch to 10-bit before capture
            } else {
                std::cout << "Could not enable HDR automatically. Turn on "
                             "Settings > Display > Use HDR for the tablet display, "
                             "or run without --hdr.\n";
            }
        } else {
            // SDR path: make sure Windows HDR is OFF on the virtual display, else
            // the SDR capture of an HDR framebuffer looks washed-out / over-bright.
            if (setAdvancedColor(selected->name, false)) {
                std::cout << "Virtual display set to SDR (correct desktop colors).\n";
                Sleep(800);  // let the framebuffer switch back to 8-bit before capture
            }
        }

        if (!options.noTouch) {
            std::thread(runTouchBridge, adb, options.host, options.port + 1,
                        options.host.empty(), *selected)
                .detach();
            std::cout << "Touch input bridge active (tablet touches control Windows).\n";
        }

        const int exitCode = runSupervised(options, ffmpeg, adb, exeDir, *selected);
        collapseToInternal();
        return exitCode;
    } catch (const std::exception& ex) {
        collapseToInternal();
        std::cerr << "Error: " << ex.what() << "\n\n";
        printUsage();
        return 1;
    }
}
