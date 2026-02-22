#cat > rocky_net_rewire.sh <<"EOF"
#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Rocky Linux 9/10 network rewire:
#
# Forward mode (default):
#  - Ensures required packages are installed (iproute, systemd-networkd)
#  - Disable NetworkManager
#  - Enable systemd-networkd + systemd-resolved
#  - Rename NICs via udev to:
#      * 2 Ethernet -> en0, en1 (sorted by MAC)
#      * 1 WLAN     -> wlan0
#  - Changes are persistent across reboots (udev rule + service changes)
#
# Reverse mode (-R):
#  - Remove custom udev naming rule
#  - Disable systemd-networkd + resolved
#  - Enable NetworkManager
#
# Flags:
#  -D  Dry-run: print actions, do not apply
#  -R  Reverse actions (restore NM)
#  -P  Permanent/non-interactive mode:
#        - Skip confirmation prompts
#        - Auto-apply udev trigger in forward mode
#  -h  Help
###############################################################################

DRY=0
REVERSE=0
PERMANENT=0

usage() {
    cat <<EOFU
Usage: $0 [options]

Options:
  -D        Dry run: show actions but do not apply changes
  -R        Reverse: restore NetworkManager, disable systemd-networkd,
            and remove /etc/udev/rules.d/70-persistent-net-custom.rules
  -P        Permanent/non-interactive mode:
            - Skip confirmation prompts
            - In forward mode, automatically reload udev rules
              and trigger rename (no prompt)
  -h        Show this help

Forward mode (default, without -R):
  - Ensures required packages are installed (iproute, systemd-networkd)
  - Stops & disables NetworkManager
  - Enables & starts systemd-networkd and systemd-resolved
  - Detects 2 Ethernet and 1 WLAN interface and maps them to:
        en0, en1  (Ethernet, sorted by MAC ascending)
        wlan0     (wireless)
  - Writes /etc/udev/rules.d/70-persistent-net-custom.rules
  - In interactive mode, asks whether to trigger udev now or reboot later
  - In -P mode, triggers udev automatically

Reverse mode (-R):
  - Removes the above udev rule, if present
  - Disables systemd-networkd and systemd-resolved
  - Enables and starts NetworkManager

Examples:
  Forward (plan only):
    sudo $0 -D

  Forward (apply, interactive):
    sudo $0

  Forward (apply, non-interactive/automation):
    sudo $0 -P

  Reverse (plan only):
    sudo $0 -D -R

  Reverse (apply):
    sudo $0 -R
EOFU
}

run_cmd() {
    if [ "$DRY" -eq 1 ]; then
        echo "[DRY] $*"
    else
        echo "[RUN] $*"
        "$@"
    fi
}

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root." >&2
    exit 1
fi

while getopts "DRPh" opt; do
    case "$opt" in
        D) DRY=1 ;;
        R) REVERSE=1 ;;
        P) PERMANENT=1 ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

UDEV_RULE="/etc/udev/rules.d/70-persistent-net-custom.rules"

ensure_pkg() {
    local pkg="$1"
    if dnf -q list installed "$pkg" >/dev/null 2>&1; then
        echo "[OK] Package $pkg already installed"
        return 0
    fi
    echo "[INFO] Package $pkg not installed"
    if [ "$DRY" -eq 1 ]; then
        echo "[DRY] Would install: dnf install -y $pkg"
        return 0
    fi
    run_cmd dnf install -y "$pkg"
}

ensure_networkd_available() {
    if systemctl list-unit-files | grep -q '^systemd-networkd.service'; then
        echo "[OK] systemd-networkd unit present"
        return 0
    fi

    echo "[INFO] systemd-networkd unit not found, ensuring package is installed"
    if ! dnf -q list installed systemd-networkd >/dev/null 2>&1; then
        if [ "$DRY" -eq 1 ]; then
            echo "[DRY] Would try: dnf install -y systemd-networkd"
            echo "[DRY] If that fails, would install epel-release then retry"
            return 0
        fi
        if ! dnf install -y systemd-networkd; then
            if ! dnf -q list installed epel-release >/dev/null 2>&1; then
                echo "[INFO] Installing epel-release to obtain systemd-networkd"
                run_cmd dnf install -y epel-release
            fi
            echo "[INFO] Retrying systemd-networkd install after enabling EPEL"
            run_cmd dnf install -y systemd-networkd
        fi
    fi

    if ! systemctl list-unit-files | grep -q '^systemd-networkd.service'; then
        echo "[ERR] systemd-networkd still not available after install attempts." >&2
        exit 1
    fi
    echo "[OK] systemd-networkd is available"
}

###############################################################################
# Reverse path: restore NetworkManager
###############################################################################
if [ "$REVERSE" -eq 1 ]; then
    echo "=== Reverse mode: restoring NetworkManager, removing custom udev rules ==="

    if [ -f "$UDEV_RULE" ]; then
        run_cmd rm -f "$UDEV_RULE"
        echo "Custom udev net rule removed: $UDEV_RULE"
    else
        echo "No custom udev net rule found at $UDEV_RULE"
    fi

    run_cmd systemctl stop systemd-networkd || true
    run_cmd systemctl disable systemd-networkd || true
    run_cmd systemctl stop systemd-resolved || true
    run_cmd systemctl disable systemd-resolved || true

    run_cmd systemctl enable NetworkManager
    run_cmd systemctl start NetworkManager

    echo "Reverse actions complete. NetworkManager is enabled again."
    exit 0
fi

###############################################################################
# Forward path: ensure packages, disable NM, enable networkd, rename interfaces
###############################################################################

echo "=== Preflight: checking required packages ==="
if ! command -v dnf >/dev/null 2>&1; then
    echo "[ERR] dnf not found; cannot install required packages." >&2
    exit 1
fi

ensure_pkg iproute
ensure_networkd_available

echo
echo "=== Current interfaces (before changes) ==="
ip -o link show | awk -F': ' '{print $1": "$2}'

echo
echo "=== Step 1: Disable NetworkManager, enable systemd-networkd ==="
echo "This will stop NetworkManager and enable systemd-networkd/resolved."
if [ "$DRY" -eq 0 ] && [ "$PERMANENT" -eq 0 ]; then
    read -r -p "Proceed with disabling NetworkManager? [y/N]: " CONFIRM
    CONFIRM=${CONFIRM:-n}
    if [[ "$CONFIRM" != [yY] ]]; then
        echo "Aborted."
        exit 1
    fi
fi

run_cmd systemctl stop NetworkManager || true
run_cmd systemctl disable NetworkManager || true

run_cmd systemctl enable systemd-networkd
run_cmd systemctl enable systemd-resolved
run_cmd systemctl start systemd-networkd
run_cmd systemctl start systemd-resolved

echo
echo "=== Step 2: Identify interfaces and build naming plan ==="

TMP_IFACES=$(mktemp)
while read -r idx name rest; do
    name="${name%:}"
    case "$name" in
        lo|veth*|virbr*|docker*|br-*|tap*|vxlan*|vlan*|bond*|macvlan*|ipvlan*|dummy*)
            continue
            ;;
    esac
    mac=$(cat "/sys/class/net/${name}/address" 2>/dev/null || echo "00:00:00:00:00:00")
    if [ -d "/sys/class/net/${name}/wireless" ]; then
        echo "wlan $mac $name" >> "$TMP_IFACES"
    else
        echo "eth  $mac $name" >> "$TMP_IFACES"
    fi
done < <(ip -o link show)

echo "Detected interfaces (type MAC name):"
cat "$TMP_IFACES"

ETH_LIST=$(grep '^eth ' "$TMP_IFACES" || true)
WLAN_LIST=$(grep '^wlan ' "$TMP_IFACES" || true)

eth_count=$(echo "$ETH_LIST" | sed '/^$/d' | wc -l || true)
wlan_count=$(echo "$WLAN_LIST" | sed '/^$/d' | wc -l || true)

echo "Ethernet count: $eth_count"
echo "WLAN count    : $wlan_count"

if [ "$eth_count" -ne 2 ] || [ "$wlan_count" -ne 1 ]; then
    echo "ERROR: Expected exactly 2 Ethernet and 1 WLAN interface; detected ${eth_count} eth, ${wlan_count} wlan." >&2
    echo "Aborting to avoid misnaming. Adjust script or host hardware accordingly."
    rm -f "$TMP_IFACES"
    exit 1
fi

MAP_FILE="/tmp/iface_rename_map.txt"
> "$MAP_FILE"

echo "$ETH_LIST" | sort -k2 | while read -r _ mac name; do
    echo "eth $mac $name" >> "$MAP_FILE"
done
echo "$WLAN_LIST" | while read -r _ mac name; do
    echo "wlan $mac $name" >> "$MAP_FILE"
done

echo
echo "Planned mapping:"
en_idx=0
wlan_idx=0
> /tmp/iface_rename_final.txt
while read -r type mac name; do
    if [ "$type" = "eth" ]; then
        newname="en${en_idx}"
        en_idx=$((en_idx+1))
    else
        newname="wlan${wlan_idx}"
        wlan_idx=$((wlan_idx+1))
    fi
    echo "${name} ${mac} ${newname}" >> /tmp/iface_rename_final.txt
done < "$MAP_FILE"

cat /tmp/iface_rename_final.txt | awk '{printf "  %s (%s) -> %s\n",$1,$2,$3}'

rm -f "$TMP_IFACES" "$MAP_FILE"

echo
echo "=== Step 3: Write udev rules for persistent naming ==="
if [ "$DRY" -eq 1 ]; then
    echo "Would write udev rules to $UDEV_RULE:"
    while read -r oldname mac newname; do
        [ -z "$oldname" ] && continue
        echo "SUBSYSTEM==\"net\", ACTION==\"add\", ATTR{address}==\"${mac}\", NAME=\"${newname}\""
    done < /tmp/iface_rename_final.txt
else
    echo "Writing udev rules to $UDEV_RULE..."
    > "$UDEV_RULE"
    while read -r oldname mac newname; do
        [ -z "$oldname" ] && continue
        echo "SUBSYSTEM==\"net\", ACTION==\"add\", ATTR{address}==\"${mac}\", NAME=\"${newname}\"" >> "$UDEV_RULE"
    done < /tmp/iface_rename_final.txt
endif

rm -f /tmp/iface_rename_final.txt

echo
echo "=== Step 4: Apply naming (udev trigger) or reboot later ==="
if [ "$DRY" -eq 0 ]; then
    if [ "$PERMANENT" -eq 1 ]; then
        run_cmd udevadm control --reload
        run_cmd udevadm trigger --subsystem-match=net
        echo "Names may have changed; current interfaces:"
        ip -o link show | awk -F': ' '{print $1": "$2}'
    else
        read -r -p "Apply udev rules now (udevadm trigger) or just reboot later? [a/R]: " ACT
        ACT=${ACT:-R}
        if [[ "$ACT" == [aA] ]]; then
            run_cmd udevadm control --reload
            run_cmd udevadm trigger --subsystem-match=net
            echo "Names may have changed; current interfaces:"
            ip -o link show | awk -F': ' '{print $1": "$2}'
        else
            echo "Skipping live trigger; please reboot to apply persistent names."
        fi
    fi
else
    echo "Dry-run: not triggering udev. After a real run, you may need to reboot."
fi

echo
echo "=== Step 5: Next steps ==="
cat <<'EON'
After reboot (or after udev trigger), you should see:
  en0, en1  - two Ethernet NICs
  wlan0     - one wireless NIC

Configure them with:
  - systemd-networkd .network/.netdev files, or
  - iproute2 commands (e.g. ip addr add ..., ip route add ...), or
  - your vrf_vxlan_setup.sh script to build VRFs and VXLAN overlays.

EON

echo "Done."
EOF
#chmod +x rocky_net_rewire.sh
