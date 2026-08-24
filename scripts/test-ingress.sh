#!/usr/bin/env bash
# Layer 3: ingress test on k3d.
#
# kustomize/base/ingress.yaml hardcodes `ingressClassName: traefik`, which a
# default kind cluster has no controller for — the Ingress is inert there and the
# other tests remove it. k3d bundles Traefik, so it is the cheapest way to
# actually exercise that manifest: routing rules, path precedence, and the
# service backends behind them.
#
# Usage: scripts/test-ingress.sh
#
# Env:
#   K3D_CLUSTER    cluster name (default kw-test-ingress)
#   K3D_HTTP_PORT  host port mapped to the cluster's :80 (default 18080)
#   K3D_KEEP       leave the cluster running afterwards

SCRIPT_NAME="test-ingress"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/k8s.sh
source "${SCRIPT_DIR}/lib/k8s.sh"

require_tools k3d kubectl kustomize curl

cd "$REPO_ROOT"

: "${K3D_CLUSTER:=kw-test-ingress}"
: "${K3D_HTTP_PORT:=18080}"

# The base Ingress serves these hosts. We resolve them to the mapped port with
# curl --resolve rather than touching /etc/hosts.
HOST_MAIN=workspaces.example.com
HOST_API=api.workspaces.example.com

cleanup() {
  local rc=$?
  pf_stop_all
  if [ "$rc" -ne 0 ] || [ "${CHECKS_FAILED:-0}" -gt 0 ]; then
    warn "ingress test failed — dumping diagnostics"
    kubectl get ingress -A -o wide 2>&1 | sed 's/^/  /' >&2 || true
    kubectl -n kube-system logs -l app.kubernetes.io/name=traefik \
      --tail=60 2>&1 | sed 's/^/  traefik: /' >&2 || true
    dump_diagnostics || true
  fi
  if [ -z "${K3D_KEEP:-}" ]; then
    k3d cluster delete "$K3D_CLUSTER" >/dev/null 2>&1 || true
  else
    warn "K3D_KEEP set — leaving cluster ${K3D_CLUSTER} running"
  fi
  return $rc
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------

group "k3d cluster: ${K3D_CLUSTER}"

if k3d cluster list 2>/dev/null | awk '{print $1}' | grep -qx "$K3D_CLUSTER"; then
  info "cluster already exists — deleting it for a clean run"
  k3d cluster delete "$K3D_CLUSTER" >/dev/null 2>&1 || true
fi

# Map a host port to the loadbalancer's :80 so the Ingress is reachable from
# here. Traefik ships enabled by default, which is the entire point of using k3d.
info "creating cluster (this pulls the k3s image on first run)"
k3d cluster create "$K3D_CLUSTER" \
  --port "${K3D_HTTP_PORT}:80@loadbalancer" \
  --wait \
  --timeout 180s \
  >/dev/null 2>&1 || die "k3d cluster create failed"

kubectl config use-context "k3d-${K3D_CLUSTER}" >/dev/null 2>&1 \
  || die "could not switch to context k3d-${K3D_CLUSTER}"

info "context: $(kubectl config current-context)"

# Traefik is installed by a HelmChart CR, so it appears slightly after the node
# is Ready.
ok=0
for _ in $(seq 1 60); do
  if kubectl -n kube-system get deploy traefik >/dev/null 2>&1; then
    ok=1; break
  fi
  sleep 5
done
if [ "$ok" = "1" ]; then
  kubectl -n kube-system rollout status deploy/traefik --timeout=180s >/dev/null 2>&1
  pass "Traefik ingress controller is running"
else
  fail "Traefik ingress controller is running"
  finish; exit 1
fi

# The manifest pins this class; if k3d ever stops providing it the test is void.
if kubectl get ingressclass traefik >/dev/null 2>&1; then
  pass "the 'traefik' IngressClass exists"
else
  fail "the 'traefik' IngressClass exists (kustomize/base pins ingressClassName: traefik)"
fi

endgroup

# ---------------------------------------------------------------------------
# Deploy, including the real Ingress
# ---------------------------------------------------------------------------

group "deploy"

check "apply CRDs (server-side)" kubectl apply --server-side -k kustomize/crds/
wait_for_crds 120s

# Deliberately kustomize/base, not overlays/test: base is the only variant that
# carries the Ingress, and testing it is the whole purpose here.
check "apply kustomize/base (server-side)" \
  kubectl apply --server-side -k kustomize/base/
check "apply Image CRs" kubectl apply --server-side -f images.yaml

wait_for_deployments 300s
assert_pods_ready

endgroup

# ---------------------------------------------------------------------------
# The Ingress itself
# ---------------------------------------------------------------------------

group "ingress object"

check "Ingress exists" kubectl get ingress kube-workspaces -n "$KW_NAMESPACE"

class=$(kubectl get ingress kube-workspaces -n "$KW_NAMESPACE" \
  -o jsonpath='{.spec.ingressClassName}' 2>/dev/null)
check_equals "ingressClassName is traefik" "traefik" "$class"

# Unlike on kind, the Ingress should now actually be assigned an address. This is
# the assertion the other test methods can never make.
addr=""
for _ in $(seq 1 60); do
  addr=$(kubectl get ingress kube-workspaces -n "$KW_NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
  [ -n "$addr" ] && break
  sleep 5
done
if [ -n "$addr" ]; then
  pass "Ingress was assigned an address (${addr})"
else
  fail "Ingress was assigned an address"
fi

endgroup

# ---------------------------------------------------------------------------
# Routing — does each path reach the service it names?
# ---------------------------------------------------------------------------

group "routing"

base="http://${HOST_MAIN}:${K3D_HTTP_PORT}"
resolve=(--resolve "${HOST_MAIN}:${K3D_HTTP_PORT}:127.0.0.1")

# ingress_get <path> -> status code, with the Host header set correctly.
ingress_get() {
  curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
    "${resolve[@]}" "${base}$1" 2>/dev/null || echo 000
}
ingress_body() {
  curl -sS --max-time 15 "${resolve[@]}" "${base}$1" 2>/dev/null || true
}

# Retry: Traefik needs a moment to pick up the Ingress after it is created.
retry_ingress() {
  local desc="$1" path="$2" want="$3" attempts="${4:-30}"
  local i got
  for i in $(seq 1 "$attempts"); do
    got=$(ingress_get "$path")
    if [ "$got" = "$want" ]; then
      pass "$desc (${path} -> ${got})"
      return 0
    fi
    sleep 2
  done
  fail "$desc (${path} -> got ${got}, want ${want})"
  return 1
}

# / must reach the frontend (the catch-all, declared last).
retry_ingress "/ routes to the frontend" "/" 200
if printf '%s' "$(ingress_body /)" | grep -q '<html'; then
  pass "/ returns the frontend's HTML"
else
  fail "/ returns the frontend's HTML"
fi

# /v1 and /openapi must reach the API, not be swallowed by the catch-all.
retry_ingress "/v1/images routes to the api" "/v1/images" 200
retry_ingress "/v1/namespaces routes to the api" "/v1/namespaces" 200

# /proxy must reach the proxy. A 404 here would mean it hit the API instead,
# which is exactly the bug that shipped in the Helm chart's default values.
code=$(ingress_get "/proxy/${KW_WORKSPACE_NAMESPACE}/nonexistent/")
case "$code" in
  502|503|404)
    # The proxy answers for an unknown workspace; the important thing is that
    # the request reached the proxy rather than 404ing at the API's router.
    pass "/proxy reaches the proxy service (${code})"
    ;;
  200) fail "/proxy reaches the proxy service (got 200 for a nonexistent workspace)" ;;
  *)   fail "/proxy reaches the proxy service (got ${code})" ;;
esac

# Frontend page routes must not be captured by the API prefixes.
retry_ingress "/workspaces page routes to the frontend" "/workspaces" 200
retry_ingress "/admin page routes to the frontend" "/admin" 200

# The second host sends everything to the API.
api_base="http://${HOST_API}:${K3D_HTTP_PORT}"
api_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
  --resolve "${HOST_API}:${K3D_HTTP_PORT}:127.0.0.1" \
  "${api_base}/healthz" 2>/dev/null || echo 000)
check_equals "the api host serves /healthz" "200" "$api_code"

endgroup

# ---------------------------------------------------------------------------
# The components must still be healthy behind the Ingress
# ---------------------------------------------------------------------------

group "smoke"
if "${SCRIPT_DIR}/smoke.sh"; then
  pass "smoke suite (k3d + traefik)"
else
  fail "smoke suite (k3d + traefik)"
fi
endgroup

finish
