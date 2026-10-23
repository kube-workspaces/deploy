# Windows 11 VM proof and prerequisites

Windows 11 workspace integration is **in development**. These tools create
direct KubeVirt proof VMs; they do not enable a Windows Image in the product
catalog. The cross-repository status is maintained in
[tracking](https://github.com/kube-workspaces/tracking/blob/main/windows-vm-workspaces-plan.md).

For an end-to-end process starting with Microsoft's official ISO, see
[Build your own Windows 11 image](https://github.com/kube-workspaces/image-catalog/blob/main/windows11/BUILD-GUIDE.md).
That guide retains the install/bootstrap/evidence and Docker-free packaging
scripts, and covers private root export, registry authentication and clone
validation. Operators supply Windows media and retain prepared disks privately;
the catalog distributes recipes, not Windows binaries.

## Create a Windows Image CR and Workspace

The Windows controller/API/UI integration uses the versioned
`windows11-amd64-v1` profile. Deploy the matching controller and API builds,
generated Image/Workspace CRDs, and prerequisite RBAC together. When a GitOps
application owns CRDs/RBAC through a pinned chart, update that chart through its
normal release/revision workflow; do not override another field manager's schema.

After preparing and privately publishing a generalised image using the
[build guide](https://github.com/kube-workspaces/image-catalog/blob/main/windows11/BUILD-GUIDE.md),
create an operator-owned Image (replace the example reference with its real digest):

```yaml
apiVersion: kubeworkspaces.io/v1alpha1
kind: Image
metadata:
  name: windows11-pro-private
spec:
  displayName: Windows 11 Pro (private)
  image: registry.example.com/private/windows11@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  workspaceTypes: [vm]
  vmProfile: windows11-amd64-v1
  persistentRootDisk: true
  persistentRootDiskSize: 80Gi
  memoryLimit: 4Gi
  memoryRequest: 4Gi
  defaultPort: 0
```

The digest references the prepared root, not an installer ISO. No shared
password, Linux cloud-init or Selkies configuration belongs in this Image.
`defaultPort: 0` advertises no guest web service; access uses hypervisor VNC.

Create CDI credentials and, when needed, a registry CA ConfigMap in the
Workspace's namespace. Certify an eligible worker with
`kubeworkspaces.io/windows11-amd64-eligible: "true"` after checking the actual
CPU/build and persistent-state prerequisites. A minimal Workspace is:

```yaml
apiVersion: kubeworkspaces.io/v1alpha1
kind: Workspace
metadata:
  name: windows-desktop
  namespace: workspaces
spec:
  type: vm
  vmProfile:
    id: windows11-amd64-v1
    image: registry.example.com/private/windows11@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    cpuCores: 2
    guestMemory: 4Gi
    rootDiskSize: 80Gi
    importSecretName: registry-import
    importCertConfigMapName: registry-ca
  template:
    spec:
      nodeSelector:
        kubernetes.io/hostname: eligible-worker
        kubernetes.io/arch: amd64
      containers:
        - name: workspace
          image: registry.example.com/private/windows11@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
          resources:
            requests: {cpu: "2", memory: 4Gi}
            limits: {cpu: "2", memory: 4Gi}
```

Omit `importCertConfigMapName` for a registry using normal public trust roots;
omit `importSecretName` only when the root can legitimately be imported without
authentication. The controller generates a unique provisioning generation,
firmware identity, hostname and initial account credentials. Keep `vmProfile`
and the main image consistent. Normal restart preserves them; Reset creates a
fresh root/state/credential generation. User data disks are not part of this
Windows profile.

In the UI select Virtual Machine, choose the Windows Image, set an eligible
worker, and supply the same-namespace import Secret/CA references. The REST create
payload uses those references under `vm_options`:

```json
{
  "name": "windows-desktop",
  "namespace": "workspaces",
  "type": "vm",
  "container": {
    "name": "workspace",
    "image": "registry.example.com/private/windows11@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "cpu_limit": "2",
    "memory_limit": "4Gi"
  },
  "node_selector": {"kubernetes.io/hostname": "eligible-worker"},
  "vm_options": {"import_secret_name": "registry-import", "import_cert_config_map_name": "registry-ca"}
}
```

Windows readiness requires native setup/account completion, guest-agent
connection and bootstrap removal. The controller gracefully restarts the guest
once after setup to remove its answer CD, then retains only the unique initial
credentials in a Workspace-owned Secret. Namespace editors/admins retrieve them
through `GET /v1/workspaces/windows-desktop/credentials?namespace=workspaces`
or the workspace's initial-account panel. The response is `Cache-Control:
no-store`; the answer XML/password is not included in ordinary Image/Workspace
responses or YAML views. Use the Display connection for login. Serial, SSH,
Linux mounts and guest-streaming are unavailable for this profile.

## Infrastructure preflight

Target KubeVirt **1.9.x**, CDI **1.61.0**, Linux amd64 KVM workers and operator
provided Windows 11 Pro/Enterprise media. Select and record the exact supported
Windows feature release, edition, ISO SHA256, patch build and signed VirtIO
driver ISO version/SHA256 before installing. Record activation and virtualisation
entitlements separately from the public evidence.

```sh
python3 scripts/windows-vm-proof.py preflight --node YOUR_WORKER
```

This only reads cluster resources and reports known infrastructure blockers.
It does not certify CPU eligibility, free physical disk space or Windows
licensing. Inventory the actual CPU with `lscpu` on the worker; KubeVirt's
`host-model-cpu` labels can describe an older compatibility model. Check namespace
quotas, existing pod requests and physical storage capacity. The default proof
needs 4 vCPU, 8Gi guest memory **plus launcher overhead**, 80Gi root, installer
and driver media, import scratch space and a separate backend-state PVC.

### Persistent EFI and TPM storage

`VMPersistentState` is **GA and automatically enabled in KubeVirt 1.9.0**.
An empty feature-gate array is not a blocker on this version. Older upstream
documentation still asks operators to enable the gate explicitly. Verify the
versioned implementation when using another version.

Leave `spec.configuration.vmStateStorageClass` unset in the KubeVirt CR to use
the default storage class. To choose another class, configure that field in the
deployment that owns the KubeVirt CR. Chart-side support requires a coordinated
chart rollout; inspect your deployed chart's values before assuming it exposes
this override.

**Do not explicitly select an RWO-only class with an empty StorageProfile.**
KubeVirt 1.9 selects RWX in that case; with no explicit class it defaults to
RWO. If explicitly selecting `local-path`, first set its CDI StorageProfile:

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: StorageProfile
metadata:
  name: local-path
spec:
  claimPropertySets:
    - accessModes: [ReadWriteOnce]
      volumeMode: Filesystem
```

Wait for `status.claimPropertySets` to reflect this before creating the VM.
Backend state and root/media PVCs must schedule on the same worker. Node-local
storage provides stop/start persistence on that worker, not node-failure recovery
or relocation. KubeVirt creates backend-state PVCs owned by the **VM**; keep the
VM object when restarting. Creating a bare VMI ties its state PVC to that VMI.

## Isolated proof

Create an isolated `windows11-proof` namespace. The renderer emits a **stopped**
VM with a new firmware UUID; save the manifest and reuse it for that VM. Rendering
again without `--firmware-uuid` creates a new identity. Nothing is automatically
applied or started by the script.

### Infrastructure-only firmware probe

```sh
kubectl create namespace windows11-proof
python3 scripts/windows-vm-proof.py render --mode firmware --node YOUR_WORKER > firmware.json
kubectl apply --dry-run=server -f firmware.json
kubectl apply -f firmware.json
virtctl start -n windows11-proof windows11-proof
```

The firmware-only probe uses 1 vCPU, 1Gi RAM and a 1Gi blank root; install/clone
fixtures use the 4 vCPU/8Gi/80Gi desktop defaults. `--cpus 2 --memory-gi 4`
selects the Windows minimum validation floor when capacity is constrained.
Reserve host/control-plane headroom beyond guest and launcher memory. The live
proof's resource selection must account for the other workloads on the worker;
successful scheduling alone does not establish sufficient physical headroom.

An empty root can reach firmware only. It can establish persistent state PVC
allocation, KVM, signed OVMF, SMM and an emulated TPM in the launcher. It cannot
prove Windows installation, BitLocker persistence, graphics or guest readiness.

### Installer proof

Upload operator-supplied ISO files with the version-matched `virtctl image-upload`
tool, using the default kubevirt content type, Filesystem/RWO PVCs, an appropriate size
(e.g. 10Gi installer and 2Gi drivers) and the chosen StorageClass. With node-local
storage, ensure upload pods/media are placed on the selected worker. Do not use
`--insecure` as a default; configure trust for the CDI upload proxy.

```sh
python3 scripts/windows-vm-proof.py render --mode install --node YOUR_WORKER \
  --name windows11-build --installer-pvc windows11-iso --drivers-pvc virtio-iso > install.json
kubectl apply --dry-run=server -f install.json
kubectl apply -f install.json
virtctl start -n windows11-proof windows11-build
virtctl vnc -n windows11-proof windows11-build
```

The installer boots first, then the VirtIO root. Load signed **viostor** drivers
for the root and **NetKVM** for networking; install the matching guest-agent
serial driver and QEMU guest agent. The initial graphics candidate is VGA with a
USB absolute tablet, not Linux VirtIO graphics. Pin and test drivers with Secure
Boot enabled. Do not bypass the Windows installer requirements.

After installation stop the VM, wait for the VMI to disappear, remove installer
and driver disks/volumes from the saved manifest, and set root boot order to 1.
Apply it while stopped, then restart. Record TPM 2.0, Secure Boot, connected
agent, network and display evidence using the catalog's guest evidence script.

## Seal and test two clones

Follow the private image recipe in
[image-catalog/windows11](https://github.com/kube-workspaces/image-catalog/tree/main/windows11).
The catalog includes `windows11/render-bootstrap.py` for private install/clone
answer-file generation (see its README). Install mode wipes disk 0 and must only
be used with a disposable blank root. Clone mode does not partition disks.
Use the recipe's offline `prepare-sealed-root.py` step after Sysprep/export:
the tested Windows build needs a credential-free native setup registry pointer
to `D:\autounattend.xml` to consume its SATA answer CD. Keep clone media at root
plus that one CD, and remove the pointer after confirmed setup.
For each clone create a different same-namespace bootstrap Secret containing
`autounattend.xml` rendered with Windows System Image Manager for the pinned
edition/build. Use distinct local account credentials/hostnames, XML-safe
values, no auto-logon and no shared password. Secrets are supplied locally, never
committed. This initial fixture references a Secret; the product's automated
credential generation/retrieval is a later controller/API milestone.

For CDI 1.61 pod registry imports, create an Opaque Secret with `accessKeyId`
(registry username) and `secretKey` (password/token), and pass it as
`--import-secret`. The catalog's `windows11/render-import-secret.py` converts
private inline Docker auth to these keys. A Secret with only `.dockerconfigjson`
causes `CreateContainerConfigError`; Pod imagePullSecrets alone do not configure
the import. Test authentication to the private registry using the actual CDI
importer. Do not include registry credentials in the manifest.

For a registry signed by your own CA, create a same-namespace ConfigMap with
the CA PEM (e.g. `kubectl create configmap registry-ca --from-file=ca.crt -n
windows11-proof`) and pass `--import-cert-configmap registry-ca`. This sets CDI's
`registry.certConfigMap`; local workstation trust alone does not configure the
importer. Keep TLS/hostname verification enabled.

```sh
python3 scripts/windows-vm-proof.py render --mode clone --node YOUR_WORKER \
  --name windows11-clone-a --image 'REGISTRY/PRIVATE/IMAGE@sha256:DIGEST' \
  --import-secret registry-import --sysprep-secret clone-a-bootstrap > clone-a.json
```

Repeat as clone-b with a different Secret and VM identity. Apply the saved
manifests and start each clone. KubeVirt attaches Sysprep as a SATA CD-ROM.
After setup is confirmed, stop, wait for VMI deletion, remove the `sysprep`
disk/volume from the saved manifest and apply it. Delete the bootstrap Secret
only after detaching it. Clean Windows Panther/Sysprep answer-file caches and
verify that subsequent starts do not replay setup.

## Acceptance and cleanup

Record root PVC UID, state PVC UID, VM UID, firmware UUID and VMI UID. Use
`virtctl stop`, wait for VMI deletion, then `virtctl start`; require a **different
VMI UID** and unchanged root/state PVCs, firmware identity and guest files.
Prove guest TPM-bound state survives, using BitLocker only on a disposable guest
with separately stored recovery material. Test Windows Update and guest reboot.
Check graceful shutdown via agent/ACPI; do not substitute force deletion for it.

Record browser/native VNC login, secure-attention sequence, keyboard/layout,
absolute pointer, reconnect, observer input restrictions, `dxdiag` and agent
status. Clipboard, audio, resize, GPU, RDP, SSH, nested Hyper-V and Windows data
disks are not implied by the firmware probe or VNC availability.

To dispose of a proof VM, stop it and wait for VMI deletion, delete the VM, then
verify its owned root DataVolume/PVC and backend-state PVC are gone. Uploaded ISO
PVCs and manually created bootstrap/import Secrets are independent resources;
delete them separately. Remove only the dedicated proof namespace after all
required disk exports/evidence are saved.

## Guest access without VNC (QEMU guest agent)

The QEMU guest agent (QGA) channel gives shell access to a running Windows VM
without opening VNC or the desktop client, which is what makes headless
diagnosis possible: read the agent's own version, service/worker state, event
log, files and logs while a UAC prompt or a dead interactive session blocks the
normal path. It rides the virtio-serial agent channel, not the network, so it
also works when the desktop session is unusable.

Run the agent command through the VMI's `virt-launcher` pod. The domain is named
`<namespace>_<name>` and the command JSON is a single argument:

```sh
VM=windows11-pro
NS=windows11-proof
POD=$(kubectl get pod -n "$NS" -l kubevirt.io/domain="$VM" \
  -o jsonpath='{.items[0].metadata.name}')
qga() {
  kubectl exec -n "$NS" "$POD" -c compute -- \
    virsh -c qemu:///session qemu-agent-command "${NS}_${VM}" "$1"
}
```

`guest-exec` runs a guest process; `capture-output` collects stdout/stderr and
`guest-exec-status` polls it. Encode a PowerShell script as base64 UTF-16LE and
run it with `-EncodedCommand`:

```sh
SCRIPT='Get-Service KubeWorkspacesAgent | Format-List *; \
  Get-Content C:\ProgramData\workspace-agent\status.json'
B64=$(printf '%s' "$SCRIPT" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
qga "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"C:\\\\Windows\\\\System32\\\\WindowsPowerShell\\\\v1.0\\\\powershell.exe\",\"arg\":[\"-NoProfile\",\"-EncodedCommand\",\"$B64\"],\"capture-output\":true}}"
# -> {"return":{"pid":1234}}; then poll:
qga '{"execute":"guest-exec-status","arguments":{"pid":1234}}'
```

A small Python helper loops the poll until `exited` and decodes `out-data`/
`err-data`. Useful probes: the running worker's `ExecutablePath`, `StartTime`
and command line (`Get-CimInstance Win32_Process`), the on-disk binary's
compiled version (`kw-agent.exe --version`) and SHA-256, `service-status.json`
and `status.json` under `C:\ProgramData\workspace-agent`, and the worker logs
under `C:\Users\<user>\AppData\Local\workspace-agent\`. Comparing the running
process image hash with the installed file on disk is how a stale worker (old
binary still resident after an MSI upgrade) is ruled out.

`guest-exec` requires the guest agent service to be running; a completed
`guest-exec-status` only reports the guest process's own exit, so read its
captured output rather than assuming success from an empty result.

## Tool checks

```sh
python3 -m unittest discover -s scripts -p 'test_windows_vm_proof.py'
make test-lint
```

Versioned references:
[KubeVirt 1.9 GA gates](https://github.com/kubevirt/kubevirt/blob/v1.9.0/pkg/virt-config/featuregate/inactive.go),
[backend PVC selection/ownership](https://github.com/kubevirt/kubevirt/blob/v1.9.0/pkg/storage/backend-storage/backend-storage.go).

The chart vendors **KubeVirt 1.9.1**. For PCI GPU passthrough on hosts without
`CONFIG_IOMMUFD`/VFIO cdev support (including Debian 13's 6.12 kernel), use
1.9.1 or a later release carrying
[the VFIO cdev fallback fix](https://github.com/kubevirt/kubevirt/pull/18905).
KubeVirt 1.9.0 can advertise a PCI resource but fail to create the launcher with
`lstat /dev/vfio/devices/vfio0: no such file or directory`, even with the
IOMMUFD feature gate disabled. Device advertisement alone is not guest attachment
proof; verify a real launcher/guest and keep the host PF on its intended driver
when passing an SR-IOV VF.

## Experimental render-only GPU profiles

Chart **0.6.45** adds the typed Workspace/PlatformConfig GPU schema. Adopt the
CRDs before declaring a profile or requesting a GPU. The controller, API and
browser must also include the matching implementation; chart adoption alone
does not install a Windows driver or make GPU streaming ready.

An operator can declare a **versioned** profile in `PlatformConfig/default`:

```yaml
apiVersion: kubeworkspaces.io/v1alpha1
kind: PlatformConfig
metadata:
  name: default
spec:
  vmGPUProfiles:
    - id: intel-sriov-experimental-v1
      displayName: Intel graphics VF (experimental)
      resourceName: intel.com/graphics-vf
      kind: pci
      count: 1
      nodeSelector:
        example.com/windows-gpu: qualified
      guestDriverVersion: "32.0.101.6452"
      experimental: true
```

Apply a partial configuration with server-side apply and a dedicated field
manager to preserve independently managed maintenance/auth/execution settings.
Use actual qualified device resources, node labels and guest driver versions.
The Windows workspace still requires an explicit certified worker hostname;
that worker must match the GPU profile, be Ready/schedulable and advertise the
resource. The resource must appear in the matching KubeVirt PCI or mediated
allowlist. `count: 1` is the initial supported allocation shape. Device capacity
and namespace quotas remain enforced by Kubernetes scheduling/admission; the
profile list is not a promise that a free device is available.

Discovery: `GET /v1/vm-gpu-profiles`. Create a Windows workspace with
`vm_options.gpu_profile` set to the approved ID. Generic container GPU quantities
remain rejected for Windows. The resolved snapshot is returned as
`vm_gpu_profile`; it is requested configuration, **not observed driver, rendering,
capture or encoder readiness**. Browser create/detail pages expose these choices.

For an existing workspace, Stop it and wait until the KubeVirt VM is halted and
its VMI has disappeared, then call:

```http
PUT /v1/workspaces/my-windows/gpu-profile?namespace=my-workspaces
Content-Type: application/json

{"profile_id":"intel-sriov-experimental-v1"}
```

Namespace editor/admin access is required. The API uses the Workspace resource
version to reject concurrent lifecycle changes, and the controller independently
guards actual VM/VMI state before changing hardware. No Reset or root import is
performed: root, EFI/TPM, provisioning generation and initial credentials remain.
Start the workspace normally after applying the choice. A Start racing ahead of
reconciliation can apply the change only if the previous VM is actually halted
and no old VMI exists. The emulated VGA and IDD are retained; the GPU is a
secondary **render-only** adapter, with an exact extended-resource allocation.

Install/verify the matching signed guest driver separately using a qualified
post-clone flow or private image. To remove the GPU, Stop/wait again and submit
`{"profile_id":""}`, then Start. Software rollback does not require the old
profile registry/device to be available. Do not edit an existing profile ID to
represent different hardware/driver requirements: declare a new versioned ID and
explicitly switch while stopped. Existing snapshots are not silently rewritten.

Before claiming accelerated Tier 1 support, separately prove an interactive GPU
application on the IDD output, captured frames in native/browser viewers, device
loss/resize/restart behavior and hardware encoder activation or honest software
fallback. Off-screen D3D device/rendering proof alone does not establish those.

### Reusable console diagnostics

`scripts/windows-console-probe.py` transfers a local diagnostic executable over
QGA, verifies SHA256 and runs it as the already logged-in local console user
through a temporary limited-user scheduled task. It uses Kubernetes/launcher
authorization, requires no guest password, and removes its task, binary and
output files after the run. It does not log in or replace the installed agent.
An internal task deadline bounds normal execution; as with any GPU diagnostic,
an unresponsive kernel/driver still requires operator recovery.

For output-selection inventory, build the workspace-agent
`kw-platform` example `capture-check`, then run:

```sh
python3 scripts/windows-console-probe.py \
  --namespace workspaces --vm windows-desktop \
  /path/to/capture-check.exe
```

For an animated hardware-output proof, build the bounded probe with MinGW:

```sh
x86_64-w64-mingw32-g++ -std=c++17 -O2 -Wall -Wextra -Werror -static \
  scripts/windows-d3d11-output-probe.cpp -o /tmp/windows-d3d11-output-probe.exe \
  -ld3d11 -ld3dcompiler -ldxgi -lgdi32 -luser32 -lole32 -luuid
python3 scripts/windows-console-probe.py \
  --namespace workspaces --vm windows-desktop \
  /tmp/windows-d3d11-output-probe.exe -- '\\.\DISPLAY2'
```

Choose the actual output name from the inventory, not the example number.
The probe shows an always-on-top diagnostic window on that output for ten
seconds, draws alternating colours using its non-software D3D11 adapter, then
checks those colours in DXGI desktop-duplication readback. It changes no display
modes or input state and saves no pixels. Exit 0 requires both colours to be
observed repeatedly. Presented draws alone, or one static capture frame, are
not acceptance. These tools test selection/render/capture independently of
encoder, transport, viewer, audio and real-application performance acceptance.
