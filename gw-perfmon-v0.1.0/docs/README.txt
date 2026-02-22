gw-perfmon v0.1.0 (RC1-light)
============================

Portal-side perf monitoring for placement governance.

It polls each gw-node via SSH, samples interface byte counters and /proc/stat,
computes a composite load and projected load, then stores results into the SoT
registry database (/etc/gateway/registry/registry.db) in table node_metrics.

Scoring:
- composite_load = max(interface_util%, cpu_util%, tenant_density%)
- projected = composite_load * (1 + oversub/100)
- cap table:
    0 -> 75
   25 -> 75
   50 -> 125
   75 -> 150
  100 -> 175
- eligibility:
   OK         projected <= cap
   WARN       cap < projected <= cap+10
   INELIGIBLE projected > cap+10

Install:
  sudo ./bin/install.sh
  sudo vi /etc/gateway/perfmon/gwperf.conf

Report:
  gwperf-report 50
