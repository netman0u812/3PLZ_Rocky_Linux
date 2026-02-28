#!/usr/bin/env bash
set -euo pipefail
source /opt/gw-builder/gw.conf
source /opt/gw-builder/modules/00-common.sh

tconf="$1"; shift || true
cmd="${1:-}"
shift || true
# shellcheck source=/dev/null
source "$tconf"

apps_dir="$(catalog_revproxy_dir "${TENANT}")"
apps_file="${apps_dir}/apps.list"


ensure_unit() {
  cat >/etc/systemd/system/envoy-tenant@.service <<'EOF'
[Unit]
Description=Envoy Tenant %i (vrf-%i)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/sbin/ip vrf exec vrf-%i /usr/bin/envoy -c /etc/envoy/tenants/%i/envoy.yaml --log-level info
Restart=on-failure
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}


migrate_apps_if_needed() {
  # Back-compat: import legacy ${APPS_DIR}/${TENANT}.apps into catalog once
  local legacy="${APPS_DIR}/${TENANT}.apps"
  if [[ -f "$legacy" && ! -s "$apps_file" ]]; then
    cp -f "$legacy" "$apps_file" || true
  fi
}

ensure_envoy_base() {
  ensure_unit
  ensure_tenant_catalog "${TENANT}"
  mkdir -p "${ENVOY_TENANT_DIR}/${TENANT}"
  mkdir -p "${apps_dir}"
  migrate_apps_if_needed
  [[ -f "$apps_file" ]] || touch "$apps_file"
  ensure_tenant_logdirs "${TENANT}"
  mkdir -p /var/log/gw-builder/${TENANT}/envoy
}


render_apps_manifest() {
  # Source of truth: ${apps_dir}/*.app
  : > "${apps_file}"
  if compgen -G "${apps_dir}/*.app" >/dev/null; then
    cat "${apps_dir}/"*.app >> "${apps_file}"
  fi
}

render_envoy() {
  local cfg="${ENVOY_TENANT_DIR}/${TENANT}/envoy.yaml"

  cat >"$cfg" <<EOF
static_resources:
  listeners:
EOF

  while read -r fqdn vip upstream inspect; do
    [[ -n "$fqdn" ]] || continue
    local upstream_host="${upstream%:*}"
    local upstream_port="${upstream##*:}"

    local cert_dir="${TLS_DIR}/${TENANT}/apps/${fqdn}"
    local cert="${cert_dir}/cert.pem"
    local key="${cert_dir}/key.pem"

    cat >>"$cfg" <<EOF
  - name: listener_${fqdn}
    address:
      socket_address: { address: ${vip}, port_value: 443 }
    filter_chains:
    - filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          stat_prefix: ingress_${fqdn}
          access_log:
          - name: envoy.access_loggers.file
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.access_loggers.file.v3.FileAccessLog
              path: /var/log/envoy/${TENANT}-${fqdn}.access.log
          route_config:
            name: local_route_${fqdn}
            virtual_hosts:
            - name: vhost_${fqdn}
              domains: ["*"]
              routes:
              - match: { prefix: "/" }
                route: { cluster: cluster_${fqdn} }
          http_filters:
          - name: envoy.filters.http.router
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
EOF

    if [[ "$inspect" == "on" ]]; then
      cat >>"$cfg" <<EOF
      transport_socket:
        name: envoy.transport_sockets.tls
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.DownstreamTlsContext
          common_tls_context:
            tls_certificates:
            - certificate_chain: { filename: "${cert}" }
              private_key: { filename: "${key}" }
EOF
    fi
  done <"$apps_file"

  cat >>"$cfg" <<EOF
  clusters:
EOF

  while read -r fqdn vip upstream inspect; do
    [[ -n "$fqdn" ]] || continue
    local upstream_host="${upstream%:*}"
    local upstream_port="${upstream##*:}"

    cat >>"$cfg" <<EOF
  - name: cluster_${fqdn}
    connect_timeout: 3s
    type: STRICT_DNS
    lb_policy: ROUND_ROBIN
    load_assignment:
      cluster_name: cluster_${fqdn}
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address: { address: ${upstream_host}, port_value: ${upstream_port} }
EOF
  done <"$apps_file"

  cat >>"$cfg" <<'EOF'
admin:
  access_log_path: /var/log/envoy/admin.log
  address:
    socket_address: { address: 127.0.0.1, port_value: 9901 }
EOF
}

add_app() {
  local fqdn="$1" upstream="$2" inspect="${3:-inherit}" auto_cert="${4:-no}"
  [[ -n "$fqdn" && -n "$upstream" ]] || die "Usage: add-app <fqdn> <upstream_ip:port> [inspect=on|off|inherit] [auto_cert=yes|no]"

  local lower25 upper25
  read -r lower25 upper25 <<<"$(split_24_to_25s "$TENANT_NET")"

  local effective_inspect="$inspect"
  if [[ "$inspect" == "inherit" ]]; then effective_inspect="$REVPROXY_INSPECT"; fi

  local vip
  vip="$(alloc_app_vip "$TENANT" "$upper25")"
  ip addr add "${vip}/32" dev lo 2>/dev/null || true

  mkdir -p "${apps_dir}"
  echo "${fqdn} ${vip} ${upstream} ${effective_inspect}" > "${apps_dir}/${fqdn}.app"
  render_apps_manifest

  # DNS override
  local overrides="$(catalog_dns_rewrites "${TENANT}")"
  echo "local-data: \"${fqdn}. A ${vip}\"" >>"$overrides"
  systemctl reload "unbound-tenant@${TENANT}" 2>/dev/null || systemctl restart "unbound-tenant@${TENANT}" || true

  # Ensure firewall fragments exist (creates tenant set), then add VIP to allowlist set if enforced
  /opt/gw-builder/modules/15-firewall-nft.sh "$tconf" apply || true
  if [[ "${FW_MODE}" == "enforced" ]]; then
    nft add element inet gw "catalog_vips_${TENANT}" { ${vip} } 2>/dev/null || true
  fi

  # Cert handling for inspect=on
  if [[ "$effective_inspect" == "on" && "$auto_cert" == "yes" ]]; then
    /opt/gw-builder/modules/70-pki.sh "$tconf" --issue-app-cert "$fqdn" || true
  fi
  if [[ "$effective_inspect" == "on" ]]; then
    local cert_dir="${TLS_DIR}/${TENANT}/apps/${fqdn}"
    [[ -f "${cert_dir}/cert.pem" && -f "${cert_dir}/key.pem" ]] || die "inspect=on requires cert/key at ${cert_dir}/{cert.pem,key.pem}"
  fi

  ensure_envoy_base
  render_envoy
  systemctl enable --now "envoy-tenant@${TENANT}" || true
  systemctl restart "envoy-tenant@${TENANT}" || true

  echo "App added for $TENANT:"
  echo "  FQDN:     $fqdn"
  echo "  VIP:      $vip"
  echo "  Upstream: $upstream"
  echo "  Inspect:  $effective_inspect"
}

list_apps() {
  ensure_envoy_base
  render_apps_manifest
  [[ -s "$apps_file" ]] || { echo "(no apps)"; exit 0; }
  cat "$apps_file"
}

del_app() {
  local fqdn="$1"
  [[ -n "$fqdn" ]] || die "Usage: del-app <fqdn>"
  [[ -f "$apps_file" ]] || die "No apps for tenant"

  local vip=""
  vip="$(awk -v f="$fqdn" '$1==f{print $2}' "$apps_file" | head -n1)"

  rm -f "${apps_dir}/${fqdn}.app" 2>/dev/null || true
  render_apps_manifest

  # Remove DNS override
  local overrides="$(catalog_dns_rewrites "${TENANT}")"
  if [[ -f "$overrides" ]]; then
    grep -v "local-data: \"${fqdn}\." "$overrides" > "${overrides}.tmp" || true
    mv "${overrides}.tmp" "$overrides"
    systemctl reload "unbound-tenant@${TENANT}" 2>/dev/null || true
  fi

  # Remove VIP from enforced allowlist set (do NOT reapply firewall here to preserve set state)
  if [[ -n "$vip" && "${FW_MODE}" == "enforced" ]]; then
    nft delete element inet gw "catalog_vips_${TENANT}" { ${vip} } 2>/dev/null || true
  fi

  render_envoy
  systemctl restart "envoy-tenant@${TENANT}" 2>/dev/null || true

  echo "App deleted for $TENANT: $fqdn"
}

case "$cmd" in
  add-app) add_app "$@";;
  del-app) del_app "$@";;
  list-apps) list_apps;;
  *) die "Usage: 80-app-envoy.sh <tenant.conf> add-app|del-app|list-apps ...";;
esac
