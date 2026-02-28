#!/usr/bin/env bash
set -euo pipefail

# v1.0.0 - CRL refresh + NGINX reload automation

ensure_crl_timer_units() {
  cat >/etc/systemd/system/gw-crl-refresh@.service <<'EOF'
[Unit]
Description=Regenerate tenant CRL and reload nginx for %i

[Service]
Type=oneshot
ExecStart=/opt/gw-builder/gwctl.sh crl-refresh %i
EOF

  cat >/etc/systemd/system/gw-crl-refresh@.timer <<'EOF'
[Unit]
Description=Daily CRL refresh for %i

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

crl_timer_enable() {
  local tenant="$1"
  ensure_crl_timer_units
  systemctl daemon-reload
  systemctl enable --now "gw-crl-refresh@${tenant}.timer"
}

crl_timer_disable() {
  local tenant="$1"
  systemctl disable --now "gw-crl-refresh@${tenant}.timer" || true
}
