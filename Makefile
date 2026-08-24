# Deploy repo Makefile - operational targets for kube-workspaces deployment

.PHONY: install-crd install-images pull-images push-images deploy-kustomize deploy-crds \
	deploy-auth auth-enable auth-disable port-forward-frontend port-forward-api \
	port-forward-proxy helm-install helm-upgrade helm-template lint-helm \
	sync-helm-crds check-helm-crds \
	test-tools test-lint test-smoke test-e2e test-all test-dump \
	kind-up kind-down \
	test-deploy-kustomize test-deploy-helm test-deploy-helm-oci \
	test-deploy-argocd test-deploy-auth test-upgrade

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

test-upgrade: test-tools
	@scripts/test-upgrade.sh

# Everything, in cost order.
test-all: test-lint
	@scripts/test-deploy.sh kustomize
	@scripts/test-deploy.sh helm
	@scripts/test-deploy.sh helm-oci

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

# Install CRDs to the current cluster (server-side apply)
install-crd:
	kubectl apply --server-side -f kustomize/crds/

# Install Image CRs from images.yaml
install-images:
	kubectl apply --server-side -f images.yaml

# Pull Image CRs from cluster into local images.yaml
pull-images:
	python3 pull-images.py > images.yaml

# Push local images.yaml to cluster
push-images:
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

# Enable authentication.
# Requires an existing AuthConfig CR. One is NOT created by kustomize/base — it
# only exists if you deployed with the auth overlay or Helm auth.enabled=true.
# Auth cannot be enabled without OIDC config (the controller rejects it), so we
# refuse to create a half-configured CR here.
auth-enable:
	@if ! kubectl get authconfig default >/dev/null 2>&1; then \
		echo "error: AuthConfig 'default' not found in the cluster."; \
		echo; \
		echo "kustomize/base does not create one. To get an AuthConfig, either:"; \
		echo "  - Kustomize: kubectl apply --server-side -k kustomize/overlays/auth/"; \
		echo "  - Helm:      helm upgrade ... --set auth.enabled=true"; \
		echo; \
		echo "Enabling auth also requires OIDC settings (issuerURL, clientID,"; \
		echo "clientSecret). See docs/authentication.md."; \
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
