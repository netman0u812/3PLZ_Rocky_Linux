#!/usr/bin/env bash
set -euo pipefail
source /opt/gw-builder/gw.conf
source /opt/gw-builder/modules/00-common.sh

action="${1:-install}"

install_logrotate() {
  mkdir -p /etc/logrotate.d
  cat >/etc/logrotate.d/gw-builder <<'EOF'
/var/log/gw-builder/*/*/*.log /var/log/gw-builder/*/*/*.out /var/log/gw-builder/*/*/*.err {
  daily
  rotate 14
  missingok
  notifempty
  compress
  delaycompress
  copytruncate
  sharedscripts
  postrotate
    # Best-effort: reload nginx tenant services if present
    systemctl daemon-reload >/dev/null 2>&1 || true
  endscript
}
EOF
}

case "$action" in
  install) install_logrotate ;;
  *) echo "Usage: $0 install" ; exit 1 ;;
esac
