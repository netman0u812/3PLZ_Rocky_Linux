#!/usr/bin/env bash
set -euo pipefail
source /opt/gw-builder/gw.conf
source /opt/gw-builder/modules/00-common.sh

tconf="$1"; shift || true
action="${1:-create}"
# shellcheck source=/dev/null
source "$tconf"

ensure_updown() {
  if [[ -x "$UPDOWN_SCRIPT" ]]; then return 0; fi
  cat >"$UPDOWN_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# strongSwan updown script for route-based VTI (VTI created in default namespace then moved to VRF)
# Env vars from strongSwan: PLUTO_*.
# Requires: TENANT, VRF_NAME, VTI_IF, VTI_LOCAL_CIDR, VTI_REMOTE_IP, VTI_KEY

TENANT="${TENANT:-}"
VRF_NAME="${VRF_NAME:-}"
VTI_IF="${VTI_IF:-}"
VTI_LOCAL_CIDR="${VTI_LOCAL_CIDR:-}"
VTI_REMOTE_IP="${VTI_REMOTE_IP:-}"
VTI_KEY="${VTI_KEY:-}"

# Called with: up-client / down-client (and others)
case "${PLUTO_VERB:-}" in
  up-client|up-host)
    ip link add "$VTI_IF" type vti local "${PLUTO_ME:-0.0.0.0}" remote "${PLUTO_PEER:-0.0.0.0}" key "$VTI_KEY" 2>/dev/null || true
    ip link set "$VTI_IF" up
    ip addr add "$VTI_LOCAL_CIDR" dev "$VTI_IF" 2>/dev/null || true
    ip link set "$VTI_IF" master "$VRF_NAME" 2>/dev/null || true
    # Route to peer VTI remote as /32
    ip vrf exec "$VRF_NAME" ip route replace "$VTI_REMOTE_IP/32" dev "$VTI_IF" 2>/dev/null || true
    ;;
  down-client|down-host)
    ip link del "$VTI_IF" 2>/dev/null || true
    ;;
esac
EOF
  chmod +x "$UPDOWN_SCRIPT"
}

create() {
  ensure_dirs
  ensure_updown

  mkdir -p /etc/ipsec.d/tenants

  local vti_if="vti-${TENANT}"
  local vti_key="${TENANT_INDEX}"

  cat >/etc/ipsec.d/tenants/${TENANT}.conf <<EOF
conn ${TENANT}
  keyexchange=ikev2
  type=tunnel
  authby=psk
  ike=aes256-sha256-modp2048!
  esp=aes256-sha256!
  dpdaction=restart
  dpddelay=10s
  rekey=yes
  left=%defaultroute
  leftid=${IKE_LOOPBACK%/*}
  leftsubnet=0.0.0.0/0
  right=${PEER_PUBLIC_IP}
  rightsubnet=0.0.0.0/0
  mark=${FWMARK}
  auto=add
  leftupdown=${UPDOWN_SCRIPT}

  # Export vars for updown
  leftupdownargs=TENANT=${TENANT} VRF_NAME=${VRF_NAME} VTI_IF=${vti_if} VTI_LOCAL_CIDR=${VTI_LOCAL} VTI_REMOTE_IP=${VTI_REMOTE} VTI_KEY=${vti_key}
EOF

  cat >/etc/ipsec.d/tenants/${TENANT}.secrets <<EOF
${IKE_LOOPBACK%/*} ${PEER_PUBLIC_IP} : PSK "CHANGEME-${TENANT}"
EOF
  chmod 600 /etc/ipsec.d/tenants/${TENANT}.secrets

  # Ensure /etc/ipsec.conf includes tenant directory once
  if [[ -f "$IPSEC_CONF" ]]; then
    grep -q 'ipsec.d/tenants' "$IPSEC_CONF" || echo "include /etc/ipsec.d/tenants/*.conf" >>"$IPSEC_CONF"
  else
    cat >"$IPSEC_CONF" <<'EOF'
config setup
  uniqueids=no
include /etc/ipsec.d/tenants/*.conf
EOF
  fi

  systemctl restart strongswan || true
  echo "IPsec tenant config generated: /etc/ipsec.d/tenants/${TENANT}.conf"
  echo "Set PSK in: /etc/ipsec.d/tenants/${TENANT}.secrets"
}

delete() {
  rm -f /etc/ipsec.d/tenants/${TENANT}.conf /etc/ipsec.d/tenants/${TENANT}.secrets
  ip link del "vti-${TENANT}" 2>/dev/null || true
  systemctl restart strongswan || true
}

if [[ "$action" == "--delete" ]]; then delete; else create; fi
