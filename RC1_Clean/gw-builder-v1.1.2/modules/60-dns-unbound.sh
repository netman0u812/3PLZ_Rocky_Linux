#!/usr/bin/env bash
set -euo pipefail
source /opt/gw-builder/gw.conf
source /opt/gw-builder/modules/00-common.sh

tconf="$1"; shift || true
action="${1:-create}"
# shellcheck source=/dev/null
source "$tconf"

ensure_unit() {
  cat >/etc/systemd/system/unbound-tenant@.service <<'EOF'
[Unit]
Description=Unbound DNS Tenant %i (vrf-%i)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/sbin/ip vrf exec vrf-%i /usr/sbin/unbound -d -c /etc/unbound/tenants/%i/unbound.conf
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

create() {
  ensure_unit
  mkdir -p "${UNBOUND_TENANT_DIR}/${TENANT}"

  local cfg="${UNBOUND_TENANT_DIR}/${TENANT}/unbound.conf"
  local local_overrides="${UNBOUND_TENANT_DIR}/${TENANT}/local-overrides.conf"
  local catalog_overrides="$(catalog_dns_rewrites "${TENANT}")"

  ensure_tenant_catalog "${TENANT}"
  ln -sf "${catalog_overrides}" "${local_overrides}"

  cat >"$cfg" <<EOF
server:
  interface: ${DNS_VIP%/*}
  port: 53
  access-control: ${TENANT_NET} allow
  access-control: 0.0.0.0/0 refuse
  verbosity: 1
  hide-identity: yes
  hide-version: yes

  include: "${local_overrides}"

forward-zone:
  name: "${DEFAULT_FORWARD_ZONE}"
  forward-addr: ${DEFAULT_FORWARD_ADDR}
EOF

  [[ -f "$local_overrides" ]] || cat >"$local_overrides" <<'EOF'
# local overrides for catalog VIPs:
# local-data: "sap.outlan.net. A 172.16.X.129"
EOF

  systemctl enable --now "unbound-tenant@${TENANT}" || true
  echo "Tenant DNS ready: unbound-tenant@${TENANT} listening on ${DNS_VIP%/*}:53"
}

delete() {
  systemctl disable --now "unbound-tenant@${TENANT}" 2>/dev/null || true
  rm -rf "${UNBOUND_TENANT_DIR:?}/${TENANT}"
}

if [[ "$action" == "--delete" ]]; then delete; else create; fi
