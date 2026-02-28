#!/usr/bin/env bash
set -euo pipefail
source /opt/gw-builder/gw.conf
source /opt/gw-builder/modules/00-common.sh

# Core setup:
# - Create vrf-core and move LAN_IF into it
# - Create core<->default veth transit
# - Assign IPs on veth endpoints

action="${2:-create}"

create() {
  ensure_dirs

  # Create vrf-core if missing
  if ! ip link show "$CORE_VRF_NAME" >/dev/null 2>&1; then
    ip link add "$CORE_VRF_NAME" type vrf table "$CORE_VRF_TABLE"
    ip link set "$CORE_VRF_NAME" up
  fi

  # Move LAN_IF into vrf-core
  ip link set "$LAN_IF" master "$CORE_VRF_NAME" 2>/dev/null || true
  ip link set "$LAN_IF" up

  # Create core<->default veth pair
  if ! ip link show veth-core-default >/dev/null 2>&1; then
    ip link add veth-core-default type veth peer name veth-default-core
  fi

  # Attach veth-core-default into vrf-core; keep veth-default-core in default VRF
  ip link set veth-core-default master "$CORE_VRF_NAME" 2>/dev/null || true
  ip link set veth-core-default up
  ip link set veth-default-core up

  # Assign /30 addresses
  # CORE_DEFAULT_VETH_NET = 192.168.20.0/30 -> .1 default side, .2 core side
  local net="${CORE_DEFAULT_VETH_NET%/*}"
  local a b c d
  IFS='.' read -r a b c d <<<"$net"
  local def_ip="${a}.${b}.${c}.$((d+1))"
  local core_ip="${a}.${b}.${c}.$((d+2))"

  ip addr add "${def_ip}/30" dev veth-default-core 2>/dev/null || true
  ip addr add "${core_ip}/30" dev veth-core-default 2>/dev/null || true

  echo "Core VRF ready: $CORE_VRF_NAME (table $CORE_VRF_TABLE) on $LAN_IF"
  echo "Transit veth: default(${def_ip}/30) <-> core(${core_ip}/30)"
}

delete() {
  ip link del veth-core-default 2>/dev/null || true
  ip link del "$CORE_VRF_NAME" 2>/dev/null || true
}

if [[ "$action" == "--delete" ]]; then delete; else create; fi
