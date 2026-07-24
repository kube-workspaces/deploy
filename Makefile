# Deploy repo Makefile - operational targets for kube-workspaces deployment

.PHONY: install-crd install-images pull-images push-images deploy-kustomize deploy-crds \
	auth-enable auth-disable port-forward-frontend port-forward-api port-forward-proxy \
	helm-install helm-upgrade helm-template lint-helm

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

# Enable authentication
auth-enable:
	kubectl patch authconfig default --type=merge -p '{"spec":{"enabled":true}}'

# Disable authentication
auth-disable:
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
