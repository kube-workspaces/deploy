# Testing

This repo holds deployment manifests, so its tests answer one question: **does
the documented way of installing kube-workspaces actually work?**

The suite is layered by cost. Run the cheap layer constantly, the expensive
layers before merging anything that touches manifests.

| Layer | Command | Cluster? | Runtime | What it proves |
|-------|---------|----------|---------|----------------|
| 0 — static | `make test-lint` | no | ~15 s | Everything renders, validates and is internally consistent |
| 1 — smoke | `make test-deploy-kustomize` etc. | kind | ~4 min | The components install and serve traffic |
| 2 — functional | `make test-e2e` | kind | ~5 min | A real workspace works end to end |
| 3 — upgrade | `make test-upgrade` | kind | ~8 min | Existing installs can move to this version |

## Prerequisites

`kubectl`, `kustomize`, `helm`, `kind`, `yq`, `jq`, `curl`. Layer 0 additionally
uses [kubeconform](https://github.com/yannh/kubeconform), which
`make test-tools` installs into `.bin/` at a pinned version. If it is missing,
schema validation is skipped with a warning rather than failing.

## Layer 0 — static validation

```sh
make test-lint
```

No cluster, no network beyond the kubeconform schema fetch. This is the gate
that runs on every push, and it catches the majority of real breakage:

- every kustomization under `kustomize/` builds (including both overlays)
- the Helm chart renders across a matrix of values combinations — auth on/off,
  Dex, ingress variants, namespace toggles, custom image tags
- rendered output validates against the Kubernetes schema, **including our own
  CRDs**: `scripts/crd-to-schema.sh` extracts JSON Schema from the six CRDs so
  `Workspace`, `Image` and friends are genuinely validated rather than skipped
- the CRDs vendored into `helm/kube-workspaces/crds/` match `kustomize/crds/`
  (this is `make check-helm-crds`)
- structural CRD checks: all six present, correct API group, every version has a
  schema, and the `Workspace` CRD is still over the 256 KiB client-side apply
  limit that makes `--server-side` mandatory
- no Deployment inherits the `default` ServiceAccount, every referenced SA is
  defined, and the frontend does not mount a token
- the ArgoCD Applications point at this repo, reference paths that exist, and
  use the right sync options for the oversized CRD
- docs do not reference `make` targets that do not exist

Negative tests are included where a guard could silently stop working — e.g. an
ingress host with no `paths` must be rejected at template time.

## Layer 1 — deployment smoke tests

Each method gets its own throwaway kind cluster, which is deleted afterwards
even on failure.

```sh
make test-deploy-kustomize    # kustomize/crds + overlays/test
make test-deploy-helm         # the local chart
make test-deploy-helm-oci     # the published chart from ghcr.io
make test-deploy-auth         # kustomize with the auth overlay
make test-deploy-argocd       # Argo CD syncing both Applications
```

All of them converge on `scripts/smoke.sh`, which asserts the *outcome* rather
than the mechanism, so it is method-agnostic:

- all six CRDs Established
- all four Deployments Available, all pods Ready, **zero restarts**
- API: `/healthz`, `/v1/workspaces`, `/v1/namespaces`, `/v1/volumes`,
  `/v1/images`, `/platform/config`, valid `/openapi3.json`, and a 404 on an
  unknown path
- proxy: `/healthz`, `/readyz`, `/sw.js`
- frontend: `/` returns HTML (it has **no** `/healthz` — `/` is its probe path,
  matching the manifests)
- controller: `/healthz` and `/readyz` on port 8081, probed pod-directly since
  it has no Service
- RBAC: the controller's SA can list workspaces cluster-wide and create
  StatefulSets, verified with `kubectl auth can-i` so we test effective
  permissions rather than reading bindings

The suite reads the `AuthConfig` and adapts: with auth **enabled** it asserts the
API *rejects* unauthenticated calls with 401/403 and that `/auth/config` stays
reachable, because asserting a 200 there would be asserting an auth bypass.
Override the detection with `KW_AUTH_ENABLED=0|1`.

To iterate against a cluster you keep between runs:

```sh
make kind-up
make install-crd deploy-kustomize install-images
make test-smoke
make test-e2e
make kind-down
```

`make test-smoke` and `make test-e2e` run against whatever your current kubectl
context is. They do not create or delete clusters.

## Layer 2 — functional end-to-end

```sh
make test-e2e
```

Where Layer 1 proves the components start, this proves the platform works:

1. Creates a `Workspace` CR using `traefik/whoami` (~5 MB, so the image pull
   does not dominate the runtime)
2. Asserts the controller creates a StatefulSet and Service named after the
   workspace, with the pod as `<name>-0`, the Service mapping port 80 to the
   container port, and an ownerReference back to the Workspace
3. Asserts the API can see it, both individually and in the list
4. Asserts the **proxy actually routes to it** — `/proxy/<ns>/<name>/` returns
   the workspace's own response body, and an unknown workspace does not 200
5. Exercises stop/start: `POST /v1/workspaces/<name>/stop` scales the
   StatefulSet to 0 and sets the `kubeworkspaces.io/stopped` annotation while
   leaving the CR in place; `/start` brings it back
6. Deletes the CR and asserts the StatefulSet and Service are garbage-collected

A raw `Workspace` needs no matching `Image` CR — `Image` CRs only populate the
UI/API catalog and supply defaults at creation time through the API.

## Layer 3 — chart upgrade

```sh
make test-upgrade
```

Installs the newest **published** chart, upgrades to the local one, smoke-tests
the result, then rolls back. This is the path every existing user takes, and it
covers what a fresh install cannot: changed immutable fields, removed or renamed
resources, and CRD updates applied over existing objects.

The version to upgrade from is the newest published tag that is not the local
version, resolved by semver from the GHCR tag list. Override with
`FROM_VERSION`. If the local `Chart.yaml` version is already published, the test
warns that it is only exercising a no-op upgrade — bump the version first.

This is also the check that tells you a version bump is genuinely releasable: the
post-upgrade smoke run is strict, so hardening that only exists locally must
actually take effect on an upgraded install.

## CI

| Workflow | Trigger | Contents |
|----------|---------|----------|
| `test.yaml` | push, PR | Layer 0, then kustomize/helm/helm-oci in parallel plus Layer 2 |
| `nightly.yaml` | 03:00 UTC | argocd, auth, upgrade, a Kubernetes version matrix, Layer 2, and an image-drift report |
| `helm-publish.yaml` | push to main touching `helm/**` | Packages and pushes the chart, refusing to overwrite a published version |

Point branch protection at the `All tests passed` check from `test.yaml`; it
aggregates the matrix so the required check does not need editing when the matrix
changes.

`argocd` and `auth` are nightly rather than per-PR: ArgoCD can only test pushed
commits, and on a fork PR the SHA is not fetchable from the base repo at all.

## Caveats

### ArgoCD tests only *pushed* commits

This is the one method that does not test your working tree. Argo CD clones from
the git remote, so `make test-deploy-argocd` validates **HEAD as pushed**, not
what you are currently editing. Every other method applies local files.

The script overrides `targetRevision` to the current commit SHA (or `GITHUB_SHA`
in CI) so it at least tests *your* commit rather than `main`, and it warns when
the working tree is dirty. But uncommitted changes are invisible to it. Commit
and push before relying on this method, and treat a green ArgoCD run on a dirty
tree as meaningless for the uncommitted parts.

For the same reason, ArgoCD tests belong in the nightly/post-merge job rather
than the PR gate — on a PR from a fork the SHA is not fetchable from the base
repo at all.

### The Ingress is inert on kind

`kustomize/base` includes an Ingress hardcoded to `ingressClassName: traefik`
plus a cert-manager annotation. A default kind cluster has neither, so:

- the Ingress never gets an address, and **Argo CD reports the Application as
  `Progressing` indefinitely** even when all four Deployments are Healthy. The
  ArgoCD test accounts for this: `Synced` with only the Ingress unhealthy is
  treated as success, and the smoke suite is the real arbiter.
- `kustomize/overlays/test/` removes the Ingress entirely. Tests reach services
  via `kubectl port-forward`.

Genuinely testing `base/ingress.yaml` needs a cluster that ships Traefik — k3d
is the cheapest option and is planned as a separate nightly job.

### `helm-oci` tests a released artifact

`make test-deploy-helm-oci` installs the published chart, which by definition
predates unreleased changes in this tree. It therefore runs with
`KW_LENIENT_SA=1`, downgrading the ServiceAccount hardening assertions to
warnings. Its job is to prove the released chart installs, not to re-litigate
its contents.

### Floating image tags

The manifests reference `:latest`, so a green run can turn red with no commit on
this repo. The nightly job exists partly to surface that drift early.

### Registry credentials

The `helm-oci` test points `DOCKER_CONFIG` at an empty directory so the
published chart is pulled anonymously. A stale or revoked `ghcr.io` entry in
`~/.docker/config.json` otherwise causes a `403 denied` instead of falling back
to an anonymous token.

## Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `KIND_CLUSTER` | `kube-workspaces-test` / `kw-test-<method>` | Cluster name |
| `KIND_NODE_IMAGE` | `kindest/node:v1.31.0` | Pinned node image |
| `KIND_KEEP` | unset | Leave the cluster running after `kind-down` |
| `SKIP_CLUSTER` | unset | Use the current context instead of creating a cluster |
| `KW_NAMESPACE` | `kube-workspaces-system` | Component namespace |
| `KW_WORKSPACE_NAMESPACE` | `workspaces` | Where Workspace CRs live |
| `KW_EXPECT_IMAGES` | `1` | Set to `0` to skip Image-catalog assertions |
| `KW_AUTH_ENABLED` | auto-detected | Force auth-on or auth-off API assertions |
| `KW_LENIENT_SA` | unset | Downgrade SA hardening checks to warnings |
| `E2E_IMAGE` | `traefik/whoami` | Container image for the test workspace |
| `E2E_KEEP` | unset | Leave the test workspace behind |
| `CHART_VERSION` | local `Chart.yaml` version | Version for `helm-oci` |
| `FROM_VERSION` | newest published | Version to upgrade from in `test-upgrade` |

## Debugging a failure

Every cluster-touching script dumps diagnostics automatically on failure:
resources in both namespaces, `describe` for not-ready pods, recent events, and
logs from all four components including `--previous` (where crash-loop causes
live). Port-forwards are always reaped.

To dump the same information on demand:

```sh
make test-dump
```

To keep a failed cluster for inspection:

```sh
KIND_KEEP=1 make test-deploy-kustomize
```

## Adding a check

Assertions live in `scripts/lib/`:

- `common.sh` — `pass`/`fail`/`check`/`check_equals`/`check_contains`, the
  failure tally, and `finish` (which sets the exit code)
- `k8s.sh` — waiting, port-forwarding, HTTP retries, diagnostics

Scripts use `set -uo pipefail` but deliberately **not** `-e`: a failing
assertion must be recorded and the run must continue, so one failure does not
hide the rest. Use `die` only for setup problems that make the run meaningless.
