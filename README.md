# kube-workspaces

A Kubernetes-native platform for managing container-based workspaces and desktops via a web UI.

Modelled on the Kubeflow Notebooks architecture but as a standalone, lightweight solution.

## Architecture

```
                    ┌─────────────┐
                    │  Dex/OIDC   │  (optional IdP)
                    └──────┬──────┘
                           │
┌─────────────┐     ┌──────▼──────┐     ┌─────────────────────────────┐
│  Frontend   │────▶│  API        │────▶│  Kubernetes API Server      │
│  (Next.js)  │     │  (Goa/Go)   │     │                             │
└─────────────┘     └─────────────┘     │  ┌─────────────────────┐    │
                          │             │  │ Workspace CRD       │    │
                          │             │  │ Image CRD           │    │
                     ┌────▼────┐        │  │ User CRD            │    │
                     │  Proxy  │        │  │ AuthConfig CRD      │    │
                     │  (Go)   │        │  └──────────┬──────────┘    │
                     └─────────┘        │             │               │
                                        │  ┌──────────▼──────────┐    │
                                        │  │ Controller          │    │
                                        │  │ (kubebuilder)       │    │
                                        │  └──────────┬──────────┘    │
                                        │             │               │
                                        │  ┌──────────▼────────────┐  │
                                        │  │ StatefulSet + Service │  │
                                        │  │ (per workspace)       │  │
                                        │  └───────────────────────┘  │
                                        └─────────────────────────────┘
```

## Components

| Component | Path | Description |
|-----------|------|-------------|
| **Controller** | `controller/` | Kubernetes controller (kubebuilder) that reconciles `Workspace`, `User`, and `AuthConfig` CRs |
| **API** | `api/` | REST API service (Goa framework) providing workspace CRUD, volumes, images, auth, and a reverse proxy for workspace web UIs |
| **Frontend** | `frontend/` | Next.js web UI with dashboard, workspace management, user management, namespace filtering, dark mode |
| **Deploy** | `deploy/` | Helm chart, Kustomize manifests, and ArgoCD Application for deployment |

## Features

- Full PodSpec flexibility per workspace (like Kubeflow Notebook CRD)
- Browser-based access to workspaces via built-in reverse proxy (WebSocket support)
- **Optional authentication** via OIDC (Dex, Okta, Auth0, or any OIDC provider)
- **Kubernetes-native RBAC** — three roles: admin, editor, viewer
- **Personal namespaces** — auto-created per user with configurable naming template
- **No database required** — all state in CRDs, Secrets, and native RBAC objects
- Namespace filtering with global selector persisted in localStorage
- Dark mode with class-based toggle
- Volume (PVC) management - create, list, attach to workspaces
- Start/Stop workspaces without deleting them (annotation-based)
- Admin section with user management, auth settings, API docs, and CRD browser
- Workspace detail view with Overview, Logs, Events, Metrics, and YAML tabs

## Quick Start

### Prerequisites

- Go 1.24+ (controller) and Go 1.26+ (API)
- Node.js 20+
- Docker
- kubectl with access to a Kubernetes cluster
- kind (for local development)

### Local Development

1. Create a kind cluster and install the CRDs:
```bash
kind create cluster
make install-crd
```

2. Run all components (in separate terminals):
```bash
make run-controller   # Terminal 1
make run-api          # Terminal 2
make run-frontend     # Terminal 3
```

3. Open http://localhost:3000 in your browser.

Authentication is disabled by default — no login is required. See [Authentication](#authentication) to enable it.

### Deploy to a Cluster

Deployment options (ArgoCD, Helm, Kustomize) are described in [`docs/`](docs/).
Before going to production, set your own hostnames — see
[`docs/domains.md`](docs/domains.md) for how to override the placeholder domains
via Helm values or kustomize patches.

#### Quick deploy with ArgoCD:
```bash
kubectl apply -f deploy/argocd/application.yaml
```

#### Quick deploy with Helm:
```bash
helm install kube-workspaces deploy/helm/kube-workspaces/ \
  --namespace kube-workspaces-system --create-namespace
```

#### Quick deploy with Kustomize:
```bash
kubectl apply --server-side -k deploy/kustomize/base/
```

### Docker Images

Build all images:
```bash
docker build -t kube-workspaces-controller:latest -f controller/Dockerfile controller/
docker build -t kube-workspaces-api:latest -f api/Dockerfile api/
docker build -t kube-workspaces-frontend:latest -f frontend/Dockerfile frontend/
```

For kind clusters, load images:
```bash
kind load docker-image kube-workspaces-controller:latest \
  kube-workspaces-api:latest kube-workspaces-frontend:latest
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

Cluster-scoped CRD defining available workspace images with default configuration:

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

Use the following prompt with an LLM coding agent (e.g. Claude, GPT) to deploy kube-workspaces to your current Kubernetes context:

> Deploy kube-workspaces to my Kubernetes cluster using the current kubectl context. Clone https://github.com/kube-workspaces/deploy.git, build all three Docker images (controller, api, frontend) from their respective Dockerfiles, load them into the cluster (or push to a registry if not using kind), then apply the Kustomize manifests with `kubectl apply --server-side -k deploy/kustomize/base/`. After deployment, verify all pods in `kube-workspaces-system` are running, then set up port-forwards: frontend on localhost:3000 and API on localhost:8888. Create a sample workspace using the code-server image to verify end-to-end functionality.

For kind clusters specifically:

> Deploy kube-workspaces to my local kind cluster. Clone https://github.com/kube-workspaces/deploy.git, build the Docker images (`docker build -t kube-workspaces-controller:latest -f controller/Dockerfile controller/`, same pattern for api/ and frontend/), load them with `kind load docker-image`, apply manifests with `kubectl apply --server-side -k deploy/kustomize/base/`, wait for rollout, then port-forward the frontend (port 3000) and API (port 8888) services from the `kube-workspaces-system` namespace.

## License

Apache License 2.0
