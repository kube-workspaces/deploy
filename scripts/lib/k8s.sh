#!/usr/bin/env bash
# Kubernetes wait / port-forward / diagnostics helpers.
# Source after common.sh.

# ---------------------------------------------------------------------------
# Waiting
# ---------------------------------------------------------------------------

# wait_for_crds [timeout]
# Waits for every CRD in KW_CRDS to reach Established.
#
# Deliberately does not use `kubectl wait`: it exits immediately with NotFound
# when the object does not exist yet rather than waiting for it to appear, and a
# server-side apply of the 837 KiB CRD bundle returns before the API server has
# registered them all. It also proved flaky against the 658 KiB Workspace CRD
# even once present. Polling the condition directly is both simpler and reliable.
wait_for_crds() {
  local timeout="${1:-120s}" crd
  # Strip any unit suffix; used as a per-CRD second budget.
  local budget="${timeout%s}"
  [ "$budget" -gt 0 ] 2>/dev/null || budget=120

  for crd in "${KW_CRDS[@]}"; do
    local i=0 status=""
    while :; do
      status=$(kubectl get "crd/${crd}" \
        -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' \
        2>/dev/null || true)
      [ "$status" = "True" ] && break
      i=$((i + 1))
      if [ "$i" -ge "$budget" ]; then
        if [ -z "$status" ]; then
          fail "CRD $crd Established (not registered after ${budget}s)"
        else
          fail "CRD $crd Established (status=${status} after ${budget}s)"
        fi
        return 1
      fi
      sleep 1
    done
  done
  pass "all ${#KW_CRDS[@]} CRDs Established"
}

# wait_for_deployments [timeout]
# Waits for all four component deployments to be Available.
# Deliberately waits on each by name rather than --all, so a missing
# deployment is a failure instead of a silent pass on an empty set.
wait_for_deployments() {
  local timeout="${1:-300s}" d rc=0
  for d in "${KW_DEPLOYMENTS[@]}"; do
    if ! kubectl get "deployment/$d" -n "$KW_NAMESPACE" >/dev/null 2>&1; then
      fail "deployment $d exists"
      rc=1
      continue
    fi
    if kubectl wait --for=condition=Available \
        "deployment/$d" -n "$KW_NAMESPACE" --timeout="$timeout" >/dev/null 2>&1; then
      pass "deployment $d Available"
    else
      fail "deployment $d Available (timeout ${timeout})"
      rc=1
    fi
  done
  return $rc
}

# assert_no_restarts
# Any container restart means something crash-looped even if it later passed.
assert_no_restarts() {
  local bad
  bad=$(kubectl get pods -n "$KW_NAMESPACE" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.containerStatuses[*]}{.restartCount}{" "}{end}{"\n"}{end}' \
    2>/dev/null | awk 'NF>1 { for (i=2;i<=NF;i++) if ($i+0>0) { print $1": "$i" restarts"; break } }')
  if [ -n "$bad" ]; then
    fail "no container restarts"
    printf '%s\n' "$bad" | sed 's/^/     /' >&2
    return 1
  fi
  pass "no container restarts"
}

# assert_pods_ready
# Belt-and-braces on top of deployment Available: catches pods that are
# Running but not Ready, and any non-Running phase.
assert_pods_ready() {
  local bad
  bad=$(kubectl get pods -n "$KW_NAMESPACE" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' \
    2>/dev/null | awk -F'\t' '$2!="Running" || $3!="True"')
  if [ -n "$bad" ]; then
    fail "all pods Running and Ready"
    printf '%s\n' "$bad" | sed 's/^/     /' >&2
    return 1
  fi
  pass "all pods Running and Ready"
}

# ---------------------------------------------------------------------------
# Port-forwarding
# ---------------------------------------------------------------------------

# Track PIDs so cleanup can always reap them.
PF_PIDS=()

# pf_start <service> <local_port> <remote_port>
# Starts a background port-forward and blocks until the port answers.
# Never leaves a foreground process behind.
pf_start() {
  local svc="$1" lport="$2" rport="$3"
  local log
  log="$(mktemp)"

  kubectl port-forward -n "$KW_NAMESPACE" "svc/${svc}" \
    "${lport}:${rport}" >"$log" 2>&1 &
  local pid=$!
  PF_PIDS+=("$pid")

  # Wait for the tunnel to be usable rather than sleeping a fixed amount.
  local i
  for i in $(seq 1 50); do
    if ! kill -0 "$pid" 2>/dev/null; then
      warn "port-forward for $svc died during startup:"
      sed 's/^/     /' "$log" >&2
      rm -f "$log"
      return 1
    fi
    # bash's /dev/tcp is enough to know the listener is up.
    if (exec 3<>"/dev/tcp/127.0.0.1/${lport}") 2>/dev/null; then
      exec 3<&- 2>/dev/null || true
      rm -f "$log"
      return 0
    fi
    sleep 0.2
  done

  warn "port-forward for $svc did not become ready on :${lport}"
  sed 's/^/     /' "$log" >&2
  rm -f "$log"
  return 1
}

# pf_stop_all — kill every port-forward this script started.
pf_stop_all() {
  local pid
  for pid in "${PF_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  PF_PIDS=()
}

# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

# http_code <url> — echo the status code, or 000 if unreachable.
http_code() {
  curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$1" 2>/dev/null || echo 000
}

# http_body <url>
http_body() {
  curl -sS --max-time 10 "$1" 2>/dev/null || true
}

# retry_http <description> <url> <expected_code> [attempts]
# Retries because a Ready pod is not always instantly serving.
retry_http() {
  local desc="$1" url="$2" want="${3:-200}" attempts="${4:-30}"
  local i got
  for i in $(seq 1 "$attempts"); do
    got=$(http_code "$url")
    if [ "$got" = "$want" ]; then
      pass "$desc ($url -> $got)"
      return 0
    fi
    sleep 1
  done
  fail "$desc ($url -> got $got, want $want)"
  return 1
}

# retry_http_body <description> <url> <needle> [attempts]
retry_http_body() {
  local desc="$1" url="$2" needle="$3" attempts="${4:-30}"
  local i body
  for i in $(seq 1 "$attempts"); do
    body=$(http_body "$url")
    if printf '%s' "$body" | grep -qF -- "$needle"; then
      pass "$desc"
      return 0
    fi
    sleep 1
  done
  fail "$desc (expected body to contain '$needle')"
  printf '     got: %s\n' "$(printf '%s' "$body" | head -c 300)" >&2
  return 1
}

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------

# dump_diagnostics [namespace...]
# Called on failure. Everything here is best-effort — never let a diagnostic
# error mask the real failure.
dump_diagnostics() {
  local namespaces=("$@")
  [ ${#namespaces[@]} -gt 0 ] || namespaces=("$KW_NAMESPACE" "$KW_WORKSPACE_NAMESPACE")

  group "diagnostics"
  local ns
  for ns in "${namespaces[@]}"; do
    kubectl get ns "$ns" >/dev/null 2>&1 || continue

    echo "--- all resources in $ns ---"
    kubectl get all -n "$ns" -o wide 2>&1 | sed 's/^/  /' || true

    echo "--- not-ready pods in $ns ---"
    local pods p
    pods=$(kubectl get pods -n "$ns" \
      -o jsonpath='{range .items[?(@.status.phase!="Running")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
    for p in $pods; do
      echo "  == describe $p =="
      kubectl describe pod "$p" -n "$ns" 2>&1 | sed 's/^/    /' || true
    done

    echo "--- events in $ns (most recent 40) ---"
    kubectl get events -n "$ns" --sort-by=.lastTimestamp 2>&1 \
      | tail -40 | sed 's/^/  /' || true
  done

  echo "--- component logs ---"
  local d
  for d in "${KW_DEPLOYMENTS[@]}"; do
    kubectl get "deployment/$d" -n "$KW_NAMESPACE" >/dev/null 2>&1 || continue
    echo "  == $d (last 60 lines, all containers) =="
    kubectl logs "deployment/$d" -n "$KW_NAMESPACE" \
      --all-containers --tail=60 2>&1 | sed 's/^/    /' || true
    # Previous container logs are where crash-loop causes actually live.
    kubectl logs "deployment/$d" -n "$KW_NAMESPACE" \
      --all-containers --tail=60 --previous 2>/dev/null | sed 's/^/    [prev] /' || true
  done
  endgroup
}

# Register a trap that tears down port-forwards and dumps diagnostics on
# non-zero exit. Call once, early, from any script that touches a cluster.
install_cluster_trap() {
  # shellcheck disable=SC2317  # invoked via trap
  _cluster_exit_trap() {
    local rc=$?
    pf_stop_all
    if [ "$rc" -ne 0 ] || [ "${CHECKS_FAILED:-0}" -gt 0 ]; then
      dump_diagnostics || true
    fi
    return $rc
  }
  trap _cluster_exit_trap EXIT
}
