GW SSH/SFTP Reverse Proxy Add-on (HAProxy TCP) — v0.1.2
======================================================

Purpose
-------
Per-tenant SSH/SFTP "reverse proxy" service using the same UX pattern as HTTPS reverse proxy:
- DNS rewrite maps hostname -> tenant VIP (172.16.x.y)
- User connects to original hostname (ssh/sftp)
- Gateway forwards TCP: VIP:22 -> upstream:22

MVG friendly
------------
- No external identity dependencies
- SSH remains end-to-end encrypted
- Upstream server enforces user auth (password/key)

Install
-------
1) Install HAProxy:
   sudo dnf install -y haproxy

2) Install add-on:
   unzip gw-sshproxy-v0.1.0.zip
   cd gw-sshproxy-v0.1.0
   sudo ./gw-sshproxyctl.sh install

3) Enable per tenant:
   /opt/gw-builder/tenants/<tenant>.conf
     SSH_PROXY_MODE=on
     SSH_PROXY_UPSTREAM_ALLOWLIST=<approved upstream IPs>
     SSH_PROXY_EGRESS_IF=eth0   # recommended for safe enforcement

Manage services
---------------
Add:
  sudo /opt/gw-sshproxy/gw-sshproxyctl.sh add tenantA remote-host 172.16.100.50 93.77.89.1 22
List:
  /opt/gw-sshproxy/gw-sshproxyctl.sh list tenantA
Apply:
  sudo /opt/gw-sshproxy/gw-sshproxyctl.sh apply tenantA
Status:
  /opt/gw-sshproxy/gw-sshproxyctl.sh status tenantA
Remove:
  sudo /opt/gw-sshproxy/gw-sshproxyctl.sh remove tenantA

User experience
---------------
After DNS rewrite: remote-host.outlan.net -> 172.16.100.50
Tenant user:
  ssh user@remote-host.outlan.net
  sftp user@remote-host.outlan.net

Limitations
-----------
- No OTP/MFA yet (planned for Production)
- No SSH decryption/inspection (by design)


v0.1.1: Automatically emits SSH_PROXY_UPSTREAM_ALLOWLIST from services.csv on apply.


v0.1.2: Auto-detect WAN_IF and set SSH_PROXY_EGRESS_IF_DEFAULT; apply auto-writes SSH_PROXY_EGRESS_IF when missing.
