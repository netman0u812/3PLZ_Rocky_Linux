#!/usr/bin/env bash
set -euo pipefail

# v0.5.0 - PKI revocation (CRL) + enforcement helpers
# Implements:
# - revoke-user: revoke a user's cert in tenant intermediate CA index
# - gen-crl: generate CRL for tenant intermediate
# - publish-crl: place CRL under /var/www/crl/<tenant>/ (optional)
# - nginx CRL enforcement: NGINX config references CRL file when CRL_ENFORCE=on

CRL_WWW_BASE="/var/www/crl"

pki_revoke_user() {
  local tenant="$1" email="$2"
  tenant_conf_load "${tenant}"

  local ca_dir="/etc/gateway/pki/${tenant}/intermediate"
  local cert="/etc/gateway/tls/${tenant}/users/${email}/cert.pem"
  if [[ ! -f "${cert}" ]]; then
    die "User cert not found: ${cert}"
  fi

  info "Revoking user cert for ${email} under tenant ${tenant}"
  openssl ca -config "${ca_dir}/openssl.cnf" -revoke "${cert}"

  pki_gen_crl "${tenant}"
}

pki_gen_crl() {
  local tenant="$1"
  local ca_dir="/etc/gateway/pki/${tenant}/intermediate"
  local out="${ca_dir}/crl/${tenant}-intermediate.crl.pem"
  mkdir -p "${ca_dir}/crl"
  info "Generating CRL: ${out}"
  openssl ca -config "${ca_dir}/openssl.cnf" -gencrl -out "${out}"
}

pki_publish_crl() {
  local tenant="$1"
  local ca_dir="/etc/gateway/pki/${tenant}/intermediate"
  local crl="${ca_dir}/crl/${tenant}-intermediate.crl.pem"
  if [[ ! -f "${crl}" ]]; then
    die "CRL not found; run gen-crl first: ${crl}"
  fi
  mkdir -p "${CRL_WWW_BASE}/${tenant}"
  cp -f "${crl}" "${CRL_WWW_BASE}/${tenant}/tenant-intermediate.crl.pem"
  chmod 644 "${CRL_WWW_BASE}/${tenant}/tenant-intermediate.crl.pem"
  info "Published CRL to ${CRL_WWW_BASE}/${tenant}/tenant-intermediate.crl.pem"
}

# OCSP placeholder: implementation depends on chosen responder and integration.
pki_ocsp_note() {
  cat <<'EOF'
OCSP (Parking Lot / Phase 2):
- For mTLS client certs, CRL is simplest with NGINX (ssl_crl).
- OCSP requires:
  * an OCSP responder process (per tenant or shared)
  * responder cert + key (OCSPSigning)
  * NGINX 'ssl_stapling' is for server certs; client cert OCSP is not as straightforward.
Recommendation:
- Use CRL enforcement first.
- If OCSP becomes mandatory, implement responder and validate appliance/client requirements.
EOF
}


pki_crl_refresh() {
  local tenant="$1"
  pki_gen_crl "$tenant"
  # publish if webroot exists
  if [[ -d "/var/www/crl" ]]; then
    pki_publish_crl "$tenant" || true
  fi
  # reload nginx tenants if running
  systemctl reload "nginx-tenant@${tenant}" 2>/dev/null || true
  systemctl reload "nginx-forwardproxy@${tenant}" 2>/dev/null || true
}
