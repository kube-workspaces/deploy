#!/usr/bin/env bash
# generate-godoc.sh - Generates Markdown documentation for all Go packages
# using gomarkdoc, then produces combined output files for embedding
# in the API server.
#
# Usage: ./scripts/generate-godoc.sh
# Output: api/cmd/kube_workspaces/godoc/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/api/cmd/kube_workspaces/godoc"

# Ensure gomarkdoc is available
if ! command -v gomarkdoc &> /dev/null; then
    echo "Installing gomarkdoc..."
    go install github.com/princjef/gomarkdoc/cmd/gomarkdoc@latest
fi

echo "Generating Go documentation..."

# Create output directory
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

REPO_URL="https://github.com/flaccid/kube-workspaces"
BRANCH="main"

# --- Controller Module ---
echo "  -> Controller module (controller/)"
cd "$ROOT_DIR/controller"

CONTROLLER_OUT="$OUTPUT_DIR/controller.md"
: > "$CONTROLLER_OUT"

CONTROLLER_PACKAGES=(
    "./api/v1alpha1"
    "./internal/controller"
)

for pkg in "${CONTROLLER_PACKAGES[@]}"; do
    echo "     - $pkg"
    gomarkdoc --format github \
        --repository.url "$REPO_URL" \
        --repository.default-branch "$BRANCH" \
        --repository.path "controller" \
        "$pkg" >> "$CONTROLLER_OUT" 2>/dev/null || {
        echo "     [warning] partial failure for $pkg, trying without repo links..."
        gomarkdoc --format github "$pkg" >> "$CONTROLLER_OUT" 2>/dev/null || true
    }
    printf "\n---\n\n" >> "$CONTROLLER_OUT"
done

# --- API Module ---
echo "  -> API module (api/)"
cd "$ROOT_DIR/api"

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
        --repository.url "$REPO_URL" \
        --repository.default-branch "$BRANCH" \
        --repository.path "api" \
        "$pkg" >> "$API_OUT" 2>/dev/null || {
        echo "     [warning] partial failure for $pkg, trying without repo links..."
        gomarkdoc --format github "$pkg" >> "$API_OUT" 2>/dev/null || true
    }
    printf "\n---\n\n" >> "$API_OUT"
done

# --- Generate index metadata ---
cat > "$OUTPUT_DIR/index.json" << EOF
{
  "generated": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "modules": [
    {
      "name": "Controller",
      "path": "controller",
      "goVersion": "1.24",
      "module": "github.com/flaccid/kube-workspaces/controller",
      "description": "Kubernetes controllers for Workspace, User, and AuthConfig CRDs",
      "packages": [
        "api/v1alpha1",
        "internal/controller"
      ]
    },
    {
      "name": "API",
      "path": "api",
      "goVersion": "1.26",
      "module": "github.com/flaccid/kube-workspaces/api",
      "description": "REST API server built with Goa framework",
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

echo ""
echo "Done! Output written to: $OUTPUT_DIR/"
echo "  - controller.md ($(wc -l < "$CONTROLLER_OUT") lines)"
echo "  - api.md ($(wc -l < "$API_OUT") lines)"
echo "  - index.json"
