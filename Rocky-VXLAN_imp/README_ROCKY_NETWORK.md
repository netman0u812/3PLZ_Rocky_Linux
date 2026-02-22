# Rocky Linux VRF/VXLAN Preflight and Network Rewire

This README covers two helper scripts for Rocky Linux 9/10:

- `rocky_vrf_vxlan_preflight.sh` – prepares a host with required packages and kernel modules for VRF/VXLAN work.
- `rocky_net_rewire.sh` – switches networking away from NetworkManager to systemd-networkd and renames NICs to stable names (en0/en1/wlan0).

Use them together with your VRF/VXLAN configuration scripts (for example, `vrf_vxlan_setup.sh`).

> WARNING: `rocky_net_rewire.sh` will disrupt networking when NetworkManager is stopped. Run it from a console or be ready to reconnect.

---

## 1. Preflight: `rocky_vrf_vxlan_preflight.sh`

### Purpose

Ensure that a Rocky Linux 9/10 host has:

- `dnf` available.
- `iproute` installed (provides `ip` tools).
- `systemd-networkd` present (package and unit).
- Common kernel modules for advanced networking: `vrf`, `vxlan`, `8021q`, `macvlan`, `ipvlan`.

This script **does not** change NetworkManager settings, rename interfaces, or configure IP addresses.

### Usage

Make it executable:

```bash

