#!/usr/bin/env bash
set -euo pipefail
source /opt/gw-builder/gw.conf
source /opt/gw-builder/modules/00-common.sh

# Setup tier-2 proxies:
# - squid@inet in default VRF listening on veth-default-core:3128
# - squid@core in vrf-core listening on veth-core-default:3129

action="${2:-create}"

ensure_units() {
  cat >/etc/systemd/system/squid-vrf@.service <<'EOF'
[Unit]
Description=Squid in VRF %i
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
ExecStartPre=/usr/bin/mkdir -p /var/log/squid-%i /var/spool/squid-%i
ExecStartPre=/usr/sbin/squid -Nz -f /etc/squid/instances/%i/squid.conf
ExecStart=/usr/sbin/ip vrf exec %i /usr/sbin/squid -f /etc/squid/instances/%i/squid.conf
ExecReload=/usr/sbin/squid -k reconfigure -f /etc/squid/instances/%i/squid.conf
ExecStop=/usr/sbin/squid -k shutdown -f /etc/squid/instances/%i/squid.conf
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

create() {
  ensure_dirs
  ensure_units

  # Determine veth IPs
  local net="${CORE_DEFAULT_VETH_NET%/*}"
  local a b c d
  IFS='.' read -r a b c d <<<"$net"
  local def_ip="${a}.${b}.${c}.$((d+1))"
  local core_ip="${a}.${b}.${c}.$((d+2))"

  # squid@inet instance (default VRF)
  mkdir -p "${SQUID_INST_DIR}/inet"
  cat >"${SQUID_INST_DIR}/inet/squid.conf" <<EOF
http_port ${def_ip}:3128
acl all src all
http_access allow all
cache deny all
access_log stdio:/var/log/squid/inet-access.log
cache_log /var/log/squid/inet-cache.log
EOF
  systemctl enable --now squid 2>/dev/null || true
  systemctl restart squid 2>/dev/null || true

  # squid@core instance (vrf-core)
  mkdir -p "${SQUID_INST_DIR}/${CORE_VRF_NAME}"
  cat >"${SQUID_INST_DIR}/${CORE_VRF_NAME}/squid.conf" <<EOF
http_port ${core_ip}:3129
acl all src all
http_access allow all
cache deny all
access_log stdio:/var/log/squid/${CORE_VRF_NAME}-access.log
cache_log /var/log/squid/${CORE_VRF_NAME}-cache.log
EOF
  systemctl enable --now "squid-vrf@${CORE_VRF_NAME}" || true
  systemctl restart "squid-vrf@${CORE_VRF_NAME}" || true

  echo "Tier-2 proxies configured:"
  echo "  squid@inet listening ${def_ip}:3128 (default VRF)"
  echo "  squid-vrf@${CORE_VRF_NAME} listening ${core_ip}:3129 (vrf-core)"
}

delete() {
  systemctl disable --now "squid-vrf@${CORE_VRF_NAME}" 2>/dev/null || true
  rm -rf "${SQUID_INST_DIR}/inet" "${SQUID_INST_DIR}/${CORE_VRF_NAME}"
}

if [[ "$action" == "--delete" ]]; then delete; else create; fi
