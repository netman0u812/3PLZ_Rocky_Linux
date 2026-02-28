#!/usr/bin/env bash
set -euo pipefail
# 98-sshproxy-firewall-hook.sh — v1.0.8
#
# Enforces a per-tenant nftables allow-list for outbound SSH proxy destinations.
# This prevents using the SSH proxy plane as a pivot to arbitrary hosts.
#
# Tenant conf keys:
#   SSH_PROXY_MODE=on|off
#   SSH_PROXY_UPSTREAM_ALLOWLIST=ip1,ip2,...
# Optional:
#   SSH_PROXY_EGRESS_IF=eth0     (if set, scope enforcement to that egress IF)
#
TENANT="${1:-}"
PHASE="${2:-ipsec-up}"
[[ -n "$TENANT" ]] || exit 0

TCONF="/opt/gw-builder/tenants/${TENANT}.conf"
[[ -f "$TCONF" ]] || exit 0

MODE="$(grep -E '^SSH_PROXY_MODE=' "$TCONF" | tail -n1 | cut -d= -f2- || echo off)"
ALLOW="$(grep -E '^SSH_PROXY_UPSTREAM_ALLOWLIST=' "$TCONF" | tail -n1 | cut -d= -f2- || true)"
EIF="$(grep -E '^SSH_PROXY_EGRESS_IF=' "$TCONF" | tail -n1 | cut -d= -f2- || true)"

[[ "$MODE" == "on" ]] || exit 0
[[ -n "$ALLOW" ]] || exit 0

TABLE="gw_ssh_${TENANT}"
CHAIN="ssh_egress"

cleanup(){
  nft delete table inet "$TABLE" 2>/dev/null || true
}

if [[ "$PHASE" == "tenant-stop" || "$PHASE" == "stop" ]]; then
  cleanup
  exit 0
fi

# Create table + chain (idempotent)
nft list table inet "$TABLE" >/dev/null 2>&1 || nft add table inet "$TABLE"
nft list chain inet "$TABLE" "$CHAIN" >/dev/null 2>&1 || nft "add chain inet $TABLE $CHAIN { type filter hook output priority 0; policy accept; }"

# Remove prior tenant rules (by comment)
while read -r handle; do
  [[ -n "$handle" ]] || continue
  nft delete rule inet "$TABLE" "$CHAIN" handle "$handle" 2>/dev/null || true
done < <(nft -a list chain inet "$TABLE" "$CHAIN" 2>/dev/null | awk -v t="$TENANT" '/comment "gw-ssh:'"$TENANT"'"/ {print $NF}')

# Add allow rules
IFS=',' read -ra IPS <<< "$ALLOW"
for ip in "${IPS[@]}"; do
  ip="$(echo "$ip" | xargs)"
  [[ -n "$ip" ]] || continue
  if [[ -n "$EIF" ]]; then
    nft add rule inet "$TABLE" "$CHAIN" oifname "$EIF" ip daddr "$ip" tcp dport 22 accept comment "gw-ssh:${TENANT}"
  else
    nft add rule inet "$TABLE" "$CHAIN" ip daddr "$ip" tcp dport 22 accept comment "gw-ssh:${TENANT}"
  fi
done

# Add drop rule only when scoped to egress IF (safer)
if [[ -n "$EIF" ]]; then
  set_elems="$(printf "%s, " "${IPS[@]}" | sed 's/, $//')"
  nft add rule inet "$TABLE" "$CHAIN" oifname "$EIF" tcp dport 22 ip daddr != { $set_elems } drop comment "gw-ssh:${TENANT}"
fi
