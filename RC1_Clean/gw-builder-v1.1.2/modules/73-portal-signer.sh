#!/usr/bin/env bash
set -euo pipefail

# v1.0.0 - Portal signer worker (Phase 1 end-to-end issuance)
# Watches /etc/gateway/portal/<tenant>/issued/* for request.csr.pem and signs it
# with tenant intermediate CA, then creates bundle.zip for portal download endpoint.

STATE_DIR="/etc/gateway/portal"
OUT_ZIP_NAME="bundle.zip"


validate_csr_email() {
  local csr="$1" expected_email="$2"

  openssl req -in "$csr" -noout >/dev/null 2>&1 || return 1

  local subj
  subj="$(openssl req -in "$csr" -noout -subject 2>/dev/null || true)"

  if ! echo "$subj" | grep -Eq "(CN *= *${expected_email}\b|emailAddress *= *${expected_email}\b)"; then
    echo "CSR subject does not contain expected email (CN or emailAddress): $expected_email" >&2
    echo "CSR subject: $subj" >&2
    return 1
  fi

  local text
  text="$(openssl req -in "$csr" -noout -text 2>/dev/null || true)"
  if ! echo "$text" | grep -A2 -i "Subject Alternative Name" | grep -qi "email:${expected_email}"; then
    echo "CSR missing required SAN email:${expected_email}" >&2
    return 1
  fi
  return 0
}


sign_one() {
  local tenant="$1" rid="$2"
  local req_dir="${STATE_DIR}/${tenant}/issued/${rid}"
  local csr="${req_dir}/request.csr.pem"
  local email_file="${req_dir}/email.txt"
  local done="${req_dir}/${OUT_ZIP_NAME}"

  [[ -f "${csr}" ]] || return 0
  [[ -f "${email_file}" ]] || return 0
  [[ -f "${done}" ]] && return 0

  local email
  email="$(tr -d '\r\n' < "${email_file}")"

  # Enforce identity binding: prefer SAN email, and require CN/emailAddress match
  validate_csr_email "${csr}" "${email}" || { echo "CSR validation failed for ${email}"; return 0; }

  local ca_dir="/etc/gateway/pki/${tenant}/intermediate"
  local out_dir="${req_dir}/out"
  mkdir -p "${out_dir}"

  # Sign CSR
  openssl ca -config "${ca_dir}/openssl.cnf" \
    -extensions usr_cert \
    -days 30 \
    -notext \
    -md sha256 \
    -in "${csr}" \
    -out "${out_dir}/cert.pem" \
    -batch

  # Chain
  if [[ -f "${ca_dir}/certs/ca-chain.cert.pem" ]]; then
    cp -f "${ca_dir}/certs/ca-chain.cert.pem" "${out_dir}/chain.pem"
  elif [[ -f "${ca_dir}/certs/intermediate.cert.pem" ]]; then
    cp -f "${ca_dir}/certs/intermediate.cert.pem" "${out_dir}/chain.pem"
  else
    : > "${out_dir}/chain.pem"
  fi

  # Bundle zip
  (cd "${out_dir}" && zip -q -r "../${OUT_ZIP_NAME}" .)

  # Metadata
  cat >"${req_dir}/issued.json" <<EOF
{"tenant":"${tenant}","request_id":"${rid}","email":"${email}","issued_ts":$(date +%s)}
EOF

  echo "Issued bundle for ${tenant} request ${rid} (${email})"
}

portal_signer_loop() {
  local tenant="$1"
  local interval="${2:-2}"
  while true; do
    local tdir="${STATE_DIR}/${tenant}/issued"
    [[ -d "${tdir}" ]] || { sleep "${interval}"; continue; }

    for req_dir in "${tdir}"/*; do
      [[ -d "${req_dir}" ]] || continue
      local rid
      rid="$(basename "${req_dir}")"
      sign_one "${tenant}" "${rid}" || true
    done
    sleep "${interval}"
  done
}
