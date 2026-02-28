#!/usr/bin/env bash
set -euo pipefail

# pki-issue.sh — v1.1.0
# Issues tenant mTLS user (ClientAuth) and server (ServerAuth) certificates
# from a per-tenant Intermediate CA located at /etc/gateway/pki/<tenant>/intermediate.
#
# Preferred mode: sign-* (sign external CSR; key stays with requester).
# POC mode: issue-* (generate key+csr+cert locally).

VERSION="1.1.0"

usage() {
  cat <<'EOF'
pki-issue.sh (v1.1.0)

Usage:
  # User mTLS (ClientAuth)
  pki-issue.sh sign-user-csr  --tenant TENANT --email user@domain --csr /path/to/user.csr.pem   [--pki-dir DIR] [--days N] [--outdir DIR]
  pki-issue.sh issue-user     --tenant TENANT --email user@domain                               [--pki-dir DIR] [--days N] [--outdir DIR] [--p12]

  # Server TLS (ServerAuth) for per-app VIP listeners
  pki-issue.sh sign-server-csr --tenant TENANT --fqdn host.domain --csr /path/to/server.csr.pem [--pki-dir DIR] [--days N] [--outdir DIR]
  pki-issue.sh issue-server    --tenant TENANT --fqdn host.domain                               [--pki-dir DIR] [--days N] [--outdir DIR] [--p12]

Defaults:
  --pki-dir  /etc/gateway/pki
  --days     30
  --outdir   ./out

Identity binding rules:
- User certs (v1.0.1+):
  * CSR Subject MUST contain CN=<email> OR emailAddress=<email>
  * CSR MUST contain SAN email:<email>
- Server certs:
  * CSR MUST contain SAN DNS:<fqdn>
  * CN should typically be <fqdn> (recommended)

Examples:
  ./pki-issue.sh sign-user-csr --tenant tenantA --email alice@outlan.net --csr alice.csr.pem --outdir ./alice

  ./pki-issue.sh issue-user --tenant tenantA --email alice@outlan.net --outdir ./alice --p12

  ./pki-issue.sh sign-server-csr --tenant tenantA --fqdn sap.outlan.net --csr sap.csr.pem --outdir ./sap

  ./pki-issue.sh issue-server --tenant tenantA --fqdn sap.outlan.net --outdir ./sap

EOF
}

die(){ echo "ERROR: $*" >&2; exit 1; }

PKI_DIR="/etc/gateway/pki"
DAYS="30"
OUTDIR="./out"
TENANT=""
EMAIL=""
FQDN=""
CSR=""
P12="off"
CMD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    sign-user-csr|issue-user|sign-server-csr|issue-server) CMD="$1"; shift;;
    --pki-dir) PKI_DIR="$2"; shift 2;;
    --days) DAYS="$2"; shift 2;;
    --outdir) OUTDIR="$2"; shift 2;;
    --tenant) TENANT="$2"; shift 2;;
    --email) EMAIL="$2"; shift 2;;
    --fqdn) FQDN="$2"; shift 2;;
    --csr) CSR="$2"; shift 2;;
    --p12) P12="on"; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown arg: $1";;
  esac
done

[[ -n "${CMD}" ]] || { usage; exit 1; }
[[ -n "${TENANT}" ]] || die "--tenant is required"

IDIR="${PKI_DIR}/${TENANT}/intermediate"
[[ -f "${IDIR}/openssl.cnf" ]] || die "Tenant intermediate not found: ${TENANT} (${IDIR})"

validate_user_csr() {
  local csr="$1" expected="$2"
  openssl req -in "$csr" -noout >/dev/null 2>&1 || return 1
  local subj text
  subj="$(openssl req -in "$csr" -noout -subject 2>/dev/null || true)"
  if ! echo "$subj" | grep -Eq "(CN *= *${expected}\b|emailAddress *= *${expected}\b)"; then
    echo "CSR subject missing CN/emailAddress=${expected}" >&2
    echo "CSR subject: $subj" >&2
    return 1
  fi
  text="$(openssl req -in "$csr" -noout -text 2>/dev/null || true)"
  if ! echo "$text" | grep -A2 -i "Subject Alternative Name" | grep -qi "email:${expected}"; then
    echo "CSR missing required SAN email:${expected}" >&2
    return 1
  fi
  return 0
}

validate_server_csr() {
  local csr="$1" fqdn="$2"
  openssl req -in "$csr" -noout >/dev/null 2>&1 || return 1
  local text
  text="$(openssl req -in "$csr" -noout -text 2>/dev/null || true)"
  if ! echo "$text" | grep -A3 -i "Subject Alternative Name" | grep -qi "DNS:${fqdn}"; then
    echo "CSR missing required SAN DNS:${fqdn}" >&2
    return 1
  fi
  return 0
}

bundle_zip() {
  local outdir="$1"
  (cd "$outdir" && zip -q -r "bundle.zip" ./*)
}

sign_user_csr() {
  [[ -n "${EMAIL}" ]] || die "sign-user-csr requires --email"
  [[ -n "${CSR}" ]] || die "sign-user-csr requires --csr"
  [[ -f "${CSR}" ]] || die "CSR not found: ${CSR}"
  mkdir -p "${OUTDIR}"
  validate_user_csr "${CSR}" "${EMAIL}" || die "CSR validation failed"

  local cert_out="${OUTDIR}/${EMAIL}.cert.pem"
  local chain_out="${OUTDIR}/chain.pem"

  openssl ca -config "${IDIR}/openssl.cnf" \
    -extensions usr_cert \
    -days "${DAYS}" -notext -md sha256 \
    -in "${CSR}" \
    -out "${cert_out}" \
    -batch

  cp -f "${IDIR}/certs/ca-chain.cert.pem" "${chain_out}" 2>/dev/null || \
    cp -f "${IDIR}/certs/intermediate.cert.pem" "${chain_out}"

  bundle_zip "${OUTDIR}"
  echo "Issued USER cert bundle at: ${OUTDIR}/bundle.zip"
}

issue_user_poc() {
  [[ -n "${EMAIL}" ]] || die "issue-user requires --email"
  mkdir -p "${OUTDIR}"

  local key="${OUTDIR}/${EMAIL}.key.pem"
  local csr="${OUTDIR}/${EMAIL}.csr.pem"
  local cert="${OUTDIR}/${EMAIL}.cert.pem"
  local chain="${OUTDIR}/chain.pem"

  openssl genrsa -out "${key}" 2048
  chmod 600 "${key}"

  openssl req -new -sha256 \
    -key "${key}" \
    -out "${csr}" \
    -subj "/CN=${EMAIL}" \
    -addext "subjectAltName=email:${EMAIL}"

  validate_user_csr "${csr}" "${EMAIL}" || die "Generated CSR validation failed"

  openssl ca -config "${IDIR}/openssl.cnf" \
    -extensions usr_cert \
    -days "${DAYS}" -notext -md sha256 \
    -in "${csr}" \
    -out "${cert}" \
    -batch

  cp -f "${IDIR}/certs/ca-chain.cert.pem" "${chain}" 2>/dev/null || \
    cp -f "${IDIR}/certs/intermediate.cert.pem" "${chain}"

  if [[ "${P12}" == "on" ]]; then
    openssl pkcs12 -export \
      -inkey "${key}" \
      -in "${cert}" \
      -certfile "${chain}" \
      -out "${OUTDIR}/${EMAIL}.p12"
  fi

  bundle_zip "${OUTDIR}"
  echo "Issued USER POC bundle at: ${OUTDIR}/bundle.zip"
}

sign_server_csr() {
  [[ -n "${FQDN}" ]] || die "sign-server-csr requires --fqdn"
  [[ -n "${CSR}" ]] || die "sign-server-csr requires --csr"
  [[ -f "${CSR}" ]] || die "CSR not found: ${CSR}"
  mkdir -p "${OUTDIR}"
  validate_server_csr "${CSR}" "${FQDN}" || die "CSR validation failed"

  local cert_out="${OUTDIR}/${FQDN}.cert.pem"
  local chain_out="${OUTDIR}/chain.pem"

  openssl ca -config "${IDIR}/openssl.cnf" \
    -extensions server_cert \
    -days "${DAYS}" -notext -md sha256 \
    -in "${CSR}" \
    -out "${cert_out}" \
    -batch

  cp -f "${IDIR}/certs/ca-chain.cert.pem" "${chain_out}" 2>/dev/null || \
    cp -f "${IDIR}/certs/intermediate.cert.pem" "${chain_out}"

  bundle_zip "${OUTDIR}"
  echo "Issued SERVER cert bundle at: ${OUTDIR}/bundle.zip"
}

issue_server_poc() {
  [[ -n "${FQDN}" ]] || die "issue-server requires --fqdn"
  mkdir -p "${OUTDIR}"

  local key="${OUTDIR}/${FQDN}.key.pem"
  local csr="${OUTDIR}/${FQDN}.csr.pem"
  local cert="${OUTDIR}/${FQDN}.cert.pem"
  local chain="${OUTDIR}/chain.pem"

  openssl genrsa -out "${key}" 2048
  chmod 600 "${key}"

  openssl req -new -sha256 \
    -key "${key}" \
    -out "${csr}" \
    -subj "/CN=${FQDN}" \
    -addext "subjectAltName=DNS:${FQDN}"

  validate_server_csr "${csr}" "${FQDN}" || die "Generated CSR validation failed"

  openssl ca -config "${IDIR}/openssl.cnf" \
    -extensions server_cert \
    -days "${DAYS}" -notext -md sha256 \
    -in "${csr}" \
    -out "${cert}" \
    -batch

  cp -f "${IDIR}/certs/ca-chain.cert.pem" "${chain}" 2>/dev/null || \
    cp -f "${IDIR}/certs/intermediate.cert.pem" "${chain}"

  if [[ "${P12}" == "on" ]]; then
    openssl pkcs12 -export \
      -inkey "${key}" \
      -in "${cert}" \
      -certfile "${chain}" \
      -out "${OUTDIR}/${FQDN}.p12"
  fi

  bundle_zip "${OUTDIR}"
  echo "Issued SERVER POC bundle at: ${OUTDIR}/bundle.zip"
}

case "${CMD}" in
  sign-user-csr) sign_user_csr;;
  issue-user) issue_user_poc;;
  sign-server-csr) sign_server_csr;;
  issue-server) issue_server_poc;;
  *) die "Unknown command: ${CMD}";;
esac
