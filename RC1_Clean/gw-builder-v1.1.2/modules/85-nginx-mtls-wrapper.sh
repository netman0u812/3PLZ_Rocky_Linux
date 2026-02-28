#!/usr/bin/env bash
set -euo pipefail

# v0.5.0 - Tenant mTLS enforcement plane using NGINX
# Responsibilities:
# - install/configure nginx (if requested by control plane)
# - generate per-tenant nginx config that:
#   * listens on portal VIP (.2) and app VIPs (upper /25)
#   * terminates TLS with per-app server cert
#   * requires client mTLS using tenant intermediate CA
#   * enforces optional CRL (ssl_crl) if enabled
# - runs nginx in tenant VRF using ip vrf exec (systemd template)

# Expects helper functions from gwctl.sh:
# - die, info, warn
# - tenant_conf_load <tenant>
# Variables from tenant conf (examples):
# - TENANT_NAME, VRF_NAME
# - TENANT_NET_CIDR
# - PORTAL_VIP (172.16.X.2/32)
# - DNS_VIP, SQUID_VIP
# - NGINX_MTLS_MODE (on/off)
# - CRL_ENFORCE (on/off)
# - TENANT_CA_PEM path

NGINX_ETC="/etc/nginx"
TENANTS_DIR="${NGINX_ETC}/tenants"
TENANT_LOG_DIR_BASE="/var/log/gw-builder"

ensure_nginx_base() {
  mkdir -p "${TENANTS_DIR}" "${TENANT_LOG_DIR_BASE}"
  mkdir -p /etc/systemd/system

  # systemd template to run nginx inside VRF
  cat >/etc/systemd/system/nginx-tenant@.service <<'EOF'
[Unit]
Description=NGINX tenant instance for %i (runs in tenant VRF)
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/run/nginx-%i.pid
ExecStartPre=/usr/bin/mkdir -p /run
ExecStartPre=/usr/bin/rm -f /run/nginx-%i.pid
# run nginx within VRF, with tenant-specific config
ExecStart=/usr/sbin/ip vrf exec vrf-%i /usr/sbin/nginx -c /etc/nginx/tenants/%i/nginx.conf -g 'pid /run/nginx-%i.pid;'
ExecReload=/bin/kill -HUP $MAINPID
ExecStop=/bin/kill -QUIT $MAINPID
Restart=on-failure
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF
}

write_nginx_tenant_conf() {
  local tenant="$1"
  tenant_conf_load "${tenant}"

  local tdir="${TENANTS_DIR}/${tenant}"
  local ldir="${TENANT_LOG_DIR_BASE}/${tenant}"
  mkdir -p "${tdir}/conf.d" "${tdir}/apps.d" "${ldir}"

  # JSON log format with mTLS identity fields
  cat >"${tdir}/conf.d/logging.conf" <<'EOF'
log_format json_combined escape=json
  '{'
    '"ts":"$time_iso8601",'
    '"remote_addr":"$remote_addr",'
    '"x_forwarded_for":"$http_x_forwarded_for",'
    '"host":"$host",'
    '"server_name":"$server_name",'
    '"request":"$request",'
    '"uri":"$uri",'
    '"status":$status,'
    '"bytes_sent":$bytes_sent,'
    '"request_time":$request_time,'
    '"upstream_addr":"$upstream_addr",'
    '"upstream_status":"$upstream_status",'
    '"upstream_response_time":"$upstream_response_time",'
    '"ssl_protocol":"$ssl_protocol",'
    '"ssl_cipher":"$ssl_cipher",'
    '"mtls_verify":"$ssl_client_verify",'
    '"mtls_dn":"$ssl_client_s_dn",'
    '"mtls_fingerprint":"$ssl_client_fingerprint"'
  '}';

access_log  /var/log/nginx/tenants/$tenant/access.json  json_combined;
error_log   /var/log/nginx/tenants/$tenant/error.log   warn;
EOF

  # Base nginx.conf for the tenant instance
  cat >"${tdir}/nginx.conf" <<EOF
worker_processes auto;
events { worker_connections 1024; }

http {
  include       ${NGINX_ETC}/mime.types;
  default_type  application/octet-stream;

  sendfile on;
  tcp_nopush on;
  keepalive_timeout 65;

  # Logging
  include ${tdir}/conf.d/logging.conf;

  # Hardening
  server_tokens off;
  ssl_session_cache shared:SSL:10m;
  ssl_session_timeout 10m;
  ssl_protocols TLSv1.2 TLSv1.3;

  # mTLS trust
  ssl_verify_depth 3;
  ssl_client_certificate ${TENANT_CA_PEM};
EOF

  if [[ "${CRL_ENFORCE:-off}" == "on" ]]; then
    echo "  ssl_crl /etc/gateway/pki/${tenant}/intermediate/crl/${tenant}-intermediate.crl.pem;" >>"${tdir}/nginx.conf"
  fi

  cat >>"${tdir}/nginx.conf" <<'EOF'

  # Authz (optional)
  include /etc/nginx/tenants/'"$tenant"'/conf.d/authz.conf;

  # Include generated app servers (VIP listeners)
  include /etc/nginx/tenants/'"$tenant"'/apps.d/*.conf;

  # Portal listener (optional; reverse-proxies to portal app)
  include /etc/nginx/tenants/'"$tenant"'/conf.d/portal.conf;
}
EOF

  # Portal listener definition (default: proxy to localhost:9443 within VRF)
  cat >"${tdir}/conf.d/portal.conf" <<EOF
server {
  listen ${PORTAL_VIP%/*}:443 ssl;
  server_name portal.${tenant}.local;

  # Tenant-issued portal/server certificate (can be shared or per-tenant)
  ssl_certificate     /etc/gateway/tls/${tenant}/portal/cert.pem;
  ssl_certificate_key /etc/gateway/tls/${tenant}/portal/key.pem;

  # Require client cert
  ssl_verify_client on;

  location /healthz { return 200 "ok\n"; }

  # Portal app runs on 127.0.0.1:9443 in tenant VRF
  location / {
    proxy_set_header X-Tenant ${tenant};
    proxy_set_header X-mTLS-Verify $ssl_client_verify;
    proxy_set_header X-mTLS-DN $ssl_client_s_dn;
    proxy_set_header X-mTLS-Fingerprint $ssl_client_fingerprint;
    proxy_pass http://127.0.0.1:9443;
  }
}
EOF

  info "Wrote tenant nginx config: ${tdir}/nginx.conf"
}

write_nginx_app_server() {
  local tenant="$1" fqdn="$2" vip="$3" upstream="$4" inspect="${5:-on}"
  tenant_conf_load "${tenant}"
  local tdir="${TENANTS_DIR}/${tenant}"

  local conf="${tdir}/apps.d/${fqdn}.conf"

  # For Phase 1, NGINX terminates TLS for inspection and logs L7.
  # If inspect=off, we still terminate TLS for mTLS and forward to upstream over TLS (no payload inspection on gateway),
  # but you can disable request_body logging separately if desired.
  cat >"${conf}" <<EOF
# app: ${fqdn}
server {
  listen ${vip}:443 ssl;
  server_name ${fqdn};

  ssl_certificate     /etc/gateway/tls/${tenant}/apps/${fqdn}/cert.pem;
  ssl_certificate_key /etc/gateway/tls/${tenant}/apps/${fqdn}/key.pem;

  # Require client cert
  ssl_verify_client on;

  # Basic request limits (tunable)
  client_max_body_size 50m;

  location / {
    # Authorization check (403 if denied)
    include /etc/nginx/tenants/${tenant}/conf.d/authz_enforce.inc;

    proxy_set_header Host ${fqdn};
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-For $remote_addr;

    # Identity propagation
    proxy_set_header X-mTLS-Verify $ssl_client_verify;
    proxy_set_header X-mTLS-DN $ssl_client_s_dn;
    proxy_set_header X-mTLS-Fingerprint $ssl_client_fingerprint;

    # Upstream
    proxy_ssl_server_name on;
    proxy_pass https://${upstream};
  }
}
EOF

  info "Wrote app server: ${conf}"
}

nginx_tenant_enable() {
  local tenant="$1"
  ensure_nginx_base
  systemctl daemon-reload
  systemctl enable --now "nginx-tenant@${tenant}"
}

nginx_tenant_reload() {
  local tenant="$1"
  systemctl reload "nginx-tenant@${tenant}" || systemctl restart "nginx-tenant@${tenant}"
}
