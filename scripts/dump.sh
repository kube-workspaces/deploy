#!/usr/bin/env bash
# Dump diagnostics for the kube-workspaces deployment in the current kubectl
# context. Run this after a failed deploy or smoke test.
#
# Usage: scripts/dump.sh [namespace...]

SCRIPT_NAME="dump"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/k8s.sh
source "${SCRIPT_DIR}/lib/k8s.sh"

require_tools kubectl

echo "context:   $(kubectl config current-context 2>/dev/null || echo unknown)"
echo "namespace: ${KW_NAMESPACE}"
echo

group "cluster"
kubectl version --short 2>/dev/null || kubectl version 2>&1 | head -4
kubectl get nodes -o wide 2>&1
endgroup

group "CRDs"
kubectl get crd -o custom-columns=\
'NAME:.metadata.name,ESTABLISHED:.status.conditions[?(@.type=="Established")].status' \
  2>&1 | grep -E 'NAME|kubeworkspaces' || echo "  no kubeworkspaces.io CRDs found"
endgroup

group "custom resources"
for kind in images users authconfigs platformconfigs; do
  echo "--- ${kind} (cluster-scoped) ---"
  kubectl get "${kind}.kubeworkspaces.io" 2>&1 | sed 's/^/  /' || true
done
echo "--- workspaces (all namespaces) ---"
kubectl get workspaces.kubeworkspaces.io -A 2>&1 | sed 's/^/  /' || true
endgroup

# The heavy lifting lives in the shared library so the smoke/e2e traps and this
# script cannot drift apart.
dump_diagnostics "$@"

group "helm"
if command -v helm >/dev/null 2>&1; then
  helm list -A 2>&1 | sed 's/^/  /' || true
else
  echo "  helm not installed"
fi
endgroup

echo
info "diagnostics complete"
