#!/usr/bin/env bash
set -euo pipefail
# 97-sshproxy-hook.sh — v1.0.8
# Optional external SSH/SFTP reverse-proxy add-on hook.
# If /opt/gw-sshproxy/gw-sshproxyctl.sh exists and tenant enables SSH proxying,
# this hook applies/removes per-tenant HAProxy TCP listeners for SSH/SFTP services.
#
# Tenant conf keys:
#   SSH_PROXY_MODE=off|on
#
TENANT="${1:-}"
PHASE="${2:-ipsec-up}"
[[ -n "$TENANT" ]] || { echo "Usage: $0 <tenant> [phase]" >&2; exit 1; }

TCONF="/opt/gw-builder/tenants/${TENANT}.conf"
[[ -f "$TCONF" ]] || exit 0

MODE="$(grep -E '^SSH_PROXY_MODE=' "$TCONF" | tail -n1 | cut -d= -f2- || echo off)"
[[ -n "$MODE" ]] || MODE="off"

CTL="/opt/gw-sshproxy/gw-sshproxyctl.sh"
[[ -x "$CTL" ]] || exit 0

case "$PHASE" in
  ipsec-up)
    [[ "$MODE" == "on" ]] || exit 0
    "$CTL" apply "$TENANT" || true
    ;;
  tenant-stop|stop)
    "$CTL" remove "$TENANT" || true
    ;;
  *) exit 0 ;;
esac
