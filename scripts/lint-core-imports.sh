#!/bin/bash
# QuickyCore may import only Foundation, Security and Observation (docs/design.md, decision 1).
set -euo pipefail
cd "$(dirname "$0")/.."
bad=$(grep -rnE '^\s*(@preconcurrency\s+|@_exported\s+)?import\s+' Sources/QuickyCore \
  | grep -vE 'import\s+(Foundation|Security|Observation)\s*$' || true)
if [[ -n "$bad" ]]; then
  echo "QuickyCore imports outside Foundation/Security/Observation:" >&2
  echo "$bad" >&2
  exit 1
fi
