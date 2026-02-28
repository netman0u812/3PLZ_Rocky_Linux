#!/usr/bin/env bash
set -euo pipefail
# 96-inspection-export-hook.sh — v1.0.5
TENANT="${1:-}"
PHASE="${2:-ipsec-up}"
[[ -n "$TENANT" ]] || { echo "Usage: $0 <tenant> [phase]" >&2; exit 1; }

TCONF="/opt/gw-builder/tenants/${TENANT}.conf"
[[ -f "$TCONF" ]] || exit 0

MODE="$(grep -E '^INSPECTION_EXPORT_MODE=' "$TCONF" | tail -n1 | cut -d= -f2- || echo off)"
[[ -n "$MODE" ]] || MODE="off"

INSPECTCTL="/opt/gw-inspection/gw-inspectctl.sh"
[[ -x "$INSPECTCTL" ]] || exit 0

case "$PHASE" in
  ipsec-up)
    if [[ "$MODE" == "tap" || "$MODE" == "tap+nflog" ]]; then
      "$INSPECTCTL" apply "$TENANT" || true
    fi
    ;;
  tenant-stop|stop)
    "$INSPECTCTL" remove "$TENANT" || true
    ;;
  *) exit 0 ;;
esac
