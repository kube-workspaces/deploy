#!/usr/bin/env bash
# Verify .github/release.yml is identical across the five kube-workspaces
# repositories.
#
# The release-notes categories only produce a consistent reading experience if
# every repo uses the same ones. The file itself says it must be kept in step;
# this is what makes that true rather than aspirational.
#
# Skips silently when the sibling checkouts are not present, so it does not fail
# CI in this repo — the sibling repos are not available there. Run it locally
# before changing the config.
#
# Usage: scripts/check-release-config.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIBLINGS="$(cd "${REPO_ROOT}/.." && pwd)"

REFERENCE="${REPO_ROOT}/.github/release.yml"
if [ ! -f "$REFERENCE" ]; then
  echo "error: ${REFERENCE} does not exist" >&2
  exit 1
fi

ref_sum=$(md5sum < "$REFERENCE" | cut -d' ' -f1)
checked=0
drifted=""

for r in controller api proxy frontend; do
  f="${SIBLINGS}/${r}/.github/release.yml"
  if [ ! -f "$f" ]; then
    continue
  fi
  checked=$((checked + 1))
  if [ "$(md5sum < "$f" | cut -d' ' -f1)" != "$ref_sum" ]; then
    drifted="${drifted} ${r}"
  fi
done

if [ "$checked" -eq 0 ]; then
  echo "no sibling checkouts found in ${SIBLINGS} — skipping"
  exit 0
fi

if [ -n "$drifted" ]; then
  echo "release.yml has drifted in:${drifted}" >&2
  for r in $drifted; do
    echo "--- diff against ${r} ---" >&2
    diff "$REFERENCE" "${SIBLINGS}/${r}/.github/release.yml" >&2 || true
  done
  exit 1
fi

echo "release.yml is identical across ${checked} sibling repo(s)"
