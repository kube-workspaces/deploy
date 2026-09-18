#!/usr/bin/env bash
# Summarise recent GitHub Actions status across every repository in a GitHub
# organisation.
#
# The point is to find CI failures worth addressing before cutting a release:
# it inspects the most recent workflow runs on each repo's default branch and
# reports whether the newest commit's runs are green, with a per-repo yes/no on
# whether action is needed. Failures on superseded commits are surfaced in the
# NOTES column rather than flagged as action items, so a run that re-succeeded
# (or was fixed by a later commit) does not block a release.
#
# Requires: gh (GitHub CLI) authenticated to the org.
#
# Usage: scripts/org-project-recent-actions-status.sh [ORG] [--runs N] [--repo NAME ...]
#
#   ORG        organisation (default: kube-workspaces)
#   --runs N   how many recent workflow runs to inspect per repo (default: 10)
#   --repo     restrict the scan to the given repo(s); repeatable
#
# Exit status is 1 when any repo needs action, 0 otherwise.

set -uo pipefail

ORG="kube-workspaces"
RUN_LIMIT=10
REPOS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --runs) RUN_LIMIT="$2"; shift 2 ;;
    --repo) REPOS+=("$2"); shift 2 ;;
    -h|--help)
      cat <<EOF
Summarise recent GitHub Actions status across an org's repositories.

Usage: scripts/org-project-recent-actions-status.sh [ORG] [--runs N] [--repo NAME ...]

  ORG        organisation (default: kube-workspaces)
  --runs N   how many recent workflow runs to inspect per repo (default: 10)
  --repo     restrict the scan to the given repo(s); repeatable

Looks at the newest commit on each repo's default branch and reports whether
its workflow runs are green. Exits 1 when any repo needs action.
EOF
      exit 0
      ;;
    *) ORG="$1"; shift ;;
  esac
done

if ! [[ "$RUN_LIMIT" =~ ^[0-9]+$ ]] || [ "$RUN_LIMIT" -eq 0 ]; then
  echo "error: --runs must be a positive integer, got '$RUN_LIMIT'" >&2
  exit 2
fi

if ! command -v gh &>/dev/null; then
  echo "error: gh (GitHub CLI) is not installed." >&2
  echo "  install: https://cli.github.com/" >&2
  exit 1
fi

if ! gh auth status &>/dev/null; then
  echo "error: gh is not authenticated — run 'gh auth login' first." >&2
  exit 1
fi

# Colour helpers (no-op when stdout is not a terminal or NO_COLOR is set).
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'
  YELLOW=$'\033[33m'; OFF=$'\033[0m'
else
  BOLD=''; RED=''; GREEN=''; YELLOW=''; OFF=''
fi

# A completed run whose conclusion is anything in this set failed for real.
# action_required (approval needed) and startup_failure count too — a release
# must not go out on those. success/neutral/skipped and cancelled are handled
# separately by the caller.
conclusion_is_failure() {
  case "$1" in
    failure|timed_out|action_required|startup_failure) return 0 ;;
    *) return 1 ;;
  esac
}

org_repos=$(gh repo list "$ORG" --limit 1000 --json name,isArchived \
  --jq '[.[] | select(.isArchived == false) | .name] | sort[]')

if [ -z "$org_repos" ]; then
  echo "No repositories found in $ORG (or org does not exist)." >&2
  exit 1
fi

if [ "${#REPOS[@]}" -gt 0 ]; then
  requested=" ${REPOS[*]} "
  repos=""
  for r in $org_repos; do
    case "$requested" in
      *" $r "*) repos="${repos}${repos:+ }${r}" ;;
    esac
  done
  if [ -z "$repos" ]; then
    echo "error: none of the requested repos are in $ORG: ${REPOS[*]}" >&2
    exit 2
  fi
else
  repos="$org_repos"
fi

# Per-workflow verdict at the newest commit, keyed by workflow name. Declared
# once, cleared each iteration — declare does not empty an array.
declare -A tip_seen tip_res

printf "${BOLD}%-22s  %-12s  %-7s  %-9s  %s${OFF}\n" \
  "PROJECT" "STATUS" "ACTION" "HEAD" "NOTES"
printf '%.0s─' {1..120}; echo

needs_action=0
for repo in $repos; do
  branch=$(gh repo view "$ORG/$repo" --json defaultBranchRef \
    --jq '.defaultBranchRef.name' 2>/dev/null) || true

  args=(
    -R "$ORG/$repo"
    --limit "$RUN_LIMIT"
    --json "status,conclusion,workflowName,headSha,databaseId,createdAt"
    --jq 'sort_by(.createdAt) | reverse | .[] | [.headSha, .status, (.conclusion // "-"), .workflowName, (.databaseId|tostring)] | @tsv'
  )
  [ -n "$branch" ] && args+=(--branch "$branch")

  runs=$(gh run list "${args[@]}" 2>/dev/null) || true

  if [ -z "$runs" ]; then
    printf "%-22s  %-12s  %-7s  %-9s  %s\n" \
      "$repo" "no actions" "—" "—" "no runs on default branch"
    continue
  fi

  # Runs arrive newest-first, so the first sha seen is the tip we judge;
  # everything after it is superseded commits we only mention in NOTES.
  tip_seen=()
  tip_res=()
  newest_sha=""   # first (newest) commit seen
  older_fails=()  # "Workflow@shorthash" for failures on superseded commits

  while IFS=$'\t' read -r sha status conclusion wf id; do
    [ -n "$newest_sha" ] || newest_sha="$sha"
    if [ "$sha" = "$newest_sha" ]; then
      # The first run of each workflow at the tip is its most recent verdict.
      if [ -z "${tip_seen[$wf]:-}" ]; then
        tip_seen[$wf]=1
        if [ "$status" = "completed" ]; then
          tip_res[$wf]="${conclusion}:${id}"
        else
          tip_res[$wf]="running:${id}"
        fi
      fi
    elif [ "$status" = "completed" ] && conclusion_is_failure "$conclusion"; then
      older_fails+=("${wf}@${sha:0:7}")
    fi
  done <<< "$runs"

  tip_failed=()    # workflow names whose newest tip run failed
  tip_running=()   # workflow names still in progress at the tip
  tip_cancelled=() # workflow names cancelled at the tip
  for wf in "${!tip_res[@]}"; do
    case "${tip_res[$wf]%%:*}" in
      success|neutral|skipped) ;;
      cancelled)     tip_cancelled+=("$wf") ;;
      running|queued|pending|requested|waiting) tip_running+=("$wf") ;;
      *)             tip_failed+=("$wf") ;;
    esac
  done

  if [ "${#tip_failed[@]}" -gt 0 ]; then
    status="failed"; action="yes"; sc="$RED"; ac="$RED$BOLD"
    needs_action=$((needs_action + 1))
  elif [ "${#tip_running[@]}" -gt 0 ]; then
    status="in progress"; action="wait"; sc="$YELLOW"; ac="$YELLOW"
  elif [ "${#tip_cancelled[@]}" -gt 0 ]; then
    status="cancelled"; action="check"; sc="$YELLOW"; ac="$YELLOW"
  else
    status="healthy"; action="no"; sc="$GREEN"; ac="$GREEN"
  fi

  # NOTES: failing tip workflows first, then recent superseded-commit failures.
  tip_note=""
  for wf in "${tip_failed[@]}"; do
    id="${tip_res[$wf]#*:}"
    tip_note="${tip_note}${tip_note:+; }${wf} (#${id})@${newest_sha:0:7}"
  done
  older_note=""
  for f in "${older_fails[@]:0:4}"; do
    older_note="${older_note}${older_note:+; }older ${f}"
  done
  [ "${#older_fails[@]}" -le 4 ] || older_note="${older_note}; +$(( ${#older_fails[@]} - 4 )) more"

  if [ -n "$tip_note" ] && [ -n "$older_note" ]; then
    notes="${tip_note}; ${older_note}"
  elif [ -n "$tip_note" ] || [ -n "$older_note" ]; then
    notes="${tip_note}${older_note}"
  else
    notes="—"
  fi

  printf "%-22s  %s%-12s%s  %s%-7s%s  %-9s  %s\n" \
    "$repo" "$sc" "$status" "$OFF" "$ac" "$action" "$OFF" \
    "${newest_sha:0:7}" "$notes"
done

printf '%.0s─' {1..120}; echo
if [ "$needs_action" -gt 0 ]; then
  if [ "$needs_action" -eq 1 ]; then
    printf '%s1 repo needs action before a release — address the failure above.%s\n' \
      "$RED$BOLD" "$OFF"
  else
    printf '%s%d repos need action before a release — address the failures above.%s\n' \
      "$RED$BOLD" "$needs_action" "$OFF"
  fi
  echo "(superseded-commit failures in NOTES are already fixed on the tip; review only if they look flaky)"
  exit 1
fi
echo "All repos with recent runs are healthy — no CI failures to address."
exit 0