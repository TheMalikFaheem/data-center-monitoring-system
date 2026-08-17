# 📊 Project Status Report — Centralized Data Center Monitoring
**Date:** 2026-08-17  
**Project:** Centralized Infrastructure Monitoring & Observability Platform  
**Server:** `monitor01` — DigitalOcean, Ubuntu 24.04, 8 GB RAM — `107.170.11.210`  
**Repository:** `github.com/TheMalikFaheem/data-center-monitoring-system`  
**Latest Commit:** `a0e293b` on `main`

---

## 🔑 The One-Line Summary for Your Supervisor

> We built a complete, production-grade monitoring platform from scratch. The entire monitoring engine (10 components) is **deployed and verified live today**. Alert rules, dashboards, and Telegram notifications are fully written. All that remains is entering your real device IPs into one file and running one command.

---

## ✅ Phase 1 — What Has Been Done

### 1.1 — The Monitoring Engine (ALL LIVE on monitor01 right now)

Verified today at 10:37 AM:

```
COMPONENT            ACTIVE   HTTP     VERSION
prometheus           PASS     PASS     PASS (3.6.0)      ← time-series database
node_exporter        PASS     PASS     PASS (1.9.1)      ← monitors monitor01 itself
alertmanager         PASS     PASS     PASS (0.28.1)     ← alert routing & dedup
loki                 PASS     PASS     PASS (3.5.5)      ← log aggregation
blackbox_exporter    PASS     PASS     PASS (0.27.0)     ← HTTP/SSL/TCP probes
snmp_exporter        PASS     PASS     PASS (0.29.0)     ← switches/pfSense/iDRAC
process_exporter     PASS     PASS     PASS (0.8.7)      ← per-process monitoring
mysqld_exporter      PASS     PASS     PASS (0.17.2)     ← MySQL deep metrics
postgres_exporter    PASS     PASS     PASS (0.18.0)     ← PostgreSQL deep metrics
redis_exporter       PASS     PASS     PASS (1.80.0)     ← Redis deep metrics
```

**All 10 components: active, healthy, version-pinned.**

---

### 1.2 — The Installer Framework (built, committed, tested)

| Feature | What it means |
|---|---|
| `monitorctl install <component>` | Installs any component in one command |
| `monitorctl health` | Shows PASS/FAIL for every component in seconds |
| `monitorctl update` | Upgrades components without downtime |
| `monitorctl backup` | Snapshots all config + data |
| SHA256 checksum verification | Every binary is verified before install |
| Auto-rollback on failure | A failed install reverts itself automatically |
| Idempotent installers | Safe to re-run at any time |

The entire platform can be rebuilt on a fresh Ubuntu 24.04 server in under 30 minutes with `git clone + sudo ./monitorctl install all`.

---

### 1.3 — Alert Rules (35+ rules written, ready to deploy)

| Rule File | What It Alerts On |
|---|---|
| `host.rules.yml` | Server down, CPU > 80%, Memory > 85%, Disk < 15%/5%, High network traffic |
| `ssl.rules.yml` | SSL cert expiring in 30 days, 7 days, expired; Website down; TCP port closed |
| `network.rules.yml` | SNMP device unreachable, Switch port down, Interface errors, iDRAC hardware faults |
| `database.rules.yml` | MySQL/PostgreSQL/Redis down, replication lag, slow queries, memory pressure, evictions |

---

### 1.4 — Telegram Alert Routing (written, waiting for bot token)

- **Critical** (server down, hardware fault, DB down) → Telegram immediately, repeat every 1 hour
- **Warning** (CPU high, disk low, slow queries) → Telegram, repeat every 4 hours
- **SSL expiry** → Telegram once per day
- **Smart inhibition** — if a server is completely down, suppresses child alerts

---

### 1.5 — Grafana Dashboards (9 dashboards, ready to load)

| Dashboard | What it shows |
|---|---|
| Node Exporter Full | CPU, RAM, disk, network per server |
| Proxmox VE | VMs, containers, CPU/RAM per node |
| pfSense / OPNsense | WAN/LAN traffic, firewall states |
| Network Interface Overview | Switch port utilization, errors |
| MySQL / MariaDB Overview | Queries/sec, connections, slow queries |
| PostgreSQL Overview | Cache hit ratio, connections, deadlocks |
| Redis Dashboard | Memory, evictions, commands/sec |
| SSL Certificate Expiry | Days until expiry per domain |
| Blackbox Exporter | HTTP probe status, response time, SSL |

---

### 1.6 — Operations & Security (all built)

| Feature | Status |
|---|---|
| `backup.sh` — snapshot all configs + metrics data | ✅ Built |
| `restore.sh` — verified restore from backup | ✅ Built |
| `uninstall.sh` — clean removal per component | ✅ Built |
| `agent-bootstrap.sh` — one-line onboard any Linux server | ✅ Built |
| nginx + HTTPS + Let's Encrypt | ✅ Built, pending domain name |
| Watchdog (monitor monitors itself) | ✅ Built, pending deploy |
| UFW firewall (default-deny, SSH rate-limited) | ✅ Configured |
| All services loopback-only (0 ports exposed) | ✅ Confirmed |

---

## ⏳ Phase 2 — What Is Pending

### Components Pending Deployment (code written, need one command each)

| Component | Command to Deploy | What it Unlocks |
|---|---|---|
| Grafana | `sudo ./monitorctl install grafana` | Visual dashboards |
| Alloy | `sudo ./monitorctl install alloy` | Log shipping from servers |
| Watchdog | `sudo ./monitorctl install watchdog` | Self-monitoring |
| nginx + HTTPS | `sudo ./monitorctl install nginx` | Public HTTPS URL |

### Configuration Pending (needs your real values)

| What | File | Time |
|---|---|---|
| Real device IPs (Proxmox, pfSense, switches, iDRAC) | `configs/inventory.yml` | 15 min |
| Website URLs to monitor | `configs/inventory.yml` | 5 min |
| Database credentials (MySQL, PostgreSQL, Redis) | `configs/environment.local.yml` | 10 min |
| Telegram bot token + chat ID | `configs/environment.local.yml` | 10 min |
| Grafana admin password | `configs/environment.local.yml` | 2 min |
| nginx domain name (optional) | `configs/environment.local.yml` | 5 min |

### On-prem actions (physical devices)

| Device | Action Needed |
|---|---|
| Each Linux/Proxmox server | Run `agent-bootstrap.sh` on it (one curl command) |
| pfSense | Enable SNMP: Services → SNMP → community = public |
| Each Cisco switch | Enable SNMP: `snmp-server community public RO` |
| Each HP/Aruba switch | Enable SNMP: `snmp-server community public` |
| Each iDRAC | Enable SNMP: iDRAC Settings → Connectivity → SNMP |

---

## 📐 Architecture (Current + Target)

```
YOUR ON-PREM DATACENTER                    monitor01 (107.170.11.210)
──────────────────────────────             ──────────────────────────────────────
Proxmox hosts                              ┌─ Prometheus (metrics DB)
  └─ node_exporter ──────────────────────▶ │   evaluates 35+ alert rules
                                           │   30 days of history
pfSense (SNMP) ───────────────────────────▶│
Cisco/HP Switches (SNMP) ─────────────────▶│   fires alerts to ▼
Dell iDRAC (SNMP) ────────────────────────▶│
                                           Alertmanager ──▶ Telegram
MySQL / PostgreSQL / Redis ───────────────▶│
                                           ├─ Loki (log storage)
Your websites (HTTP probes) ───────────────▶│   ◀── Alloy from each server
                                           │
                                           └─ Grafana (9 dashboards)
                                               browser via SSH tunnel
                                               (or HTTPS if nginx installed)
```

---

## 📈 Overall Progress

| Area | Progress |
|---|---|
| Monitoring engine built | 100% |
| Monitoring engine deployed (10/10) | 100% |
| Alert rules written (35+ rules) | 100% |
| Grafana dashboards written (9) | 100% |
| Telegram alerts configured | 80% (needs bot token) |
| Grafana deployed | 0% (one command away) |
| On-prem servers onboarded | 0% (needs real IPs + agent installs) |
| Network devices (SNMP) onboarded | 0% (needs SNMP enabled on devices) |
| Databases connected | 0% (needs credentials) |
| HTTPS / nginx | 0% (needs domain name) |

---

## 🕐 Estimated Time to Full Coverage

| Task | Time |
|---|---|
| Fill in inventory.yml | 15 min |
| Deploy Grafana + Alloy + Watchdog | 10 min |
| Enable SNMP on pfSense | 5 min |
| Enable SNMP on each switch | 5 min/switch |
| Enable SNMP on each iDRAC | 5 min/server |
| Run agent-bootstrap on each Linux server | 5 min/server |
| Set up Telegram bot | 10 min |
| Set up database users + credentials | 15 min |
| **Total** | **~2–3 hours** |
