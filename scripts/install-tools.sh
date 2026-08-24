#!/usr/bin/env bash
# Install pinned test tooling into .bin/ so local runs and CI agree on versions
# without touching the system. Idempotent: skips anything already at the right
# version.
#
# Usage: scripts/install-tools.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${REPO_ROOT}/.bin"
mkdir -p "$BIN"

KUBECONFORM_VERSION="${KUBECONFORM_VERSION:-v0.6.7}"

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$(uname -m)" in
  x86_64|amd64) arch=amd64 ;;
  arm64|aarch64) arch=arm64 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

have_version() {
  # have_version <binary> <expected-substring>
  [ -x "$BIN/$1" ] || return 1
  "$BIN/$1" -v 2>/dev/null | grep -qF "$2"
}

if have_version kubeconform "${KUBECONFORM_VERSION#v}"; then
  echo "kubeconform ${KUBECONFORM_VERSION} already installed"
else
  echo "installing kubeconform ${KUBECONFORM_VERSION} (${os}/${arch})"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  url="https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-${os}-${arch}.tar.gz"
  if ! curl -fsSL -o "$tmp/kc.tar.gz" "$url"; then
    echo "warning: could not download kubeconform from $url" >&2
    echo "schema validation will be skipped" >&2
    exit 0
  fi
  tar -xzf "$tmp/kc.tar.gz" -C "$tmp" kubeconform
  mv "$tmp/kubeconform" "$BIN/kubeconform"
  chmod +x "$BIN/kubeconform"
fi

echo "tools ready in ${BIN}"
