#cat > vrf_vxlan_setup.sh <<"EOF"
#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# VRF + VXLAN + VLAN + macvlan/ipvlan helper
#
# Features:
#   - Create/ensure VRF
#   - Create VXLAN interface on underlay
#   - Create one or more VLAN subinterfaces on VXLAN, with IPs in VRF
#   - Optionally create a macvlan/ipvlan tenant interface on a VLAN IF
#   - Optionally enslave one or more physical interfaces into the VRF
#
# Modes:
#   - Interactive: prompts for all values
#   - Non-interactive: pass all values with flags
#   - Profile: load defaults from a simple key=value file
#   - Dry-run: print ip commands without executing
#   - Emit systemd-networkd snippets to stdout (--emit-systemd)
###############################################################################

show_help() {
    cat <<EOFH
Usage: $0 [options]

General:
  -h                  Show this help and exit
  -n                  Non-interactive mode (all relevant options must be given)
  -f <profile-file>   Load defaults from key=value profile
  -D                  Dry-run; print actions but do not apply
  --emit-systemd      Print example systemd-networkd .network/.netdev snippets
                      matching the chosen parameters, then exit

Underlay / VXLAN:
  -U <ifname>         Underlay interface name (e.g. eth0)
  -u <ip/prefix>      Local underlay IP/prefix (e.g. 10.0.0.1/24)
  -g <ip>             Underlay default gateway (optional)
  -r <ip>             Remote underlay IP (other host)
  -x <VNI>            VXLAN VNI (e.g. 10010)
  -P <port>           VXLAN UDP port (default 4789)

VRF:
  -v <vrf-name>       VRF name (e.g. vrf-blue)
  -t <table-id>       VRF table ID (e.g. 1001)

Primary VLAN/IP (required when creating VXLAN):
  -V <vlan-id>        Primary VLAN ID on VXLAN (e.g. 10)
  -i <ip/prefix>      IP/prefix on primary VLAN in VRF (e.g. 192.168.10.1/24)

Extra VLANs:
  -A <vlan:ip,...>    Additional VLAN/IP pairs, comma-separated.
                      Example: -A 20:192.168.20.1/24,30:192.168.30.1/24

Tenant interface on VLAN (macvlan/ipvlan):
  -M <type>           Tenant type: "macvlan" or "ipvlan"
  -B <base-if>        Base interface for tenant (e.g. vxlan<VNI>.<VLAN>)
                      If omitted, uses primary VLAN interface.
  -s <mode>           macvlan/ipvlan mode (e.g. bridge, l2, l3; default bridge)
  -I <ip/prefix>      IP/prefix on tenant interface in VRF

Tie physical interfaces to VRF:
  -p <if1,if2,...>    Comma-separated list of physical interfaces to enslave
                      into the VRF (L3 only; you configure their IPs separately)

Profile file format (example):
  UNDERLAY_IF=eth0
  UNDERLAY_IP=10.0.0.1/24
  UNDERLAY_GW=10.0.0.254
  REMOTE_UNDERLAY_IP=10.0.0.2
  VRF_NAME=vrf-blue
  VRF_TABLE=1001
  VNI=10010
  VXLAN_PORT=4789
  PRIMARY_VLAN_ID=10
  PRIMARY_VRF_IP=192.168.10.1/24
  EXTRA_VLANS=20:192.168.20.1/24,30:192.168.30.1/24
  TENANT_TYPE=macvlan
  TENANT_MODE=bridge
  TENANT_IP=192.168.10.101/24
  PHYS_IFS=eth1,eth2

Examples:
  Host A:
    $0 -U eth0 -u 10.0.0.1/24 -r 10.0.0.2 -v vrf-blue -t 1001 -x 10010 \
       -V 10 -i 192.168.10.1/24

  Host B:
    $0 -U eth0 -u 10.0.0.2/24 -r 10.0.0.1 -v vrf-blue -t 1001 -x 10010 \
       -V 10 -i 192.168.10.2/24
EOFH
}

INTERACTIVE=1
DRY_RUN=0
PROFILE_FILE=""
EMIT_SYSTEMD=0

UNDERLAY_IF_DEFAULT="eth0"
UNDERLAY_IP_DEFAULT=""
UNDERLAY_GW_DEFAULT=""
REMOTE_UNDERLAY_IP_DEFAULT=""
VRF_NAME_DEFAULT="vrf-blue"
VRF_TABLE_DEFAULT="1001"
VNI_DEFAULT="10010"
VXLAN_PORT_DEFAULT="4789"
PRIMARY_VLAN_ID_DEFAULT="10"
PRIMARY_VRF_IP_DEFAULT=""
EXTRA_VLANS=""
TENANT_TYPE=""
TENANT_BASE_IF=""
TENANT_MODE_DEFAULT="bridge"
TENANT_IP=""
PHYS_IFS=""

run_cmd() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[DRY] $*"
    else
        "$@"
    fi
}

prompt_default() {
    local prompt="$1"
    local default="$2"
    local var
    if [ -n "$default" ]; then
        read -r -p "$prompt [$default]: " var
        echo "${var:-$default}"
    else
        read -r -p "$prompt: " var
        echo "$var"
    fi
}

emit_systemd_snippets() {
    local vx_if="$1"
    local uif="$2"
    local uip="$3"
    local ugw="$4"
    local remote="$5"
    local vrf="$6"
    local table="$7"
    local vni="$8"
    local vport="$9"
    local vlanid="${10}"
    local vlan_if="${vx_if}.${vlanid}"
    cat <<EOFS
# Example systemd-networkd snippets (adjust paths and details):

# /etc/systemd/network/10-${uif}.network
[Match]
Name=${uif}

[Network]
Address=${uip}
EOFS
    if [ -n "$ugw" ]; then
        cat <<EOFS
Gateway=${ugw}
EOFS
    fi
    cat <<EOFS

# /etc/systemd/network/20-${vrf}.netdev
[NetDev]
Name=${vrf}
Kind=vrf

[VRF]
Table=${table}

# /etc/systemd/network/21-${vx_if}.netdev
[NetDev]
Name=${vx_if}
Kind=vxlan

[VXLAN]
VNI=${vni}
Remote=${remote}
DestinationPort=${vport}

# /etc/systemd/network/22-${vlan_if}.netdev
[NetDev]
Name=${vlan_if}
Kind=vlan

[VLAN]
Id=${vlanid}

# /etc/systemd/network/23-${vrf}.network
[Match]
Name=${vrf}

[Network]

# /etc/systemd/network/24-${vlan_if}.network
[Match]
Name=${vlan_if}

[Network]
VRF=${vrf}
# Address=<your-primary-VRF-IP/prefix>

EOFS
}

LONG_OPTS="emit-systemd"
PARSED=$(getopt -o "hnf:U:u:g:r:x:P:v:t:V:i:A:M:B:s:I:p:D" -l "$LONG_OPTS" -- "$@") || {
    show_help
    exit 1
}
eval set -- "$PARSED"

while true; do
    case "$1" in
        -h) show_help; exit 0 ;;
        -n) INTERACTIVE=0; shift ;;
        -f) PROFILE_FILE="$2"; shift 2 ;;
        -U) UNDERLAY_IF="$2"; shift 2 ;;
        -u) UNDERLAY_IP="$2"; shift 2 ;;
        -g) UNDERLAY_GW="$2"; shift 2 ;;
        -r) REMOTE_UNDERLAY_IP="$2"; shift 2 ;;
        -x) VNI="$2"; shift 2 ;;
        -P) VXLAN_PORT="$2"; shift 2 ;;
        -v) VRF_NAME="$2"; shift 2 ;;
        -t) VRF_TABLE="$2"; shift 2 ;;
        -V) PRIMARY_VLAN_ID="$2"; shift 2 ;;
        -i) PRIMARY_VRF_IP="$2"; shift 2 ;;
        -A) EXTRA_VLANS="$2"; shift 2 ;;
        -M) TENANT_TYPE="$2"; shift 2 ;;
        -B) TENANT_BASE_IF="$2"; shift 2 ;;
        -s) TENANT_MODE="$2"; shift 2 ;;
        -I) TENANT_IP="$2"; shift 2 ;;
        -p) PHYS_IFS="$2"; shift 2 ;;
        -D) DRY_RUN=1; shift ;;
        --emit-systemd) EMIT_SYSTEMD=1; shift ;;
        --) shift; break ;;
        *) break ;;
    esac
done

if [ -n "$PROFILE_FILE" ]; then
    if [ ! -f "$PROFILE_FILE" ]; then
        echo "Profile file $PROFILE_FILE not found." >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    . "$PROFILE_FILE"
fi

if [ "${INTERACTIVE}" -eq 1 ]; then
    UNDERLAY_IF=${UNDERLAY_IF:-$(prompt_default "Underlay interface" "$UNDERLAY_IF_DEFAULT")}
    UNDERLAY_IP=${UNDERLAY_IP:-$(prompt_default "Local underlay IP/prefix" "$UNDERLAY_IP_DEFAULT")}
    UNDERLAY_GW=${UNDERLAY_GW:-$(prompt_default "Underlay gateway (blank for none)" "$UNDERLAY_GW_DEFAULT")}
    REMOTE_UNDERLAY_IP=${REMOTE_UNDERLAY_IP:-$(prompt_default "Remote underlay IP" "$REMOTE_UNDERLAY_IP_DEFAULT")}
    VRF_NAME=${VRF_NAME:-$(prompt_default "VRF name" "$VRF_NAME_DEFAULT")}
    VRF_TABLE=${VRF_TABLE:-$(prompt_default "VRF table ID" "$VRF_TABLE_DEFAULT")}
    VNI=${VNI:-$(prompt_default "VXLAN VNI" "$VNI_DEFAULT")}
    VXLAN_PORT=${VXLAN_PORT:-$(prompt_default "VXLAN UDP port" "$VXLAN_PORT_DEFAULT")}
    PRIMARY_VLAN_ID=${PRIMARY_VLAN_ID:-$(prompt_default "Primary VLAN ID" "$PRIMARY_VLAN_ID_DEFAULT")}
    PRIMARY_VRF_IP=${PRIMARY_VRF_IP:-$(prompt_default "Primary VLAN IP/prefix in VRF" "$PRIMARY_VRF_IP_DEFAULT")}
    if [ -z "${EXTRA_VLANS}" ]; then
        EXTRA_VLANS=$(prompt_default "Additional VLAN:IP pairs (comma; empty for none)" "")
    fi
    if [ -z "${TENANT_TYPE}" ]; then
        TENANT_TYPE=$(prompt_default "Tenant type (macvlan/ipvlan/empty for none)" "")
    fi
    if [ -n "${TENANT_TYPE}" ] && [ -z "${TENANT_IP}" ]; then
        TENANT_IP=$(prompt_default "Tenant IP/prefix in VRF" "")
    fi
    if [ -z "${PHYS_IFS}" ]; then
        PHYS_IFS=$(prompt_default "Physical interfaces to tie to VRF (comma; empty for none)" "")
    fi
fi

REQUIRED_VARS=(UNDERLAY_IF UNDERLAY_IP REMOTE_UNDERLAY_IP VRF_NAME VRF_TABLE VNI PRIMARY_VLAN_ID PRIMARY_VRF_IP)
for v in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!v:-}" ]; then
        echo "Error: $v is required (or run without -n for interactive mode)." >&2
        exit 1
    fi
done
VXLAN_PORT=${VXLAN_PORT:-$VXLAN_PORT_DEFAULT}
TENANT_MODE=${TENANT_MODE:-$TENANT_MODE_DEFAULT}
VXLAN_IF="vxlan${VNI}"
PRIMARY_VLAN_IF="${VXLAN_IF}.${PRIMARY_VLAN_ID}"

if [ "$EMIT_SYSTEMD" -eq 1 ]; then
    emit_systemd_snippets "$VXLAN_IF" "$UNDERLAY_IF" "$UNDERLAY_IP" "$UNDERLAY_GW" \
        "$REMOTE_UNDERLAY_IP" "$VRF_NAME" "$VRF_TABLE" "$VNI" "$VXLAN_PORT" "$PRIMARY_VLAN_ID"
    exit 0
fi

echo "=== Summary ==="
echo "Underlay interface : $UNDERLAY_IF"
echo "Local underlay IP  : $UNDERLAY_IP"
echo "Underlay gateway   : ${UNDERLAY_GW:-<none>}"
echo "Remote underlay IP : $REMOTE_UNDERLAY_IP"
echo "VRF name           : $VRF_NAME"
echo "VRF table ID       : $VRF_TABLE"
echo "VXLAN IF/VNI/port  : $VXLAN_IF / $VNI / $VXLAN_PORT"
echo "Primary VLAN ID    : $PRIMARY_VLAN_ID"
echo "Primary VLAN IF    : $PRIMARY_VLAN_IF"
echo "Primary VRF IP     : $PRIMARY_VRF_IP"
echo "Extra VLANs        : ${EXTRA_VLANS:-<none>}"
echo "Tenant type        : ${TENANT_TYPE:-<none>}"
echo "Tenant base IF     : ${TENANT_BASE_IF:-<auto primary VLAN>}"
echo "Tenant mode        : $TENANT_MODE"
echo "Tenant IP          : ${TENANT_IP:-<none>}"
echo "Physical IFs->VRF  : ${PHYS_IFS:-<none>}"
echo "Dry-run            : $([ $DRY_RUN -eq 1 ] && echo yes || echo no)"
echo

if [ "${INTERACTIVE}" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
    read -r -p "Proceed with configuration? [y/N]: " CONFIRM
    CONFIRM=${CONFIRM:-n}
    if [[ "$CONFIRM" != [yY] ]]; then
        echo "Aborted."
        exit 1
    fi
fi

echo "=== Applying configuration ==="

run_cmd modprobe vrf || true
run_cmd modprobe vxlan || true
run_cmd modprobe 8021q || true
run_cmd modprobe macvlan || true
run_cmd modprobe ipvlan || true

echo "Configuring underlay on ${UNDERLAY_IF}..."
run_cmd ip addr flush dev "${UNDERLAY_IF}" || true
run_cmd ip addr add "${UNDERLAY_IP}" dev "${UNDERLAY_IF}"
run_cmd ip link set "${UNDERLAY_IF}" up
if [ -n "${UNDERLAY_GW}" ]; then
    run_cmd ip route del default 2>/dev/null || true
    run_cmd ip route add default via "${UNDERLAY_GW}" dev "${UNDERLAY_IF}"
fi

echo "Configuring VRF ${VRF_NAME} (table ${VRF_TABLE})..."
if ip link show "${VRF_NAME}" >/dev/null 2>&1; then
    :
else
    run_cmd ip link add "${VRF_NAME}" type vrf table "${VRF_TABLE}"
fi
run_cmd ip link set "${VRF_NAME}" up

echo "Configuring VXLAN ${VXLAN_IF}..."
if ip link show "${VXLAN_IF}" >/dev/null 2>&1; then
    run_cmd ip link del "${VXLAN_IF}"
fi
run_cmd ip link add "${VXLAN_IF}" type vxlan \
    id "${VNI}" dev "${UNDERLAY_IF}" \
    remote "${REMOTE_UNDERLAY_IP}" \
    dstport "${VXLAN_PORT}"
run_cmd ip link set "${VXLAN_IF}" up

echo "Configuring primary VLAN ${PRIMARY_VLAN_ID} (${PRIMARY_VLAN_IF})..."
if ip link show "${PRIMARY_VLAN_IF}" >/dev/null 2>&1; then
    run_cmd ip link del "${PRIMARY_VLAN_IF}"
fi
run_cmd ip link add link "${VXLAN_IF}" name "${PRIMARY_VLAN_IF}" type vlan id "${PRIMARY_VLAN_ID}"
run_cmd ip link set "${PRIMARY_VLAN_IF}" up
run_cmd ip link set "${PRIMARY_VLAN_IF}" master "${VRF_NAME}"
run_cmd ip addr flush dev "${PRIMARY_VLAN_IF}" || true
run_cmd ip addr add "${PRIMARY_VRF_IP}" dev "${PRIMARY_VLAN_IF}"

if [ -n "${EXTRA_VLANS}" ]; then
    IFS=',' read -r -a PAIRS <<< "${EXTRA_VLANS}"
    for pair in "${PAIRS[@]}"; do
        vlan="${pair%%:*}"
        ipnet="${pair#*:}"
        [ -z "$vlan" ] && continue
        VLAN_IF="${VXLAN_IF}.${vlan}"
        echo "Configuring extra VLAN ${vlan} (${VLAN_IF}) with IP ${ipnet}..."
        if ip link show "${VLAN_IF}" >/dev/null 2>&1; then
            run_cmd ip link del "${VLAN_IF}"
        fi
        run_cmd ip link add link "${VXLAN_IF}" name "${VLAN_IF}" type vlan id "${vlan}"
        run_cmd ip link set "${VLAN_IF}" up
        run_cmd ip link set "${VLAN_IF}" master "${VRF_NAME}"
        if [ -n "${ipnet}" ]; then
            run_cmd ip addr flush dev "${VLAN_IF}" || true
            run_cmd ip addr add "${ipnet}" dev "${VLAN_IF}"
        fi
    done
fi

if [ -n "${TENANT_TYPE}" ]; then
    case "${TENANT_TYPE}" in
        macvlan|ipvlan) ;;
        *)
            echo "Invalid tenant type: ${TENANT_TYPE}. Use macvlan or ipvlan." >&2
            exit 1
            ;;
    esac
    BASE_IF="${TENANT_BASE_IF:-$PRIMARY_VLAN_IF}"
    TENANT_IF="${TENANT_TYPE}0-${PRIMARY_VLAN_ID}"
    echo "Configuring ${TENANT_TYPE} tenant ${TENANT_IF} on ${BASE_IF} mode ${TENANT_MODE}..."
    if ip link show "${TENANT_IF}" >/dev/null 2>&1; then
        run_cmd ip link del "${TENANT_IF}"
    fi
    if [ "${TENANT_TYPE}" = "macvlan" ]; then
        run_cmd ip link add "${TENANT_IF}" link "${BASE_IF}" type macvlan mode "${TENANT_MODE}"
    else
        run_cmd ip link add "${TENANT_IF}" link "${BASE_IF}" type ipvlan mode "${TENANT_MODE}"
    fi
    run_cmd ip link set "${TENANT_IF}" up
    run_cmd ip link set "${TENANT_IF}" master "${VRF_NAME}"
    if [ -n "${TENANT_IP}" ]; then
        run_cmd ip addr flush dev "${TENANT_IF}" || true
        run_cmd ip addr add "${TENANT_IP}" dev "${TENANT_IF}"
    fi
fi

if [ -n "${PHYS_IFS}" ]; then
    IFS=',' read -r -a PHYS_ARR <<< "${PHYS_IFS}"
    for pif in "${PHYS_ARR[@]}"; do
        [ -z "${pif}" ] && continue
        echo "Enslaving physical interface ${pif} into VRF ${VRF_NAME}..."
        run_cmd ip link set "${pif}" master "${VRF_NAME}"
    done
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "Dry-run complete (no changes applied)."
    exit 0
fi

echo "=== VRF state ==="
ip vrf show
ip -d link show "${VRF_NAME}"
ip addr show dev "${PRIMARY_VLAN_IF}"
ip route show table "${VRF_TABLE}"

echo "Done. Use: ip vrf exec ${VRF_NAME} ping <peer IP in VRF>"
EOF
#chmod +x vrf_vxlan_setup.sh
