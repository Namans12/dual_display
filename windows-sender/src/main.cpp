// ExtendedDisplaySender — plug-and-play extended-display host for Windows.
//
// Flow (no arguments needed):
//   1. Find ffmpeg.exe and adb.exe (beside this exe, then PATH).
//   2. Enumerate displays across ALL DXGI adapters; pick the virtual display
//      (VirtualDrivers VDD), attaching it to the desktop if needed. Real
//      monitors are used only with --display N.
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
#include <bcrypt.h>
#include <mmdeviceapi.h>   // WASAPI: IMMDeviceEnumerator (desktop-audio loopback)
#include <audioclient.h>   // WASAPI: IAudioClient / IAudioCaptureClient
#include <audioclientactivationparams.h> // process loopback (Windows 10 2004+)
#include <endpointvolume.h> // IAudioEndpointVolume (optional "mute PC while streaming")
#include <mmreg.h>         // WAVE_FORMAT_* tags for the mix format

#include <array>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <mutex>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <future>
#include <thread>
#include <vector>

namespace {

constexpr int kRemotePort = 5000;       // video listener inside the Android app
constexpr int kRemoteTouchPort = 5001;  // touch uplink listener inside the app
constexpr int kDiscoveryPort = 5002;    // UDP discovery port on the tablet
constexpr int kRemoteAudioPort = 5003;  // desktop-audio listener inside the app
constexpr uint32_t kAudioMagic = 0x45584155;  // 'EXAU' (audio format header)
constexpr uint32_t kEncVideoMagic = 0x45585645;  // 'EXVE' (encrypted-video stream marker)
constexpr ULONGLONG kProvenUptimeMs = 5000;

// UDP video framing (low-latency Wi-Fi path). Each NAL unit is split into
// datagrams with a 12-byte big-endian header: magic, nalSeq, fragIndex,
// fragCount. The receiver reassembles by nalSeq and drops incomplete NALs.
constexpr uint32_t kUdpMagic = 0x45585544;  // 'EXUD'
constexpr int kUdpPayloadMax = 1400;        // keep total datagram under ~1500 MTU
constexpr int kUdpHeaderSize = 12;

std::atomic<bool> g_stop{false};
std::atomic<HANDLE> g_child{nullptr};

// ------------------------------------------------------------- crypto (BCrypt)
// PBKDF2-HMAC-SHA256 key derivation + AES-256-GCM, via Windows BCrypt (no third-
// party crypto). Wire frame per message: [12B nonce][ciphertext][16B tag].
// See SECURITY.md for the pairing/threat-model design.
constexpr int kGcmNonceLen = 12;
constexpr int kGcmTagLen = 16;
constexpr int kKeyLen = 32;

// Derive a 32-byte key from the pairing code (same salt/iterations as the app).
bool deriveKey(const std::string& code, std::array<uint8_t, kKeyLen>& outKey) {
    static const char kSalt[] = "ExtDisplay/v1";
    BCRYPT_ALG_HANDLE hPrf = nullptr;
    if (BCryptOpenAlgorithmProvider(&hPrf, BCRYPT_SHA256_ALGORITHM, nullptr,
                                    BCRYPT_ALG_HANDLE_HMAC_FLAG) != 0)
        return false;
    NTSTATUS st = BCryptDeriveKeyPBKDF2(
        hPrf, reinterpret_cast<PUCHAR>(const_cast<char*>(code.data())),
        static_cast<ULONG>(code.size()),
        reinterpret_cast<PUCHAR>(const_cast<char*>(kSalt)), sizeof(kSalt) - 1,
        200000, outKey.data(), kKeyLen, 0);
    BCryptCloseAlgorithmProvider(hPrf, 0);
    return st == 0;
}

// Reusable AES-256-GCM context (one per channel/direction; the key handle is kept
// open so per-message encrypt/decrypt is cheap enough for the video path).
class AesGcm {
public:
    bool init(const std::array<uint8_t, kKeyLen>& key) {
        if (BCryptOpenAlgorithmProvider(&hAlg_, BCRYPT_AES_ALGORITHM, nullptr, 0) != 0) return false;
        if (BCryptSetProperty(hAlg_, BCRYPT_CHAINING_MODE,
                reinterpret_cast<PUCHAR>(const_cast<wchar_t*>(BCRYPT_CHAIN_MODE_GCM)),
                sizeof(BCRYPT_CHAIN_MODE_GCM), 0) != 0) return false;
        return BCryptGenerateSymmetricKey(hAlg_, &hKey_, nullptr, 0,
                reinterpret_cast<PUCHAR>(const_cast<uint8_t*>(key.data())), kKeyLen, 0) == 0;
    }
    ~AesGcm() {
        if (hKey_) BCryptDestroyKey(hKey_);
        if (hAlg_) BCryptCloseAlgorithmProvider(hAlg_, 0);
    }
    // out = [nonce][ciphertext][tag]
    bool encrypt(const uint8_t* pt, int ptLen, const uint8_t nonce[kGcmNonceLen],
                 std::vector<uint8_t>& out) {
        out.resize(kGcmNonceLen + ptLen + kGcmTagLen);
        std::memcpy(out.data(), nonce, kGcmNonceLen);
        BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO info;
        BCRYPT_INIT_AUTH_MODE_INFO(info);
        info.pbNonce = const_cast<PUCHAR>(nonce); info.cbNonce = kGcmNonceLen;
        info.pbTag = out.data() + kGcmNonceLen + ptLen; info.cbTag = kGcmTagLen;
        ULONG res = 0;
        return BCryptEncrypt(hKey_, const_cast<PUCHAR>(pt), ptLen, &info, nullptr, 0,
                             out.data() + kGcmNonceLen, ptLen, &res, 0) == 0;
    }
    // in = [nonce][ciphertext][tag]; fails (returns false) on auth mismatch.
    bool decrypt(const uint8_t* in, int inLen, std::vector<uint8_t>& out) {
        if (inLen < kGcmNonceLen + kGcmTagLen) return false;
        int ctLen = inLen - kGcmNonceLen - kGcmTagLen;
        out.resize(ctLen);
        BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO info;
        BCRYPT_INIT_AUTH_MODE_INFO(info);
        info.pbNonce = const_cast<PUCHAR>(in); info.cbNonce = kGcmNonceLen;
        info.pbTag = const_cast<PUCHAR>(in) + kGcmNonceLen + ctLen; info.cbTag = kGcmTagLen;
        ULONG res = 0;
        return BCryptDecrypt(hKey_, const_cast<PUCHAR>(in) + kGcmNonceLen, ctLen, &info,
                             nullptr, 0, out.data(), ctLen, &res, 0) == 0;
    }
private:
    BCRYPT_ALG_HANDLE hAlg_ = nullptr;
    BCRYPT_KEY_HANDLE hKey_ = nullptr;
};

// Round-trips the crypto so a regression is caught at build/smoke-test time.
int cryptoSelfTest() {
    std::array<uint8_t, kKeyLen> k1{}, k2{}, kWrong{};
    if (!deriveKey("TESTCODE", k1) || !deriveKey("TESTCODE", k2) || !deriveKey("WRONGXXX", kWrong)) {
        std::cout << "crypto self-test: KDF FAILED\n"; return 1;
    }
    if (k1 != k2) { std::cout << "crypto self-test: KDF not deterministic\n"; return 1; }
    AesGcm enc, dec, decBad;
    if (!enc.init(k1) || !dec.init(k2) || !decBad.init(kWrong)) {
        std::cout << "crypto self-test: AES init FAILED\n"; return 1;
    }
    const char* msg = "hello extended display touch+video payload 12345";
    uint8_t nonce[kGcmNonceLen] = {1,2,3,4,5,6,7,8,9,10,11,12};
    std::vector<uint8_t> ct, pt, ptBad;
    if (!enc.encrypt(reinterpret_cast<const uint8_t*>(msg), (int)std::strlen(msg), nonce, ct)) {
        std::cout << "crypto self-test: encrypt FAILED\n"; return 1;
    }
    if (!dec.decrypt(ct.data(), (int)ct.size(), pt) ||
        std::string(pt.begin(), pt.end()) != msg) {
        std::cout << "crypto self-test: round-trip FAILED\n"; return 1;
    }
    if (decBad.decrypt(ct.data(), (int)ct.size(), ptBad)) {
        std::cout << "crypto self-test: wrong key DECRYPTED (must be rejected)\n"; return 1;
    }
    std::cout << "crypto self-test: OK (KDF deterministic, GCM round-trip, wrong key rejected)\n";
    return 0;
}

// Set when a pairing code is supplied (env EXTDISPLAY_KEY): channels are encrypted.
std::optional<std::array<uint8_t, kKeyLen>> g_pairKey;
// Encrypted touch frame = [12B nonce][28B ciphertext][16B tag].
constexpr int kTouchEncSize = kGcmNonceLen + 28 + kGcmTagLen;

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
    bool audio = false;          // stream desktop audio (WASAPI loopback) to the tablet
    bool muteLocal = false;      // mute the PC's own speakers while streaming audio
    int audioDelayMs = 40;       // tablet audio buffer/latency for A/V sync (bigger = later)
    bool listDisplays = false;
    bool cleanup = false;        // switch the virtual screen off, un-mute, exit
    bool audioTest = false;      // dev: process loopback with the speakers muted, print peak
    bool screenTest = false;     // dev: screen on, list, wait 3 s, screen off, list
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
    bool isVirtual = false;  // the bundled virtual display (VirtualDrivers VDD)
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

bool virtualScreenOff(const char* reason, bool announce = true, bool force = false);  // below
void restoreLocalMuteIfNeeded();  // below

// Common stop: what Ctrl+C, closing the console and the launcher's stop event all do.
void requestStop(const char* reason) {
    g_stop.store(true);
    // Atomically claim the handle so we never race main's CloseHandle.
    HANDLE child = g_child.exchange(nullptr);
    if (child) {
        TerminateProcess(child, 1);
    }
    virtualScreenOff(reason);
}

BOOL WINAPI consoleCtrlHandler(DWORD type) {
    if (type == CTRL_C_EVENT || type == CTRL_BREAK_EVENT || type == CTRL_CLOSE_EVENT ||
        type == CTRL_LOGOFF_EVENT || type == CTRL_SHUTDOWN_EVENT) {
        requestStop("stopped");
        // On close/logoff the process dies when this handler returns, so the
        // speakers must be restored here, not in main().
        if (type != CTRL_C_EVENT && type != CTRL_BREAK_EVENT) restoreLocalMuteIfNeeded();
        return TRUE;
    }
    return FALSE;
}

// Last-resort: if the process faults, still switch the virtual screen off so it
// isn't left extended onto a non-existent tablet.
LONG WINAPI crashHandler(EXCEPTION_POINTERS*) {
    virtualScreenOff("sender crashed");
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

// ffmpeg must not outlive the sender. The launcher's Stop (and Task Manager)
// kill the sender outright, which skips every cleanup path, so each ffmpeg goes
// into a job object that Windows kills when the sender's last handle to it
// closes, i.e. when the sender exits for any reason. Only ffmpeg is placed in
// it: adb starts a shared server that must keep running.
void killWithSender(HANDLE child) {
    static HANDLE job = [] {
        HANDLE j = CreateJobObjectA(nullptr, nullptr);
        if (j) {
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION info{};
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            SetInformationJobObject(j, JobObjectExtendedLimitInformation, &info, sizeof(info));
        }
        return j;
    }();
    if (job && child) AssignProcessToJobObject(job, child);
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

// True if the GDI device (e.g. "\\.\DISPLAY4") is the bundled virtual display:
// the VirtualDrivers IddCx adapter reports "Virtual Display Driver" and its
// monitor hardware id is MTT1337. Real monitors (HDMI, USB-C, the laptop panel)
// are never this, so they are never picked or reconfigured automatically.
bool isVirtualDisplayDevice(const std::string& gdiName) {
    DISPLAY_DEVICEA dd{};
    dd.cb = sizeof(dd);
    for (DWORD i = 0; EnumDisplayDevicesA(nullptr, i, &dd, 0); ++i) {
        if (gdiName != dd.DeviceName) continue;
        if (std::string(dd.DeviceString).find("Virtual Display") != std::string::npos) return true;
        DISPLAY_DEVICEA mon{};
        mon.cb = sizeof(mon);
        return EnumDisplayDevicesA(dd.DeviceName, 0, &mon, 0) &&
               std::string(mon.DeviceID).find("MTT1337") != std::string::npos;
    }
    return false;
}

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
                info.isVirtual = isVirtualDisplayDevice(info.name);
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
        if (d.isVirtual) std::cout << "virtual ";
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
    // Only the virtual display is picked automatically. Before, this took the first
    // non-primary display, so with a real second monitor attached (HDMI, USB-C) the
    // sender streamed that monitor and changed its resolution and HDR setting.
    for (const DisplayInfo& d : displays) {
        if (d.attached && d.isVirtual) {
            return d;
        }
    }
    return std::nullopt;
}

// ------------------------------------------------------------ virtual screen
//
// The launcher loads the VirtualDrivers VDD (IddCx) when its app opens and unloads
// it when the app closes. While the driver is loaded but its screen is off it costs
// nothing. THIS sender owns the screen: it switches the virtual display's own CCD
// path on when a tablet is found and off again when the stream ends or the tablet
// has been gone for a few seconds. Every other active path is passed back to
// SetDisplayConfig unchanged, so real monitors (laptop panel, HDMI) are never
// moved, re-moded or disabled. Nothing is persisted: no registry update, no saved
// display database entry, no topology presets. No admin rights are needed.
constexpr UINT32 kIdxInvalid = 0xffffffffu;  // DISPLAYCONFIG_PATH_MODE_IDX_INVALID
constexpr ULONGLONG kTabletGoneMs = 5000;

using CcdPath = DISPLAYCONFIG_PATH_INFO;
using CcdMode = DISPLAYCONFIG_MODE_INFO;

struct ScreenMode {
    UINT32 w = 0, h = 0, hz = 0;  // hz 0 = leave the refresh rate to Windows
};

enum class ScreenResult { Switched, Unchanged, NoDriver, Failed };
enum class PrepResult { Ok, NoDriver, Failed };

bool g_ccdVerbose = false;  // --screen-test: print each SetDisplayConfig return code
std::mutex g_screenMutex;                 // serialises every CCD change
std::atomic<bool> g_screenOwned{false};   // this process switched the screen on

// The rectangle touch coordinates map onto. Updated each time the screen is
// switched on or re-moded; the touch bridge reads it for every packet.
std::mutex g_touchRectMutex;
DisplayInfo g_touchDisplay;

void setTouchDisplay(const DisplayInfo& d) {
    std::lock_guard<std::mutex> lock(g_touchRectMutex);
    g_touchDisplay = d;
}

DisplayInfo getTouchDisplay() {
    std::lock_guard<std::mutex> lock(g_touchRectMutex);
    return g_touchDisplay;
}

bool queryConfig(UINT32 flags, std::vector<CcdPath>& paths, std::vector<CcdMode>& modes) {
    for (int attempt = 0; attempt < 4; ++attempt) {
        UINT32 np = 0, nm = 0;
        if (GetDisplayConfigBufferSizes(flags, &np, &nm) != ERROR_SUCCESS) return false;
        paths.assign(np, CcdPath{});
        modes.assign(nm, CcdMode{});
        const LONG rc = QueryDisplayConfig(flags, &np, paths.data(), &nm, modes.data(), nullptr);
        if (rc == ERROR_INSUFFICIENT_BUFFER) continue;  // config changed between the calls
        if (rc != ERROR_SUCCESS) return false;
        paths.resize(np);
        modes.resize(nm);
        return true;
    }
    return false;
}

// The VirtualDrivers VDD monitor reports hardware id "MTT1337" in its device path
// and "VDD" in its friendly name; no real monitor does.
bool isVddPath(const CcdPath& p) {
    DISPLAYCONFIG_TARGET_DEVICE_NAME tgt{};
    tgt.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
    tgt.header.size = sizeof(tgt);
    tgt.header.adapterId = p.targetInfo.adapterId;
    tgt.header.id = p.targetInfo.id;
    if (DisplayConfigGetDeviceInfo(&tgt.header) != ERROR_SUCCESS) return false;
    const std::wstring devPath = tgt.monitorDevicePath;
    const std::wstring friendly = tgt.monitorFriendlyDeviceName;
    return devPath.find(L"MTT1337") != std::wstring::npos ||
           friendly.find(L"VDD") != std::wstring::npos;
}

DISPLAYCONFIG_SOURCE_MODE* sourceModeOf(const CcdPath& p, std::vector<CcdMode>& modes) {
    const UINT32 idx = p.sourceInfo.modeInfoIdx;
    if (idx == kIdxInvalid || idx >= modes.size() ||
        modes[idx].infoType != DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE) {
        return nullptr;
    }
    return &modes[idx].sourceMode;
}

UINT32 refreshOf(const CcdPath& p, const std::vector<CcdMode>& modes) {
    UINT32 num = p.targetInfo.refreshRate.Numerator, den = p.targetInfo.refreshRate.Denominator;
    const UINT32 idx = p.targetInfo.modeInfoIdx;
    if (idx != kIdxInvalid && idx < modes.size() &&
        modes[idx].infoType == DISPLAYCONFIG_MODE_INFO_TYPE_TARGET) {
        const auto& v = modes[idx].targetMode.targetVideoSignalInfo.vSyncFreq;
        if (v.Denominator != 0) { num = v.Numerator; den = v.Denominator; }
    }
    return den == 0 ? 0 : static_cast<UINT32>((static_cast<double>(num) / den) + 0.5);
}

bool rectsIntersect(const RECT& a, const RECT& b) {
    return a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom;
}

bool virtualScreenActive() {
    std::lock_guard<std::mutex> lock(g_screenMutex);
    std::vector<CcdPath> paths;
    std::vector<CcdMode> modes;
    if (!queryConfig(QDC_ONLY_ACTIVE_PATHS, paths, modes)) return false;
    for (const CcdPath& p : paths) if (isVddPath(p)) return true;
    return false;
}

void fillTargetSignal(DISPLAYCONFIG_TARGET_MODE& t, const ScreenMode& want) {
    auto& si = t.targetVideoSignalInfo;
    si.pixelRate = static_cast<UINT64>(want.w) * want.h * want.hz;
    si.hSyncFreq = {want.h * want.hz, 1};
    si.vSyncFreq = {want.hz, 1};
    si.activeSize = {want.w, want.h};
    si.totalSize = {want.w, want.h};
    si.videoStandard = 0;
    si.scanLineOrdering = DISPLAYCONFIG_SCANLINE_ORDERING_PROGRESSIVE;
}

// Brings the virtual screen to the wanted state in ONE SetDisplayConfig call:
//  - off: switches its path on with the wanted size/refresh and a position to the
//    right of the rightmost active display, top aligned with the primary (which is
//    always at 0,0);
//  - on but at another mode, or overlapping a display: changes just that.
// "Unchanged" means it was already on at the full wanted mode (width, height and
// refresh compared) without overlap, and nothing was sent.
ScreenResult applyVirtualScreen(const ScreenMode& want, std::string& detail) {
    std::lock_guard<std::mutex> lock(g_screenMutex);
    std::vector<CcdPath> active;
    std::vector<CcdMode> modes;
    if (!queryConfig(QDC_ONLY_ACTIVE_PATHS, active, modes)) {
        detail = "QueryDisplayConfig failed";
        return ScreenResult::Failed;
    }

    int vdd = -1;
    for (size_t i = 0; i < active.size(); ++i) {
        if (isVddPath(active[i])) { vdd = static_cast<int>(i); break; }
    }

    LONG right = 0;
    std::vector<RECT> others;
    for (size_t i = 0; i < active.size(); ++i) {
        if (static_cast<int>(i) == vdd) continue;
        const DISPLAYCONFIG_SOURCE_MODE* sm = sourceModeOf(active[i], modes);
        if (!sm) continue;
        RECT r{sm->position.x, sm->position.y,
               sm->position.x + static_cast<LONG>(sm->width),
               sm->position.y + static_cast<LONG>(sm->height)};
        others.push_back(r);
        if (r.right > right) right = r.right;
    }
    const POINTL place{right, 0};
    constexpr DWORD kFlags = SDC_APPLY | SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_ALLOW_CHANGES;

    if (vdd >= 0) {
        DISPLAYCONFIG_SOURCE_MODE* sm = sourceModeOf(active[vdd], modes);
        if (!sm) {
            detail = "virtual screen has no source mode";
            return ScreenResult::Failed;
        }
        const UINT32 curHz = refreshOf(active[vdd], modes);
        const bool modeOk = sm->width == want.w && sm->height == want.h &&
                            (want.hz == 0 || curHz == want.hz);
        const RECT me{sm->position.x, sm->position.y,
                      sm->position.x + static_cast<LONG>(sm->width),
                      sm->position.y + static_cast<LONG>(sm->height)};
        bool overlap = false;
        for (const RECT& o : others) overlap = overlap || rectsIntersect(me, o);
        if (modeOk && !overlap) return ScreenResult::Unchanged;

        sm->width = want.w;
        sm->height = want.h;
        if (overlap) sm->position = place;
        const UINT32 tIdx = active[vdd].targetInfo.modeInfoIdx;
        if (want.hz && tIdx != kIdxInvalid && tIdx < modes.size() &&
            modes[tIdx].infoType == DISPLAYCONFIG_MODE_INFO_TYPE_TARGET) {
            fillTargetSignal(modes[tIdx].targetMode, want);  // same call, same entries
            active[vdd].targetInfo.refreshRate = {want.hz, 1};
        } else {
            active[vdd].targetInfo.modeInfoIdx = kIdxInvalid;  // Windows rebuilds the timing
        }
        const LONG rc = SetDisplayConfig(static_cast<UINT32>(active.size()), active.data(),
                                         static_cast<UINT32>(modes.size()), modes.data(), kFlags);
        if (g_ccdVerbose) std::cout << "  SetDisplayConfig (re-mode) rc=" << rc << "\n";
        if (rc != ERROR_SUCCESS) {
            detail = "SetDisplayConfig (re-mode) failed, code " + std::to_string(rc);
            return ScreenResult::Failed;
        }
        return ScreenResult::Switched;
    }

    // Off: find the VDD's inactive path whose source is not used by an active path.
    std::vector<CcdPath> all;
    std::vector<CcdMode> allModes;
    if (!queryConfig(QDC_ALL_PATHS, all, allModes)) {
        detail = "QueryDisplayConfig (all paths) failed";
        return ScreenResult::Failed;
    }
    bool sawVdd = false;
    for (const CcdPath& p : all) {
        if (!isVddPath(p)) continue;
        sawVdd = true;
        if (!p.targetInfo.targetAvailable) continue;
        bool used = false;
        for (const CcdPath& a : active) {
            used = used || (a.sourceInfo.adapterId.LowPart == p.sourceInfo.adapterId.LowPart &&
                            a.sourceInfo.adapterId.HighPart == p.sourceInfo.adapterId.HighPart &&
                            a.sourceInfo.id == p.sourceInfo.id);
        }
        if (used) continue;

        CcdMode sm{};
        sm.infoType = DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE;
        sm.id = p.sourceInfo.id;
        sm.adapterId = p.sourceInfo.adapterId;
        sm.sourceMode.width = want.w;
        sm.sourceMode.height = want.h;
        sm.sourceMode.pixelFormat = DISPLAYCONFIG_PIXELFORMAT_32BPP;
        sm.sourceMode.position = place;
        modes.push_back(sm);

        CcdPath np = p;
        np.flags |= DISPLAYCONFIG_PATH_ACTIVE;
        np.sourceInfo.modeInfoIdx = static_cast<UINT32>(modes.size() - 1);
        np.targetInfo.modeInfoIdx = kIdxInvalid;
        if (want.hz) {
            // The refresh rate can only be chosen through a target mode: setting just
            // the path's refreshRate is rejected (error 87). One call still.
            CcdMode tm{};
            tm.infoType = DISPLAYCONFIG_MODE_INFO_TYPE_TARGET;
            tm.id = p.targetInfo.id;
            tm.adapterId = p.targetInfo.adapterId;
            fillTargetSignal(tm.targetMode, want);
            modes.push_back(tm);
            np.targetInfo.modeInfoIdx = static_cast<UINT32>(modes.size() - 1);
            np.targetInfo.refreshRate = {want.hz, 1};
        }
        active.push_back(np);

        const LONG rc = SetDisplayConfig(static_cast<UINT32>(active.size()), active.data(),
                                         static_cast<UINT32>(modes.size()), modes.data(), kFlags);
        if (g_ccdVerbose) std::cout << "  SetDisplayConfig (switch on) rc=" << rc << "\n";
        if (rc != ERROR_SUCCESS) {
            detail = "SetDisplayConfig (switch on) failed, code " + std::to_string(rc);
            return ScreenResult::Failed;
        }
        return ScreenResult::Switched;
    }
    detail = sawVdd ? "the virtual screen has no free display path" : "driver not loaded";
    return sawVdd ? ScreenResult::Failed : ScreenResult::NoDriver;
}

// Switches the virtual screen off by clearing ONLY its path's active flag. Safe from
// any thread and from the Ctrl+C handler. Unless force is set, it does nothing when
// this process never switched the screen on. Returns true if it switched it off.
bool virtualScreenOff(const char* reason, bool announce, bool force) {
    if (!force && !g_screenOwned.load()) return false;
    std::lock_guard<std::mutex> lock(g_screenMutex);
    std::vector<CcdPath> paths;
    std::vector<CcdMode> modes;
    bool switched = false;
    if (queryConfig(QDC_ONLY_ACTIVE_PATHS, paths, modes)) {
        bool found = false;
        for (CcdPath& p : paths) {
            if (isVddPath(p)) { p.flags &= ~DISPLAYCONFIG_PATH_ACTIVE; found = true; }
        }
        if (found) {
            // Saved: Windows keeps a layout per set of connected screens and re-applies
            // it on any display change. Old builds saved the virtual screen as ON, so
            // unplugging HDMI while idle switched it back on (measured). Saving the off
            // state records the other screens exactly as they are now, unchanged.
            const LONG rc = SetDisplayConfig(static_cast<UINT32>(paths.size()), paths.data(),
                                             static_cast<UINT32>(modes.size()), modes.data(),
                                             SDC_APPLY | SDC_USE_SUPPLIED_DISPLAY_CONFIG |
                                                 SDC_ALLOW_CHANGES | SDC_SAVE_TO_DATABASE);
            switched = rc == ERROR_SUCCESS;
            if (g_ccdVerbose) std::cout << "  SetDisplayConfig (switch off) rc=" << rc << "\n";
            if (!switched) std::cerr << "Could not switch the virtual screen off (code " << rc << ").\n";
        }
    }
    g_screenOwned.store(false);
    if (switched && announce) std::cout << "Virtual screen off (" << reason << ")" << std::endl;
    return switched;
}

// Supervisor bookkeeping: called whenever the tablet is seen present or absent while
// no stream runs. After it has been absent for kTabletGoneMs the screen goes off; it
// comes back when the loop finds the tablet again (ensureVirtualScreen).
void tabletPresence(bool present) {
    static ULONGLONG absentSince = 0;  // supervisor (main) thread only
    if (present) { absentSince = 0; return; }
    const ULONGLONG now = GetTickCount64();
    if (absentSince == 0) { absentSince = now; return; }
    if (now - absentSince >= kTabletGoneMs && g_screenOwned.load()) {
        virtualScreenOff("tablet gone for 5 s");
    }
}

// Prints every attached display's rectangle (physical pixels), for --screen-test.
void printDisplayRects() {
    for (const DisplayInfo& d : enumerateDisplays()) {
        if (!d.attached) continue;
        std::cout << "  rect " << d.name << " left=" << d.left << " top=" << d.top
                  << " right=" << d.left + d.width << " bottom=" << d.top + d.height
                  << (d.isVirtual ? " (virtual)" : "");
        DEVMODEA dm{};
        dm.dmSize = sizeof(dm);
        if (EnumDisplaySettingsA(d.name.c_str(), ENUM_CURRENT_SETTINGS, &dm)) {
            std::cout << "  EnumDisplaySettings: " << dm.dmPelsWidth << "x" << dm.dmPelsHeight
                      << " @" << dm.dmDisplayFrequency << " Hz pos=(" << dm.dmPosition.x << ","
                      << dm.dmPosition.y << ")";
        }
        std::cout << "\n";
    }
}

// Turns Windows Advanced Color (HDR) on or off for the display with the given
// GDI name (e.g. "\\.\DISPLAY5"). HDR must be ON for a 10-bit HDR10 capture, and
// must be OFF for a normal SDR capture — capturing an HDR framebuffer as SDR
// looks washed-out/over-bright, so the SDR path explicitly disables it.
// Uses the CCD API with the SDK's own struct definitions. *changed reports whether
// a switch was actually sent (nothing is sent when the state already matches).
bool setAdvancedColor(const std::string& gdiName, bool enable, bool* changed = nullptr) {
    if (changed) *changed = false;
    std::vector<CcdPath> paths;
    std::vector<CcdMode> modes;
    if (!queryConfig(QDC_ONLY_ACTIVE_PATHS, paths, modes)) return false;

    for (size_t i = 0; i < paths.size(); ++i) {
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

        // Already in the requested state: don't send it again. Every HDR switch
        // makes Windows rebuild the desktop, which can blank all screens briefly.
        DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO cur{};
        cur.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_ADVANCED_COLOR_INFO;
        cur.header.size = sizeof(cur);
        cur.header.adapterId = paths[i].targetInfo.adapterId;
        cur.header.id = paths[i].targetInfo.id;
        if (DisplayConfigGetDeviceInfo(&cur.header) == ERROR_SUCCESS &&
            (cur.advancedColorEnabled != 0) == enable) {
            return true;
        }

        DISPLAYCONFIG_SET_ADVANCED_COLOR_STATE set{};
        set.header.type = DISPLAYCONFIG_DEVICE_INFO_SET_ADVANCED_COLOR_STATE;
        set.header.size = sizeof(set);
        set.header.adapterId = paths[i].targetInfo.adapterId;
        set.header.id = paths[i].targetInfo.id;
        set.enableAdvancedColor = enable ? TRUE : FALSE;
        const bool ok = DisplayConfigSetDeviceInfo(&set.header) == ERROR_SUCCESS;
        if (ok && changed) *changed = true;
        return ok;
    }
    return false;
}

// Presets, as in July: Balanced and Best use the tablet's native 2960x1848 at
// 120 Hz (capturing 60 fps from a 120 Hz screen avoids capture/refresh phase
// judder). 120 fps at native is past the capture+encode throughput (frames back
// up, the cursor drags), so Smooth drops to a lighter 16:10 mode and the tablet
// upscales: 1920x1200 held ffmpeg fps=120 and felt smoother on-device than 2560x1600.
ScreenMode wantedMode(const Options& options) {
    if (options.fps >= 120) return {1920, 1200, 120};
    return {2960, 1848, 120};
}

// Switches the virtual screen on at the wanted mode and placement, waits until DXGI
// lists it, sets HDR/SDR on it if its state differs, and publishes its rectangle to
// the touch bridge. Fills `out` with the display as DXGI now sees it.
PrepResult prepareVirtualDisplay(const Options& options, DisplayInfo& out) {
    const ScreenMode want = wantedMode(options);
    const auto t0 = std::chrono::steady_clock::now();

    std::string detail;
    ScreenResult res = applyVirtualScreen(want, detail);
    if (res == ScreenResult::NoDriver) return PrepResult::NoDriver;
    if (res == ScreenResult::Failed) {
        std::cerr << "Virtual screen: " << detail << ".\n";
        return PrepResult::Failed;
    }
    g_screenOwned.store(true);

    auto waitForDisplay = [&]() -> std::optional<DisplayInfo> {
        for (int i = 0; i < 150 && !g_stop.load(); ++i) {  // up to ~3 s
            if (auto d = pickExtendedDisplay(enumerateDisplays(), -1)) return d;
            Sleep(20);
        }
        return std::nullopt;
    };
    std::optional<DisplayInfo> found = waitForDisplay();
    if (!found) {
        std::cerr << "Virtual screen: it did not appear on the desktop.\n";
        return PrepResult::Failed;
    }
    // Windows may have picked another mode; correct it once (a second change).
    if (static_cast<UINT32>(found->width) != want.w || static_cast<UINT32>(found->height) != want.h) {
        if (applyVirtualScreen(want, detail) == ScreenResult::Switched) {
            if (auto d = waitForDisplay()) found = d;
        }
    }

    // HDR/SDR only on this display, and only if its state differs.
    bool colorChanged = false;
    if (options.hdr) {
        if (setAdvancedColor(found->name, true, &colorChanged)) {
            if (colorChanged) std::cout << "HDR enabled on the virtual display.\n";
            if (colorChanged) Sleep(1500);  // let the framebuffer switch to 10-bit before capture
        } else {
            std::cout << "Could not enable HDR automatically. Turn on "
                         "Settings > Display > Use HDR for the tablet display, "
                         "or run without --hdr.\n";
        }
    } else if (setAdvancedColor(found->name, false, &colorChanged) && colorChanged) {
        std::cout << "Virtual display set to SDR (correct desktop colors).\n";
        Sleep(800);  // let the framebuffer switch back to 8-bit before capture
    }

    // Verify the placement: it must not overlap any other display.
    for (const DisplayInfo& d : enumerateDisplays()) {
        if (!d.attached || d.name == found->name) continue;
        const RECT a{found->left, found->top, found->left + found->width, found->top + found->height};
        const RECT b{d.left, d.top, d.left + d.width, d.top + d.height};
        if (rectsIntersect(a, b)) {
            std::cerr << "Warning: the virtual screen overlaps " << d.name << ".\n";
        }
    }

    out = *found;
    setTouchDisplay(out);
    const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - t0).count();
    std::cout << "Virtual screen on: " << found->width << "x" << found->height << " at ("
              << found->left << "," << found->top << "), " << ms << " ms" << std::endl;
    return PrepResult::Ok;
}

// Called by the supervisor before each stream start: if the screen was switched off
// (tablet gone) switch it back on and refresh `display`. No-op for --display N.
bool ensureVirtualScreen(const Options& options, DisplayInfo& display) {
    if (options.displayOverride >= 0 || virtualScreenActive()) return true;
    return prepareVirtualDisplay(options, display) == PrepResult::Ok;
}

// ---------------------------------------------------------------------- adb

bool adbWaitForDevice(const std::string& adb) {
    bool announced = false;
    while (!g_stop.load()) {
        const CaptureResult r = runCapture(quote(adb) + " get-state");
        if (trim(r.output) == "device") {
            tabletPresence(true);
            if (announced) std::cout << "Tablet connected.\n";
            return true;
        }
        tabletPresence(false);  // screen goes off after ~5 s without the tablet
        if (!announced) {
            std::cout << "Waiting for tablet over USB... "
                         "(enable USB debugging; use a data-capable cable)\n";
            announced = true;
        }
        sleepInterruptible(1000);
    }
    return false;
}

// Minimum receiver versionCode this sender needs. v8 moved touch capture to the
// Activity's dispatchTouchEvent (the SurfaceView OnTouchListener never fired);
// v9 made the touch server re-accept a reconnecting host immediately; v10
// presents each frame at once, re-detects the codec per connection (H.264 <->
// HEVC without restarting the app), blanks the screen when the stream ends and
// asks for the pairing code only when an encrypted stream needs it.
constexpr int kRequiredAppVersion = 10;

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
        if (install.output.find("INSTALL_FAILED_UPDATE_INCOMPATIBLE") != std::string::npos) {
            // Different signing key (docs/signing.md). Never uninstall automatically:
            // that also deletes the tablet's saved pairing code.
            std::cout << "The tablet app could not be updated: it was signed with a different key. "
                         "Uninstall DualSlate on the tablet once, then press Start again "
                         "(you will type the pairing code once more). See docs/signing.md.\n";
        } else {
            std::cout << "APK install may have failed:\n" << install.output << "\n";
        }
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
    // Wait until the app listens on its video port instead of a fixed 1.5 s (an
    // already-open app is ready at once). Port 5000 = 0x1388; state 0A = LISTEN.
    char portHex[8];
    snprintf(portHex, sizeof(portHex), ":%04X", kRemotePort);
    const ULONGLONG deadline = GetTickCount64() + 1500;
    while (GetTickCount64() < deadline && !g_stop.load()) {
        const std::string net =
            runCapture(quote(adb) + " shell cat /proc/net/tcp6 /proc/net/tcp").output;
        bool listening = false;
        for (size_t p = net.find(portHex); p != std::string::npos; p = net.find(portHex, p + 1)) {
            // "local_address rem_address st": the local port is followed by the
            // remote address, then the state.
            const size_t sp = net.find(' ', p);
            if (sp == std::string::npos) break;
            const size_t st = net.find(' ', sp + 1);
            if (st != std::string::npos && net.compare(st + 1, 2, "0A") == 0) { listening = true; break; }
        }
        if (listening) break;
        Sleep(100);
    }
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

    // Probe every candidate at once (each probe is a short ffmpeg run); one after
    // another they added seconds to every Start. The ladder order is unchanged.
    std::vector<const Candidate*> wanted;
    for (const Candidate& c : all) {
        if (c.encoder[0] == '\0') continue;  // codec not available via this backend
        if (!options.encoderOverride.empty() && options.encoderOverride != c.flag) continue;
        wanted.push_back(&c);
    }
    std::vector<std::future<bool>> probes;
    for (const Candidate* c : wanted) {
        const std::string enc = c->encoder;
        probes.push_back(std::async(std::launch::async,
                                    [&ffmpeg, enc]() { return probeEncoder(ffmpeg, enc); }));
    }

    std::vector<Attempt> ladder;
    for (size_t i = 0; i < wanted.size(); ++i) {
        const Candidate& c = *wanted[i];
        const bool available = probes[i].get();
        std::cout << "Probing " << c.encoder << "... " << (available ? "ok" : "not available") << "\n";
        if (!available) continue;
        ladder.push_back({c.encoder, false});  // plain CPU-fed path first (always works)
        // The NVENC GPU zero-copy path is lower-latency but only works when the
        // display is on the NVIDIA adapter (never the VDD), so try it AFTER plain.
        if (std::string(c.flag) == "nvenc" && !options.noZeroCopy && !options.hevc) {
            ladder.push_back({c.encoder, true});
        }
    }
    return ladder;
}

// Dev-only switches are environment variables set to 1 (see envFlag users).
bool envFlag(const char* name) {
    char v[8] = {0};
    return GetEnvironmentVariableA(name, v, sizeof(v)) > 0 && v[0] == '1';
}

// Dev-only: EXTDISPLAY_DIRECT_TCP=1 restores plaintext "ffmpeg writes straight to
// the tablet" (no sender in the path) so the old behaviour can be measured.
bool directTcpDev() { return envFlag("EXTDISPLAY_DIRECT_TCP"); }

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
        // -stats emits a periodic "frame=.. fps=.. bitrate=.." line on stderr
        // (separate from the NAL stdout pipe) so the GUI can show live throughput.
        << " -hide_banner -loglevel warning -stats -stats_period 1"
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
        // NOTE: intra-refresh was tried for the UDP path but it removed the periodic
        // IDR keyframes the decoder needs to (re)sync on a lossy Wi-Fi link, causing
        // a permanent freeze. Periodic IDR (-g) recovers within ~1s, so keep it.
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

    // Route through the sender (Annex-B on stdout) for UDP, and also for encrypted
    // TCP where the sender AES-GCMs each NAL before sending. Plain TCP lets ffmpeg
    // connect to the tablet's listener directly.
    if (options.udp || g_pairKey || !directTcpDev()) {
        // AVI wraps every packet in a size-prefixed chunk, so the sender knows
        // exactly where each frame ends (see pumpAnnexB). -avioflags direct: the
        // muxer does not hold packets back. Dev switch: EXTDISPLAY_LEGACY_SPLIT=1
        // asks for the raw stream again (to measure the old behaviour).
        if (envFlag("EXTDISPLAY_LEGACY_SPLIT")) {
            cmd << " -f " << (isHevc ? "hevc" : "h264") << " pipe:1";
        } else {
            // AVI is a variable-frame-rate format, which would turn ffmpeg's
            // default (constant rate, repeating the last frame on a still screen)
            // into "only when something changes"; keep the constant rate.
            cmd << " -fps_mode cfr -avioflags direct -f avi pipe:1";
        }
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
        // InjectSyntheticPointerInput takes pen positions relative to the VIRTUAL
        // SCREEN's top-left, not the primary's (unlike InjectTouchInput). Measured
        // with a monitor left of the primary (virtual screen at x=-1920): every pen
        // point landed exactly 1920 px left; with this shift, 0 px error on all
        // three displays.
        penInfo.pointerInfo.ptPixelLocation.x = pt.x - GetSystemMetrics(SM_XVIRTUALSCREEN);
        penInfo.pointerInfo.ptPixelLocation.y = pt.y - GetSystemMetrics(SM_YVIRTUALSCREEN);
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

bool sendAll(SOCKET sock, const unsigned char* buffer, int length) {
    int sent = 0;
    while (sent < length) {
        const int n = send(sock, reinterpret_cast<const char*>(buffer) + sent, length - sent, 0);
        if (n == SOCKET_ERROR || n == 0) return false;
        sent += n;
    }
    return true;
}

void runTouchBridge(const std::string adb, const std::string host, int localPort,
                    bool adbMode) {
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

        bool connected = true;
        if (g_pairKey) {
            // Encrypted path: fixed-size AES-GCM frames. TCP keeps us aligned from
            // the first packet; an auth failure means a wrong pairing code (or
            // tampering) — there's nothing to resync to, so drop the connection.
            AesGcm dec;
            if (!dec.init(*g_pairKey)) { closesocket(sock); break; }
            unsigned char enc[kTouchEncSize];
            std::vector<uint8_t> pt;
            uint64_t lastCtr = 0;
            bool haveCtr = false;
            while (connected && !g_stop.load()) {
                if (!recvFull(sock, enc, kTouchEncSize)) break;
                if (!dec.decrypt(enc, kTouchEncSize, pt) ||
                    pt.size() != kTouchPacketSize || readBe32(pt.data()) != kTouchMagic) {
                    // Wrong pairing code or tampering — reject (no input injection).
                    // stderr is unbuffered so the GUI sees it promptly.
                    fprintf(stderr, "Touch pairing/auth failed - check the code on the tablet.\n");
                    fflush(stderr);
                    break;
                }
                // Replay guard: nonce = 4B random prefix + 8B big-endian counter.
                uint64_t ctr = 0;
                for (int i = 4; i < kGcmNonceLen; ++i) ctr = (ctr << 8) | enc[i];
                if (haveCtr && ctr <= lastCtr) continue;  // drop replays / reorders
                lastCtr = ctr; haveCtr = true;
                if (readBe16(pt.data() + 4) != kTouchProtocolVersion) continue;
                injector.handle(parseTouchPacket(pt.data()), getTouchDisplay());
            }
        } else {
            unsigned char packet[kTouchPacketSize];
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
                injector.handle(parseTouchPacket(packet), getTouchDisplay());
            }
        }
        closesocket(sock);
        injector.releaseAllContacts();  // don't leave fingers stuck down
        sleepInterruptible(1000);
    }
    injector.shutdown();
    WSACleanup();
}

// --------------------------------------------------------------- desktop audio
//
// WASAPI loopback capture of the default render endpoint (whatever the PC is
// playing) -> S16 stereo PCM -> length-prefixed frames to the tablet, which plays
// them through an AudioTrack. Opt-in via --audio.
//
// Wire format: a 12-byte plaintext header once per connection —
//   [4B 'EXAU'][4B BE sampleRate][2B BE channels=2][2B BE bits=16]
// then per-capture-packet frames [4B BE len][payload], where payload is raw
// S16LE interleaved PCM (open link) or a [12B nonce][ct][16B tag] AES-GCM blob
// (paired). Nonce prefix 0x02 domain-separates audio from video (0x01)/touch (0x00).

// Convert one WASAPI capture packet (the endpoint mix format) to interleaved
// S16 stereo. Handles the common float32 mix and 16/32-bit PCM; anything else
// (rare 24-bit) becomes silence rather than noise.
void mixToStereoS16(const BYTE* src, UINT32 frames, const WAVEFORMATEX* fmt,
                    bool silent, std::vector<int16_t>& out) {
    out.resize(static_cast<size_t>(frames) * 2);
    if (out.empty()) return;
    if (silent || src == nullptr) {
        std::memset(out.data(), 0, out.size() * sizeof(int16_t));
        return;
    }
    WORD tag = fmt->wFormatTag;
    if (tag == WAVE_FORMAT_EXTENSIBLE)
        tag = static_cast<WORD>(
            reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(fmt)->SubFormat.Data1);
    const int ch = fmt->nChannels;
    auto clampF = [](float v) -> int16_t {
        v *= 32767.0f;
        if (v > 32767.0f) v = 32767.0f;
        else if (v < -32768.0f) v = -32768.0f;
        return static_cast<int16_t>(v);
    };
    if (tag == WAVE_FORMAT_IEEE_FLOAT) {
        const float* f = reinterpret_cast<const float*>(src);
        for (UINT32 i = 0; i < frames; ++i) {
            const float l = f[i * ch];
            out[i * 2] = clampF(l);
            out[i * 2 + 1] = clampF(ch >= 2 ? f[i * ch + 1] : l);
        }
    } else if (tag == WAVE_FORMAT_PCM && fmt->wBitsPerSample == 16) {
        const int16_t* s = reinterpret_cast<const int16_t*>(src);
        for (UINT32 i = 0; i < frames; ++i) {
            out[i * 2] = s[i * ch];
            out[i * 2 + 1] = ch >= 2 ? s[i * ch + 1] : s[i * ch];
        }
    } else if (tag == WAVE_FORMAT_PCM && fmt->wBitsPerSample == 32) {
        const int32_t* s = reinterpret_cast<const int32_t*>(src);
        for (UINT32 i = 0; i < frames; ++i) {
            out[i * 2] = static_cast<int16_t>(s[i * ch] >> 16);
            out[i * 2 + 1] = static_cast<int16_t>((ch >= 2 ? s[i * ch + 1] : s[i * ch]) >> 16);
        }
    } else {
        std::memset(out.data(), 0, out.size() * sizeof(int16_t));
    }
}

// Marker so a force-killed sender (the GUI's Stop terminates the process, skipping
// the restore) doesn't leave the PC muted: written while muted, deleted on restore,
// and cleared at next startup by restoreLocalMuteIfNeeded().
std::string muteMarkerPath() {
    char localAppData[MAX_PATH] = {};
    DWORD len = GetEnvironmentVariableA("LOCALAPPDATA", localAppData, MAX_PATH);
    if (len > 0 && len < MAX_PATH) {
        const std::string dir = std::string(localAppData) + "\\ExtendedDisplay";
        CreateDirectoryA(dir.c_str(), nullptr);
        return dir + "\\local-muted.flag";
    }
    return "local-muted.flag";
}

// Mute/unmute the default render endpoint (the PC's speakers). COM must already be
// initialized on the calling thread. NOTE: on some PCs (measured: ASUS, Realtek HD
// Audio + DTS APOs, Windows 11 26320) a normal device loopback goes silent when the
// endpoint is muted or at volume 0, so the audio bridge captures with *process
// loopback* when it mutes (see openProcessLoopbackExcluding), which is unaffected.
bool setEndpointMute(bool mute) {
    IMMDeviceEnumerator* en = nullptr;
    IMMDevice* dev = nullptr;
    IAudioEndpointVolume* vol = nullptr;
    bool ok = false;
    if (SUCCEEDED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                   __uuidof(IMMDeviceEnumerator), reinterpret_cast<void**>(&en))) &&
        SUCCEEDED(en->GetDefaultAudioEndpoint(eRender, eConsole, &dev)) &&
        SUCCEEDED(dev->Activate(__uuidof(IAudioEndpointVolume), CLSCTX_ALL, nullptr,
                                reinterpret_cast<void**>(&vol)))) {
        ok = SUCCEEDED(vol->SetMute(mute ? TRUE : FALSE, nullptr));
    }
    if (vol) vol->Release();
    if (dev) dev->Release();
    if (en) en->Release();
    return ok;
}

// Self-heal: if a prior run muted the PC and died before restoring, unmute now.
void restoreLocalMuteIfNeeded() {
    if (!fileExists(muteMarkerPath())) return;
    const bool coInit = SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED));
    setEndpointMute(false);
    if (coInit) CoUninitialize();
    DeleteFileA(muteMarkerPath().c_str());
}

// Process loopback (Windows 10 version 2004+, build 19041): captures the audio of every
// process EXCEPT the given process tree, tapped inside the audio engine before the
// endpoint's volume/mute/driver stage. Muting the PC speakers therefore does not
// silence what is sent to the tablet, unlike plain device loopback (measured here:
// device loopback peak 0.119 -> 0.000 on mute; process loopback stays at 0.300).
struct ActivateHandler : IActivateAudioInterfaceCompletionHandler, IAgileObject {
    LONG refs = 1;
    HANDLE done = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    ~ActivateHandler() { if (done) CloseHandle(done); }
    STDMETHODIMP QueryInterface(REFIID r, void** o) override {
        if (r == __uuidof(IUnknown) || r == __uuidof(IActivateAudioInterfaceCompletionHandler))
            *o = static_cast<IActivateAudioInterfaceCompletionHandler*>(this);
        else if (r == __uuidof(IAgileObject)) *o = static_cast<IAgileObject*>(this);
        else { *o = nullptr; return E_NOINTERFACE; }
        AddRef();
        return S_OK;
    }
    STDMETHODIMP_(ULONG) AddRef() override { return InterlockedIncrement(&refs); }
    STDMETHODIMP_(ULONG) Release() override {
        const ULONG n = InterlockedDecrement(&refs);
        if (n == 0) delete this;
        return n;
    }
    STDMETHODIMP ActivateCompleted(IActivateAudioInterfaceAsyncOperation*) override {
        SetEvent(done);
        return S_OK;
    }
};

// On success: *outClient is initialised (loopback, 48 kHz / 16-bit / stereo, not yet
// started) with *outCapture, a CoTaskMem-allocated *outFmt and an event handle the
// caller closes. Returns false on any failure (older Windows, API missing) and leaves
// the outputs untouched.
bool openProcessLoopbackExcluding(DWORD excludePid, IAudioClient** outClient,
                                  IAudioCaptureClient** outCapture, WAVEFORMATEX** outFmt,
                                  HANDLE* outEvent) {
    AUDIOCLIENT_ACTIVATION_PARAMS ap = {};
    ap.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
    ap.ProcessLoopbackParams.TargetProcessId = excludePid;
    ap.ProcessLoopbackParams.ProcessLoopbackMode = PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE;
    PROPVARIANT pv = {};
    pv.vt = VT_BLOB;
    pv.blob.cbSize = sizeof(ap);
    pv.blob.pBlobData = reinterpret_cast<BYTE*>(&ap);

    ActivateHandler* h = new ActivateHandler;
    IActivateAudioInterfaceAsyncOperation* op = nullptr;
    if (FAILED(ActivateAudioInterfaceAsync(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK,
                                           __uuidof(IAudioClient), &pv, h, &op)) || !op) {
        h->Release();
        return false;
    }
    WaitForSingleObject(h->done, 5000);
    HRESULT ahr = E_FAIL;
    IUnknown* unk = nullptr;
    op->GetActivateResult(&ahr, &unk);
    op->Release();
    h->Release();
    if (FAILED(ahr) || !unk) return false;

    IAudioClient* c = nullptr;
    unk->QueryInterface(__uuidof(IAudioClient), reinterpret_cast<void**>(&c));
    unk->Release();
    if (!c) return false;

    WAVEFORMATEX* f = static_cast<WAVEFORMATEX*>(CoTaskMemAlloc(sizeof(WAVEFORMATEX)));
    if (!f) { c->Release(); return false; }
    *f = {};
    f->wFormatTag = WAVE_FORMAT_PCM;
    f->nChannels = 2;
    f->nSamplesPerSec = 48000;
    f->wBitsPerSample = 16;
    f->nBlockAlign = 4;
    f->nAvgBytesPerSec = 48000 * 4;
    // Measured on this PC: AUDCLNT_STREAMFLAGS_NOPERSIST is rejected (0x88890021),
    // while LOOPBACK|EVENTCALLBACK with 16-bit PCM works. The event is not waited on
    // (the bridge polls), it only has to exist.
    HANDLE ev = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    IAudioCaptureClient* cap = nullptr;
    if (!ev ||
        FAILED(c->Initialize(AUDCLNT_SHAREMODE_SHARED,
                             AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
                             // 200 ms: with 0 the buffer is one ~10 ms period, which a
                             // 5 ms Sleep (really up to ~15 ms) overran: choppy audio.
                             2000000, 0, f, nullptr)) ||
        FAILED(c->SetEventHandle(ev)) ||
        FAILED(c->GetService(__uuidof(IAudioCaptureClient), reinterpret_cast<void**>(&cap)))) {
        if (ev) CloseHandle(ev);
        CoTaskMemFree(f);
        c->Release();
        return false;
    }
    *outClient = c;
    *outCapture = cap;
    *outFmt = f;
    *outEvent = ev;
    return true;
}

void runAudioBridge(const std::string adb, const std::string host, int localPort,
                    bool adbMode, bool muteLocal, int audioDelayMs) {
    if (FAILED(CoInitializeEx(nullptr, COINIT_MULTITHREADED))) return;

    IMMDeviceEnumerator* enumr = nullptr;
    IMMDevice* dev = nullptr;
    IAudioClient* client = nullptr;
    IAudioCaptureClient* capture = nullptr;
    WAVEFORMATEX* mixFmt = nullptr;
    HANDLE procEvent = nullptr;  // only when capturing via process loopback
    auto cleanup = [&]() {
        if (procEvent) { CloseHandle(procEvent); procEvent = nullptr; }
        if (capture) capture->Release();
        if (client) client->Release();
        if (dev) dev->Release();
        if (enumr) enumr->Release();
        if (mixFmt) CoTaskMemFree(mixFmt);
    };

    if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                __uuidof(IMMDeviceEnumerator),
                                reinterpret_cast<void**>(&enumr))) ||
        FAILED(enumr->GetDefaultAudioEndpoint(eRender, eConsole, &dev)) ||
        FAILED(dev->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                             reinterpret_cast<void**>(&client))) ||
        FAILED(client->GetMixFormat(&mixFmt))) {
        std::cerr << "Desktop audio: WASAPI init failed; continuing without audio.\n";
        cleanup(); CoUninitialize(); return;
    }
    const REFERENCE_TIME hnsBuffer = 2000000;  // 200ms client buffer (100ns units)
    if (FAILED(client->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK,
                                  hnsBuffer, 0, mixFmt, nullptr)) ||
        FAILED(client->GetService(__uuidof(IAudioCaptureClient),
                                  reinterpret_cast<void**>(&capture)))) {
        std::cerr << "Desktop audio: WASAPI loopback unavailable; continuing without audio.\n";
        cleanup(); CoUninitialize(); return;
    }
    // "Mute PC speakers": plain device loopback can go silent together with the speakers
    // (driver-dependent), so capture with process loopback (everything except this
    // process tree) instead. If that is unavailable (Windows older than 10 2004) the
    // option can't work: leave the speakers on and say so.
    if (muteLocal) {
        IAudioClient* pc = nullptr;
        IAudioCaptureClient* pcap = nullptr;
        WAVEFORMATEX* pfmt = nullptr;
        HANDLE pev = nullptr;
        if (openProcessLoopbackExcluding(GetCurrentProcessId(), &pc, &pcap, &pfmt, &pev)) {
            capture->Release();
            client->Release();
            CoTaskMemFree(mixFmt);
            client = pc; capture = pcap; mixFmt = pfmt; procEvent = pev;
        } else {
            muteLocal = false;
            std::cout << "Desktop audio: \"Mute PC speakers\" needs Windows 10 version 2004 or newer; "
                         "the PC speakers stay on." << std::endl;
        }
    }
    const uint32_t sampleRate = mixFmt->nSamplesPerSec;
    std::cout << "Desktop audio: capturing at " << sampleRate
              << " Hz -> tablet (stereo 16-bit).\n";

    WSADATA wsa{};
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) { cleanup(); CoUninitialize(); return; }

    // Optionally silence the PC's own speakers so sound only comes from the tablet.
    // The capture above is process loopback, which is tapped before the endpoint's
    // mute, so muting is safe. We mute only while a tablet is connected, only if the
    // speakers were not already muted by the user (then we never touch them), and
    // write a marker file first so a force-killed sender is healed at the next start
    // (restoreLocalMuteIfNeeded). Pressing Volume Up/Down un-mutes the endpoint
    // (Windows behaviour), so a mute we own is re-asserted periodically below.
    // While a tablet is receiving we HOLD the mute (re-asserted below), whether or
    // not the user had muted already: measured, a user who started muted and then
    // un-muted got sound from the laptop. On release the speakers go back to exactly
    // what the user had. The marker file is written only when we changed an
    // un-muted endpoint, so the force-kill self-heal never un-mutes a user's mute.
    IAudioEndpointVolume* epv = nullptr;
    bool didMute = false;        // we are holding the speakers muted
    BOOL userHadMuted = FALSE;   // their state before we took over
    if (muteLocal &&
        FAILED(dev->Activate(__uuidof(IAudioEndpointVolume), CLSCTX_ALL, nullptr,
                             reinterpret_cast<void**>(&epv)))) {
        epv = nullptr;
    }
    auto muteLocalSpeakers = [&]() {
        if (!epv || didMute) return;
        if (FAILED(epv->GetMute(&userHadMuted))) return;
        if (!userHadMuted) {
            FILE* mf = nullptr;
            if (fopen_s(&mf, muteMarkerPath().c_str(), "w") == 0 && mf) fclose(mf);
            if (FAILED(epv->SetMute(TRUE, nullptr))) {
                DeleteFileA(muteMarkerPath().c_str());
                return;
            }
        }
        didMute = true;
        std::cout << "Desktop audio: PC speakers muted (sound plays on the tablet only)." << std::endl;
    };
    auto unmuteLocal = [&]() {
        if (!didMute) return;
        epv->SetMute(userHadMuted, nullptr);  // back to what the user had
        DeleteFileA(muteMarkerPath().c_str());
        didMute = false;
        std::cout << (userHadMuted ? "Desktop audio: PC speakers left muted, as they were."
                                   : "Desktop audio: PC speakers un-muted.") << std::endl;
    };
    ULONGLONG lastRemute = GetTickCount64();

    const std::string connectHost = adbMode ? "127.0.0.1" : host;
    const int connectPort = adbMode ? localPort : kRemoteAudioPort;

    std::vector<int16_t> pcm;
    std::vector<uint8_t> blob;

    while (!g_stop.load()) {
        if (adbMode) {
            runCapture(quote(adb) + " forward tcp:" + std::to_string(localPort) +
                       " tcp:" + std::to_string(kRemoteAudioPort));
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

        AesGcm aenc;
        const bool enc = g_pairKey && aenc.init(*g_pairKey);
        uint8_t aPrefix[4] = {0x02, 0, 0, 0};
        if (enc) BCryptGenRandom(nullptr, aPrefix + 1, 3, BCRYPT_USE_SYSTEM_PREFERRED_RNG);
        uint64_t aCtr = 0;

        // Header: [4 magic][4 rate][2 channels][1 bits][1 flags][2 delayMs][2 rsvd].
        // flags bit0 = encrypted, so the tablet stays silent until paired (else it
        // would play the encrypted bytes as raw PCM = white noise while you type the
        // code). delayMs is the tablet's audio buffer/latency for A/V sync.
        const int dms = audioDelayMs < 0 ? 0 : (audioDelayMs > 1000 ? 1000 : audioDelayMs);
        unsigned char hdr[16] = {
            static_cast<unsigned char>(kAudioMagic >> 24), static_cast<unsigned char>(kAudioMagic >> 16),
            static_cast<unsigned char>(kAudioMagic >> 8),  static_cast<unsigned char>(kAudioMagic),
            static_cast<unsigned char>(sampleRate >> 24),  static_cast<unsigned char>(sampleRate >> 16),
            static_cast<unsigned char>(sampleRate >> 8),   static_cast<unsigned char>(sampleRate),
            0, 2,   // channels = 2
            16,     // bits = 16
            static_cast<unsigned char>(enc ? 1 : 0),  // flags: bit0 = encrypted
            static_cast<unsigned char>(dms >> 8), static_cast<unsigned char>(dms),  // delayMs (BE)
            0, 0    // reserved
        };
        if (!sendAll(sock, hdr, 16)) { closesocket(sock); sleepInterruptible(1000); continue; }

        // Wait for the tablet's 1-byte ACK. adb-forward accepts our local socket even
        // before the app has bound its port (startup race), so a successful connect()
        // doesn't mean a live receiver; without this we'd stream audio (a write-only
        // channel, so no error surfaces) into a dead relay forever. Reconnect if the
        // ACK doesn't arrive.
        {
            DWORD ackTimeout = 4000;
            setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO,
                       reinterpret_cast<char*>(&ackTimeout), sizeof(ackTimeout));
            unsigned char ack = 0;
            if (recv(sock, reinterpret_cast<char*>(&ack), 1, 0) != 1) {
                // No live receiver yet (app still launching / relay not ready) — retry
                // quietly, like the touch bridge does.
                closesocket(sock); sleepInterruptible(1000); continue;
            }
        }

        // Drop anything buffered from a prior session. Never Reset() a process-loopback
        // client: measured, it then delivers no packets at all (tablet silent).
        if (!procEvent) client->Reset();
        client->Start();
        muteLocalSpeakers();  // a tablet is receiving: now it's safe to silence the PC
        bool alive = true;
        while (!g_stop.load() && alive) {
            // Re-assert the mute if the user's volume keys un-muted the endpoint.
            if (didMute) {
                const ULONGLONG now = GetTickCount64();
                if (now - lastRemute > 500) {
                    lastRemute = now;
                    BOOL m = FALSE;
                    if (SUCCEEDED(epv->GetMute(&m)) && !m) epv->SetMute(TRUE, nullptr);
                }
            }
            UINT32 packetLen = 0;
            if (FAILED(capture->GetNextPacketSize(&packetLen))) break;
            if (packetLen == 0) {
                // Process loopback signals its event per period: wait on it instead
                // of sleeping, so no period is missed.
                // (sleepInterruptible() sleeps in 100 ms steps: far too coarse here.)
                if (procEvent) WaitForSingleObject(procEvent, 50);
                else Sleep(5);
                continue;
            }
            while (packetLen != 0 && alive) {
                BYTE* data = nullptr;
                UINT32 frames = 0;
                DWORD flags = 0;
                if (FAILED(capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr))) {
                    alive = false; break;
                }
                mixToStereoS16(data, frames, mixFmt,
                               (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0, pcm);
                capture->ReleaseBuffer(frames);

                const unsigned char* payload = reinterpret_cast<const unsigned char*>(pcm.data());
                int payloadLen = static_cast<int>(pcm.size() * sizeof(int16_t));
                if (payloadLen == 0) {
                    if (FAILED(capture->GetNextPacketSize(&packetLen))) alive = false;
                    continue;
                }
                if (enc) {
                    uint8_t nonce[kGcmNonceLen];
                    std::memcpy(nonce, aPrefix, 4);
                    ++aCtr;
                    for (int i = 0; i < 8; ++i)
                        nonce[4 + i] = static_cast<uint8_t>(aCtr >> (8 * (7 - i)));
                    if (!aenc.encrypt(payload, payloadLen, nonce, blob)) { alive = false; break; }
                    payload = blob.data();
                    payloadLen = static_cast<int>(blob.size());
                }
                unsigned char lh[4] = {
                    static_cast<unsigned char>(payloadLen >> 24), static_cast<unsigned char>(payloadLen >> 16),
                    static_cast<unsigned char>(payloadLen >> 8),  static_cast<unsigned char>(payloadLen) };
                if (!sendAll(sock, lh, 4) || !sendAll(sock, payload, payloadLen)) {
                    alive = false; break;  // tablet closed the connection
                }
                if (FAILED(capture->GetNextPacketSize(&packetLen))) { alive = false; break; }
            }
        }
        client->Stop();
        closesocket(sock);
        unmuteLocal();  // tablet gone: give the PC its sound back until it reconnects
        if (!g_stop.load()) sleepInterruptible(1000);
    }
    unmuteLocal();
    if (epv) epv->Release();
    cleanup();
    WSACleanup();
    CoUninitialize();
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
                 "(make sure the DualSlate app is open on the tablet)...\n";
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
        "ExtendedDisplaySender - plug-and-play extended display over USB\n\n"
        "Just run it with no arguments:\n"
        "  - switches the virtual screen on once a tablet is found (the driver must be\n"
        "    loaded: start from the DualSlate app) and off again when done\n"
        "  - waits for the tablet over USB, installs and launches the receiver app\n"
        "  - picks the best encoder for this machine and streams; reconnects automatically\n\n"
        "Options:\n"
        "  --port N          Local forward port (default 5000)\n"
        "  --fps N           Frame rate (default 60)\n"
        "  --bitrate KBPS    Encoder bitrate in kbps (default 25000)\n"
        "  --display N       Capture a specific display (see --list-displays)\n"
        "  --list-displays   Print the display table and exit\n"
        "  --cleanup         Switch the virtual screen off, un-mute the PC, and exit\n"
        "  --width N         Scale output width (default: native)\n"
        "  --height N        Scale output height (default: native)\n"
        "  --encoder NAME    Pin encoder: nvenc | qsv | amf | mf | x264\n"
        "  --no-zerocopy     Disable the GPU-only NVENC path\n"
        "  --hevc            Use H.265/HEVC (sharper at high resolution)\n"
        "  --hdr             HDR10 output (10-bit BT.2020 PQ; implies --hevc)\n"
        "  --no-touch        Disable tablet touch -> mouse injection\n"
        "  --audio           Stream desktop audio (PC playback) to the tablet\n"
        "  --mute-local      With --audio: mute the PC's own speakers (tablet only)\n"
        "  --audio-delay-ms N  Tablet audio buffer for A/V sync (default 40; higher=later)\n"
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
        } else if (arg == "--cleanup") {
            options.cleanup = true;
        } else if (arg == "--audio-test") {
            options.audioTest = true;
        } else if (arg == "--screen-test") {
            options.screenTest = true;
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
        } else if (arg == "--audio") {
            options.audio = true;
        } else if (arg == "--no-audio") {
            options.audio = false;
        } else if (arg == "--mute-local") {
            options.muteLocal = true;
        } else if (arg == "--audio-delay-ms") {
            options.audioDelayMs = readInt(requireValue("--audio-delay-ms"), "--audio-delay-ms");
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

// ------------------------------------------------- frame-exact ffmpeg output
//
// Raw Annex-B has no frame boundaries: a NAL ends where the next start code
// begins, so the last NAL of every frame (the picture slice) used to sit in the
// sender until the NEXT frame arrived, one frame interval (16.7 ms at 60 fps) later.
// Pipe reads cannot fix that: ffmpeg writes a large packet in 32 KB pieces, so a
// read boundary is not a packet boundary (measured; cutting there sent partial NALs).
//
// So the relay paths ask ffmpeg for AVI instead (-f avi): the muxer passes each
// packet through untouched, in-band parameter sets included, but wraps it in a
// '00dc' chunk whose header carries the exact size. A frame is therefore known to
// be complete the moment its last byte arrives, whatever the pipe's read sizes.
// With -avioflags direct the muxer does not buffer, so nothing waits for the next
// packet (verified with a 2 fps source: each frame arrived when produced).
//
// If the stream is not AVI (the dev switch EXTDISPLAY_LEGACY_SPLIT=1, or an ffmpeg
// that ignored -f avi) the pump falls back to start-code framing, as before.

bool createVideoPipe(HANDLE& readEnd, HANDLE& writeEnd) {
    SECURITY_ATTRIBUTES sa{};
    sa.nLength = sizeof(sa);
    sa.bInheritHandle = TRUE;
    if (!CreatePipe(&readEnd, &writeEnd, &sa, 1 << 20)) return false;
    SetHandleInformation(readEnd, HANDLE_FLAG_INHERIT, 0);
    return true;
}

double nowMs() {
    static const double freq = [] {
        LARGE_INTEGER f; QueryPerformanceFrequency(&f); return static_cast<double>(f.QuadPart);
    }();
    LARGE_INTEGER c; QueryPerformanceCounter(&c);
    return static_cast<double>(c.QuadPart) * 1000.0 / freq;
}

// Dev-only (EXTDISPLAY_HOLD_STATS=1): once a second, how long NALs were held
// between their last byte arriving from ffmpeg and being handed to the network.
struct HoldStats {
    bool on = false;
    const char* tag = "";
    unsigned n = 0, held = 0;
    double sum = 0, sumHeld = 0, max = 0, lastPrint = 0;
    void init(const char* t) { tag = t; on = envFlag("EXTDISPLAY_HOLD_STATS"); lastPrint = nowMs(); }
    void add(double ms) {
        if (!on) return;
        ++n; sum += ms; if (ms > max) max = ms; if (ms > 1.0) { ++held; sumHeld += ms; }
        const double t = nowMs();
        if (t - lastPrint >= 1000.0) {
            std::cerr << "HOLD[" << tag << "] nals=" << n << " held>1ms=" << held
                      << " avg=" << (n ? sum / n : 0.0) << "ms avgHeld=" << (held ? sumHeld / held : 0.0)
                      << "ms max=" << max << "ms" << std::endl;
            n = held = 0; sum = sumHeld = max = 0; lastPrint = t;
        }
    }
};

// Annex-B access-unit delimiters (a complete NAL each): H.264 type 9, HEVC type 35.
// Appended right after a complete frame they are the NEXT access unit's delimiter,
// so the stream stays valid, and they tell a receiver that reads a byte stream
// that the frame's last NAL has ended (it sees a start code right away).
const unsigned char kAudH264[] = {0, 0, 0, 1, 0x09, 0xF0};
const unsigned char kAudHevc[] = {0, 0, 0, 1, 0x46, 0x01, 0x50};

int annexBStartLen(const unsigned char* p, size_t avail) {
    if (avail >= 3 && p[0] == 0 && p[1] == 0 && p[2] == 1) return 3;
    if (avail >= 4 && p[0] == 0 && p[1] == 0 && p[2] == 0 && p[3] == 1) return 4;
    return 0;
}

size_t annexBNextStart(const unsigned char* b, size_t size, size_t from) {
    for (size_t i = from; i + 3 <= size; ++i) {
        if (b[i] == 0 && b[i + 1] == 0 &&
            (b[i + 2] == 1 || (b[i + 2] == 0 && i + 3 < size && b[i + 3] == 1))) {
            return i;
        }
    }
    return std::string::npos;
}

// Reads ffmpeg's stdout until it ends (or keepGoing() turns false) and calls
//   emit(nal, len, flush, frameEnd)
// for every NAL (start code included). flush is true on the last NAL of a batch
// that may be written out; frameEnd is true only when that NAL is PROVEN to end a
// frame (AVI chunk boundary), i.e. an AUD may follow it.
template <class KeepGoing, class Emit>
void pumpAnnexB(HANDLE pipe, const char* tag, KeepGoing keepGoing, Emit emit) {
    constexpr size_t kMaxChunk = 64u << 20;  // a frame this big means a corrupt stream
    HoldStats stats;
    stats.init(tag);
    std::vector<unsigned char> chunk(1 << 18), buf;
    buf.reserve(1 << 20);
    enum { kDetect, kAviTop, kAviMovi, kRaw } mode = kDetect;
    size_t pos = 0;                                  // consumed up to here
    size_t rawBase = std::string::npos;              // raw mode: start of the current NAL
    double tRead = nowMs(), tPrevRead = tRead;       // when the latest / previous read returned
    long long readStart = 0;                         // buf index where the latest read begins
    bool bad = false;
    DWORD got = 0;
    while (!bad && keepGoing() &&
           ReadFile(pipe, chunk.data(), static_cast<DWORD>(chunk.size()), &got, nullptr) && got > 0) {
        tPrevRead = tRead;
        tRead = nowMs();
        readStart = static_cast<long long>(buf.size());
        buf.insert(buf.end(), chunk.data(), chunk.data() + got);

        for (;;) {
            const size_t avail = buf.size() - pos;
            const unsigned char* p = buf.data() + pos;
            if (mode == kDetect) {
                if (avail < 12) break;
                if (std::memcmp(p, "RIFF", 4) == 0 && std::memcmp(p + 8, "AVI ", 4) == 0) {
                    pos += 12;
                    mode = kAviTop;
                } else {
                    mode = kRaw;
                }
                continue;
            }
            if (mode == kAviTop) {
                // Skip the header lists; frames start after "LIST <size> movi". (The
                // sizes in a streamed header are not relied on, so search for it.)
                size_t found = std::string::npos;
                for (size_t i = 0; i + 12 <= avail; ++i) {
                    if (std::memcmp(p + i, "LIST", 4) == 0 && std::memcmp(p + i + 8, "movi", 4) == 0) {
                        found = i;
                        break;
                    }
                }
                if (found == std::string::npos) {
                    if (avail > (1u << 20)) bad = true;  // no movi list: not the AVI we asked for
                    break;
                }
                pos += found + 12;
                mode = kAviMovi;
                continue;
            }
            if (mode == kAviMovi) {
                if (avail < 8) break;
                const size_t sz = static_cast<size_t>(p[4]) | (static_cast<size_t>(p[5]) << 8) |
                                  (static_cast<size_t>(p[6]) << 16) | (static_cast<size_t>(p[7]) << 24);
                if (sz > kMaxChunk) { bad = true; break; }
                const size_t total = 8 + sz + (sz & 1);
                if (avail < total) break;  // the rest of this frame is still on its way
                if (p[2] == 'd' && (p[3] == 'c' || p[3] == 'b') && sz > 0) {
                    const unsigned char* f = p + 8;
                    size_t base = 0;
                    for (;;) {
                        const size_t next = annexBNextStart(f, sz, base + annexBStartLen(f + base, sz - base));
                        const size_t end = next == std::string::npos ? sz : next;
                        const bool last = next == std::string::npos;
                        emit(f + base, end - base, last, last);
                        stats.add(nowMs() - tRead);
                        if (last) break;
                        base = next;
                    }
                }
                pos += total;
                continue;
            }
            // kRaw: a NAL is complete only when the next start code arrives.
            if (rawBase == std::string::npos) {
                rawBase = annexBNextStart(buf.data(), buf.size(), pos);
                if (rawBase == std::string::npos) break;
            }
            const size_t next = annexBNextStart(
                buf.data(), buf.size(),
                rawBase + annexBStartLen(buf.data() + rawBase, buf.size() - rawBase));
            if (next == std::string::npos) break;
            emit(buf.data() + rawBase, next - rawBase, true, false);
            // Its last byte came in with this read, or waited since the one before.
            stats.add(static_cast<long long>(next) - 1 >= readStart ? 0.0 : tRead - tPrevRead);
            rawBase = next;
            pos = next;
        }

        if (pos > 0) {
            buf.erase(buf.begin(), buf.begin() + pos);
            if (rawBase != std::string::npos) rawBase -= pos;
            pos = 0;
        }
    }
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
    // A keyframe bursts dozens of fragments at once; a big send buffer keeps the
    // OS/Wi-Fi driver from dropping them on the floor (a common cause of UDP stutter).
    int sndBuf = 4 << 20;  // 4 MB
    setsockopt(sock, SOL_SOCKET, SO_SNDBUF, reinterpret_cast<char*>(&sndBuf), sizeof(sndBuf));
    sockaddr_in dest{};
    dest.sin_family = AF_INET;
    dest.sin_port = htons(static_cast<u_short>(udpPort));
    inet_pton(AF_INET, host.c_str(), &dest.sin_addr);

    HANDLE readPipe = nullptr, writePipe = nullptr;
    if (!createVideoPipe(readPipe, writePipe)) {
        closesocket(sock);
        WSACleanup();
        return 0;
    }

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
    killWithSender(pi.hProcess);
    const ULONGLONG started = GetTickCount64();

    // When paired, encrypt each NAL end-to-end. The EXUD header stays plaintext
    // (needed for reassembly); the fragmented payload is the AES-GCM blob
    // [12B nonce][ct][16B tag], so a sniffer sees only opaque fragments. Nonce
    // prefix byte 0 = 0x01 domain-separates video from the touch channel (0x00)
    // under the shared key.
    AesGcm venc;
    bool vEnc = g_pairKey && venc.init(*g_pairKey);
    uint8_t vPrefix[4] = {0x01, 0, 0, 0};
    if (vEnc) BCryptGenRandom(nullptr, vPrefix + 1, 3, BCRYPT_USE_SYSTEM_PREFERRED_RNG);
    uint64_t vCtr = 0;

    uint32_t nalSeq = 0;
    std::vector<uint8_t> encBlob;
    auto sendNal = [&](const unsigned char* nal, size_t len) {
        if (len == 0) return;
        const unsigned char* data = nal;
        size_t dlen = len;
        if (vEnc) {
            uint8_t nonce[kGcmNonceLen];
            std::memcpy(nonce, vPrefix, 4);
            ++vCtr;
            for (int i = 0; i < 8; ++i) nonce[4 + i] = static_cast<uint8_t>(vCtr >> (8 * (7 - i)));
            if (!venc.encrypt(nal, static_cast<int>(len), nonce, encBlob)) return;
            data = encBlob.data();
            dlen = encBlob.size();
        }
        const uint16_t fragCount = static_cast<uint16_t>(
            (dlen + kUdpPayloadMax - 1) / kUdpPayloadMax);
        unsigned char pkt[kUdpHeaderSize + kUdpPayloadMax];
        for (uint16_t f = 0; f < fragCount; ++f) {
            const size_t off = static_cast<size_t>(f) * kUdpPayloadMax;
            const size_t chunk = (dlen - off < static_cast<size_t>(kUdpPayloadMax))
                                     ? (dlen - off) : static_cast<size_t>(kUdpPayloadMax);
            auto b = [](uint32_t v) { return static_cast<unsigned char>(v & 0xFF); };
            pkt[0] = b(kUdpMagic >> 24); pkt[1] = b(kUdpMagic >> 16);
            pkt[2] = b(kUdpMagic >> 8);  pkt[3] = b(kUdpMagic);
            pkt[4] = b(nalSeq >> 24); pkt[5] = b(nalSeq >> 16);
            pkt[6] = b(nalSeq >> 8);  pkt[7] = b(nalSeq);
            pkt[8] = b(f >> 8);          pkt[9] = b(f);
            pkt[10] = b(fragCount >> 8); pkt[11] = b(fragCount);
            memcpy(pkt + kUdpHeaderSize, data + off, chunk);
            sendto(sock, reinterpret_cast<char*>(pkt),
                   static_cast<int>(kUdpHeaderSize + chunk), 0,
                   reinterpret_cast<sockaddr*>(&dest), sizeof(dest));
        }
        ++nalSeq;
    };

    pumpAnnexB(readPipe, "udp", [] { return !g_stop.load(); },
               [&](const unsigned char* nal, size_t len, bool, bool) { sendNal(nal, len); });

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

// (Also serves plaintext TCP: with no pairing key it skips the marker and the
// encryption and appends a frame-end AUD, so the tablet need not wait a frame.)
// Encrypted TCP video: route ffmpeg's NALs through the sender, AES-256-GCM each one,
// and send it length-prefixed over a reliable TCP connection to the tablet. Used
// when paired (g_pairKey) and NOT --udp, so encrypted Wi-Fi keeps TCP's
// no-dropped-frames smoothness. Wire frame: [4-byte BE length][12B nonce][ct][16B tag].
//
// peerClosed is set when the TABLET ended the connection. A tablet holding a
// different pairing key (or none it can use) closes the stream on the first frame,
// so repeated quick closes mean a pairing mismatch, not an encoder failure.
// announceStable: print a line once the stream has survived kProvenUptimeMs (the
// GUI uses it to leave its "enter the code" state).
ULONGLONG runEncryptedTcpAttempt(const std::string& cmd, const std::string& host, int tcpPort,
                                 bool& peerClosed, bool announceStable, bool hevc) {
    peerClosed = false;
    const bool encrypted = g_pairKey.has_value();
    WSADATA wsa{};
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return 0;
    SOCKET sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (sock == INVALID_SOCKET) { WSACleanup(); return 0; }
    sockaddr_in dest{};
    dest.sin_family = AF_INET;
    dest.sin_port = htons(static_cast<u_short>(tcpPort));
    inet_pton(AF_INET, host.c_str(), &dest.sin_addr);
    if (connect(sock, reinterpret_cast<sockaddr*>(&dest), sizeof(dest)) != 0) {
        closesocket(sock); WSACleanup(); return 0;
    }
    BOOL noDelay = TRUE;
    setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<char*>(&noDelay), sizeof(noDelay));

    // Announce this as an encrypted stream with a 4-byte plaintext marker before any
    // frames. The tablet reads it up front, so it knows to expect length-prefixed
    // AES-GCM frames and can drain them (no garbage decode) until you enter the code,
    // then decrypt on the same connection — no reconnect, no forced socket close.
    unsigned char vmagic[4] = {
        static_cast<unsigned char>(kEncVideoMagic >> 24), static_cast<unsigned char>(kEncVideoMagic >> 16),
        static_cast<unsigned char>(kEncVideoMagic >> 8),  static_cast<unsigned char>(kEncVideoMagic) };
    if (encrypted && !sendAll(sock, vmagic, 4)) { closesocket(sock); WSACleanup(); return 0; }

    HANDLE readPipe = nullptr, writePipe = nullptr;
    if (!createVideoPipe(readPipe, writePipe)) { closesocket(sock); WSACleanup(); return 0; }
    STARTUPINFOA si{}; si.cb = sizeof(si); si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdOutput = writePipe;
    si.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    PROCESS_INFORMATION pi{};
    std::string mutableCmd = cmd;
    if (!CreateProcessA(nullptr, mutableCmd.data(), nullptr, nullptr, TRUE,
                        CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi)) {
        CloseHandle(readPipe); CloseHandle(writePipe); closesocket(sock); WSACleanup(); return 0;
    }
    CloseHandle(writePipe);
    g_child.store(pi.hProcess);
    killWithSender(pi.hProcess);
    const ULONGLONG started = GetTickCount64();

    AesGcm venc;
    bool encOk = encrypted && venc.init(*g_pairKey);
    uint8_t vPrefix[4] = {0x01, 0, 0, 0};
    if (encOk) BCryptGenRandom(nullptr, vPrefix + 1, 3, BCRYPT_USE_SYSTEM_PREFERRED_RNG);
    uint64_t vCtr = 0;
    std::vector<uint8_t> blob;
    std::vector<unsigned char> out;  // one send() per NAL (encrypted) / per frame (plain)
    bool alive = encrypted ? encOk : true;

    // Encrypted: [4-byte BE length][nonce+ct+tag] per NAL in ONE send().
    // Plain: the frame's NALs go out in ONE send(), followed by an AUD that marks
    // the end of the frame (see kAudH264) so the tablet's byte-stream splitter does
    // not have to wait for the next frame to find the last NAL's end.
    auto sendNal = [&](const unsigned char* nal, size_t len, bool flush, bool frameEnd) {
        if (len == 0 || !alive) return;
        if (encrypted) {
            uint8_t nonce[kGcmNonceLen];
            std::memcpy(nonce, vPrefix, 4);
            ++vCtr;
            for (int i = 0; i < 8; ++i) nonce[4 + i] = static_cast<uint8_t>(vCtr >> (8 * (7 - i)));
            if (!venc.encrypt(nal, static_cast<int>(len), nonce, blob)) return;
            const uint32_t n = static_cast<uint32_t>(blob.size());
            out.resize(4 + blob.size());
            out[0] = static_cast<unsigned char>(n >> 24); out[1] = static_cast<unsigned char>(n >> 16);
            out[2] = static_cast<unsigned char>(n >> 8);  out[3] = static_cast<unsigned char>(n);
            std::memcpy(out.data() + 4, blob.data(), blob.size());
            if (!sendAll(sock, out.data(), static_cast<int>(out.size()))) alive = false;
            return;
        }
        // The encoder may already put an AUD in front of every frame (AMF does). Our
        // own AUD after each frame takes that role, so drop theirs: one delimiter
        // per frame, none duplicated.
        const int sc = annexBStartLen(nal, len);
        const bool isAud = sc > 0 && len > static_cast<size_t>(sc) &&
            (hevc ? (((nal[sc] >> 1) & 0x3F) == 35 && (nal[sc] & 0x80) == 0)
                  : ((nal[sc] & 0x9F) == 0x09));
        if (!isAud) out.insert(out.end(), nal, nal + len);
        if (!flush) return;
        if (out.empty()) return;
        if (frameEnd) {
            if (hevc) out.insert(out.end(), kAudHevc, kAudHevc + sizeof(kAudHevc));
            else out.insert(out.end(), kAudH264, kAudH264 + sizeof(kAudH264));
        }
        if (!sendAll(sock, out.data(), static_cast<int>(out.size()))) alive = false;
        out.clear();
    };

    bool announced = !announceStable;
    pumpAnnexB(readPipe, encrypted ? "tcp-enc" : "tcp", [&] { return !g_stop.load() && alive; },
               [&](const unsigned char* nal, size_t len, bool flush, bool frameEnd) {
                   if (!announced && GetTickCount64() - started >= kProvenUptimeMs) {
                       announced = true;
                       std::cout << "Tablet accepted the pairing code - streaming." << std::endl;
                   }
                   sendNal(nal, len, flush, frameEnd);
               });

    // ffmpeg only exits on its own when ITS pipe breaks. If the tablet dropped the
    // TCP connection (alive == false, e.g. the app restarted), ffmpeg is still
    // running and blocked on the now-undrained pipe — waiting INFINITE here would
    // deadlock the whole session. Kill it so the supervisor can reconnect.
    peerClosed = encrypted && encOk && !alive;
    WaitForSingleObject(pi.hProcess, (g_stop.load() || !alive) ? 0 : INFINITE);
    TerminateProcess(pi.hProcess, 1);  // no-op if it already exited
    ULONGLONG uptime = GetTickCount64() - started;
    DWORD exitCode = 0;
    // A peer disconnect (!alive) is a clean stream end, not an encoder failure —
    // keep the uptime so the supervisor reconnects instead of walking the ladder.
    if (alive && GetExitCodeProcess(pi.hProcess, &exitCode) && exitCode != 0 &&
        exitCode != STILL_ACTIVE) {
        uptime = 0;
    }
    g_child.exchange(nullptr);
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
                  DisplayInfo display) {
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
                     "broken - install the full GPL build (ffmpeg.org or gyan.dev).\n";
        return 3;
    }

    size_t idx = 0;
    bool proven = false;
    int fastFails = 0;
    int shortDrops = 0;             // encrypted TCP: quick closes by the tablet in a row
    bool mismatchReported = false;  // the pairing-mismatch line has been printed

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

        // The tablet is back (or never left): make sure the virtual screen is on.
        // With Wi-Fi the tablet is probed first, but only while the screen is off,
        // so a running link is never disturbed.
        if (!adbMode && options.displayOverride < 0 && !virtualScreenActive()) {
            if (!tabletReachable(host, options.port, 1000)) {
                tabletPresence(false);
                sleepInterruptible(1000);
                continue;
            }
            tabletPresence(true);
        }
        if (!ensureVirtualScreen(options, display)) {
            if (g_stop.load()) break;
            sleepInterruptible(1500);
            continue;
        }

        const std::string cmd = buildStreamCommand(ffmpeg, options, display, attempt, host);
        const bool encTcp = !options.udp && g_pairKey.has_value();
        // Plaintext TCP goes through the sender too (it appends a frame-end marker),
        // unless the dev switch EXTDISPLAY_DIRECT_TCP=1 asks for the old direct path.
        const bool relayTcp = !options.udp && (encTcp || !directTcpDev());
        std::cout << "\nStreaming " << display.name
                  << " with " << attempt.encoder
                  << (attempt.zeroCopy ? " (GPU zero-copy)" : "")
                  << (options.udp ? " over UDP" : (encTcp ? " over TCP (encrypted)" : ""))
                  << " -> " << host << ":" << options.port << "\n";

        ULONGLONG uptime = 0;
        if (options.udp) {
            uptime = runUdpAttempt(cmd, host, options.port);
        } else if (relayTcp) {
            bool peerClosed = false;
            uptime = runEncryptedTcpAttempt(cmd, host, options.port, peerClosed,
                                            encTcp && mismatchReported, options.hevc);
            if (g_stop.load()) break;
            if (peerClosed && uptime < kProvenUptimeMs) {
                // The tablet took the connection and closed it at once. Twice in a
                // row is a pairing mismatch: say so and keep retrying with the SAME
                // encoder (before, this walked the encoder ladder and gave up with
                // "All encoder configurations failed").
                if (++shortDrops >= 2 && !mismatchReported) {
                    mismatchReported = true;
                    std::cout << "Pairing code mismatch - the tablet keeps closing the encrypted "
                                 "stream. Enter this PC's pairing code on the tablet (it is "
                                 "asking for it now); retrying until it is entered." << std::endl;
                }
                if (mismatchReported) {
                    sleepInterruptible(3000);
                    continue;
                }
            } else if (uptime >= kProvenUptimeMs) {
                shortDrops = 0;
                mismatchReported = false;
            }
        } else {
            PROCESS_INFORMATION pi{};
            if (!spawnProcess(cmd, pi)) {
                std::cerr << "Failed to launch ffmpeg.\n";
                return 5;
            }
            g_child.store(pi.hProcess);
            killWithSender(pi.hProcess);
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
            tabletPresence(true);  // it was streaming a moment ago
            std::cout << "Stream ended (tablet unplugged or app closed). Reconnecting...\n";
            if (!adbMode) tabletPresence(false);  // Wi-Fi: start the 5 s clock
            continue;
        }

        // A fast-fail with an unreachable tablet is a disconnect (app closed,
        // screen locked, Wi-Fi blip), NOT an encoder problem — so wait for the
        // tablet to return and retry the SAME config instead of walking the
        // ladder and giving up. (USB also re-waits via adbSetup at the top.)
        if (!tabletReachable(host, options.port, 1000)) {
            std::cout << "Tablet not reachable; waiting to reconnect...\n";
            tabletPresence(false);
            fastFails = 0;
            sleepInterruptible(1500);
            continue;
        }

        tabletPresence(true);  // reachable: an encoder problem, not a missing tablet
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

// Dev-only (--audio-test): opens the same process loopback the audio bridge uses
// (everything except this process tree), keeps the speakers muted for 3 s and
// prints the capture peak, then puts the speakers back exactly as they were. It
// plays no sound itself, so a non-zero peak needs something playing on the PC.
// The mute is applied only if the user had not already muted; the prior mute state
// and master volume are restored and verified.
int runAudioTest() {
    if (FAILED(CoInitializeEx(nullptr, COINIT_MULTITHREADED))) return 1;
    IMMDeviceEnumerator* en = nullptr;
    IMMDevice* dev = nullptr;
    IAudioEndpointVolume* epv = nullptr;
    int rc = 1;
    if (SUCCEEDED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                   __uuidof(IMMDeviceEnumerator), reinterpret_cast<void**>(&en))) &&
        SUCCEEDED(en->GetDefaultAudioEndpoint(eRender, eConsole, &dev)) &&
        SUCCEEDED(dev->Activate(__uuidof(IAudioEndpointVolume), CLSCTX_ALL, nullptr,
                                reinterpret_cast<void**>(&epv)))) {
        BOOL priorMute = FALSE;
        float priorVol = 0.0f;
        epv->GetMute(&priorMute);
        epv->GetMasterVolumeLevelScalar(&priorVol);
        std::cout << "audio-test: before: muted=" << priorMute << " volume=" << priorVol << "\n";

        IAudioClient* client = nullptr;
        IAudioCaptureClient* capture = nullptr;
        WAVEFORMATEX* fmt = nullptr;
        HANDLE ev2 = nullptr;
        if (!openProcessLoopbackExcluding(GetCurrentProcessId(), &client, &capture, &fmt, &ev2)) {
            std::cout << "audio-test: process loopback unavailable on this PC\n";
        } else {
            bool weMuted = false;
            if (!priorMute && SUCCEEDED(epv->SetMute(TRUE, nullptr))) weMuted = true;
            client->Start();
            std::vector<int16_t> pcm;
            float peak = 0.0f;
            UINT64 frames = 0, packets = 0, silentPackets = 0;
            const ULONGLONG end = GetTickCount64() + 3000;
            while (GetTickCount64() < end) {
                UINT32 n = 0;
                while (SUCCEEDED(capture->GetNextPacketSize(&n)) && n > 0) {
                    BYTE* data = nullptr;
                    UINT32 got = 0;
                    DWORD flags = 0;
                    if (FAILED(capture->GetBuffer(&data, &got, &flags, nullptr, nullptr))) break;
                    mixToStereoS16(data, got, fmt, (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0, pcm);
                    capture->ReleaseBuffer(got);
                    for (int16_t v : pcm) {
                        const float a = (v < 0 ? -static_cast<float>(v) : static_cast<float>(v)) / 32768.0f;
                        if (a > peak) peak = a;
                    }
                    frames += got;
                    ++packets;
                    if (flags & AUDCLNT_BUFFERFLAGS_SILENT) ++silentPackets;
                }
                WaitForSingleObject(ev2, 50);  // same wait as the bridge
            }
            client->Stop();
            BOOL nowMuted = FALSE;
            epv->GetMute(&nowMuted);
            std::cout << "audio-test: process loopback ok, endpoint muted during capture="
                      << nowMuted << " packets=" << packets << " (silent " << silentPackets
                      << ") frames=" << frames << " peak=" << peak << "\n";
            if (weMuted) epv->SetMute(FALSE, nullptr);
            BOOL afterMute = FALSE;
            float afterVol = 0.0f;
            epv->GetMute(&afterMute);
            epv->GetMasterVolumeLevelScalar(&afterVol);
            std::cout << "audio-test: after: muted=" << afterMute << " volume=" << afterVol
                      << (afterMute == priorMute && afterVol == priorVol ? " (restored)" : " (DIFFERS)")
                      << "\n";
            if (ev2) CloseHandle(ev2);
            capture->Release();
            client->Release();
            CoTaskMemFree(fmt);
            rc = 0;
        }
    } else {
        std::cout << "audio-test: no default render endpoint\n";
    }
    if (epv) epv->Release();
    if (dev) dev->Release();
    if (en) en->Release();
    CoUninitialize();
    return rc;
}

// Graceful stop for the launcher: a manual-reset named event that the launcher
// signals instead of killing the process. It behaves like Ctrl+C (stop ffmpeg,
// switch the virtual screen off, un-mute) and the process exits 0 within about 2 s
// even when the main thread is stuck in a long blocking call (adb install, UDP
// discovery, encoder probes).
void stopEventWatcher(HANDLE stopEvent) {
    WaitForSingleObject(stopEvent, INFINITE);
    requestStop("stop requested by the launcher");
    Sleep(1600);  // main normally returns well before this
    restoreLocalMuteIfNeeded();
    ExitProcess(0);
}

void startStopEventWatcher() {
    const std::string name = "Local\\ExtendedDisplaySender-Stop-" +
                             std::to_string(GetCurrentProcessId());
    HANDLE ev = CreateEventA(nullptr, TRUE, FALSE, name.c_str());
    if (ev) std::thread(stopEventWatcher, ev).detach();
}

// Common exit path: screen off, then make sure the PC speakers are un-muted. The
// audio thread un-mutes by itself once g_stop is set; give it a moment, then use
// the marker file as the backstop (the process ends when main returns, which would
// otherwise cut the audio thread short).
int finishAndExit(int code, const char* reason) {
    virtualScreenOff(reason);
    for (int i = 0; i < 14 && fileExists(muteMarkerPath()); ++i) Sleep(50);
    restoreLocalMuteIfNeeded();
    return code;
}

// Dev-only: screen on, list, wait, screen off, list. Prints rectangles and timings.
int runScreenTest(const Options& options) {
    g_ccdVerbose = true;
    auto show = [](const char* title) {
        std::cout << title << "\n";
        printDisplays(enumerateDisplays());
        printDisplayRects();
    };
    show("--- before");
    DisplayInfo d;
    const auto t0 = std::chrono::steady_clock::now();
    const PrepResult r = prepareVirtualDisplay(options, d);
    const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - t0).count();
    std::cout << "prepareVirtualDisplay result=" << static_cast<int>(r) << " total " << ms << " ms\n";
    if (r == PrepResult::Ok) {
        show("--- on");
        // Already-on logic: the same mode must send nothing; another mode re-modes.
        std::string detail;
        const ScreenMode same = wantedMode(options);
        const ScreenResult r1 = applyVirtualScreen(same, detail);
        std::cout << "re-apply same mode -> " << (r1 == ScreenResult::Unchanged ? "Unchanged" : "CHANGED/FAILED") << "\n";
        const ScreenMode other = same.w == 1920 ? ScreenMode{2960, 1848, 60} : ScreenMode{1920, 1200, 120};
        const auto t2 = std::chrono::steady_clock::now();
        const ScreenResult r2 = applyVirtualScreen(other, detail);
        const auto ms3 = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - t2).count();
        std::cout << "re-mode to " << other.w << "x" << other.h << "@" << other.hz << " -> "
                  << (r2 == ScreenResult::Switched ? "Switched" : "FAILED " + detail) << " in " << ms3 << " ms\n";
        Sleep(500);
        show("--- re-moded");
        Sleep(1500);
    }
    const auto t1 = std::chrono::steady_clock::now();
    const bool off = virtualScreenOff("screen test finished", true, true);
    const auto ms2 = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - t1).count();
    std::cout << "off switched=" << off << " in " << ms2 << " ms\n";
    show("--- after");
    return r == PrepResult::Ok ? 0 : 2;
}

}  // namespace

int main(int argc, char** argv) {
    // Crypto smoke test (used in CI/dev): verify KDF + AES-GCM before shipping.
    for (int i = 1; i < argc; ++i) {
        if (std::string(argv[i]) == "--crypto-selftest") return cryptoSelfTest();
        // Print the key derived from a code (hex) — used to confirm the Windows and
        // Android KDFs agree. Dev-only.
        if (std::string(argv[i]) == "--derive-key" && i + 1 < argc) {
            std::array<uint8_t, kKeyLen> k{};
            if (!deriveKey(argv[i + 1], k)) { std::cout << "derive failed\n"; return 1; }
            for (uint8_t b : k) printf("%02x", b);
            printf("\n");
            return 0;
        }
    }
    // Without DPI awareness, DesktopCoordinates come back scaled (e.g. a
    // 2560x1600 panel at 150% reports 1536x960) and we'd encode at the wrong size.
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    // Unbuffered output: when the launcher reads it through a pipe, the CRT
    // would otherwise hold status lines in a 4 KB buffer and the GUI status lags.
    setvbuf(stdout, nullptr, _IONBF, 0);
    std::cout << std::unitbuf;
    try {
        Options options = parseArgs(argc, argv);  // host may be filled by --wifi discovery

        // Launcher hook: release everything a killed sender could have left behind.
        if (options.cleanup) {
            const bool wasMuted = fileExists(muteMarkerPath());
            const bool wasOn = virtualScreenOff("cleanup", false, true);
            restoreLocalMuteIfNeeded();
            std::cout << "Cleanup: virtual screen " << (wasOn ? "switched off" : "already off")
                      << ", PC speakers " << (wasMuted ? "un-muted" : "left as they were") << ".\n";
            return 0;
        }
        if (options.listDisplays) {
            printDisplays(enumerateDisplays());
            return 0;
        }
        if (options.audioTest) return runAudioTest();
        if (options.screenTest) return runScreenTest(options);

        SetConsoleCtrlHandler(consoleCtrlHandler, TRUE);
        SetUnhandledExceptionFilter(crashHandler);
        startStopEventWatcher();

        // Pairing: if the GUI (or the user) set a pairing code in EXTDISPLAY_KEY,
        // derive the shared key and encrypt the channels. Passed via env, not the
        // command line, so it never shows in a process listing.
        {
            char* keyEnv = nullptr; size_t keyEnvLen = 0;
            if (_dupenv_s(&keyEnv, &keyEnvLen, "EXTDISPLAY_KEY") == 0 && keyEnv && *keyEnv) {
                std::array<uint8_t, kKeyLen> k{};
                if (deriveKey(keyEnv, k)) {
                    g_pairKey = k;
                    std::cout << "Pairing enabled - encrypting the link (enter the code on the tablet).\n";
                }
                SecureZeroMemory(keyEnv, keyEnvLen);
            }
            if (keyEnv) free(keyEnv);
        }

        // Self-heal: if a previous run muted the PC for tablet-only audio and was
        // force-killed before restoring, un-mute now.
        restoreLocalMuteIfNeeded();

        const std::string exeDir = exeDirectory();

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
            if (g_stop.load()) return finishAndExit(0, "stopped");
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
                    std::cout << "Waiting for a tablet - plug in USB, or open the app "
                                 "on the same Wi-Fi...\n";
                    announced = true;
                }
            }
            if (g_stop.load()) return finishAndExit(0, "stopped");
        }

        // Display. A tablet exists now, so this is the moment the virtual screen is
        // switched on (only its own display path; real monitors are never touched).
        // --display N captures a real display as it is and never switches anything.
        DisplayInfo selected;
        if (options.displayOverride >= 0) {
            const auto displays = enumerateDisplays();
            const auto picked = pickExtendedDisplay(displays, options.displayOverride);
            if (!picked) {
                std::cerr << "Display " << options.displayOverride << " is not available.\n"
                             "Displays found:\n";
                printDisplays(displays);
                return 2;
            }
            selected = *picked;
            std::cout << "Display is not the virtual display; leaving its resolution as is.\n";
            if (options.hdr) {
                bool changed = false;
                if (setAdvancedColor(selected.name, true, &changed)) {
                    std::cout << "HDR enabled on the display.\n";
                    if (changed) Sleep(1500);
                } else {
                    std::cout << "Could not enable HDR automatically. Turn on "
                                 "Settings > Display > Use HDR for the tablet display, "
                                 "or run without --hdr.\n";
                }
            }
            setTouchDisplay(selected);
        } else {
            const PrepResult prep = prepareVirtualDisplay(options, selected);
            if (prep == PrepResult::NoDriver) {
                std::cerr << "The virtual display driver is not loaded. Start from the "
                             "DualSlate app, which loads the driver and then runs "
                             "this sender.\n";
                return 2;
            }
            if (prep != PrepResult::Ok) {
                if (g_stop.load()) return finishAndExit(0, "stopped");
                std::cerr << "Could not switch on the virtual screen.\n";
                return finishAndExit(2, "start failed");
            }
        }

        std::cout << "Extended display: " << selected.name << " "
                  << selected.width << "x" << selected.height
                  << " (adapter " << selected.adapterIndex
                  << ", output " << selected.outputIndex << ")\n";

        if (!options.noTouch) {
            std::thread(runTouchBridge, adb, options.host, options.port + 1,
                        options.host.empty())
                .detach();
            std::cout << "Touch input bridge active (tablet touches control Windows).\n";
        }

        if (options.audio) {
            std::thread(runAudioBridge, adb, options.host, options.port + 3,
                        options.host.empty(), options.muteLocal, options.audioDelayMs)
                .detach();
            std::cout << "Desktop audio bridge active (PC audio plays on the tablet).\n";
        }

        const int exitCode = runSupervised(options, ffmpeg, adb, exeDir, selected);
        return finishAndExit(exitCode, g_stop.load() ? "stopped" : "stream ended");
    } catch (const std::exception& ex) {
        virtualScreenOff("error");
        std::cerr << "Error: " << ex.what() << "\n\n";
        printUsage();
        return 1;
    }
}
