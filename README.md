# Data Center Monitoring — Architecture & Rollout Plan

Local, fully self-hosted, single-pane-of-glass monitoring for a small data center.

> **New to monitoring? Start with [GETTING-STARTED.md](GETTING-STARTED.md).**
> It walks you from an empty VM to working phone alerts in about 90 minutes, assuming no prior knowledge of Prometheus, Grafana, or Docker. Come back here for the reasoning.

- **[GETTING-STARTED.md](GETTING-STARTED.md)** — step-by-step setup guide, copy-paste commands, no assumed knowledge.
- **[COVERAGE.md](COVERAGE.md)** — exhaustive per-device breakdown: what to monitor, which exporter, which metrics, which alerts.
- This file — architecture, tool decisions, sizing, ports, phased rollout.

---

## 1. Design principles

1. **One TSDB, one log store, one UI.** Every device — firewall, switch, NVR, iDRAC, hypervisor, VM, database, app — lands in the same Prometheus + Loki + Grafana pane. No per-vendor consoles.
2. **Agentless where possible, agent where necessary.** SNMP/IPMI/API for appliances; `node_exporter` for anything running an OS you control.
3. **Monitoring must not live inside the thing it monitors.** A dedicated host, plus an external deadman's switch.
4. **Alert on symptoms, notify on causes.** "Site down" pages a human. "Disk 80%" files a ticket.
5. **Every alert has a runbook link.** If you can't write what to do about it, delete the alert.
6. **Alert on absence, not just failure.** A backup that silently stopped running is worse than one that fails loudly.

---

## 2. Core stack

| Layer | Tool | Why this one |
|---|---|---|
| Metrics TSDB | **Prometheus** (→ VictoriaMetrics later) | Largest exporter ecosystem; every device below has one |
| Long-term metrics | **VictoriaMetrics** | Drop-in Prometheus remote-write target; ~7× compression, 1–2 yr retention on modest disk |
| Logs | **Grafana Loki** | Label-indexed, ~10× cheaper than Elasticsearch, native Grafana integration |
| Log shipping | **Grafana Alloy** | Replaces Promtail (EOL). Also acts as syslog + SNMP-trap receiver |
| Dashboards | **Grafana** | Queries Prometheus, Loki, and MySQL/Postgres directly |
| Alerting | **Alertmanager** | Grouping, inhibition, silences, maintenance windows |
| Notifications | **ntfy** (self-hosted) + Telegram + SMTP | Push to phone without a cloud dependency |
| Uptime / SSL | **Blackbox exporter** + **Uptime Kuma** | Blackbox for alerting rules; Kuma for the human-friendly SLA view and public status page |
| Network deep-dive | **LibreNMS** *(optional)* | 5,000+ device templates, SNMP auto-discovery, LLDP topology maps. Complements Prometheus, doesn't replace it |
| Traffic analysis | **ntopng** | NetFlow/sFlow from pfSense — answers "*who* is saturating the line", which SNMP counters never can |
| Config backup | **Oxidized** | Git-versioned configs for switches + pfSense; diff on every change |
| Security / HIDS | **Wazuh** + **CrowdSec** | Wazuh: FIM, CVE-per-host, compliance. CrowdSec: active blocking with a pfSense bouncer |
| Source of truth | **NetBox** *(optional)* | Racks, IPs, VLANs, circuits — and generates Prometheus service-discovery targets so you stop hand-editing YAML |

### Why not Zabbix?

Zabbix is excellent for SNMP + IPMI and would cover your network gear and Dell iron beautifully. It's weaker on containerized apps, per-request app metrics, and ad-hoc log exploration. Given you have Node/Python/PHP apps and multiple databases, Prometheus + Loki wins overall. **LibreNMS** fills the "nice SNMP device UI" gap at a fraction of Zabbix's operational weight.

---

## 3. Where it runs

Run the stack on a **separate physical box** (a mini-PC or the least-loaded R720), *not* as a VM on the Proxmox cluster it watches. If the cluster goes down, monitoring must survive to tell you why.

**Sizing to start:** 4–8 vCPU · 16 GB RAM · 500 GB SSD.
At ~100 targets / ~300k active series, Prometheus uses ~6 GB RAM. Loki ingest will be roughly 5–20 GB/day.

**Network:** dedicated monitoring VLAN with pfSense rules allowing it into the management VLAN (iDRAC, switch mgmt, NVR). Nothing needs to reach *into* the monitoring VLAN except your browser.

**Deployment:** Docker Compose (or Podman) with all state on a dedicated volume that has its own backup job. Host agents (`node_exporter` etc.) rolled out via a small Ansible playbook.

### The deadman's switch

Alertmanager fires a permanent `Watchdog` alert every 30s. Something outside the building must notice when it stops:

- a $5 VPS running a 30-line receiver, **or**
- self-hosted Healthchecks.io on that VPS, **or**
- an out-of-band 4G/LTE router with an SMS script.

Without this, a total DC outage produces **zero alerts** — the monitoring died with everything else.

---

## 4. Retention

| Data | Hot | Warm | Notes |
|---|---|---|---|
| Metrics | Prometheus, 30 d | VictoriaMetrics, 18 mo | Enough history for capacity planning + YoY comparison |
| Logs | Loki, 30 d | MinIO (S3-compatible), 12 mo | Bump to 12 mo hot for anything under a compliance obligation |
| Flow data | ntopng, 7–30 d | — | Volume-heavy; keep aggregates only |
| Device configs | Oxidized/Git | forever | Tiny, priceless during an outage |

---

## 5. Port map

| Port | Service | | Port | Service |
|---|---|---|---|---|
| 3000 | Grafana | | 9104 | mysqld_exporter |
| 3001 | Uptime Kuma | | 9113 | nginx_exporter |
| 3002 | ntopng | | 9117 | apache_exporter |
| 3100 | Loki | | 9121 | redis_exporter |
| 8000 | LibreNMS | | 9187 | postgres_exporter |
| 8428 | VictoriaMetrics | | 9199 | nut_exporter (UPS) |
| 9090 | Prometheus | | 9221 | pve_exporter |
| 9093 | Alertmanager | | 9253 | php-fpm_exporter |
| 9090 | Prometheus | | 9256 | process_exporter |
| 9100 | node_exporter | | 9290 | ipmi_exporter |
| 9115 | blackbox_exporter | | 9633 | smartctl_exporter |
| 9116 | snmp_exporter | | 514 | syslog ingest (Alloy) |
| 12345 | Grafana Alloy | | 162 | SNMP traps (snmptrapd) |

---

## 6. Phased rollout

Each phase delivers standalone value. Stop at any point and you still have a working system.

### Phase 0 — Foundation (day 1)
Monitoring host + Docker + Prometheus + Grafana + Alertmanager + Blackbox + Uptime Kuma.
**You immediately get:** every website up/down, SSL expiry countdown, WAN reachability, phone alerts.
*This is 80% of the pain for 5% of the work — do it first.*

### Phase 1 — Compute (week 1)
`node_exporter` on all Proxmox hosts and every VM (Ansible), `pve_exporter`, `smartctl_exporter`, `process_exporter`.
**You get:** CPU/RAM/disk/network per host and per VM, CPU **steal time** (your overcommit alarm), disk-failure prediction, per-process resource tracking for pm2/php-fpm/mysqld.

### Phase 2 — Infrastructure (week 2)
`snmp_exporter` for pfSense + Cisco + HP, `ipmi_exporter` for iDRAC on all three Dells, custom ISAPI exporter for the HikVision NVR. Optionally stand up LibreNMS alongside.
**You get:** per-port bandwidth and errors, pf state-table usage, PSU/fan/temp/RAID health, camera online/offline, NVR disk health.

### Phase 3 — Logs (week 3)
Loki + Alloy on every host; syslog receiver for pfSense/switches/NVR/iDRAC; `snmptrapd` for hardware traps.
**You get:** searchable everything, plus log-derived alerts (OOM killer, filesystem remounted read-only, RAID degraded, SSH brute force, kernel MCE).

### Phase 4 — Services (week 4)
`mysqld_exporter`, `postgres_exporter`, `redis_exporter`, `php-fpm_exporter`, nginx/apache exporters, pm2 textfile collector, Python `prometheus_client` instrumentation, WHM/Plesk exporter.
**You get:** replication lag, connection saturation, slow queries, cache hit ratios, per-app request rate / error rate / latency.

### Phase 5 — Physical & operational (week 5–6)
NUT for UPS, environmental sensors, PDU via SNMP, ntopng NetFlow, Oxidized config backup, backup-job monitoring.
**You get:** power and cooling visibility, "who is eating the bandwidth", config diffs, and confidence your backups actually ran.

### Phase 6 — Maturity (ongoing)
Wazuh + CrowdSec, NetBox as SD source, SLO definitions via Sloth, `predict_linear()` capacity dashboards, public status page, deploy annotations in Grafana.

---

## 7. The gaps worth closing first

Ranked by "how badly this bites you at 3 a.m." — details in [COVERAGE.md § 10](COVERAGE.md).

1. **UPS / power (NUT).** Not on your list at all. Without it you get no warning before an unclean shutdown of every Proxmox host, and no automated graceful shutdown on low battery. **Highest-value single addition.**
2. **Backup verification.** Alert when a backup is *missing*, not just failed. Track job success, duration, and output size per VM.
3. **Environmental.** Room temperature, humidity, and a water-leak sensor. A ~$60 sensor prevents a five-figure incident.
4. **Deadman's switch.** Covered in §3. Cheap, and the difference between "we knew at 02:14" and "a customer told us at 09:00".
5. **Internet line *quality*, not just up/down.** Smokeping-style latency/jitter/loss per WAN. This is your evidence when the ISP claims the line is fine.
6. **RBL / blacklist monitoring.** You run WHM — if your mail IP hits Spamhaus, you want to know in minutes, not from a customer.
7. **NetFlow.** SNMP tells you the pipe is full. NetFlow tells you *which host and which protocol*.
8. **Thin-pool / ZFS pool capacity.** An LVM-thin pool hitting 100% corrupts guest filesystems. Alert at 75%.

---

## 8. Alerting model

| Severity | Route | Examples |
|---|---|---|
| **P1 — page** | ntfy priority-max + Telegram + SMS | Site/DB down, host down, UPS on battery, room temp critical, RAID array failed |
| **P2 — notify** | Telegram + email | Disk >85%, replication lag >60s, cert <14 d, PSU redundancy lost, predictive drive failure |
| **P3 — digest** | Daily email | Pending updates, cert 14–30 d, capacity trends, config diffs |

**Rules that keep it survivable:**
- **Inhibition:** `host down` suppresses every service alert on that host. One page, not forty.
- **Grouping:** by `cluster` + `alertname`, 5 m group interval.
- **Absence detection:** `up == 0`, `absent(metric)`, `time() - backup_last_success > 26h`.
- **Every alert carries** `runbook_url`, `severity`, and `owner` annotations.
- **Maintenance windows** as scheduled Alertmanager silences, driven from your change calendar.

---

## 9. Repo layout

**Phase 0 is scaffolded and runnable.** Follow [GETTING-STARTED.md](GETTING-STARTED.md).

```
docker-compose.yml                  ✅ Prometheus, Grafana, Alertmanager,
                                       Blackbox, node_exporter, Uptime Kuma
.env.example                        ✅ copy to .env — Grafana password, timezone
prometheus/prometheus.yml           ✅ scrape config
prometheus/targets/websites.yml     ✅ edit this to add sites
prometheus/targets/servers.yml      ✅ edit this to add servers
prometheus/targets/ping.yml         ✅ edit this to add switches/NVR/iDRAC
prometheus/rules/alerts.yml         ✅ 17 starter alerts incl. Watchdog
alertmanager/alertmanager.yml       ✅ grouping, inhibition, Telegram ready
blackbox/blackbox.yml               ✅ http, icmp, tcp, smtp_starttls, dns
grafana/provisioning/               ✅ datasources auto-connected
```

Still to build, in rollout order:

```
ansible/                            ⬜ node_exporter + Alloy rollout (Phase 1)
snmp/                               ⬜ generated MIB config for pfSense/switches (Phase 2)
exporters/hikvision/                ⬜ custom ISAPI exporter for the NVR (Phase 2)
loki/ · alloy/                      ⬜ log pipeline, syslog + trap receivers (Phase 3)
exporters/whm/                      ⬜ custom WHM/cPanel exporter (Phase 4)
nut/                                ⬜ UPS monitoring + graceful shutdown (Phase 5)
```

### Starter alert rules included

Websites: down, slow, SSL <21 d, SSL <7 d · Reachability: device unreachable, internet packet loss · Servers: exporter down, disk 85%/95%, inodes, memory, CPU, **CPU steal**, reboot detection, clock drift, `predict_linear` disk-fill forecast · Plus the **Watchdog** deadman's-switch alert.
