# VRF/VXLAN Implementation Checklist (Rocky Linux 9/10)

This checklist walks through preparing Rocky Linux hosts, rewiring networking, and deploying a VRF/VXLAN overlay using the helper scripts.

---

## 1. Prep and safety

- [ ] Ensure console/IPMI access in case SSH drops during NetworkManager changes.
- [ ] Back up important NetworkManager connection profiles:
  - [ ] `/etc/NetworkManager/system-connections/` (copy somewhere safe).
- [ ] Confirm each host has:
  - [ ] 2 Ethernet NICs.
  - [ ] 1 wireless NIC.

---

## 2. Preflight on each host (`rocky_vrf_vxlan_preflight.sh`)

- [ ] Copy `rocky_vrf_vxlan_preflight.sh` to the host.
- [ ] Make it executable:
  - [ ] `chmod +x rocky_vrf_vxlan_preflight.sh`
- [ ] Dry-run preflight:
  - [ ] `sudo ./rocky_vrf_vxlan_preflight.sh -D`
- [ ] Run preflight for real:
  - [ ] `sudo ./rocky_vrf_vxlan_preflight.sh`
- [ ] Verify preflight reports:
  - [ ] `dnf` present.
  - [ ] `iproute` installed.
  - [ ] `systemd-networkd` available.
  - [ ] Kernel modules checked: `vrf`, `vxlan`, `8021q`, `macvlan`, `ipvlan`.

---

## 3. Rewire networking & rename interfaces (`rocky_net_rewire.sh`)

- [ ] Copy `rocky_net_rewire.sh` to each host.
- [ ] Make it executable:
  - [ ] `chmod +x rocky_net_rewire.sh`
- [ ] Dry-run forward mode:
  - [ ] `sudo ./rocky_net_rewire.sh -D`
  - [ ] Confirm it detects exactly **2 Ethernet** and **1 WLAN** device.
  - [ ] Confirm planned mapping:
    - [ ] Ethernet → `en0`, `en1` (sorted by MAC).
    - [ ] WLAN → `wlan0`.
- [ ] Apply forward mode (non-interactive recommended):
  - [ ] `sudo ./rocky_net_rewire.sh -P`
- [ ] If you did not trigger udev immediately, **reboot** the host.
- [ ] After reboot or trigger, verify naming:
  - [ ] `ip -o link show` lists `en0`, `en1`, `wlan0`.
- [ ] Optional rollback plan:
  - [ ] To restore NetworkManager and remove custom naming:
    - [ ] `sudo ./rocky_net_rewire.sh -R`

---

## 4. Deploy VRF/VXLAN scripts

On each host:

- [ ] Ensure the following scripts are present:
  - [ ] `vrf_vxlan_setup.sh`
  - [ ] `vrf_vxlan_test.sh`
  - [ ] `vrf_vxlan_teardown.sh`
- [ ] Make them executable:
  - [ ] `chmod +x vrf_vxlan_*.sh`

Optional: create per-host profile files for automation:

- [ ] On Host A, create `hostA.env` with e.g.:
  - [ ] `UNDERLAY_IF=en0`
  - [ ] `UNDERLAY_IP=10.0.0.1/24`
  - [ ] `REMOTE_UNDERLAY_IP=10.0.0.2`
  - [ ] `VRF_NAME=vrf-blue`
  - [ ] `VRF_TABLE=1001`
  - [ ] `VNI=10010`
  - [ ] `PRIMARY_VLAN_ID=10`
  - [ ] `PRIMARY_VRF_IP=192.168.10.1/24`
- [ ] On Host B, create `hostB.env` with mirrored values:
  - [ ] `UNDERLAY_IF=en0`
  - [ ] `UNDERLAY_IP=10.0.0.2/24`
  - [ ] `REMOTE_UNDERLAY_IP=10.0.0.1`
  - [ ] `VRF_NAME=vrf-blue`
  - [ ] `VRF_TABLE=1001`
  - [ ] `VNI=10010`
  - [ ] `PRIMARY_VLAN_ID=10`
  - [ ] `PRIMARY_VRF_IP=192.168.10.2/24`

---

## 5. Build the VRF/VXLAN overlay

### Host A

