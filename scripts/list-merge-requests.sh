#!/usr/bin/env bash
# List open pull requests across the organisation, including all result pages.
# Requires: gh (GitHub CLI) authenticated to the org.
# Usage: bash scripts/list-merge-requests.sh [ORG]

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
  --jq '.[].full_name')

if [ -z "$repos" ]; then
  echo "No repositories found in $ORG."
  exit 0
fi

while IFS= read -r repo; do
  printf '\n%s\n' "$repo"
  requests=$(gh api --paginate "repos/$repo/pulls?state=open&per_page=100" \
    --jq '.[] | "  #\(.number)  \(.title)  \(.html_url)"')
  if [ -n "$requests" ]; then
    printf '%s\n' "$requests"
  else
    printf '  No open pull requests.\n'
  fi
done <<< "$repos"
