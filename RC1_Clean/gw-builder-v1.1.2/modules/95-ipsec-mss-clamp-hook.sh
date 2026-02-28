#!/usr/bin/env bash
set -euo pipefail
# 95-ipsec-mss-clamp-hook.sh — v1.0.3
TENANT="${1:-}"
PHASE="${2:-ipsec-up}"
[[ -n "$TENANT" ]] || { echo "Usage: $0 <tenant>" >&2; exit 1; }
GWCTL="/opt/gw-builder/gwctl.sh"

if [[ "$PHASE" != "ipsec-up" ]]; then
  exit 0
fi
if [[ -x "$GWCTL" ]]; then
  "$GWCTL" ipsec-mss-clamp apply "$TENANT" || true
else
  echo "gwctl not found at $GWCTL; skipping MSS clamp apply." >&2
fi
