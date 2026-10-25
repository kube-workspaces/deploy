# GPU support

Kube Workspaces supports GPU resource requests for container workspaces and GPU
assignment to compatible KubeVirt VMs. The allocation mechanism depends on the
workspace type. A GPU is optional for ordinary software-rendered desktops.

## Choose the right path

| Workspace / goal | GPU access | Configuration | Guide |
|---|---|---|---|
| `container` / host-driven graphics, compute or video | Kubernetes device plugin allocates host GPU devices to the pod; applications use the host kernel driver | `container.gpu_request` and the exact `container.gpu_vendor` resource, or container resource limits in the Workspace PodSpec | [Container GPUs](container-gpu.md) |
| `scratch` / GPU-enabled ephemeral pod | Same device-plugin allocation as containers, in a Deployment rather than a StatefulSet | Same GPU resource fields / PodSpec; storage and pod identity follow scratch semantics | [Container GPUs](container-gpu.md) |
| General `vm` / assigned hardware GPU | KubeVirt assigns an allowed PCI device, SR-IOV VF or mediated GPU to the guest | Generic GPU resource request with a controller-recognised resource name; compatible KubeVirt allowlist and guest driver | [VM GPU passthrough](vm.md#gpu-passthrough) |
| Managed Windows VM / render-only GPU | Operator-declared, versioned GPU profile resolves an exact resource and driver contract | `vm_options.gpu_profile`; change an existing VM's profile only while stopped | [Windows GPU profiles](windows-vm.md#experimental-render-only-gpu-profiles) |
| VM / virtual display without host GPU assignment | Emulated/paravirtual display device | Image `videoDevice: virtio` | [VM display device](vm.md#display-device) |

`virtio-gpu`, KVM CPU acceleration and a premium remote-display transport do not,
by themselves, provide physical GPU acceleration to applications.

## What must be installed

### Containers

1. A GPU node with a working **host** driver.
2. A device plugin advertising a resource that provides the required devices;
   NVIDIA deployments also need the appropriate container runtime/toolkit wiring.
3. A workspace requesting that exact resource, with suitable scheduling and
   process permissions.
4. Compatible graphics/compute/video userspace libraries inside the image.

Intel/AMD graphics commonly use `/dev/dri/renderD*`. A render node permits
off-screen GPU work without handing the container display modesetting control.
The device plugin must actually allocate the device; a directory mount or a
resource name alone is insufficient. No KubeVirt installation, KubeVirt device
allowlist or VFIO binding is needed for this host-driven container path.

### VMs

The assigned device must be suitable for KubeVirt: host IOMMU/isolation and VFIO
for PCI assignment, or the applicable mediated-device setup; a matching device
resource; a KubeVirt allowlist entry; and a compatible **guest** driver. Integrated
GPUs and SR-IOV VFs can be candidates as well as discrete GPUs. A physical GPU
function assigned through VFIO cannot simultaneously act as a host DRM device.
A Linux-driven PF and a separately assigned VF can coexist where the hardware
and driver support it; validate their behaviour under concurrent load.

The chart's `kubevirt.gpuPassthrough` settings concern VMs. The chart does not
install a general container GPU driver/operator/device plugin. The render-node
plugin in `examples/container-gpu/` is an optional, separately managed example.

## Resource names and the current UI

Use the resource **actually advertised by the selected device plugin**:

| Example resource | Intended allocation |
|---|---|
| `nvidia.com/gpu` | NVIDIA plugin resource; container or VM suitability depends on which plugin/runtime supplies it |
| `amd.com/gpu` | AMD device-plugin resource; required graphics/compute libraries still depend on the workload |
| `gpu.intel.com/i915` / `gpu.intel.com/xe` | Intel's container GPU plugin resources for the corresponding host driver |
| `kubeworkspaces.io/intel-render` | This repository's optional, explicitly selected host render-node example |
| Operator-defined Windows profile resource | Exact KubeVirt-assignable resource declared by the Windows GPU profile |

These are examples, not interchangeable aliases. List node capacity with:

```sh
kubectl get nodes -o custom-columns='NAME:.metadata.name,ALLOCATABLE:.status.allocatable'
```

The generic create form currently offers NVIDIA (`nvidia.com/gpu`), AMD
(`amd.com/gpu`) and Intel (`intel.com/gpu`). It does not discover or accept every
custom resource name. In particular, the Intel option does **not** automatically
request `gpu.intel.com/i915`, `gpu.intel.com/xe`, or the render-node example.
Use the API's `container.gpu_vendor` or an operator-managed Workspace manifest
for these names. Managed Windows has a separate profile selector.

For generic VMs, the controller's passthrough mapping recognises `nvidia.com/gpu`,
`amd.com/gpu`, `intel.com/gpu` and other names ending in `/gpu`. Requesting a
container resource with another name does not create a KubeVirt attachment.
Managed Windows profiles use their explicit resource name instead of that
generic naming convention.

## Validate the whole application path

| Layer | Evidence to collect |
|---|---|
| Allocation | Pod scheduled with the requested resource; expected device accessible to the application user |
| Application graphics/compute | Selected hardware adapter and a successful application operation; no silent software fallback |
| Desktop rendering | Compositor/window-system renderer and the device it uses |
| Remote video encoding | Encoder actually selected during a connected stream; decoded output in the viewer |

A smooth viewer is not proof of GPU application rendering. An accelerated
desktop does not establish that an image editor's compositor or filters use the
GPU. Encoder capability discovery is not an active encoding measurement.

The container guide includes a working Intel/Craft Apps recipe and a PhotoCraft
probe that renders a synthetic image and checks the application's actual GPU
compositor state. It is a functional proof; broader vendor support, large
documents and streaming performance require their own checks.

## Sharing and lifecycle

Device counts represent **allocations**, not a portable amount of GPU memory or
compute capacity. Some plugins expose a whole device; others expose shared
slots, partitions or VFs. Host processes and VM VFs may still contend for the
same physical GPU. Document the allocator's sharing policy before promising
dedicated performance or isolation.

Keep the desired GPU resource in the owning Workspace and the node/plugin
configuration in the operator's deployment or GitOps configuration. Save work
before changing a running container's PodSpec, because it recreates the pod.
Changing managed Windows GPU hardware requires the stopped-VM profile workflow.
Verify stop/start, pod recreation, host reboot and unavailable-device behaviour
for the chosen hardware and allocation mechanism.
