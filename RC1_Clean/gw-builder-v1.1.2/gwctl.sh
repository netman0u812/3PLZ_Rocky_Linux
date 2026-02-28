#!/usr/bin/env bash
set -euo pipefail

VERSION="1.1.2"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${ROOT_DIR}/gw.conf"

# shellcheck source=/dev/null
source "${ROOT_DIR}/modules/00-common.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/modules/85-nginx-mtls-wrapper.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/modules/72-portal-enroll.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/modules/75-inspection-export.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/modules/71-pki-revocation.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/modules/73-portal-signer.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/modules/86-nginx-forwardproxy-mtls.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/modules/74-crl-refresh-timer.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/modules/87-nginx-authz.sh"

usage() {
  cat <<EOF
gwctl.sh v${VERSION}

Core:
  $0 -h | --help
  $0 check
  $0 preflight
  $0 init
  $0 core-setup
  $0 fw-apply

Tenant:
  $0 add-tenant <tenant> --peer <peer_public_ip>
  $0 del-tenant <tenant>
  $0 tenant-delete <tenant>   # alias of del-tenant (full cleanup)
  $0 show-tenant <tenant>
  $0 list-tenants
  $0 tenant-start <tenant>
  $0 tenant-stop <tenant>
  $0 tenant-restart <tenant>
  $0 tenant-status <tenant>
  $0 tenant-health <tenant>
  $0 tenant-export <tenant>
  $0 diag <tenant>

Routing:
  $0 apply-bgp <tenant>

PKI:
  $0 pki-init
  $0 pki-tenant <tenant>
  $0 issue-user <tenant> <email>
  $0 issue-app-cert <tenant> <fqdn>

Catalog (Envoy reverse proxy):
  $0 add-app <tenant> <fqdn> <upstream_ip:port> [inspect=inherit|on|off] [auto_cert=yes|no]
  $0 del-app <tenant> <fqdn>
  $0 list-apps <tenant>

NGINX mTLS + Portal:
  $0 mtls-enable <tenant> [crl=on|off]
  $0 mtls-reload <tenant>
  $0 portal-enable <tenant>
  $0 portal-disable <tenant>
  $0 otp-create <tenant> <email> [ttl_seconds=900]

Inspection Export (Phase 1):
  $0 inspect-export enable|disable

Revocation:
  $0 revoke-user <tenant> <email>
  $0 gen-crl <tenant>
  $0 publish-crl <tenant>
  $0 ocsp-note

Forward Proxy mTLS:
  $0 fwdproxy-enable <tenant> [listen_port=8443]
  $0 fwdproxy-disable <tenant>

Authorization (Service Catalog):
  $0 app-allow <tenant> <email|*> <fqdn>
  $0 app-deny  <tenant> <email|*> <fqdn>

CRL Automation:
  $0 crl-refresh <tenant>
  $0 crl-timer-enable <tenant>
  $0 crl-timer-disable <tenant>

Portal Signer:
  $0 portal-signer-loop <tenant> [interval_seconds=2]

EOF
}

require_conf() {
  [[ -f "$CONF" ]] || die "Missing config: $CONF"
  # shellcheck source=/dev/null
  source "$CONF"
}


cmd_preflight() {
  require_conf
  echo "[preflight] checking commands/packages..."
  local cmds=(ip nft systemctl awk sed grep tar)
  for c in "${cmds[@]}"; do command -v "$c" >/dev/null || die "Missing command: $c"; done

  # Packages (best-effort)
  local pkgs=(strongswan frr unbound squid nginx)
  for p in "${pkgs[@]}"; do
    rpm -q "$p" >/dev/null 2>&1 || echo "[preflight] WARN: rpm package not installed: $p"
  done

  echo "[preflight] checking kernel modules..."
  for m in vrf ip_vti vxlan; do
    modprobe "$m" >/dev/null 2>&1 || echo "[preflight] WARN: could not modprobe $m (may be built-in)"
  done

  echo "[preflight] checking interfaces from gw.conf..."
  [[ -n "${WAN_IF:-}" && -n "${LAN_IF:-}" ]] || die "WAN_IF/LAN_IF not set in gw.conf"
  ip link show "$WAN_IF" >/dev/null 2>&1 || die "WAN_IF not found: $WAN_IF"
  ip link show "$LAN_IF" >/dev/null 2>&1 || die "LAN_IF not found: $LAN_IF"

  echo "[preflight] OK"
}

cmd_tenant_health() {
  require_conf
  local tenant="$1"
  local tconf; tconf="$(tenant_conf_path "$tenant")"
  [[ -f "$tconf" ]] || die "Tenant not found: $tenant"
  # shellcheck source=/dev/null
  source "$tconf"

  local ok=1
  echo "== Tenant health: $tenant =="

  # VRF
  if ip link show "$TENANT_VRF" >/dev/null 2>&1; then
    echo "[OK] VRF present: $TENANT_VRF"
  else
    echo "[FAIL] VRF missing: $TENANT_VRF"; ok=0
  fi

  # VTI
  if ip link show "$VTI_IF" >/dev/null 2>&1; then
    echo "[OK] VTI present: $VTI_IF"
  else
    echo "[FAIL] VTI missing: $VTI_IF"; ok=0
  fi

  # BGP (best-effort)
  if command -v vtysh >/dev/null 2>&1; then
    if vtysh -c "show bgp vrf ${TENANT_VRF} summary" 2>/dev/null | grep -q "Estab"; then
      echo "[OK] BGP neighbor established (vrf ${TENANT_VRF})"
    else
      echo "[WARN] BGP not established (or not configured)"; 
    fi
  else
    echo "[WARN] vtysh not present; skipping BGP check"
  fi

  # DNS (tenant resolver)
  local dns_ip="${TENANT_DNS_IP:-}"
  if [[ -n "$dns_ip" ]] && command -v dig >/dev/null 2>&1; then
    if ip vrf exec "$TENANT_VRF" dig @"$dns_ip" localhost >/dev/null 2>&1; then
      echo "[OK] DNS responding on $dns_ip"
    else
      echo "[WARN] DNS not responding on $dns_ip"
    fi
  else
    echo "[INFO] DNS check skipped (no dig or TENANT_DNS_IP)"
  fi

  # Squid
  if systemctl is-active --quiet "squid-tenant@${tenant}"; then
    echo "[OK] squid-tenant@${tenant} active"
  else
    echo "[WARN] squid-tenant@${tenant} not active"
  fi

  # NGINX mTLS
  if systemctl is-active --quiet "nginx-mtls@${tenant}"; then
    echo "[OK] nginx-mtls@${tenant} active"
  else
    echo "[WARN] nginx-mtls@${tenant} not active"
  fi

  # PKI presence
  if [[ -d "${PKI_DIR}/${tenant}" ]]; then
    echo "[OK] PKI dir present: ${PKI_DIR}/${tenant}"
  else
    echo "[WARN] PKI dir missing: ${PKI_DIR}/${tenant}"
  fi

  # nft guardrail
  if nft list ruleset 2>/dev/null | grep -q "gw_${tenant}"; then
    echo "[OK] nft tenant rules present (gw_${tenant})"
  else
    echo "[WARN] nft tenant rules not found (gw_${tenant})"
  fi

  [[ "$ok" -eq 1 ]] && echo "HEALTH: PASS" || (echo "HEALTH: FAIL"; return 1)
}

cmd_tenant_export() {
  require_conf
  local tenant="$1"
  local tconf; tconf="$(tenant_conf_path "$tenant")"
  [[ -f "$tconf" ]] || die "Tenant not found: $tenant"
  local out="/var/tmp/${tenant}-export-$(date +%Y%m%d%H%M%S).tar.gz"
  mkdir -p /var/tmp

  local tmpdir; tmpdir="$(mktemp -d)"
  cp -a "$tconf" "$tmpdir/" || true
  [[ -d "${APPS_DIR}/${tenant}" ]] && cp -a "${APPS_DIR}/${tenant}" "$tmpdir/apps-${tenant}" || true
  [[ -d "${CATALOG_DIR}/${tenant}" ]] && cp -a "${CATALOG_DIR}/${tenant}" "$tmpdir/catalog-${tenant}" || true
  [[ -d "${TENANTS_DIR}" ]] && true

  # Public-only PKI artifacts (no private keys)
  if [[ -d "${PKI_DIR}/${tenant}" ]]; then
    mkdir -p "$tmpdir/pki-${tenant}"
    find "${PKI_DIR}/${tenant}" -type f \( -name "*.crt" -o -name "*.pem" -o -name "*.crl" -o -name "*.txt" \) -maxdepth 4 -print0 2>/dev/null | xargs -0 -I{} cp -a "{}" "$tmpdir/pki-${tenant}/" 2>/dev/null || true
  fi

  tar -czf "$out" -C "$tmpdir" .
  rm -rf "$tmpdir"
  echo "Export created: $out"
}

cmd_tenant_delete() {
  require_conf
  local tenant="$1"
  local tconf; tconf="$(tenant_conf_path "$tenant")"
  [[ -f "$tconf" ]] || die "Tenant not found: $tenant"

  echo "Stopping per-tenant services (best-effort)..."
  local units=(
    "envoy-tenant@${tenant}"
    "squid-tenant@${tenant}"
    "unbound-tenant@${tenant}"
    "nginx-mtls@${tenant}"
    "nginx-fwdproxy@${tenant}"
    "portal-enroll@${tenant}"
    "crl-refresh@${tenant}"
    "sshproxy@${tenant}"
  )
  for u in "${units[@]}"; do systemctl disable --now "$u" 2>/dev/null || true; done

  # Module-based teardown (existing)
  run_module "40-tier1-squid" "$tconf" --delete || true
  run_module "60-dns-unbound" "$tconf" --delete || true
  run_module "70-pki" "$tconf" --delete || true
  run_module "30-bgp-frr" "$tconf" --delete || true
  run_module "21-ipsec-managed" "$tconf" --delete || true
  run_module "10-tenant-vrf" "$tconf" --delete || true

  # File/dir cleanup
  rm -f "$tconf" 2>/dev/null || true
  deallocate_tenant_index "$tenant" "$TENANT_INDEX_FILE" || true

  rm -rf "${APPS_DIR}/${tenant}" 2>/dev/null || true
  rm -rf "${CATALOG_DIR}/${tenant}" 2>/dev/null || true
  rm -rf "${SQUID_TENANT_DIR}/${tenant}" 2>/dev/null || true
  rm -rf "${UNBOUND_TENANT_DIR}/${tenant}" 2>/dev/null || true
  rm -rf "${ENVOY_TENANT_DIR}/${tenant}" 2>/dev/null || true
  rm -rf "${TLS_DIR}/${tenant}" 2>/dev/null || true
  rm -rf "${PKI_DIR}/${tenant}" 2>/dev/null || true
  rm -rf "${LOG_DIR}/${tenant}" 2>/dev/null || true

  rm -f "${FRR_SNIPPETS_DIR}/${tenant}.bgp.conf" 2>/dev/null || true
  rm -f "${NFT_DIR}/30-tenants/${tenant}.nft" 2>/dev/null || true

  # Re-apply baseline firewall
  run_module "15-firewall-nft" "" apply || true

  echo "Tenant deleted (full cleanup): $tenant"
}

tenant_conf_path() { echo "${TENANTS_DIR}/${1}.conf"; }


tenant_conf_set_kv() {
  local tconf="$1" key="$2" val="$3"
  if grep -qE "^${key}=" "$tconf"; then
    sed -i "s|^${key}=.*|${key}=\"${val}\"|g" "$tconf"
  else
    echo "${key}=\"${val}\"" >>"$tconf"
  fi
}


cmd_check() { require_conf; check_requirements; }

cmd_init() {
  require_conf
  prompt_for_interfaces_if_needed "$CONF"
  # shellcheck source=/dev/null
  source "$CONF"
  ensure_dirs
  ensure_sysctls
  ensure_packages
  ensure_services
  echo "Init complete. WAN_IF=$WAN_IF LAN_IF=$LAN_IF"
}

cmd_core_setup() {
  require_conf
  ensure_dirs
  run_module "05-core" ""
  run_module "55-tier2-proxies" ""
  run_module "15-firewall-nft" "" apply
  echo "Core setup complete."
}

cmd_fw_apply() { require_conf; run_module "15-firewall-nft" "" apply; }

cmd_add_tenant() {
  require_conf
  local tenant="$1"; shift
  local peer_ip=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --peer) peer_ip="$2"; shift 2;;
      "ipsec-mss-clamp") cmd_ipsec_mss_clamp "${2:-}" "${3:-}" ;;
  *) die "Unknown arg: $1";;
    esac
  done
  [[ -n "$tenant" && -n "$peer_ip" ]] || die "Usage: add-tenant <tenant> --peer <peer_public_ip>"

  local tconf="${TENANTS_DIR}/${tenant}.conf"
  [[ ! -f "$tconf" ]] || die "Tenant already exists: $tenant"

  # Create per-tenant catalog + log directories (MVG canonical registry)
  ensure_tenant_catalog "$tenant"
  ensure_tenant_logdirs "$tenant"

  local idx; idx="$(allocate_tenant_index "$tenant" "$TENANT_INDEX_FILE")"

  echo "Tenant build options for $tenant:"
  read -r -p " Squid mode [${DEFAULT_SQUID_MODE}] explicit|transparent|both: " squid_mode
  squid_mode="${squid_mode:-$DEFAULT_SQUID_MODE}"

  read -r -p " Firewall mode [${DEFAULT_FW_MODE}] permit-all|enforced: " fw_mode
  fw_mode="${fw_mode:-$DEFAULT_FW_MODE}"

  read -r -p " Reverse proxy inspect default [${DEFAULT_REVPROXY_INSPECT}] on|off: " rp_inspect
  rp_inspect="${rp_inspect:-$DEFAULT_REVPROXY_INSPECT}"

  read -r -p " Reverse proxy tap mode [${DEFAULT_TAP_MODE}] logs|tap: " tap_mode
  tap_mode="${tap_mode:-$DEFAULT_TAP_MODE}"

  local ike_lo egress_id vti_net vti_local vti_remote tenant24
  ike_lo="$(alloc_host_from_pool24 "$IKE_LOOPBACK_POOL_CIDR" "$idx")"
  egress_id="$(alloc_host_from_pool24 "$EGRESS_ID_POOL_CIDR" "$idx")"

  vti_net="$(alloc_vti_30_from_pool "$VTI_POOL_CIDR" "$idx")"
  vti_local="$(vti_local_ip "$vti_net")"
  vti_remote="$(vti_remote_ip "$vti_net")"

  tenant24="$(alloc_tenant_subnet24 "$TENANT_NET_BASE_CIDR" "$idx")"
  local lower25 upper25
  read -r lower25 upper25 <<<"$(split_24_to_25s "$tenant24")"

  local squid_vip portal_vip dns_vip
  squid_vip="$(host_in_subnet "$lower25" 1)"
  portal_vip="$(host_in_subnet "$lower25" 2)"
  dns_vip="$(host_in_subnet "$lower25" 3)"

  local table=$((VRF_TABLE_BASE + idx))
  local mark; mark="$(printf "0x%x" $(( (FWMARK_BASE_DEC) + idx )))"

  cat >"$tconf" <<EOF
TENANT="$tenant"
TENANT_INDEX=$idx
PEER_PUBLIC_IP="$peer_ip"

VRF_NAME="vrf-$tenant"
VRF_TABLE=$table
FWMARK="$mark"

IKE_LOOPBACK="${ike_lo}/32"
EGRESS_ID="${egress_id}/32"

VTI_NET="$vti_net"
VTI_LOCAL="${vti_local}/30"
VTI_REMOTE="${vti_remote}"

TENANT_NET="${tenant24}"
TENANT_LOWER25="${lower25}"
TENANT_UPPER25="${upper25}"

SQUID_VIP="${squid_vip}/32"
PORTAL_VIP="${portal_vip}/32"
DNS_VIP="${dns_vip}/32"

TENANT_CORE_LINK_NET="$(alloc_veth_30_from_pool "$TENANT_CORE_VETH_POOL_CIDR" "$idx")"

SQUID_MODE="${squid_mode}"
FW_MODE="${fw_mode}"
REVPROXY_INSPECT="${rp_inspect}"
TAP_MODE="${tap_mode}"
EOF

  run_module "10-tenant-vrf" "$tconf"
  run_module "21-ipsec-managed" "$tconf"
  run_module "30-bgp-frr" "$tconf"
  run_module "70-pki" "$tconf"
  run_module "60-dns-unbound" "$tconf"
  run_module "40-tier1-squid" "$tconf"
  run_module "15-firewall-nft" "$tconf" apply

  echo "Tenant created: $tenant"
  echo "Next:"
  echo "  1) Set PSK in /etc/ipsec.d/tenants/${tenant}.secrets"
  echo "  2) Apply BGP: $0 apply-bgp $tenant"
  echo "  3) Start tenant services: $0 tenant-start $tenant"
}

cmd_del_tenant() {
  cmd_tenant_delete "$@"
}

cmd_apply_bgp() {
  require_conf
  local tenant="$1"
  local f="${FRR_SNIPPETS_DIR}/${tenant}.bgp.conf"
  [[ -f "$f" ]] || die "No BGP snippet found: $f"
  vtysh -f "$f"
  echo "Applied BGP config for $tenant"
}

cmd_tenant_service() {
  require_conf
  local action="$1" tenant="$2"
  [[ -n "$tenant" ]] || die "Tenant required"
  local tconf; tconf="$(tenant_conf_path "$tenant")"
  [[ -f "$tconf" ]] || die "Tenant not found: $tenant"

  case "$action" in
    start)
      systemctl enable --now "unbound-tenant@${tenant}" || true
      systemctl enable --now "squid-tenant@${tenant}" || true
      systemctl start "envoy-tenant@${tenant}" 2>/dev/null || true
      systemctl start "nginx-tenant@${tenant}" 2>/dev/null || true
      systemctl start "gw-portal@${tenant}" 2>/dev/null || true
      systemctl start "gw-portal-signer@${tenant}" 2>/dev/null || true
      systemctl start "nginx-forwardproxy@${tenant}" 2>/dev/null || true
      systemctl restart strongswan || true
      ;;
    stop)
      systemctl stop "envoy-tenant@${tenant}" 2>/dev/null || true
      systemctl stop "squid-tenant@${tenant}" || true
      systemctl stop "unbound-tenant@${tenant}" || true
      systemctl stop "gw-portal@${tenant}" 2>/dev/null || true
      systemctl stop "gw-portal-signer@${tenant}" 2>/dev/null || true
      systemctl stop "nginx-forwardproxy@${tenant}" 2>/dev/null || true
      systemctl stop "nginx-tenant@${tenant}" 2>/dev/null || true
      ;;
    restart)
      systemctl restart "unbound-tenant@${tenant}" || true
      systemctl restart "squid-tenant@${tenant}" || true
      systemctl restart "envoy-tenant@${tenant}" 2>/dev/null || true
      systemctl restart "gw-portal@${tenant}" 2>/dev/null || true
      systemctl restart "gw-portal-signer@${tenant}" 2>/dev/null || true
      systemctl restart "nginx-forwardproxy@${tenant}" 2>/dev/null || true
      systemctl restart "nginx-tenant@${tenant}" 2>/dev/null || true
      systemctl restart strongswan || true
      ;;
    status)
      systemctl --no-pager status "unbound-tenant@${tenant}" || true
      systemctl --no-pager status "squid-tenant@${tenant}" || true
      systemctl --no-pager status "envoy-tenant@${tenant}" 2>/dev/null || true
      systemctl --no-pager status "nginx-tenant@${tenant}" 2>/dev/null || true
      systemctl --no-pager status "gw-portal@${tenant}" 2>/dev/null || true
      systemctl --no-pager status "gw-portal-signer@${tenant}" 2>/dev/null || true
      systemctl --no-pager status "nginx-forwardproxy@${tenant}" 2>/dev/null || true
      ;;
    "ipsec-mss-clamp") cmd_ipsec_mss_clamp "${2:-}" "${3:-}" ;;
  *) die "Unknown tenant service action: $action";;
  esac
}

cmd_diag() {
  require_conf
  local tenant="$1"
  local tconf; tconf="$(tenant_conf_path "$tenant")"
  [[ -f "$tconf" ]] || die "Tenant not found: $tenant"
  # shellcheck source=/dev/null
  source "$tconf"

  echo "== DIAG tenant=$tenant =="
  echo "-- ipsec status (summary) --"
  ipsec statusall 2>/dev/null | head -n 120 || true

  echo "-- xfrm state/policy --"
  ip xfrm state 2>/dev/null | head -n 120 || true
  ip xfrm policy 2>/dev/null | head -n 120 || true

  echo "-- vrf routes --"
  ip vrf exec "$VRF_NAME" ip route || true
  echo "-- core routes --"
  ip vrf exec "$CORE_VRF_NAME" ip route || true

  echo "-- bgp summary (if available) --"
  vtysh -c "show bgp vrf $tenant summary" 2>/dev/null || true

  echo "-- services --"
  systemctl --no-pager status "unbound-tenant@${tenant}" || true
  systemctl --no-pager status "squid-tenant@${tenant}" || true
  systemctl --no-pager status "envoy-tenant@${tenant}" 2>/dev/null || true

  echo "-- firewall (first 200 lines) --"
  nft list ruleset | head -n 200 || true

  echo "-- catalog vip set (if enforced) --"
  nft list set inet gw "catalog_vips_${tenant}" 2>/dev/null || true
}

cmd_add_app() {
  require_conf
  local tenant="$1" fqdn="$2" upstream="$3" inspect="${4:-inherit}" auto_cert="${5:-no}"
  local tconf; tconf="$(tenant_conf_path "$tenant")"
  [[ -f "$tconf" ]] || die "Tenant not found: $tenant"
  run_module "80-app-envoy" "$tconf" add-app "$fqdn" "$upstream" "$inspect" "$auto_cert"
  # If tenant mTLS NGINX plane is enabled, create/update VIP listener for this app.
  # shellcheck source=/dev/null
  source "$tconf"
  if [[ "${NGINX_MTLS_MODE:-off}" == "on" ]]; then
    local apps_file="${APPS_DIR}/${tenant}.apps"
    if [[ -f "$apps_file" ]]; then
      local line; line="$(grep -E "^${fqdn} " "$apps_file" | tail -n 1 || true)"
      if [[ -n "$line" ]]; then
        local _fqdn vip _upstream _insp
        read -r _fqdn vip _upstream _insp <<<"$line"
        write_nginx_app_server "$tenant" "$fqdn" "$vip" "$_upstream" "$_insp"
        nginx_tenant_reload "$tenant"
      fi
    fi
  fi
}

cmd_del_app() {
  require_conf
  local tenant="$1" fqdn="$2"
  local tconf; tconf="$(tenant_conf_path "$tenant")"
  [[ -f "$tconf" ]] || die "Tenant not found: $tenant"
  run_module "80-app-envoy" "$tconf" del-app "$fqdn"
}

cmd_list_apps() {
  require_conf
  local tenant="$1"
  local tconf; tconf="$(tenant_conf_path "$tenant")"
  [[ -f "$tconf" ]] || die "Tenant not found: $tenant"
  run_module "80-app-envoy" "$tconf" list-apps
}

cmd_pki_init() { require_conf; ensure_dirs; run_module "70-pki" "" --root-only; }
cmd_pki_tenant(){ require_conf; local tconf; tconf="$(tenant_conf_path "$1")"; run_module "70-pki" "$tconf" --tenant-only; }
cmd_issue_user(){ require_conf; local tconf; tconf="$(tenant_conf_path "$1")"; run_module "70-pki" "$tconf" --issue-user "$2"; }
cmd_issue_app_cert(){ require_conf; local tconf; tconf="$(tenant_conf_path "$1")"; run_module "70-pki" "$tconf" --issue-app-cert "$2"; }

cmd_show_tenant(){ require_conf; cat "$(tenant_conf_path "$1")"; }
cmd_list_tenants(){ require_conf; ls -1 "$TENANTS_DIR"/*.conf 2>/dev/null | sed 's#.*/##; s/\.conf$//' || true; }


cmd_mtls_enable() {
  require_conf
  local tenant="$1" crl="${2:-off}"
  [[ -n "$tenant" ]] || die "Usage: mtls-enable <tenant> [crl=on|off]"
  local tconf; tconf="$(tenant_conf_path "$tenant")"
  [[ -f "$tconf" ]] || die "Tenant not found: $tenant"

  # Load tenant conf for VIPs and PKI paths
  # shellcheck source=/dev/null
  source "$tconf"

  # Determine CA bundle path for client verification
  local ca_chain="/etc/gateway/pki/${tenant}/intermediate/certs/ca-chain.cert.pem"
  local ca_int="/etc/gateway/pki/${tenant}/intermediate/certs/intermediate.cert.pem"
  local ca_pem="$ca_chain"
  [[ -f "$ca_pem" ]] || ca_pem="$ca_int"

  tenant_conf_set_kv "$tconf" "NGINX_MTLS_MODE" "on"
  tenant_conf_set_kv "$tconf" "CRL_ENFORCE" "${crl}"
  tenant_conf_set_kv "$tconf" "TENANT_CA_PEM" "${ca_pem}"

  # Ensure portal cert exists (signed by tenant CA) via PKI module; store under portal/
  mkdir -p "/etc/gateway/tls/${tenant}/portal"
  if [[ ! -f "/etc/gateway/tls/${tenant}/portal/cert.pem" || ! -f "/etc/gateway/tls/${tenant}/portal/key.pem" ]]; then
    # generate portal cert as an "app" cert then copy
    /opt/gw-builder/modules/70-pki.sh "$tconf" --issue-app-cert "portal.${tenant}.local" || true
    local src_dir="/etc/gateway/tls/${tenant}/apps/portal.${tenant}.local"
    if [[ -f "${src_dir}/cert.pem" && -f "${src_dir}/key.pem" ]]; then
      cp -f "${src_dir}/cert.pem" "/etc/gateway/tls/${tenant}/portal/cert.pem"
      cp -f "${src_dir}/key.pem"  "/etc/gateway/tls/${tenant}/portal/key.pem"
      chmod 600 "/etc/gateway/tls/${tenant}/portal/key.pem"
    else
      warn "Portal cert not found under ${src_dir}; you may need to issue it manually."
    fi
  fi

  ensure_nginx_base
  write_nginx_tenant_conf "$tenant"
  nginx_tenant_enable "$tenant"

  echo "mTLS enabled for tenant ${tenant} (CRL_ENFORCE=${crl})"
}

cmd_mtls_reload() {
  require_conf
  local tenant="$1"
  [[ -n "$tenant" ]] || die "Usage: mtls-reload <tenant>"
  local tconf; tconf="$(tenant_conf_path "$tenant")"
  [[ -f "$tconf" ]] || die "Tenant not found: $tenant"
  write_nginx_tenant_conf "$tenant"
  nginx_tenant_reload "$tenant"
  echo "NGINX tenant config reloaded for ${tenant}"
}

cmd_portal_enable() {
  require_conf
  local tenant="$1"
  [[ -n "$tenant" ]] || die "Usage: portal-enable <tenant>"
  local tconf; tconf="$(tenant_conf_path "$tenant")"
  [[ -f "$tconf" ]] || die "Tenant not found: $tenant"

  # portal backend (127.0.0.1:9443 inside tenant VRF)
  portal_enable "$tenant"

  # ensure NGINX tenant is present; if not, enable mTLS with defaults
  if ! systemctl is-enabled "nginx-tenant@${tenant}" >/dev/null 2>&1; then
    cmd_mtls_enable "$tenant" "off"
  else
    cmd_mtls_reload "$tenant"
  fi

  echo "Portal enabled for tenant ${tenant} at PORTAL_VIP:443"
}

cmd_portal_disable() {
  require_conf
  local tenant="$1"
  [[ -n "$tenant" ]] || die "Usage: portal-disable <tenant>"
  portal_disable "$tenant"
  echo "Portal disabled for tenant ${tenant}"
}

cmd_otp_create() {
  require_conf
  local tenant="$1" email="$2" ttl="${3:-900}"
  [[ -n "$tenant" && -n "$email" ]] || die "Usage: otp-create <tenant> <email> [ttl_seconds=900]"

  local token
  token="$(tr -dc 'A-Z2-7' </dev/urandom | head -c 22)"
  local now exp
  now="$(date +%s)"
  exp="$((now + ttl))"

  local dir="/etc/gateway/portal/${tenant}/tokens"
  mkdir -p "$dir"
  cat >"${dir}/${token}.json" <<EOF
{"tenant":"${tenant}","email":"${email}","iat":${now},"exp":${exp},"used":false}
EOF
  chmod 600 "${dir}/${token}.json"

  echo "OTP created (share out-of-band):"
  echo "  tenant: ${tenant}"
  echo "  email:  ${email}"
  echo "  token:  ${token}"
  echo "  exp:    ${exp} (epoch)"
}

cmd_inspect_export() {
  require_conf
  local action="$1"
  case "$action" in
    enable) inspect_export_enable;;
    disable) inspect_export_disable;;
    "ipsec-mss-clamp") cmd_ipsec_mss_clamp "${2:-}" "${3:-}" ;;
  *) die "Usage: inspect-export enable|disable";;
  esac
}

cmd_revoke_user() {
  require_conf
  local tenant="$1" email="$2"
  [[ -n "$tenant" && -n "$email" ]] || die "Usage: revoke-user <tenant> <email>"
  pki_revoke_user "$tenant" "$email"
  echo "Revoked user cert for ${email} in tenant ${tenant} and regenerated CRL."
}

cmd_gen_crl() {
  require_conf
  local tenant="$1"
  [[ -n "$tenant" ]] || die "Usage: gen-crl <tenant>"
  pki_gen_crl "$tenant"
  echo "Generated CRL for tenant ${tenant}"
}

cmd_publish_crl() {
  require_conf
  local tenant="$1"
  [[ -n "$tenant" ]] || die "Usage: publish-crl <tenant>"
  pki_publish_crl "$tenant"
  echo "Published CRL for tenant ${tenant}"
}

cmd_ocsp_note() {
  require_conf
  pki_ocsp_note
}



cmd_fwdproxy_enable() {
  require_conf
  local tenant="$1" listen_port="${2:-8443}"
  [[ -n "$tenant" ]] || die "Usage: fwdproxy-enable <tenant> [listen_port=8443]"
  local tconf; tconf="$(tenant_conf_path "$tenant")"
  [[ -f "$tconf" ]] || die "Tenant not found: $tenant"
  # shellcheck source=/dev/null
  source "$tconf"

  # Ensure forwardproxy cert exists
  mkdir -p "/etc/gateway/tls/${tenant}/forwardproxy"
  if [[ ! -f "/etc/gateway/tls/${tenant}/forwardproxy/cert.pem" || ! -f "/etc/gateway/tls/${tenant}/forwardproxy/key.pem" ]]; then
    /opt/gw-builder/modules/70-pki.sh "$tconf" --issue-app-cert "forwardproxy.${tenant}.local" || true
    local src="/etc/gateway/tls/${tenant}/apps/forwardproxy.${tenant}.local"
    if [[ -f "${src}/cert.pem" && -f "${src}/key.pem" ]]; then
      cp -f "${src}/cert.pem" "/etc/gateway/tls/${tenant}/forwardproxy/cert.pem"
      cp -f "${src}/key.pem"  "/etc/gateway/tls/${tenant}/forwardproxy/key.pem"
      chmod 600 "/etc/gateway/tls/${tenant}/forwardproxy/key.pem"
    else
      die "Unable to create forwardproxy cert; check PKI module."
    fi
  fi

  write_nginx_forwardproxy_stream "$tenant" "${SQUID_VIP%/*}" "${listen_port}" "${SQUID_VIP%/*}" "3128"
  nginx_forwardproxy_enable "$tenant"
  echo "Forward proxy mTLS wrapper enabled for ${tenant}: ${SQUID_VIP%/*}:${listen_port} -> ${SQUID_VIP%/*}:3128"
}

cmd_fwdproxy_disable() {
  require_conf
  local tenant="$1"
  [[ -n "$tenant" ]] || die "Usage: fwdproxy-disable <tenant>"
  nginx_forwardproxy_disable "$tenant"
  echo "Forward proxy mTLS wrapper disabled for ${tenant}"
}

cmd_app_allow() {
  require_conf
  local tenant="$1" email="$2" fqdn="$3"
  [[ -n "$tenant" && -n "$email" && -n "$fqdn" ]] || die "Usage: app-allow <tenant> <email|*> <fqdn>"
  authz_allow_add "$tenant" "$email" "$fqdn"
  authz_build_nginx_snippets "$tenant"
  systemctl reload "nginx-tenant@${tenant}" 2>/dev/null || true
  echo "Allowed ${email} to access ${fqdn} in tenant ${tenant}"
}

cmd_app_deny() {
  require_conf
  local tenant="$1" email="$2" fqdn="$3"
  [[ -n "$tenant" && -n "$email" && -n "$fqdn" ]] || die "Usage: app-deny <tenant> <email|*> <fqdn>"
  authz_allow_del "$tenant" "$email" "$fqdn"
  authz_build_nginx_snippets "$tenant"
  systemctl reload "nginx-tenant@${tenant}" 2>/dev/null || true
  echo "Removed allow rule for ${email} -> ${fqdn} in tenant ${tenant}"
}

cmd_crl_refresh() {
  require_conf
  local tenant="$1"
  [[ -n "$tenant" ]] || die "Usage: crl-refresh <tenant>"
  pki_crl_refresh "$tenant"
  echo "CRL refreshed and nginx reloaded for tenant ${tenant}"
}

cmd_crl_timer_enable() {
  require_conf
  local tenant="$1"
  [[ -n "$tenant" ]] || die "Usage: crl-timer-enable <tenant>"
  crl_timer_enable "$tenant"
  echo "Enabled daily CRL refresh timer for tenant ${tenant}"
}

cmd_crl_timer_disable() {
  require_conf
  local tenant="$1"
  [[ -n "$tenant" ]] || die "Usage: crl-timer-disable <tenant>"
  crl_timer_disable "$tenant"
  echo "Disabled CRL refresh timer for tenant ${tenant}"
}

cmd_portal_signer_loop() {
  require_conf
  local tenant="$1" interval="${2:-2}"
  [[ -n "$tenant" ]] || die "Usage: portal-signer-loop <tenant> [interval_seconds=2]"
  portal_signer_loop "$tenant" "$interval"
}


main() {
  [[ $# -ge 1 ]] || { usage; exit 1; }
  case "$1" in
    -h|--help) usage;;
    check) cmd_check;;
    preflight) cmd_preflight;;
    init) cmd_init;;
    core-setup) cmd_core_setup;;
    fw-apply) cmd_fw_apply;;

    add-tenant) shift; cmd_add_tenant "$@";;
    del-tenant) shift; cmd_del_tenant "$@";;
    show-tenant) shift; cmd_show_tenant "$@";;
    list-tenants) shift; cmd_list_tenants;;

    tenant-start) shift; cmd_tenant_service start "$@";;
    tenant-stop) shift; cmd_tenant_service stop "$@";;
    tenant-restart) shift; cmd_tenant_service restart "$@";;
    tenant-status) shift; cmd_tenant_service status "$@";;
    diag) shift; cmd_diag "$@";;

    apply-bgp) shift; cmd_apply_bgp "$@";;

    pki-init) shift; cmd_pki_init;;
    pki-tenant) shift; cmd_pki_tenant "$@";;
    issue-user) shift; cmd_issue_user "$@";;
    issue-app-cert) shift; cmd_issue_app_cert "$@";;

    add-app) shift; cmd_add_app "$@";;
    del-app) shift; cmd_del_app "$@";;
    list-apps) shift; cmd_list_apps "$@";;

mtls-enable) shift; cmd_mtls_enable "$@";;
mtls-reload) shift; cmd_mtls_reload "$@";;
portal-enable) shift; cmd_portal_enable "$@";;
portal-disable) shift; cmd_portal_disable "$@";;
otp-create) shift; cmd_otp_create "$@";;

inspect-export) shift; cmd_inspect_export "$@";;

revoke-user) shift; cmd_revoke_user "$@";;
gen-crl) shift; cmd_gen_crl "$@";;
publish-crl) shift; cmd_publish_crl "$@";;
ocsp-note) shift; cmd_ocsp_note;;

    "ipsec-mss-clamp") cmd_ipsec_mss_clamp "${2:-}" "${3:-}" ;;
  *) usage; die "Unknown command: $1";;
  esac
}

main "$@"


# --- IPsec vendor interop profiles (v1.0.2) ---
load_ipsec_profiles() {
  local p="/opt/gw-builder/ipsec-profiles.conf"
  [[ -f "$p" ]] || p="$(dirname "$0")/ipsec-profiles.conf"
  [[ -f "$p" ]] || die "ipsec profiles file not found: ipsec-profiles.conf"
  # shellcheck disable=SC1090
  source "$p"
}

get_profile_var() {
  local prof="$1" field="$2"
  local v="PROFILE_${prof}_${field}"
  echo "${!v:-}"
}

tenant_get_ipsec_profile() {
  local tenant="$1"
  local tconf
  tconf="$(tenant_conf_path "$tenant")"
  [[ -f "$tconf" ]] || die "Tenant conf not found: $tconf"
  local prof
  prof="$(grep -E '^IPSEC_PROFILE=' "$tconf" | tail -n1 | cut -d= -f2- || true)"
  [[ -n "$prof" ]] || prof="${IPSEC_PROFILE_DEFAULT:-strongswan}"
  echo "$prof"
}

cmd_set_ipsec_profile() {
  local tenant="${1:-}" prof="${2:-}"
  [[ -n "$tenant" && -n "$prof" ]] || die "Usage: $0 set-ipsec-profile <tenant> <strongswan|cisco|arista>"
  load_ipsec_profiles
  local ike esp
  ike="$(get_profile_var "$prof" "IKE_PROPOSALS")"
  esp="$(get_profile_var "$prof" "ESP_PROPOSALS")"
  [[ -n "$ike" && -n "$esp" ]] || die "Unknown/invalid profile: $prof"
  local tconf
  tconf="$(tenant_conf_path "$tenant")"
  [[ -f "$tconf" ]] || die "Tenant conf not found: $tconf"
  if grep -qE '^IPSEC_PROFILE=' "$tconf"; then
    sed -i "s/^IPSEC_PROFILE=.*/IPSEC_PROFILE=${prof}/" "$tconf"
  else
    echo "IPSEC_PROFILE=${prof}" >> "$tconf"
  fi
  echo "Set ${tenant} IPsec profile to: ${prof}"
  echo "Rebuild/restart tenant IPsec to apply."
}

render_peer_doc_header() {
  local tenant="$1" prof="$2"
  cat <<EOF
# GW-Builder IPsec Peer Template
# Tenant: ${tenant}
# Profile: ${prof}
# Generated: $(date -Is)
#
# Use this as a starting point for the remote peer configuration.
EOF
}

cmd_ipsec_peer_template() {
  local tenant="${1:-}" peer_type="${2:-}"
  [[ -n "$tenant" ]] || die "Usage: $0 ipsec-peer-template <tenant> [strongswan|cisco|arista]"
  load_ipsec_profiles
  local prof="${peer_type:-$(tenant_get_ipsec_profile "$tenant")}"

  local ike esp ike_lt esp_lt dpd_delay dpd_to frag mss
  ike="$(get_profile_var "$prof" "IKE_PROPOSALS")"
  esp="$(get_profile_var "$prof" "ESP_PROPOSALS")"
  ike_lt="$(get_profile_var "$prof" "IKE_LIFETIME")"
  esp_lt="$(get_profile_var "$prof" "ESP_LIFETIME")"
  dpd_delay="$(get_profile_var "$prof" "DPD_DELAY")"
  dpd_to="$(get_profile_var "$prof" "DPD_TIMEOUT")"
  frag="$(get_profile_var "$prof" "FRAG")"
  mss="$(get_profile_var "$prof" "MSS_CLAMP")"

  [[ -n "$ike" && -n "$esp" ]] || die "Unknown/invalid profile: $prof"

  local tconf
  tconf="$(tenant_conf_path "$tenant")"
  local vti_local vti_peer lo_local lo_peer
  vti_local="$(grep -E '^VTI_LOCAL_IP=' "$tconf" 2>/dev/null | cut -d= -f2- || true)"
  vti_peer="$(grep -E '^VTI_PEER_IP=' "$tconf" 2>/dev/null | cut -d= -f2- || true)"
  lo_local="$(grep -E '^IKE_LOOPBACK_LOCAL=' "$tconf" 2>/dev/null | cut -d= -f2- || true)"
  lo_peer="$(grep -E '^IKE_LOOPBACK_PEER=' "$tconf" 2>/dev/null | cut -d= -f2- || true)"

  [[ -n "$vti_local" ]] || vti_local="192.168.248.1"
  [[ -n "$vti_peer"  ]] || vti_peer="192.168.248.2"
  [[ -n "$lo_local"  ]] || lo_local="192.168.1.10"
  [[ -n "$lo_peer"   ]] || lo_peer="198.51.100.10"

  render_peer_doc_header "$tenant" "$prof"
  echo
  echo "## Parameters"
  echo "- IKE proposals: ${ike}"
  echo "- ESP proposals: ${esp}"
  echo "- IKE lifetime:  ${ike_lt}"
  echo "- ESP lifetime:  ${esp_lt}"
  echo "- DPD:           delay=${dpd_delay} timeout=${dpd_to}"
  echo "- IKE frag:      ${frag}"
  echo "- MSS clamp:     ${mss}"
  echo
  echo "## Tunnel addressing (/30)"
  echo "- Remote peer tunnel IP: ${vti_peer}"
  echo "- GW tunnel IP:          ${vti_local}"
  echo
  case "$prof" in
    strongswan)
      cat <<EOF
### strongSwan remote peer notes
- Use IKEv2 PSK
- Configure a route-based tunnel (VTI) with /30 above
- Establish BGP over the tunnel to exchange tenant routes
EOF
      ;;
    cisco)
      cat <<EOF
### Cisco IOS/IOS-XE starting template (adjust to your platform/version)
crypto ikev2 proposal GW-PROP
  encryption aes-cbc-256
  integrity sha256
  group 14
crypto ikev2 policy 10
  proposal GW-PROP

crypto ikev2 keyring GW-KR
  peer GW
    address ${lo_local}
    pre-shared-key local <PSK>
    pre-shared-key remote <PSK>

crypto ikev2 profile GW-PROFILE
  match identity remote address ${lo_local} 255.255.255.255
  authentication local pre-share
  authentication remote pre-share
  keyring local GW-KR
  dpd 10 3 periodic

crypto ipsec transform-set GW-TS esp-aes 256 esp-sha256-hmac
  mode tunnel
crypto ipsec profile GW-IPSEC-PROFILE
  set transform-set GW-TS

interface Tunnel100
  ip address ${vti_peer} 255.255.255.252
  tunnel source <WAN-IF>
  tunnel destination ${lo_local}
  tunnel mode ipsec ipv4
  tunnel protection ipsec profile GW-IPSEC-PROFILE

router bgp <CISCO_ASN>
  neighbor ${vti_local} remote-as <GW_ASN>
EOF
      ;;
    arista)
      cat <<EOF
### Arista EOS guidance (commands vary by EOS release)
- Define IKE policy and IPsec SA policy matching the proposals above
- Define a tunnel interface:
    ip address ${vti_peer}/30
    tunnel destination ${lo_local}
- Apply the IPsec profile/policy to the tunnel
- Establish BGP neighbor ${vti_local} over the tunnel

Also consider MSS clamping if you observe TCP issues (recommended: ${mss}).
EOF
      ;;
    "ipsec-mss-clamp") cmd_ipsec_mss_clamp "${2:-}" "${3:-}" ;;
  *)
      die "Unsupported profile: $prof"
      ;;
  esac
}



# --- MSS clamp hook (nftables) (v1.0.3) ---
mss_table_name() { local tenant="$1"; echo "gw_mss_${tenant}"; }
mss_chain_name() { echo "mangle_fwd"; }

tenant_vti_ifname() {
  local tenant="$1"
  local tconf
  tconf="$(tenant_conf_path "$tenant")"
  local ifn
  ifn="$(grep -E '^VTI_IFNAME=' "$tconf" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
  [[ -n "$ifn" ]] || ifn="vti-${tenant}"
  echo "$ifn"
}

cmd_ipsec_mss_clamp() {
  local action="${1:-}" tenant="${2:-}"
  [[ -n "$action" && -n "$tenant" ]] || die "Usage: $0 ipsec-mss-clamp <apply|remove|show> <tenant>"
  load_conf
  load_ipsec_profiles

  local prof mss ifn table chain
  prof="$(tenant_get_ipsec_profile "$tenant")"
  mss="$(get_profile_var "$prof" "MSS_CLAMP")"
  [[ -n "$mss" ]] || mss="0"
  ifn="$(tenant_vti_ifname "$tenant")"
  table="$(mss_table_name "$tenant")"
  chain="$(mss_chain_name)"

  case "$action" in
    show)
      echo "tenant=$tenant profile=$prof vti_if=$ifn mss=$mss"
      nft list table inet "$table" 2>/dev/null || true
      ;;
    remove)
      nft delete table inet "$table" 2>/dev/null || true
      echo "Removed MSS clamp table inet $table (if it existed)."
      ;;
    apply)
      if [[ "$mss" == "0" ]]; then
        echo "Profile MSS_CLAMP=0; nothing to apply."
        nft delete table inet "$table" 2>/dev/null || true
        return 0
      fi
      nft -f - <<EOF
table inet ${table} {
  chain ${chain} {
    type filter hook forward priority mangle; policy accept;
    iifname "${ifn}" tcp flags syn tcp option maxseg size set ${mss}
    oifname "${ifn}" tcp flags syn tcp option maxseg size set ${mss}
  }
}
EOF
      echo "Applied MSS clamp=${mss} on forward hook for iif/oif ${ifn} (table inet ${table})."
      ;;
    "ipsec-mss-clamp") cmd_ipsec_mss_clamp "${2:-}" "${3:-}" ;;
  *) die "Unknown action: $action (use apply|remove|show)";;
  esac
}



run_tenant_hooks() {
  local tenant="$1" phase="${2:-ipsec-up}"
  local hooks_dir="/opt/gw-builder/modules"
  [[ -d "$hooks_dir" ]] || hooks_dir="$(dirname "$0")/modules"
  [[ -d "$hooks_dir" ]] || return 0
  for h in "$hooks_dir"/*-hook.sh; do
    [[ -x "$h" ]] || continue
    "$h" "$tenant" "$phase" || true
  done
}
