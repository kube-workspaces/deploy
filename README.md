# Kube Workspaces

A Kubernetes-native platform for managing container-based workspaces and desktops via a web UI.

Modelled on the Kubeflow Notebooks architecture but as a standalone, lightweight solution.

![GitHub Release](https://img.shields.io/github/v/release/kube-workspaces/deploy) ![License](https://img.shields.io/github/license/kube-workspaces/deploy) [![controller](https://img.shields.io/badge/ghcr.io-kube--workspaces%2Fcontroller-blue)](https://ghcr.io/kube-workspaces/controller) [![api](https://img.shields.io/badge/ghcr.io-kube--workspaces%2Fapi-blue)](https://ghcr.io/kube-workspaces/api) [![proxy](https://img.shields.io/badge/ghcr.io-kube--workspaces%2Fproxy-blue)](https://ghcr.io/kube-workspaces/proxy) [![frontend](https://img.shields.io/badge/ghcr.io-kube--workspaces%2Ffrontend-blue)](https://ghcr.io/kube-workspaces/frontend)
![Controller CI](https://img.shields.io/github/actions/workflow/status/kube-workspaces/controller/test.yml?label=controller%20CI) ![API CI](https://img.shields.io/github/actions/workflow/status/kube-workspaces/api/ci.yml?label=api%20CI) ![Proxy CI](https://img.shields.io/github/actions/workflow/status/kube-workspaces/proxy/ci.yml?label=proxy%20CI) ![Frontend CI](https://img.shields.io/github/actions/workflow/status/kube-workspaces/frontend/ci.yml?label=frontend%20CI)

## Architecture

![Architecture diagram](docs/architecture.svg)

## Components

| Component | Path | Description |
|-----------|------|-------------|
| **Controller** | `controller/` | Kubernetes controller (kubebuilder) that reconciles `Workspace`, `User`, and `AuthConfig` CRs |
| **API** | `api/` | REST API service (Goa framework) providing workspace CRUD, volumes, images, auth, and a reverse proxy for workspace web UIs |
| **Frontend** | `frontend/` | Next.js web UI with dashboard, workspace management, user management, namespace filtering, dark mode |
| **Deploy** | `deploy/` | Helm chart, Kustomize manifests, and ArgoCD Application for deployment |

## Features

- Full PodSpec flexibility per workspace (like Kubeflow Notebook CRD)
- Browser-based access to workspaces via built-in [reverse proxy](#workspace-proxy) (WebSocket support)
- **Optional [authentication](#authentication)** via OIDC (Dex, Okta, Auth0, or any OIDC provider)
- **Kubernetes-native [RBAC](#roles)** — three roles: admin, editor, viewer
- **[Personal namespaces](#personal-namespaces)** — auto-created per user with configurable naming template
- **No database required** — all state in CRDs, Secrets, and native RBAC objects
- Namespace filtering with global selector persisted in localStorage
- Dark mode with class-based toggle
- Volume (PVC) management - create, list, attach to workspaces
- Start/Stop workspaces without deleting them (annotation-based)
- Admin section with user management, auth settings, API docs, and CRD browser
- Workspace detail view with Overview, Logs, Events, Metrics, and YAML tabs

## Quick Start

### Prerequisites

- [kubectl](https://kubernetes.io/docs/tasks/tools/) with access to a Kubernetes cluster
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/) (for a local cluster)
- [Helm](https://helm.sh/docs/intro/install/) 3.8+ (only for the Helm install path)

Building the components from source additionally needs
[Go](https://go.dev/dl/) 1.24+ (controller) / 1.26+ (API and proxy),
[Node.js](https://nodejs.org/) 20+ (frontend) and
[Docker](https://docs.docker.com/get-docker/). See each component repo for
its own developer workflow — this repo only holds deployment manifests.

### Local cluster (kind)

Deploy the published images to a throwaway kind cluster:

```bash
kind create cluster

# CRDs must use server-side apply (the Workspace CRD exceeds the
# client-side annotation size limit)
make install-crd

make deploy-kustomize
make port-forward-frontend
```

Open <http://localhost:3000>. Authentication is disabled by default, so no
login is required — see [Authentication](#authentication) to enable it.

To tear it down: `kind delete cluster`.

### Deploy to a Cluster

Before going to production, set your own hostnames — see
[`docs/domains.md`](docs/domains.md) for how to override the placeholder
domains via Helm values or kustomize patches.

#### Quick deploy with ArgoCD:
```bash
kubectl apply -f argocd/application-crds.yaml
kubectl apply -f argocd/application.yaml
```

Apply the CRDs Application first — the components Application will not sync
cleanly against missing CRDs. Note that Argo CD syncs from the **git remote**,
so it deploys the last pushed commit rather than your local working tree.

#### Quick deploy with Helm:
```bash
helm install kube-workspaces helm/kube-workspaces/ \
  --namespace kube-workspaces-system --create-namespace
```

Or straight from the published chart, without cloning this repo:

```bash
helm install kube-workspaces \
  oci://ghcr.io/kube-workspaces/charts/kube-workspaces \
  --namespace kube-workspaces-system --create-namespace
```

Installing into a **pre-existing namespace** that is managed elsewhere (e.g. a
shared namespace provisioned by another tool) requires disabling creation of the
release namespace, since Helm cannot adopt a namespace it did not create:

```bash
helm install kube-workspaces oci://ghcr.io/kube-workspaces/charts/kube-workspaces \
  --namespace my-shared-namespace \
  --set namespaces.createReleaseNamespace=false
```

Without this, the install fails with
`invalid ownership metadata; label validation error: missing key "app.kubernetes.io/managed-by"`.
The workspace namespace is still created — control it with
`namespaces.createWorkspaceNamespace`.

#### Quick deploy with Kustomize:
```bash
kubectl apply --server-side -k kustomize/crds/
kubectl apply --server-side -k kustomize/base/
```

### Docker Images

Released images are published to GHCR and are what the manifests reference by
default — you do not need to build anything to deploy:

| Component | Image |
|-----------|-------|
| controller | `ghcr.io/kube-workspaces/controller` |
| api | `ghcr.io/kube-workspaces/api` |
| proxy | `ghcr.io/kube-workspaces/proxy` |
| frontend | `ghcr.io/kube-workspaces/frontend` |

To build from source, clone each component repo alongside this one and build
from its root (each repo has its own `Dockerfile`):

```bash
for c in controller api proxy frontend; do
  docker build -t "kube-workspaces-$c:dev" "../$c"
done
```

For kind clusters, load the locally built images and deploy with the test
overlay, which switches `imagePullPolicy` to `IfNotPresent` so the loaded
images are actually used:

```bash
kind load docker-image \
  kube-workspaces-controller:dev kube-workspaces-api:dev \
  kube-workspaces-proxy:dev kube-workspaces-frontend:dev

kubectl apply --server-side -k kustomize/overlays/test/
```

## Authentication

Authentication is **opt-in** and disabled by default. When disabled, the system operates without login — all users have full access (preserving backward compatibility).

### Enabling Auth

Authentication is **opt-in**. To enable it, create an `AuthConfig` CR and necessary secrets. 

**Note for Google OIDC:** Ensure your Redirect URI is set to `https://<YOUR-DOMAIN>/auth/callback` in the Google Cloud Console.

```yaml
apiVersion: kubeworkspaces.io/v1alpha1
kind: AuthConfig
metadata:
  name: default
spec:
  enabled: true
  oidc:
    issuerURL: https://accounts.google.com
    clientID: <YOUR-GOOGLE-CLIENT-ID>
    clientSecret:
      name: kube-workspaces-oidc-secret
      key: client-secret
  session:
    signingKey:
      name: kube-workspaces-session-secret
      key: signing-key
  personalNamespaces:
    enabled: true
    template: "{{username}}"
  registration:
    autoProvision: true
    defaultRole: editor
  adminEmails:
    - your-email@gmail.com
```

Create the required secrets:
```bash
kubectl create secret generic kube-workspaces-oidc-secret \
  --from-literal=client-secret=YOUR_CLIENT_SECRET \
  -n kube-workspaces-system

kubectl create secret generic kube-workspaces-session-secret \
  --from-literal=signing-key=$(openssl rand -hex 32) \
  -n kube-workspaces-system
```

### Supported Identity Providers

- **Dex** (recommended for multi-provider support) — supports LDAP, SAML, GitHub, GitLab, etc.
- **Okta** — direct OIDC integration
- **Auth0** — direct OIDC integration
- Any **OIDC-compliant** provider

### User Management

Users are managed as `User` CRDs (cluster-scoped). They can be managed via:
- The **Admin UI** at `/admin/users`
- **kubectl**: `kubectl get users.kubeworkspaces.io`

Users are auto-provisioned on first OIDC login when `registration.autoProvision` is enabled.

```yaml
apiVersion: kubeworkspaces.io/v1alpha1
kind: User
metadata:
  name: jane-doe
spec:
  email: jane@example.com
  displayName: "Jane Doe"
  role: editor
  namespaceAccess:
    - namespace: team-platform
      role: editor
```

### Roles

| Role | Permissions |
|------|-------------|
| **admin** | Full access to all namespaces, user management, settings |
| **editor** | Create/edit/delete workspaces in assigned namespaces |
| **viewer** | Read-only access to assigned namespaces |

### Personal Namespaces

When enabled, each user gets a personal namespace automatically created by the User controller. The namespace name is derived from the configurable template (default: `{{username}}`).

The controller also creates:
- A `RoleBinding` granting the user editor access
- An optional `ResourceQuota` (if configured in AuthConfig)

## CRDs

### Workspace

The `Workspace` custom resource wraps a full Kubernetes PodSpec, giving complete flexibility over container configuration:

```yaml
apiVersion: kubeworkspaces.io/v1alpha1
kind: Workspace
metadata:
  name: my-workspace
  namespace: workspaces
spec:
  template:
    spec:
      containers:
        - name: code-server
          image: codercom/code-server:latest
          args: ["--bind-addr", "0.0.0.0:8080", "--auth", "none"]
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: "500m"
              memory: "512Mi"
            limits:
              cpu: "2"
              memory: "2Gi"
```

### Start/Stop

Workspaces are stopped by adding the annotation `kubeworkspaces.io/stopped: "true"`, which sets the StatefulSet replicas to 0. Removing the annotation starts the workspace.

### Image

Cluster-scoped CRD defining available [workspace images](#available-images) with default configuration:

```yaml
apiVersion: kubeworkspaces.io/v1alpha1
kind: Image
metadata:
  name: code-server
spec:
  image: codercom/code-server:latest
  displayName: "Code Server (VS Code)"
  defaultPort: 8080
  icon: vscode
```

## Available Images

| Image | Port | Default Path | Description |
|-------|------|--------------|-------------|
| `codercom/code-server:latest` | 8080 | `/` | Browser-based VS Code (auth disabled by default) |
| `flaccid/debian-desktop:latest` | 6901 | `/vnc.html?resize=remote` | Full Linux desktop (noVNC) |

## Workspace Proxy

The API includes a built-in reverse proxy at `/proxy/{namespace}/{name}/{path...}` that provides direct browser access to running workspace web UIs.

### Features

- **WebSocket support**: Full WebSocket passthrough (needed for noVNC's `websockify` and code-server)
- **Location header rewriting**: Redirects from workspace apps stay under the proxy prefix
- **Escaped request handling**: Requests that escape the proxy prefix (e.g., apps referencing `/sw.js` or absolute paths) are caught via the `Referer` header and rerouted
- **No-op ServiceWorker**: Apps that try to register a ServiceWorker at root scope get a no-op SW
- **Per-image proxy configuration**: Each image can declare proxy behavior hints

### Local Access

Port-forward to access the UI and workspace proxies:

```bash
make port-forward-frontend   # localhost:3000 -> frontend UI (includes proxy)
make port-forward-api        # localhost:8888 -> API (direct proxy access, better WebSocket)
```

Connect to workspaces via the UI "Connect" button, or directly:
- Code Server: `http://localhost:8888/proxy/workspaces/{name}/`
- Debian Desktop: `http://localhost:8888/proxy/workspaces/{name}/vnc.html?resize=remote`

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/v1/workspaces` | List workspaces (supports `?namespace=` filter) |
| GET | `/v1/workspaces/{name}` | Get workspace |
| POST | `/v1/workspaces` | Create workspace |
| PUT | `/v1/workspaces/{name}` | Update workspace |
| DELETE | `/v1/workspaces/{name}` | Delete workspace |
| POST | `/v1/workspaces/{name}/start` | Start workspace |
| POST | `/v1/workspaces/{name}/stop` | Stop workspace |
| GET | `/v1/workspaces/{name}/logs` | Get container logs |
| GET | `/v1/workspaces/{name}/events` | Get workspace events |
| GET | `/v1/workspaces/{name}/pod` | Get pod details |
| GET | `/v1/workspaces/{name}/metrics` | Get pod metrics |
| GET | `/v1/volumes` | List volumes (supports `?namespace=` filter) |
| POST | `/v1/volumes` | Create volume |
| DELETE | `/v1/volumes/{name}` | Delete volume |
| GET | `/v1/images` | List available images |
| GET | `/v1/namespaces` | List namespaces |
| GET | `/healthz` | Health check |
| GET | `/openapi3.json` | OpenAPI 3.0 spec (JSON) |
| GET | `/proxy/{ns}/{name}/{path...}` | Reverse proxy to workspace web UI |
| GET | `/auth/config` | Public auth configuration |
| GET | `/auth/login` | Initiate OIDC login |
| GET | `/auth/callback` | OIDC callback |
| POST | `/auth/logout` | Clear session |
| GET | `/auth/me` | Current user info |
| GET | `/admin/users` | List users (admin) |
| POST | `/admin/users` | Create user (admin) |
| PUT | `/admin/users/{name}` | Update user (admin) |
| DELETE | `/admin/users/{name}` | Delete user (admin) |
| GET | `/admin/auth-config` | Get AuthConfig (admin) |
| PUT | `/admin/auth-config` | Update AuthConfig (admin) |
| GET | `/admin/crds/definitions` | List CRD definitions |
| GET | `/admin/crds/workspaces` | List raw workspace CRs |

## UI Pages

| Route | Description |
|-------|-------------|
| `/` | Dashboard with summary cards and workspace list |
| `/login` | SSO login page (shown when auth enabled) |
| `/workspaces` | Workspace table with status, actions |
| `/workspaces/new` | Create workspace form |
| `/workspaces/{name}` | Workspace detail (Overview, Logs, Events, Metrics, YAML) |
| `/volumes` | Volume list |
| `/volumes/new` | Create volume form |
| `/images` | Available images catalog |
| `/admin` | Admin index (visible to admins only when auth enabled) |
| `/admin/users` | User management (list, create, enable/disable, delete) |
| `/admin/settings` | Auth settings (OIDC config, namespaces, registration) |
| `/admin/api` | API documentation (Scalar) |
| `/admin/images` | Image CR editor |
| `/admin/crds` | CRD browser |

## LLM Deployment Prompt

Prompts for driving an LLM coding agent (Claude Code, Codex, Cursor, …) through
a deployment. Each one is self-contained, states explicit success criteria, and
avoids blocking commands so the agent does not hang waiting on a foreground
process.

### Deploy to the current kubectl context

> Deploy kube-workspaces to my Kubernetes cluster using the current kubectl
> context. Do not create or switch clusters — confirm the context first with
> `kubectl config current-context` and stop and ask me if it is not what I
> expect.
>
> 1. Clone `https://github.com/kube-workspaces/deploy.git` and work from the
>    repo root.
> 2. Install the CRDs: `kubectl apply --server-side -k kustomize/crds/`.
>    Server-side apply is mandatory — the Workspace CRD embeds a full PodSpec
>    and is ~658 KiB, far over the 256 KiB `last-applied-configuration`
>    annotation limit, so plain `kubectl apply -f` fails.
> 3. Install the components: `kubectl apply --server-side -k kustomize/base/`.
>    The manifests already point at the published `ghcr.io/kube-workspaces/*`
>    images, so do not build any images.
> 4. Install the workspace image catalog: `make install-images`. This applies
>    the cluster-scoped `Image` CRs from `images.yaml`. Skipping this leaves the
>    UI catalog empty — `kustomize/base` does not create any `Image` CRs.
>
> Then verify, and report a pass/fail line for each check:
>
> - All six CRDs are Established:
>   `kubectl wait --for=condition=Established crd/workspaces.kubeworkspaces.io crd/images.kubeworkspaces.io crd/users.kubeworkspaces.io crd/authconfigs.kubeworkspaces.io crd/platformconfigs.kubeworkspaces.io crd/poddefaults.kubeworkspaces.io --timeout=60s`
> - All four deployments are Available:
>   `kubectl wait --for=condition=Available deployment --all -n kube-workspaces-system --timeout=300s`
>   (expect `kube-workspaces-controller`, `-api`, `-proxy`, `-frontend`)
> - No container has restarted. Every pod must show `0` restarts and no
>   `CrashLoopBackOff`:
>   `kubectl get pods -n kube-workspaces-system -o wide`
> - The API is healthy. Start a **background** port-forward, poll, then kill it:
>   `kubectl port-forward -n kube-workspaces-system svc/kube-workspaces-api 8888:80 &`
>   then `curl -fsS http://localhost:8888/healthz` must return `{"status":"ok"}`.
> - `curl -fsS http://localhost:8888/v1/images` lists the catalog entries you
>   applied in step 4.
> - The frontend serves HTML: background-forward
>   `svc/kube-workspaces-frontend 3000:80` and check
>   `curl -fsS http://localhost:3000/` returns HTTP 200 with an HTML body. The
>   frontend has no `/healthz` endpoint — `/` is its probe path.
>
> If any deployment fails to become Available, diagnose before continuing:
> `kubectl describe pod` on the not-ready pod, `kubectl logs` for its
> containers, and `kubectl get events -n kube-workspaces-system --sort-by=.lastTimestamp`.
> Report the root cause rather than retrying blindly.
>
> Finally, tell me the exact commands to re-open the port-forwards myself, and
> do not leave any background port-forward processes running.

### Deploy to a local kind cluster

> Deploy kube-workspaces to a local kind cluster.
>
> 1. `kind create cluster --name kube-workspaces`
> 2. Clone `https://github.com/kube-workspaces/deploy.git`, then from the repo
>    root run `make install-crd && make deploy-kustomize && make install-images`.
> 3. Wait for readiness:
>    `kubectl wait --for=condition=Available deployment --all -n kube-workspaces-system --timeout=300s`
>
> Verify with a background port-forward (never a foreground one):
>
> - `kubectl port-forward -n kube-workspaces-system svc/kube-workspaces-api 8888:80 &`
>   → `curl -fsS http://localhost:8888/healthz` returns `{"status":"ok"}`
> - `kubectl port-forward -n kube-workspaces-system svc/kube-workspaces-proxy 8891:80 &`
>   → `curl -fsS http://localhost:8891/readyz` returns `{"status":"ok"}`
> - `kubectl port-forward -n kube-workspaces-system svc/kube-workspaces-frontend 3000:80 &`
>   → `curl -fsS http://localhost:3000/` returns HTTP 200 and HTML
>
> Kill every port-forward you started when done. Note that the Ingress in
> `kustomize/base` hardcodes `ingressClassName: traefik` and a placeholder
> hostname, so it is inert on a default kind cluster — port-forwarding is the
> only way in. Do not try to make the Ingress work.
>
> Report each check as pass/fail, and finish with the single command I need to
> delete everything (`kind delete cluster --name kube-workspaces`).

### Verify an end-to-end workspace

Run this after either deployment above to prove the controller and proxy
actually work, not just that the pods started:

> Using the current kubectl context with kube-workspaces already deployed,
> create a workspace and verify it end to end.
>
> 1. Apply this `Workspace` CR. Note that a raw `Workspace` does **not** need a
>    matching `Image` CR — `Image` CRs only populate the UI/API catalog and
>    supply defaults at creation time through the API. Use `traefik/whoami`
>    rather than a heavyweight IDE image so the pull is a few MB and the check
>    is fast:
>
>    ```yaml
>    apiVersion: kubeworkspaces.io/v1alpha1
>    kind: Workspace
>    metadata:
>      name: smoke-test
>      namespace: workspaces
>    spec:
>      template:
>        spec:
>          containers:
>            - name: whoami
>              image: traefik/whoami
>              ports:
>                - containerPort: 80
>                  name: workspace-port
>    ```
>
>    The `workspaces` namespace already exists — `kustomize/base` creates it.
>
> 2. Assert the controller reconciled it. It creates a StatefulSet and a Service
>    both named after the workspace, and the pod is `smoke-test-0`:
>    - `kubectl rollout status statefulset/smoke-test -n workspaces --timeout=180s`
>      (prefer this over `kubectl wait --for=jsonpath=...readyReplicas`, which
>      errors out when the field is not yet present)
>    - `kubectl get svc smoke-test -n workspaces` — expect port 80 targeting the
>      container's first port
>    - `kubectl get workspace smoke-test -n workspaces -o yaml` and confirm
>      `status.readyReplicas` is 1 and `status.conditions` reports ready
>
> 3. Assert the API sees it: background-forward the API to 8888, then
>    `curl -fsS "http://localhost:8888/v1/workspaces/smoke-test?namespace=workspaces"`
>    returns 200 with the workspace.
>
> 4. Assert the proxy routes to it: background-forward the proxy to 8891, then
>    `curl -fsS http://localhost:8891/proxy/workspaces/smoke-test/` returns the
>    whoami response body.
>
> 5. Exercise stop/start. Stopping is annotation-driven — the controller scales
>    the StatefulSet to 0 without deleting the CR:
>    - `curl -fsS -X POST "http://localhost:8888/v1/workspaces/smoke-test/stop?namespace=workspaces"`
>      → StatefulSet replicas becomes 0 and the CR gains the
>      `kubeworkspaces.io/stopped` annotation
>    - `curl -fsS -X POST "http://localhost:8888/v1/workspaces/smoke-test/start?namespace=workspaces"`
>      → replicas returns to 1 and the pod becomes Ready again
>
> 6. Clean up: `kubectl delete workspace smoke-test -n workspaces`, then confirm
>    the StatefulSet and Service are garbage-collected via owner references.
>    Kill all port-forwards.
>
> Report every step as pass/fail with the observed value. If a step fails, dump
> `kubectl describe workspace smoke-test -n workspaces`, the controller logs
> (`kubectl logs -n kube-workspaces-system deploy/kube-workspaces-controller`),
> and namespace events before drawing a conclusion.

## License

Apache License 2.0
