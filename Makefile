# Deploy repo Makefile - operational targets for kube-workspaces deployment

.PHONY: install-crd install-images deploy-kustomize deploy-crds \
	deploy-auth deploy-auth-local auth-enable auth-disable \
	get-admin-password reset-admin-password \
	port-forward-frontend port-forward-api \
	port-forward-proxy helm-install helm-upgrade helm-template lint-helm \
	sync-helm-crds check-helm-crds sync-images check-images \
	test-tools test-lint test-smoke test-e2e test-all test-dump \
	kind-up kind-down \
	test-deploy-kustomize test-deploy-helm test-deploy-helm-oci \
	test-deploy-argocd test-deploy-auth test-deploy-auth-local test-upgrade test-ingress test-e2e-full

# ---------------------------------------------------------------------------
# Testing
#
# Layer 0 (test-lint)       no cluster, seconds
# Layer 1 (test-deploy-*)   kind cluster, ~4 min per deployment method
# Layer 2 (test-e2e)        kind cluster, ~10 min, real Workspace lifecycle
#
# See docs/testing.md.
# ---------------------------------------------------------------------------

# Kind cluster name and node image used by every cluster test. Pinning the node
# image keeps runs reproducible; bump deliberately.
KIND_CLUSTER ?= kube-workspaces-test
KIND_NODE_IMAGE ?= kindest/node:v1.31.0
export KIND_CLUSTER KIND_NODE_IMAGE

# Image CR catalog is vendored from kube-workspaces/image-catalog at this
# pinned release. Bump deliberately with `make sync-images`.
IMAGE_CATALOG_VERSION ?= v0.1.0
IMAGE_CATALOG_REPO ?= kube-workspaces/image-catalog

# Install pinned test tools into .bin/ (gitignored).
test-tools:
	@scripts/install-tools.sh

# Layer 0: static validation, no cluster required.
test-lint: test-tools
	@scripts/validate.sh

# Create / delete a reusable local cluster for iterating.
kind-up:
	@scripts/kind.sh up

kind-down:
	@scripts/kind.sh down

# Layer 1: smoke-test whatever is deployed in the current kubectl context.
test-smoke: test-tools
	@scripts/smoke.sh

# Layer 2: full workspace lifecycle against the current context.
test-e2e: test-tools
	@scripts/e2e.sh

# Layer 2, self-contained: creates a cluster, deploys, runs the lifecycle test,
# then tears it down. Use this when you do not already have a deployment up.
test-e2e-full: test-tools
	@scripts/test-deploy.sh e2e

# Layer 1 per-method: each creates a fresh kind cluster, deploys, smoke-tests,
# then tears the cluster down.
test-deploy-kustomize: test-tools
	@scripts/test-deploy.sh kustomize

test-deploy-helm: test-tools
	@scripts/test-deploy.sh helm

test-deploy-helm-oci: test-tools
	@scripts/test-deploy.sh helm-oci

test-deploy-argocd: test-tools
	@scripts/test-deploy.sh argocd

test-deploy-auth: test-tools
	@scripts/test-deploy.sh auth

test-deploy-auth-local: test-tools
	@scripts/test-deploy.sh auth-local

test-upgrade: test-tools
	@scripts/test-upgrade.sh

# Layer 3: exercise the real Ingress on k3d, which bundles Traefik. This is the
# only way to test kustomize/base/ingress.yaml, whose hardcoded traefik class is
# inert on a default kind cluster.
test-ingress: export INSTALL_K3D=1
test-ingress: test-tools
	@scripts/test-ingress.sh

# Everything, in cost order. Each deployment method creates and destroys its own
# cluster, so this is safe to run unattended — but it takes ~40 minutes.
test-all: test-lint
	@scripts/test-deploy.sh kustomize
	@scripts/test-deploy.sh helm
	@scripts/test-deploy.sh helm-oci
	@scripts/test-deploy.sh e2e
	@scripts/test-deploy.sh auth
	@scripts/test-deploy.sh auth-local
	@scripts/test-deploy.sh argocd
	@scripts/test-upgrade.sh
	@INSTALL_K3D=1 scripts/install-tools.sh >/dev/null
	@scripts/test-ingress.sh

# Dump diagnostics for the current context (use after a failure).
test-dump:
	@scripts/dump.sh


# CRDs are the single source of truth in kustomize/crds/ and are vendored into
# the Helm chart's crds/ directory so `helm install` creates them automatically.
HELM_CRDS := crd.yaml kubeworkspaces.io_users.yaml kubeworkspaces.io_authconfigs.yaml \
	kubeworkspaces.io_platformconfigs.yaml kubeworkspaces.io_poddefaults.yaml

# Copy CRDs from kustomize/crds/ into the Helm chart's crds/ directory
sync-helm-crds:
	@mkdir -p helm/kube-workspaces/crds
	@for f in $(HELM_CRDS); do cp "kustomize/crds/$$f" helm/kube-workspaces/crds/; done
	@echo "Synced CRDs into helm/kube-workspaces/crds/"

# Fail if the vendored Helm CRDs have drifted from kustomize/crds/
check-helm-crds:
	@drift=""; \
	for f in $(HELM_CRDS); do \
		if ! diff -q "kustomize/crds/$$f" "helm/kube-workspaces/crds/$$f" >/dev/null 2>&1; then \
			echo "DRIFT: helm/kube-workspaces/crds/$$f differs from kustomize/crds/$$f"; \
			drift="yes"; \
		fi; \
	done; \
	if [ -n "$$drift" ]; then echo "Run 'make sync-helm-crds' to resolve."; exit 1; fi; \
	echo "Helm CRDs are in sync with kustomize/crds/"

# images.yaml is vendored from kube-workspaces/image-catalog (source of
# truth for Image CR manifests) at IMAGE_CATALOG_VERSION, not hand-edited.
# The Helm chart gets its own copies so `helm install` works standalone
# without a runtime fetch.
IMAGE_CATALOG_BASE_URL := https://github.com/$(IMAGE_CATALOG_REPO)/releases/download/$(IMAGE_CATALOG_VERSION)

sync-images:
	@curl -fsSLo images.yaml "$(IMAGE_CATALOG_BASE_URL)/images.yaml"
	@mkdir -p helm/kube-workspaces/files
	@curl -fsSLo helm/kube-workspaces/files/images-catalog.yaml "$(IMAGE_CATALOG_BASE_URL)/images.yaml"
	@curl -fsSLo helm/kube-workspaces/files/images-examples.yaml "$(IMAGE_CATALOG_BASE_URL)/images-examples.yaml"
	@echo "Synced images.yaml and helm/kube-workspaces/files/images-*.yaml from $(IMAGE_CATALOG_REPO)@$(IMAGE_CATALOG_VERSION)"

# Fail if the vendored image manifests have drifted from
# IMAGE_CATALOG_VERSION — catches a version bump that forgot 'make sync-images'.
check-images:
	@tmp=$$(mktemp -d); \
	trap 'rm -rf "$$tmp"' EXIT; \
	curl -fsSLo "$$tmp/images.yaml" "$(IMAGE_CATALOG_BASE_URL)/images.yaml"; \
	curl -fsSLo "$$tmp/images-examples.yaml" "$(IMAGE_CATALOG_BASE_URL)/images-examples.yaml"; \
	drift=""; \
	if ! diff -q "$$tmp/images.yaml" images.yaml >/dev/null 2>&1; then \
		echo "DRIFT: images.yaml differs from $(IMAGE_CATALOG_REPO)@$(IMAGE_CATALOG_VERSION)"; \
		drift="yes"; \
	fi; \
	if ! diff -q "$$tmp/images.yaml" helm/kube-workspaces/files/images-catalog.yaml >/dev/null 2>&1; then \
		echo "DRIFT: helm/kube-workspaces/files/images-catalog.yaml differs from $(IMAGE_CATALOG_REPO)@$(IMAGE_CATALOG_VERSION)"; \
		drift="yes"; \
	fi; \
	if ! diff -q "$$tmp/images-examples.yaml" helm/kube-workspaces/files/images-examples.yaml >/dev/null 2>&1; then \
		echo "DRIFT: helm/kube-workspaces/files/images-examples.yaml differs from $(IMAGE_CATALOG_REPO)@$(IMAGE_CATALOG_VERSION)"; \
		drift="yes"; \
	fi; \
	if [ -n "$$drift" ]; then echo "Run 'make sync-images' to resolve."; exit 1; fi; \
	echo "Vendored image manifests are in sync with $(IMAGE_CATALOG_REPO)@$(IMAGE_CATALOG_VERSION)"

# Install CRDs to the current cluster (server-side apply).
# -k, not -f: with -f, kubectl treats kustomization.yaml as a manifest and fails
# with 'no matches for kind "Kustomization"' after applying the CRDs, so the
# target exits non-zero despite having done its job.
install-crd:
	kubectl apply --server-side -k kustomize/crds/

# Install Image CRs from images.yaml (vendored from image-catalog — see
# 'make sync-images', do not hand-edit)
install-images:
	kubectl apply --server-side -f images.yaml

# Deploy via Kustomize (base)
deploy-kustomize:
	kubectl apply --server-side -k kustomize/base/

# Deploy CRDs via Kustomize
deploy-crds:
	kubectl apply --server-side -k kustomize/crds/

# Deploy via Kustomize with the auth overlay (creates AuthConfig + secrets).
# Edit kustomize/overlays/auth/ CHANGEME values first.
deploy-auth:
	kubectl apply --server-side -k kustomize/overlays/auth/

# Deploy via Kustomize with the local-only auth overlay (creates AuthConfig +
# session secret; no OIDC provider required). A default admin user is
# auto-created — retrieve its password with 'make get-admin-password'.
deploy-auth-local:
	kubectl apply --server-side -k kustomize/overlays/auth-local/

# Enable authentication.
# Requires an existing AuthConfig CR. One is NOT created by kustomize/base — it
# only exists if you deployed with an auth overlay or Helm auth.enabled=true.
# Auth cannot be enabled without at least one authentication method configured
# (the controller rejects it): either OIDC or localAuth.
auth-enable:
	@if ! kubectl get authconfig default >/dev/null 2>&1; then \
		echo "error: AuthConfig 'default' not found in the cluster."; \
		echo; \
		echo "kustomize/base does not create one. To get an AuthConfig, either:"; \
		echo "  - Kustomize (OIDC):  kubectl apply --server-side -k kustomize/overlays/auth/"; \
		echo "  - Kustomize (local): kubectl apply --server-side -k kustomize/overlays/auth-local/"; \
		echo "  - Helm:              helm upgrade ... --set auth.enabled=true"; \
		echo; \
		echo "Enabling auth also requires OIDC settings (issuerURL, clientID,"; \
		echo "clientSecret) or localAuth.enabled=true. See docs/authentication.md."; \
		exit 1; \
	fi
	kubectl patch authconfig default --type=merge -p '{"spec":{"enabled":true}}'

# Disable authentication
auth-disable:
	@if ! kubectl get authconfig default >/dev/null 2>&1; then \
		echo "AuthConfig 'default' not found — auth is already effectively disabled."; \
		exit 0; \
	fi
	kubectl patch authconfig default --type=merge -p '{"spec":{"enabled":false}}'

# Retrieve the bootstrap local admin's password.
# Only works until the admin changes their password for the first time — the
# plaintext key is removed from the Secret at that point (see
# docs/authentication.md). Use 'make reset-admin-password' if the password
# has already been changed or is otherwise unknown.
ADMIN_EMAIL ?= admin@local
get-admin-password:
	@slug=$$(echo "$(ADMIN_EMAIL)" | tr '[:upper:]' '[:lower:]' | sed -e 's/@/-at-/' -e 's/\./-/g' -e 's/_/-/g'); \
	secret="kw-user-$${slug}-local-auth"; \
	pw=$$(kubectl get secret "$$secret" -n kube-workspaces-system -o jsonpath='{.data.password}' 2>/dev/null | base64 -d); \
	if [ -z "$$pw" ]; then \
		echo "error: no plaintext password found in secret/$$secret (already changed, or auth not enabled yet)."; \
		echo "       Use 'make reset-admin-password' to generate and set a new one."; \
		exit 1; \
	fi; \
	echo "$$pw"

# Reset the bootstrap local admin's password to a new randomly generated value.
# Use this when the password has been changed via the UI and is no longer known.
# Prints the new password and sets mustChangePassword=true so the admin is
# prompted to pick a permanent one on next login.
reset-admin-password:
	@command -v python3 >/dev/null 2>&1 || { echo "error: python3 is required"; exit 1; }; \
	python3 -c "import bcrypt" 2>/dev/null || { echo "error: python3 bcrypt module required (pip install bcrypt)"; exit 1; }; \
	slug=$$(echo "$(ADMIN_EMAIL)" | tr '[:upper:]' '[:lower:]' | sed -e 's/@/-at-/' -e 's/\./-/g' -e 's/_/-/g'); \
	secret="kw-user-$${slug}-local-auth"; \
	new_pw=$$(cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 20); \
	new_hash=$$(python3 -c "import bcrypt,sys; print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt(12)).decode())" "$$new_pw"); \
	kubectl patch secret "$$secret" -n kube-workspaces-system --type=merge \
		-p "{\"stringData\":{\"password\":\"$$new_pw\",\"passwordHash\":\"$$new_hash\"}}" >/dev/null; \
	kubectl patch user "$$slug" --type=merge \
		-p '{"spec":{"localAuth":{"mustChangePassword":true}}}' >/dev/null; \
	echo "Password reset for $(ADMIN_EMAIL)"; \
	echo "New password: $$new_pw"; \
	echo "(you will be prompted to change it on next login)"

# Port-forward frontend to localhost:3000
port-forward-frontend:
	kubectl port-forward -n kube-workspaces-system svc/kube-workspaces-frontend 3000:80

# Port-forward API to localhost:8888
port-forward-api:
	kubectl port-forward -n kube-workspaces-system svc/kube-workspaces-api 8888:80

# Port-forward proxy to localhost:8891
port-forward-proxy:
	kubectl port-forward -n kube-workspaces-system svc/kube-workspaces-proxy 8891:80

# Helm install
helm-install:
	helm install kube-workspaces helm/kube-workspaces/ \
		--namespace kube-workspaces-system --create-namespace

# Helm upgrade
helm-upgrade:
	helm upgrade kube-workspaces helm/kube-workspaces/ \
		--namespace kube-workspaces-system

# Helm template (dry-run)
helm-template:
	helm template kube-workspaces helm/kube-workspaces/ \
		--namespace kube-workspaces-system

# Lint Helm chart
lint-helm:
	helm lint helm/kube-workspaces/
