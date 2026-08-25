# Contributing to Kube Workspaces

Thank you for considering a contribution to Kube Workspaces. This document explains how to get started, the development workflow, and what we expect from pull requests.

## Project Structure

Kube Workspaces is split across five independent repositories under the
[kube-workspaces](https://github.com/kube-workspaces) org. There is no
monorepo — clone whichever components you need side by side.

| Repository | Language | Build |
|-----------|----------|-------|
| [controller](https://github.com/kube-workspaces/controller) | Go 1.24 | `make build` |
| [api](https://github.com/kube-workspaces/api) | Go 1.26 | `go build ./cmd/kube_workspaces/` |
| [proxy](https://github.com/kube-workspaces/proxy) | Go 1.26 | `go build ./cmd/proxy/` |
| [frontend](https://github.com/kube-workspaces/frontend) | TypeScript (Node 20+) | `npm run build` |
| [deploy](https://github.com/kube-workspaces/deploy) | YAML | Helm / Kustomize / ArgoCD |

This file covers the **deploy** repo. For component-specific workflows, see the
`CONTRIBUTING.md` or `README.md` in that component's own repository.

## Development Setup

### Prerequisites

For this repo (deployment manifests):

- kubectl with access to a Kubernetes cluster
- [kind](https://kind.sigs.k8s.io/) for a local cluster
- Helm 3.8+
- kustomize 5+
- [yq](https://github.com/mikefarah/yq) and [jq](https://jqlang.github.io/jq/) (used by the test scripts)
- Optionally [kubeconform](https://github.com/yannh/kubeconform) — `make test-tools` installs a pinned copy into `.bin/`

Building components from source additionally needs Go 1.24+/1.26+, Node.js 20+
and Docker.

### Getting Started

1. Fork and clone this repository:
   ```bash
   git clone https://github.com/<your-username>/deploy.git kube-workspaces-deploy
   cd kube-workspaces-deploy
   ```

2. Run the static checks — no cluster required, takes seconds:
   ```bash
   make test-lint
   ```

3. Deploy to a throwaway kind cluster and smoke-test it:
   ```bash
   make test-deploy-kustomize
   ```

   Or work against a cluster you keep around:
   ```bash
   make kind-up
   make install-crd deploy-kustomize install-images
   make test-smoke
   make kind-down
   ```

4. To iterate on the UI, port-forward the frontend and open
   <http://localhost:3000>:
   ```bash
   make port-forward-frontend
   ```

## Testing

This repo has a layered test suite. See [docs/testing.md](docs/testing.md) for
the full description.

| Layer | Command | Cluster | Runtime |
|-------|---------|---------|---------|
| Static validation | `make test-lint` | no | seconds |
| Deployment smoke | `make test-deploy-kustomize`, `make test-deploy-helm` | kind | ~4 min each |
| Functional e2e | `make test-e2e` | kind | ~10 min |
| Everything | `make test-all` | kind | ~20 min |

When changing the Helm chart, also bump `version` in
`helm/kube-workspaces/Chart.yaml` and run `make test-upgrade` — CI refuses to
republish an already-published version, and the upgrade test is what proves an
existing install can move to it.

Run at minimum `make test-lint` before opening a PR — CI runs it on every push
and it catches unbuildable kustomizations, unrenderable Helm values, schema
violations and drifted vendored CRDs.

Two caveats worth knowing before you rely on a green run:

- **`make test-deploy-argocd` only tests pushed commits.** Argo CD clones from
  the git remote, so it validates HEAD as pushed, not your working tree. Every
  other method applies local files. The script warns when the tree is dirty.
- **The Ingress is inert on kind.** `kustomize/base` pins
  `ingressClassName: traefik`, which a default kind cluster does not have, so
  tests reach services via port-forward.

See [docs/testing.md](docs/testing.md) for the full list.

## Releasing

The five repositories are released together and share a version. See
[docs/releasing.md](docs/releasing.md) for the procedure — the order matters,
since the chart's `appVersion` must name component images that already exist.

Release notes are generated, not hand-written: `scripts/release-notes.sh`
produces a preamble (leading with whether the release changes behaviour at all)
and GitHub appends a commit list categorised per `.github/release.yml`. Label
your PRs so they land in the right section.

## Making Changes

### Branching

- Create a feature branch from `main`: `git checkout -b feature/my-change`
- Keep branches focused on a single change

### Code Style

**This repo (YAML/shell):**
- Shell scripts use `bash`, are `shellcheck`-clean, and live in `scripts/`
- Run `make test-lint` before committing

**Go (controller, api, proxy) — in their own repos:**
- Run `gofmt` / `goimports` before committing
- The controller has golangci-lint: `make lint`
- Follow standard Go conventions

**TypeScript (frontend) — in its own repo:**
- Run `npm run lint` before committing
- Follow the existing patterns in `src/`
- Files containing JSX must use `.tsx` extension

### Testing

- **This repo:** `make test-lint` always; `make test-deploy-kustomize` or
  `make test-all` when changing manifests, the chart, or the ArgoCD Applications
- **Controller:** `make test` (envtest) and `make test-e2e` (kind)
- **API/Proxy:** `go test ./...`
- **Frontend:** `npm run lint && npm run build` (no test suite yet)

### Commit Messages

- Use clear, concise commit messages
- Prefix with the component if the change is scoped: `controller: fix status reconciliation`
- Use imperative mood: "add feature" not "added feature"

## Pull Request Process

1. Ensure your branch builds cleanly and passes lint/tests for affected components
2. Update documentation if your change affects user-facing behavior
3. Fill out the PR description explaining what and why
4. PRs require at least one maintainer approval before merging

### What We Look For

- Does the change solve the stated problem?
- Is it consistent with the existing architecture?
- Are there tests or is the change manually verified?
- Is documentation updated where needed?

## Component-Specific Notes

These live in their own repositories — the commands below are run from that
repo's root, not from here.

### Controller

- CRD changes require running `make manifests && make generate`
- After regenerating, copy the CRDs into this repo — see [CRD Sync](#crd-sync)
- Always use `kubectl apply --server-side` for CRD manifests (they exceed client-side apply limits)
- The controller reconciles Workspace, Image, User, AuthConfig, PodDefault and PlatformConfig CRDs

### API

- The API design is defined in `design/design.go` using Goa DSL
- There is no Makefile; regenerate with:
  `go run goa.design/goa/v3/cmd/goa gen github.com/kube-workspaces/api/design`
- Hand-written endpoint implementations go in `cmd/kube_workspaces/http.go`, not in generated files

### Proxy

- The proxy is deployed independently from the API
- It validates `kw-session` cookies using the same HMAC-SHA256 scheme as the API
- Auth config is cached 30s; User lookups are fresh per-request

### Frontend

- Uses Next.js 16 (not 15) — APIs may differ from what you expect
- React 19 context: use `<Context value={...}>` directly (not `<Context.Provider>`)
- Dark mode uses class strategy with `@custom-variant dark` in Tailwind v4
- All `fetch()` calls must include `credentials: "include"` for cookie auth

## CRD Sync

The CRD YAML is generated by the controller repo and vendored here twice: into
`kustomize/crds/` (the source of truth) and `helm/kube-workspaces/crds/`.

When CRDs change:

1. In the controller repo: `make manifests`
2. Copy `config/crd/bases/kubeworkspaces.io_*.yaml` into `kustomize/crds/`
3. Run `make sync-helm-crds` to mirror them into the chart
4. Run `make test-lint` — `check-helm-crds` fails the build on drift

`make check-helm-crds` runs in CI, so forgetting step 3 blocks the merge.

## Image Catalog Sync

`Image` CR manifests are not authored in this repo. The source of truth is
[kube-workspaces/image-catalog](https://github.com/kube-workspaces/image-catalog),
which is vendored here at a pinned version (`IMAGE_CATALOG_VERSION` in the
Makefile) into three files:

- `images.yaml` — full catalog, used by `make install-images` (Kustomize path)
- `helm/kube-workspaces/files/images-catalog.yaml` — same content, packaged with the Helm chart
- `helm/kube-workspaces/files/images-examples.yaml` — curated subset, installed by default via `installExampleImages: true`

To add or edit an image, open a PR against `image-catalog`, not here.

To pick up a new image-catalog release:

1. Bump `IMAGE_CATALOG_VERSION` in `Makefile`
2. Run `make sync-images`
3. Commit the updated `images.yaml` and `helm/kube-workspaces/files/images-*.yaml`

`make check-images` runs in CI (the `helm-publish` workflow, which already
talks to the network) rather than `make test-lint` — Layer 0 static
validation is offline-only. Forgetting step 2 blocks the chart publish, not
the PR.

## Reporting Issues

- Use GitHub Issues on the relevant repository
- Include steps to reproduce, expected vs actual behavior, and environment details
- For security vulnerabilities, see [SECURITY.md](SECURITY.md)

## License

By contributing, you agree that your contributions will be licensed under the Apache License 2.0.
