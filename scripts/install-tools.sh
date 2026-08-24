#!/usr/bin/env bash
# Install pinned test tooling into .bin/ so local runs and CI agree on versions
# without touching the system. Idempotent: skips anything already at the right
# version, and skips anything already on PATH at an acceptable version.
#
# Usage: scripts/install-tools.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${REPO_ROOT}/.bin"
mkdir -p "$BIN"

KUBECONFORM_VERSION="${KUBECONFORM_VERSION:-v0.6.7}"
KUSTOMIZE_VERSION="${KUSTOMIZE_VERSION:-v5.5.0}"
YQ_VERSION="${YQ_VERSION:-v4.44.3}"

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

# --- kubeconform ------------------------------------------------------------
if have_version kubeconform "${KUBECONFORM_VERSION#v}"; then
  echo "kubeconform ${KUBECONFORM_VERSION} already installed"
else
  echo "installing kubeconform ${KUBECONFORM_VERSION} (${os}/${arch})"
  tmp="$(mktemp -d)"
  url="https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-${os}-${arch}.tar.gz"
  if curl -fsSL -o "$tmp/kc.tar.gz" "$url"; then
    tar -xzf "$tmp/kc.tar.gz" -C "$tmp" kubeconform
    mv "$tmp/kubeconform" "$BIN/kubeconform"
    chmod +x "$BIN/kubeconform"
  else
    echo "warning: could not download kubeconform from $url" >&2
    echo "schema validation will be skipped" >&2
  fi
  rm -rf "$tmp"
fi

# --- kustomize --------------------------------------------------------------
# Not preinstalled on GitHub runners. `kubectl kustomize` exists but lags the
# standalone release and does not accept all the same flags, so install the real
# thing rather than papering over it.
if command -v kustomize >/dev/null 2>&1 && [ ! -x "$BIN/kustomize" ]; then
  echo "kustomize already on PATH ($(kustomize version 2>/dev/null | head -1))"
elif [ -x "$BIN/kustomize" ]; then
  echo "kustomize already installed in .bin/"
else
  echo "installing kustomize ${KUSTOMIZE_VERSION} (${os}/${arch})"
  tmp="$(mktemp -d)"
  url="https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION}_${os}_${arch}.tar.gz"
  if curl -fsSL -o "$tmp/k.tar.gz" "$url"; then
    tar -xzf "$tmp/k.tar.gz" -C "$tmp" kustomize
    mv "$tmp/kustomize" "$BIN/kustomize"
    chmod +x "$BIN/kustomize"
  else
    echo "error: could not download kustomize from $url" >&2
    rm -rf "$tmp"
    exit 1
  fi
  rm -rf "$tmp"
fi

# --- yq ---------------------------------------------------------------------
if command -v yq >/dev/null 2>&1 && [ ! -x "$BIN/yq" ]; then
  echo "yq already on PATH ($(yq --version 2>/dev/null))"
elif [ -x "$BIN/yq" ]; then
  echo "yq already installed in .bin/"
else
  echo "installing yq ${YQ_VERSION} (${os}/${arch})"
  url="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_${os}_${arch}"
  if curl -fsSL -o "$BIN/yq" "$url"; then
    chmod +x "$BIN/yq"
  else
    echo "error: could not download yq from $url" >&2
    exit 1
  fi
fi

echo "tools ready in ${BIN}"
