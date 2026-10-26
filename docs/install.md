# Installation

Kube Workspaces can be deployed to any Kubernetes cluster using four supported
methods: a local kind cluster for development, and Kustomize, Helm, or ArgoCD
for production. Every method deploys the same published images and CRDs — pick
the one that matches how you manage the rest of your cluster.

All installs below deploy **without authentication** (it is opt-in and off by
default). See [Authentication](authentication.md) to enable OIDC or local auth
after deploying. Before going to production, set your own hostnames — the
manifests use the placeholder domain `workspaces.example.com`, which is not
issued by real ACME providers; see [Customizing your domain](domains.md).

## Git-backed image catalogs

An ImageRepository can be added under **Admin → Image Repositories** or as a
cluster-scoped CR. Its first sync imports missing images and **adopts any existing
Image CR with the same metadata.name**, including images installed by Helm or
manually. The repository manifest replaces the complete image spec and records
the repository name, Git URL/ref/commit, and file path. The Images page can then
filter by source repository. Images with no imported source remain “Not recorded”.

For a fresh Helm installation, use these values to let Git manage the catalog:

```yaml
installExampleImages: false
installCatalogImages: false
imageRepositories:
  - name: image-catalog
    url: https://github.com/kube-workspaces/image-catalog.git
    ref: main
    paths: [images]
    syncInterval: 10m
```

Paths are scanned **non-recursively**. Add separate repositories or list additional
paths for `images/kasm/core`, `images/kasm/desktop`, or `images/linuxserver`.
Avoid overlapping image names between repositories: the last sync wins ownership.
After successful imports, removing an image from the owning repository's paths
prunes that Image CR. Removing the ImageRepository itself leaves imported images.

For an existing installation, add the repository and trigger a sync to backfill
provenance without deleting/recreating the Image CRs:

```bash
kubectl annotate imagerepositories.kubeworkspaces.io --all \
  kubeworkspaces.io/sync="$(date -u +%s)" --overwrite
kubectl get imagerepositories.kubeworkspaces.io
kubectl get images.kubeworkspaces.io -L kubeworkspaces.io/image-repository
```

Stop reconciling adopted Image specs from static Helm/ArgoCD manifests so they
do not compete with Git sync. When removing static manifests from an existing
release, use your deployment tool's retain/orphan mechanism to hand them over
without pruning them. Image adoption preserves Kubernetes identity and unrelated
metadata and does not recreate running workspaces. The API must also be upgraded
to a build exposing `source_repository`; recording labels alone is not enough
for the frontend filter.

## Prerequisites

- `kubectl` with access to your target cluster
- `kind` — only for the local cluster method
- `helm` 3.8+ — only for the Helm method

No images need to be built: the manifests reference the published
`ghcr.io/kube-workspaces/*` images.

**Optional — VM workspaces.** `spec.type: vm` requires
[KubeVirt](https://kubevirt.io) in the cluster. Install it separately or enable the
chart's vendored operator/CR with `kubevirt.enabled: true`. On a local/kind
cluster without nested virtualization, enable
software emulation in the KubeVirt CR (`spec.configuration.developerConfiguration.useEmulation: true`).
The controller detects the KubeVirt CRDs and reports a `KubeVirtNotInstalled`
status condition on any `vm` workspace created without them; container and
scratch workspaces work regardless.

### Optional GPU support

Choose the allocation path for the workspace type; see the [GPU guide](gpu.md)
for a comparison and exact resource names.

**Container and scratch workspaces:** install a compatible host GPU driver,
container device plugin and any required runtime integration, then request its
advertised resource through `container.gpu_request` / `container.gpu_vendor` or
the Workspace PodSpec. The application image needs matching userspace libraries
and device permissions. These host-driven GPUs do not require KubeVirt, IOMMU
PCI assignment, or binding the GPU to VFIO. The optional
[Intel render-node recipe](container-gpu.md) includes allocation manifests and
Craft Apps / PhotoCraft verification. GPU drivers and that container plugin are
separately operator-managed, not installed by the chart.

**VM GPU assignment:** general VMs accept a generic GPU request;
[managed Windows VMs](windows-vm.md#experimental-render-only-gpu-profiles) use
an operator-declared GPU profile instead. To assign hardware to a guest:

1. **Host device preparation.** For PCI assignment, GPU-bearing nodes need
   IOMMU enabled (`intel_iommu=on` / `amd_iommu=on` where applicable), suitable
   isolation and the **assigned PCI function** bound to `vfio-pci`. This can be
   a physical function or an SR-IOV VF. Mediated GPUs use their supported host
   driver/mdev setup instead; the whole physical GPU is not bound to VFIO.
2. **A device plugin advertising the resource.** The GPU resource (e.g.
   `nvidia.com/gpu`) must be allocatable on the nodes. For NVIDIA this is the
   GPU Operator (sandbox device plugin / vGPU manager). For bare PCI/mediated
   devices KubeVirt's built-in device plugin discovers them — but only once
   they are **permitted** in step 3.
3. **Permitted in the KubeVirt CR.** Allowlist the device so KubeVirt can hand
   it to VMs. In the Helm chart, configure `kubevirt.gpuPassthrough.permittedHostDevices`
   (which renders `spec.configuration.permittedHostDevices` on the KubeVirt CR):

   ```yaml
   kubevirt:
     gpuPassthrough:
       permittedHostDevices:
         pciHostDevices:
           - pciVendorSelector: "10DE:1EB8"
             resourceName: "nvidia.com/TU104GL_Tesla_T4"
         mediatedDevices:
           - mdevNameSelector: "GRID T4-1Q"
             resourceName: "nvidia.com/GRID_T4-1Q"
   ```

    (Vendor/product selectors come from `lspci`; mediated device selectors from
    `/sys/bus/pci/devices/*/mdev_supported_types/*/name`. When the device
    plugin advertises the resource directly, e.g. the NVIDIA GPU Operator's
    `nvidia.com/gpu`, asking for it by name still requires it to be permitted
    here before it can be assigned to a VM.)

    Compatible older Intel GVT-g integrated GPUs follow the mediated-device path
    (where supported, the host needs `i915.enable_gvt=1` and the `kvmgt` module; e.g.
    `mdevNameSelector: "GVTg_V5_4"` with `resourceName: "intel.com/GVTg_V5_4"`).
    Configure host/KubeVirt-mediated device creation so devices are recreated
    after a host reboot. Newer Intel GPUs may use a separate SR-IOV path; GVT-g
    settings are not a universal Intel GPU recipe. Guest-driver support is
    OS-specific; Windows guests need a signed driver that recognises the vGPU,
    which is a separate acceptance gate from exposing the resource.

For generic VMs, the controller maps recognised GPU resource names into
KubeVirt `domain.devices.gpus` plus scheduling limits; arbitrary container
resource names do not automatically become VM attachments. Managed Windows
profiles name the resource explicitly. See [VM GPU passthrough](vm.md#gpu-passthrough)
for the mapping limits. Allowlisting and resource capacity are prerequisites,
not evidence that a guest driver or application actually uses the device.

**VM display without assigned hardware — virtio-gpu.** Integrated and discrete
GPUs can both be hardware-assignment candidates when compatible. When you only
want a paravirtual **display** without assigning host GPU hardware, set
`videoDevice: virtio` on the Image CR. The controller then emits
`domain.devices.video: {type: virtio}` on the VM (the virtio-gpu display,
enabled by default in KubeVirt's `VideoConfig` feature gate), giving better
noVNC performance and arbitrary guest-set resolutions than VGA emulation. The
`debian-xfce` example image ships with `videoDevice: virtio`; see the
[Image catalog](https://github.com/kube-workspaces/image-catalog) for the field
reference. This virtual display configuration alone does not enable host-GPU
3D rendering, compute or hardware video encoding in the guest.

> **CRDs must use server-side apply.** The `Workspace` CRD embeds a full
> Kubernetes `PodSpec` and is ~658 KiB, far over the 256 KiB
> `last-applied-configuration` annotation limit. Plain `kubectl apply -f` fails
> on it — every method below applies the CRDs with `--server-side` (or its
> ArgoCD equivalent).

## Local cluster (kind)

Deploy to a throwaway local cluster for development:

```bash
kind create cluster

make install-crd           # CRDs (server-side apply)
make deploy-kustomize      # components
make install-images        # workspace image catalog
make port-forward-frontend # UI on localhost:3000
```

Open <http://localhost:3000>. No login is required.

The Ingress in `kustomize/base` hardcodes `ingressClassName: traefik` and a
placeholder hostname, so it is inert on a default kind cluster —
port-forwarding is the only way in.

To tear everything down:

```bash
kind delete cluster
```

## Kustomize

Apply the CRDs first, then the components. Both must use server-side apply:

```bash
kubectl apply --server-side -k kustomize/crds/
kubectl apply --server-side -k kustomize/base/
```

`kustomize/base` does **not** create any `Image` CRs — without the catalog the
UI is empty. Install it separately:

```bash
kubectl apply --server-side -f images.yaml   # or: make install-images
```

Set your own hostnames with a kustomize overlay before going to production —
see [Customizing your domain](domains.md#kustomize).

## Helm

The chart ships the CRDs and, by default, a curated catalog of example images
(including Alpine, Debian, and the Debian Desktop XFCE VM images for
`spec.type: vm`).

From the published chart, without cloning this repository:

```bash
helm install kube-workspaces \
  oci://ghcr.io/kube-workspaces/charts/kube-workspaces \
  --namespace kube-workspaces-system --create-namespace
```

From this repository:

```bash
helm install kube-workspaces helm/kube-workspaces/ \
  --namespace kube-workspaces-system --create-namespace
```

### Workspace images

| Setting | Default | Effect |
|---------|---------|--------|
| `installExampleImages` | `true` | Curated set of example images (incl. Alpine + Debian VMs) |
| `installCatalogImages` | `false` | Install the full vendored catalog instead |
| `images` | `[]` | Add your own `Image` CRs regardless of the catalog setting |

For example, to install the full catalog:

```bash
helm install kube-workspaces oci://ghcr.io/kube-workspaces/charts/kube-workspaces \
  --namespace kube-workspaces-system --create-namespace \
  --set installCatalogImages=true
```

### Installing into an existing namespace

Installing into a namespace managed elsewhere requires disabling release
namespace creation — Helm cannot adopt a namespace it did not create:

```bash
helm install kube-workspaces oci://ghcr.io/kube-workspaces/charts/kube-workspaces \
  --namespace my-shared-namespace \
  --set namespaces.createReleaseNamespace=false
```

Without this, the install fails with `invalid ownership metadata`. The
**workspace** namespace is still created; control it with
`namespaces.createWorkspaceNamespace`.

### Upgrading the chart

Helm installs the CRDs in the chart's `crds/` directory on `helm install` but
does **not** upgrade them on `helm upgrade`. When a new chart version changes the
CRDs, apply them first, then upgrade the chart:

```bash
kubectl apply --server-side -k https://github.com/kube-workspaces/deploy/kustomize/crds
helm upgrade kube-workspaces \
  oci://ghcr.io/kube-workspaces/charts/kube-workspaces \
  --namespace kube-workspaces-system
```

The `Workspace` CRD is too large for client-side apply, so the CRDs must always
be applied with `--server-side`. Add `--reuse-values` (or your usual values
flags) if you customized the release.

## ArgoCD

Argo CD deploys from the **git remote**, so it syncs the last pushed commit
rather than your local working tree.

Apply the CRDs Application first — the components Application will not sync
cleanly against missing CRDs:

```bash
kubectl apply -f argocd/application-crds.yaml
kubectl apply -f argocd/application.yaml
```

The CRDs Application syncs with `Replace=true` and the components Application
with `ServerSideApply=true`, matching the kustomize requirements above.

Neither Application creates `Image` CRs (they point at `kustomize/crds` and
`kustomize/base`). To populate the UI catalog, apply `images.yaml` with
`kubectl` or via a third Application pointing at
`https://github.com/kube-workspaces/deploy` with `images.yaml` as a file source.

## Verify the deployment

Every method lands in the `kube-workspaces-system` namespace. Confirm the CRDs
are established and all four deployments are available:

```bash
kubectl wait --for=condition=Established \
  crd/workspaces.kubeworkspaces.io crd/images.kubeworkspaces.io \
  crd/users.kubeworkspaces.io crd/authconfigs.kubeworkspaces.io \
  crd/platformconfigs.kubeworkspaces.io crd/poddefaults.kubeworkspaces.io \
  crd/sshkeys.kubeworkspaces.io \
  --timeout=60s

kubectl wait --for=condition=Available deployment --all \
  -n kube-workspaces-system --timeout=300s
```

Then access the UI:

```bash
kubectl port-forward -n kube-workspaces-system svc/kube-workspaces-frontend 3000:80
```

Open <http://localhost:3000>.

## Next steps

- [Authentication](authentication.md) — enable OIDC or local auth
- [Customizing your domain](domains.md) — set your hostname and ingress before production
- [Proxy](proxy.md) — how workspace traffic is routed
- [Security](security.md) — what is hardened by default
