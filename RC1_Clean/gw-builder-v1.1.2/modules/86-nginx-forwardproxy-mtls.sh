#!/usr/bin/env bash
set -euo pipefail

# v1.0.0 - NGINX mTLS wrapper for Squid forward proxy
# Provides an mTLS-secured TCP entrypoint that forwards to Squid's 3128.
# This keeps Squid unmodified while enforcing user identity at the edge.

NGINX_ETC="/etc/nginx"
TENANTS_DIR="${NGINX_ETC}/tenants"

ensure_nginx_stream_service() {
  cat >/etc/systemd/system/nginx-forwardproxy@.service <<'EOF'
[Unit]
Description=NGINX forward-proxy mTLS wrapper for %i (runs in tenant VRF)
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/run/nginx-fwd-%i.pid
ExecStartPre=/usr/bin/mkdir -p /run
ExecStartPre=/usr/bin/rm -f /run/nginx-fwd-%i.pid
ExecStart=/usr/sbin/ip vrf exec vrf-%i /usr/sbin/nginx -c /etc/nginx/tenants/%i/stream.conf -g 'pid /run/nginx-fwd-%i.pid;'
ExecReload=/bin/kill -HUP $MAINPID
ExecStop=/bin/kill -QUIT $MAINPID
Restart=on-failure
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF
}

write_nginx_forwardproxy_stream() {
  local tenant="$1" listen_ip="$2" listen_port="${3:-8443}" squid_ip="$4" squid_port="${5:-3128}"
  tenant_conf_load "${tenant}"
  local tdir="${TENANTS_DIR}/${tenant}"
  mkdir -p "${tdir}"

  mkdir -p "/var/log/nginx/tenants/${tenant}"

  cat >"${tdir}/stream.conf" <<EOF
worker_processes auto;
events { worker_connections 1024; }

stream {
  log_format stream_json escape=json
    '{'
      '"ts":"$time_iso8601",'
      '"remote_addr":"$remote_addr",'
      '"bytes_sent":$bytes_sent,'
      '"bytes_received":$bytes_received,'
      '"session_time":$session_time,'
      '"ssl_protocol":"$ssl_protocol",'
      '"ssl_cipher":"$ssl_cipher",'
      '"mtls_verify":"$ssl_client_verify",'
      '"mtls_dn":"$ssl_client_s_dn",'
      '"mtls_fingerprint":"$ssl_client_fingerprint"'
    '}';

  access_log /var/log/nginx/tenants/${tenant}/forwardproxy-stream.json stream_json;

  server {
    listen ${listen_ip}:${listen_port} ssl;

    ssl_certificate     /etc/gateway/tls/${tenant}/forwardproxy/cert.pem;
    ssl_certificate_key /etc/gateway/tls/${tenant}/forwardproxy/key.pem;

    ssl_verify_client on;
    ssl_verify_depth 3;
    ssl_client_certificate ${TENANT_CA_PEM};
EOF

  if [[ "${CRL_ENFORCE:-off}" == "on" ]]; then
    echo "    ssl_crl /etc/gateway/pki/${tenant}/intermediate/crl/${tenant}-intermediate.crl.pem;" >>"${tdir}/stream.conf"
  fi

  cat >>"${tdir}/stream.conf" <<EOF

    proxy_connect_timeout 10s;
    proxy_timeout 3600s;
    proxy_pass ${squid_ip}:${squid_port};
  }
}
EOF

  echo "Wrote ${tdir}/stream.conf (mTLS forward proxy wrapper)"
}

nginx_forwardproxy_enable() {
  local tenant="$1"
  ensure_nginx_stream_service
  systemctl daemon-reload
  systemctl enable --now "nginx-forwardproxy@${tenant}"
}

nginx_forwardproxy_reload() {
  local tenant="$1"
  systemctl reload "nginx-forwardproxy@${tenant}" || systemctl restart "nginx-forwardproxy@${tenant}"
}

nginx_forwardproxy_disable() {
  local tenant="$1"
  systemctl disable --now "nginx-forwardproxy@${tenant}" || true
}
