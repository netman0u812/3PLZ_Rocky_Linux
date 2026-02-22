#!/usr/bin/env bash
set -euo pipefail
die(){ echo "ERROR: $*" >&2; exit 1; }
[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"

prefix="/opt/gw-perfmon"
src="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$prefix"
cp -a "$src"/{bin,conf,docs,systemd,lib} "$prefix"/

mkdir -p /etc/gateway/perfmon
if [[ ! -f /etc/gateway/perfmon/gwperf.conf ]]; then
  cp "$prefix/conf/gwperf.conf.example" /etc/gateway/perfmon/gwperf.conf
fi

install -d /usr/local/bin
ln -sfn "$prefix/bin/gwperf-poll" /usr/local/bin/gwperf-poll
ln -sfn "$prefix/bin/gwperf-report" /usr/local/bin/gwperf-report

cp "$prefix/systemd/"gwperfmon.* /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now gwperfmon.timer

echo "Installed gw-perfmon to $prefix"
echo "Config: /etc/gateway/perfmon/gwperf.conf"
echo "Run: gwperf-report"
