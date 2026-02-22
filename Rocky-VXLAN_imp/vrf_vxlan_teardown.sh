#cat > vrf_vxlan_teardown.sh <<"EOF"
#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# VRF + VXLAN teardown script
#
# Removes:
#   - VXLAN device (vxlan<VNI>)
#   - Primary VLAN IF (vxlan<VNI>.<VLAN>)
#   - Extra VLAN IFs (optionally)
#   - Tenant macvlan/ipvlan IF (optionally)
#   - Optionally the VRF device itself
#
# It does NOT touch underlay IPs/routes by default.
###############################################################################

show_help() {
    cat <<EOFH
Usage: $0 [options]

Required:
  -v <vrf-name>        VRF name (e.g. vrf-blue)
  -x <VNI>             VXLAN VNI (e.g. 10010)
  -V <vlan-id>         Primary VLAN ID (e.g. 10)

Optional:
  -A <vlan,...>        Extra VLAN IDs to remove (comma-separated)
  -M <tenant-if>       Tenant interface name to remove (e.g. macvlan0-10)
  -R                   Also remove the VRF device after cleanup

Examples:
  # Remove VXLAN, VLAN 10, keep VRF
  $0 -v vrf-blue -x 10010 -V 10

  # Remove VXLAN, VLAN 10, VLAN 20 and tenant IF, and delete VRF
  $0 -v vrf-blue -x 10010 -V 10 -A 20,30 -M macvlan0-10 -R
EOFH
}

VRF_NAME=""
VNI=""
PRIMARY_VLAN_ID=""
EXTRA_VLANS=""
TENANT_IF=""
REMOVE_VRF=0

while getopts "hv:x:V:A:M:R" opt; do
    case "$opt" in
        h) show_help; exit 0 ;;
        v) VRF_NAME="$OPTARG" ;;
        x) VNI="$OPTARG" ;;
        V) PRIMARY_VLAN_ID="$OPTARG" ;;
        A) EXTRA_VLANS="$OPTARG" ;;
        M) TENANT_IF="$OPTARG" ;;
        R) REMOVE_VRF=1 ;;
        *) show_help; exit 1 ;;
    esac
done

for v in VRF_NAME VNI PRIMARY_VLAN_ID; do
    if [ -z "${!v}" ]; then
        echo "Error: $v is required." >&2
        show_help
        exit 1
    fi
done

VXLAN_IF="vxlan${VNI}"
PRIMARY_VLAN_IF="${VXLAN_IF}.${PRIMARY_VLAN_ID}"

echo "=== Teardown summary ==="
echo "VRF name        : $VRF_NAME"
echo "VXLAN IF / VNI  : $VXLAN_IF / $VNI"
echo "Primary VLAN IF : $PRIMARY_VLAN_IF"
echo "Extra VLAN IDs  : ${EXTRA_VLANS:-<none>}"
echo "Tenant IF       : ${TENANT_IF:-<none>}"
echo "Remove VRF      : $([ $REMOVE_VRF -eq 1 ] && echo yes || echo no)"
echo

read -r -p "Proceed with teardown? [y/N]: " CONFIRM
CONFIRM=${CONFIRM:-n}
if [[ "$CONFIRM" != [yY] ]]; then
    echo "Aborted."
    exit 1
fi

echo "=== Removing tenant interface (if any) ==="
if [ -n "${TENANT_IF}" ]; then
    if ip link show "${TENANT_IF}" >/dev/null 2>&1; then
        echo "Deleting tenant IF ${TENANT_IF}..."
        ip link set "${TENANT_IF}" down || true
        ip link del "${TENANT_IF}" || true
    else
        echo "Tenant IF ${TENANT_IF} not present."
    fi
fi

echo "=== Removing extra VLAN interfaces (if any) ==="
if [ -n "${EXTRA_VLANS}" ]; then
    IFS=',' read -r -a VARR <<< "${EXTRA_VLANS}"
    for vlan in "${VARR[@]}"; do
        [ -z "$vlan" ] && continue
        VLAN_IF="${VXLAN_IF}.${vlan}"
        if ip link show "${VLAN_IF}" >/dev/null 2>&1; then
            echo "Deleting extra VLAN IF ${VLAN_IF}..."
            ip link set "${VLAN_IF}" down || true
            ip link del "${VLAN_IF}" || true
        else
            echo "Extra VLAN IF ${VLAN_IF} not present."
        fi
    done
fi

echo "=== Removing primary VLAN interface ==="
if ip link show "${PRIMARY_VLAN_IF}" >/dev/null 2>&1; then
    echo "Deleting ${PRIMARY_VLAN_IF}..."
    ip link set "${PRIMARY_VLAN_IF}" down || true
    ip link del "${PRIMARY_VLAN_IF}" || true
else
    echo "Primary VLAN IF ${PRIMARY_VLAN_IF} not present."
fi

echo "=== Removing VXLAN interface ==="
if ip link show "${VXLAN_IF}" >/dev/null 2>&1; then
    echo "Deleting ${VXLAN_IF}..."
    ip link set "${VXLAN_IF}" down || true
    ip link del "${VXLAN_IF}" || true
else
    echo "VXLAN IF ${VXLAN_IF} not present."
fi

if [ "$REMOVE_VRF" -eq 1 ]; then
    echo "=== Removing VRF device ${VRF_NAME} ==="
    if ip link show "${VRF_NAME}" >/dev/null 2>&1; then
        ip link set "${VRF_NAME}" down || true
        ip link del "${VRF_NAME}" || true
    else
        echo "VRF device ${VRF_NAME} not present."
    fi
fi

echo "Teardown complete."
EOF
#chmod +x vrf_vxlan_teardown.sh
