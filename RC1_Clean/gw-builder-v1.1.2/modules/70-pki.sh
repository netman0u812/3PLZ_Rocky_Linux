#!/usr/bin/env bash
set -euo pipefail
source /opt/gw-builder/gw.conf
source /opt/gw-builder/modules/00-common.sh

tconf="${1:-}"; shift || true
cmd="${1:-create}"; shift || true

if [[ -n "${tconf:-}" && -f "$tconf" ]]; then
  # shellcheck source=/dev/null
  source "$tconf"
fi

root_dir="${PKI_DIR}/root"
tenant_dir="${PKI_DIR}/${TENANT:-}"

root_init() {
  ensure_dirs
  mkdir -p "${root_dir}/private" "${root_dir}/certs" "${root_dir}/newcerts"
  chmod 700 "${root_dir}/private" || true
  touch "${root_dir}/index.txt"
  [[ -f "${root_dir}/serial" ]] || echo "1000" > "${root_dir}/serial"

  local key="${root_dir}/private/root-ca.key.pem"
  local crt="${root_dir}/certs/root-ca.cert.pem"
  if [[ ! -f "$key" ]]; then
    openssl genrsa -out "$key" 4096
    chmod 600 "$key" || true
  fi
  if [[ ! -f "$crt" ]]; then
    openssl req -x509 -new -nodes -key "$key" -sha256 -days 3650 \
      -subj "/CN=Gateway Platform Root CA" \
      -out "$crt"
  fi
  echo "Root CA ready: $crt"
}

write_tenant_openssl_cnf() {
  local dir="$1"
  cat >"${dir}/intermediate/openssl.cnf" <<EOF
[ ca ]
default_ca = CA_default

[ CA_default ]
dir               = ${dir}/intermediate
certs             = \$dir/certs
crl_dir           = \$dir/crl
new_certs_dir     = \$dir/newcerts
database          = \$dir/index.txt
serial            = \$dir/serial
private_key       = \$dir/private/tenant-intermediate.key.pem
certificate       = \$dir/certs/tenant-intermediate.cert.pem
default_md        = sha256
policy            = policy_loose
email_in_dn       = no
copy_extensions   = copy
unique_subject    = no
default_days      = 825

[ policy_loose ]
commonName              = supplied

[ req ]
default_bits        = 2048
distinguished_name  = req_distinguished_name
string_mask         = utf8only

[ req_distinguished_name ]
commonName = Common Name

[ server_cert ]
basicConstraints = CA:FALSE
nsCertType = server
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth

[ usr_cert ]
basicConstraints = CA:FALSE
nsCertType = client
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
EOF
}

tenant_init() {
  [[ -n "${TENANT:-}" ]] || die "tenant_init requires tenant context"
  root_init

  mkdir -p "${tenant_dir}/intermediate/private" "${tenant_dir}/intermediate/certs" \
           "${tenant_dir}/intermediate/newcerts"
  chmod 700 "${tenant_dir}/intermediate/private" || true
  touch "${tenant_dir}/intermediate/index.txt"
  [[ -f "${tenant_dir}/intermediate/serial" ]] || echo "1000" > "${tenant_dir}/intermediate/serial"

  write_tenant_openssl_cnf "${tenant_dir}"

  local ikey="${tenant_dir}/intermediate/private/tenant-intermediate.key.pem"
  local icsr="${tenant_dir}/intermediate/certs/tenant-intermediate.csr.pem"
  local icrt="${tenant_dir}/intermediate/certs/tenant-intermediate.cert.pem"

  if [[ ! -f "$ikey" ]]; then
    openssl genrsa -out "$ikey" 4096
    chmod 600 "$ikey" || true
  fi
  if [[ ! -f "$icrt" ]]; then
    openssl req -new -key "$ikey" -subj "/CN=${TENANT} Intermediate CA" -out "$icsr"
    openssl x509 -req -in "$icsr" \
      -CA "${root_dir}/certs/root-ca.cert.pem" \
      -CAkey "${root_dir}/private/root-ca.key.pem" \
      -CAcreateserial -out "$icrt" -days 3650 -sha256
  fi

  echo "Tenant intermediate CA ready: $icrt"
}

issue_user() {
  local email="$1"
  [[ -n "${TENANT:-}" && -n "$email" ]] || die "issue_user <email> requires tenant context"
  tenant_init

  local out_dir="${TLS_DIR}/${TENANT}/users/${email}"
  mkdir -p "$out_dir"
  local key="${out_dir}/key.pem"
  local csr="${out_dir}/req.csr.pem"
  local crt="${out_dir}/cert.pem"

  openssl req -new -newkey rsa:2048 -nodes \
    -keyout "$key" \
    -out "$csr" \
    -subj "/CN=${email}" \
    -addext "subjectAltName=email:${email}"

  openssl ca -batch -config "${tenant_dir}/intermediate/openssl.cnf" \
    -extensions usr_cert -days 365 \
    -in "$csr" -out "$crt"

  chmod 600 "$key" || true
  echo "Issued user cert for ${TENANT}: ${email}"
  echo "  cert: $crt"
  echo "  key : $key"
}

issue_app_cert() {
  local fqdn="$1"
  [[ -n "${TENANT:-}" && -n "$fqdn" ]] || die "issue_app_cert <fqdn> requires tenant context"
  tenant_init

  local out_dir="${TLS_DIR}/${TENANT}/apps/${fqdn}"
  mkdir -p "$out_dir"
  local key="${out_dir}/key.pem"
  local csr="${out_dir}/req.csr.pem"
  local crt="${out_dir}/cert.pem"

  openssl req -new -newkey rsa:2048 -nodes \
    -keyout "$key" \
    -out "$csr" \
    -subj "/CN=${fqdn}" \
    -addext "subjectAltName=DNS:${fqdn}"

  openssl ca -batch -config "${tenant_dir}/intermediate/openssl.cnf" \
    -extensions server_cert -days 365 \
    -in "$csr" -out "$crt"

  chmod 600 "$key" || true
  echo "Issued app cert for ${TENANT}: ${fqdn}"
  echo "  cert: $crt"
  echo "  key : $key"
}

delete_tenant_pki() {
  [[ -n "${TENANT:-}" ]] || die "delete requires tenant context"
  rm -rf "${tenant_dir}"
  rm -rf "${TLS_DIR:?}/${TENANT}"
}

case "$cmd" in
  --root-only) root_init;;
  --tenant-only) tenant_init;;
  --issue-user) issue_user "${1:-}";;
  --issue-app-cert) issue_app_cert "${1:-}";;
  --delete) delete_tenant_pki;;
  create)
    # default behavior during tenant build: ensure tenant CA exists
    tenant_init
    ;;
  *) die "Unknown PKI command: $cmd";;
esac
