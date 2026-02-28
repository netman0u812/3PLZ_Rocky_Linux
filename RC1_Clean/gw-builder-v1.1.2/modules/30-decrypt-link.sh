#!/usr/bin/env bash
set -euo pipefail
# 30-decrypt-link.sh — v1.0.5
TENANT="${1:-}"
VRF="${2:-}"
[[ -n "$TENANT" && -n "$VRF" ]] || { echo "Usage: $0 <tenant> <vrf-name>" >&2; exit 1; }

TCONF="/opt/gw-builder/tenants/${TENANT}.conf"
[[ -f "$TCONF" ]] || { echo "Tenant conf not found: $TCONF" >&2; exit 1; }

DECRYPT_IFACE="$(grep -E '^DECRYPT_IFACE=' "$TCONF" | tail -n1 | cut -d= -f2- || true)"
[[ -n "$DECRYPT_IFACE" ]] || DECRYPT_IFACE="dec-${TENANT}"
CORE_IFACE="${DECRYPT_IFACE}-core"

if ! ip link show "$DECRYPT_IFACE" >/dev/null 2>&1; then
  ip link add "$DECRYPT_IFACE" type veth peer name "$CORE_IFACE"
fi

ip link set "$DECRYPT_IFACE" master "$VRF" || true
ip link set "$DECRYPT_IFACE" up
ip link set "$CORE_IFACE" up
exit 0
