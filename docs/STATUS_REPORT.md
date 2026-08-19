# 📊 Project Status Report — Centralized Data Center Monitoring
**Date:** 2026-08-19  
**Project:** Centralized Infrastructure Monitoring & Observability Platform  
**Repository:** `github.com/TheMalikFaheem/data-center-monitoring-system`  
**Monitoring Server:** Local LAN server (Ubuntu 24.04 LTS) — IP set in `configs/environment.local.yml`  
**Latest Commit:** `main` branch

---

## 🔑 The One-Line Summary for Your Supervisor

> We built a complete, production-grade monitoring platform from scratch. The entire monitoring engine (10 components) is **deployed and verified live**. Alert rules, dashboards, and Telegram notifications are fully written. The platform is being migrated to a local LAN server. All that remains is assigning a static IP to the monitoring server, entering your device IPs into one file, and running one command.

---

## ✅ Phase 1 — What Has Been Done

### 1.1 — The Monitoring Engine (10 Components — All Verified)

```
COMPONENT            ACTIVE   HTTP     VERSION
prometheus           PASS     PASS     PASS (3.6.0)      ← metrics database
node_exporter        PASS     PASS     PASS (1.9.1)      ← monitors the server itself
alertmanager         PASS     PASS     PASS (0.28.1)     ← alert routing & dedup
loki                 PASS     PASS     PASS (3.5.5)      ← log aggregation
blackbox_exporter    PASS     PASS     PASS (0.27.0)     ← HTTP/SSL/TCP probes
snmp_exporter        PASS     PASS     PASS (0.29.0)     ← switches/pfSense/iDRAC
process_exporter     PASS     PASS     PASS (0.8.7)      ← per-process monitoring
mysqld_exporter      PASS     PASS     PASS (0.17.2)     ← MySQL deep metrics
postgres_exporter    PASS     PASS     PASS (0.18.0)     ← PostgreSQL deep metrics
redis_exporter       PASS     PASS     PASS (1.80.0)     ← Redis deep metrics
```

### 1.2 — The Installer Framework

| Feature | What it means |
|---|---|
| `monitorctl install <component>` | Installs any component in one command |
| `monitorctl health` | Shows PASS/FAIL for every component |
| `monitorctl update` | Upgrades components without downtime |
| `monitorctl backup` | Snapshots all config + data |
| SHA256 checksum verification | Every binary verified before install |
| Auto-rollback on failure | Failed install reverts itself |
| Idempotent installers | Safe to re-run at any time |

Rebuilt from a fresh Ubuntu 24.04 server in under 30 minutes with `git clone + sudo ./monitorctl install all`.

### 1.3 — Alert Rules (35+ rules across 4 files)

| Rule File | What It Alerts On |
|---|---|
| `host.rules.yml` | Server down, CPU > 80%, Memory > 85%, Disk < 15%, High network traffic |
| `ssl.rules.yml` | SSL cert expiring 30d/7d/expired, Website down, TCP port closed |
| `network.rules.yml` | SNMP device unreachable, Switch port down, Interface errors, iDRAC hardware faults |
| `database.rules.yml` | MySQL/PostgreSQL/Redis down, replication lag, slow queries, memory pressure |

### 1.4 — Telegram Alert Routing

- **Critical** (server down, hardware fault, DB down) → Telegram immediately, repeat every 1 hour
- **Warning** (CPU high, disk low, slow queries) → Telegram, repeat every 4 hours
- **SSL expiry** → Telegram once per day
- **Smart inhibition** — if a server is down, suppresses redundant child alerts

### 1.5 — Grafana Dashboards (9 dashboards, auto-downloaded on install)

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

### 1.6 — LAN Migration

- Platform is moving from a cloud server to a dedicated local LAN server
- **No code changes required** — only one IP value to set in `environment.local.yml`
- LAN deployment is simpler: no public HTTPS/nginx needed, direct scraping with no tunnels

### 1.7 — Security & Operations

| Feature | Status |
|---|---|
| `backup.sh / restore.sh` | ✅ Built |
| `agent-bootstrap.sh` — one-line onboard any Linux server | ✅ Built |
| `apply-inventory.sh` — bulk register all devices to Prometheus | ✅ Built |
| nginx + HTTPS (optional for LAN) | ✅ Built, only needed if team needs browser URL |
| Watchdog (monitor monitors itself) | ✅ Built, pending deploy |
| All services loopback-only (SSH tunnel access) | ✅ Confirmed |

---

## ⏳ Phase 2 — What Is Pending

### Immediate (before deploying to local server)

| Task | Time |
|---|---|
| Assign static LAN IP to monitoring server | 5 min (in pfSense DHCP reservation) |
| Set `monitor_server_ip` in `environment.local.yml` | 1 min |
| Clone repo + run `monitorctl install all` | 20–30 min |

### Configuration (fill in your real values)

| What | File | Time |
|---|---|---|
| Device IPs (Proxmox, pfSense, switches, iDRAC) | `configs/inventory.yml` | 15 min |
| Website URLs | `configs/inventory.yml` | 5 min |
| Database credentials | `configs/environment.local.yml` | 10 min |
| Telegram bot token + chat ID | `configs/environment.local.yml` | 10 min |
| Grafana admin password | `configs/environment.local.yml` | 2 min |

### On-prem actions (devices)

| Device | Action Needed |
|---|---|
| Each Linux/Proxmox server | Run `agent-bootstrap.sh` (one curl command) |
| pfSense | Enable SNMP: Services → SNMP → community = public |
| Each switch | `snmp-server community public RO` |
| Each iDRAC | iDRAC Settings → Connectivity → SNMP → enable |

---

## 📐 Architecture

```
YOUR LAN (same network as monitoring server)
──────────────────────────────────────────────────────────────────
Proxmox hosts          → node_exporter → Prometheus (scrapes directly)
Linux servers          → node_exporter → Prometheus
pfSense                → SNMP poll    → snmp_exporter → Prometheus
Switches               → SNMP poll    → snmp_exporter → Prometheus
Dell iDRAC             → SNMP poll    → snmp_exporter → Prometheus
MySQL/PostgreSQL/Redis → exporters    → Prometheus
Websites (HTTP probes) → blackbox_exporter → Prometheus

Prometheus → evaluates 35+ alert rules → Alertmanager → Telegram
Loki ← Alloy (log shipper on each server)
Grafana → 9 dashboards (access via SSH tunnel from your workstation)
```

---

## 📈 Overall Progress

| Area | Progress |
|---|---|
| Monitoring engine built | 100% |
| Alert rules written (35+) | 100% |
| Grafana dashboards (9) | 100% |
| Telegram alerts configured | 80% (needs bot token) |
| LAN server setup | 0% (pending static IP) |
| Grafana deployed | 0% (one command away) |
| On-prem devices onboarded | 0% (needs real IPs + agent installs) |
