#!/usr/bin/env bash
set -euo pipefail
source /opt/gw-builder/gw.conf
source /opt/gw-builder/modules/00-common.sh

tconf="$1"; shift || true
action="${1:-create}"
# shellcheck source=/dev/null
source "$tconf"

ensure_unit() {
  cat >/etc/systemd/system/squid-tenant@.service <<'EOF'
[Unit]
Description=Squid Tenant %i (vrf-%i)
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
ExecStartPre=/usr/bin/mkdir -p /var/log/gw-builder/%i/squid /var/spool/squid-%i
ExecStartPre=/usr/sbin/squid -Nz -f /etc/squid/tenants/%i/squid.conf
ExecStart=/usr/sbin/ip vrf exec vrf-%i /usr/sbin/squid -f /etc/squid/tenants/%i/squid.conf
ExecReload=/usr/sbin/squid -k reconfigure -f /etc/squid/tenants/%i/squid.conf
ExecStop=/usr/sbin/squid -k shutdown -f /etc/squid/tenants/%i/squid.conf
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

create() {
  ensure_dirs
  ensure_unit
  mkdir -p "${SQUID_TENANT_DIR}/${TENANT}"

  # Determine tier-2 peers
  local net="${CORE_DEFAULT_VETH_NET%/*}"
  local a b c d
  IFS='.' read -r a b c d <<<"$net"
  local inet_peer="${a}.${b}.${c}.$((d+1))"
  local core_peer="${a}.${b}.${c}.$((d+2))"

  # Squid ports:
  # 3128 explicit proxy; 3129 intercept (optional for transparent HTTP)
  local cfg="${SQUID_TENANT_DIR}/${TENANT}/squid.conf"
  cat >"$cfg" <<EOF
http_port ${SQUID_VIP%/*}:3128
# Intercept port for optional transparent HTTP
http_port ${SQUID_VIP%/*}:3129 intercept

acl tenant_net src ${TENANT_NET}
http_access allow tenant_net
http_access deny all

# Peers
cache_peer ${core_peer} parent 3129 0 no-query default login=PASSTHRU name=core
cache_peer ${inet_peer} parent 3128 0 no-query default login=PASSTHRU name=inet

# Prefer internal for RFC1918 destinations; else use inet
acl rfc1918 dst 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16
cache_peer_access core allow rfc1918
cache_peer_access core deny all
cache_peer_access inet allow all

cache deny all
access_log stdio:/var/log/gw-builder/${TENANT}/squid/access.log
cache_log /var/log/gw-builder/${TENANT}/squid/cache.log
EOF

  systemctl enable --now "squid-tenant@${TENANT}" || true
  systemctl restart "squid-tenant@${TENANT}" || true

  # Transparent mode (HTTP intercept) optional: rules are installed by firewall wrapper later.
  echo "Tenant squid configured: ${SQUID_VIP%/*}:3128 (explicit), :3129 (intercept)"
  echo "SQUID_MODE=${SQUID_MODE} (transparent HTTP requires redirect rules; not enabled automatically in v0.4.2)"
}

delete() {
  systemctl disable --now "squid-tenant@${TENANT}" 2>/dev/null || true
  rm -rf "${SQUID_TENANT_DIR:?}/${TENANT}"
}

if [[ "$action" == "--delete" ]]; then delete; else create; fi
