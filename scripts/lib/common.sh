#!/usr/bin/env bash
# Shared helpers for the kube-workspaces deploy test scripts.
#
# Source this, do not execute it:
#   source "$(dirname "$0")/lib/common.sh"
#
# Every script that sources this gets: strict mode, colourised pass/fail
# reporting with a non-zero exit when anything failed, and tool checks.
#
# Note on strictness: we want -u and pipefail, but NOT -e. These scripts are
# test harnesses — a failing assertion must be recorded and the run must
# continue so one command failure does not hide the remaining results. Scripts
# exit non-zero via finish() based on the failure tally. Use die() for genuine
# setup errors that should abort immediately.

set -uo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

# Repo root, regardless of where the script was invoked from.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''; C_OFF=''
fi

# Running tallies, consumed by finish().
CHECKS_PASSED=0
CHECKS_FAILED=0
FAILED_NAMES=()

# GitHub Actions log grouping when available, plain headers otherwise.
group() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::group::$*"
  else
    printf '\n%s==> %s%s\n' "$C_BOLD$C_BLUE" "$*" "$C_OFF"
  fi
}

endgroup() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::endgroup::"
  fi
}

info()  { printf '%s--%s %s\n' "$C_BLUE" "$C_OFF" "$*"; }
warn()  { printf '%s!!%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }

# pass/fail record a result AND print it.
pass() {
  CHECKS_PASSED=$((CHECKS_PASSED + 1))
  printf '%sPASS%s %s\n' "$C_GREEN" "$C_OFF" "$*"
}

fail() {
  CHECKS_FAILED=$((CHECKS_FAILED + 1))
  FAILED_NAMES+=("$*")
  printf '%sFAIL%s %s\n' "$C_RED" "$C_OFF" "$*"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::error::$*"
  fi
}

# die aborts immediately — for setup problems, not test failures.
die() {
  printf '%sfatal:%s %s\n' "$C_RED$C_BOLD" "$C_OFF" "$*" >&2
  exit 1
}

# Print the tally and exit non-zero if anything failed. Call at end of script.
finish() {
  local total=$((CHECKS_PASSED + CHECKS_FAILED))
  printf '\n%s%s%s: %d/%d checks passed' \
    "$C_BOLD" "${SCRIPT_NAME:-results}" "$C_OFF" "$CHECKS_PASSED" "$total"
  if [ "$CHECKS_FAILED" -gt 0 ]; then
    printf ', %s%d failed%s\n' "$C_RED" "$CHECKS_FAILED" "$C_OFF"
    printf '\nFailed checks:\n'
    local n
    for n in "${FAILED_NAMES[@]}"; do
      printf '  %s-%s %s\n' "$C_RED" "$C_OFF" "$n"
    done
    return 1
  fi
  printf '\n'
  return 0
}

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------

# check <description> <command...>
# Runs the command, hides its output unless it fails.
check() {
  local desc="$1"; shift
  local out
  if out=$("$@" 2>&1); then
    pass "$desc"
    return 0
  fi
  fail "$desc"
  printf '%s\n' "$out" | sed 's/^/     /' >&2
  return 1
}

# check_contains <description> <needle> <command...>
check_contains() {
  local desc="$1" needle="$2"; shift 2
  local out
  if ! out=$("$@" 2>&1); then
    fail "$desc (command failed)"
    printf '%s\n' "$out" | sed 's/^/     /' >&2
    return 1
  fi
  if printf '%s' "$out" | grep -qF -- "$needle"; then
    pass "$desc"
    return 0
  fi
  fail "$desc (expected to contain '$needle')"
  printf '%s\n' "$out" | sed 's/^/     /' >&2
  return 1
}

# check_equals <description> <expected> <actual>
check_equals() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$desc"
    return 0
  fi
  fail "$desc (expected '$expected', got '$actual')"
  return 1
}

# ---------------------------------------------------------------------------
# Tooling
# ---------------------------------------------------------------------------

# require_tools kubectl helm ...
require_tools() {
  local missing=() t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    die "required tool(s) not on PATH: ${missing[*]}"
  fi
}

# Install a pinned tool into .bin/ if absent, and prepend .bin to PATH.
# Used so CI and local runs agree on versions without polluting the system.
LOCAL_BIN="${REPO_ROOT}/.bin"
export PATH="${LOCAL_BIN}:${PATH}"

ensure_local_bin() { mkdir -p "$LOCAL_BIN"; }

# ---------------------------------------------------------------------------
# Constants shared across test scripts
# ---------------------------------------------------------------------------

# The namespace every deployment method targets.
: "${KW_NAMESPACE:=kube-workspaces-system}"
# Namespace where Workspace CRs live.
: "${KW_WORKSPACE_NAMESPACE:=workspaces}"
# The four component deployments.
KW_DEPLOYMENTS=(
  kube-workspaces-controller
  kube-workspaces-api
  kube-workspaces-proxy
  kube-workspaces-frontend
)
# All six CRDs.
KW_CRDS=(
  workspaces.kubeworkspaces.io
  images.kubeworkspaces.io
  users.kubeworkspaces.io
  authconfigs.kubeworkspaces.io
  platformconfigs.kubeworkspaces.io
  poddefaults.kubeworkspaces.io
)
export KW_NAMESPACE KW_WORKSPACE_NAMESPACE
