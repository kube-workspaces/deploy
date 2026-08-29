# kube-workspaces

A Helm chart for deploying [kube-workspaces](https://github.com/kube-workspaces) — a
Kubernetes-native platform for managing container-based workspaces and desktops via a
web UI. This chart installs all four platform components (controller, API, proxy,
frontend), their RBAC, and an optional bundled [Dex](https://dexidp.io/) OIDC provider.

## Introduction

This chart installs:

- **controller** — a kubebuilder controller reconciling `Workspace`, `Image`, `User`,
  `AuthConfig`, `PodDefault` and `PlatformConfig` custom resources
- **api** — a REST API (workspace CRUD, volumes, images, auth) that the frontend and
  `kubectl`-adjacent tooling talk to
- **proxy** — a session-authenticated reverse proxy for browser access to running
  workspaces (WebSocket support)
- **frontend** — a Next.js web UI: dashboard, workspace management, admin/user
  management, dark mode
- Supporting **RBAC** (ServiceAccount, ClusterRole/ClusterRoleBinding for the
  controller/API/proxy, namespaced Role/RoleBinding for local-auth password Secrets),
  **Namespaces**, and a curated or full **Image** CR catalog
- Optionally, a bundled **Dex** sub-chart as an OIDC provider

Authentication (OIDC and/or local username/password) is **opt-in and disabled by
default** — installing with defaults gives every caller full access. See
[Authentication](#authentication) before exposing an install beyond a local cluster.

## Prerequisites

- A Kubernetes cluster (tested against 1.31 — see [`docs/testing.md`](../../docs/testing.md))
- Helm 3.8+
- The chart's CRDs (installed automatically — see [CRDs](#crds))

## Installing the Chart

From the published OCI chart (no clone required):

```bash
helm install kube-workspaces \
  oci://ghcr.io/kube-workspaces/charts/kube-workspaces \
  --namespace kube-workspaces-system --create-namespace
```

Or from a local clone of [kube-workspaces/deploy](https://github.com/kube-workspaces/deploy):

```bash
helm install kube-workspaces helm/kube-workspaces/ \
  --namespace kube-workspaces-system --create-namespace
```

Then port-forward the frontend and open <http://localhost:3000>:

```bash
kubectl port-forward -n kube-workspaces-system svc/kube-workspaces-frontend 3000:80
```

Installing into a **pre-existing namespace** managed elsewhere (e.g. by another tool)
requires disabling creation of the release namespace, since Helm cannot adopt a
namespace it did not create itself:

```bash
helm install kube-workspaces oci://ghcr.io/kube-workspaces/charts/kube-workspaces \
  --namespace my-shared-namespace \
  --set namespaces.createReleaseNamespace=false
```

Without this, install fails with `invalid ownership metadata; label validation
error: missing key "app.kubernetes.io/managed-by"`. See
[`docs/domains.md`](../../docs/domains.md#namespaces-and---create-namespace) for
more on this and on setting your own hostname before going to production.

## Uninstalling the Chart

```bash
helm uninstall kube-workspaces --namespace kube-workspaces-system
```

This removes everything the chart created **except CRDs** (Helm never deletes
CRDs it installed, to avoid taking running `Workspace`/`User`/etc. resources with
it). Remove them explicitly if you are decommissioning the platform entirely:

```bash
kubectl delete crd \
  workspaces.kubeworkspaces.io images.kubeworkspaces.io \
  users.kubeworkspaces.io authconfigs.kubeworkspaces.io \
  platformconfigs.kubeworkspaces.io poddefaults.kubeworkspaces.io
```

Deleting the CRDs deletes every custom resource of those kinds, cluster-wide.

## Upgrading the Chart

```bash
helm upgrade kube-workspaces \
  oci://ghcr.io/kube-workspaces/charts/kube-workspaces \
  --namespace kube-workspaces-system
```

`appVersion` (see [Versioning](#versioning-and-appversion)) pins the exact
controller/api/proxy/frontend image tags installed — a chart upgrade only changes
component versions when `appVersion` changed too.

## CRDs

The chart vendors CRD manifests under `crds/` and lets Helm install them
automatically on `helm install` (Helm's [CRD convention](https://helm.sh/docs/chart_best_practices/custom_resource_definitions/)).
Helm does **not** upgrade or delete CRDs it installed this way — see
[Uninstalling](#uninstalling-the-chart) and, for upgrades, apply the CRDs
directory yourself first if a new chart version changed them:

```bash
kubectl apply --server-side -k https://github.com/kube-workspaces/deploy/kustomize/crds
```

The CRDs here are generated from the [controller](https://github.com/kube-workspaces/controller)
repo and kept in sync with `kustomize/crds/` in this repo — see
[CRD Sync](../../CONTRIBUTING.md#crd-sync) in `CONTRIBUTING.md`.

## Versioning and `appVersion`

The five kube-workspaces repositories are released together but versioned somewhat
independently in this chart:

- **`version`** (`Chart.yaml`) is this chart's own release line — bump it for any
  chart change, whether or not the component images changed.
- **`appVersion`** (`Chart.yaml`) names the controller/api/proxy/frontend image tag
  this chart version installs (all four share one number). It only advances when a
  new component release exists to pin.

A chart-only fix (an Ingress path, a template guard) bumps `version` without
`appVersion` changing — that is expected, not a bug. See
[`docs/releasing.md`](../../docs/releasing.md) for the full release procedure.

Override the images installed without touching `appVersion`, per-component:

```bash
helm upgrade kube-workspaces oci://ghcr.io/kube-workspaces/charts/kube-workspaces \
  --set controller.image.tag=v0.4.0-rc.1
```

Leaving `*.image.tag` empty (the default) installs `Chart.AppVersion` for that
component.

## Configuration

The following table lists commonly overridden values. See
[`values.yaml`](values.yaml) for the complete, commented set — every value below
links back to the section explaining it in context.

### Global

| Key | Default | Description |
|-----|---------|--------------|
| `replicaCount` | `1` | Replica count for every Deployment (controller, api, proxy, frontend) |
| `serviceAccount.create` | `true` | Create a ServiceAccount for controller/api/proxy to share |
| `serviceAccount.name` | `""` | Override the generated ServiceAccount name |
| `serviceAccount.annotations` | `{}` | Annotations on the created ServiceAccount |
| `workspaceRoles.create` | `true` | Install the `workspace-admin/editor/viewer-role` ClusterRoles the User controller binds per-namespace |
| `nameOverride` / `fullnameOverride` | unset | Standard Helm chart naming overrides |

### Controller, API, Proxy, Frontend

Each component exposes the same shape under its own top-level key
(`controller`, `api`, `proxy`, `frontend`):

| Key | Default | Description |
|-----|---------|--------------|
| `<component>.image.repository` | `ghcr.io/kube-workspaces/<component>` | Image repository |
| `<component>.image.tag` | `""` (→ `Chart.AppVersion`) | Image tag override — see [Versioning](#versioning-and-appversion) |
| `<component>.image.pullPolicy` | `Always` | Set to `IfNotPresent` for `kind load docker-image` / locally built images |
| `<component>.resources` | see `values.yaml` | Standard Kubernetes resource requests/limits |

Component-specific extras:

| Key | Default | Description |
|-----|---------|--------------|
| `api.port` | `8080` | Container port the API listens on |
| `api.externalHost` | `""` | `Host` header forwarded to proxied workspace backends; also derives the OIDC callback URL when `auth.callbackURL` is unset |
| `api.allowedOrigins` | `https://workspaces.example.com,http://localhost:3000` | CORS allow-list for the API — set this to your real frontend origin(s) |
| `proxy.port` | `8080` | Container port the proxy listens on |
| `proxy.allowedOrigins` | `https://workspaces.example.com,http://localhost:3000` | CORS allow-list for the proxy |
| `proxy.pathPrefix` | `/proxy` | Path prefix for proxy routes (single-mode; do not change without also updating the Ingress paths) |
| `proxy.service.type` | `ClusterIP` | Proxy Service type |
| `frontend.port` | `3000` | Container port the frontend listens on |
| `frontend.externalApiUrl` | `""` | Override the API base URL baked into the frontend at runtime, for split-host deployments |

See [`docs/domains.md`](../../docs/domains.md) before going to production — it
covers `externalHost`, `allowedOrigins`, and the callback URL together, since
getting one without the others wrong is the most common early misconfiguration.

### Namespaces

| Key | Default | Description |
|-----|---------|--------------|
| `namespaces.create` | `true` | Master switch — when `false`, no `Namespace` objects are rendered at all |
| `namespaces.createReleaseNamespace` | `false` | Render a `Namespace` for `.Release.Namespace`. Leave `false` with `helm install --create-namespace` (the documented path); only set `true` when something else — e.g. Argo CD — needs the namespace tracked as a chart resource, and in that case do **not** pass `--create-namespace` too |
| `namespaces.createWorkspaceNamespace` | `true` | Also create the namespace named by `workspaceNamespace` |
| `workspaceNamespace` | `workspaces` | Default namespace workspaces are created into |

### Images (workspace catalog)

Workspace images are `Image` custom resources, not Helm values for individual
images. The chart vendors a catalog from
[kube-workspaces/image-catalog](https://github.com/kube-workspaces/image-catalog):

| Key | Default | Description |
|-----|---------|--------------|
| `installExampleImages` | `true` | Install a curated 5-image subset (code-server, debian-desktop, kasm, kasmweb-chrome, kasmweb-desktop) so a fresh install has something to launch immediately |
| `installCatalogImages` | `false` | Install the full catalog (38+ images) instead of the curated subset. Takes precedence over `installExampleImages` when both are true |
| `images` | `[]` | Additional/custom `Image` CRs layered on top of whichever catalog set is installed. Each entry needs an RFC 1123-compliant `name`; every other field is passed through to the `Image` spec verbatim — see [`values.yaml`](values.yaml) for the shape |

### Ingress

| Key | Default | Description |
|-----|---------|--------------|
| `ingress.enabled` | `false` | Render an `Ingress` |
| `ingress.className` | `""` | `ingressClassName` (e.g. `traefik`, `nginx`) |
| `ingress.annotations` | `{}` | e.g. `cert-manager.io/cluster-issuer` or ingress-controller-specific middleware |
| `ingress.middlewares` | `[]` | Optional Traefik `Middleware` CRs (`traefik.io/v1alpha1`), rendered into the release namespace. Each entry is `{name, spec}`; `spec` is passed through verbatim. Reference one from an annotation as `<release-namespace>-<name>@kubernetescrd` |
| `ingress.hosts` | one `workspaces.local` host, five paths | Host → paths mapping. **Overriding `hosts` replaces the whole list** — each host you supply needs its own complete `paths` list, or the chart fails the render rather than emit an Ingress rule with no paths |
| `ingress.tls` | `[]` | `[{hosts: [...], secretName: ...}]` entries |

The default path set routes `/proxy` to the proxy Service, `/v1`, `/auth` and
`/openapi` to the API Service, and everything else (`/`) to the frontend —
**not** `/proxy` to the API, which has no routes there and 404s all workspace
traffic if misrouted. See [`docs/proxy.md`](../../docs/proxy.md) for the full
routing table and [`docs/domains.md`](../../docs/domains.md) for customizing
hosts/paths without hand-editing the whole list.

Traefik ingress controllers need a `stripPrefix` middleware to strip the `/api`
prefix before requests reach the API service. The chart can render it for you:

```yaml
ingress:
  enabled: true
  className: traefik
  annotations:
    traefik.ingress.kubernetes.io/router.middlewares: kube-workspaces-system-kube-workspaces-strip-api@kubernetescrd
  middlewares:
    - name: kube-workspaces-strip-api
      spec:
        stripPrefix:
          prefixes:
            - /api
```

### Authentication

Authentication is **opt-in**; with `auth.enabled: false` (the default), every
caller has full access. Two independent, combinable methods are supported: OIDC
(federate to an external identity provider) and local username/password accounts.
See [`docs/authentication.md`](../../docs/authentication.md) for the full setup
guide with provider-specific notes — this table covers only the Helm values.

| Key | Default | Description |
|-----|---------|--------------|
| `auth.enabled` | `false` | Master switch for authentication |
| `auth.callbackURL` | `""` | Override the OIDC callback URL (derived from `api.externalHost` otherwise) |
| `auth.oidc.issuerURL` | `""` | OIDC issuer URL. Leave unset to run local-auth-only |
| `auth.oidc.clientID` | `""` | OAuth2 client ID |
| `auth.oidc.clientSecret.create` | `false` | If `true`, Helm creates the Secret from `auth.oidc.clientSecret.value`; if `false`, `auth.oidc.clientSecret.secretName`/`secretKey` must reference a Secret you create yourself |
| `auth.oidc.clientSecret.secretName` / `secretKey` | `kube-workspaces-oidc` / `client-secret` | Secret name/key for the client secret |
| `auth.oidc.scopes` | `[openid, email, profile]` | OIDC scopes requested |
| `auth.oidc.usernameClaim` | `email` | JWT claim used as the username/identity |
| `auth.oidc.groupsClaim` | unset | JWT claim used for group membership, if your provider supplies one |
| `auth.session.signingKey.create` | `true` | If `true`, Helm auto-generates a random signing key Secret; sessions are HMAC-signed with this regardless of auth method, so it is required even for local-auth-only setups |
| `auth.session.signingKey.secretName` / `secretKey` | `kube-workspaces-session` / `signing-key` | Secret name/key for the session signing key |
| `auth.session.tokenExpiry` | `24h` | Session token lifetime |
| `auth.session.refreshExpiry` | `7d` | Refresh token lifetime |
| `auth.personalNamespaces.enabled` | `false` | Auto-create a personal namespace per user on first login |
| `auth.personalNamespaces.template` | `{{username}}` | Naming template for personal namespaces |
| `auth.registration.autoProvision` | `true` | Auto-create a `User` CR on first OIDC login |
| `auth.registration.defaultRole` | `editor` | Role assigned to auto-provisioned users |
| `auth.registration.allowedDomains` / `allowedEmails` | `[]` | Restrict auto-provisioning to matching email domains/addresses |
| `auth.registration.requireApproval` | `false` | Require an admin to approve auto-provisioned users before they can log in |
| `auth.adminEmails` | `[]` | Email addresses always granted the `admin` role, for bootstrapping OIDC admin access |
| `auth.authorization.restrictNamespaceAccess` | `false` | Restrict non-admin users to namespaces explicitly assigned to them (personal + `namespaceAccess`) instead of all namespaces |
| `auth.localAuth.enabled` | `false` | Enable local username/password authentication, independently of or alongside OIDC |
| `auth.localAuth.bootstrapAdmin.email` | `admin@local` | Identifier for the auto-created default local admin user |
| `auth.localAuth.bootstrapAdmin.skip` | `false` | Skip auto-creating the bootstrap admin (e.g. if one is already provisioned) |

Enabling `auth.localAuth.enabled` with no OIDC configured is the fastest path to
a working login with zero external dependencies — a default admin `User` is
auto-created with a randomly generated password stored in a Kubernetes Secret
(`kw-user-admin-at-local-local-auth` by default):

```bash
helm install kube-workspaces oci://ghcr.io/kube-workspaces/charts/kube-workspaces \
  --namespace kube-workspaces-system --create-namespace \
  --set auth.enabled=true \
  --set auth.localAuth.enabled=true

kubectl get secret kw-user-admin-at-local-local-auth \
  -n kube-workspaces-system -o jsonpath='{.data.password}' | base64 -d
```

The user is required to change this password on first login. See
[`docs/authentication.md`](../../docs/authentication.md) for password policy,
account lockout, creating additional users, and combining local auth with OIDC.

### Bundled Dex (optional OIDC provider)

| Key | Default | Description |
|-----|---------|--------------|
| `dex.enabled` | `false` | Install [Dex](https://dexidp.io/) as a sub-chart. When enabled, point `auth.oidc.issuerURL` at Dex's in-cluster service URL |
| `dex.*` | see [dex chart](https://github.com/dexidp/helm-charts) | Any value the upstream Dex chart accepts (storage backend, connectors, static clients, etc.) — see the commented example block in [`values.yaml`](values.yaml) |

Dex is useful when you want federation to providers without native OIDC support
(LDAP, SAML) or multiple simultaneous connectors (e.g. GitHub + Google) behind a
single issuer.

## Examples

Local cluster, no auth, curated image set (the defaults):

```bash
helm install kube-workspaces oci://ghcr.io/kube-workspaces/charts/kube-workspaces \
  --namespace kube-workspaces-system --create-namespace
```

Production-ish install with your own domain, the full image catalog, and Ingress:

```bash
helm install kube-workspaces oci://ghcr.io/kube-workspaces/charts/kube-workspaces \
  --namespace kube-workspaces-system --create-namespace \
  --set api.externalHost=workspaces.example.com \
  --set api.allowedOrigins=https://workspaces.example.com \
  --set proxy.allowedOrigins=https://workspaces.example.com \
  --set ingress.enabled=true \
  --set ingress.className=nginx \
  --set installCatalogImages=true
```

OIDC via an external provider, with personal namespaces and one seed admin:

```bash
helm install kube-workspaces oci://ghcr.io/kube-workspaces/charts/kube-workspaces \
  --namespace kube-workspaces-system --create-namespace \
  --set auth.enabled=true \
  --set auth.oidc.issuerURL=https://accounts.google.com \
  --set auth.oidc.clientID=<your-client-id> \
  --set auth.oidc.clientSecret.create=true \
  --set auth.oidc.clientSecret.value=<your-client-secret> \
  --set auth.personalNamespaces.enabled=true \
  --set 'auth.adminEmails[0]=you@example.com'
```

Both OIDC and local auth enabled at once — see
[`docs/authentication.md`](../../docs/authentication.md#enabling-local-auth-alongside-oidc)
for the full walkthrough.

## Testing this chart

This chart is covered by [helm-unittest](https://github.com/helm-unittest/helm-unittest)
suites (`tests/`) and by the layered deployment tests in the parent repo. From a
clone of [kube-workspaces/deploy](https://github.com/kube-workspaces/deploy):

```bash
make lint-helm       # helm lint
make test-lint       # full static validation, including helm-unittest and kubeconform
make test-deploy-helm  # install this chart on a throwaway kind cluster and smoke-test it
```

See [`docs/testing.md`](../../docs/testing.md) for the complete test-layer
description.

## Chart source

This chart lives in [kube-workspaces/deploy](https://github.com/kube-workspaces/deploy),
alongside Kustomize manifests and an ArgoCD `Application` covering the same
platform. See the parent repo's [`README.md`](../../README.md) for the
non-Helm deployment options and the overall project architecture.
