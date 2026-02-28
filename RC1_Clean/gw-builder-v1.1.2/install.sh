#!/usr/bin/env bash
set -euo pipefail

# gw-builder installer for Rocky Linux 9
# Installs bundle into /opt/gw-builder and optionally runs checks.
#
# Usage:
#   sudo ./install.sh [--dest /opt/gw-builder] [--run-check] [--run-init] [--run-core-setup]

DEST="/opt/gw-builder"
RUN_CHECK="no"
RUN_INIT="no"
RUN_CORE="no"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest) DEST="$2"; shift 2;;
    --run-check) RUN_CHECK="yes"; shift;;
    --run-init) RUN_INIT="yes"; shift;;
    --run-core-setup) RUN_CORE="yes"; shift;;
    -h|--help)
      cat <<EOF
gw-builder install.sh

Options:
  --dest <path>         Install destination (default: /opt/gw-builder)
  --run-check           Run gwctl.sh check after install
  --run-init            Run gwctl.sh init after install
  --run-core-setup      Run gwctl.sh core-setup after install

Example:
  sudo ./install.sh --run-check --run-init --run-core-setup
EOF
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: Must be run as root (use sudo)" >&2
  exit 1
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing gw-builder from:"
echo "  $SRC_DIR"
echo "to:"
echo "  $DEST"

mkdir -p "$DEST/modules"

cp -f "$SRC_DIR/gw.conf"    "$DEST/gw.conf"
cp -f "$SRC_DIR/gwctl.sh"   "$DEST/gwctl.sh"
cp -f "$SRC_DIR/README.txt" "$DEST/README.txt"
cp -f "$SRC_DIR/modules/"*.sh "$DEST/modules/"

chmod 755 "$DEST/gwctl.sh" "$DEST/modules/"*.sh
chmod 644 "$DEST/gw.conf" "$DEST/README.txt"

echo "Smoke check: running bash -n on scripts..."
bash -n "$DEST/gwctl.sh"
for f in "$DEST/modules/"*.sh; do bash -n "$f"; done
echo "OK: bash syntax checks passed."

if [[ "$RUN_CHECK" == "yes" ]]; then
  echo "Running: $DEST/gwctl.sh check"
  "$DEST/gwctl.sh" check
fi

if [[ "$RUN_INIT" == "yes" ]]; then
  echo "Running: $DEST/gwctl.sh init"
  "$DEST/gwctl.sh" init
fi

if [[ "$RUN_CORE" == "yes" ]]; then
  echo "Running: $DEST/gwctl.sh core-setup"
  "$DEST/gwctl.sh" core-setup
fi

echo "Done."
