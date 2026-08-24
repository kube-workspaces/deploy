#!/usr/bin/env bash
# Manage the local kind cluster used by the deployment tests.
#
# Usage:
#   scripts/kind.sh up      create the cluster (no-op if it exists)
#   scripts/kind.sh down    delete the cluster
#   scripts/kind.sh status   report whether it exists
#
# Env:
#   KIND_CLUSTER      cluster name (default kube-workspaces-test)
#   KIND_NODE_IMAGE   pinned node image
#   KIND_KEEP         if set, `down` is a no-op (useful for debugging CI)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

: "${KIND_CLUSTER:=kube-workspaces-test}"
: "${KIND_NODE_IMAGE:=kindest/node:v1.31.0}"

require_tools kind kubectl

cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER"
}

cmd_up() {
  if cluster_exists; then
    info "kind cluster '${KIND_CLUSTER}' already exists — reusing it"
  else
    info "creating kind cluster '${KIND_CLUSTER}' (${KIND_NODE_IMAGE})"
    # --wait blocks until the control plane is Ready, so callers do not have to
    # poll before applying manifests.
    kind create cluster \
      --name "$KIND_CLUSTER" \
      --image "$KIND_NODE_IMAGE" \
      --wait 120s \
      || die "kind create cluster failed"
  fi

  # Always (re)point kubectl at this cluster, so a subsequent apply cannot
  # accidentally hit whatever context was previously active.
  kubectl config use-context "kind-${KIND_CLUSTER}" >/dev/null \
    || die "could not switch to context kind-${KIND_CLUSTER}"

  info "context: $(kubectl config current-context)"
  kubectl get nodes -o wide
}

cmd_down() {
  if [ -n "${KIND_KEEP:-}" ]; then
    warn "KIND_KEEP is set — leaving cluster '${KIND_CLUSTER}' running"
    return 0
  fi
  if cluster_exists; then
    info "deleting kind cluster '${KIND_CLUSTER}'"
    kind delete cluster --name "$KIND_CLUSTER"
  else
    info "kind cluster '${KIND_CLUSTER}' does not exist"
  fi
}

cmd_status() {
  if cluster_exists; then
    echo "kind cluster '${KIND_CLUSTER}' exists"
    kubectl --context "kind-${KIND_CLUSTER}" get nodes 2>/dev/null || true
  else
    echo "kind cluster '${KIND_CLUSTER}' does not exist"
    return 1
  fi
}

case "${1:-}" in
  up)     cmd_up ;;
  down)   cmd_down ;;
  status) cmd_status ;;
  *)
    echo "usage: $0 {up|down|status}" >&2
    exit 2
    ;;
esac
