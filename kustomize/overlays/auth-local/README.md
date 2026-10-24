# Local authentication prerequisites

Provision a stable signing Secret before applying this overlay. Local auth uses
signed sessions too; an OIDC provider and OIDC client Secret are not required.

```sh
kubectl create namespace kube-workspaces-system
kubectl create secret generic kube-workspaces-session -n kube-workspaces-system \
  --from-literal=signing-key="$(openssl rand -base64 32)"
```

Reuse an existing namespace and signing Secret on upgrades. This overlay does
not create or overwrite Secrets. The controller separately creates the bootstrap
administrator password Secret; follow `authconfig.yaml` to retrieve it.

For GitOps, manage the signing Secret through an encrypted-secret or
external-secret controller and ensure it exists before enabling auth. See
[stable signing keys](../../../docs/authentication.md#stable-signing-keys-for-gitops).
