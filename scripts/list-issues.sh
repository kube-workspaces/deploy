#!/usr/bin/env bash
# List open issues across the organisation, including all result pages.
# Requires: gh (GitHub CLI) authenticated to the org.
# Usage: bash scripts/list-issues.sh [ORG]

set -euo pipefail

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

repos=$(gh api --paginate "orgs/$ORG/repos?per_page=100" \
  --jq '.[] | select(.has_issues) | .full_name')

if [ -z "$repos" ]; then
  echo "No repositories with issues enabled found in $ORG."
  exit 0
fi

while IFS= read -r repo; do
  printf '\n%s\n' "$repo"
  # GitHub's issues endpoint also returns pull requests; exclude those.
  issues=$(gh api --paginate "repos/$repo/issues?state=open&per_page=100" \
    --jq '.[] | select(.pull_request == null) | "  #\(.number)  \(.title)  \(.html_url)"')
  if [ -n "$issues" ]; then
    printf '%s\n' "$issues"
  else
    printf '  No open issues.\n'
  fi
done <<< "$repos"
