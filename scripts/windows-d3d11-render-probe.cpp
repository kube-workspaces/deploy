// Bounded off-screen D3D11 draw/readback comparison. No display/input/network changes.
// Reports synchronized draw+readback wall times, not application or streaming FPS.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <dxgi.h>
#include <wrl/client.h>
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

using Microsoft::WRL::ComPtr;
using Clock = std::chrono::steady_clock;
constexpr UINT width = 1920, height = 1080;

static void check(HRESULT result, const char* operation) {
    if (FAILED(result)) {
        std::cerr << operation << " failed: 0x" << std::hex
                  << static_cast<unsigned long>(result) << '\n';
        throw std::runtime_error(operation);
    }
}

static UINT hex_id(const char* value) {
    char* end = nullptr;
    const unsigned long number = std::strtoul(value, &end, 16);
    if (!*value || *end || number > 0xffff) throw std::runtime_error("invalid PCI ID");
    return static_cast<UINT>(number);
}

static const char* shader = R"(
float4 vs(uint id : SV_VertexID) : SV_Position {
    float2 p = float2((id << 1) & 2, id & 2);
    return float4(p * float2(2, -2) + float2(-1, 1), 0, 1);
}
float4 ps(float4 p : SV_Position) : SV_Target {
    float3 c = float3(p.x / 1920.0, p.y / 1080.0, 0.5);
    [loop] for (uint i = 0; i < 32; ++i)
        c = frac(c.yzx * float3(1.17, 1.23, 1.31) + float3(0.11, 0.07, 0.03));
    return float4(c, 1);
}
)";

struct Result {
    std::vector<double> samples;
    double elapsed = 0;
    std::uint64_t checksum = 0;
    UINT vendor = 0, device = 0, feature = 0;
    LONG luidHigh = 0;
    DWORD luidLow = 0;
    bool software = false;
    bool nonuniform = false;
};

static Result render(IDXGIAdapter* adapter, bool warp, int seconds) {
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_0};
    D3D_FEATURE_LEVEL feature{};
    check(D3D11CreateDevice(adapter, warp ? D3D_DRIVER_TYPE_WARP : D3D_DRIVER_TYPE_UNKNOWN,
        nullptr, 0, levels, 1, D3D11_SDK_VERSION, &device, &feature, &context), "create D3D11 device");
    ComPtr<IDXGIDevice> dxgi;
    ComPtr<IDXGIAdapter> actual;
    DXGI_ADAPTER_DESC description{};
    check(device.As(&dxgi), "query DXGI device");
    check(dxgi->GetAdapter(&actual), "get actual adapter");
    check(actual->GetDesc(&description), "get adapter description");
    ComPtr<IDXGIAdapter1> adapter1;
    DXGI_ADAPTER_DESC1 desc1{};
    check(actual.As(&adapter1), "query adapter flags");
    check(adapter1->GetDesc1(&desc1), "get adapter flags");
    Result result;
    result.vendor = description.VendorId;
    result.device = description.DeviceId;
    result.luidHigh = description.AdapterLuid.HighPart;
    result.luidLow = description.AdapterLuid.LowPart;
    result.feature = feature;
    result.software = (desc1.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0;
    if (!warp && result.software) throw std::runtime_error("hardware request resolved to software");
    if (warp && !result.software) throw std::runtime_error("WARP request did not resolve to software");

    ComPtr<ID3DBlob> vsCode, psCode, errors;
    check(D3DCompile(shader, std::strlen(shader), nullptr, nullptr, nullptr, "vs", "vs_5_0",
        D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &vsCode, &errors), "compile vertex shader");
    errors.Reset();
    check(D3DCompile(shader, std::strlen(shader), nullptr, nullptr, nullptr, "ps", "ps_5_0",
        D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &psCode, &errors), "compile pixel shader");
    ComPtr<ID3D11VertexShader> vs;
    ComPtr<ID3D11PixelShader> ps;
    check(device->CreateVertexShader(vsCode->GetBufferPointer(), vsCode->GetBufferSize(), nullptr, &vs), "create vertex shader");
    check(device->CreatePixelShader(psCode->GetBufferPointer(), psCode->GetBufferSize(), nullptr, &ps), "create pixel shader");
    D3D11_TEXTURE2D_DESC desc{};
    desc.Width = width; desc.Height = height; desc.MipLevels = 1; desc.ArraySize = 1;
    desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM; desc.SampleDesc.Count = 1;
    desc.Usage = D3D11_USAGE_DEFAULT; desc.BindFlags = D3D11_BIND_RENDER_TARGET;
    ComPtr<ID3D11Texture2D> target, staging;
    check(device->CreateTexture2D(&desc, nullptr, &target), "create render target");
    desc.Usage = D3D11_USAGE_STAGING; desc.BindFlags = 0; desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    check(device->CreateTexture2D(&desc, nullptr, &staging), "create staging texture");
    ComPtr<ID3D11RenderTargetView> view;
    check(device->CreateRenderTargetView(target.Get(), nullptr, &view), "create render view");
    D3D11_RASTERIZER_DESC raster{};
    raster.FillMode = D3D11_FILL_SOLID; raster.CullMode = D3D11_CULL_NONE;
    raster.DepthClipEnable = TRUE;
    ComPtr<ID3D11RasterizerState> rasterState;
    check(device->CreateRasterizerState(&raster, &rasterState), "create rasterizer");
    context->RSSetState(rasterState.Get());
    D3D11_VIEWPORT viewport{0, 0, static_cast<float>(width), static_cast<float>(height), 0, 1};
    context->RSSetViewports(1, &viewport);
    ID3D11RenderTargetView* rawView = view.Get();
    context->OMSetRenderTargets(1, &rawView, nullptr);
    context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    context->VSSetShader(vs.Get(), nullptr, 0);
    context->PSSetShader(ps.Get(), nullptr, 0);

    auto frame = [&]() {
        const float clear[] = {0, 0, 0, 0};
        context->ClearRenderTargetView(view.Get(), clear);
        context->Draw(3, 0);
        context->CopyResource(staging.Get(), target.Get());
        D3D11_MAPPED_SUBRESOURCE mapped{};
        // Map waits for GPU completion, bounding the queue to one frame.
        check(context->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped), "read completed draw");
        const auto* pixels = static_cast<const unsigned char*>(mapped.pData);
        std::uint32_t first = 0;
        std::memcpy(&first, pixels, sizeof(first));
        std::uint64_t hash = 14695981039346656037ULL;
        bool varied = false, alpha = true;
        for (UINT y = 0; y < height; ++y) {
            const auto* row = pixels + y * mapped.RowPitch;
            // Sample a fixed grid without saving image content.
            if (y % 31 != 0 && y != height - 1) continue;
            for (UINT x = 0; x < width; x += 31) {
                std::uint32_t pixel = 0;
                std::memcpy(&pixel, row + x * 4, sizeof(pixel));
                varied = varied || pixel != first;
                alpha = alpha && row[x * 4 + 3] == 255;
                hash = (hash ^ pixel) * 1099511628211ULL;
            }
        }
        context->Unmap(staging.Get(), 0);
        check(device->GetDeviceRemovedReason(), "device health");
        if (!alpha || !varied) throw std::runtime_error("rendered content validation failed");
        result.checksum = hash;
        result.nonuniform = varied;
    };
    for (int i = 0; i < 3; ++i) frame(); // Exclude device/shader warmup.
    const auto begin = Clock::now();
    do {
        const auto start = Clock::now();
        frame();
        result.samples.push_back(std::chrono::duration<double, std::milli>(Clock::now() - start).count());
        result.elapsed = std::chrono::duration<double>(Clock::now() - begin).count();
    } while (result.elapsed < seconds && result.samples.size() < 100000);
    return result;
}

static void report(const Result& result) {
    auto sorted = result.samples;
    std::sort(sorted.begin(), sorted.end());
    auto percentile = [&](double p) { return sorted[static_cast<size_t>((sorted.size() - 1) * p)]; };
    std::cout << "{\"vendorId\":" << result.vendor << ",\"deviceId\":" << result.device
        << ",\"luidHigh\":" << result.luidHigh << ",\"luidLow\":" << result.luidLow
        << ",\"softwareFlag\":" << (result.software ? "true" : "false")
        << ",\"featureLevel\":" << result.feature << ",\"frames\":" << result.samples.size()
        << ",\"elapsedSeconds\":" << result.elapsed
        << ",\"synchronizedDrawReadbackFps\":" << result.samples.size() / result.elapsed
        << ",\"frameMsP50\":" << percentile(0.50) << ",\"frameMsP95\":" << percentile(0.95)
        << ",\"sampleChecksum\":" << result.checksum << ",\"contentValidated\":true}";
}

int main(int argc, char** argv) {
    try {
        if (argc != 4) throw std::runtime_error("usage: windows-d3d11-render-probe.exe VENDOR_HEX DEVICE_HEX SECONDS_1_TO_10");
        const UINT vendor = hex_id(argv[1]), pciDevice = hex_id(argv[2]);
        char* end = nullptr;
        const long seconds = std::strtol(argv[3], &end, 10);
        if (!*argv[3] || *end || seconds < 1 || seconds > 10) throw std::runtime_error("invalid seconds (1..10)");
        ComPtr<IDXGIFactory1> factory;
        check(CreateDXGIFactory1(IID_PPV_ARGS(&factory)), "create DXGI factory");
        ComPtr<IDXGIAdapter1> selected;
        for (UINT i = 0; i < 32; ++i) {
            ComPtr<IDXGIAdapter1> candidate;
            if (factory->EnumAdapters1(i, &candidate) == DXGI_ERROR_NOT_FOUND) break;
            if (!candidate) continue;
            DXGI_ADAPTER_DESC1 desc{};
            check(candidate->GetDesc1(&desc), "enumerate adapter");
            if (desc.VendorId == vendor && desc.DeviceId == pciDevice && !(desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE)) {
                selected = candidate;
                break;
            }
        }
        if (!selected) throw std::runtime_error("requested hardware adapter not found; refusing fallback");
        const Result hardware = render(selected.Get(), false, static_cast<int>(seconds));
        const Result warp = render(nullptr, true, static_cast<int>(seconds));
        std::cout << std::setprecision(8) << "{\"schemaVersion\":1,\"width\":" << width
            << ",\"height\":" << height << ",\"pixelShaderIterations\":32,\"requestedSecondsPerAdapter\":" << seconds
            << ",\"hardware\":";
        report(hardware);
        std::cout << ",\"warp\":";
        report(warp);
        std::cout << ",\"hardwareOverWarpThroughput\":"
            << (hardware.samples.size() / hardware.elapsed) / (warp.samples.size() / warp.elapsed)
            << ",\"limitations\":[\"Off-screen synthetic draw plus synchronized CPU readback, not application or streaming FPS\","
               "\"Wall time includes driver synchronization, readback and content checks; no GPU timestamp claim\","
               "\"Session 0 can test off-screen rendering but cannot prove interactive capture\","
               "\"A driver call may hang; run under an external process watchdog\"]}\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
