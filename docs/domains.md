# Customizing your domain (hostname)

By default the manifests use the placeholder domains `workspaces.example.com` and
`api.workspaces.example.com`. These are **not issued by real ACME providers** (they
are reserved by [RFC 2606](https://datatracker.ietf.org/doc/html/rfc2606)), so you
must override them with your own hostnames before going to production.

There are two supported ways to set your hostname, depending on how you deploy.

> Keep the shared `kustomize/base` domain-agnostic. Consumers are expected to set
> their own hostname via Helm values or a kustomize patch — the base should never
> hardcode a specific operator's domain.

## Helm (recommended)

The Helm chart exposes every hostname-dependent value. The values that matter:

| Value | Default | Purpose |
|-------|---------|---------|
| `api.externalHost` | `""` | Sets `EXTERNAL_HOST` on the API (OpenAPI server URL) |
| `api.allowedOrigins` | `https://workspaces.example.com,...` | CORS allow-list for the API |
| `proxy.allowedOrigins` | `https://workspaces.example.com,...` | CORS allow-list for the proxy |
| `auth.callbackURL` | `""` | Optional override of the OIDC callback URL |
| `ingress.hosts` | `workspaces.local` | Ingress rules (host → paths) |
| `ingress.tls` | `[]` | TLS hosts + secret name |
| `ingress.className` | `""` | e.g. `traefik`, `nginx` |
| `ingress.annotations` | `{}` | e.g. `cert-manager.io/cluster-issuer` |

Example `values.yaml` for a two-host deployment (main host + dedicated API host):

```yaml
api:
  externalHost: "api.workspaces.example.com"
  allowedOrigins: "https://workspaces.example.com,http://localhost:3000"
proxy:
  allowedOrigins: "https://workspaces.example.com,http://localhost:3000"
ingress:
  enabled: true
  className: traefik
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-production
  hosts:
    - host: workspaces.example.com
      paths:
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
    - host: api.workspaces.example.com
      paths:
        - path: /
          pathType: Prefix
          backend:
            serviceName: kube-workspaces-api
            servicePort: 80
  tls:
    - hosts:
        - workspaces.example.com
        - api.workspaces.example.com
      secretName: kube-workspaces-tls
```

Install with:

```bash
helm install kube-workspaces ./helm/kube-workspaces \
  --namespace kube-workspaces-system --create-namespace \
  -f my-values.yaml
```

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
            externalHost: "api.workspaces.example.com"
          ingress:
            enabled: true
            className: traefik
            # ... hosts / tls as above
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
