# GW-Builder MVG Platform (v1.1.2-RC1)

GW-Builder is a multi-tenant secure gateway framework for Rocky Linux 9 providing:

- Per-tenant VRF isolation
- IPsec VTI site-to-site tunnels (IKEv2 PSK)
- Per-tenant BGP routing (FRR)
- Tenant DNS namespace preservation + rewrite plane
- Forward proxy (Squid) for generic HTTP/HTTPS egress
- Reverse proxy enforcement plane with mTLS user authentication
- Per-tenant PKI tooling (Root CA → Tenant Sub-CA → User/Server certs)
- Optional inspection export add-on (tap/log modes)
- Optional SSH/SFTP reverse proxy add-on with nftables allow-list guardrails

## Quick Start

1. Install on Rocky Linux 9 with 2 NICs (WAN + LAN).
2. Configure `gw.conf` with interface names and address pools.
3. Run:

```bash
./gwctl.sh install
./gwctl.sh preflight
./gwctl.sh add-tenant tenantA
./gwctl.sh tenant-health tenantA
```

4. Configure tenant peer IPsec + BGP.
5. Add reverse proxy apps:

```bash
./gwctl.sh add-app tenantA sap.outlan.net 172.16.100.50 10.99.40.7:443 inspect=on
```

6. Use PKI tools to issue user mTLS certificates.

## Canonical Tenant Service Catalog

All tenant services are defined under:

```
/etc/gateway/catalog/<tenant>/
  reverse-proxy.d/
  ssh.d/
  dns-rewrites.conf
  inspection.conf
```

## Testing

Use the RC1 QA Binder:

- Comprehensive test plan
- Execution worksheet
- Customer onboarding worksheet

## Status

Release Candidate 1 is feature-complete for MVG.
Next step: Execute full validation + bug fixing before GA.

