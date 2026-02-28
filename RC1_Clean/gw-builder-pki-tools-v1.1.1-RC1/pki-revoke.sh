#!/usr/bin/env bash
set -euo pipefail

# pki-revoke.sh — v1.0.0
# Revoke a USER (email) or SERVER (fqdn) certificate issued by a tenant Intermediate CA,
# regenerate tenant CRL, and optionally reload gateway mTLS planes.
#
# This script assumes the CA state is at:
#   /etc/gateway/pki/<tenant>/intermediate
#
# Notes:
# - Revocation uses openssl ca database (index.txt). The target cert must have been
#   issued by this CA and recorded in its database.
# - If you issued certs outside of "openssl ca" (e.g., "openssl x509 -req"), they
#   won't be in the database and cannot be revoked reliably here.

VERSION="1.0.0"

usage() {
  cat <<'EOF'
pki-revoke.sh (v1.0.0)

Usage:
  pki-revoke.sh revoke-user   --tenant TENANT --email user@domain   [--pki-dir DIR] [--reason REASON] [--reload]
  pki-revoke.sh revoke-server --tenant TENANT --fqdn host.domain    [--pki-dir DIR] [--reason REASON] [--reload]
  pki-revoke.sh gen-crl       --tenant TENANT                       [--pki-dir DIR] [--reload]
  pki-revoke.sh list-issued   --tenant TENANT                       [--pki-dir DIR]
  pki-revoke.sh list-revoked  --tenant TENANT                       [--pki-dir DIR]

Defaults:
  --pki-dir  /etc/gateway/pki
  --reason   keyCompromise

Reload behavior:
  --reload will attempt to run:
    /opt/gw-builder/gwctl.sh mtls-reload <tenant>
    /opt/gw-builder/gwctl.sh fwdproxy-reload <tenant>   (if present)
  If gwctl is not present, reload is skipped.

Examples:
  sudo ./pki-revoke.sh revoke-user --tenant tenantA --email alice@outlan.net --reload
  sudo ./pki-revoke.sh revoke-server --tenant tenantA --fqdn sap.outlan.net --reload
  sudo ./pki-revoke.sh gen-crl --tenant tenantA

EOF
}

die(){ echo "ERROR: $*" >&2; exit 1; }

PKI_DIR="/etc/gateway/pki"
TENANT=""
EMAIL=""
FQDN=""
REASON="keyCompromise"
RELOAD="off"
CMD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    revoke-user|revoke-server|gen-crl|list-issued|list-revoked) CMD="$1"; shift;;
    --pki-dir) PKI_DIR="$2"; shift 2;;
    --tenant) TENANT="$2"; shift 2;;
    --email) EMAIL="$2"; shift 2;;
    --fqdn) FQDN="$2"; shift 2;;
    --reason) REASON="$2"; shift 2;;
    --reload) RELOAD="on"; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown arg: $1";;
  esac
done

[[ -n "${CMD}" ]] || { usage; exit 1; }
[[ -n "${TENANT}" ]] || die "--tenant is required"

IDIR="${PKI_DIR}/${TENANT}/intermediate"
CNF="${IDIR}/openssl.cnf"
INDEX="${IDIR}/index.txt"

[[ -f "${CNF}" ]] || die "Tenant intermediate not found: ${TENANT} (${IDIR})"
[[ -f "${INDEX}" ]] || die "CA database missing: ${INDEX}"

crl_path() {
  echo "${IDIR}/crl/${TENANT}-intermediate.crl.pem"
}

ensure_crl_dir() {
  mkdir -p "${IDIR}/crl"
}

gen_crl() {
  ensure_crl_dir
  openssl ca -config "${CNF}" -gencrl -out "$(crl_path)" -batch
  echo "Generated CRL: $(crl_path)"
}

find_serial_by_subject_regex() {
  local regex="$1"
  awk -F'\t' -v re="$regex" '
    $1=="V" && $6 ~ re { print $4; exit }
  ' "${INDEX}" || true
}

list_issued() {
  echo "Issued certificates in ${TENANT} (valid entries):"
  awk -F'\t' '$1=="V"{print "SERIAL="$4"  SUBJECT="$6}' "${INDEX}" || true
}

list_revoked() {
  echo "Revoked certificates in ${TENANT}:"
  awk -F'\t' '$1=="R"{print "SERIAL="$4"  REVOKED_AT="$3"  SUBJECT="$6}' "${INDEX}" || true
}

revoke_by_serial() {
  local serial="$1"
  [[ -n "${serial}" ]] || die "No serial found to revoke"
  local cert_file="${IDIR}/newcerts/${serial}.pem"
  [[ -f "${cert_file}" ]] || die "Expected issued cert file not found: ${cert_file}"
  echo "Revoking serial: ${serial} (reason=${REASON})"
  openssl ca -config "${CNF}" -revoke "${cert_file}" -crl_reason "${REASON}" -batch
}

try_reload() {
  [[ "${RELOAD}" == "on" ]] || return 0
  local gwctl="/opt/gw-builder/gwctl.sh"
  if [[ -x "${gwctl}" ]]; then
    echo "Reloading gateway planes for ${TENANT} via gwctl..."
    "${gwctl}" mtls-reload "${TENANT}" || true
    "${gwctl}" fwdproxy-reload "${TENANT}" >/dev/null 2>&1 || true
  else
    echo "gwctl not found/executable at ${gwctl}; skipping reload"
  fi
}

cmd_revoke_user() {
  [[ -n "${EMAIL}" ]] || die "revoke-user requires --email user@domain"
  local re="(CN *= *${EMAIL}|emailAddress *= *${EMAIL})"
  local serial
  serial="$(find_serial_by_subject_regex "${re}")"
  [[ -n "${serial}" ]] || die "No matching issued cert found for user ${EMAIL} in CA database"
  revoke_by_serial "${serial}"
  gen_crl
  try_reload
}

cmd_revoke_server() {
  [[ -n "${FQDN}" ]] || die "revoke-server requires --fqdn host.domain"
  local re="(CN *= *${FQDN}\b)"
  local serial
  serial="$(find_serial_by_subject_regex "${re}")"
  [[ -n "${serial}" ]] || die "No matching issued cert found for server ${FQDN} in CA database"
  revoke_by_serial "${serial}"
  gen_crl
  try_reload
}

case "${CMD}" in
  revoke-user)   cmd_revoke_user;;
  revoke-server) cmd_revoke_server;;
  gen-crl)       gen_crl; try_reload;;
  list-issued)   list_issued;;
  list-revoked)  list_revoked;;
  *) die "Unknown command: ${CMD}";;
esac
