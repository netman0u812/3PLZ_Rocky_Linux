#!/usr/bin/env bash
set -euo pipefail
source /opt/gw-builder/gw.conf
source /opt/gw-builder/modules/00-common.sh

tconf="$1"; shift || true
action="${1:-create}"
# shellcheck source=/dev/null
source "$tconf"

create() {
  ensure_dirs
  # Create tenant VRF
  if ! ip link show "$VRF_NAME" >/dev/null 2>&1; then
    ip link add "$VRF_NAME" type vrf table "$VRF_TABLE"
    ip link set "$VRF_NAME" up
  fi

  # Create tenant<->core veth
  if ! ip link show "veth-${TENANT}-core" >/dev/null 2>&1; then
    ip link add "veth-${TENANT}-core" type veth peer name "veth-core-${TENANT}"
  fi

  # Attach ends
  ip link set "veth-${TENANT}-core" master "$VRF_NAME" 2>/dev/null || true
  ip link set "veth-core-${TENANT}" master "$CORE_VRF_NAME" 2>/dev/null || true
  ip link set "veth-${TENANT}-core" up
  ip link set "veth-core-${TENANT}" up

  # Assign /30 on veth link: tenant side .1, core side .2
  local net="${TENANT_CORE_LINK_NET%/*}"
  local a b c d
  IFS='.' read -r a b c d <<<"$net"
  local t_ip="${a}.${b}.${c}.$((d+1))"
  local c_ip="${a}.${b}.${c}.$((d+2))"
  ip addr add "${t_ip}/30" dev "veth-${TENANT}-core" 2>/dev/null || true
  ip addr add "${c_ip}/30" dev "veth-core-${TENANT}" 2>/dev/null || true

  # Add service VIPs (/32) on loopback (visible in tenant VRF when running ip vrf exec)
  ip addr add "$SQUID_VIP" dev lo 2>/dev/null || true
  ip addr add "$DNS_VIP" dev lo 2>/dev/null || true
  ip addr add "$PORTAL_VIP" dev lo 2>/dev/null || true

  # Ensure loopback is up
  ip link set lo up

  echo "Tenant VRF ready: $VRF_NAME table=$VRF_TABLE"
  echo "Tenant subnet: $TENANT_NET (lower/25=$TENANT_LOWER25 upper/25=$TENANT_UPPER25)"
}

delete() {
  ip link del "veth-${TENANT}-core" 2>/dev/null || true
  ip link del "$VRF_NAME" 2>/dev/null || true
}

if [[ "$action" == "--delete" ]]; then delete; else create; fi
