// Bounded P0 diagnostic, not an agent: no networking, input, mode changes or pixels saved.
// Run in the disposable guest's interactive console. Default is inventory only.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mmdeviceapi.h>
#include <initguid.h>
#include <functiondiscoverykeys_devpkey.h>
#include <wrl/client.h>
#include <chrono>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>

using Microsoft::WRL::ComPtr;
using Clock = std::chrono::steady_clock;

static std::string quote(const wchar_t* value) {
    if (!value) return "null";
    int n = WideCharToMultiByte(CP_UTF8, 0, value, -1, nullptr, 0, nullptr, nullptr);
    std::string utf8(n > 0 ? n : 1, '\0');
    if (n > 0) WideCharToMultiByte(CP_UTF8, 0, value, -1, &utf8[0], n, nullptr, nullptr);
    std::ostringstream result;
    result << '"';
    for (int i = 0; i < n - 1; ++i) {
        unsigned char c = static_cast<unsigned char>(utf8[i]);
        if (c == '"' || c == '\\') result << '\\' << c;
        else if (c < 32) result << "\\u" << std::hex << std::setw(4)
                                << std::setfill('0') << static_cast<int>(c) << std::dec;
        else result << c;
    }
    result << '"';
    return result.str();
}

static std::string hr(HRESULT value) {
    std::ostringstream result;
    result << '"' << "0x" << std::hex << std::setw(8) << std::setfill('0')
           << static_cast<unsigned long>(value) << '"';
    return result.str();
}

static void graphics(int seconds) {    ComPtr<IDXGIFactory1> factory;
    HRESULT status = CreateDXGIFactory1(IID_PPV_ARGS(&factory));
    std::cout << "\"dxgiFactoryResult\":" << hr(status) << ",\"adapters\":[";
    bool firstAdapter = true;
    // Total capture budget is shared across outputs, not multiplied per monitor.
    auto deadline = Clock::now() + std::chrono::seconds(seconds);
    if (SUCCEEDED(status)) for (UINT i = 0; i < 32; ++i) {
        ComPtr<IDXGIAdapter1> adapter;
        if (factory->EnumAdapters1(i, &adapter) != S_OK) break;
        DXGI_ADAPTER_DESC1 desc{};
        if (FAILED(adapter->GetDesc1(&desc))) continue;
        if (!firstAdapter) std::cout << ',';
        firstAdapter = false;
        ComPtr<ID3D11Device> device;
        D3D_FEATURE_LEVEL level{};
        HRESULT create = D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN,
            nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION,
            &device, &level, nullptr);
        std::cout << "{\"description\":" << quote(desc.Description)
                  << ",\"vendorId\":" << desc.VendorId << ",\"deviceId\":" << desc.DeviceId
                  << ",\"luidHigh\":" << desc.AdapterLuid.HighPart
                  << ",\"luidLow\":" << desc.AdapterLuid.LowPart
                  << ",\"dedicatedVideoMemoryBytes\":" << desc.DedicatedVideoMemory
                  << ",\"softwareFlag\":" << ((desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) ? "true" : "false")
                  << ",\"d3d11CreateResult\":" << hr(create)
                  << ",\"d3dFeatureLevel\":" << static_cast<unsigned>(level);
            // D3D12 on the same enumerated adapter (dynamic load: no SDK header/link needed).
            {
                HMODULE d3d12 = LoadLibraryW(L"d3d12.dll");
                if (d3d12) {
                    typedef HRESULT(WINAPI* CreateFn)(IUnknown*, unsigned, const IID&, void**);
                    CreateFn create12 = reinterpret_cast<CreateFn>(reinterpret_cast<void*>(GetProcAddress(d3d12, "D3D12CreateDevice")));
                    // D3D_FEATURE_LEVEL_11_0 = 0xb000; IID_ID3D12Device inline to avoid d3d12.h.
                    static const GUID IID_ID3D12Device = {0x189819f1, 0x1db6, 0x4b57,
                        {0xbe, 0x54, 0x18, 0x21, 0x33, 0x9b, 0x85, 0xf7}};
                    void* device12 = nullptr;
                    HRESULT r12 = create12
                        ? create12(adapter.Get(), 0xb000, IID_ID3D12Device, &device12)
                        : E_NOTIMPL;
                    if (device12) reinterpret_cast<IUnknown*>(device12)->Release();
                    std::cout << ",\"d3d12CreateResult\":" << hr(r12);
                    FreeLibrary(d3d12);
                } else {
                    std::cout << ",\"d3d12CreateResult\":\"d3d12.dll-absent\"";
                }
            }
            std::cout << ",\"outputs\":[";
        bool firstOutput = true;
        for (UINT j = 0; j < 32; ++j) {
            ComPtr<IDXGIOutput> output;
            if (adapter->EnumOutputs(j, &output) != S_OK) break;
            DXGI_OUTPUT_DESC od{};
            if (FAILED(output->GetDesc(&od))) continue;
            if (!firstOutput) std::cout << ',';
            firstOutput = false;
            std::cout << "{\"name\":" << quote(od.DeviceName)
                      << ",\"attached\":" << (od.AttachedToDesktop ? "true" : "false")
                      << ",\"width\":" << od.DesktopCoordinates.right - od.DesktopCoordinates.left
                      << ",\"height\":" << od.DesktopCoordinates.bottom - od.DesktopCoordinates.top;
            std::cout << ",\"displayModes\":[";
            DEVMODEW mode{};
            mode.dmSize = sizeof(mode);
            bool firstMode = true;
            for (DWORD m = 0; m < 512 && EnumDisplaySettingsW(od.DeviceName, m, &mode); ++m) {
                if (!firstMode) std::cout << ',';
                firstMode = false;
                std::cout << "{\"width\":" << mode.dmPelsWidth << ",\"height\":" << mode.dmPelsHeight
                          << ",\"refreshHz\":" << mode.dmDisplayFrequency
                          << ",\"bitsPerPixel\":" << mode.dmBitsPerPel << '}';
            }
            std::cout << ']';
            bool attempt = seconds > 0 && device && od.AttachedToDesktop && Clock::now() < deadline;
            std::cout << ",\"captureAttempted\":" << (attempt ? "true" : "false");
            if (attempt) {
                ComPtr<IDXGIOutput1> output1;
                ComPtr<IDXGIOutputDuplication> duplication;
                HRESULT duplicate = output.As(&output1);
                if (SUCCEEDED(duplicate)) duplicate = output1->DuplicateOutput(device.Get(), &duplication);
                std::cout << ",\"duplicateOutputResult\":" << hr(duplicate);
                unsigned frames = 0, timeouts = 0;
                unsigned long long accumulated = 0;
                HRESULT acquire = duplicate;
                auto started = Clock::now();
                if (SUCCEEDED(duplicate)) while (Clock::now() < deadline) {
                    DXGI_OUTDUPL_FRAME_INFO info{};
                    ComPtr<IDXGIResource> frame;
                    acquire = duplication->AcquireNextFrame(50, &info, &frame);
                    if (acquire == DXGI_ERROR_WAIT_TIMEOUT) { ++timeouts; continue; }
                    if (FAILED(acquire)) break;
                    ++frames;
                    accumulated += info.AccumulatedFrames;
                    HRESULT release = duplication->ReleaseFrame();
                    if (FAILED(release)) { acquire = release; break; }
                }
                auto elapsed = std::chrono::duration<double>(Clock::now() - started).count();
                std::cout << ",\"acquiredFrames\":" << frames << ",\"accumulatedFrames\":" << accumulated
                          << ",\"waitTimeouts\":" << timeouts << ",\"lastAcquireResult\":" << hr(acquire)
                          << ",\"captureSeconds\":" << elapsed;
            }
            std::cout << '}';
        }
        std::cout << "]}";
    }
    ComPtr<ID3D11Device> warp;
    D3D_FEATURE_LEVEL level{};
    HRESULT result = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, 0,
        nullptr, 0, D3D11_SDK_VERSION, &warp, &level, nullptr);
    std::cout << "],\"warpCreateResult\":" << hr(result)
              << ",\"warpFeatureLevel\":" << static_cast<unsigned>(level);
}

static void audio() {
    ComPtr<IMMDeviceEnumerator> enumerator;
    HRESULT result = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
        CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&enumerator));
    ComPtr<IMMDeviceCollection> endpoints;
    if (SUCCEEDED(result)) result = enumerator->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &endpoints);
    std::cout << ",\"activeRenderEndpointResult\":" << hr(result) << ",\"activeRenderEndpoints\":[";
    UINT count = 0;
    if (SUCCEEDED(result)) endpoints->GetCount(&count);
    bool first = true;
    for (UINT i = 0; i < count && i < 64; ++i) {
        ComPtr<IMMDevice> endpoint;
        ComPtr<IPropertyStore> properties;
        if (FAILED(endpoints->Item(i, &endpoint))) continue;
        if (!first) std::cout << ',';
        first = false;
        PROPVARIANT name;
        PropVariantInit(&name);
        HRESULT named = endpoint->OpenPropertyStore(STGM_READ, &properties);
        if (SUCCEEDED(named)) named = properties->GetValue(PKEY_Device_FriendlyName, &name);
        std::cout << "{\"name\":" << (SUCCEEDED(named) && name.vt == VT_LPWSTR ? quote(name.pwszVal) : "null")
                  << ",\"nameResult\":" << hr(named) << '}';
        PropVariantClear(&name);
    }
    std::cout << ']';
}

static void renderAPIs() {
    // Vulkan enumeration via the loader only (dynamic load, no SDK needed).
    // OpenGL is reported as Intel ICD file evidence only: a real context needs
    // a drawable, which Session 0 has none of. Neither proves app rendering.
    std::cout << ",\"vulkan\":{";
    HMODULE loader = LoadLibraryW(L"vulkan-1.dll");
    if (!loader) {
        std::cout << "\"loaderPresent\":false}";
    } else {
        typedef int(WINAPI* VkCreateFn)(const void*, const void*, void**);
        typedef void(WINAPI* VkDestroyFn)(void*, const void*);
        typedef int(WINAPI* VkEnumFn)(void*, unsigned*, void*);
        VkCreateFn create = reinterpret_cast<VkCreateFn>(reinterpret_cast<void*>(GetProcAddress(loader, "vkCreateInstance")));
        std::cout << "\"loaderPresent\":true,\"createInstanceResult\":";
        void* instance = nullptr;
        // Minimal VkApplicationInfo + VkInstanceCreateInfo (sType 0/1, apiVersion 1.0).
        struct AppInfo { int sType; const void* next; const char* name; unsigned ver;
                         const char* eng; unsigned engVer; unsigned api; } app{0, nullptr, "probe", 1,
                         "probe", 1, 0x00400000};
        struct InstInfo { int sType; const void* next; unsigned flags; const AppInfo* app;
                          unsigned layerCount; const char* const* layers;
                          unsigned extCount; const char* const* exts; } inst{1, nullptr, 0, &app, 0, nullptr, 0, nullptr};
        int created = create ? create(&inst, nullptr, &instance) : -1;
        std::cout << created;
        if (created == 0 && instance) {
            VkEnumFn enumerate = reinterpret_cast<VkEnumFn>(reinterpret_cast<void*>(GetProcAddress(loader, "vkEnumeratePhysicalDevices")));
            unsigned count = 0;
            int listed = enumerate ? enumerate(instance, &count, nullptr) : -1;
            std::cout << ",\"enumerateResult\":" << listed << ",\"deviceCount\":" << count;
            VkDestroyFn destroy = reinterpret_cast<VkDestroyFn>(reinterpret_cast<void*>(GetProcAddress(loader, "vkDestroyInstance")));
            if (destroy) destroy(instance, nullptr);
        }
        std::cout << '}';
        FreeLibrary(loader);
    }
    wchar_t systemDir[MAX_PATH]{};
    std::string icd = "absent";
    if (GetSystemDirectoryW(systemDir, MAX_PATH)) {
        std::wstring path = std::wstring(systemDir) + L"\\ig9icd64.dll";
        DWORD attrs = GetFileAttributesW(path.c_str());
        if (attrs != INVALID_FILE_ATTRIBUTES) {
            DWORD ver = 0, size = GetFileVersionInfoSizeW(path.c_str(), &ver);
            icd = size ? "present-with-version-info" : "present-no-version-info";
        }
    }
    std::cout << ",\"openGLIntelICD\":\"" << icd << '"';
}

static void encoders() {
    HRESULT startup = MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET);
    std::cout << ",\"mediaFoundationStartupResult\":" << hr(startup);
    if (FAILED(startup)) return;
    IMFActivate** transforms = nullptr;
    UINT count = 0;
    MFT_REGISTER_TYPE_INFO output{MFMediaType_Video, MFVideoFormat_H264};
    HRESULT result = MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER,
        MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_ASYNCMFT | MFT_ENUM_FLAG_LOCALMFT | MFT_ENUM_FLAG_SORTANDFILTER,
        nullptr, &output, &transforms, &count);
    std::cout << ",\"softwareH264EnumerationResult\":" << hr(result) << ",\"softwareH264Candidates\":[";
    for (UINT i = 0; i < count; ++i) {
        wchar_t* name = nullptr;
        UINT length = 0;
        if (i < 64) {
            if (i) std::cout << ',';
            HRESULT named = transforms[i]->GetAllocatedString(MFT_FRIENDLY_NAME_Attribute, &name, &length);
            std::cout << "{\"name\":" << quote(name) << ",\"nameResult\":" << hr(named) << '}';
        }
        CoTaskMemFree(name);
        transforms[i]->Release();
    }
    CoTaskMemFree(transforms);
    std::cout << ']';
    MFShutdown();
}

int main(int argc, char** argv) {
    int seconds = 0;
    if (argc == 3 && std::string(argv[1]) == "--capture-seconds") {
        char* end = nullptr;
        long value = std::strtol(argv[2], &end, 10);
        if (!*argv[2] || *end || value < 1 || value > 10) return 2;
        seconds = static_cast<int>(value);
    } else if (argc != 1) {
        std::cerr << "Usage: windows-premium-probe.exe [--capture-seconds 1..10]\n";
        return 2;
    }
    HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(com)) { std::cerr << "COM initialization failed\n"; return 1; }
    DWORD session = 0;
    ProcessIdToSessionId(GetCurrentProcessId(), &session);
    std::cout << "{\"schemaVersion\":2,\"processSessionId\":" << session
              << ",\"activeConsoleSessionId\":" << WTSGetActiveConsoleSessionId()
              << ",\"requestedCaptureSeconds\":" << seconds << ',';
    graphics(seconds);
    audio();
    encoders();
    renderAPIs();
    std::cout << ",\"limitations\":[\"Inventory/capture availability only, not encode or rendering benchmarks\","
                 "\"No pixels saved; static screens may yield few capture frames\","
                 "\"Software encoder candidates are not proven activated encoders\","
                 "\"Render endpoint presence is not WASAPI loopback or playback acceptance\","
                 "\"Vulkan/OpenGL results are API availability, not app-rendering proof\","
                 "\"Session 0 is not interactive-console capture acceptance\"]}\n";
    CoUninitialize();
    return 0;
}
