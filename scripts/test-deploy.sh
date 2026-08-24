#!/usr/bin/env bash
# Layer 1: create a throwaway kind cluster, deploy kube-workspaces by a
# specific method, smoke-test it, then tear the cluster down.
#
# Usage: scripts/test-deploy.sh <method>
#
# Methods:
#   kustomize   kustomize/crds + kustomize/base  (the documented default path)
#   helm        the local chart in helm/kube-workspaces/
#   helm-oci    the published chart from ghcr.io  (tests the artifact users get)
#   auth        kustomize with the auth overlay
#   argocd      install Argo CD, then both Application manifests
#
# Env:
#   KIND_CLUSTER      cluster name (default derived from the method)
#   KIND_KEEP         set to leave the cluster running after the test
#   SKIP_CLUSTER      set to use the current context instead of creating a
#                     cluster (dangerous — only for local iteration)
#   CHART_VERSION     for helm-oci; defaults to the local Chart.yaml version

SCRIPT_NAME="test-deploy"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/k8s.sh
source "${SCRIPT_DIR}/lib/k8s.sh"

METHOD="${1:-}"
case "$METHOD" in
  kustomize|helm|helm-oci|auth|argocd) ;;
  *)
    echo "usage: $0 {kustomize|helm|helm-oci|auth|argocd}" >&2
    exit 2
    ;;
esac

require_tools kubectl kustomize curl
[ "$METHOD" = "kustomize" ] || [ "$METHOD" = "auth" ] || require_tools helm

cd "$REPO_ROOT"

# Give each method its own cluster name so parallel runs do not collide.
: "${KIND_CLUSTER:=kw-test-${METHOD}}"
export KIND_CLUSTER

HELM_RELEASE=kube-workspaces
ARGOCD_NAMESPACE=argocd

# ---------------------------------------------------------------------------
# Cluster lifecycle
# ---------------------------------------------------------------------------

cleanup() {
  local rc=$?
  pf_stop_all
  if [ "$rc" -ne 0 ] || [ "${CHECKS_FAILED:-0}" -gt 0 ]; then
    warn "deployment test failed — dumping diagnostics"
    dump_diagnostics || true
    if [ "$METHOD" = "argocd" ]; then
      dump_diagnostics "$ARGOCD_NAMESPACE" || true
    fi
  fi
  if [ -z "${SKIP_CLUSTER:-}" ]; then
    "${SCRIPT_DIR}/kind.sh" down || true
  fi
  [ -n "${oci_conf:-}" ] && rm -rf "$oci_conf"
  return $rc
}
trap cleanup EXIT

if [ -z "${SKIP_CLUSTER:-}" ]; then
  group "cluster: ${KIND_CLUSTER}"
  "${SCRIPT_DIR}/kind.sh" up || die "could not create kind cluster"
  endgroup
else
  warn "SKIP_CLUSTER set — using current context $(kubectl config current-context)"
fi

# ---------------------------------------------------------------------------
# Deploy
# ---------------------------------------------------------------------------

# Image CRs are not part of kustomize/base, so the catalog has to be applied
# separately for the Kustomize paths. The Helm chart renders its own.
apply_images() {
  info "applying Image CRs from images.yaml"
  kubectl apply --server-side -f images.yaml >/dev/null \
    || fail "apply images.yaml"
}

deploy_kustomize_common() {
  local overlay="$1"
  # CRDs first, and always server-side: the Workspace CRD is ~658 KiB.
  check "apply CRDs (server-side)" \
    kubectl apply --server-side -k kustomize/crds/
  wait_for_crds 120s
  check "apply ${overlay} (server-side)" \
    kubectl apply --server-side -k "$overlay"
  apply_images
}

case "$METHOD" in
  kustomize)
    group "deploy: kustomize"
    # Use the test overlay: base hardcodes imagePullPolicy: Always and an
    # Ingress pinned to traefik, neither of which suits a kind cluster.
    deploy_kustomize_common kustomize/overlays/test/
    endgroup
    ;;

  auth)
    group "deploy: kustomize + auth overlay"
    deploy_kustomize_common kustomize/overlays/auth/
    # The overlay ships an AuthConfig with a placeholder OIDC issuer that is
    # unreachable, so the controller will mark it not-ready. That is expected:
    # this test proves the manifests apply and the components still start.
    check "AuthConfig CR was created" \
      kubectl get authconfig default
    endgroup
    ;;

  helm)
    group "deploy: helm (local chart)"
    # The chart vendors CRDs in crds/, which Helm installs itself. It cannot
    # use server-side apply for those, but Helm creates rather than patches on
    # a fresh cluster, so the size limit does not bite.
    check "helm install (local chart)" \
      helm install "$HELM_RELEASE" helm/kube-workspaces/ \
        --namespace "$KW_NAMESPACE" --create-namespace \
        --set controller.image.pullPolicy=IfNotPresent \
        --set api.image.pullPolicy=IfNotPresent \
        --set proxy.image.pullPolicy=IfNotPresent \
        --set frontend.image.pullPolicy=IfNotPresent \
        --wait --timeout 5m
    wait_for_crds 120s
    endgroup
    ;;

  helm-oci)
    : "${CHART_VERSION:=$(awk '/^version:/{print $2; exit}' helm/kube-workspaces/Chart.yaml)}"
    group "deploy: helm (published OCI chart ${CHART_VERSION})"

    # The published chart is public, so pull anonymously. Ambient credentials
    # are actively harmful here: a stale or revoked ghcr.io entry in
    # ~/.docker/config.json makes the registry return 403 instead of falling
    # back to an anonymous token. Point DOCKER_CONFIG at a throwaway directory
    # so the test behaves the same for every developer and in CI.
    oci_conf="$(mktemp -d)"
    printf '{}' > "${oci_conf}/config.json"
    export DOCKER_CONFIG="$oci_conf"
    info "using an empty DOCKER_CONFIG for anonymous pulls (${oci_conf})"

    # This is the exact artifact the website tells people to install. If the
    # version under test is not published yet, fall back to the newest one.
    if ! helm show chart "oci://ghcr.io/kube-workspaces/charts/kube-workspaces" \
        --version "$CHART_VERSION" >/dev/null 2>&1; then
      warn "chart ${CHART_VERSION} is not published; using the latest published version"
      CHART_VERSION=""
    fi
    ver_args=()
    [ -n "$CHART_VERSION" ] && ver_args=(--version "$CHART_VERSION")
    check "helm install (OCI chart)" \
      helm install "$HELM_RELEASE" \
        oci://ghcr.io/kube-workspaces/charts/kube-workspaces \
        "${ver_args[@]}" \
        --namespace "$KW_NAMESPACE" --create-namespace \
        --wait --timeout 5m
    wait_for_crds 120s
    endgroup
    ;;

  argocd)
    group "deploy: argocd"
    require_tools jq
    kubectl create namespace "$ARGOCD_NAMESPACE" >/dev/null 2>&1 || true
    info "installing Argo CD (this takes a couple of minutes)"
    check "install Argo CD" \
      kubectl apply -n "$ARGOCD_NAMESPACE" --server-side -f \
        https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

    info "waiting for the Argo CD application controller and repo server"
    for d in argocd-repo-server argocd-applicationset-controller argocd-server; do
      kubectl rollout status "deployment/$d" -n "$ARGOCD_NAMESPACE" \
        --timeout=300s >/dev/null 2>&1 \
        || warn "$d did not report ready in time"
    done
    kubectl rollout status statefulset/argocd-application-controller \
      -n "$ARGOCD_NAMESPACE" --timeout=300s >/dev/null 2>&1 \
      || warn "argocd-application-controller did not report ready in time"

    # The committed Applications track `main`. When testing a branch we must
    # override targetRevision, or Argo would sync main and the test would say
    # nothing about this commit.
    #
    # IMPORTANT: Argo CD clones from the remote, so this method can only ever
    # test *pushed* commits. Uncommitted working-tree changes are invisible to
    # it — unlike every other method here, which applies local files. A local
    # run therefore validates HEAD as pushed, not what you are editing.
    rev="${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo main)}"
    info "pointing Applications at revision ${rev}"
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
      warn "working tree has uncommitted changes — Argo CD syncs from the remote,"
      warn "so those changes are NOT under test in this run"
    fi

    for app in argocd/application-crds.yaml argocd/application.yaml; do
      # yq edit in a temp copy; never mutate the tracked file.
      tmp="$(mktemp)"
      yq ".spec.source.targetRevision = \"${rev}\"" "$app" > "$tmp"
      check "apply $(basename "$app")" kubectl apply -f "$tmp"
      rm -f "$tmp"
    done

    # CRDs Application must sync before the components one can succeed.
    #
    # The components Application syncs kustomize/base, which includes an Ingress
    # pinned to ingressClassName: traefik. A default kind cluster has no ingress
    # controller, so that Ingress never receives a load-balancer address and Argo
    # reports the Application as Progressing forever — even though all four
    # Deployments are Healthy. Treat Synced + (Healthy | Progressing-with-only-
    # the-Ingress-outstanding) as success, and let the smoke suite be the real
    # arbiter of whether the workloads came up.
    info "waiting for Applications to sync"
    for app in kube-workspaces-crds kube-workspaces; do
      ok=0
      for _ in $(seq 1 90); do
        health=$(kubectl get application "$app" -n "$ARGOCD_NAMESPACE" \
          -o jsonpath='{.status.health.status}' 2>/dev/null || true)
        sync=$(kubectl get application "$app" -n "$ARGOCD_NAMESPACE" \
          -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
        if [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ]; then
          ok=1; break
        fi
        # Degraded will not recover on its own — fail fast rather than waiting.
        if [ "$health" = "Degraded" ]; then
          break
        fi
        sleep 5
      done

      if [ "$ok" = "1" ]; then
        pass "Application ${app} is Synced/Healthy"
        continue
      fi

      # Not Healthy. Determine whether the only unhealthy resource is the
      # Ingress, which is expected on a cluster with no ingress controller.
      unhealthy=$(kubectl get application "$app" -n "$ARGOCD_NAMESPACE" \
        -o jsonpath='{range .status.resources[?(@.health.status)]}{.kind}/{.name}={.health.status}{"\n"}{end}' \
        2>/dev/null | grep -v '=Healthy$' || true)
      non_ingress=$(printf '%s\n' "$unhealthy" | grep -v '^Ingress/' | grep -v '^$' || true)

      if [ "$sync" = "Synced" ] && [ -z "$non_ingress" ] && [ -n "$unhealthy" ]; then
        pass "Application ${app} is Synced (only the Ingress is not Healthy — expected without an ingress controller)"
      else
        fail "Application ${app} is Synced/Healthy (sync=${sync:-?} health=${health:-?})"
        [ -n "$unhealthy" ] && printf '%s\n' "$unhealthy" | sed 's/^/     unhealthy: /' >&2
        kubectl get application "$app" -n "$ARGOCD_NAMESPACE" \
          -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}' \
          2>/dev/null | sed 's/^/     /' >&2 || true
      fi
    done
    apply_images
    endgroup
    ;;
esac

# ---------------------------------------------------------------------------
# Smoke test
# ---------------------------------------------------------------------------

group "smoke"
# Run the shared smoke script in-process so its tallies merge with ours.
# It re-sources the libraries, which is harmless.
#
# Two methods deploy something other than the local working tree, so tolerate
# hardening that has not shipped there yet rather than reporting a false failure:
#   helm-oci  installs an already-released chart
#   argocd    syncs from the git remote, i.e. the last pushed commit
case "$METHOD" in
  helm-oci|argocd) export KW_LENIENT_SA=1 ;;
esac
if "${SCRIPT_DIR}/smoke.sh"; then
  pass "smoke suite (${METHOD})"
else
  fail "smoke suite (${METHOD})"
fi
endgroup

printf '\n%s%s deployment via %s%s\n' "$C_BOLD" "kube-workspaces" "$METHOD" "$C_OFF"
finish
