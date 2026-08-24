# Customizing your domain (hostname)

By default the manifests use the placeholder domain `workspaces.example.com`.
This is **not issued by real ACME providers** (it is reserved by
[RFC 2606](https://datatracker.ietf.org/doc/html/rfc2606)), so you must
override it with your own hostname before going to production.

There are two supported ways to set your hostname, depending on how you deploy.

> Keep the shared `kustomize/base` domain-agnostic. Consumers are expected to set
> their own hostname via Helm values or a kustomize patch — the base should never
> hardcode a specific operator's domain.

## Helm (recommended)

The Helm chart exposes every hostname-dependent value. The values that matter:

| Value | Default | Purpose |
|-------|---------|---------|
| `api.externalHost` | `""` | `Host` header forwarded to proxied workspace backends |
| `api.allowedOrigins` | `https://workspaces.example.com,...` | CORS allow-list for the API |
| `proxy.allowedOrigins` | `https://workspaces.example.com,...` | CORS allow-list for the proxy |
| `auth.callbackURL` | `""` | Optional override of the OIDC callback URL |
| `ingress.hosts` | `workspaces.local` | Ingress rules (host → paths) |
| `ingress.tls` | `[]` | TLS hosts + secret name |
| `ingress.className` | `""` | e.g. `traefik`, `nginx` |
| `ingress.annotations` | `{}` | e.g. `cert-manager.io/cluster-issuer` or traefik middleware |

The recommended deployment model is **single-host**: frontend, API, and proxy
are all served from one domain. The frontend defaults to calling the API at
`/api` on the same origin (the `API_BASE` is baked into the frontend image at
build time and defaults to `/api`). A reverse-proxy strips the `/api` prefix
before forwarding to the API service.

The API sets a host-only `kw-session` cookie — this means single-host keeps the
cookie on one origin and avoids cross-origin cookie issues.

**Traefik ingress controllers** need a `StripPrefix` middleware to strip `/api`
before the API service handles the request:

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: kube-workspaces-strip-api
  namespace: kube-workspaces-system
spec:
  stripPrefix:
    prefixes:
      - /api
```

With the middleware in place, configure the Helm values:

```yaml
api:
  externalHost: "workspaces.example.com"
  allowedOrigins: "https://workspaces.example.com,http://localhost:3000"
proxy:
  allowedOrigins: "https://workspaces.example.com,http://localhost:3000"
ingress:
  enabled: true
  className: traefik
  annotations:
    traefik.ingress.kubernetes.io/router.middlewares: kube-workspaces-system-kube-workspaces-strip-api@kubernetescrd
  hosts:
    - host: workspaces.example.com
      paths:
        - path: /api
          pathType: Prefix
          backend:
            serviceName: kube-workspaces-api
            servicePort: 80
        - path: /v1
          pathType: Prefix
          backend:
            serviceName: kube-workspaces-api
            servicePort: 80
        - path: /auth
          pathType: Prefix
          backend:
            serviceName: kube-workspaces-api
            servicePort: 80
        - path: /openapi
          pathType: Prefix
          backend:
            serviceName: kube-workspaces-api
            servicePort: 80
        - path: /proxy
          pathType: Prefix
          backend:
            serviceName: kube-workspaces-proxy
            servicePort: 80
        - path: /
          pathType: Prefix
          backend:
            serviceName: kube-workspaces-frontend
            servicePort: 80
```

Install with:

```bash
helm install kube-workspaces ./helm/kube-workspaces \
  --namespace kube-workspaces-system --create-namespace \
  -f my-values.yaml
```

**ingress-nginx controllers** have no middleware concept — use a
`rewrite-target` annotation with regex capture groups to strip `/api` instead:

```yaml
api:
  externalHost: "workspaces.example.com"
  allowedOrigins: "https://workspaces.example.com"
proxy:
  allowedOrigins: "https://workspaces.example.com"
ingress:
  enabled: true
  className: nginx
  annotations:
    nginx.ingress.kubernetes.io/use-regex: "true"
    nginx.ingress.kubernetes.io/rewrite-target: /$2
  hosts:
    - host: workspaces.example.com
      paths:
        # $2 is the second capture group, so /api/v1/x -> /v1/x on the API
        - path: /api(/|$)(.*)
          pathType: ImplementationSpecific
          backend:
            serviceName: kube-workspaces-api
            servicePort: 80
        - path: /v1(/|$)(.*)
          pathType: ImplementationSpecific
          backend:
            serviceName: kube-workspaces-api
            servicePort: 80
        - path: /auth(/|$)(.*)
          pathType: ImplementationSpecific
          backend:
            serviceName: kube-workspaces-api
            servicePort: 80
        - path: /openapi(/|$)(.*)
          pathType: ImplementationSpecific
          backend:
            serviceName: kube-workspaces-api
            servicePort: 80
        - path: /proxy(/|$)(.*)
          pathType: ImplementationSpecific
          backend:
            serviceName: kube-workspaces-proxy
            servicePort: 80
        # /()(.*) keeps the capture-group count consistent so $2 resolves
        - path: /()(.*)
          pathType: ImplementationSpecific
          backend:
            serviceName: kube-workspaces-frontend
            servicePort: 80
```

> Every path needs a `backend` block — the chart has no default. Omitting it
> fails with `nil pointer evaluating interface {}.serviceName`.
>
> Where TLS terminates at an upstream load balancer, leave `ingress.tls` unset.

### ArgoCD

Point your Application at the chart and put the values inline. Multi-source
example (chart + CRDs):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kube-workspaces
  namespace: argocd
spec:
  destination:
    name: in-cluster
  project: default
  sources:
    - repoURL: https://github.com/kube-workspaces/deploy.git
      targetRevision: main
      path: helm/kube-workspaces
      helm:
        values: |
          api:
            externalHost: "workspaces.example.com"
          ingress:
            enabled: true
            className: traefik
            # ... hosts as above (single-host with /api route)
          images: []
    - repoURL: https://github.com/kube-workspaces/deploy.git
      targetRevision: main
      path: kustomize/crds
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

Notes:

- Set `images: []` if you already manage `Image` CRs out-of-band (e.g. for a
  curated image catalog), to stop the chart's default images from rendering.
- ArgoCD renders the chart with `helm template` and applies the output as plain
  manifests — it does not create a Helm release, so `helm list` won't show it.
- The middleware YAML should be applied before the Ingress references it, or
  managed by a separate ArgoCD Application (the Ingress will still route
  correctly even if the middleware is missing for a short time).

### Two-host setup (alternative)

If you prefer a separate API host (`api.workspaces.example.com`), you need a
frontend image built with `NEXT_PUBLIC_API_URL=https://api.workspaces.example.com`
baked in at build time. The default image on ghcr.io is not built with this
value. When using a custom-built image, set `frontend.externalApiUrl` in the
Helm values and use these ingress rules:

```yaml
api:
  externalHost: "api.workspaces.example.com"
ingress:
  hosts:
    - host: workspaces.example.com
      paths:
        - path: /v1
          pathType: Prefix
          backend:
            serviceName: kube-workspaces-api
            servicePort: 80
        # ... /auth, /openapi, /proxy, /
    - host: api.workspaces.example.com
      paths:
        - path: /
          pathType: Prefix
          backend:
            serviceName: kube-workspaces-api
            servicePort: 80
```

## Kustomize

The `kustomize/base` is intentionally generic. Override the hostnames with a
json6902 patch in your own overlay:

```yaml
# kustomization.yaml
resources:
  - ../base

patches:
  - target:
      kind: Ingress
      name: kube-workspaces
    patch: |-
      - op: replace
        path: /spec/rules/0/host
        value: workspaces.example.com
      - op: replace
        path: /spec/rules/1/host
        value: api.workspaces.example.com
      - op: replace
        path: /spec/tls/0/hosts
        value: [workspaces.example.com, api.workspaces.example.com]
  - target:
      kind: Deployment
      name: kube-workspaces-api
    patch: |-
      - op: replace
        path: /spec/template/spec/containers/0/env/0/value
        value: api.workspaces.example.com
      - op: replace
        path: /spec/template/spec/containers/0/env/1/value
        value: https://workspaces.example.com/auth/callback
      - op: replace
        path: /spec/template/spec/containers/0/env/2/value
        value: https://workspaces.example.com,http://localhost:3000
  - target:
      kind: Deployment
      name: kube-workspaces-proxy
    patch: |-
      - op: replace
        path: /spec/template/spec/containers/0/env/0/value
        value: https://workspaces.example.com,http://localhost:3000
```

The same patches can be expressed inline in an ArgoCD Application via
`spec.sources[].kustomize.patches`.

## DNS and TLS

Before applying, make sure your DNS points at your ingress controller and that
cert-manager (or your ACME client) is configured to issue for your domains.
The ingress annotation `cert-manager.io/cluster-issuer` triggers automatic
certificate issuance through cert-manager's ingress-shim.
