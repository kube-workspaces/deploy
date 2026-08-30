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

## Prerequisites

- `kubectl` with access to your target cluster
- `kind` — only for the local cluster method
- `helm` 3.8+ — only for the Helm method

No images need to be built: the manifests reference the published
`ghcr.io/kube-workspaces/*` images.

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

The chart ships the CRDs and, by default, a curated catalog of 5 example
images.

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
| `installExampleImages` | `true` | Curated set of 5 example images |
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