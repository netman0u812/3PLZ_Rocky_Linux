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
  mkdir -p "$FRR_SNIPPETS_DIR"

  local neighbor="$VTI_REMOTE"

  cat >"${FRR_SNIPPETS_DIR}/${TENANT}.bgp.conf" <<EOF
configure terminal
vrf ${TENANT}
 exit-vrf
router bgp ${LOCAL_ASN} vrf ${TENANT}
 bgp router-id ${EGRESS_ID%/*}
 neighbor ${neighbor} remote-as ${REMOTE_ASN}
 neighbor ${neighbor} timers ${BGP_KEEPTIME} ${BGP_HOLDTIME}
 !
 address-family ipv4 unicast
  redistribute connected
 exit-address-family
exit
write memory
EOF

  echo "FRR BGP snippet ready: ${FRR_SNIPPETS_DIR}/${TENANT}.bgp.conf"
}

delete() {
  rm -f "${FRR_SNIPPETS_DIR}/${TENANT}.bgp.conf"
}

if [[ "$action" == "--delete" ]]; then delete; else create; fi
