#!/usr/bin/env bash
# Layer 0: static validation. No cluster required, runs in seconds.
#
# Catches the class of bug that makes a deploy fail before anything is applied:
# unbuildable kustomizations, unrenderable Helm values combinations, manifests
# that violate the Kubernetes schema, drifted vendored CRDs, and docs that
# reference make targets which do not exist.
#
# Usage: scripts/validate.sh

SCRIPT_NAME="validate"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_tools kustomize helm kubectl awk grep

cd "$REPO_ROOT"

# Kubernetes version to validate manifests against. Keep in step with the
# kind node image used by the cluster tests.
: "${KUBECONFORM_K8S_VERSION:=1.31.0}"

# ---------------------------------------------------------------------------
# 1. Every kustomization must build
# ---------------------------------------------------------------------------

group "kustomize build"

KUSTOMIZE_DIRS=(
  kustomize/crds
  kustomize/base
  kustomize/overlays/auth
  kustomize/overlays/test
)

for d in "${KUSTOMIZE_DIRS[@]}"; do
  if out=$(kustomize build "$d" 2>&1); then
    if [ -z "$out" ]; then
      fail "kustomize build $d (rendered nothing)"
    else
      pass "kustomize build $d"
    fi
  else
    fail "kustomize build $d"
    printf '%s\n' "$out" | sed 's/^/     /' >&2
  fi
done

endgroup

# ---------------------------------------------------------------------------
# 2. Helm must render across a values matrix
# ---------------------------------------------------------------------------

group "helm template matrix"

CHART=helm/kube-workspaces

check "helm lint" helm lint "$CHART"

# name=flags pairs. Each combination must render without error.
render_case() {
  local name="$1"; shift
  local out
  if out=$(helm template kw "$CHART" -n "$KW_NAMESPACE" "$@" 2>&1); then
    if [ -z "$out" ]; then
      fail "helm template [$name] (rendered nothing)"
      return 1
    fi
    pass "helm template [$name]"
    printf '%s' "$out" > "${RENDER_DIR}/helm-${name}.yaml"
  else
    fail "helm template [$name]"
    printf '%s\n' "$out" | sed 's/^/     /' >&2
    return 1
  fi
}

RENDER_DIR="$(mktemp -d)"
trap 'rm -rf "$RENDER_DIR"' EXIT

render_case defaults
render_case auth --set auth.enabled=true
render_case auth-oidc \
  --set auth.enabled=true \
  --set auth.oidc.issuerURL=https://dex.example.com \
  --set auth.oidc.clientID=kube-workspaces \
  --set auth.oidc.clientSecret.create=true \
  --set auth.oidc.clientSecret.value=shhh
render_case auth-full \
  --set auth.enabled=true \
  --set auth.oidc.issuerURL=https://dex.example.com \
  --set auth.oidc.clientID=kube-workspaces \
  --set auth.oidc.clientSecret.create=true \
  --set auth.oidc.clientSecret.value=shhh \
  --set auth.personalNamespaces.enabled=true \
  --set 'auth.adminEmails[0]=admin@example.com'
render_case dex --set dex.enabled=true
render_case ingress --set ingress.enabled=true
render_case ingress-custom \
  --set ingress.enabled=true \
  --set ingress.className=nginx \
  --set 'ingress.hosts[0].host=kw.test.local' \
  --set 'ingress.hosts[0].paths[0].path=/' \
  --set 'ingress.hosts[0].paths[0].pathType=Prefix' \
  --set 'ingress.hosts[0].paths[0].backend.serviceName=kube-workspaces-frontend' \
  --set 'ingress.hosts[0].paths[0].backend.servicePort=80'
render_case ingress-tls \
  --set ingress.enabled=true \
  --set 'ingress.tls[0].secretName=kw-tls' \
  --set 'ingress.tls[0].hosts[0]=workspaces.local'
render_case no-namespaces \
  --set namespaces.create=false \
  --set namespaces.createReleaseNamespace=false
render_case no-images --set images=null
render_case custom-images \
  --set controller.image.tag=v1.2.3 \
  --set api.image.tag=v1.2.3 \
  --set proxy.image.tag=v1.2.3 \
  --set frontend.image.tag=v1.2.3
render_case pull-policy \
  --set controller.image.pullPolicy=IfNotPresent \
  --set api.image.pullPolicy=IfNotPresent

# Negative case: a host with no paths must be rejected at template time rather
# than producing an Ingress with `paths: null` that the API server refuses.
if helm template kw "$CHART" -n "$KW_NAMESPACE" \
    --set ingress.enabled=true \
    --set 'ingress.hosts[0].host=nopaths.local' >/dev/null 2>&1; then
  fail "helm template rejects an ingress host with no paths"
else
  pass "helm template rejects an ingress host with no paths"
fi

# The default ingress must route /proxy to the proxy service. The API serves no
# /proxy routes, so getting this wrong 404s all workspace traffic.
proxy_backend=$(helm template kw "$CHART" -n "$KW_NAMESPACE" \
  --set ingress.enabled=true 2>/dev/null \
  | yq -N 'select(.kind=="Ingress") | .spec.rules[0].http.paths[] | select(.path=="/proxy") | .backend.service.name' 2>/dev/null)
check_equals "default ingress routes /proxy to the proxy service" \
  "kube-workspaces-proxy" "$proxy_backend"

endgroup

# ---------------------------------------------------------------------------
# 3. Vendored CRDs must match the source of truth
# ---------------------------------------------------------------------------

group "CRD sync"
check "vendored Helm CRDs match kustomize/crds" make check-helm-crds
endgroup

# ---------------------------------------------------------------------------
# 3b. Helm template unit tests
# ---------------------------------------------------------------------------

group "helm unittest"

if helm plugin list 2>/dev/null | grep -q '^unittest'; then
  # --strict so a malformed suite is an error rather than being skipped.
  if out=$(helm unittest --strict "$CHART" 2>&1); then
    # Surface the tally rather than the whole log.
    tally=$(printf '%s\n' "$out" | grep -E '^Tests:' | head -1)
    pass "helm unittest (${tally:-passed})"
  else
    fail "helm unittest"
    printf '%s\n' "$out" | sed 's/^/     /' >&2
  fi
else
  warn "helm-unittest plugin not installed — skipping template unit tests"
  warn "install: helm plugin install https://github.com/helm-unittest/helm-unittest --verify=false"
fi

endgroup

# ---------------------------------------------------------------------------
# 4. Schema validation with kubeconform
# ---------------------------------------------------------------------------

group "kubeconform"

if ! command -v kubeconform >/dev/null 2>&1; then
  warn "kubeconform not on PATH — skipping schema validation."
  warn "install: go install github.com/yannh/kubeconform/cmd/kubeconform@latest"
else
  # Extract JSON schemas from our own CRDs so custom kinds validate too,
  # rather than being skipped.
  SCHEMA_DIR="${RENDER_DIR}/schemas"
  mkdir -p "$SCHEMA_DIR"
  if scripts/crd-to-schema.sh "$SCHEMA_DIR" >/dev/null 2>&1; then
    info "extracted $(find "$SCHEMA_DIR" -name '*.json' | wc -l | tr -d ' ') CRD schemas"
  else
    warn "CRD schema extraction failed; custom resources will be skipped"
  fi

  kc() {
    kubeconform \
      -kubernetes-version "$KUBECONFORM_K8S_VERSION" \
      -schema-location default \
      -schema-location "${SCHEMA_DIR}/{{.ResourceKind}}.json" \
      -strict -summary "$@"
  }

  # Rendered kustomize output.
  for d in kustomize/base kustomize/overlays/auth kustomize/overlays/test; do
    if out=$(kustomize build "$d" | kc - 2>&1); then
      pass "kubeconform $d"
    else
      fail "kubeconform $d"
      printf '%s\n' "$out" | sed 's/^/     /' >&2
    fi
  done

  # Rendered Helm output for every case above.
  for f in "$RENDER_DIR"/helm-*.yaml; do
    [ -e "$f" ] || continue
    name=$(basename "$f" .yaml)
    if out=$(kc "$f" 2>&1); then
      pass "kubeconform $name"
    else
      fail "kubeconform $name"
      printf '%s\n' "$out" | sed 's/^/     /' >&2
    fi
  done

  # The CRD definitions themselves are checked structurally below rather than
  # with kubeconform: the upstream schema set ships the CustomResourceDefinition
  # sub-schemas (…names, …status, …condition) but not the top-level kind, so
  # kubeconform can only ever report "could not find schema".
fi

endgroup

# ---------------------------------------------------------------------------
# 4b. CRD structure
# ---------------------------------------------------------------------------

group "CRD structure"

crd_stream="${RENDER_DIR}/crds.yaml"
kustomize build kustomize/crds > "$crd_stream" 2>/dev/null

crd_count=$(yq -N 'select(.kind=="CustomResourceDefinition") | .metadata.name' "$crd_stream" | wc -l | tr -d ' ')
check_equals "kustomize/crds renders 6 CRDs" "6" "$crd_count"

# Every CRD must be in our group, have a schema, and a status subresource —
# a CRD without a schema accepts anything, silently.
for name in $(yq -N 'select(.kind=="CustomResourceDefinition") | .metadata.name' "$crd_stream"); do
  grp="${name#*.}"
  check_equals "$name is in the kubeworkspaces.io group" "kubeworkspaces.io" "$grp"
done

no_schema=$(yq -N 'select(.kind=="CustomResourceDefinition") | select(.spec.versions[0].schema.openAPIV3Schema == null) | .metadata.name' "$crd_stream" | wc -l | tr -d ' ')
check_equals "all CRDs define an openAPIV3Schema" "0" "$no_schema"

# The Workspace CRD is the one that forces server-side apply. Assert it is
# still oversized so the requirement stays documented and obvious, and warn if
# it unexpectedly shrinks below the limit.
ws_bytes=$(wc -c < kustomize/crds/crd.yaml | tr -d ' ')
if [ "$ws_bytes" -gt 262144 ]; then
  pass "Workspace CRD exceeds the 256 KiB client-side apply limit (${ws_bytes} bytes) — server-side apply required"
else
  warn "Workspace CRD is now ${ws_bytes} bytes, under the 256 KiB limit; the server-side apply requirement may no longer hold"
  pass "Workspace CRD size recorded (${ws_bytes} bytes)"
fi

endgroup

# ---------------------------------------------------------------------------
# 5. Static manifests must be parseable and correctly scoped
# ---------------------------------------------------------------------------

group "static manifests"

# NOTE: deliberately not using `kubectl create --dry-run=client` here. Despite
# the name it still reaches out to the cluster for the OpenAPI schema, so it
# fails (or worse, silently validates against the wrong cluster) whenever a
# kubecontext is configured. Layer 0 must be entirely offline: parse with yq and
# validate schemas with kubeconform instead.

for f in images.yaml poddefaults.yaml; do
  if out=$(yq -e 'true' "$f" 2>&1 >/dev/null); then
    pass "$f is valid YAML"
  else
    fail "$f is valid YAML"
    printf '%s\n' "$out" | sed 's/^/     /' >&2
  fi
done

if command -v kubeconform >/dev/null 2>&1; then
  for f in images.yaml poddefaults.yaml; do
    if out=$(kc "$f" 2>&1); then
      pass "kubeconform $f"
    else
      fail "kubeconform $f"
      printf '%s\n' "$out" | sed 's/^/     /' >&2
    fi
  done
fi

# Every document must carry apiVersion and kind.
# Emit one boolean per document and assert none are false. Note: chaining two
# `select` filters does not work here — yq applies the second across the whole
# stream rather than the filtered subset, which silently reports every document
# as bad.
for f in images.yaml poddefaults.yaml; do
  bad=$(yq -N '(.apiVersion != null and .kind != null)' "$f" 2>/dev/null \
    | grep -c '^false$' || true)
  if [ "$bad" = "0" ]; then
    pass "$f documents all have apiVersion and kind"
  else
    fail "$f documents all have apiVersion and kind ($bad missing)"
  fi
done

# Image is cluster-scoped; a stray namespace field is silently ignored by the
# API server but signals a copy-paste error.
if grep -nE '^\s+namespace:' images.yaml >/dev/null 2>&1; then
  fail "images.yaml has no namespace fields (Image is cluster-scoped)"
  grep -nE '^\s+namespace:' images.yaml | sed 's/^/     /' >&2
else
  pass "images.yaml has no namespace fields (Image is cluster-scoped)"
fi

# Every Image CR name must be RFC 1123 — a past bug shipped invalid names.
bad_names=$(yq -N '.metadata.name' images.yaml 2>/dev/null \
  | grep -vE '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$' || true)
if [ -n "$bad_names" ]; then
  fail "all Image CR names are RFC 1123 compliant"
  printf '%s\n' "$bad_names" | sed 's/^/     /' >&2
else
  pass "all Image CR names are RFC 1123 compliant"
fi

endgroup

# ---------------------------------------------------------------------------
# 6. ArgoCD Application manifests
# ---------------------------------------------------------------------------

group "argocd manifests"

for f in argocd/*.yaml; do
  if out=$(yq -e 'true' "$f" 2>&1 >/dev/null); then
    pass "$f is valid YAML"
  else
    fail "$f is valid YAML"
    printf '%s\n' "$out" | sed 's/^/     /' >&2
  fi

  # An Application pointing at the wrong repo or a missing path is a silent
  # no-op in Argo, so assert the essentials.
  kindv=$(yq -N '.kind' "$f")
  check_equals "$f kind is Application" "Application" "$kindv"

  repo=$(yq -N '.spec.source.repoURL' "$f")
  case "$repo" in
    *kube-workspaces/deploy*) pass "$f repoURL points at this repo" ;;
    *) fail "$f repoURL points at this repo (got '$repo')" ;;
  esac

  # The referenced path must exist in the working tree.
  srcpath=$(yq -N '.spec.source.path' "$f")
  if [ -n "$srcpath" ] && [ "$srcpath" != "null" ] && [ -d "$srcpath" ]; then
    pass "$f source.path '$srcpath' exists"
  else
    fail "$f source.path '$srcpath' exists"
  fi
done

# The CRD Application must not use ServerSideApply, and the base Application
# must — these are load-bearing given the 658 KiB Workspace CRD.
if grep -q 'ServerSideApply=true' argocd/application.yaml; then
  pass "argocd/application.yaml uses ServerSideApply"
else
  fail "argocd/application.yaml uses ServerSideApply"
fi

if grep -qE 'Replace=true|ServerSideApply=true' argocd/application-crds.yaml; then
  pass "argocd/application-crds.yaml handles large CRDs"
else
  fail "argocd/application-crds.yaml handles large CRDs"
fi

endgroup

# ---------------------------------------------------------------------------
# 6b. ServiceAccounts must be explicit
# ---------------------------------------------------------------------------

group "service accounts"

# No workload should silently inherit the 'default' ServiceAccount: it makes the
# effective permissions invisible and, for components that need no API access at
# all, needlessly mounts a usable token.
#
# Checked for both render paths, since they name SAs differently (kustomize uses
# kube-workspaces-controller, Helm uses the release fullname).
check_sa_explicit() {
  local label="$1" stream="$2"
  local bad
  bad=$(yq -N 'select(.kind=="Deployment")
    | select(.spec.template.spec.serviceAccountName == null)
    | .metadata.name' "$stream" 2>/dev/null)
  if [ -z "$bad" ]; then
    pass "${label}: every Deployment sets serviceAccountName"
  else
    fail "${label}: every Deployment sets serviceAccountName"
    printf '%s\n' "$bad" | sed 's/^/     inherits default: /' >&2
  fi

  # Every referenced SA must actually be defined in the same render.
  local refs defined missing
  refs=$(yq -N 'select(.kind=="Deployment") | .spec.template.spec.serviceAccountName' "$stream" 2>/dev/null | grep -v '^null$' | sort -u)
  defined=$(yq -N 'select(.kind=="ServiceAccount") | .metadata.name' "$stream" 2>/dev/null | sort -u)
  missing=""
  while read -r sa; do
    [ -n "$sa" ] || continue
    printf '%s\n' "$defined" | grep -qx "$sa" || missing="${missing} ${sa}"
  done <<< "$refs"
  if [ -z "$missing" ]; then
    pass "${label}: all referenced ServiceAccounts are defined"
  else
    fail "${label}: all referenced ServiceAccounts are defined (missing:${missing})"
  fi

  # The frontend has no Kubernetes client, so it must not mount a token.
  local automount
  automount=$(yq -N 'select(.kind=="Deployment")
    | select(.metadata.name | test("frontend"))
    | .spec.template.spec.automountServiceAccountToken' "$stream" 2>/dev/null)
  check_equals "${label}: frontend does not mount a SA token" "false" "$automount"
}

k_stream="${RENDER_DIR}/kustomize-base.yaml"
kustomize build kustomize/base > "$k_stream" 2>/dev/null
check_sa_explicit "kustomize" "$k_stream"
check_sa_explicit "helm" "${RENDER_DIR}/helm-defaults.yaml"

# The two render paths must grant identical effective permissions. They write
# their rules differently and use different SA names, so a textual diff says
# nothing — flatten to {group/resource: verbs} and compare that. A divergence
# here means one install method is more privileged than the other.
if command -v python3 >/dev/null 2>&1; then
  if out=$(scripts/compare-rbac.py "$k_stream" "${RENDER_DIR}/helm-defaults.yaml" 2>&1); then
    pass "kustomize and helm grant equivalent RBAC"
  else
    fail "kustomize and helm grant equivalent RBAC"
    printf '%s\n' "$out" | sed 's/^/     /' >&2
  fi
else
  warn "python3 not available — skipping the RBAC equivalence check"
fi

endgroup

# ---------------------------------------------------------------------------
# 7. Docs must not reference make targets that do not exist
# ---------------------------------------------------------------------------

group "docs consistency"

defined_targets=$(grep -oE '^[a-zA-Z][a-zA-Z0-9_-]*:' Makefile | tr -d ':' | sort -u)

# Docs in this repo also describe commands run in the *component* repos, whose
# Makefiles we cannot see. Those references are exempted by listing them here,
# so a genuinely broken reference to one of our own targets still fails.
#
# Keep this list minimal — every entry is a target in another repo.
EXTERNAL_TARGETS="build generate lint manifests test run-proxy run-controller run-api run-frontend"

# Only consider `make <target>` inside backticks — bare prose ("make sure your
# DNS...") is not a command reference.
referenced=$(grep -ohE '`[^`]*`' README.md CONTRIBUTING.md docs/*.md 2>/dev/null \
  | grep -oE '\bmake [a-z][a-z0-9-]+' \
  | awk '{print $2}' | sort -u)

missing=""
while read -r t; do
  [ -n "$t" ] || continue
  # Ours?
  printf '%s\n' "$defined_targets" | grep -qx "$t" && continue
  # Known to belong to another repo?
  printf '%s\n' $EXTERNAL_TARGETS | grep -qx "$t" && continue
  missing="${missing} ${t}"
done <<< "$referenced"

if [ -n "$missing" ]; then
  fail "docs reference only existing make targets (missing:${missing})"
else
  pass "docs reference only existing make targets"
fi

# Guard the exemption list against rot: if a name in EXTERNAL_TARGETS is now
# defined locally, it should be removed from the list.
stale=""
for t in $EXTERNAL_TARGETS; do
  if printf '%s\n' "$defined_targets" | grep -qx "$t"; then
    stale="${stale} ${t}"
  fi
done
if [ -n "$stale" ]; then
  fail "EXTERNAL_TARGETS has entries now defined locally (remove:${stale})"
else
  pass "EXTERNAL_TARGETS contains no locally-defined targets"
fi

# Every target in .PHONY should exist and vice versa.
phony=$(make -p 2>/dev/null | grep -m1 '^\.PHONY:' | cut -d: -f2- | tr ' ' '\n' | grep -v '^$' | sort -u)
not_phony=$(comm -23 <(printf '%s\n' "$defined_targets") <(printf '%s\n' "$phony"))
if [ -n "$not_phony" ]; then
  fail "all Makefile targets are declared .PHONY (missing: $(echo "$not_phony" | tr '\n' ' '))"
else
  pass "all Makefile targets are declared .PHONY"
fi

# A kustomize directory must be applied with -k. With -f, kubectl treats
# kustomization.yaml as a manifest and fails with 'no matches for kind
# "Kustomization"' — after applying everything else, so the mistake is easy to
# miss until a strict caller checks the exit code.
bad_apply=$(grep -rnE 'kubectl apply [^|]*-f [^ ]*kustomize/[a-z]+/?( |$)' \
  Makefile scripts/ .github/ README.md docs/ 2>/dev/null || true)
if [ -n "$bad_apply" ]; then
  fail "kustomize directories are applied with -k, not -f"
  printf '%s\n' "$bad_apply" | sed 's/^/     /' >&2
else
  pass "kustomize directories are applied with -k, not -f"
fi

# The release-notes categories only give a consistent reading experience if every
# repo uses the same ones. Skips when the sibling checkouts are absent (as in CI
# for this repo), so it is advisory there and enforcing locally.
if out=$(scripts/check-release-config.sh 2>&1); then
  case "$out" in
    *"skipping"*) info "release.yml consistency: ${out}" ;;
    *)            pass "release.yml is consistent across sibling repos" ;;
  esac
else
  fail "release.yml is consistent across sibling repos"
  printf '%s\n' "$out" | sed 's/^/     /' >&2
fi

endgroup

finish
