PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS meta (
  k TEXT PRIMARY KEY,
  v TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS nodes (
  node_name TEXT PRIMARY KEY,
  mgmt_ip TEXT NOT NULL,
  vtep_ip TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'gw',
  state TEXT NOT NULL DEFAULT 'active',
  capacity_weight INTEGER NOT NULL DEFAULT 100,
  last_checkin TEXT,
  notes TEXT
);

CREATE TABLE IF NOT EXISTS tenants (
  tenant_name TEXT PRIMARY KEY,
  tenant_id TEXT NOT NULL,
  created_at TEXT NOT NULL,
  created_by TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'active',
  placement_mode TEXT NOT NULL DEFAULT 'balanced',
  primary_node TEXT,
  backup_node TEXT,
  FOREIGN KEY(primary_node) REFERENCES nodes(node_name),
  FOREIGN KEY(backup_node) REFERENCES nodes(node_name)
);

CREATE TABLE IF NOT EXISTS allocations (
  tenant_name TEXT NOT NULL,
  kind TEXT NOT NULL,
  value TEXT NOT NULL,
  created_at TEXT NOT NULL,
  created_by TEXT NOT NULL,
  UNIQUE(kind, value),
  FOREIGN KEY(tenant_name) REFERENCES tenants(tenant_name)
);

CREATE TABLE IF NOT EXISTS audit_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts TEXT NOT NULL,
  actor TEXT NOT NULL,
  action TEXT NOT NULL,
  object_type TEXT NOT NULL,
  object_id TEXT NOT NULL,
  details TEXT
);
