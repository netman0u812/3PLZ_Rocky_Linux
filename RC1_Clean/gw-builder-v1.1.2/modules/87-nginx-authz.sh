#!/usr/bin/env bash
set -euo pipefail

# v1.0.0 - Per-user/per-app authorization for NGINX app VIP listeners
#
# Policy model:
# - /etc/gateway/authz/<tenant>/allow.csv lines: email,fqdn
#   - email can be "*" for all users in tenant
# - NGINX extracts mtls_email from client DN:
#   - prefers emailAddress=... in DN
#   - else if CN looks like email uses CN
# - NGINX enforces allow/deny per request:
#   - per-app server includes authz snippet which returns 403 if not allowed

AUTHZ_DIR="/etc/gateway/authz"
NGINX_TENANTS_DIR="/etc/nginx/tenants"

authz_allow_file() {
  local tenant="$1"
  echo "${AUTHZ_DIR}/${tenant}/allow.csv"
}

authz_allow_add() {
  local tenant="$1" email="$2" fqdn="$3"
  mkdir -p "${AUTHZ_DIR}/${tenant}"
  local f; f="$(authz_allow_file "${tenant}")"
  touch "$f"
  grep -qF "${email},${fqdn}" "$f" || echo "${email},${fqdn}" >>"$f"
}

authz_allow_del() {
  local tenant="$1" email="$2" fqdn="$3"
  local f; f="$(authz_allow_file "${tenant}")"
  [[ -f "$f" ]] || return 0
  grep -vF "${email},${fqdn}" "$f" >"${f}.tmp" || true
  mv -f "${f}.tmp" "$f"
}

authz_build_nginx_snippets() {
  local tenant="$1"
  local tdir="${NGINX_TENANTS_DIR}/${tenant}"
  mkdir -p "${tdir}/conf.d"

  local f; f="$(authz_allow_file "${tenant}")"
  mkdir -p "$(dirname "$f")"
  touch "$f"

  # 1) Extract mtls_email
  cat >"${tdir}/conf.d/authz.conf" <<'EOF'
# v1.0.0 authz: derive an email from client DN if present
map $ssl_client_s_dn $mtls_email {
  default "";
  ~*emailAddress=([^,\/]+) $1;
  ~*CN=([^,\/]+@[^,\/]+) $1;
}

# Build a key "email|host" for allowlist matching
map "$mtls_email|$host" $authz_ok {
  default 0;
EOF

  # 2) Allowlist entries
  while IFS=, read -r email fqdn; do
    email="$(echo "${email:-}" | xargs || true)"
    fqdn="$(echo "${fqdn:-}" | xargs || true)"
    [[ -n "$email" && -n "$fqdn" ]] || continue
    [[ "$email" =~ ^# ]] && continue

    if [[ "$email" == "*" ]]; then
      # wildcard for any user: match "|fqdn"
      echo "  \"|${fqdn}\" 1;" >>"${tdir}/conf.d/authz.conf"
    else
      echo "  \"${email}|${fqdn}\" 1;" >>"${tdir}/conf.d/authz.conf"
    fi
  done <"$f"

  cat >>"${tdir}/conf.d/authz.conf" <<'EOF'
}

# Helper: if not authorized, block
map $authz_ok $authz_block {
  default 1;
  1 0;
}
EOF

  # 3) Per-request check snippet to include inside server/location
  cat >"${tdir}/conf.d/authz_enforce.inc" <<'EOF'
# v1.0.0 authz enforcement
if ($authz_block) { return 403; }
EOF
}
