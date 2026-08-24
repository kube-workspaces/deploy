#!/usr/bin/env bash
# generate-godoc.sh - Generates Markdown documentation for the Go packages in
# the controller and api repositories, then writes the combined output into the
# api repo for embedding in the API server.
#
# NOTE: this script predates the monorepo split. The components now live in
# separate repositories, so it needs the controller and api repos checked out
# alongside this one:
#
#   src/github/kube-workspaces/
#     ├── api/
#     ├── controller/
#     └── deploy/      <- you are here
#
# Override the locations with CONTROLLER_DIR / API_DIR if your layout differs.
#
# Usage: ./scripts/generate-godoc.sh
# Output: $API_DIR/cmd/kube_workspaces/godoc/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SIBLINGS="$(cd "$DEPLOY_DIR/.." && pwd)"

CONTROLLER_DIR="${CONTROLLER_DIR:-$SIBLINGS/controller}"
API_DIR="${API_DIR:-$SIBLINGS/api}"

for d in "$CONTROLLER_DIR" "$API_DIR"; do
  if [ ! -f "$d/go.mod" ]; then
    cat >&2 <<EOF
error: expected a Go module at $d

The components live in separate repositories since the monorepo
(github.com/flaccid/kube-workspaces, now archived) was split. Clone them
alongside this repo, or set CONTROLLER_DIR / API_DIR explicitly:

  git clone https://github.com/kube-workspaces/controller "$SIBLINGS/controller"
  git clone https://github.com/kube-workspaces/api "$SIBLINGS/api"
EOF
    exit 1
  fi
done

OUTPUT_DIR="$API_DIR/cmd/kube_workspaces/godoc"

# Ensure gomarkdoc is available
if ! command -v gomarkdoc &> /dev/null; then
    echo "Installing gomarkdoc..."
    go install github.com/princjef/gomarkdoc/cmd/gomarkdoc@latest
fi

echo "Generating Go documentation..."
echo "  controller: $CONTROLLER_DIR"
echo "  api:        $API_DIR"
echo "  output:     $OUTPUT_DIR"

# Create output directory
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

BRANCH="main"

# Derive each repo's URL from its module path so the links stay correct without
# hardcoding an org that may change again.
module_path() { awk '/^module /{print $2; exit}' "$1/go.mod"; }
CONTROLLER_MODULE="$(module_path "$CONTROLLER_DIR")"
API_MODULE="$(module_path "$API_DIR")"
CONTROLLER_URL="https://${CONTROLLER_MODULE}"
API_URL="https://${API_MODULE}"

# Go version each module declares, for the index metadata.
go_version() { awk '/^go /{print $2; exit}' "$1/go.mod"; }

# --- Controller Module ---
echo "  -> Controller module ($CONTROLLER_DIR)"
cd "$CONTROLLER_DIR"

CONTROLLER_OUT="$OUTPUT_DIR/controller.md"
: > "$CONTROLLER_OUT"

CONTROLLER_PACKAGES=(
    "./api/v1alpha1"
    "./internal/controller"
)

for pkg in "${CONTROLLER_PACKAGES[@]}"; do
    echo "     - $pkg"
    gomarkdoc --format github \
        --repository.url "$CONTROLLER_URL" \
        --repository.default-branch "$BRANCH" \
        --repository.path "/" \
        "$pkg" >> "$CONTROLLER_OUT" 2>/dev/null || {
        # Retry without repository links: gomarkdoc fails when the checkout has
        # no git remote (e.g. a tarball or CI cache).
        gomarkdoc --format github "$pkg" >> "$CONTROLLER_OUT"
    }
    echo "" >> "$CONTROLLER_OUT"
done

# --- API Module ---
echo "  -> API module ($API_DIR)"
cd "$API_DIR"

API_OUT="$OUTPUT_DIR/api.md"
: > "$API_OUT"

API_PACKAGES=(
    "."
    "./internal/auth"
    "./internal/k8s"
    "./internal/proxy"
    "./internal/exec"
)

for pkg in "${API_PACKAGES[@]}"; do
    echo "     - $pkg"
    gomarkdoc --format github \
        --repository.url "$API_URL" \
        --repository.default-branch "$BRANCH" \
        --repository.path "/" \
        "$pkg" >> "$API_OUT" 2>/dev/null || {
        gomarkdoc --format github "$pkg" >> "$API_OUT"
    }
    echo "" >> "$API_OUT"
done

# --- Index metadata ---
cat > "$OUTPUT_DIR/index.json" << EOF
{
  "generated": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "modules": [
    {
      "name": "Controller",
      "path": "controller",
      "goVersion": "$(go_version "$CONTROLLER_DIR")",
      "module": "${CONTROLLER_MODULE}",
      "description": "Kubernetes controllers for Workspace, User, and AuthConfig CRDs",
      "packages": [
        "api/v1alpha1",
        "internal/controller"
      ]
    },
    {
      "name": "API",
      "path": "api",
      "goVersion": "$(go_version "$API_DIR")",
      "module": "${API_MODULE}",
      "description": "REST API service built with Goa",
      "packages": [
        ".",
        "internal/auth",
        "internal/k8s",
        "internal/proxy",
        "internal/exec"
      ]
    }
  ]
}
EOF

echo "Done. Generated:"
echo "  - controller.md ($(wc -l < "$CONTROLLER_OUT") lines)"
echo "  - api.md ($(wc -l < "$API_OUT") lines)"
echo "  - index.json"
