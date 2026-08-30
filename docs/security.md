# Security

How kube-workspaces is hardened at the deployment level, and the reasoning behind
each decision. For authentication and authorisation of *users*, see
[authentication.md](authentication.md).

## ServiceAccount tokens

Every component runs under a dedicated ServiceAccount with least-privilege RBAC,
and none relies on Kubernetes' legacy token automounting.

| Component | ServiceAccount | Token |
|-----------|---------------|-------|
| controller | `kube-workspaces-controller` (Helm: release fullname) | projected, 1h, auto-rotated |
| api | same as controller | projected, 1h, auto-rotated |
| proxy | `kube-workspaces-proxy` | projected, 1h, auto-rotated |
| frontend | `kube-workspaces-frontend` | **none** |

### Why the frontend has no token

The frontend is a UI and reverse proxy. It has no Kubernetes client — there is no
`@kubernetes/*` dependency in its `package.json` and it makes no API-server calls;
everything goes through the API service. It previously ran on the `default`
ServiceAccount and was handed a token it could not use, so it now has its own
ServiceAccount with **no** Role or ClusterRole bindings and
`automountServiceAccountToken: false` on both the ServiceAccount and the pod.

### Why the others use projected tokens

The three components that do call the API server would end up with a token either
way. A projected token is better than the automounted one because it is:

- **short-lived and auto-rotated** (1 hour), rather than a long-lived
  Secret-backed token that stays valid until deleted
- **explicitly declared**, so the mount is auditable rather than implicit
- **bound to the pod**, so it stops being valid when the pod goes away

```yaml
automountServiceAccountToken: false
volumes:
  - name: kube-api-access
    projected:
      defaultMode: 420
      sources:
        - serviceAccountToken:
            path: token
            expirationSeconds: 3600
        - configMap:
            name: kube-root-ca.crt
            items: [{ key: ca.crt, path: ca.crt }]
        - downwardAPI:
            items: [{ path: namespace, fieldRef: { fieldPath: metadata.namespace } }]
```

Two details matter, and both are enforced by tests:

**The path layout is exact.** `client-go`'s in-cluster config reads `token`,
`ca.crt` and `namespace` from
`/var/run/secrets/kubernetes.io/serviceaccount`. A partial mount fails
authentication at pod startup, not at build time, so `make test-lint` asserts all
three files are present in both render paths.

**No audience is pinned.** It is tempting to set
`audience: https://kubernetes.default.svc`, but the correct value is
cluster-specific — on kind the issuer is
`https://kubernetes.default.svc.cluster.local`, and a mismatch fails
authentication. Omitting it makes the API server issue for its own default
audience, which is what `client-go` expects. Verified with a `TokenReview`:
an audience-less projected token authenticates and reports
`audiences: ["https://kubernetes.default.svc.cluster.local"]`.

`make test-lint` fails if an audience appears.

## RBAC

Both install paths grant **identical effective permissions**. They name the
ServiceAccount differently (`kube-workspaces-controller` under Kustomize, the
release fullname under Helm) and group their ClusterRole rules differently, so a
textual diff is meaningless — the manager role is 152 lines one side and 45 the
other.

`scripts/compare-rbac.py` flattens both renders to
`{apiGroup/resource: sorted(verbs)}` and compares that, so a divergence in
*privilege* is caught even though the text differs. It runs in `make test-lint`.

`make test-smoke` additionally verifies effective permissions on a live cluster
with `kubectl auth can-i`, rather than inferring them from bindings.

## What is deliberately not hardened

**The workspace pods themselves.** A workspace is a user-supplied container image
running user code; the `Workspace` CRD accepts a full PodSpec. Constraining it is
a policy decision for the cluster operator — use PodDefaults, admission control
(Kyverno, Gatekeeper) or Pod Security Standards on the `workspaces` namespace.

**Network policy.** None is shipped. The proxy needs to reach arbitrary workspace
pods, so a useful default policy depends on how workspaces are namespaced in your
cluster.

## Reporting a vulnerability

See [SECURITY.md](../SECURITY.md).

---

This guide is also rendered on the
[Kube Workspaces website](https://kubeworkspaces.io/docs/security/).
