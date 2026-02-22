#!/usr/bin/env bash
set -euo pipefail
CONF="${CONF:-/etc/gateway/perfmon/gwperf.conf}"
die(){ echo "ERROR: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }
load_conf(){
  [[ -f "$CONF" ]] || die "Missing $CONF (copy gwperf.conf.example to $CONF)"
  # shellcheck disable=SC1090
  source "$CONF"
  : "${REGISTRY_DB:?}"
}
sql(){ sqlite3 -bail "$REGISTRY_DB" "$1"; }
ensure_tables(){
  sql "CREATE TABLE IF NOT EXISTS node_metrics(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ts TEXT NOT NULL,
        node_name TEXT NOT NULL,
        if_util_pct REAL NOT NULL,
        cpu_util_pct REAL NOT NULL,
        tenant_density_pct REAL NOT NULL,
        composite_load_pct REAL NOT NULL,
        oversub_percent INTEGER NOT NULL,
        projected_pct REAL NOT NULL,
        cap_pct REAL NOT NULL,
        eligibility TEXT NOT NULL,
        reasons TEXT
      );"
  sql "CREATE INDEX IF NOT EXISTS idx_node_metrics_node_ts ON node_metrics(node_name, ts);"
}
