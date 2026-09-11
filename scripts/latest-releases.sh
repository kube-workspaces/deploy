#!/usr/bin/env bash
# List the latest release (if any) for every repository in the kube-workspaces
# GitHub organisation.
#
# Requires: gh (GitHub CLI) authenticated to the org.
#
# Usage: scripts/latest-releases.sh [ORG]

set -uo pipefail

ORG="${1:-kube-workspaces}"

if ! command -v gh &>/dev/null; then
  echo "error: gh (GitHub CLI) is not installed." >&2
  echo "  install: https://cli.github.com/" >&2
  exit 1
fi

if ! gh auth status &>/dev/null; then
  echo "error: gh is not authenticated — run 'gh auth login' first." >&2
  exit 1
fi

repos=$(gh repo list "$ORG" --limit 1000 --json name,isArchived \
  --jq '[.[] | select(.isArchived == false) | .name] | sort[]')

if [ -z "$repos" ]; then
  echo "No repositories found in $ORG (or org does not exist)." >&2
  exit 1
fi

# Colour helpers (no-op when stdout is not a terminal or NO_COLOR is set).
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  BOLD=$'\033[1m'; GREEN=$'\033[32m'; OFF=$'\033[0m'
else
  BOLD=''; GREEN=''; OFF=''
fi

printf "${BOLD}%-26s  %-14s  %-16s  %s${OFF}\n" "REPOSITORY" "LATEST RELEASE" "COMMITS BEHIND" "URL"
printf '%.0s─' {1..100}; echo

for repo in $repos; do
  result=$(gh release view \
    -R "$ORG/$repo" \
    --json tagName,url \
    -t '{{.tagName}}{{"\t"}}{{.url}}' \
    2>/dev/null) || true

  if [ -n "$result" ]; then
    tag="${result%%	*}"
    url="${result#*	}"

    # How many commits the default branch is ahead of the release tag: compare
    # tag...<default-branch> and read ahead_by. Empty when the compare fails.
    branch=$(gh repo view "$ORG/$repo" \
      --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null)
    behind=""
    if [ -n "$branch" ]; then
      behind=$(gh api "repos/$ORG/$repo/compare/${tag}...${branch}" \
        --jq '.ahead_by' 2>/dev/null) || true
    fi
    [ -n "$behind" ] || behind="n/a"

    printf "%-26s  ${GREEN}%-14s${OFF}  %-16s  %s\n" "$repo" "$tag" "$behind" "$url"
  else
    printf "%-26s  %-14s  %-16s\n" "$repo" "—" "—"
  fi
done
