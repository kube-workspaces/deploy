#!/usr/bin/env bash
# Layer 1: smoke-test a kube-workspaces deployment in the current kubectl
# context. Deployment-method agnostic — it asserts the outcome, not how you
# got there, so it works for Kustomize, Helm, OCI Helm and ArgoCD alike.
#
# Usage: scripts/smoke.sh
#
# Env:
#   KW_NAMESPACE        default kube-workspaces-system
#   KW_EXPECT_IMAGES    set to 0 to skip the Image-catalog assertions
#                       (kustomize/base creates no Image CRs on its own)
#   KW_SKIP_INGRESS     unused; the base Ingress is inert on kind by design
#
# Ports used locally: 18888 (api), 18891 (proxy), 13000 (frontend). Deliberately
# not 8888/3000 so a developer's own port-forwards are not clobbered.

SCRIPT_NAME="smoke"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/k8s.sh
source "${SCRIPT_DIR}/lib/k8s.sh"

require_tools kubectl curl

API_PORT="${API_PORT:-18888}"
PROXY_PORT="${PROXY_PORT:-18891}"
FRONTEND_PORT="${FRONTEND_PORT:-13000}"

install_cluster_trap

info "context: $(kubectl config current-context 2>/dev/null || echo unknown)"
info "namespace: ${KW_NAMESPACE}"

# Detect whether authentication is enabled, so the API assertions expect the
# right thing. With auth on, an unauthenticated 200 would be a bypass, not a
# pass. Callers can force it either way with KW_AUTH_ENABLED.
if [ -z "${KW_AUTH_ENABLED:-}" ]; then
  if [ "$(kubectl get authconfig default \
      -o jsonpath='{.spec.enabled}' 2>/dev/null)" = "true" ]; then
    KW_AUTH_ENABLED=1
  else
    KW_AUTH_ENABLED=0
  fi
fi
export KW_AUTH_ENABLED
info "auth enabled: ${KW_AUTH_ENABLED}"

# ---------------------------------------------------------------------------
# CRDs and workloads
# ---------------------------------------------------------------------------

group "CRDs"
wait_for_crds 120s
endgroup

group "workloads"
wait_for_deployments "${DEPLOY_TIMEOUT:-300s}"
assert_pods_ready
assert_no_restarts
endgroup

group "services"
for svc in kube-workspaces-api kube-workspaces-proxy kube-workspaces-frontend; do
  check "service ${svc} exists" \
    kubectl get "svc/${svc}" -n "$KW_NAMESPACE"
done

# The controller is intentionally headless — it has no Service in base. Assert
# that stays true so a stray Service does not appear unnoticed.
if kubectl get svc/kube-workspaces-controller -n "$KW_NAMESPACE" >/dev/null 2>&1; then
  warn "unexpected Service for the controller — base does not define one"
fi
endgroup

# ---------------------------------------------------------------------------
# HTTP surface
# ---------------------------------------------------------------------------

group "api"
if pf_start kube-workspaces-api "$API_PORT" 80; then
  api="http://127.0.0.1:${API_PORT}"

  # /healthz is always unauthenticated.
  retry_http_body "api /healthz returns ok" "${api}/healthz" '"status":"ok"'

  if [ "${KW_AUTH_ENABLED:-0}" = "1" ]; then
    # With auth on, the correct behaviour for an unauthenticated caller is a
    # rejection. Asserting 200 here would be asserting an auth bypass.
    info "auth is enabled — asserting endpoints reject unauthenticated calls"
    for ep in \
      "/v1/workspaces?namespace=${KW_WORKSPACE_NAMESPACE}" \
      "/v1/namespaces" \
      "/v1/volumes?namespace=${KW_WORKSPACE_NAMESPACE}" \
      "/v1/images"
    do
      code=$(http_code "${api}${ep}")
      case "$code" in
        401|403) pass "api ${ep} rejects unauthenticated access (${code})" ;;
        *)       fail "api ${ep} rejects unauthenticated access (got ${code}, want 401/403)" ;;
      esac
    done

    # The login/config endpoint must stay reachable or nobody can authenticate.
    code=$(http_code "${api}/auth/config")
    case "$code" in
      200) pass "api /auth/config is reachable (${code})" ;;
      *)   fail "api /auth/config is reachable (got ${code})" ;;
    esac
  else
    retry_http "api /v1/workspaces responds" "${api}/v1/workspaces?namespace=${KW_WORKSPACE_NAMESPACE}" 200
    retry_http "api /v1/namespaces responds" "${api}/v1/namespaces" 200
    retry_http "api /v1/volumes responds" "${api}/v1/volumes?namespace=${KW_WORKSPACE_NAMESPACE}" 200
    retry_http "api /v1/images responds" "${api}/v1/images" 200
    retry_http "api /platform/config responds" "${api}/platform/config" 200

    # An unknown path must 404 rather than 200 — catches a catch-all misroute.
    retry_http "api unknown path 404s" "${api}/v1/definitely-not-a-route" 404 3
  fi

  # The OpenAPI document must be valid JSON, not just a 200.
  if http_body "${api}/openapi3.json" | jq -e '.openapi' >/dev/null 2>&1; then
    pass "api /openapi3.json is valid OpenAPI JSON"
  else
    fail "api /openapi3.json is valid OpenAPI JSON"
  fi

  # Image catalog. kustomize/base ships no Image CRs, so this is opt-in, and it
  # is unreadable anonymously when auth is on.
  if [ "${KW_EXPECT_IMAGES:-1}" = "1" ] && [ "${KW_AUTH_ENABLED:-0}" != "1" ]; then
    count=$(http_body "${api}/v1/images" | jq 'length' 2>/dev/null || echo 0)
    if [ "${count:-0}" -gt 0 ]; then
      pass "api /v1/images returns ${count} image(s)"
    else
      fail "api /v1/images returns at least one image (got ${count:-0}); did 'make install-images' run?"
    fi
  else
    info "skipping Image catalog assertions"
  fi
else
  fail "port-forward to the api service"
fi
pf_stop_all
endgroup

group "proxy"
if pf_start kube-workspaces-proxy "$PROXY_PORT" 80; then
  proxy="http://127.0.0.1:${PROXY_PORT}"
  retry_http_body "proxy /healthz returns ok" "${proxy}/healthz" '"status":"ok"'
  retry_http_body "proxy /readyz returns ok" "${proxy}/readyz" '"status":"ok"'
  retry_http_body "proxy / identifies itself" "${proxy}/" 'kube-workspaces-proxy'
  # The no-op service worker is load-bearing for proxied apps.
  retry_http "proxy /sw.js is served" "${proxy}/sw.js" 200
else
  fail "port-forward to the proxy service"
fi
pf_stop_all
endgroup

group "frontend"
if pf_start kube-workspaces-frontend "$FRONTEND_PORT" 80; then
  fe="http://127.0.0.1:${FRONTEND_PORT}"
  # The frontend has no /healthz; / is its probe path (matching the manifests).
  retry_http "frontend / responds 200" "${fe}/" 200
  retry_http_body "frontend / serves HTML" "${fe}/" '<html'
  retry_http "frontend /workspaces page responds" "${fe}/workspaces" 200
else
  fail "port-forward to the frontend service"
fi
pf_stop_all
endgroup

# ---------------------------------------------------------------------------
# Controller
# ---------------------------------------------------------------------------

group "controller"
# The controller exposes health on 8081 and metrics on 8080, but has no
# Service, so probe the pod directly.
pod=$(kubectl get pods -n "$KW_NAMESPACE" \
  -l app.kubernetes.io/component=controller \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -n "$pod" ]; then
  pass "controller pod found (${pod})"
  # port-forward straight to the pod.
  kubectl port-forward -n "$KW_NAMESPACE" "pod/${pod}" 18081:8081 >/dev/null 2>&1 &
  cpid=$!
  PF_PIDS+=("$cpid")
  ok=0
  for _ in $(seq 1 40); do
    if (exec 3<>/dev/tcp/127.0.0.1/18081) 2>/dev/null; then
      exec 3<&- 2>/dev/null || true
      ok=1; break
    fi
    kill -0 "$cpid" 2>/dev/null || break
    sleep 0.25
  done
  if [ "$ok" = "1" ]; then
    retry_http "controller /readyz responds" "http://127.0.0.1:18081/readyz" 200 10
    retry_http "controller /healthz responds" "http://127.0.0.1:18081/healthz" 200 10
  else
    fail "port-forward to the controller pod"
  fi
  pf_stop_all
else
  fail "controller pod found"
fi
endgroup

# ---------------------------------------------------------------------------
# RBAC — the API and controller share a ServiceAccount and must be bound.
# ---------------------------------------------------------------------------

group "rbac"
# The ServiceAccount name differs by deployment method: kustomize/base uses
# 'kube-workspaces-controller', while the Helm chart uses the release fullname
# (e.g. 'kube-workspaces'). Discover it from the controller Deployment rather
# than hardcoding either, so this works for every install path.
ctrl_sa=$(kubectl get deployment/kube-workspaces-controller -n "$KW_NAMESPACE" \
  -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null)
: "${ctrl_sa:=default}"
info "controller ServiceAccount: ${ctrl_sa}"

check "controller ServiceAccount ${ctrl_sa} exists" \
  kubectl get "sa/${ctrl_sa}" -n "$KW_NAMESPACE"

# Verify the effective permissions via SelfSubjectAccessReview rather than
# inspecting bindings, so we test what the controller can actually do.
if kubectl auth can-i list workspaces.kubeworkspaces.io \
    --all-namespaces \
    --as="system:serviceaccount:${KW_NAMESPACE}:${ctrl_sa}" \
    >/dev/null 2>&1; then
  pass "controller SA can list workspaces cluster-wide"
else
  fail "controller SA can list workspaces cluster-wide"
fi

if kubectl auth can-i create statefulsets \
    -n "$KW_WORKSPACE_NAMESPACE" \
    --as="system:serviceaccount:${KW_NAMESPACE}:${ctrl_sa}" \
    >/dev/null 2>&1; then
  pass "controller SA can create statefulsets in ${KW_WORKSPACE_NAMESPACE}"
else
  fail "controller SA can create statefulsets in ${KW_WORKSPACE_NAMESPACE}"
fi

# The proxy has its own SA in both paths and needs to read session secrets.
proxy_sa=$(kubectl get deployment/kube-workspaces-proxy -n "$KW_NAMESPACE" \
  -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null)
if [ -n "$proxy_sa" ]; then
  check "proxy ServiceAccount ${proxy_sa} exists" \
    kubectl get "sa/${proxy_sa}" -n "$KW_NAMESPACE"
fi

# No component should run as 'default' — that hides the effective permissions.
#
# KW_LENIENT_SA downgrades this to a warning. It is set when smoke-testing an
# already-published artifact (see test-deploy.sh helm-oci): a release made before
# this hardening landed legitimately still uses 'default', and the job's purpose
# is to prove the released chart installs, not to re-litigate its contents.
default_users=$(kubectl get deployments -n "$KW_NAMESPACE" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.serviceAccountName}{"\n"}{end}' \
  2>/dev/null | awk -F'\t' '$2=="" || $2=="default" {print $1}')
if [ -z "$default_users" ]; then
  pass "no Deployment runs as the default ServiceAccount"
elif [ -n "${KW_LENIENT_SA:-}" ]; then
  warn "Deployment(s) run as the default ServiceAccount: $(echo "$default_users" | tr '\n' ' ')"
  info "tolerated because KW_LENIENT_SA is set (testing a published artifact)"
else
  fail "no Deployment runs as the default ServiceAccount"
  printf '%s\n' "$default_users" | sed 's/^/     /' >&2
fi

# The frontend has no Kubernetes client, so it must not have a token mounted.
# Assert at runtime, not just in the manifest.
if kubectl exec -n "$KW_NAMESPACE" deploy/kube-workspaces-frontend -- \
    test -e /var/run/secrets/kubernetes.io/serviceaccount/token >/dev/null 2>&1; then
  if [ -n "${KW_LENIENT_SA:-}" ]; then
    warn "frontend has a ServiceAccount token mounted (tolerated: KW_LENIENT_SA)"
  else
    fail "frontend has no ServiceAccount token mounted"
  fi
else
  pass "frontend has no ServiceAccount token mounted"
fi
endgroup

finish
