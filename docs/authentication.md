# Authentication Setup Guide

This guide covers how to configure authentication for kube-workspaces using different OIDC providers.

## Overview

kube-workspaces uses OIDC (OpenID Connect) for authentication. The system supports:

- **Dex** (bundled or external) - federated OIDC proxy supporting GitHub, GitLab, LDAP, SAML, and more
- **Okta** - enterprise identity provider
- **Any OIDC-compliant provider** - Google, Auth0, Keycloak, Azure AD, etc.

Authentication is **opt-in** and disabled by default. When disabled, the system operates without auth (everyone has full access).

## Architecture

```
User Browser
    |
    v
Frontend (Next.js) -- /auth/login --> API (/auth/login) --> OIDC Provider
    |                                     |
    |                                     v
    |                              API (/auth/callback) <-- Provider callback
    |                                     |
    v                                     v
Frontend (reads session)          Sets httpOnly cookie (kw-session)
```

- Session tokens are HMAC-SHA256 signed JWTs stored in a `kw-session` httpOnly cookie
- The signing key is stored in a Kubernetes Secret
- User state is stored in `User` CRDs (cluster-scoped)
- Configuration is stored in an `AuthConfig` CRD (singleton named `default`)

## Prerequisites

- kube-workspaces deployed (controller, API, frontend)
- CRDs installed (`kubectl apply --server-side -k deploy/kustomize/crds/`)
- An OIDC provider configured with a client ID and secret
- The API must be reachable at a stable URL for the OIDC callback

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

## User Management

### Creating users manually

Users are auto-created on first login when `registration.autoProvision` is true. You can also pre-create users:

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

### Roles

| Role | Capabilities |
|------|-------------|
| `admin` | Full access to all workspaces in assigned namespaces; can manage users via admin API |
| `editor` | Create, edit, delete workspaces in assigned namespaces |
| `viewer` | Read-only access to workspaces in assigned namespaces |

### Disabling a user

```bash
kubectl patch user jane-doe --type=merge -p '{"spec":{"disabled":true}}'
```

### Granting shared namespace access

```bash
kubectl patch user jane-doe --type=json -p '[
  {"op": "add", "path": "/spec/namespaceAccess/-", "value": {"namespace": "team-alpha", "role": "editor"}}
]'
```

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
