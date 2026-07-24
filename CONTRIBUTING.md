# Contributing to Kube Workspaces

Thank you for considering a contribution to Kube Workspaces. This document explains how to get started, the development workflow, and what we expect from pull requests.

## Project Structure

Kube Workspaces is a multi-component project. Each component is an independent module:

| Component | Path | Language | Build |
|-----------|------|----------|-------|
| Controller | `controller/` | Go 1.24 | `cd controller && make build` |
| API | `api/` | Go 1.26 | `cd api && go build ./cmd/kube_workspaces/` |
| Proxy | `proxy/` | Go 1.26 | `cd proxy && go build ./cmd/proxy/` |
| Frontend | `frontend/` | TypeScript (Node 20+) | `cd frontend && npm run build` |
| Deploy | `deploy/` | YAML | Helm / Kustomize / ArgoCD |

## Development Setup

### Prerequisites

- Go 1.24+ (controller) and Go 1.26+ (API, Proxy)
- Node.js 20+ and npm
- Docker
- kubectl with access to a Kubernetes cluster
- [kind](https://kind.sigs.k8s.io/) for local development

### Getting Started

1. Fork and clone the repository:
   ```bash
   git clone https://github.com/<your-username>/kube-workspaces.git
   cd kube-workspaces
   ```

2. Create a kind cluster and install CRDs:
   ```bash
   kind create cluster
   make install-crd
   ```

3. Run components locally (each in a separate terminal):
   ```bash
   make run-controller   # port 8082 (health)
   make run-api          # port 8090
   make run-proxy        # port 8091
   make run-frontend     # port 3000
   ```

4. Open http://localhost:3000 in your browser.

## Making Changes

### Branching

- Create a feature branch from `main`: `git checkout -b feature/my-change`
- Keep branches focused on a single change

### Code Style

**Go (controller, api, proxy):**
- Run `gofmt` / `goimports` before committing
- Controller has golangci-lint: `cd controller && make lint`
- Follow standard Go conventions

**TypeScript (frontend):**
- Run `npm run lint` before committing
- Follow the existing patterns in `src/`
- Files containing JSX must use `.tsx` extension

### Testing

- **Controller:** `cd controller && make test` (unit tests with envtest)
- **Frontend:** `cd frontend && npm run lint` (no test suite yet)
- **API/Proxy:** Ensure `go build` succeeds and manual testing passes

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

### Controller

- CRD changes require running `make manifests` and `make generate`
- Always use `kubectl apply --server-side` for CRD manifests (they exceed client-side apply limits)
- The controller reconciles Workspace, User, and AuthConfig CRDs

### API

- The API design is defined in `api/design/design.go` using Goa DSL
- After editing the design, regenerate with `make generate-api` from the repo root
- Hand-written endpoint implementations go in `api/cmd/kube_workspaces/http.go`, not in generated files

### Proxy

- The proxy is deployed independently from the API
- It validates `kw-session` cookies using the same HMAC-SHA256 scheme as the API
- Auth config is cached 30s; User lookups are fresh per-request

### Frontend

- Uses Next.js 16 (not 15) — APIs may differ from what you expect
- React 19 context: use `<Context value={...}>` directly (not `<Context.Provider>`)
- Dark mode uses class strategy with `@custom-variant dark` in Tailwind v4
- All `fetch()` calls must include `credentials: "include"` for cookie auth

## Reporting Issues

- Use GitHub Issues on the relevant repository
- Include steps to reproduce, expected vs actual behavior, and environment details
- For security vulnerabilities, see [SECURITY.md](SECURITY.md)

## License

By contributing, you agree that your contributions will be licensed under the Apache License 2.0.
