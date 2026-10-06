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

## Preflight

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

## Tool checks

```sh
python3 -m unittest discover -s scripts -p 'test_windows_vm_proof.py'
make test-lint
```

Versioned references:
[KubeVirt 1.9 GA gates](https://github.com/kubevirt/kubevirt/blob/v1.9.0/pkg/virt-config/featuregate/inactive.go),
[backend PVC selection/ownership](https://github.com/kubevirt/kubevirt/blob/v1.9.0/pkg/storage/backend-storage/backend-storage.go).
