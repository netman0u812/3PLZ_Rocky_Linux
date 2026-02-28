#!/usr/bin/env bash
set -euo pipefail

# pki-bootstrap.sh — v1.0.0
# Creates:
# - Root CA (self-signed)
# - Per-tenant Intermediate CA (Sub-CA) signed by Root
# - Tenant CA chain and CRL
#
# Default base directory: /etc/gateway/pki
#
# NOTE (POC vs Production):
# - For production, keep Root CA offline and do not run init-root on the gateway host.

VERSION="1.0.0"

usage() {
  cat <<'EOF'
pki-bootstrap.sh (v1.0.0)

Usage:
  pki-bootstrap.sh init-root [--pki-dir DIR] [--cn "Root CA CN"] [--days N]
  pki-bootstrap.sh init-tenant --tenant NAME [--pki-dir DIR] [--days N]
  pki-bootstrap.sh gen-crl --tenant NAME [--pki-dir DIR]

Defaults:
  --pki-dir  /etc/gateway/pki
  Root CN    "GW-Builder Root CA"
  Root days  3650
  Tenant CA days 1825

Examples:
  sudo ./pki-bootstrap.sh init-root --cn "Outlan Root CA"
  sudo ./pki-bootstrap.sh init-tenant --tenant tenantA
  sudo ./pki-bootstrap.sh gen-crl --tenant tenantA
EOF
}

die(){ echo "ERROR: $*" >&2; exit 1; }

PKI_DIR="/etc/gateway/pki"
ROOT_CN="GW-Builder Root CA"
ROOT_DAYS="3650"
TENANT_DAYS="1825"
TENANT=""
CMD=""
DAYS_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    init-root|init-tenant|gen-crl) CMD="$1"; shift;;
    --pki-dir) PKI_DIR="$2"; shift 2;;
    --cn) ROOT_CN="$2"; shift 2;;
    --days) DAYS_OVERRIDE="$2"; shift 2;;
    --tenant) TENANT="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) die "Unknown arg: $1";;
  esac
done

[[ -n "${CMD}" ]] || { usage; exit 1; }

ensure_ca_dirs() {
  local dir="$1"
  mkdir -p "$dir"/{certs,crl,newcerts,private}
  chmod 700 "$dir/private"
  touch "$dir/index.txt"
  [[ -f "$dir/serial" ]] || echo 1000 >"$dir/serial"
  [[ -f "$dir/crlnumber" ]] || echo 1000 >"$dir/crlnumber"
}

write_root_openssl_cnf() {
  local root_dir="$1"
  cat >"${root_dir}/openssl.cnf" <<EOF
[ ca ]
default_ca = CA_default

[ CA_default ]
dir               = ${root_dir}
certs             = \$dir/certs
crl_dir           = \$dir/crl
new_certs_dir     = \$dir/newcerts
database          = \$dir/index.txt
serial            = \$dir/serial
crlnumber         = \$dir/crlnumber
private_key       = \$dir/private/root.key.pem
certificate       = \$dir/certs/root.cert.pem
default_md        = sha256
name_opt          = ca_default
cert_opt          = ca_default
default_days      = ${ROOT_DAYS}
policy            = policy_loose
x509_extensions   = v3_ca
copy_extensions   = copy
unique_subject    = no

[ policy_loose ]
countryName             = optional
stateOrProvinceName     = optional
localityName            = optional
organizationName        = optional
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional

[ req ]
default_bits        = 4096
distinguished_name  = req_distinguished_name
string_mask         = utf8only
default_md          = sha256
x509_extensions     = v3_ca

[ req_distinguished_name ]
commonName = Common Name (e.g. Root CA)

[ v3_ca ]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, cRLSign, keyCertSign
EOF
}

write_intermediate_openssl_cnf() {
  local idir="$1"
  cat >"${idir}/openssl.cnf" <<EOF
[ ca ]
default_ca = CA_default

[ CA_default ]
dir               = ${idir}
certs             = \$dir/certs
crl_dir           = \$dir/crl
new_certs_dir     = \$dir/newcerts
database          = \$dir/index.txt
serial            = \$dir/serial
crlnumber         = \$dir/crlnumber
private_key       = \$dir/private/intermediate.key.pem
certificate       = \$dir/certs/intermediate.cert.pem
default_md        = sha256
name_opt          = ca_default
cert_opt          = ca_default
default_days      = 365
policy            = policy_loose
unique_subject    = no
copy_extensions   = copy

[ policy_loose ]
countryName             = optional
stateOrProvinceName     = optional
localityName            = optional
organizationName        = optional
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional

[ req ]
default_bits        = 4096
distinguished_name  = req_distinguished_name
string_mask         = utf8only
default_md          = sha256

[ req_distinguished_name ]
commonName = Common Name (e.g. Tenant Intermediate CA)

[ v3_intermediate_ca ]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, digitalSignature, cRLSign, keyCertSign

[ usr_cert ]
basicConstraints = CA:FALSE
nsComment = "GW-Builder Client Cert"
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth

[ server_cert ]
basicConstraints = CA:FALSE
nsComment = "GW-Builder Server Cert"
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
EOF
}

cmd_init_root() {
  local root_dir="${PKI_DIR}/root"
  local days="${DAYS_OVERRIDE:-$ROOT_DAYS}"

  ensure_ca_dirs "$root_dir"
  write_root_openssl_cnf "$root_dir"

  if [[ -f "${root_dir}/private/root.key.pem" && -f "${root_dir}/certs/root.cert.pem" ]]; then
    echo "Root CA already exists at ${root_dir}"
    return 0
  fi

  echo "Creating Root CA at ${root_dir}"
  openssl genrsa -out "${root_dir}/private/root.key.pem" 4096
  chmod 600 "${root_dir}/private/root.key.pem"

  openssl req -x509 -new -nodes \
    -key "${root_dir}/private/root.key.pem" \
    -sha256 -days "${days}" \
    -out "${root_dir}/certs/root.cert.pem" \
    -subj "/CN=${ROOT_CN}"

  echo "Root CA created:"
  openssl x509 -in "${root_dir}/certs/root.cert.pem" -noout -subject -issuer
}

cmd_init_tenant() {
  [[ -n "${TENANT}" ]] || die "init-tenant requires --tenant NAME"
  local tenant="${TENANT}"
  local root_dir="${PKI_DIR}/root"
  local tenant_dir="${PKI_DIR}/${tenant}/intermediate"
  local days="${DAYS_OVERRIDE:-$TENANT_DAYS}"

  [[ -f "${root_dir}/private/root.key.pem" && -f "${root_dir}/certs/root.cert.pem" ]] || \
    die "Root CA not found. Run init-root first (or provide offline Root artifacts)."

  mkdir -p "${PKI_DIR}/${tenant}"
  ensure_ca_dirs "${tenant_dir}"
  mkdir -p "${tenant_dir}/csr"
  write_intermediate_openssl_cnf "${tenant_dir}"

  if [[ -f "${tenant_dir}/private/intermediate.key.pem" && -f "${tenant_dir}/certs/intermediate.cert.pem" ]]; then
    echo "Tenant intermediate already exists: ${tenant}"
  else
    echo "Creating tenant intermediate key+CSR: ${tenant}"
    openssl genrsa -out "${tenant_dir}/private/intermediate.key.pem" 4096
    chmod 600 "${tenant_dir}/private/intermediate.key.pem"

    openssl req -new -sha256 \
      -key "${tenant_dir}/private/intermediate.key.pem" \
      -out "${tenant_dir}/csr/intermediate.csr.pem" \
      -subj "/CN=${tenant} Intermediate CA"

    echo "Signing tenant intermediate with Root CA (openssl ca)"
    openssl ca -config "${root_dir}/openssl.cnf" \
      -extensions v3_intermediate_ca \
      -days "${days}" -notext -md sha256 \
      -in "${tenant_dir}/csr/intermediate.csr.pem" \
      -out "${tenant_dir}/certs/intermediate.cert.pem" \
      -batch
  fi

  # Build chain
  cat "${tenant_dir}/certs/intermediate.cert.pem" "${root_dir}/certs/root.cert.pem" > \
    "${tenant_dir}/certs/ca-chain.cert.pem"

  # Initialize CRL file
  mkdir -p "${tenant_dir}/crl"
  openssl ca -config "${tenant_dir}/openssl.cnf" -gencrl \
    -out "${tenant_dir}/crl/${tenant}-intermediate.crl.pem" -batch

  echo "Tenant intermediate ready: ${tenant}"
  echo "  Intermediate cert: ${tenant_dir}/certs/intermediate.cert.pem"
  echo "  CA chain:          ${tenant_dir}/certs/ca-chain.cert.pem"
  echo "  CRL:               ${tenant_dir}/crl/${tenant}-intermediate.crl.pem"
}

cmd_gen_crl() {
  [[ -n "${TENANT}" ]] || die "gen-crl requires --tenant NAME"
  local tenant="${TENANT}"
  local tenant_dir="${PKI_DIR}/${tenant}/intermediate"
  [[ -f "${tenant_dir}/openssl.cnf" ]] || die "Tenant intermediate not found: ${tenant}"

  mkdir -p "${tenant_dir}/crl"
  openssl ca -config "${tenant_dir}/openssl.cnf" -gencrl \
    -out "${tenant_dir}/crl/${tenant}-intermediate.crl.pem" -batch

  echo "Generated CRL: ${tenant_dir}/crl/${tenant}-intermediate.crl.pem"
}

case "${CMD}" in
  init-root) cmd_init_root;;
  init-tenant) cmd_init_tenant;;
  gen-crl) cmd_gen_crl;;
  *) die "Unknown command: ${CMD}";;
esac
