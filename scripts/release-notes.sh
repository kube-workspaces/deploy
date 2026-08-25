#!/usr/bin/env bash
# Classify the changes since the last tag and emit a release-notes preamble.
#
# The point is to answer, up front, the question a reader actually has: does this
# release change how the software behaves, or is it a version alignment?
#
# The five repositories are released together and the chart's appVersion pins all
# four images to one number, so a component with no functional changes still gets
# tagged. Saying so explicitly is much better than leaving someone to infer it
# from a list of CI commits.
#
# Usage: scripts/release-notes.sh [--repo NAME] [--from TAG] [--to REF]
# Output: markdown on stdout.

set -uo pipefail

REPO_NAME=""
FROM=""
TO="HEAD"

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO_NAME="$2"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    --to)   TO="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$REPO_NAME" ] || REPO_NAME="$(basename "$(git rev-parse --show-toplevel)")"

if [ -z "$FROM" ]; then
  FROM=$(git describe --tags --abbrev=0 "${TO}^" 2>/dev/null \
      || git describe --tags --abbrev=0 2>/dev/null || true)
fi

if [ -z "$FROM" ]; then
  echo "No previous tag found — this appears to be the first release."
  exit 0
fi

range="${FROM}..${TO}"
subjects=$(git log "$range" --no-merges --format='%s' 2>/dev/null)

if [ -z "$subjects" ]; then
  echo "No commits since ${FROM}."
  exit 0
fi

# ---------------------------------------------------------------------------
# Classify by conventional-commit prefix.
#
# Deliberately conservative: a commit only counts as functional if it is
# explicitly feat/fix/perf/refactor/revert, or carries a `!` breaking marker.
# Anything unrecognised counts as functional too — better to under-claim
# "no functional changes" than to over-claim it.
# ---------------------------------------------------------------------------

count_matching() { printf '%s\n' "$subjects" | grep -cE "$1" || true; }

n_total=$(printf '%s\n' "$subjects" | grep -c . || true)
n_breaking=$(count_matching '^[a-z]+(\([^)]*\))?!:')
n_feat=$(count_matching '^feat(\([^)]*\))?!?:')
n_fix=$(count_matching '^fix(\([^)]*\))?!?:')
n_perf=$(count_matching '^perf(\([^)]*\))?!?:')
n_refactor=$(count_matching '^(refactor|revert)(\([^)]*\))?!?:')
n_sec=$(count_matching '^security(\([^)]*\))?!?:')

# Non-functional prefixes.
n_ci=$(count_matching '^(ci|build)(\([^)]*\))?:')
n_docs=$(count_matching '^docs(\([^)]*\))?:')
n_chore=$(count_matching '^(chore|style|test)(\([^)]*\))?:')

n_nonfunctional=$((n_ci + n_docs + n_chore))
n_functional=$((n_feat + n_fix + n_perf + n_refactor + n_sec))
n_unclassified=$((n_total - n_functional - n_nonfunctional))

# ---------------------------------------------------------------------------
# Preamble
# ---------------------------------------------------------------------------

if [ "$n_breaking" -gt 0 ]; then
  cat <<EOF
> [!WARNING]
> **This release contains breaking changes.** See the breaking changes section
> below before upgrading.

EOF
fi

if [ "$n_functional" -eq 0 ] && [ "$n_unclassified" -eq 0 ]; then
  cat <<EOF
> [!NOTE]
> **No functional changes in this release.**
>
> The ${n_total} commit(s) since \`${FROM}\` are CI, tooling and documentation
> only. This version exists to keep the kube-workspaces components aligned: the
> Helm chart's \`appVersion\` pins all four images to a single number, so a shared
> version is materially easier to support than four drifting ones.
>
> Upgrading is safe and changes no behaviour.

EOF
else
  echo "## Summary"
  echo
  printf '%s commit(s) since `%s`' "$n_total" "$FROM"
  parts=""
  [ "$n_breaking" -gt 0 ]  && parts="${parts}, ${n_breaking} breaking"
  [ "$n_feat" -gt 0 ]      && parts="${parts}, ${n_feat} feature(s)"
  [ "$n_fix" -gt 0 ]       && parts="${parts}, ${n_fix} fix(es)"
  [ "$n_sec" -gt 0 ]       && parts="${parts}, ${n_sec} security"
  [ "$n_perf" -gt 0 ]      && parts="${parts}, ${n_perf} performance"
  [ "$n_nonfunctional" -gt 0 ] && parts="${parts}, ${n_nonfunctional} CI/docs"
  # Surface unclassified commits rather than hiding them: they are the reason a
  # release is not reported as non-functional, so the reader should see the count.
  [ "$n_unclassified" -gt 0 ] && parts="${parts}, ${n_unclassified} unclassified"
  [ -n "$parts" ] && printf ' — %s' "${parts#, }"
  printf '.\n'
  if [ "$n_functional" -eq 0 ] && [ "$n_unclassified" -gt 0 ]; then
    printf '\nNo commit is tagged as a feature or fix, but %s commit(s) use no\n' "$n_unclassified"
    printf 'conventional-commit prefix, so this release is not being claimed as\n'
    printf 'functionally unchanged. Check the list below.\n'
  fi
  printf '\n'
fi

# ---------------------------------------------------------------------------
# Upgrade instructions, tailored per repo
# ---------------------------------------------------------------------------

VERSION="${TO#refs/tags/}"
case "$REPO_NAME" in
  deploy)
    cat <<EOF
## Upgrading

\`\`\`sh
helm upgrade kube-workspaces \\
  oci://ghcr.io/kube-workspaces/charts/kube-workspaces \\
  --version ${VERSION#v} --namespace kube-workspaces-system
\`\`\`

Or with Kustomize:

\`\`\`sh
kubectl apply --server-side -k https://github.com/kube-workspaces/deploy/kustomize/crds
kubectl apply --server-side -k https://github.com/kube-workspaces/deploy/kustomize/base
\`\`\`

EOF
    ;;
  *)
    cat <<EOF
## Upgrading

This component is deployed as part of the platform:

\`\`\`sh
helm upgrade kube-workspaces \\
  oci://ghcr.io/kube-workspaces/charts/kube-workspaces \\
  --namespace kube-workspaces-system
\`\`\`

EOF
    ;;
esac
