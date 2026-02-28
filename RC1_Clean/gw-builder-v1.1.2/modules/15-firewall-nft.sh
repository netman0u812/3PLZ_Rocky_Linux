#!/usr/bin/env bash
set -euo pipefail
source /opt/gw-builder/gw.conf
source /opt/gw-builder/modules/00-common.sh

tconf="${1:-}"; shift || true
action="${1:-apply}"

write_main() {
  mkdir -p "$NFT_DIR"
  cat >"$NFT_MAIN" <<EOF
#!/usr/sbin/nft -f

flush ruleset

include "${NFT_DIR}/00-base.nft"
include "${NFT_DIR}/10-sets.nft"
include "${NFT_DIR}/20-core.nft"
include "${NFT_DIR}/30-tenants.nft"
EOF
  chmod 600 "$NFT_MAIN" || true
}

write_base() {
  cat >"${NFT_DIR}/00-base.nft" <<'EOF'
table inet gw {

  chain input {
    type filter hook input priority 0; policy drop;
    ct state established,related accept
    iif "lo" accept
    ip protocol icmp accept
    ip6 nexthdr icmpv6 accept
    jump zone_input
  }

  chain forward {
    type filter hook forward priority 0; policy drop;
    ct state established,related accept
    jump zone_forward
  }

  chain output {
    type filter hook output priority 0; policy accept;
  }

  chain zone_input { }
  chain zone_forward { }
}
EOF
}

write_sets() {
  cat >"${NFT_DIR}/10-sets.nft" <<'EOF'
table inet gw {
  sets {
    tenant_veth_src {
      type ipv4_addr;
      flags interval;
    }
    # Per-tenant catalog VIP allowlists are defined in tenant fragments:
    # set catalog_vips_<tenant> { type ipv4_addr; flags interval; elements = { ... } }
  }
}
EOF
}

write_core() {
  cat >"${NFT_DIR}/20-core.nft" <<EOF
table inet gw {

  chain zone_input {
    # WAN underlay: IKE/ESP inbound on WAN_IF
    iifname "$WAN_IF" udp dport {500,4500} accept
    iifname "$WAN_IF" ip protocol esp accept

    # Allow BGP on VTI interfaces if needed (commonly required)
    iifname "vti-*" tcp dport 179 accept

    # Tier-2 proxy ports on transit veth endpoints
    iifname "veth-default-core" tcp dport 3128 accept   # squid@inet
    iifname "veth-core-default"  tcp dport 3129 accept   # squid@core
  }

  chain zone_forward {
    # Forward rules kept minimal; tenant fragments add explicit allows.
  }
}
EOF
}

write_tenants_combined() {
  local out="${NFT_DIR}/30-tenants.nft"
  cat >"$out" <<'EOF'
table inet gw {
  chain zone_input { }
  chain zone_forward { }
}
EOF

  mkdir -p "${NFT_DIR}/30-tenants"
  for f in "${NFT_DIR}/30-tenants/"*.nft; do
    [[ -f "$f" ]] || continue
    echo "" >>"$out"
    echo "include \"$f\"" >>"$out"
  done
}

build_tenant_fragment() {
  [[ -f "$tconf" ]] || die "Tenant conf required"
  # shellcheck source=/dev/null
  source "$tconf"

  mkdir -p "${NFT_DIR}/30-tenants"
  local f="${NFT_DIR}/30-tenants/${TENANT}.nft"

  local tenant24="${TENANT_NET}"
  local lower25 upper25
  read -r lower25 upper25 <<<"$(split_24_to_25s "$TENANT_NET")"
  local setname="catalog_vips_${TENANT}"

  cat >"$f" <<EOF
table inet gw {

  # Tenant: $TENANT  Mode: ${FW_MODE}

  set ${setname} {
    type ipv4_addr;
    flags interval;
    elements = { }
  }

  chain zone_input {
    # Allow tenant->DNS VIP
    ip saddr $tenant24 ip daddr ${DNS_VIP%/*} udp dport 53 accept
    ip saddr $tenant24 ip daddr ${DNS_VIP%/*} tcp dport 53 accept

    # Allow tenant->squid explicit
    ip saddr $tenant24 ip daddr ${SQUID_VIP%/*} tcp dport 3128 accept

EOF

  if [[ "${FW_MODE}" == "enforced" ]]; then
    cat >>"$f" <<EOF
    # Enforced: only allow known catalog VIPs (service-catalog driven)
    ip saddr $tenant24 ip daddr @${setname} tcp dport 443 accept

    # Allow tenant->core transit veth
    iifname "veth-${TENANT}-core" accept
  }

  chain zone_forward {
    iifname "veth-${TENANT}-core" accept
  }
}
EOF
  else
    cat >>"$f" <<EOF
    # Permit-all: allow any VIP in upper /25 on 443
    ip saddr $tenant24 ip daddr $upper25 tcp dport 443 accept

    # Allow tenant->core transit veth
    iifname "veth-${TENANT}-core" accept
  }

  chain zone_forward {
    ip saddr $tenant24 accept
  }
}
EOF
  fi
}

apply() {
  write_main
  write_base
  write_sets
  write_core

  if [[ -n "${tconf:-}" && -f "$tconf" ]]; then
    build_tenant_fragment
  fi

  write_tenants_combined
  nft -f "$NFT_MAIN"
  systemctl enable --now nftables || true
  echo "Firewall applied via nftables."
}

case "${action:-apply}" in
  apply) apply;;
  *) die "Unknown action: $action";;
esac
