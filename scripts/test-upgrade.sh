#!/usr/bin/env bash
# Layer 3: chart upgrade test.
#
# Installs the newest *published* chart, then upgrades to the local one and
# smoke-tests the result. This is the path every existing user takes, and it
# exercises things a fresh install never does: changed immutable fields, removed
# or renamed resources, and CRD updates applied over existing objects.
#
# Usage: scripts/test-upgrade.sh
#
# Env:
#   FROM_VERSION   published version to install first (default: newest published)
#   KIND_KEEP      leave the cluster running afterwards
#   SKIP_CLUSTER   use the current context instead of creating a cluster

SCRIPT_NAME="test-upgrade"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/k8s.sh
source "${SCRIPT_DIR}/lib/k8s.sh"

require_tools kubectl helm curl jq

cd "$REPO_ROOT"

: "${KIND_CLUSTER:=kw-test-upgrade}"
export KIND_CLUSTER

HELM_RELEASE=kube-workspaces
CHART_REF="oci://ghcr.io/kube-workspaces/charts/kube-workspaces"

cleanup() {
  local rc=$?
  pf_stop_all
  if [ "$rc" -ne 0 ] || [ "${CHECKS_FAILED:-0}" -gt 0 ]; then
    warn "upgrade test failed — dumping diagnostics"
    dump_diagnostics || true
    helm history "$HELM_RELEASE" -n "$KW_NAMESPACE" 2>&1 | sed 's/^/  /' >&2 || true
  fi
  if [ -z "${SKIP_CLUSTER:-}" ]; then
    "${SCRIPT_DIR}/kind.sh" down || true
  fi
  [ -n "${oci_conf:-}" ] && rm -rf "$oci_conf"
  return $rc
}
trap cleanup EXIT

# The published chart is public; pull anonymously so a stale ghcr.io credential
# cannot turn this into a 403.
oci_conf="$(mktemp -d)"
printf '{}' > "${oci_conf}/config.json"
export DOCKER_CONFIG="$oci_conf"

LOCAL_VERSION=$(awk '/^version:/{print $2; exit}' helm/kube-workspaces/Chart.yaml)

# ---------------------------------------------------------------------------
# Work out which published version to upgrade from
# ---------------------------------------------------------------------------

group "resolve versions"

if [ -z "${FROM_VERSION:-}" ]; then
  token=$(curl -fsSL \
    "https://ghcr.io/token?scope=repository:kube-workspaces/charts/kube-workspaces:pull&service=ghcr.io" \
    | jq -r '.token')
  # Newest published version that is not the one we are about to install, sorted
  # by semver rather than lexically (so 0.1.10 beats 0.1.9).
  FROM_VERSION=$(curl -fsSL -H "Authorization: Bearer ${token}" \
    "https://ghcr.io/v2/kube-workspaces/charts/kube-workspaces/tags/list" \
    | jq -r '.tags[]' \
    | grep -vx "$LOCAL_VERSION" \
    | sort -t. -k1,1n -k2,2n -k3,3n \
    | tail -1)
fi

if [ -z "$FROM_VERSION" ]; then
  die "could not determine a published version to upgrade from"
fi

info "upgrading from published ${FROM_VERSION} -> local ${LOCAL_VERSION}"
if [ "$FROM_VERSION" = "$LOCAL_VERSION" ]; then
  warn "local chart version matches the published one; this tests a no-op upgrade"
  warn "bump version in helm/kube-workspaces/Chart.yaml to test a real upgrade"
fi

endgroup

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------

if [ -z "${SKIP_CLUSTER:-}" ]; then
  group "cluster: ${KIND_CLUSTER}"
  "${SCRIPT_DIR}/kind.sh" up || die "could not create kind cluster"
  endgroup
fi

# ---------------------------------------------------------------------------
# Install the old version
# ---------------------------------------------------------------------------

group "install ${FROM_VERSION}"

check "helm install ${FROM_VERSION}" \
  helm install "$HELM_RELEASE" "$CHART_REF" \
    --version "$FROM_VERSION" \
    --namespace "$KW_NAMESPACE" --create-namespace \
    --wait --timeout 5m

wait_for_crds 120s
wait_for_deployments 300s

endgroup

# ---------------------------------------------------------------------------
# Upgrade to the local chart
# ---------------------------------------------------------------------------

group "upgrade to ${LOCAL_VERSION}"

check "helm upgrade to the local chart" \
  helm upgrade "$HELM_RELEASE" helm/kube-workspaces/ \
    --namespace "$KW_NAMESPACE" \
    --wait --timeout 5m

# Helm reports success even if it left a resource behind, so confirm the release
# actually advanced and is deployed.
deployed=$(helm list -n "$KW_NAMESPACE" -o json 2>/dev/null \
  | jq -r --arg r "$HELM_RELEASE" '.[] | select(.name==$r) | .status')
check_equals "release status is deployed" "deployed" "$deployed"

chart_now=$(helm list -n "$KW_NAMESPACE" -o json 2>/dev/null \
  | jq -r --arg r "$HELM_RELEASE" '.[] | select(.name==$r) | .chart')
check_equals "release is on the local chart version" \
  "kube-workspaces-${LOCAL_VERSION}" "$chart_now"

# Two revisions minimum: the install and the upgrade.
revs=$(helm history "$HELM_RELEASE" -n "$KW_NAMESPACE" -o json 2>/dev/null | jq 'length')
if [ "${revs:-0}" -ge 2 ]; then
  pass "release has ${revs} revisions"
else
  fail "release has at least 2 revisions (got ${revs:-0})"
fi

endgroup

# ---------------------------------------------------------------------------
# The upgraded deployment must actually work
# ---------------------------------------------------------------------------

group "post-upgrade smoke"
if "${SCRIPT_DIR}/smoke.sh"; then
  pass "smoke suite after upgrade"
else
  fail "smoke suite after upgrade"
fi
endgroup

# ---------------------------------------------------------------------------
# Rollback must also work — otherwise a bad release cannot be undone
# ---------------------------------------------------------------------------

group "rollback"

check "helm rollback to ${FROM_VERSION}" \
  helm rollback "$HELM_RELEASE" 1 \
    --namespace "$KW_NAMESPACE" --wait --timeout 5m

chart_back=$(helm list -n "$KW_NAMESPACE" -o json 2>/dev/null \
  | jq -r --arg r "$HELM_RELEASE" '.[] | select(.name==$r) | .chart')
check_equals "rollback restored the previous chart version" \
  "kube-workspaces-${FROM_VERSION}" "$chart_back"

wait_for_deployments 300s

endgroup

printf '\n%supgrade %s -> %s%s\n' "$C_BOLD" "$FROM_VERSION" "$LOCAL_VERSION" "$C_OFF"
finish
