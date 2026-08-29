#!/usr/bin/env bash
# Classify the changes since the last tag and emit the full release notes.
#
# The point is to answer, up front, the question a reader actually has: does this
# release change how the software behaves, or is it a version alignment?
#
# The five repositories are released together and the chart's appVersion pins all
# four images to one number, so a component with no functional changes still gets
# tagged. Saying so explicitly is much better than leaving someone to infer it
# from a list of CI commits.
#
# The script emits the whole body: a preamble, per-repo upgrade instructions, and
# a categorised commit list. The list is generated here rather than left to
# GitHub's --generate-notes, which groups commits by pull request — commits that
# land as direct pushes to main (this repo relies on admin-token pushes) have no
# PR and would otherwise produce an empty "What's Changed" section.
#
# Usage: scripts/release-notes.sh [--repo NAME] [--from TAG] [--to REF]
#                                 [--version VERSION]
# Output: markdown on stdout.

set -uo pipefail

REPO_NAME=""
FROM=""
TO="HEAD"
# The version being released. Defaults to TO, which is right when TO is a tag but
# renders "HEAD" in the upgrade snippet when generating notes before tagging.
VERSION_IN=""

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO_NAME="$2"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    --to)   TO="$2"; shift 2 ;;
    --version) VERSION_IN="$2"; shift 2 ;;
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
# Capture short hash + subject so the list below can link each commit. --no-merges
# keeps the squash/"direct push" history flat, which is what GitHub's per-PR notes
# would show anyway.
subjects=$(git log "$range" --no-merges --format='%h %s' 2>/dev/null)

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
n_breaking=$(count_matching ' [a-z]+(\([^)]*\))?!:')
n_feat=$(count_matching ' feat(\([^)]*\))?!?:')
n_fix=$(count_matching ' fix(\([^)]*\))?!?:')
n_perf=$(count_matching ' perf(\([^)]*\))?!?:')
n_refactor=$(count_matching ' (refactor|revert)(\([^)]*\))?!?:')
n_sec=$(count_matching ' security(\([^)]*\))?!?:')

# Non-functional prefixes.
n_ci=$(count_matching ' (ci|build)(\([^)]*\))?:')
n_docs=$(count_matching ' docs(\([^)]*\))?:')
n_chore=$(count_matching ' (chore|style|test)(\([^)]*\))?:')

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

VERSION="${VERSION_IN:-${TO#refs/tags/}}"
VERSION="${VERSION#refs/tags/}"
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

# ---------------------------------------------------------------------------
# Categorised commit list
#
# GitHub's --generate-notes groups commits by pull request and keys the
# categories off PR labels, so direct pushes to main — how most of this repo's
# changes actually land — fall through to an empty "What's Changed" section.
# Instead we build the list here, grouping the commit subjects by conventional
# prefix into the same headings .github/release.yml uses. GitHub auto-links the
# bare short hashes, so no explicit URLs are needed.
# ---------------------------------------------------------------------------

# Commit lines whose prefix carries a `!` breaking marker (feat!, fix!, ...).
# Shown once, under Breaking changes, mirroring release.yml where the breaking
# label wins over the feature/fix label.
breaking_lines=$(printf '%s\n' "$subjects" | grep -E ' [a-z]+(\([^)]*\))?!:' || true)
# Non-breaking commits — the pool the normal categories are drawn from.
plain_lines=$(printf '%s\n' "$subjects" | grep -vE ' [a-z]+(\([^)]*\))?!:' || true)

# Print "- hash subject" for every line in a category; takes the heading and one
# or more conventional prefixes.
list_category() {
  local title="$1"; shift
  local pattern
  pattern=$(printf ' (%s)(\\([^)]*\\))?!?:' "$(printf '%s|' "$@" | sed 's/|$//')")
  local hits
  hits=$(printf '%s\n' "$plain_lines" | grep -E "$pattern" || true)
  if [ -n "$hits" ]; then
    printf '\n### %s\n\n' "$title"
    printf '%s\n' "$hits" | sed 's/^/- /'
    printf '\n'
  fi
}

if [ "$n_total" -gt 0 ]; then
  echo "## What's Changed"

  if [ -n "$breaking_lines" ]; then
    printf '\n### ⚠️ Breaking changes\n\n'
    printf '%s\n' "$breaking_lines" | sed 's/^/- /'
    printf '\n'
  fi
  list_category '🔒 Security' 'security'
  list_category '✨ Features' 'feat'
  list_category '🐛 Fixes' 'fix'
  list_category '📚 Documentation' 'docs'
  list_category '🔧 CI and tooling' 'ci' 'build' 'chore' 'style' 'test'
  list_category '⬆️ Dependencies' 'deps'

  # Everything not matched above has no conventional prefix (or a bare
  # imperative) — kept under "Other" rather than dropped, matching release.yml's
  # catch-all "*" category.
  others=$(printf '%s\n' "$plain_lines" | grep -vE \
    ' (security|feat|fix|docs|ci|build|chore|style|test|deps)(\([^)]*\))?!?:' || true)
  if [ -n "$others" ]; then
    printf '\n### Other changes\n\n'
    printf '%s\n' "$others" | sed 's/^/- /'
    printf '\n'
  fi
fi
