#!/usr/bin/env bash
set -euo pipefail

die(){ echo "ERROR: $*" >&2; exit 1; }

ensure_dirs() {
  mkdir -p "$STATE_DIR" "$TENANTS_DIR" "$APPS_DIR" "$FRR_SNIPPETS_DIR" \
           "$SQUID_INST_DIR" "$SQUID_TENANT_DIR" "$UNBOUND_TENANT_DIR" \
           "$ENVOY_TENANT_DIR" "$NFT_DIR" "$PKI_DIR" "$TLS_DIR" "$CATALOG_DIR" "$LOG_DIR"
}

prompt_for_interfaces_if_needed() {
  local conf_file="$1"
  # shellcheck source=/dev/null
  source "$conf_file"

  if [[ -z "${WAN_IF:-}" || -z "${LAN_IF:-}" ]]; then
    echo "First-time setup: choose physical interfaces."
    ip -o link show | awk -F': ' '{print " - " $2}' | sed 's/@.*//'
    read -r -p "Enter WAN (tunnel/Internet-facing) interface (e.g., eth0): " wan
    read -r -p "Enter LAN (internal egress) interface (e.g., en1): " lan
    [[ -n "$wan" && -n "$lan" ]] || die "Both WAN and LAN interfaces are required"

    sed -i "s/^WAN_IF=\"\"/WAN_IF=\"$wan\"/" "$conf_file"
    sed -i "s/^LAN_IF=\"\"/LAN_IF=\"$lan\"/" "$conf_file"
  fi
}

ensure_sysctls() {
  cat >/etc/sysctl.d/99-gw-builder.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
EOF
  sysctl --system >/dev/null || true
}

check_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_packages() {
  local pkgs=(strongswan frr nginx squid unbound openssl nftables iproute)
  local missing=()
  for p in "${pkgs[@]}"; do
    rpm -q "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if ((${#missing[@]})); then
    echo "Installing missing packages: ${missing[*]}"
    dnf -y install "${missing[@]}"
  fi

  if ! rpm -q envoy >/dev/null 2>&1; then
    echo "NOTE: Envoy package not installed yet."
    echo "      Install Envoy via your approved vendor repo if you plan to use catalog reverse proxies."
  fi
}

check_requirements() {
  echo "== Requirements check =="
  for b in ip nft openssl; do
    check_cmd "$b" && echo "OK: $b" || echo "MISSING: $b"
  done

  echo "OK?: strongSwan: $(rpm -q strongswan >/dev/null 2>&1 && echo yes || echo no)"
  echo "OK?: frr:       $(rpm -q frr >/dev/null 2>&1 && echo yes || echo no)"
  echo "OK?: squid:     $(rpm -q squid >/dev/null 2>&1 && echo yes || echo no)"
  echo "OK?: unbound:   $(rpm -q unbound >/dev/null 2>&1 && echo yes || echo no)"
  echo "OK?: nftables:  $(rpm -q nftables >/dev/null 2>&1 && echo yes || echo no)"
  echo "OK?: envoy:     $(rpm -q envoy >/dev/null 2>&1 && echo yes || echo no)"

  if check_cmd nginx; then
    if nginx -V 2>&1 | grep -q -- 'stream'; then
      echo "OK: nginx has stream support"
    else
      echo "WARN: nginx may not have stream support (stream module not shown in nginx -V)"
    fi
  fi

  if [[ -f /etc/frr/daemons ]]; then
    grep -q '^zebra=yes' /etc/frr/daemons || echo "WARN: /etc/frr/daemons zebra not enabled"
    grep -q '^bgpd=yes'  /etc/frr/daemons || echo "WARN: /etc/frr/daemons bgpd not enabled"
  fi
}

ensure_services() {
  systemctl enable --now nftables || true
  systemctl enable --now strongswan || true

  if [[ -f /etc/frr/daemons ]]; then
    sed -i 's/^zebra=.*/zebra=yes/' /etc/frr/daemons
    sed -i 's/^bgpd=.*/bgpd=yes/' /etc/frr/daemons
  fi
  systemctl enable --now frr || true

  systemctl enable --now nginx || true
}

run_module() {
  local mod="$1"; shift
  local tconf="${1:-}"; shift || true
  local script="/opt/gw-builder/modules/${mod}.sh"
  [[ -x "$script" ]] || die "Module not found/executable: $script"
  "$script" "$tconf" "$@"
}

# ---------- Allocators ----------
allocate_tenant_index() {
  local tenant="$1" mapfile="$2"
  mkdir -p "$(dirname "$mapfile")"
  touch "$mapfile"
  if grep -qE "^${tenant} " "$mapfile"; then
    awk -v t="$tenant" '$1==t{print $2}' "$mapfile"
    return 0
  fi
  local idx=1
  while awk '{print $2}' "$mapfile" | grep -qx "$idx"; do idx=$((idx+1)); done
  echo "$tenant $idx" >> "$mapfile"
  echo "$idx"
}

deallocate_tenant_index() {
  local tenant="$1" mapfile="$2"
  [[ -f "$mapfile" ]] || return 0
  grep -vE "^${tenant} " "$mapfile" > "${mapfile}.tmp" || true
  mv "${mapfile}.tmp" "$mapfile"
}

alloc_host_from_pool24() {
  local cidr="$1" idx="$2"
  local net="${cidr%/*}"
  local a b c d
  IFS='.' read -r a b c d <<<"$net"
  local host=$((d + idx))
  [[ $host -le 254 ]] || die "Pool exhausted for $cidr at idx=$idx"
  echo "${a}.${b}.${c}.${host}"
}

alloc_tenant_subnet24() {
  local base_cidr="$1" idx="$2"
  local net="${base_cidr%/*}"
  local a b c d
  IFS='.' read -r a b c d <<<"$net"
  local c_new=$((c + idx - 1))
  [[ $c_new -le 254 ]] || die "Tenant net exhausted from $base_cidr at idx=$idx"
  echo "${a}.${b}.${c_new}.0/24"
}

split_24_to_25s() {
  local cidr="$1"
  local net="${cidr%/*}"
  local a b c d
  IFS='.' read -r a b c d <<<"$net"
  echo "${a}.${b}.${c}.0/25 ${a}.${b}.${c}.128/25"
}

host_in_subnet() {
  local cidr="$1" host="$2"
  local net="${cidr%/*}"
  local a b c d
  IFS='.' read -r a b c d <<<"$net"
  echo "${a}.${b}.${c}.${host}"
}

alloc_vti_30_from_pool() {
  local cidr="$1" idx="$2"
  local net="${cidr%/*}"
  local a b c d
  IFS='.' read -r a b c d <<<"$net"
  local offset=$(((idx-1)*4))
  local start=$((d + offset))
  local c_new=$c
  local d_new=$start
  while [[ $d_new -ge 256 ]]; do d_new=$((d_new-256)); c_new=$((c_new+1)); done
  [[ $c_new -le 255 ]] || die "VTI pool exhausted for $cidr at idx=$idx"
  echo "${a}.${b}.${c_new}.${d_new}"
}

alloc_veth_30_from_pool() { alloc_vti_30_from_pool "$@"; }

vti_local_ip() { local net="$1"; echo "${net%.*}.$(( ${net##*.} + 1 ))"; }
vti_remote_ip(){ local net="$1"; echo "${net%.*}.$(( ${net##*.} + 2 ))"; }

alloc_app_vip() {
  local tenant="$1" upper25="$2"
  local state="${APPS_DIR}/${tenant}.vip-counter"
  mkdir -p "$APPS_DIR"
  local base_ip
  base_ip="$(host_in_subnet "$upper25" 129)"
  local a b c d
  IFS='.' read -r a b c d <<<"$base_ip"

  local n=0
  [[ -f "$state" ]] && n="$(cat "$state")"
  local vip_last=$((d + n))
  [[ $vip_last -le 254 ]] || die "No more VIPs in upper /25 for $tenant"
  echo $((n+1)) >"$state"
  echo "${a}.${b}.${c}.${vip_last}"
}

# ---- Catalog helpers (MVG canonical service registry) ----
catalog_tenant_dir() { echo "${CATALOG_DIR}/${1}"; }
catalog_revproxy_dir() { echo "${CATALOG_DIR}/${1}/reverse-proxy.d"; }
catalog_ssh_dir() { echo "${CATALOG_DIR}/${1}/ssh.d"; }
catalog_dns_rewrites() { echo "${CATALOG_DIR}/${1}/dns-rewrites.conf"; }
catalog_inspection_conf() { echo "${CATALOG_DIR}/${1}/inspection.conf"; }

ensure_tenant_catalog() {
  local tenant="$1"
  local tdir; tdir="$(catalog_tenant_dir "$tenant")"
  mkdir -p "$(catalog_revproxy_dir "$tenant")" "$(catalog_ssh_dir "$tenant")"

  local dnsf; dnsf="$(catalog_dns_rewrites "$tenant")"
  if [[ ! -f "$dnsf" ]]; then
    cat >"$dnsf" <<'EOF'
# DNS rewrites for tenant catalog VIPs
# Format: unbound local-data lines, example:
# local-data: "sap.outlan.net. A 172.16.100.129"
EOF
  fi

  local inspf; inspf="$(catalog_inspection_conf "$tenant")"
  if [[ ! -f "$inspf" ]]; then
    cat >"$inspf" <<'EOF'
# Per-tenant inspection configuration (MVG)
# INSPECTION_EXPORT_MODE=off|log|tap
INSPECTION_EXPORT_MODE=off
# INSPECTION_TAP_TARGET=ip:port (optional, used by inspection add-on)
INSPECTION_TAP_TARGET=
EOF
  fi
}


# ---- Logging helpers ----
tenant_log_dir() { echo "${LOG_DIR}/${1}"; }
ensure_tenant_logdirs() {
  local tenant="$1"
  mkdir -p "$(tenant_log_dir "$tenant")"/{nginx,squid,envoy,sshproxy,inspection,dns,system}
  # system logs (shared but grouped under tenant for consistency)
  mkdir -p "$(tenant_log_dir "$tenant")"/system
}
