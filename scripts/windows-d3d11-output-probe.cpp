// Bounded interactive hardware draw -> selected display -> DXGI readback proof.
// Shows a temporary animated window. No input, mode changes, networking or saved pixels.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#include <chrono>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <string>

using Microsoft::WRL::ComPtr;
using Clock = std::chrono::steady_clock;

static void check(HRESULT hr, const char* operation) {
    if (FAILED(hr)) {
        std::cerr << operation << ": 0x" << std::hex << static_cast<unsigned long>(hr) << '\n';
        throw std::runtime_error(operation);
    }
}

struct Window {
    HWND handle = nullptr;
    ~Window() { if (handle) DestroyWindow(handle); }
};

struct DisplayAwake {
    EXECUTION_STATE previous = SetThreadExecutionState(ES_CONTINUOUS | ES_DISPLAY_REQUIRED);
    ~DisplayAwake() { if (previous) SetThreadExecutionState(previous); }
};

int main(int argc, char** argv) {
    try {
        if (argc != 2) throw std::runtime_error("usage: windows-d3d11-output-probe.exe DISPLAY_NAME (e.g. \\\\.\\DISPLAY2)");
        DWORD session = 0;
        if (!ProcessIdToSessionId(GetCurrentProcessId(), &session) || session == 0 || session != WTSGetActiveConsoleSessionId())
            throw std::runtime_error("run in the active interactive console session");
        SetProcessDPIAware();
        DisplayAwake awake;
        if (!awake.previous) throw std::runtime_error("display idle request");
        const std::string requested(argv[1]);
        const std::wstring wanted(requested.begin(), requested.end());
        ComPtr<IDXGIFactory1> factory;
        check(CreateDXGIFactory1(IID_PPV_ARGS(&factory)), "DXGI factory");
        ComPtr<IDXGIAdapter1> adapter;
        ComPtr<IDXGIOutput> output;
        DXGI_ADAPTER_DESC1 adapterDesc{};
        DXGI_OUTPUT_DESC outputDesc{};
        for (UINT a = 0; a < 32 && !output; ++a) {
            ComPtr<IDXGIAdapter1> candidate;
            if (factory->EnumAdapters1(a, &candidate) != S_OK) break;
            DXGI_ADAPTER_DESC1 desc{};
            check(candidate->GetDesc1(&desc), "adapter description");
            if (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) continue;
            for (UINT o = 0; o < 32; ++o) {
                ComPtr<IDXGIOutput> candidateOutput;
                if (candidate->EnumOutputs(o, &candidateOutput) != S_OK) break;
                DXGI_OUTPUT_DESC od{};
                check(candidateOutput->GetDesc(&od), "output description");
                if (od.AttachedToDesktop && _wcsicmp(od.DeviceName, wanted.c_str()) == 0) {
                    adapter = candidate; output = candidateOutput; adapterDesc = desc; outputDesc = od;
                    break;
                }
            }
        }
        if (!output || (adapterDesc.VendorId == 0x1414 && adapterDesc.DeviceId == 0x8c))
            throw std::runtime_error("requested output has no hardware adapter; refusing software fallback");
        const UINT width = outputDesc.DesktopCoordinates.right - outputDesc.DesktopCoordinates.left;
        const UINT height = outputDesc.DesktopCoordinates.bottom - outputDesc.DesktopCoordinates.top;
        if (!width || !height || width > 4096 || height > 2160)
            throw std::runtime_error("output outside bounded diagnostic dimensions");
        const wchar_t* className = L"KwD3D11OutputProbe";
        WNDCLASSW wc{}; wc.lpfnWndProc = DefWindowProcW; wc.hInstance = GetModuleHandleW(nullptr); wc.lpszClassName = className;
        if (!RegisterClassW(&wc)) throw std::runtime_error("register window");
        Window window;
        window.handle = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, className, L"GPU output diagnostic (10 seconds)",
            WS_POPUP, outputDesc.DesktopCoordinates.left, outputDesc.DesktopCoordinates.top,
            width, height, nullptr, nullptr, wc.hInstance, nullptr);
        if (!window.handle) throw std::runtime_error("create window");
        ShowWindow(window.handle, SW_SHOWNOACTIVATE);
        if (!SetWindowPos(window.handle, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE))
            throw std::runtime_error("show diagnostic window");
        MONITORINFOEXW monitor{}; monitor.cbSize = sizeof(monitor);
        if (!GetMonitorInfoW(MonitorFromWindow(window.handle, MONITOR_DEFAULTTONULL), &monitor)
            || _wcsicmp(monitor.szDevice, wanted.c_str()) != 0)
            throw std::runtime_error("diagnostic window is not on requested output");
        ComPtr<ID3D11Device> device;
        ComPtr<ID3D11DeviceContext> context;
        ComPtr<IDXGISwapChain> swap;
        DXGI_SWAP_CHAIN_DESC sd{};
        sd.BufferDesc.Width = width; sd.BufferDesc.Height = height;
        sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        sd.SampleDesc.Count = 1; sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        sd.BufferCount = 2; sd.OutputWindow = window.handle; sd.Windowed = TRUE;
        check(D3D11CreateDeviceAndSwapChain(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr,
            D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION,
            &sd, &swap, &device, nullptr, &context), "create hardware swap chain");
        ComPtr<ID3D11Texture2D> back;
        check(swap->GetBuffer(0, IID_PPV_ARGS(&back)), "swap-chain back buffer");
        ComPtr<ID3D11RenderTargetView> view;
        check(device->CreateRenderTargetView(back.Get(), nullptr, &view), "render view");
        const char* shader = R"(
cbuffer Colour : register(b0) { float4 colour; }
float4 vs(uint id : SV_VertexID) : SV_Position {
    float2 p = float2((id << 1) & 2, id & 2);
    return float4(p * float2(2, -2) + float2(-1, 1), 0, 1);
}
float4 ps(float4 p : SV_Position) : SV_Target { return colour; }
)";
        ComPtr<ID3DBlob> vsCode, psCode, errors;
        check(D3DCompile(shader, std::strlen(shader), nullptr, nullptr, nullptr, "vs", "vs_5_0", 0, 0, &vsCode, &errors), "compile VS");
        errors.Reset();
        check(D3DCompile(shader, std::strlen(shader), nullptr, nullptr, nullptr, "ps", "ps_5_0", 0, 0, &psCode, &errors), "compile PS");
        ComPtr<ID3D11VertexShader> vs;
        ComPtr<ID3D11PixelShader> ps;
        check(device->CreateVertexShader(vsCode->GetBufferPointer(), vsCode->GetBufferSize(), nullptr, &vs), "vertex shader");
        check(device->CreatePixelShader(psCode->GetBufferPointer(), psCode->GetBufferSize(), nullptr, &ps), "pixel shader");
        D3D11_BUFFER_DESC cb{}; cb.ByteWidth = 16; cb.Usage = D3D11_USAGE_DEFAULT; cb.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
        ComPtr<ID3D11Buffer> colour;
        check(device->CreateBuffer(&cb, nullptr, &colour), "colour buffer");
        ID3D11RenderTargetView* rawView = view.Get();
        ID3D11Buffer* rawColour = colour.Get();
        context->OMSetRenderTargets(1, &rawView, nullptr);
        context->PSSetConstantBuffers(0, 1, &rawColour);
        context->VSSetShader(vs.Get(), nullptr, 0); context->PSSetShader(ps.Get(), nullptr, 0);
        context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        D3D11_VIEWPORT vp{0, 0, static_cast<float>(width), static_cast<float>(height), 0, 1};
        context->RSSetViewports(1, &vp);
        ComPtr<IDXGIOutput1> output1;
        ComPtr<IDXGIOutputDuplication> duplication;
        check(output.As(&output1), "query output duplication");
        check(output1->DuplicateOutput(device.Get(), &duplication), "duplicate selected hardware output");
        D3D11_TEXTURE2D_DESC td{}; td.Width = 1; td.Height = 1; td.MipLevels = 1; td.ArraySize = 1;
        td.Format = DXGI_FORMAT_B8G8R8A8_UNORM; td.SampleDesc.Count = 1;
        td.Usage = D3D11_USAGE_STAGING; td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        ComPtr<ID3D11Texture2D> staging;
        check(device->CreateTexture2D(&td, nullptr, &staging), "readback pixel");
        const auto start = Clock::now();
        unsigned draws = 0, captures = 0, red = 0, green = 0, occluded = 0;
        while (Clock::now() - start < std::chrono::seconds(10)) {
            MSG msg{}; while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageW(&msg); }
            const bool phase = (std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - start).count() / 500) % 2;
            const float c[] = {phase ? 1.0f : 0.0f, phase ? 0.0f : 1.0f, 0.0f, 1.0f};
            context->UpdateSubresource(colour.Get(), 0, nullptr, c, 0, 0);
            context->Draw(3, 0);
            const HRESULT presented = swap->Present(1, 0);
            check(presented, "present hardware draw"); ++draws;
            occluded += presented == DXGI_STATUS_OCCLUDED;
            DXGI_OUTDUPL_FRAME_INFO info{};
            ComPtr<IDXGIResource> resource;
            HRESULT acquired = duplication->AcquireNextFrame(50, &info, &resource);
            if (acquired == DXGI_ERROR_WAIT_TIMEOUT) continue;
            check(acquired, "acquire desktop frame");
            ComPtr<ID3D11Texture2D> desktop;
            const HRESULT textureResult = resource.As(&desktop);
            if (FAILED(textureResult)) { duplication->ReleaseFrame(); check(textureResult, "desktop texture"); }
            D3D11_BOX box{width / 2, height / 2, 0, width / 2 + 1, height / 2 + 1, 1};
            context->CopySubresourceRegion(staging.Get(), 0, 0, 0, 0, desktop.Get(), 0, &box);
            D3D11_MAPPED_SUBRESOURCE pixel{};
            const HRESULT mapped = context->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &pixel);
            if (SUCCEEDED(mapped)) {
                const auto* p = static_cast<const unsigned char*>(pixel.pData);
                red += p[2] > 220 && p[1] < 35 && p[0] < 35;
                green += p[1] > 220 && p[2] < 35 && p[0] < 35;
                context->Unmap(staging.Get(), 0); ++captures;
            }
            check(duplication->ReleaseFrame(), "release capture frame");
            check(mapped, "map captured pixel");
            check(device->GetDeviceRemovedReason(), "device health");
        }
        std::cout << "{\"schemaVersion\":1,\"sessionId\":" << session
            << ",\"vendorId\":" << adapterDesc.VendorId << ",\"deviceId\":" << adapterDesc.DeviceId
            << ",\"luidHigh\":" << adapterDesc.AdapterLuid.HighPart << ",\"luidLow\":" << adapterDesc.AdapterLuid.LowPart
            << ",\"width\":" << width << ",\"height\":" << height << ",\"drawsPresented\":" << draws
            << ",\"capturedFrames\":" << captures << ",\"redContentFrames\":" << red << ",\"greenContentFrames\":" << green
            << ",\"occludedPresents\":" << occluded
            << ",\"contentValidated\":" << (red > 2 && green > 2 ? "true" : "false")
            << ",\"limitations\":[\"Synthetic hardware draw and desktop capture, not a real application benchmark\","
               "\"No encoder, transport, viewer, input or audio acceptance\"]}\n";
        if (red <= 2 || green <= 2) throw std::runtime_error("animated rendered content not verified in desktop capture");
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
