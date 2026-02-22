\
#!/usr/bin/env bash
set -euo pipefail

CONF="${CONF:-/etc/gateway/registry/gwreg.conf}"
ACTOR="${ACTOR:-Michael Martin}"
DEFAULT_REG_ROOT="/etc/gateway/registry"

die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ echo "[gwreg] $*"; }

need(){ command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

load_conf(){
  [[ -f "$CONF" ]] || die "Missing config $CONF (copy conf/gwreg.conf.example to $CONF)"
  # shellcheck disable=SC1090
  source "$CONF"
  : "${REGISTRY_ROOT:=${DEFAULT_REG_ROOT}}"
  : "${DB_PATH:=${REGISTRY_ROOT}/registry.db}"
}

sql(){
  local q="$1"
  sqlite3 -bail "$DB_PATH" "$q"
}

sql_json(){
  local q="$1"
  sqlite3 -json "$DB_PATH" "$q"
}

ensure_dirs(){
  mkdir -p "${REGISTRY_ROOT}/tenants" "${REGISTRY_ROOT}/nodes"
  chmod 0750 "${REGISTRY_ROOT}" || true
}

ensure_db(){
  need sqlite3
  ensure_dirs
  if [[ ! -f "$DB_PATH" ]]; then
    log "Initializing registry DB at $DB_PATH"
    sqlite3 "$DB_PATH" < /opt/gw-registry/schemas/schema.sql
    sql "INSERT OR REPLACE INTO meta(k,v) VALUES ('schema_version','0.1.0');"
  fi
}

audit(){
  local action="$1" otype="$2" oid="$3" details="${4:-}"
  local ts; ts="$(date -Is)"
  local esc_details; esc_details="$(printf "%s" "$details" | sed "s/'/''/g")"
  sql "INSERT INTO audit_log(ts,actor,action,object_type,object_id,details) VALUES ('$ts','${ACTOR//\'/\'\'}','$action','$otype','$oid','$esc_details');"
}

alloc_cidr_block(){
  local tenant="$1" kind="$2" supernet="$3" prefix="$4"
  local used_json
  used_json="$(sql_json "SELECT value FROM allocations WHERE kind='${kind}';")"
  python3 - <<'PY' "$supernet" "$prefix" "$used_json"
import sys, json, ipaddress
supernet = ipaddress.ip_network(sys.argv[1])
prefix = int(sys.argv[2])
used = set()
try:
    arr = json.loads(sys.argv[3])
    for o in arr:
        used.add(o["value"])
except Exception:
    pass
for sub in supernet.subnets(new_prefix=prefix):
    s=str(sub)
    if s not in used:
        print(s)
        break
PY
}

alloc_int_range(){
  local kind="$1" mn="$2" mx="$3"
  local used
  used="$(sql "SELECT value FROM allocations WHERE kind='${kind}' ORDER BY CAST(value AS INT);")" || true
  python3 - <<'PY' "$mn" "$mx" "$used"
import sys
mn=int(sys.argv[1]); mx=int(sys.argv[2])
used=set()
for line in sys.argv[3].splitlines():
    line=line.strip()
    if line:
        used.add(int(line))
for v in range(mn, mx+1):
    if v not in used:
        print(v)
        break
PY
}

svc_ip_from_block(){
  local cidr="$1" offset="$2"
  python3 - <<'PY' "$cidr" "$offset"
import sys, ipaddress
net=ipaddress.ip_network(sys.argv[1], strict=False)
off=int(sys.argv[2])
hosts=list(net.hosts())
print(str(hosts[off-1]))
PY
}
