#!/usr/bin/env bash
set -euo pipefail
TENANT="${1:-}"
PHASE="${2:-}"
MODDIR="/opt/gw-builder/modules"
[[ -n "$TENANT" && -n "$PHASE" ]] || { echo "Usage: $0 <tenant> <phase>" >&2; exit 1; }
[[ -d "$MODDIR" ]] || exit 0
for f in "$MODDIR"/*.sh; do
  [[ -x "$f" ]] || continue
  "$f" "$TENANT" "$PHASE" || true
done
