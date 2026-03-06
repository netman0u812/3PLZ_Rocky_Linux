#!/bin/bash
# RC3-build-packages.sh — Build all GW Platform RC3 deployment packages
# Usage: chmod +x RC3-build-packages.sh && ./RC3-build-packages.sh
# Output: ./RC3-Packages/*.zip + *.sha256
set -euo pipefail

# ── Portable compatibility (Linux + macOS) ──────────────────────
sha256_cmd() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}
zip_clean() {
  # Suppress macOS __MACOSX metadata entries
  local out="$1"; shift
  zip -q "$out" "$@"
  if [[ "$(uname)" == "Darwin" ]]; then
    zip -d "$out" '__MACOSX*' '*.DS_Store' 2>/dev/null || true
  fi
}
# ─────────────────────────────────────────────────────────────────

TODAY=$(date +%Y-%m-%d)
BASE="$(pwd)/RC3-Build"
OUT="$(pwd)/RC3-Packages"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "  $*"; }

# Verify all source component zips are present before starting
REQUIRED_ZIPS=(
  "gw-registry-v0.1.1-RC1.zip"
  "gw-admin-portal-v0.2.2-RC3.zip"
  "gw-perfmon-v0.1.0.zip"
  "gw-builder-v1.1.3-RC1.zip"
  "gw-builder-pki-tools-v1.1.1-RC1.zip"
  "gw-sshproxy-v0.1.2.zip"
  "gw-inspection-v0.1.1.zip"
)

echo "Checking required source packages..."
for z in "${REQUIRED_ZIPS[@]}"; do
  [[ -f "source-packages/$z" ]] \
    || die "Missing source package: source-packages/$z"
  log "OK  $z"
done

mkdir -p "$OUT"
mkdir -p "$BASE/scripts" "$BASE/configs" "$BASE/docs"
mkdir -p "$BASE/seed/registry" "$BASE/seed/portal" "$BASE/seed/pki"
mkdir -p "$BASE/seed/manifests" "$BASE/seed/packages"

echo ""
echo "Building GW Platform RC3 packages — $TODAY"
echo ""

# ─────────────────────────────────────────────────────────────────
# SCRIPTS
# ─────────────────────────────────────────────────────────────────

# --- gwreg-safe: selective pre-write backup wrapper ---
cat > "$BASE/scripts/gwreg-safe" << 'SCRIPT'
#!/bin/bash
# gwreg-safe — Wraps gwreg with pre-write backup.
# Only backs up on state-mutating commands; read-only commands pass through.
set -euo pipefail

BACKUP_DIR=/opt/backups/gwreg
DB=/opt/gw-registry/data/registry.db
LOG=/var/log/gwreg-safe.log
WRITE_CMDS="init node tenant promote drain"

cmd="${1:-}"
needs_backup=false
for wc in $WRITE_CMDS; do
  [[ "$cmd" == "$wc" ]] && needs_backup=true && break
done

if $needs_backup; then
  mkdir -p "$BACKUP_DIR"
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="$BACKUP_DIR/registry-${stamp}.db"
  sqlite3 "$DB" ".backup '$backup'" 2>/dev/null \
    && echo "[$(isotime)] backup: $backup cmd: $*" >> "$LOG" \
    || echo "[$(isotime)] WARN: backup failed, proceeding" >> "$LOG"
fi

exec /opt/gw-registry/bin/gwreg-real "$@"
SCRIPT

# --- gwreg-rollback: time-window restore, Python-parsed timestamps ---
cat > "$BASE/scripts/gwreg-rollback" << 'SCRIPT'
#!/bin/bash
# gwreg-rollback — Restore registry to backup closest to a time window.
# Usage: gwreg-rollback [--dry-run] <5m|10m|30m|1h|2h|4h|6h|12h|24h>
set -euo pipefail

BACKUP_DIR=/opt/backups/gwreg
DB=/opt/gw-registry/data/registry.db
LOG=/var/log/gwreg-rollback.log

die() { echo "ERROR: $*" >&2; exit 1; }

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true && shift

case "${1:-}" in
  5m)  SBACK=300   ;; 10m) SBACK=600   ;; 30m) SBACK=1800  ;;
  1h)  SBACK=3600  ;; 2h)  SBACK=7200  ;; 4h)  SBACK=14400 ;;
  6h)  SBACK=21600 ;; 12h) SBACK=43200 ;; 24h) SBACK=86400 ;;
  *) echo "Usage: gwreg-rollback [--dry-run] <5m|10m|30m|1h|2h|4h|6h|12h|24h>"; exit 1 ;;
esac

[[ -f "$DB" ]]            || die "Registry DB not found: $DB"
[[ -d "$BACKUP_DIR" ]]    || die "Backup dir not found: $BACKUP_DIR"

TARGET_EPOCH=$(( $(date +%s) - SBACK ))
echo "Target rollback point: $(epoch_to_date "$TARGET_EPOCH")"

BEST_MATCH=""
BEST_EPOCH=0

while IFS= read -r f; do
  fname="$(basename "$f")"
  fepoch="$(python3 -c "
import re, sys
from datetime import datetime
m = re.match(r'registry-(\d{8})-(\d{6})\.db', sys.argv[1])
if not m: sys.exit(1)
dt = datetime.strptime(m.group(1)+m.group(2), '%Y%m%d%H%M%S')
print(int(dt.timestamp()))
" "$fname" 2>/dev/null || echo "")"
  [[ -z "$fepoch" ]] && continue
  if [[ "$fepoch" -le "$TARGET_EPOCH" && "$fepoch" -gt "$BEST_EPOCH" ]]; then
    BEST_EPOCH="$fepoch"; BEST_MATCH="$f"
  fi
done < <(find "$BACKUP_DIR" -maxdepth 1 -name "registry-*.db" | sort)

[[ -z "$BEST_MATCH" ]] && die "No backup found at or before target time."

echo "Best match: $BEST_MATCH ($(epoch_to_date "$BEST_EPOCH"))"
$DRY_RUN && echo "[DRY-RUN] No changes made." && exit 0

read -r -p "Apply rollback? [yes/N] " C
[[ "$C" != "yes" ]] && echo "Aborted." && exit 0

PRE="$BACKUP_DIR/registry-pre-rollback-$(date +%Y%m%d-%H%M%S).db"
sqlite3 "$DB" ".backup '$PRE'" || die "Could not back up current state."

systemctl stop gw-registry || true
if sqlite3 "$DB" ".restore '$BEST_MATCH'"; then
  systemctl start gw-registry; sleep 2
  if systemctl is-active --quiet gw-registry; then
    echo "[SUCCESS] Registry restored."
    echo "[$(isotime)] rollback: $BEST_MATCH by $(whoami)" >> "$LOG"
  else
    echo "[ERROR] Registry failed to start. Reverting to pre-rollback state."
    sqlite3 "$DB" ".restore '$PRE'" && systemctl start gw-registry \
      || die "CRITICAL: Manual recovery required. Pre-rollback backup: $PRE"
  fi
else
  sqlite3 "$DB" ".restore '$PRE'" && systemctl start gw-registry \
    || die "CRITICAL: Manual recovery required. Pre-rollback backup: $PRE"
fi
SCRIPT

# --- gw-forward-policy ---
cat > "$BASE/scripts/gw-forward-policy" << 'SCRIPT'
#!/bin/bash
# gw-forward-policy — Toggle nftables forward chain policy on GW nodes.
# Usage: gw-forward-policy [strict|open|status]
set -euo pipefail

LOG=/var/log/gw-policy.log
TABLE="inet gw_filter"
CHAIN="forward"

die()       { echo "ERROR: $*" >&2; exit 1; }
need_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"; }

case "${1:-}" in
  strict)
    need_root
    nft flush chain $TABLE $CHAIN
    nft chain $TABLE $CHAIN '{ policy drop; }'
    nft add rule $TABLE $CHAIN ct state established,related accept
    echo "[$(isotime)] $(hostname): forward policy -> STRICT" | tee -a "$LOG"
    ;;
  open)
    need_root
    nft chain $TABLE $CHAIN '{ policy accept; }'
    echo "[$(isotime)] $(hostname): forward policy -> OPEN" | tee -a "$LOG"
    echo "WARN: Forward policy is OPEN. Restore with 'strict' when done." >&2
    ;;
  status)
    nft list chain $TABLE $CHAIN | grep -E 'policy|type'
    ;;
  *)
    echo "Usage: gw-forward-policy [strict|open|status]"
    exit 1
    ;;
esac
SCRIPT

# --- gw-seed-sync ---
cat > "$BASE/scripts/gw-seed-sync" << 'SCRIPT'
#!/bin/bash
# gw-seed-sync — Rsync portal shadow to local persistent seed copy.
set -euo pipefail

SHADOW=/mnt/portal-shadow
LOCAL=/home/gw-seed
LOG=/var/log/gw-seed-sync.log
LOCK=/var/run/gw-seed-sync.lock

exec 9>"$LOCK"
flock -n 9 || { echo "[$(isotime)] skipped: lock held" >> "$LOG"; exit 0; }

if ! mountpoint -q "$SHADOW"; then
  echo "[$(isotime)] WARNING: Shadow mount unavailable — retaining local copy" >> "$LOG"
  exit 0
fi

rsync -az --delete \
  --exclude='*.tmp' --exclude='*.lock' --exclude='pki/*.key' \
  "$SHADOW/" "$LOCAL/" >> "$LOG" 2>&1

echo "[$(isotime)] Seed sync complete" >> "$LOG"
SCRIPT

# --- gw-portal-redeploy ---
cat > "$BASE/scripts/gw-portal-redeploy" << 'SCRIPT'
#!/bin/bash
# gw-portal-redeploy — Redeploy portal or GW node from local seed.
# Usage: gw-portal-redeploy [--local | --target <ip> --user <admin-user>]
set -euo pipefail

SEED=/home/gw-seed
LOG=/var/log/gw-portal-redeploy.log
PORTAL_KEY="${PORTAL_KEY:-/var/lib/gw-admin-portal/sshkeys/gwportal_ed25519}"
KNOWN_HOSTS=/etc/ssh/ssh_known_hosts

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[$(isotime)] $*" | tee -a "$LOG"; }

MODE="local"; TARGET=""; REMOTE_USER=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; MODE="remote"; shift ;;
    --user)   REMOTE_USER="$2"; shift ;;
    --local)  MODE="local" ;;
    *) die "Unknown argument: $1" ;;
  esac; shift
done

if [[ "$MODE" == "remote" ]]; then
  [[ -n "$TARGET" ]]      || die "--target <ip> required"
  [[ -n "$REMOTE_USER" ]] || die "--user <admin-user> required"
  [[ -f "$PORTAL_KEY" ]]  || die "Portal SSH key not found: $PORTAL_KEY"
fi

log "Verifying seed checksums..."
sha256_cmd -c "$SEED/packages/"*.sha256 || die "Checksum failure — aborting."

log "Redeploy starting — mode=$MODE target=${TARGET:-localhost}"

if [[ "$MODE" == "remote" ]]; then
  log "Syncing seed to $TARGET..."
  rsync -az -e "ssh -i $PORTAL_KEY -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$KNOWN_HOSTS" \
    --exclude='pki/*.key' "$SEED/" "${REMOTE_USER}@${TARGET}:/home/gw-seed/" \
    || die "Seed sync to $TARGET failed"
  SSH="ssh -i $PORTAL_KEY -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$KNOWN_HOSTS ${REMOTE_USER}@${TARGET}"
else
  SSH="bash"
fi

$SSH -s << 'REMOTE'
set -euo pipefail; SEED=/home/gw-seed
setenforce 0 2>/dev/null || true
sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config 2>/dev/null || true
dnf -y install strongswan frr nftables iproute jq sqlite python3 chrony nfs-utils rsync
sha256_cmd -c "$SEED/packages/"*.sha256 || { echo "Target checksum failure"; exit 1; }
unzip -o "$SEED/packages/gw-registry-v0.1.1-RC1.zip"         -d /opt/
unzip -o "$SEED/packages/gw-admin-portal-v0.2.2-RC3.zip"      -d /opt/
unzip -o "$SEED/packages/gw-perfmon-v0.1.0.zip"               -d /opt/
unzip -o "$SEED/packages/gw-builder-pki-tools-v1.1.1-RC1.zip" -d /opt/
mkdir -p /opt/gw-registry/data
sqlite3 /opt/gw-registry/data/registry.db ".restore '$SEED/registry/registry.db'"
cp -r "$SEED/portal/"* /opt/gw-admin-portal/
cp -r "$SEED/pki/"*    /etc/gateway/pki/
ln -sf /opt/gw-registry/bin/gwreg /usr/local/bin/gwreg-real
systemctl enable --now gw-registry gw-admin-portal chronyd
REMOTE

log "Redeploy complete — mode=$MODE target=${TARGET:-localhost}"
SCRIPT

# --- gw-manifest-push ---
cat > "$BASE/scripts/gw-manifest-push" << 'SCRIPT'
#!/bin/bash
# gw-manifest-push — Push rendered manifest to GW nodes and apply.
# Usage: gw-manifest-push <manifest-file> <tenant>
set -euo pipefail

MANIFEST="${1:-}"; TENANT="${2:-}"
PORTAL_KEY="${PORTAL_KEY:-/var/lib/gw-admin-portal/sshkeys/gwportal_ed25519}"
KNOWN_HOSTS=/etc/ssh/ssh_known_hosts
REMOTE_PATH_BASE=/etc/gateway/registry/tenants
LOG=/var/log/gw-manifest-push.log

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[$(isotime)] $*" | tee -a "$LOG"; }

[[ -n "$MANIFEST" && -n "$TENANT" ]] || die "Usage: gw-manifest-push <manifest-file> <tenant>"
[[ -f "$MANIFEST" ]]   || die "Manifest not found: $MANIFEST"
[[ -f "$PORTAL_KEY" ]] || die "Portal SSH key not found: $PORTAL_KEY"

python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$MANIFEST" \
  || die "Manifest is not valid JSON: $MANIFEST"

if [[ -n "${GW_NODES:-}" ]]; then
  IFS=',' read -ra nodes <<< "$GW_NODES"
else
  nodes=()
  while IFS= read -r ip; do
    [[ -n "$ip" ]] && nodes+=("$ip")
  done < <(gwreg tenant show "$TENANT" 2>/dev/null \
    | grep -E 'mgmt_ip' | awk -F: '{gsub(/[[:space:]"]/,"",$2); print $2}' || true)
fi

[[ "${#nodes[@]}" -gt 0 ]] \
  || die "No GW nodes found for tenant $TENANT. Set GW_NODES=ip1,ip2 or check registry."

REMOTE_PATH="${REMOTE_PATH_BASE}/${TENANT}.json"
FAIL=0

for gw in "${nodes[@]}"; do
  log "Pushing to $gw..."
  if scp -i "$PORTAL_KEY" \
         -o StrictHostKeyChecking=yes \
         -o UserKnownHostsFile="$KNOWN_HOSTS" \
         -o ConnectTimeout=10 \
         "$MANIFEST" "gwportal@${gw}:${REMOTE_PATH}" \
     && ssh -i "$PORTAL_KEY" \
            -o StrictHostKeyChecking=yes \
            -o UserKnownHostsFile="$KNOWN_HOSTS" \
            -o ConnectTimeout=10 \
            "gwportal@${gw}" \
            "gwctl tenant-apply --manifest ${REMOTE_PATH}"; then
    log "[OK]   $gw"
  else
    log "[FAIL] $gw"
    FAIL=$(( FAIL + 1 ))
  fi
done

[[ "$FAIL" -gt 0 ]] && die "$FAIL node(s) failed. Check $LOG."
log "Manifest push complete for tenant=$TENANT"
SCRIPT

# --- gwreg-retention ---
cat > "$BASE/scripts/gwreg-retention" << 'SCRIPT'
#!/bin/bash
# /etc/cron.daily/gwreg-retention — Prune registry backups.
set -euo pipefail
BACKUP_DIR=/opt/backups/gwreg; MAX_SIZE_KB=2097152; LOG=/var/log/gwreg-backup.log
find "$BACKUP_DIR" -maxdepth 1 -name "registry-*.db" -mtime +30 -delete
while [[ "$(du -sk "$BACKUP_DIR" | cut -f1)" -gt "$MAX_SIZE_KB" ]]; do
  oldest="$(find "$BACKUP_DIR" -maxdepth 1 -name "registry-*.db" | sort | head -1)"
  [[ -z "$oldest" ]] && break
  rm -f "$oldest"; echo "[$(isotime)] pruned: $oldest" >> "$LOG"
done
echo "[$(isotime)] Retention cleanup complete" >> "$LOG"
SCRIPT

# --- gw-seed-verify ---
cat > "$BASE/scripts/gw-seed-verify" << 'SCRIPT'
#!/bin/bash
# /etc/cron.daily/gw-seed-verify — Daily seed integrity check.
set -euo pipefail
SEED=/home/gw-seed; LOG=/var/log/gw-seed-verify.log; FAIL=0
log() { echo "[$(isotime)] $*" | tee -a "$LOG"; }
log "Seed integrity check"
sha256_cmd -c "$SEED/packages/"*.sha256 >> "$LOG" 2>&1 && log "[OK] Checksums valid" || { log "[WARN] Checksum mismatch"; FAIL=1; }
sqlite3 "$SEED/registry/registry.db" "PRAGMA integrity_check;" >> "$LOG" 2>&1 \
  && log "[OK] Registry DB readable" || { log "[WARN] Registry DB unreadable"; FAIL=1; }
[[ "$FAIL" -eq 0 ]] && log "Seed verify OK" || log "Seed verify: $FAIL warning(s)"
SCRIPT

chmod +x "$BASE/scripts/"*

# ─────────────────────────────────────────────────────────────────
# CONFIGS
# ─────────────────────────────────────────────────────────────────

# GW node nftables — table-scoped, policy drop on all chains including output
cat > "$BASE/configs/nftables-gw.conf" << 'CONF'
#!/usr/sbin/nft -f
# GW Node baseline nftables (RC3)
# REQUIRED: substitute <mgmt-subnet> before applying
# Table-scoped: does NOT flush global ruleset. Add-on tables preserved.

table inet gw_filter {
  chain input {
    type filter hook input priority 0; policy drop;
    ct state established,related accept
    ct state invalid drop
    iif "lo" accept
    ip protocol icmp limit rate 10/second accept
    ip6 nexthdr icmpv6 limit rate 10/second accept
    ip saddr <mgmt-subnet> tcp dport 22 accept
    udp dport { 500, 4500 } accept
    ip protocol esp accept
    udp dport 4789 accept
    tcp dport 179 accept
    tcp dport 8443 accept
    log prefix "gw-drop-input: " drop
  }
  chain forward {
    type filter hook forward priority 0; policy drop;
    ct state established,related accept
    ct state invalid drop
    log prefix "gw-drop-fwd: " drop
  }
  chain output {
    type filter hook output priority 0; policy drop;
    ct state established,related accept
    ct state invalid drop
    oif "lo" accept
    udp dport { 53, 123 } accept
    tcp dport { 53, 80, 443 } accept
    ip daddr <mgmt-subnet> tcp dport 22 accept
    udp dport { 500, 4500 } accept
    ip protocol esp accept
    tcp dport 179 accept
    udp dport 4789 accept
    log prefix "gw-drop-output: " drop
  }
}
CONF

# Portal nftables — table-scoped, placeholders use <UPPER_CASE> convention
cat > "$BASE/configs/nftables-portal.conf" << 'CONF'
#!/usr/sbin/nft -f
# Admin Portal baseline nftables (RC3)
# REQUIRED: adminctl.sh apply-firewall substitutes all placeholders automatically.
# Table-scoped: does NOT flush global ruleset.

table inet gw_admin {
  set admin_src4 { type ipv4_addr; flags interval; }
  set gw_mgmt4   { type ipv4_addr; flags interval; }
  set nfs_cli4   { type ipv4_addr; flags interval; }

  chain input {
    type filter hook input priority 0; policy drop;
    iif "lo" accept
    ct state established,related accept
    ct state invalid drop
    ip protocol icmp limit rate 10/second accept
    ip6 nexthdr icmpv6 limit rate 10/second accept
    iifname <MGMT_ACCESS_IF> tcp dport { <PORTAL_HTTPS_PORT>, <SSH_PORT> } ip saddr @admin_src4 accept
    iifname <NFS_VLAN_IF> ip saddr @nfs_cli4 tcp dport { 111, 2049, <NFS_MOUNTD_PORT>, <NFS_STATD_PORT>, <NFS_LOCKD_TCPPORT>, <NFS_RQUOTAD_PORT> } accept
    iifname <NFS_VLAN_IF> ip saddr @nfs_cli4 udp dport { 111, 2049, <NFS_MOUNTD_PORT>, <NFS_STATD_PORT>, <NFS_LOCKD_UDPPORT>, <NFS_RQUOTAD_PORT> } accept
    log prefix "portal-drop-input: " drop
  }
  chain output {
    type filter hook output priority 0; policy drop;
    oif "lo" accept
    ct state established,related accept
    ct state invalid drop
    udp dport { 53, 123 } accept
    tcp dport { 53, 80, 443 } accept
    oifname <MGMT_VLAN_IF> tcp dport <SSH_PORT> ip daddr @gw_mgmt4 accept
    oifname <NFS_VLAN_IF> ip daddr @nfs_cli4 tcp sport { 111, 2049, <NFS_MOUNTD_PORT>, <NFS_STATD_PORT>, <NFS_LOCKD_TCPPORT>, <NFS_RQUOTAD_PORT> } accept
    oifname <NFS_VLAN_IF> ip daddr @nfs_cli4 udp sport { 111, 2049, <NFS_MOUNTD_PORT>, <NFS_STATD_PORT>, <NFS_LOCKD_UDPPORT>, <NFS_RQUOTAD_PORT> } accept
    log prefix "portal-drop-output: " drop
  }
}
CONF

cat > "$BASE/configs/chrony-portal.conf" << 'CONF'
# Admin Console — GPS-PPS Stratum 1 (RC3)
# REQUIRED: substitute <mgmt-subnet>
# Verify hardware first: ppstest /dev/pps0
refclock PPS /dev/pps0 refid PPS precision 1e-7 poll 4 trust prefer
refclock SHM 0 refid NMEA offset 0.5 delay 0.2 precision 1e-3
makestep 1.0 -1
rtcsync
driftfile /var/lib/chrony/drift
logdir /var/log/chrony
allow <mgmt-subnet>
local stratum 1
log tracking measurements statistics
CONF

cat > "$BASE/configs/chrony-gw.conf" << 'CONF'
# GW Nodes — Stratum 2 (RC3)
# REQUIRED: substitute <admin-console-mgmt-ip>
server <admin-console-mgmt-ip> iburst prefer minpoll 4 maxpoll 6
makestep 1.0 -1
rtcsync
driftfile /var/lib/chrony/drift
logdir /var/log/chrony
log tracking measurements
CONF

# ─────────────────────────────────────────────────────────────────
# COPY RC3 ADD-ON SCRIPTS INTO STAGING
# ─────────────────────────────────────────────────────────────────
# These scripts are shipped as standalone files (not generated inline above)
RC3_SCRIPTS="gwreg-promote-lock gwctl-promote gwperf-score gw-totp-setup.sh gw-sshproxyctl.sh gw-inspectctl.sh gw-pki-backup.sh connect gateway-exec"
RC3_CONFIGS="gwperf.conf.example"
for s in $RC3_SCRIPTS; do
  [[ -f "scripts/$s" ]] || die "Missing RC3 script: scripts/$s"
  cp "scripts/$s" "$BASE/scripts/$s"
  chmod +x "$BASE/scripts/$s"
done
log "RC3 add-on scripts copied to staging"
for c in $RC3_CONFIGS; do
  [[ -f "configs/$c" ]] || die "Missing RC3 config: configs/$c"
  cp "configs/$c" "$BASE/configs/$c"
done
log "RC3 add-on configs copied to staging"

# ─────────────────────────────────────────────────────────────────
# DOCUMENTS
# ─────────────────────────────────────────────────────────────────
# Docs are pre-built in docs/ directory — copy here
cp docs/RC3-Architecture.txt          "$BASE/docs/"
cp docs/RC3-Installation-Instructions.txt "$BASE/docs/"
cp docs/RC3-Feature-Reference.txt     "$BASE/docs/"
cp docs/RC3-Testing-Plan.txt          "$BASE/docs/"
cp docs/RC3-Runbook.txt               "$BASE/docs/"

# ─────────────────────────────────────────────────────────────────
# SEED PLACEHOLDERS
# ─────────────────────────────────────────────────────────────────
for d in registry portal pki manifests packages; do
  echo "# Populate after portal init — see RC3-Installation-Instructions.txt Step 3" \
    > "$BASE/seed/$d/.keep"
done

cat > "$BASE/seed/README.txt" << EOF
GW PLATFORM RC3 — SEED STRUCTURE
==================================
Date: $TODAY
Deploy to /opt/gw-seed on Admin Console.
Rsynced every 5 minutes to /home/gw-seed on each GW node.

POPULATE AFTER PORTAL INIT (see Step 3 of RC3-Installation-Instructions.txt):
  sqlite3 /opt/gw-registry/data/registry.db ".backup '/opt/gw-seed/registry/registry.db'"
  cp -r /opt/gw-admin-portal/* /opt/gw-seed/portal/
  cp /etc/gateway/pki/ca.crt   /opt/gw-seed/pki/
  cp /etc/gateway/pki/*.crt    /opt/gw-seed/pki/   # node certs only
  cp *.zip *.sha256             /opt/gw-seed/packages/

SECURITY: Private keys (.key files) are NEVER included in the seed.
          gw-seed-sync excludes pki/*.key via rsync --exclude rule.
NFS export uses no_root_squash to allow root cron read access on GW nodes.
The export is read-only. No write path exists from GW nodes to the seed.
EOF

# ─────────────────────────────────────────────────────────────────
# GENERATE SHA256 FOR SOURCE PACKAGES
# ─────────────────────────────────────────────────────────────────
echo ""
echo "Generating package checksums..."
cp source-packages/*.zip "$BASE/seed/packages/"
pushd source-packages >/dev/null
sha256_cmd ./*.zip > "$BASE/seed/packages/RC3-packages.sha256"
popd >/dev/null
log "Checksums written to seed/packages/RC3-packages.sha256"

# ─────────────────────────────────────────────────────────────────
# BUILD OUTPUT PACKAGES
# ─────────────────────────────────────────────────────────────────

DOCS="docs/RC3-Architecture.txt
docs/RC3-Installation-Instructions.txt
docs/RC3-Feature-Reference.txt
docs/RC3-Testing-Plan.txt
docs/RC3-Runbook.txt"

PORTAL_SCRIPTS="scripts/gwreg-safe scripts/gwreg-rollback scripts/gw-manifest-push scripts/gwreg-retention scripts/gwreg-promote-lock scripts/gwctl-promote scripts/gwperf-score scripts/gw-totp-setup.sh scripts/gw-selinux-setup.sh scripts/gw-pki-backup.sh"
PORTAL_CONFIGS="configs/nftables-portal.conf configs/chrony-portal.conf configs/gwperf.conf.example"

GW_SCRIPTS="scripts/gw-forward-policy scripts/gw-seed-sync scripts/gw-portal-redeploy scripts/gw-manifest-push scripts/gw-seed-verify scripts/gwctl-promote scripts/gwreg-promote-lock scripts/gw-sshproxyctl.sh scripts/gw-inspectctl.sh scripts/gw-selinux-setup.sh"
GW_CONFIGS="configs/nftables-gw.conf configs/chrony-gw.conf"

cd "$BASE"

echo ""
echo "Packaging..."

# Package 1 — Admin Portal
zip_clean "$OUT/GW-Platform-RC3-AdminPortal-${TODAY}.zip" \
  "$BASE/docs/README-AdminPortal.txt" \
  $DOCS $PORTAL_SCRIPTS $PORTAL_CONFIGS
log "✅ GW-Platform-RC3-AdminPortal-${TODAY}.zip"

# Package 2 — GW Node
zip_clean "$OUT/GW-Platform-RC3-GWNode-${TODAY}.zip" \
  "$BASE/docs/README-GWNode.txt" \
  $DOCS $GW_SCRIPTS $GW_CONFIGS
log "✅ GW-Platform-RC3-GWNode-${TODAY}.zip"

# Package 3 — Seed (structure + source packages)
zip_clean "$OUT/GW-Platform-RC3-Seed-${TODAY}.zip" \
  "$BASE/docs/README-Seed.txt" \
  $DOCS \
  seed/README.txt \
  seed/registry/.keep seed/portal/.keep seed/pki/.keep \
  seed/manifests/.keep seed/packages/.keep \
  seed/packages/RC3-packages.sha256
log "✅ GW-Platform-RC3-Seed-${TODAY}.zip"

# Package 4 — Documentation only
zip_clean "$OUT/GW-Platform-RC3-Documentation-${TODAY}.zip" $DOCS \
  "$BASE/docs/README-AdminPortal.txt" "$BASE/docs/README-GWNode.txt" \
  "$BASE/docs/README-Seed.txt" "$BASE/docs/README-Complete.txt" \
  "$BASE/docs/README-Documentation.txt"
log "✅ GW-Platform-RC3-Documentation-${TODAY}.zip"

# Package 5 — Complete (everything)
zip_clean "$OUT/GW-Platform-RC3-Complete-${TODAY}.zip" \
  "$BASE/docs/README-Complete.txt" \
  $DOCS \
  scripts/* configs/* \
  seed/README.txt \
  seed/registry/.keep seed/portal/.keep seed/pki/.keep \
  seed/manifests/.keep seed/packages/.keep \
  seed/packages/RC3-packages.sha256
log "✅ GW-Platform-RC3-Complete-${TODAY}.zip"

cd - > /dev/null

# Generate SHA256 for all output packages
echo ""
echo "Generating output package checksums..."
pushd "$OUT" >/dev/null
sha256_cmd ./*.zip > "RC3-release-${TODAY}.sha256"
popd >/dev/null
log "✅ RC3-release-${TODAY}.sha256"

echo ""
echo "════════════════════════════════════════════════════"
echo "  ALL 5 RC3 PACKAGES BUILT → ./RC3-Packages/"
echo "════════════════════════════════════════════════════"
ls -lh "$OUT/"
