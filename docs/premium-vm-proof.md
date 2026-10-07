# Premium VM proof runbook

Use a disposable Windows clone for the initial same-console streaming proof.
Keep the sealed source stopped, the existing Windows workspace on VNC, and Linux
Selkies available. These are diagnostic steps, not an enabled premium profile.

## Capacity and recovery gate

1. Select an eligible non-control-plane worker. Inspect `kubectl top nodes`,
   host `MemAvailable`, swap/load, pod reservations, quota and physical free disk.
   Reserve 4 vCPU / 8Gi guest RAM plus launcher and host/workload headroom for the
   software reference. A 2-vCPU/4Gi exploratory run must be explicitly recorded
   as below-reference; it cannot certify the reference performance target.
2. Verify both root and backend-state PV node affinity; local-path roots cannot
   be moved simply by changing a node selector. Reuse only a designated disposable
   clone with preserved root/EFI/TPM identity, or make a fresh isolated import.
3. Run `scripts/windows-vm-proof.py preflight --help` and its read-only preflight
   for the selected worker. Confirm current version-specific KubeVirt/CDI schema,
   import credentials/CA availability, artifact digest and certificate validity.
4. Record the initial VM spec, root/state UIDs and display topology. Establish
   direct VNC recovery before changing hardware or installing a driver. Bound
   each trial and stop on host pressure, security bypass or unrecoverable console.

## P0 evidence sequence

| Trial | Evidence to retain privately | Decision gate |
|---|---|---|
| Baseline | Same motion/text/audio workload, VNC and matched Linux Selkies; actual mode list, DXGI adapters, WARP, audio render endpoints; delivered FPS/bitrate, CPU/RAM and input latency | Negotiated FPS, CIM/dxdiag feature strings and client scaling are not acceptance |
| Capture | DXGI Desktop Duplication and WGC/GStreamer on Basic Display Adapter; exact HRESULT/output adapter, frame timestamps and capture/encode costs | Session-0 guest-agent commands cannot establish interactive-console capture |
| Software media | Actual software H.264 encoder plus WASAPI render-loopback/48kHz stereo Opus, no B-frame reorder; pinned binary hashes and dependency/license manifest | `mfh264enc` presence is not software fallback; enumerate a real render endpoint first |
| Audio hardware | Disposable stopped clone only: validate KubeVirt 1.9 `ich9` sound device and inbox guest driver, then endpoint/silence/device-change behavior | No blanket hardware mutation of existing Windows v1 |
| Display driver | Verify architecture, INF/catalog membership, Windows kernel-policy signature, Secure Boot/Memory Integrity before and after install; modes, 20 resize cycles, Sysprep and uninstall/watchdog restore | A published digest or signed badge does not validate the installed driver |
| Secure states | Login/logout/lock/UAC/SAS, capture-loss and agent crash; actual VGA vs IDD output and labeled VNC handover | Never disable UAC/Secure Boot or silently replace the console with RDP |
| Viewers/transport | Native diagnostic and real Chromium; codec config + IDR and actual-mode ACK; LAN then 50/100ms RTT, bandwidth caps and 1% loss for identical WSS/WebRTC runs | Freeze transport only from latency/audio/queue results; browser feature detection alone is not decode proof |

Record requested and actual sizes, p50/p95/p99 timings, delivered vs rendered
FPS, queue high-water marks, memory and audio discontinuities. WSS encoded GOP
abandonment must flush to a fresh IDR; do not drop arbitrary reference frames.
Keep input private to the disposable proof and do not expose an unauthenticated
network agent. Enrollment and control fencing precede product remote-input access.

The proof decision record must freeze the language/media build, driver package,
software workload envelope, native/browser codecs and transport, or explicitly
record a no-go and its prerequisite. Only then start the agent product project.

### Native Windows diagnostic

`scripts/windows-premium-probe.cpp` uses inbox Windows APIs, without a media
runtime install. Build with MinGW-w64 (or a reviewed equivalent Windows toolchain):

```sh
x86_64-w64-mingw32-g++ -std=c++17 -O2 -Wall -Wextra -Werror -static \
  scripts/windows-premium-probe.cpp -o windows-premium-probe.exe \
  -ld3d11 -ldxgi -lmfplat -lmfuuid -lole32 -luuid -lpropsys -lversion
```

Transfer it to the disposable guest through the isolated proof tooling and run
from its **logged-in console session**, saving JSON in a private evidence folder:

```powershell
.\windows-premium-probe.exe | Set-Content -Encoding UTF8 inventory.json
.\windows-premium-probe.exe --capture-seconds 5 | Set-Content -Encoding UTF8 capture.json
```

Default inventory enumerates DXGI adapter identity/VRAM/output modes, D3D11
device creation, per-adapter **D3D12** creation, **Vulkan** loader/instance/
physical-device enumeration, Intel OpenGL ICD file presence, separate WARP
creation, actual active MMDevice render endpoints
and non-hardware Media Foundation H.264 candidates. Optional Desktop Duplication
tries frames for a **shared 1–10 second capture budget**; it does not copy/save
pixels, change modes, inject input, install drivers or open network sockets.
Apply an external 30-second process watchdog for driver/API hangs. A run in
Session 0 can diagnose enumeration but cannot certify console capture.

Acquired-frame counts are availability diagnostics, not delivered stream FPS.
An idle screen legitimately yields few frames. Failed HRESULTs are retained in
JSON even when process exit is zero: inspect each result. Encoder enumeration
does not establish activation/encoding, and endpoint presence does not establish
loopback/Opus/playback. WGC, encoding timing, audio loopback, mode changes and
viewer/transport proof remain separate trials. A diagnostic written in C++ does
not select the production agent's implementation language.

## G0 read-only physical inventory

On each candidate Linux worker, run locally or using an already trusted SSH host:

```sh
python3 scripts/vm-gpu-inventory.py
python3 scripts/vm-gpu-inventory.py --ssh operator@gpu-worker.example.com
kubectl get nodes -o custom-columns='NAME:.metadata.name,ALLOCATABLE:.status.allocatable'
kubectl get kubevirt -A -o yaml
```

The script reads graphics PCI IDs, current driver, IOMMU members, reset methods,
boot-VGA/output state, mediated/SR-IOV exposure and capacity. It never changes
device binding or resets hardware. Retain live output privately.

For a selected device additionally record vendor-supported host/guest driver
matrix, VRAM, UEFI ROM, graphics API/encoder capabilities, cost/licensing and
host console/workload ownership. Require a VM-capable advertised resource and
operator-approved KubeVirt allowlist; a container `/gpu` resource is not proof
of VFIO/vGPU compatibility. Coordinate worker maintenance before allocation.

First prove signed Windows hardware-adapter D3D11 rendering versus WARP with
adapter LUID/vendor/device/VRAM and render-engine utilization. Probe D3D12,
OpenGL, Vulkan and hardware H.264 separately. Verify capture of that output in
native and browser viewers, retained VGA recovery and repeated reset/reallocation.
If no usable spare device exists, record physical proof blocked and the required
hardware/placement; continue the software streaming work independently.

### Integrated Intel GPU candidates

An integrated GPU can be a research candidate even when no VM resource is
advertised yet. Check privileged DRM client/host-console ownership, IOMMU groups,
kernel GVT-g module and current `i915.enable_gvt`, mediated profile exposure and
exact guest-driver support. No mediated directory while GVT-g is disabled is
not a hardware impossibility verdict. Do not assume older Intel GPUs expose
modern SR-IOV VFs.

Full IGD passthrough and GVT-g sharing have different firmware/device paths.
Consult documentation for the **running QEMU**, not an older UPT recipe: Intel
OpRegion/stolen-memory and guest firmware handling can require integration not
provided by generic PCI allowlisting. Retain the current Secure Boot/OVMF and
VGA recovery contract. GVT-g's historical Windows validation is not certification
of a current Windows 11 build; review its maintenance status before production.
Host GVT enabling/reprobe/reboot or VFIO binding requires coordinated worker
maintenance and a reversible host configuration. Do not change a live
control-plane GPU or disable firmware/driver security to make the test pass.
