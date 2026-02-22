#cat > rocky_vrf_vxlan_preflight.sh <<"EOF"
#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Rocky Linux 9/10 VRF/VXLAN preflight
#
# - Verifies:
#     * dnf is present
#     * iproute is installed
#     * systemd-networkd is available (installed + has unit)
#     * common kernel modules can be loaded: vrf, vxlan, 8021q, macvlan, ipvlan
# - Installs missing packages when possible (unless -D)
#
# This script does NOT:
#   - Change NetworkManager state
#   - Rename interfaces
#   - Configure any networking
#
# Flags:
#   -D  Dry-run: show what would be done, do not change anything
#   -h  Help
###############################################################################

DRY=0

usage() {
    cat <<EOFU
Usage: $0 [options]

Options:
  -D        Dry run: only show planned actions, no changes
  -h        Show this help

Checks performed:
  - dnf present
  - iproute package installed (ip, ip route, ip link, etc.)
  - systemd-networkd package and unit available (install if needed)
  - epel-release may be installed if required for systemd-networkd
  - Kernel modules: vrf, vxlan, 8021q, macvlan, ipvlan can be loaded

Examples:
  Plan only:
    sudo $0 -D

  Apply (install missing bits):
    sudo $0
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

while getopts "Dh" opt; do
    case "$opt" in
        D) DRY=1 ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

echo "=== Preflight: checking dnf ==="
if ! command -v dnf >/dev/null 2>&1; then
    echo "[ERR] dnf not found; cannot install required packages." >&2
    exit 1
fi
echo "[OK] dnf present"

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

echo
echo "=== Checking packages ==="
ensure_pkg iproute
ensure_networkd_available

echo
echo "=== Checking kernel modules ==="
mods=(vrf vxlan 8021q macvlan ipvlan)

for m in "${mods[@]}"; do
    if lsmod | grep -q "^${m}"; then
        echo "[OK] Module ${m} already loaded"
        continue
    fi
    if [ "$DRY" -eq 1 ]; then
        echo "[DRY] Would load module: ${m} (modprobe ${m})"
        continue
    fi
    if run_cmd modprobe "$m"; then
        echo "[OK] Loaded module ${m}"
    else
        echo "[WARN] Could not load module ${m}; ensure kernel has support" >&2
    fi
done

echo
echo "=== Summary ==="
echo " - dnf present"
echo " - iproute installed (or will be installed in non-dry mode)"
echo " - systemd-networkd available (or will be installed in non-dry mode)"
echo " - Kernel modules checked: ${mods[*]}"
echo
echo "Preflight complete."
EOF
#chmod +x rocky_vrf_vxlan_preflight.sh
