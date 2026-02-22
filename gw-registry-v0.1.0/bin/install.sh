\
#!/usr/bin/env bash
set -euo pipefail
die(){ echo "ERROR: $*" >&2; exit 1; }
[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"

prefix="/opt/gw-registry"
mkdir -p "$prefix"
src="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cp -a "$src"/{bin,lib,conf,docs,schemas,templates,systemd} "$prefix"/

install -d /usr/local/bin
ln -sfn "$prefix/bin/gwreg" /usr/local/bin/gwreg

mkdir -p /etc/gateway/registry
if [[ ! -f /etc/gateway/registry/gwreg.conf ]]; then
  cp "$prefix/conf/gwreg.conf.example" /etc/gateway/registry/gwreg.conf
fi

echo "Installed gw-registry to $prefix"
echo "Edit /etc/gateway/registry/gwreg.conf then run: gwreg init"
