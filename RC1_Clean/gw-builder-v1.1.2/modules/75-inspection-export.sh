#!/usr/bin/env bash
set -euo pipefail

# v0.5.0 - Inspection export (Phase 1): L7 log export / streaming
# For Phase 1 we export:
# - NGINX per-tenant JSON access logs
# - Envoy per-app access logs (if still used)
# - Squid access logs
#
# Transport:
# - rsyslog forwarding to a remote collector (TCP or UDP), optional TLS later
#
# Config is driven by gw.conf:
#   INSPECT_LOG_EXPORT=on/off
#   INSPECT_SYSLOG_HOST=1.2.3.4
#   INSPECT_SYSLOG_PORT=514
#   INSPECT_SYSLOG_PROTO=udp|tcp

RSYSLOG_OUT="/etc/rsyslog.d/90-gw-inspect-export.conf"

inspect_export_enable() {
  local host="${INSPECT_SYSLOG_HOST:-}"
  local port="${INSPECT_SYSLOG_PORT:-514}"
  local proto="${INSPECT_SYSLOG_PROTO:-udp}"

  if [[ -z "${host}" ]]; then
    warn "INSPECT_SYSLOG_HOST not set; leaving local logging only."
    return 0
  fi

  cat >"${RSYSLOG_OUT}" <<EOF
# gw-builder inspection export (v0.5.0)
# Forward selected logs to ${proto}://${host}:${port}

# NGINX tenant logs
\$InputFileName /var/log/nginx/tenants/*/access.json
\$InputFileTag gw-nginx:
\$InputFileStateFile stat-gw-nginx
\$InputFileSeverity info
\$InputFileFacility local6
\$InputRunFileMonitor

# Squid logs (all instances)
\$InputFileName /var/log/squid/*.log
\$InputFileTag gw-squid:
\$InputFileStateFile stat-gw-squid
\$InputFileSeverity info
\$InputFileFacility local6
\$InputRunFileMonitor

# Envoy logs (optional)
\$InputFileName /var/log/envoy/*.log
\$InputFileTag gw-envoy:
\$InputFileStateFile stat-gw-envoy
\$InputFileSeverity info
\$InputFileFacility local6
\$InputRunFileMonitor

# Forward
local6.*  @${host}:${port}
EOF

  systemctl enable --now rsyslog
  systemctl restart rsyslog
  info "Enabled inspection log export to ${host}:${port} (${proto})"
}

inspect_export_disable() {
  rm -f "${RSYSLOG_OUT}"
  systemctl restart rsyslog || true
  info "Disabled inspection log export"
}
