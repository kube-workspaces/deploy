# Authentication Setup Guide

This guide covers how to configure authentication for kube-workspaces, using
either an external OIDC provider or built-in local (username/password) accounts.
The two methods can be enabled independently or together.

## Overview

kube-workspaces supports two authentication methods:

- **OIDC** (OpenID Connect) - federate to an external identity provider:
  - **Dex** (bundled or external) - federated OIDC proxy supporting GitHub, GitLab, LDAP, SAML, and more
  - **Okta** - enterprise identity provider
  - **Any OIDC-compliant provider** - Google, Auth0, Keycloak, Azure AD, etc.
- **Local auth** - username/password accounts stored as Kubernetes Secrets, with
  no external dependency. A default admin user is created automatically the
  first time local auth is enabled.

Authentication is **opt-in** and disabled by default. When disabled, the system operates without auth (everyone has full access).

## Architecture

```
User Browser
    |
    v
Frontend (Next.js) -- /auth/login --------------> API (/auth/login) --> OIDC Provider
    |                                                   |
    |                -- /auth/login/local (email+pw) -->|
    |                                                    v
    |                                             API (/auth/callback) <-- Provider callback
    |                                                    |
    v                                                    v
Frontend (reads session)                         Sets httpOnly cookie (kw-session)
```

- Session tokens are HMAC-SHA256 signed JWTs stored in a `kw-session` httpOnly cookie
- The signing key is stored in a Kubernetes Secret, and is used for sessions
  regardless of which authentication method issued them
- Local user passwords are bcrypt-hashed and stored in a per-user Kubernetes
  Secret (`kw-user-<slug>-local-auth`), referenced from the `User` CR
- User state is stored in `User` CRDs (cluster-scoped)
- Configuration is stored in an `AuthConfig` CRD (singleton named `default`)

## Prerequisites

- kube-workspaces deployed (controller, API, frontend)
- CRDs installed (`kubectl apply --server-side -k deploy/kustomize/crds/`)
- For OIDC: an OIDC provider configured with a client ID and secret, and the
  API reachable at a stable URL for the OIDC callback
- For local auth: nothing extra — see [Option 5](#option-5-local-authentication) below

---

## Option 1: Bundled Dex (Helm)

The Helm chart includes Dex as an optional sub-chart. This is the simplest setup.

### 1. Create values file

```yaml
# values-auth.yaml
auth:
  enabled: true
  oidc:
    issuerURL: "https://dex.workspaces.example.com"
    clientID: "kube-workspaces"
    clientSecret:
      create: true
      value: "a-strong-random-secret"
    scopes: ["openid", "email", "profile", "groups"]
  session:
    signingKey:
      create: true
      # Leave value empty for auto-generation, or set explicitly:
      # value: "my-32-char-signing-key-here!!!!"
  personalNamespaces:
    enabled: true
    template: "{{username}}"
  registration:
    autoProvision: true
    defaultRole: "editor"
  adminEmails:
    - "admin@example.com"

api:
  externalHost: "workspaces.example.com"

dex:
  enabled: true
  config:
    issuer: "https://dex.workspaces.example.com"
    storage:
      type: kubernetes
      config:
        inCluster: true
    web:
      http: 0.0.0.0:5556
    staticClients:
      - id: kube-workspaces
        name: "Kube Workspaces"
        secret: "a-strong-random-secret"
        redirectURIs:
          - "https://workspaces.example.com/auth/callback"
    connectors:
      - type: github
        id: github
        name: GitHub
        config:
          clientID: "$GITHUB_CLIENT_ID"
          clientSecret: "$GITHUB_CLIENT_SECRET"
          redirectURI: "https://dex.workspaces.example.com/callback"
          orgs:
            - name: your-org
  ingress:
    enabled: true
    className: nginx
    hosts:
      - host: dex.workspaces.example.com
        paths:
          - path: /
            pathType: Prefix
    tls:
      - secretName: dex-tls
        hosts:
          - dex.workspaces.example.com
```

### 2. Install

```bash
helm dependency update deploy/helm/kube-workspaces/
helm install kube-workspaces deploy/helm/kube-workspaces/ \
  --namespace kube-workspaces-system \
  --create-namespace \
  -f values-auth.yaml
```

### 3. Verify

```bash
# Check AuthConfig status
kubectl get authconfig default -o yaml

# Should show:
#   status:
#     enabled: true
#     issuerReachable: true
#     conditions:
#       - type: Ready
#         status: "True"
#         reason: IssuerVerified
```

---

## Option 2: External Dex

If you already have Dex deployed separately, just configure the OIDC settings to point to it.

### 1. Create secrets

```bash
# Session signing key
kubectl create secret generic kube-workspaces-session \
  --namespace kube-workspaces-system \
  --from-literal=signing-key="$(openssl rand -base64 32)"

# OIDC client secret (must match what's configured in Dex)
kubectl create secret generic kube-workspaces-oidc \
  --namespace kube-workspaces-system \
  --from-literal=client-secret="your-dex-client-secret"
```

### 2. Create AuthConfig

```yaml
apiVersion: kubeworkspaces.io/v1alpha1
kind: AuthConfig
metadata:
  name: default
spec:
  enabled: true
  oidc:
    issuerURL: "https://dex.your-cluster.example.com"
    clientID: "kube-workspaces"
    clientSecret:
      name: "kube-workspaces-oidc"
      key: "client-secret"
    scopes: ["openid", "email", "profile", "groups"]
    usernameClaim: "email"
    groupsClaim: "groups"
  session:
    signingKey:
      name: "kube-workspaces-session"
      key: "signing-key"
    tokenExpiry: "24h"
    refreshExpiry: "7d"
  personalNamespaces:
    enabled: true
    template: "{{username}}"
  registration:
    autoProvision: true
    defaultRole: "editor"
  adminEmails:
    - "admin@example.com"
```

```bash
kubectl apply --server-side -f authconfig.yaml
```

### 3. Configure Dex static client

In your external Dex configuration, add:

```yaml
staticClients:
  - id: kube-workspaces
    name: "Kube Workspaces"
    secret: "your-dex-client-secret"
    redirectURIs:
      - "https://workspaces.example.com/auth/callback"
```

---

## Option 3: Okta

### 1. Create Okta application

1. In the Okta Admin Console, go to **Applications > Create App Integration**
2. Select **OIDC - OpenID Connect** and **Web Application**
3. Configure:
   - **App name**: Kube Workspaces
   - **Sign-in redirect URIs**: `https://workspaces.example.com/auth/callback`
   - **Sign-out redirect URIs**: `https://workspaces.example.com`
   - **Assignments**: Assign users/groups who should have access
4. Note the **Client ID** and **Client Secret**
5. Note your **Okta domain** (e.g., `dev-12345.okta.com`)

### 2. Create secrets

```bash
kubectl create secret generic kube-workspaces-session \
  --namespace kube-workspaces-system \
  --from-literal=signing-key="$(openssl rand -base64 32)"

kubectl create secret generic kube-workspaces-oidc \
  --namespace kube-workspaces-system \
  --from-literal=client-secret="<okta-client-secret>"
```

### 3. Create AuthConfig

```yaml
apiVersion: kubeworkspaces.io/v1alpha1
kind: AuthConfig
metadata:
  name: default
spec:
  enabled: true
  oidc:
    issuerURL: "https://dev-12345.okta.com"
    clientID: "0oa1234567890abcdef"
    clientSecret:
      name: "kube-workspaces-oidc"
      key: "client-secret"
    scopes: ["openid", "email", "profile", "groups"]
    usernameClaim: "email"
    groupsClaim: "groups"
  session:
    signingKey:
      name: "kube-workspaces-session"
      key: "signing-key"
    tokenExpiry: "24h"
    refreshExpiry: "7d"
  personalNamespaces:
    enabled: true
    template: "{{username}}"
  registration:
    autoProvision: true
    defaultRole: "editor"
    allowedDomains:
      - "yourcompany.com"
  adminEmails:
    - "admin@yourcompany.com"
```

### 4. Okta groups claim

To use Okta groups, add a **Groups claim** to the authorization server:

1. Go to **Security > API > default**
2. Click the **Claims** tab
3. Add a claim:
   - **Name**: `groups`
   - **Include in token type**: ID Token, Always
   - **Value type**: Groups
   - **Filter**: Matches regex `.*` (or specify specific groups)

---

## Option 4: Generic OIDC Provider

Any OIDC-compliant provider (Google, Auth0, Keycloak, Azure AD, etc.) can be used.

### Requirements

Your OIDC provider must:
- Support the Authorization Code flow
- Expose a `/.well-known/openid-configuration` endpoint at the issuer URL
- Return an `email` claim in the ID token (or configure `usernameClaim` accordingly)
- Support the configured `redirectURI` (`https://<your-host>/auth/callback`)

### Configuration

```yaml
apiVersion: kubeworkspaces.io/v1alpha1
kind: AuthConfig
metadata:
  name: default
spec:
  enabled: true
  oidc:
    issuerURL: "<provider-issuer-url>"
    clientID: "<your-client-id>"
    clientSecret:
      name: "kube-workspaces-oidc"
      key: "client-secret"
    scopes: ["openid", "email", "profile"]
    usernameClaim: "email"      # Adjust if your provider uses a different claim
    groupsClaim: "groups"       # Adjust or remove if not available
  session:
    signingKey:
      name: "kube-workspaces-session"
      key: "signing-key"
  personalNamespaces:
    enabled: true
    template: "{{username}}"
  registration:
    autoProvision: true
    defaultRole: "editor"
  adminEmails:
    - "admin@example.com"
```

### Provider-specific notes

| Provider | Issuer URL | Notes |
|----------|-----------|-------|
| Google | `https://accounts.google.com` | Requires `usernameClaim: "email"`, no native groups claim |
| Auth0 | `https://your-tenant.auth0.com/` | Trailing slash required; configure Rules for groups claim |
| Keycloak | `https://keycloak.example.com/realms/your-realm` | Native groups support via realm roles/groups mapper |
| Azure AD | `https://login.microsoftonline.com/<tenant-id>/v2.0` | Use `groupsClaim: "groups"`; requires API permissions for group claims |

---

## Option 5: Local Authentication

Local auth provides username/password login with no external identity provider.
It is the fastest way to get authentication running, and can be enabled
independently of OIDC, or alongside it (a user can have local auth, OIDC, or
both configured for the same email).

### Quick start (Kustomize)

```bash
kubectl apply --server-side -k deploy/kustomize/crds/
kubectl apply --server-side -k deploy/kustomize/overlays/auth-local/
```

This creates:
- An `AuthConfig` with `spec.enabled: true` and `spec.localAuth.enabled: true` (no OIDC)
- A session signing key Secret (`kube-workspaces-session`) — required for all
  sessions regardless of auth method, so it must exist even for local-only setups

Within a few seconds, the controller auto-creates a default admin `User`
(`admin@local` by default) with a randomly generated password stored in a
Secret named `kw-user-admin-at-local-local-auth` in `kube-workspaces-system`.

### Quick start (Helm)

```bash
helm install kube-workspaces helm/kube-workspaces/ \
  --namespace kube-workspaces-system --create-namespace \
  --set auth.enabled=true \
  --set auth.localAuth.enabled=true
```

Or via `make`:

```bash
make deploy-auth-local
```

### Retrieving the bootstrap admin password

```bash
make get-admin-password
# or directly:
kubectl get secret kw-user-admin-at-local-local-auth \
  -n kube-workspaces-system -o jsonpath='{.data.password}' | base64 -d
```

The plaintext `password` key only exists until the admin changes their
password for the first time (they are required to on first login) — after
that, only the bcrypt `passwordHash` key remains, and `get-admin-password`
will report an error.

### Customizing the bootstrap admin

```yaml
auth:
  enabled: true
  localAuth:
    enabled: true
    bootstrapAdmin:
      email: "root@example.com"   # defaults to admin@local
      skip: false                  # set true to skip auto-creation entirely
```

### Enabling local auth alongside OIDC

Add `spec.localAuth` to an AuthConfig that already has `spec.oidc` configured
(see `deploy/kustomize/overlays/auth/authconfig.yaml` for a commented example),
or with Helm:

```bash
helm upgrade kube-workspaces helm/kube-workspaces/ \
  --reuse-values \
  --set auth.oidc.issuerURL=https://dex.example.com \
  --set auth.localAuth.enabled=true
```

Both login methods appear on the login page; users can be created with either
method independently.

### Creating additional local users

Via the admin UI (`/admin/users` → New User → Auth method: Local password), or
via the API:

```bash
curl -X POST https://workspaces.example.com/admin/users \
  -H "Content-Type: application/json" \
  -b "kw-session=<admin-session-cookie>" \
  -d '{
    "email": "jane.doe@example.com",
    "displayName": "Jane Doe",
    "role": "viewer",
    "authMethod": "local"
  }'
```

Response includes a one-time `password` field (auto-generated if omitted from
the request). The user must change it on first login
(`spec.localAuth.mustChangePassword: true`).

### Resetting a local user's password

```bash
curl -X POST https://workspaces.example.com/admin/users/jane-doe-at-example-com/reset-password \
  -b "kw-session=<admin-session-cookie>"
```

Returns a new one-time password and sets `mustChangePassword: true` again.

### Password policy and lockout

- Minimum password length: 12 characters (enforced server-side on change/reset)
- Passwords are bcrypt-hashed (cost 12) before being stored
- After 5 consecutive failed login attempts for a user, that account is
  temporarily locked with exponential backoff (1m, 5m, 15m, then 30m), tracked
  in `User.status.failedLoginAttempts` / `status.lockedUntil`
- The `/auth/login/local` endpoint additionally applies a coarse per-IP rate
  limit, independent of per-user lockout

---

## User Management

### Creating users manually

Users are auto-created on first login when `registration.autoProvision` is true (OIDC), or via the admin API/UI (local auth — see [Option 5](#option-5-local-authentication)). You can also pre-create OIDC users directly as a CR:

```yaml
apiVersion: kubeworkspaces.io/v1alpha1
kind: User
metadata:
  name: jane-doe  # typically slugified email
spec:
  email: "jane.doe@example.com"
  displayName: "Jane Doe"
  role: editor
  namespaceAccess:
    - namespace: shared-team
      role: admin
```

```bash
kubectl apply -f user.yaml
```

Note: pre-creating a User this way does not give them local-auth password
login — that requires a password Secret and `spec.localAuth`, which the admin
API sets up for you (see [Option 5](#option-5-local-authentication)).

### Roles

| Role | Capabilities |
|------|-------------|
| `admin` | Full access to all workspaces in assigned namespaces; can manage users via admin API |
| `editor` | Create, edit, delete workspaces in assigned namespaces |
| `viewer` | Read-only access to workspaces in assigned namespaces |

A user's authentication method (OIDC, local, or both) is independent of their
role — `spec.role` applies regardless of how they signed in.

### Disabling a user

```bash
kubectl patch user jane-doe --type=merge -p '{"spec":{"disabled":true}}'
```

Disabling blocks both OIDC and local login for that user, and pauses
reconciliation of their namespace/RBAC.

### Granting shared namespace access

```bash
kubectl patch user jane-doe --type=json -p '[
  {"op": "add", "path": "/spec/namespaceAccess/-", "value": {"namespace": "team-alpha", "role": "editor"}}
]'
```

By default, new users (local or OIDC) have no namespace access beyond their
personal namespace (if enabled) — namespace access must be granted explicitly.

---

## Troubleshooting

### AuthConfig shows IssuerUnreachable

```bash
kubectl get authconfig default -o jsonpath='{.status.conditions[0].message}'
```

Check that:
- The issuer URL is correct and accessible from within the cluster
- DNS resolution works from the controller pod
- TLS certificates are valid (the controller does NOT skip TLS verification)

### Login redirects fail

Ensure:
- `AUTH_CALLBACK_URL` env var is set on the API deployment (or `EXTERNAL_HOST` is configured)
- The OIDC provider has `https://<your-host>/auth/callback` in its allowed redirect URIs
- Ingress routes `/auth/*` paths to the API service

### Session cookie not sent

- The `kw-session` cookie is httpOnly and Secure (requires HTTPS)
- All frontend `fetch()` calls must include `credentials: "include"`
- CORS must allow the frontend origin (check `ALLOWED_ORIGINS` on the API)

### User created but no namespace appears

- Check that `personalNamespaces.enabled: true` in AuthConfig
- Look at the User controller logs: `kubectl logs -l app.kubernetes.io/component=controller -n kube-workspaces-system`
- Verify the User CR status: `kubectl get user <name> -o yaml`

### Local login returns "account_locked"

The account has 5 or more consecutive failed login attempts. Check:

```bash
kubectl get user <name> -o jsonpath='{.status.failedLoginAttempts} {.status.lockedUntil}'
```

Wait for `lockedUntil` to pass, or clear it manually:

```bash
kubectl patch user <name> --subresource=status --type=merge \
  -p '{"status":{"failedLoginAttempts":0,"lockedUntil":null}}'
```

### `make get-admin-password` reports an error

The plaintext password is removed from the Secret as soon as the admin changes
it for the first time — this is expected. If the admin has forgotten their
password, reset it as another admin via the admin API/UI, or, if no other
admin account exists, delete the `User` and its password Secret to let the
controller re-create the bootstrap admin:

```bash
kubectl delete user admin-at-local
kubectl delete secret kw-user-admin-at-local-local-auth -n kube-workspaces-system
```

The controller re-reconciles the `AuthConfig` on its periodic 5-minute
recheck (or immediately if you touch the CR, e.g.
`kubectl annotate authconfig default kubectl.kubernetes.io/restartedAt="$(date +%s)" --overwrite`),
recreating both the `User` and its password Secret.
