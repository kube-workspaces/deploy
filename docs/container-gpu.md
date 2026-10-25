# GPU acceleration for container workspaces

Linux containers can use host-driven GPUs without PCI passthrough to a VM.
Applications need an allocated device, a compatible host kernel driver and
userspace graphics libraries in the container. Prove application rendering,
desktop rendering and hardware video encoding separately.

See [GPU support](gpu.md) for the workspace-type comparison, resource names and
current UI limitations. This guide covers `container` workspaces; the same
device allocation also applies to `scratch` pods. GPU access does not require
converting either type to a VM.

## Prerequisites and vendor choices

| GPU | Host / Kubernetes prerequisites | Container requirements |
|---|---|---|
| Intel | Compatible i915/xe kernel driver and Intel GPU device plugin, or the explicitly configured host render-node example below | Matching Mesa/compute/media libraries for the requested workload; access to allocated DRM render devices |
| AMD | Compatible amdgpu driver and a device plugin advertising the intended resource | Compatible Mesa/ROCm/media userspace as appropriate; graphics support must be verified separately from compute |
| NVIDIA | Compatible host driver, NVIDIA container toolkit/runtime configuration and device plugin/operator | Workload-appropriate driver capabilities and graphics/video/compute libraries; a compute-only setup may not supply desktop graphics or video encoding |

Follow the GPU vendor's hardware and runtime compatibility guidance. Container
images do not install the host kernel driver. The Intel/Craft Apps path below
has functional application proof; it is not blanket qualification of every
vendor, image or graphics API. No chart GPU switch turns on all these layers.

## Requesting a GPU

The workspace creation API already accepts `container.gpu_request` and
`container.gpu_vendor`. The latter is the Kubernetes extended resource name,
not just a vendor identifier. For example:

```json
{
  "gpu_request": "1",
  "gpu_vendor": "kubeworkspaces.io/intel-render"
}
```

These fields belong inside the create request's `container` object. They request
an existing node device resource; they do not install drivers or a device plugin.
The controller preserves container resource requests in the generated workload.

For example, a new Craft Apps workspace can request the optional allocator below
through `POST /v1/workspaces`:

```json
{
  "name": "craft-gpu",
  "namespace": "my-workspaces",
  "type": "container",
  "shared_memory": true,
  "container": {
    "name": "desktop",
    "image": "linuxserver/craft-apps:latest",
    "port": 3000,
    "cpu_request": "500m",
    "cpu_limit": "2",
    "memory_request": "512Mi",
    "memory_limit": "2Gi",
    "gpu_request": "1",
    "gpu_vendor": "kubeworkspaces.io/intel-render"
  }
}
```

This is a GPU request example, not a complete storage policy: attach an existing
home PVC at `/config` with `volume_mounts` when creating a persistent desktop.
The image/proxy configuration must also support the workspace's proxy subfolder.
Use a qualified image version/digest for a repeatable deployment and size CPU,
memory, shared memory and GPU budgets for real documents; a GPU allocation does
not remove the container's memory limit.

The API emits a container resource limit. Kubernetes defaults an omitted request
to the limit for extended device resources; use positive whole-number counts,
with equal GPU requests/limits if specifying both. The API also adds a
`NoSchedule` toleration keyed by the resource when GPU access is requested.
Other node taints or placement requirements still need their own configuration.

For an existing workspace, inspect the current template, save documents and
apply a narrow change. For a single-container Workspace whose first container
already has a `resources.limits` map:

```sh
kubectl get workspace WORKSPACE -n WORKSPACE_NAMESPACE -o yaml
kubectl patch workspace WORKSPACE -n WORKSPACE_NAMESPACE --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/resources/limits/kubeworkspaces.io~1intel-render","value":"1"}]'
kubectl rollout status statefulset/WORKSPACE -n WORKSPACE_NAMESPACE --timeout=180s
```

Select the correct container index for a multi-container template. JSON Pointer
escapes `/` in the resource name as `~1`. This preserves the existing CPU/memory
limits, environment and volumes; do not replace their maps with a GPU-only
example. Wait for the controller to reconcile the new StatefulSet template and
confirm its new pod has the resource and allocated device. For a GitOps-managed
Workspace, make the same change in its source of truth. Placement comes from
the resource's node capacity, subject to existing affinity/selectors and PVC
node constraints.

## Intel host render-node proof

Normally prefer Intel's GPU device plugin for Intel devices. There is a special
case when a host physical function (PF) remains Linux-driven while SR-IOV virtual
functions (VFs) serve VMs: Intel's plugin deliberately excludes the PF when VFs
exist. The optional examples here use the upstream generic device plugin to
allocate a specifically selected host render node in that configuration.

This is an operator-selected integration, not automatic hardware discovery or
vendor certification. It does not create VFs or change any PCI driver binding.

1. On the selected node, verify `/dev/dri/renderD128` is the intended Intel
   **host-driven** device. Check its sysfs PCI identity, driver, device ownership
   and existing consumers. A VFIO-bound function is not a DRM render device.
   Adapt the example device path if necessary; recheck identity after hardware
   or driver changes. Do not run another allocator for the same render node.
   Useful host checks are:

   ```sh
   ls -l /dev/dri /dev/dri/by-path
   readlink -f /sys/class/drm/renderD128/device
   readlink -f /sys/class/drm/renderD128/device/driver
   stat -c '%a %u:%g %n' /dev/dri/renderD128
   ```

   Use the resolved PCI address to inspect the device with `lspci -nnk -s ADDRESS`.
2. Verify the kubelet device-plugin directory. The example uses
   `/var/lib/kubelet/device-plugins`; adapt its host path for your installation.
3. Opt in the selected node and deploy the plugin:

   ```sh
   kubectl label node GPU_NODE kubeworkspaces.io/container-intel-gpu=true
   kubectl apply -f examples/container-gpu/intel-render-device-plugin.yaml
   kubectl rollout status daemonset/intel-render-device-plugin -n kube-system
   kubectl get node GPU_NODE -o jsonpath='{.status.allocatable.kubeworkspaces\.io/intel-render}'
   ```

   The node plugin uses upstream's privileged-plugin model, with only DRM and
   kubelet device-plugin directories mounted. Workspace containers do not need
   privileged mode, host device mounts or a host filesystem mount.
4. Run the isolated probe before changing a user's desktop:

   ```sh
   kubectl apply -n WORKSPACE_NAMESPACE -f examples/container-gpu/intel-render-probe.yaml
   kubectl logs -n WORKSPACE_NAMESPACE -f pod/intel-render-probe
   kubectl get pod -n WORKSPACE_NAMESPACE intel-render-probe
   kubectl delete pod -n WORKSPACE_NAMESPACE intel-render-probe
   ```

   The probe uses Craft Apps' installed Intel Vulkan userspace stack and checks
   VA-API if `vainfo` is available (otherwise explicitly reports it unverified).
   Intel-only ICD selection prevents a software Vulkan fallback from being
   mistaken for hardware support. Enumeration is a prerequisite, not an actual
   application rendering or encoding proof. The probe pod retains the allocation
   until deleted, even after its command exits.
5. Set `kubeworkspaces.io/intel-render: "1"` under the workspace container's
   resource limits (or use the API fields above for a new workspace). For an
   existing workspace, change the owning `Workspace.spec.template.spec`, not
   its generated StatefulSet. This restarts the desktop: save documents first.
   Keep the existing image, volumes, resource limits and environment entries.
6. Confirm the non-root application user can open the allocated render node.
   Craft Apps' init handles its video group membership. Other images may need
   the device's numeric group as a supplemental group and suitable userspace
   packages. Do not assume all images initialise device permissions alike.
7. Inspect the desktop renderer and application backend. In Craft Apps, verify
   PhotoCraft's image compositor as well as its window backend; separately
   verify Selkies' actual encoder. GPU device allocation alone proves none of
   these outcomes.

   PhotoCraft can retain CPU compatibility mode from an earlier failed GPU
   session. In Preferences → Performance, select Automatic or GPU rendering and
   restart PhotoCraft. A remembered CPU selection is not evidence that device
   allocation failed.

### PhotoCraft application-level probe

After the allocation prerequisite passes, run the supplied probe inside the
running graphical container as its desktop user:

```sh
kubectl exec -i -n WORKSPACE_NAMESPACE WORKSPACE_POD -- \
  s6-envdir /run/s6/container_environment s6-setuidgid abc \
  env WAYLAND_DISPLAY=wayland-0 python3 - < scripts/photocraft-gpu-probe.py
```

Adjust the desktop user and Wayland socket for the image. This targets PhotoCraft
0.15.1's control API. It opens a separate instance with a generated 256×256 PNG
and temporary settings, authenticates to a loopback-only control server, reads
the selected adapter and actual GPU-composite state, then quits and removes its
temporary files. Existing user documents/preferences are not used. It requires
an Intel hardware adapter, `canvas=gpu`, `gpu=true`, a GPU refresh, and no device
loss. A software adapter merely being available is not a failure when the
selected adapter is hardware. This is functional proof, not a performance test.

Functional validation of this path used Intel Graphics (ARL), Mesa 26.0.8 and
PhotoCraft 0.15.1: the application reported a Vulkan integrated-GPU adapter,
`canvas=gpu`, `lastRefresh=gpu-full`, and no GPU fallback/device loss while
displaying the generated image. Interactive use was also accepted. This does
not qualify other driver/image versions, every filter, or hardware streaming.

The probe briefly presents a synthetic-image window; run it when this will not
interrupt interactive work. PhotoCraft control credentials are ephemeral and
not printed by the probe.

### Allocation and coexistence

The example advertises **one allocation per render device**. This does not
reserve the whole physical GPU against host processes or VM VFs. Those consumers
still share physical hardware capacity. Raising the plugin's `count` explicitly
oversubscribes the device; it is not GPU memory/compute partitioning or a
dedicated-performance guarantee. Do not advertise sharing before testing it.

## Verification and troubleshooting

Start with scheduling and allocation:

```sh
kubectl describe pod WORKSPACE_POD -n WORKSPACE_NAMESPACE
kubectl get pod WORKSPACE_POD -n WORKSPACE_NAMESPACE \
  -o jsonpath='{.spec.containers[*].resources}'
kubectl logs -n WORKSPACE_NAMESPACE WORKSPACE_POD
```

For the optional allocator, inspect its logs too:

```sh
kubectl logs -n kube-system daemonset/intel-render-device-plugin
```

| Symptom | What to check |
|---|---|
| Pod stays Pending / insufficient GPU resource | Exact requested resource versus node allocatable; plugin registration; allocated slots, including probe pods; namespace quotas; node taints/selectors/affinity; PVC node affinity |
| Pod scheduled, expected device absent | Inspect the actual pod's resource limits and selected container; confirm the plugin allocates the expected device rather than only a numeric resource |
| Device exists but application cannot open it | Test as the desktop/application user, not only root; compare numeric device GID with process groups; verify image startup and security-context handling |
| Vulkan/OpenGL lists only llvmpipe/lavapipe/Pixman | Check device access, compatible userspace drivers/ICDs, graphics-related runtime capabilities, and any software-rendering environment overrides |
| Desktop is GPU-backed but PhotoCraft still composites on CPU | Check Preferences → Performance and restart after changing CPU compatibility mode; inspect the selected adapter, canvas and fallback reason using the application probe/System Info |
| GPU appears among adapters but is not used | Examine the **selected** adapter and actual rendering state, not the available-adapter list |
| Selkies detects VA-API but the stream uses CPU | Inspect the active session's selected encoder/codec and errors; hardware capability discovery alone does not establish active encoding |
| Device works until a host reboot | Recheck host driver binding, device identity/path, plugin rollout/registration and any operator-managed VF/mdev setup |

For Craft Apps, a headless Vulkan prerequisite check as the desktop user is:

```sh
kubectl exec -n WORKSPACE_NAMESPACE WORKSPACE_POD -- \
  s6-envdir /run/s6/container_environment s6-setuidgid abc \
  env -u DISPLAY -u WAYLAND_DISPLAY \
  VK_DRIVER_FILES=/usr/share/vulkan/icd.d/intel_icd.json vulkaninfo --summary
```

This avoids a misleading X11 authorization failure from a root diagnostic
process and selects only Intel's Vulkan ICD. It proves hardware discovery, not
rendering. Use the PhotoCraft probe above for an actual application composite.
Adapt the command for other images and driver vendors.

Expected Craft Apps startup evidence includes a GL renderer on the allocated
render node rather than `Renderer: software (Pixman), no render node`. Selkies
may also report VA-API codec capability. Keep those observations distinct from
the application's GPU compositor and the encoder actually used by a viewer.

GPU configuration survives normal pod recreation when it is kept in the
Workspace source of truth. Host reboot also depends on driver/device and plugin
recovery. Validate a saved-document stop/start, pod recreation and host reboot
before treating lifecycle persistence as accepted for a particular installation.

## Rollback

Remove the added GPU resource from the owning Workspace template, along with
any GPU-specific environment/placement/group changes introduced for that
workspace. Its persistent home volume should remain unchanged. After all
consumers release the allocation, delete the optional plugin DaemonSet and
remove the opt-in node label if no longer needed. Kubernetes can retain a
zero-capacity extended resource key after plugin removal.

For the single-container patch example above, the inverse change is:

```sh
kubectl patch workspace WORKSPACE -n WORKSPACE_NAMESPACE --type=json \
  -p='[{"op":"remove","path":"/spec/template/spec/containers/0/resources/limits/kubeworkspaces.io~1intel-render"}]'
```

If an explicit GPU request was also present, remove it as well. Restore any
application rendering preferences separately while the application is closed,
or select its software/CPU compatibility mode. Keep all existing home PVCs.
After no consumers remain, the optional allocator can be removed with:

```sh
kubectl delete -f examples/container-gpu/intel-render-device-plugin.yaml
kubectl label node GPU_NODE kubeworkspaces.io/container-intel-gpu-
```

## References

- [Craft Apps GPU support](https://docs.linuxserver.io/images/docker-craft-apps/#gpu-acceleration)
- [Intel GPU plugin, including SR-IOV behaviour](https://github.com/intel/intel-device-plugins-for-kubernetes/tree/main/cmd/gpu_plugin)
- [Generic device plugin](https://github.com/squat/generic-device-plugin)
