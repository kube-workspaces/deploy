#!/usr/bin/env bash
# Layer 2: functional end-to-end test against an existing kube-workspaces
# deployment in the current kubectl context.
#
# Where smoke.sh proves the components start, this proves the platform actually
# works: the controller reconciles a Workspace into a StatefulSet + Service, the
# API can see it, the proxy routes to it, stop/start scales it, and deleting the
# CR garbage-collects the children.
#
# Usage: scripts/e2e.sh
#
# Env:
#   KW_WORKSPACE_NAMESPACE   default 'workspaces'
#   E2E_IMAGE                container image for the test workspace
#                            (default traefik/whoami — ~5 MB, serves HTTP on 80)
#   E2E_KEEP                 set to leave the test workspace behind

SCRIPT_NAME="e2e"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/k8s.sh
source "${SCRIPT_DIR}/lib/k8s.sh"

require_tools kubectl curl jq

WS_NAME="${WS_NAME:-e2e-smoke}"
NS="$KW_WORKSPACE_NAMESPACE"
# traefik/whoami is tiny and echoes the request, so we can prove the proxy
# actually reached the workspace rather than just returning something.
E2E_IMAGE="${E2E_IMAGE:-traefik/whoami}"
E2E_PORT="${E2E_PORT:-80}"

API_PORT="${API_PORT:-18888}"
PROXY_PORT="${PROXY_PORT:-18891}"

api="http://127.0.0.1:${API_PORT}"
proxy="http://127.0.0.1:${PROXY_PORT}"

cleanup() {
  local rc=$?
  pf_stop_all
  if [ -z "${E2E_KEEP:-}" ]; then
    kubectl delete workspace "$WS_NAME" -n "$NS" \
      --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
  if [ "$rc" -ne 0 ] || [ "${CHECKS_FAILED:-0}" -gt 0 ]; then
    warn "e2e failed — dumping diagnostics"
    kubectl describe workspace "$WS_NAME" -n "$NS" 2>&1 | sed 's/^/  /' >&2 || true
    dump_diagnostics || true
  fi
  return $rc
}
trap cleanup EXIT

info "context:   $(kubectl config current-context 2>/dev/null || echo unknown)"
info "workspace: ${NS}/${WS_NAME} (${E2E_IMAGE}:${E2E_PORT})"

# Fail fast if the platform is not actually up — otherwise every assertion
# below fails confusingly.
kubectl get ns "$NS" >/dev/null 2>&1 \
  || die "namespace ${NS} does not exist; is kube-workspaces deployed?"
kubectl get crd workspaces.kubeworkspaces.io >/dev/null 2>&1 \
  || die "Workspace CRD is missing; is kube-workspaces deployed?"

# Start with a clean slate in case a previous run left something behind.
kubectl delete workspace "$WS_NAME" -n "$NS" --ignore-not-found >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 1. Create the Workspace
# ---------------------------------------------------------------------------

group "create workspace"

# A raw Workspace needs no matching Image CR — Image CRs only populate the
# UI/API catalog and supply defaults at creation time through the API.
if kubectl apply --server-side -f - >/dev/null 2>&1 <<EOF
apiVersion: kubeworkspaces.io/v1alpha1
kind: Workspace
metadata:
  name: ${WS_NAME}
  namespace: ${NS}
spec:
  template:
    spec:
      containers:
        - name: workspace
          image: ${E2E_IMAGE}
          ports:
            - containerPort: ${E2E_PORT}
              name: workspace-port
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              cpu: 200m
              memory: 128Mi
EOF
then
  pass "Workspace CR created"
else
  fail "Workspace CR created"
  finish; exit 1
fi

endgroup

# ---------------------------------------------------------------------------
# 2. Controller reconciliation
# ---------------------------------------------------------------------------

group "controller reconciliation"

# The controller names the StatefulSet and Service after the workspace, and the
# pod is <name>-0.
if kubectl rollout status "statefulset/${WS_NAME}" -n "$NS" \
    --timeout="${E2E_TIMEOUT:-240s}" >/dev/null 2>&1; then
  pass "StatefulSet ${WS_NAME} rolled out"
else
  fail "StatefulSet ${WS_NAME} rolled out"
fi

check "Service ${WS_NAME} was created" kubectl get "svc/${WS_NAME}" -n "$NS"
check "Pod ${WS_NAME}-0 exists" kubectl get "pod/${WS_NAME}-0" -n "$NS"

# The Service maps port 80 to the container's first port.
svc_port=$(kubectl get "svc/${WS_NAME}" -n "$NS" \
  -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)
check_equals "Service exposes port 80" "80" "$svc_port"

svc_target=$(kubectl get "svc/${WS_NAME}" -n "$NS" \
  -o jsonpath='{.spec.ports[0].targetPort}' 2>/dev/null)
check_equals "Service targets the container port" "$E2E_PORT" "$svc_target"

# Children must be owned by the Workspace so deletion cascades.
owner=$(kubectl get "statefulset/${WS_NAME}" -n "$NS" \
  -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null)
check_equals "StatefulSet is owned by the Workspace" "Workspace" "$owner"

# Status must reflect reality.
ready=$(kubectl get workspace "$WS_NAME" -n "$NS" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
check_equals "Workspace status.readyReplicas is 1" "1" "${ready:-0}"

endgroup

# ---------------------------------------------------------------------------
# 3. API visibility
# ---------------------------------------------------------------------------

group "api"

if pf_start kube-workspaces-api "$API_PORT" 80; then
  retry_http "api sees the workspace" \
    "${api}/v1/workspaces/${WS_NAME}?namespace=${NS}" 200

  body=$(http_body "${api}/v1/workspaces/${WS_NAME}?namespace=${NS}")
  got_name=$(printf '%s' "$body" | jq -r '.name // empty' 2>/dev/null)
  check_equals "api reports the correct workspace name" "$WS_NAME" "$got_name"

  # NOTE: use has()/tostring rather than `.stopped // empty` — jq's alternative
  # operator treats a legitimate `false` as absent and yields an empty string.
  got_stopped=$(printf '%s' "$body" \
    | jq -r 'if has("stopped") then (.stopped|tostring) else "" end' 2>/dev/null)
  check_equals "api reports the workspace as not stopped" "false" "$got_stopped"

  # It must also appear in the list, not just the single-item lookup.
  if http_body "${api}/v1/workspaces?namespace=${NS}" \
      | jq -e --arg n "$WS_NAME" 'any(.[]; .name == $n)' >/dev/null 2>&1; then
    pass "workspace appears in the api list"
  else
    fail "workspace appears in the api list"
  fi

  # Logs and pod endpoints should work for a running workspace.
  retry_http "api serves workspace logs" \
    "${api}/v1/workspaces/${WS_NAME}/logs?namespace=${NS}&lines=5" 200 10
  retry_http "api serves workspace pod detail" \
    "${api}/v1/workspaces/${WS_NAME}/pod?namespace=${NS}" 200 10
else
  fail "port-forward to the api service"
fi

endgroup

# ---------------------------------------------------------------------------
# 4. Proxy routing — the real end-to-end path
# ---------------------------------------------------------------------------

group "proxy routing"

if pf_start kube-workspaces-proxy "$PROXY_PORT" 80; then
  # whoami echoes the request headers, so seeing its output proves the proxy
  # reached the workspace container rather than short-circuiting.
  retry_http "proxy routes to the workspace" \
    "${proxy}/proxy/${NS}/${WS_NAME}/" 200 30
  retry_http_body "proxy returns the workspace's response" \
    "${proxy}/proxy/${NS}/${WS_NAME}/" "Hostname" 20

  # An unknown workspace must not 200.
  code=$(http_code "${proxy}/proxy/${NS}/definitely-not-a-workspace/")
  if [ "$code" = "200" ]; then
    fail "proxy rejects an unknown workspace (got 200)"
  else
    pass "proxy rejects an unknown workspace (got ${code})"
  fi
else
  fail "port-forward to the proxy service"
fi

endgroup

# ---------------------------------------------------------------------------
# 5. Stop / start
# ---------------------------------------------------------------------------

group "stop / start"

if pf_start kube-workspaces-api "$API_PORT" 80; then
  # Stop is annotation-driven: the controller scales the StatefulSet to 0 and
  # leaves the CR in place.
  if curl -fsS -X POST \
      "${api}/v1/workspaces/${WS_NAME}/stop?namespace=${NS}" >/dev/null 2>&1; then
    pass "api accepted the stop request"
  else
    fail "api accepted the stop request"
  fi

  ok=0
  for _ in $(seq 1 60); do
    r=$(kubectl get "statefulset/${WS_NAME}" -n "$NS" \
      -o jsonpath='{.spec.replicas}' 2>/dev/null)
    [ "$r" = "0" ] && { ok=1; break; }
    sleep 2
  done
  if [ "$ok" = "1" ]; then
    pass "StatefulSet scaled to 0 replicas after stop"
  else
    fail "StatefulSet scaled to 0 replicas after stop (got ${r:-?})"
  fi

  if kubectl get workspace "$WS_NAME" -n "$NS" \
      -o jsonpath='{.metadata.annotations}' 2>/dev/null \
      | grep -q 'kubeworkspaces.io/stopped'; then
    pass "Workspace carries the kubeworkspaces.io/stopped annotation"
  else
    fail "Workspace carries the kubeworkspaces.io/stopped annotation"
  fi

  # The CR itself must survive a stop.
  check "Workspace CR still exists after stop" \
    kubectl get workspace "$WS_NAME" -n "$NS"

  # Now start it again.
  if curl -fsS -X POST \
      "${api}/v1/workspaces/${WS_NAME}/start?namespace=${NS}" >/dev/null 2>&1; then
    pass "api accepted the start request"
  else
    fail "api accepted the start request"
  fi

  if kubectl rollout status "statefulset/${WS_NAME}" -n "$NS" \
      --timeout=240s >/dev/null 2>&1; then
    pass "StatefulSet became ready again after start"
  else
    fail "StatefulSet became ready again after start"
  fi
else
  fail "port-forward to the api service for stop/start"
fi
pf_stop_all

endgroup

# ---------------------------------------------------------------------------
# 6. Deletion cascades
# ---------------------------------------------------------------------------

group "deletion"

check "delete the Workspace CR" \
  kubectl delete workspace "$WS_NAME" -n "$NS" --wait=true --timeout=120s

# Garbage collection is asynchronous, so poll.
gone=0
for _ in $(seq 1 60); do
  if ! kubectl get "statefulset/${WS_NAME}" -n "$NS" >/dev/null 2>&1 \
     && ! kubectl get "svc/${WS_NAME}" -n "$NS" >/dev/null 2>&1; then
    gone=1; break
  fi
  sleep 2
done
if [ "$gone" = "1" ]; then
  pass "StatefulSet and Service were garbage-collected"
else
  fail "StatefulSet and Service were garbage-collected"
fi

endgroup

finish
