#!/usr/bin/env bash
# Extract OpenAPI v3 schemas from our CRDs into standalone JSON Schema files,
# so kubeconform can validate kubeworkspaces.io custom resources instead of
# skipping them.
#
# Without this, kubeconform reports our Workspace/Image/AuthConfig resources as
# "skipped" and a malformed CR sails through validation.
#
# Usage: scripts/crd-to-schema.sh <output-dir>
# Emits: <output-dir>/<kind>.json  (lowercase kind, matching the
#        -schema-location '{{.ResourceKind}}.json' template)

set -euo pipefail

OUT_DIR="${1:?usage: crd-to-schema.sh <output-dir>}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v yq >/dev/null 2>&1 || { echo "yq is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

mkdir -p "$OUT_DIR"

# Flatten every CRD file into one stream first. A single file can hold several
# CRD documents (kustomize/crds/crd.yaml holds both Workspace and Image), and
# yq's `[select(...)]` collects per-document rather than across the stream, so
# indexing per file yields nulls. Merging with `kustomize build` gives one
# well-ordered stream we can address by document index.
ALL="$(mktemp)"
trap 'rm -f "$ALL"' EXIT
kustomize build "$REPO_ROOT/kustomize/crds" > "$ALL"

# Number of documents in the stream.
doc_total=$(yq -N 'document_index' "$ALL" | tail -1)

count=0
for i in $(seq 0 "$doc_total"); do
  kind=$(yq -N "select(document_index == $i) | select(.kind==\"CustomResourceDefinition\") | .spec.names.kind" "$ALL")
  [ -n "$kind" ] && [ "$kind" != "null" ] || continue

  lc_kind=$(printf '%s' "$kind" | tr '[:upper:]' '[:lower:]')

  # Take the schema from the first served version, then wrap it so that
  # apiVersion/kind/metadata are permitted alongside spec/status — otherwise
  # strict validation rejects every real manifest.
  yq -N -o=json \
    "select(document_index == $i) | .spec.versions[0].schema.openAPIV3Schema" \
    "$ALL" \
  | jq '
      . as $s
      | {
          "$schema": "http://json-schema.org/draft-07/schema#",
          type: "object",
          properties: (
            ($s.properties // {})
            + {
                apiVersion: { type: "string" },
                kind: { type: "string" },
                metadata: { type: "object" }
              }
          ),
          required: ($s.required // [])
        }
    ' > "${OUT_DIR}/${lc_kind}.json"

  count=$((count + 1))
done

echo "wrote ${count} schema(s) to ${OUT_DIR}"
