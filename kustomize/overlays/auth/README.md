# Authentication overlay prerequisites

This overlay references, but deliberately does not create, two Secrets in
`kube-workspaces-system`:

| Secret | Key | Purpose |
|---|---|---|
| `kube-workspaces-session` | `signing-key` | Stable random session signing material (at least 32 bytes) |
| `kube-workspaces-oidc` | `client-secret` | Client secret registered with your OIDC provider |

For a new installation, create the namespace and Secrets before applying the
overlay:

```sh
kubectl create namespace kube-workspaces-system
kubectl create secret generic kube-workspaces-session -n kube-workspaces-system \
  --from-literal=signing-key="$(openssl rand -base64 32)"
kubectl create secret generic kube-workspaces-oidc -n kube-workspaces-system \
  --from-file=client-secret=/secure/path/oidc-client-secret
```

If the namespace or Secrets already exist, reuse them. Do not delete or recreate
the signing Secret on upgrade: replacing it invalidates existing credentials.
The OIDC secret file must contain the exact provider-issued value without a
trailing newline. Configure the issuer/client/public origin in `authconfig.yaml`
and `api-env-patch.yaml`, then apply the overlay. The sample issuer is an example,
not a running identity provider.

For GitOps, provision the same named Secrets using your encrypted-secret or
external-secret controller before enabling auth. Do not commit plaintext keys.
See [authentication guidance](../../../docs/authentication.md#stable-signing-keys-for-gitops)
for Helm/ArgoCD and custom namespace prerequisites.
