Gateway Builder (Rocky Linux 9)
Script Bundle Version: 0.4.2

What this builds
- Multi-tenant secure gateway with:
  - strongSwan IKEv2 PSK route-based tunnels (VTI)
  - Per-tenant VRFs (Linux VRF) for isolation
  - Per-tenant BGP over VTI (FRR zebra/bgpd)
  - Per-tenant DNS (Unbound) with conditional forward + rewrite overrides
  - Per-tenant Squid forward proxy (explicit CONNECT; optional transparent HTTP intercept)
  - Per-tenant Envoy reverse proxy catalog VIPs (upper /25), inspection via TLS termination optional
  - PKI: Root CA -> Tenant intermediate -> User mTLS certs; per-app MITM certs (SAN DNS:FQDN)
  - nftables firewall with per-tenant modes:
      permit-all: bootstrap; broad allowances within guardrails
      enforced  : least-privilege; reverse proxy VIPs allowed only if created in catalog

Install location
- Recommended: /opt/gw-builder
- Bundle includes files exactly as installed under /opt/gw-builder:
  gw.conf
  gwctl.sh
  modules/*.sh

Quick start (as root)
1) Place bundle at /opt/gw-builder and make executable:
   chmod +x /opt/gw-builder/gwctl.sh /opt/gw-builder/modules/*.sh

2) Initialize host (prompts for WAN/LAN if not set in gw.conf):
   /opt/gw-builder/gwctl.sh init

3) Core setup:
   /opt/gw-builder/gwctl.sh core-setup

4) Add tenant:
   /opt/gw-builder/gwctl.sh add-tenant tenantA --peer 203.0.113.50
   - prompts for squid mode, firewall mode, reverse proxy inspect default, tap mode
   - then edit PSK:
       /etc/ipsec.d/tenants/tenantA.secrets
   - apply BGP:
       /opt/gw-builder/gwctl.sh apply-bgp tenantA
   - start services:
       /opt/gw-builder/gwctl.sh tenant-start tenantA

Catalog reverse proxy (Envoy)
- Issue per-app cert (for MITM inspection / TLS termination):
   /opt/gw-builder/gwctl.sh issue-app-cert tenantA sap.outlan.net

- Add app VIP + DNS rewrite + Envoy listener:
   /opt/gw-builder/gwctl.sh add-app tenantA sap.outlan.net 10.99.40.7:443 on yes
   Arguments:
     inspect: inherit|on|off
     auto_cert: yes|no (issues per-app cert if inspect resolves to on)

- List/delete apps:
   /opt/gw-builder/gwctl.sh list-apps tenantA
   /opt/gw-builder/gwctl.sh del-app tenantA sap.outlan.net

Firewall behavior (v0.4.2)
- permit-all: tenant subnet broadly allowed (still guarded on WAN)
- enforced:
   - DNS VIP (53) allowed
   - Squid VIP (3128) allowed
   - Catalog VIPs (443) allowed ONLY if created via add-app
     (VIPs are maintained in nft set: inet gw catalog_vips_<tenant>)
   - Tenant->core veth transit allowed

Diagnostics
- /opt/gw-builder/gwctl.sh diag tenantA

Transparent proxy note
- This bundle supports transparent HTTP intercept via nft/iptables REDIRECT to Squid intercept port.
- Transparent HTTPS without MITM is not implemented; use explicit CONNECT unless you deliberately add MITM.

Envoy package
- The bundle checks if 'envoy' RPM is installed.
- If missing, install from an approved vendor repo for Rocky/RHEL 9, then re-run:
   /opt/gw-builder/gwctl.sh check

Files and generated state
- Tenant configs:
   /etc/gateway/tenants.d/<tenant>.conf
- DNS configs:
   /etc/unbound/tenants/<tenant>/
- Envoy configs:
   /etc/envoy/tenants/<tenant>/
- PKI:
   /etc/gateway/pki/
- TLS (issued certs/keys):
   /etc/gateway/tls/<tenant>/
- Firewall:
   /etc/nftables.conf
   /etc/nftables.d/




=== v1.0.0 (GA) — Must-Deliver Goal Completion ===
This release completes the remaining must-deliver goals for v1.0:
- End-to-end mTLS enforcement plane:
  - NGINX tenant reverse proxy listeners (per-app VIPs) with mTLS and L7 JSON logs
  - NGINX forward proxy mTLS wrapper (TCP stream) for Squid CONNECT/explicit proxy use
- End-to-end certificate enrollment portal:
  - mTLS-protected portal VIP with OTP bootstrap (Phase 1)
  - signer worker that fulfills CSR signing requests into downloadable bundles
- Service-catalog authorization (per-user/per-app):
  - allowlist policy (email,fqdn) with '*' wildcard
  - NGINX enforcement (403) and reload workflow
- PKI revocation (CRL) completeness:
  - revoke user -> gen CRL -> optional publish -> reload nginx
  - daily systemd timer for CRL refresh + nginx reload

New gwctl commands:
- mtls-enable <tenant> [crl=on|off]
- mtls-reload <tenant>
- portal-enable <tenant>
- portal-disable <tenant>
- otp-create <tenant> <email> [ttl=900]
- portal-signer-loop <tenant> [interval=2]   (used by gw-portal-signer@TENANT)
- fwdproxy-enable <tenant> [listen_port=8443]
- fwdproxy-disable <tenant>
- app-allow <tenant> <email|*> <fqdn>
- app-deny  <tenant> <email|*> <fqdn>
- crl-refresh <tenant>
- crl-timer-enable <tenant>
- crl-timer-disable <tenant>

NOTE:
- OTP/SSH Proxy and packet-TAP export are planned for 1.x.
- SAML/OIDC is planned for 1.x.


v1.0.1 Note (Identity Extraction)
- User certificates MUST include subjectAltName email:<user@domain>.
- CSR must also include CN=<email> (or emailAddress=<email>) to support simple NGINX extraction.


v1.0.2: Vendor IPsec compatibility
- Add per-tenant IPSEC_PROFILE=strongswan|cisco|arista
- New commands: set-ipsec-profile, ipsec-peer-template
- Profiles: ipsec-profiles.conf


v1.0.3: MSS clamp hook (nftables)
- New: gwctl ipsec-mss-clamp <apply|remove|show> <tenant>
- Enforces PROFILE_*_MSS_CLAMP on tenant VTI interface (tcp SYN MSS clamp).


v1.0.4: CLI Guide + hook wiring
- docs/GW-Builder-CLI-Guide-v1.0.4.txt
- run_tenant_hooks() wired into tenant start to apply hooks after IPsec up.


v1.0.5: Inspection export add-on support (Option A)
- Adds DECRYPT_IFACE and INSPECTION_* config fields
- Creates per-tenant veth dec-<tenant>/dec-<tenant>-core
- Adds hook modules/96-inspection-export-hook.sh to call external /opt/gw-inspection/gw-inspectctl.sh
- Adds docs/Inspection-Export-Addon-Architecture-v1.0.5.txt


v1.0.6: Inspection add-on enhancements (docs)
- Bidirectional mirroring + nft allow-list guardrail supported by external add-on v0.1.1
- docs/Inspection-Export-Addon-Architecture-v1.0.6.txt
- docs/GW-Builder-CLI-Guide-v1.0.6.txt
