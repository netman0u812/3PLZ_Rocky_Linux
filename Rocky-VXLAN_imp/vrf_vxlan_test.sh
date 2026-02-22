#cat > vrf_vxlan_test.sh <<"EOF"
#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# VRF + VXLAN validation script
#
# Checks:
#   - VRF existence and state
#   - VXLAN device parameters
#   - Primary VLAN interface and IP
#   - Extra VLANs (if specified)
#   - Tenant macvlan/ipvlan (if specified)
#   - Physical interfaces tied to VRF (if specified)
#   - Optional ping to peer IP in VRF
###############################################################################

show_help() {
    cat <<EOFH
Usage: $0 [options]

Required:
  -v <vrf-name>        VRF name (e.g. vrf-blue)
  -t <table-id>        VRF table ID (e.g. 1001)
  -x <VNI>             VXLAN VNI (e.g. 10010)
  -V <vlan-id>         Primary VLAN ID (e.g. 10)

Optional:
  -r <remote-ip>       Expected remote underlay IP on VXLAN
  -p <peer-vrf-ip>     Peer IP in VRF to ping (e.g. 192.168.10.2)
  -A <vlan:ip,...>     Extra VLAN:IP pairs, for presence checking
  -M <tenant-type>     Tenant: macvlan or ipvlan (if used)
  -I <tenant-if>       Tenant interface name (e.g. macvlan0-10)
  -P <if1,if2,...>     Physical interfaces expected in VRF

Example:
  $0 -v vrf-blue -t 1001 -x 10010 -V 10 -r 10.0.0.2 -p 192.168.10.2
EOFH
}

VRF_NAME=""
VRF_TABLE=""
VNI=""
PRIMARY_VLAN_ID=""
REMOTE_UNDERLAY_IP=""
PEER_VRF_IP=""
EXTRA_VLANS=""
TENANT_TYPE=""
TENANT_IF=""
PHYS_IFS=""

while getopts "hv:t:x:V:r:p:A:M:I:P:" opt; do
    case "$opt" in
        h) show_help; exit 0 ;;
        v) VRF_NAME="$OPTARG" ;;
        t) VRF_TABLE="$OPTARG" ;;
        x) VNI="$OPTARG" ;;
        V) PRIMARY_VLAN_ID="$OPTARG" ;;
        r) REMOTE_UNDERLAY_IP="$OPTARG" ;;
        p) PEER_VRF_IP="$OPTARG" ;;
        A) EXTRA_VLANS="$OPTARG" ;;
        M) TENANT_TYPE="$OPTARG" ;;
        I) TENANT_IF="$OPTARG" ;;
        P) PHYS_IFS="$OPTARG" ;;
        *) show_help; exit 1 ;;
    esac
done

for v in VRF_NAME VRF_TABLE VNI PRIMARY_VLAN_ID; do
    if [ -z "${!v}" ]; then
        echo "Error: $v is required." >&2
        show_help
        exit 1
    fi
done

VXLAN_IF="vxlan${VNI}"
PRIMARY_VLAN_IF="${VXLAN_IF}.${PRIMARY_VLAN_ID}"
FAIL=0

check_cmd() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "[OK]  $desc"
    else
        echo "[ERR] $desc"
        FAIL=1
    fi
}

echo "=== VRF/VXLAN validation ==="

check_cmd "VRF device ${VRF_NAME} exists" ip link show "${VRF_NAME}"
check_cmd "VRF ${VRF_NAME} is UP" bash -c "ip link show ${VRF_NAME} | grep -q 'state UP'"
check_cmd "VRF table ${VRF_TABLE} present" bash -c "ip route show table ${VRF_TABLE} >/dev/null"

check_cmd "VXLAN device ${VXLAN_IF} exists" ip link show "${VXLAN_IF}"
check_cmd "VXLAN ${VXLAN_IF} has VNI ${VNI}" bash -c "ip -d link show ${VXLAN_IF} | grep -q \"vxlan id ${VNI}\""

if [ -n "${REMOTE_UNDERLAY_IP}" ]; then
    check_cmd "VXLAN ${VXLAN_IF} remote ${REMOTE_UNDERLAY_IP}" \
        bash -c "ip -d link show ${VXLAN_IF} | grep -q \"remote ${REMOTE_UNDERLAY_IP}\""
fi

check_cmd "Primary VLAN IF ${PRIMARY_VLAN_IF} exists" ip link show "${PRIMARY_VLAN_IF}"
check_cmd "Primary VLAN IF ${PRIMARY_VLAN_IF} is UP" \
    bash -c "ip link show ${PRIMARY_VLAN_IF} | grep -q 'state UP'"
check_cmd "Primary VLAN IF ${PRIMARY_VLAN_IF} enslaved to VRF ${VRF_NAME}" \
    bash -c "ip link show ${PRIMARY_VLAN_IF} | grep -q \"master ${VRF_NAME}\""
check_cmd "Primary VLAN IF ${PRIMARY_VLAN_IF} has an IP" \
    bash -c "ip addr show ${PRIMARY_VLAN_IF} | grep -q 'inet '"

if [ -n "${EXTRA_VLANS}" ]; then
    IFS=',' read -r -a PAIRS <<< "${EXTRA_VLANS}"
    for pair in "${PAIRS[@]}"; do
        vlan="${pair%%:*}"
        ipnet="${pair#*:}"
        VLAN_IF="${VXLAN_IF}.${vlan}"
        check_cmd "Extra VLAN IF ${VLAN_IF} exists" ip link show "${VLAN_IF}"
        check_cmd "Extra VLAN IF ${VLAN_IF} enslaved to VRF ${VRF_NAME}" \
            bash -c "ip link show ${VLAN_IF} | grep -q \"master ${VRF_NAME}\""
        if [ -n "${ipnet}" ]; then
            check_cmd "Extra VLAN IF ${VLAN_IF} has IP (expected ${ipnet})" \
                bash -c "ip addr show ${VLAN_IF} | grep -q \"inet ${ipnet%/*}\""
        fi
    done
fi

if [ -n "${TENANT_TYPE}" ] && [ -n "${TENANT_IF}" ]; then
    check_cmd "Tenant IF ${TENANT_IF} exists" ip link show "${TENANT_IF}"
    check_cmd "Tenant IF ${TENANT_IF} enslaved to VRF ${VRF_NAME}" \
        bash -c "ip link show ${TENANT_IF} | grep -q \"master ${VRF_NAME}\""
    check_cmd "Tenant IF ${TENANT_IF} has IP" \
        bash -c "ip addr show ${TENANT_IF} | grep -q 'inet '"
fi

if [ -n "${PHYS_IFS}" ]; then
    IFS=',' read -r -a PARR <<< "${PHYS_IFS}"
    for pif in "${PARR[@]}"; do
        check_cmd "Physical IF ${pif} enslaved to VRF ${VRF_NAME}" \
            bash -c "ip link show ${pif} | grep -q \"master ${VRF_NAME}\""
    done
fi

if [ -n "${PEER_VRF_IP}" ]; then
    echo "Pinging ${PEER_VRF_IP} from VRF ${VRF_NAME}..."
    if ip vrf exec "${VRF_NAME}" ping -c 3 -W 1 "${PEER_VRF_IP}" >/dev/null 2>&1; then
        echo "[OK]  Ping to ${PEER_VRF_IP} in VRF ${VRF_NAME} succeeded"
    else
        echo "[ERR] Ping to ${PEER_VRF_IP} in VRF ${VRF_NAME} failed"
        FAIL=1
    fi
fi

if [ "$FAIL" -eq 0 ]; then
    echo "All checks passed."
else
    echo "Some checks FAILED. Review the [ERR] lines above."
fi
EOF
#chmod +x vrf_vxlan_test.sh
