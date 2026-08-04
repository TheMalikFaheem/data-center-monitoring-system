# Data Center Monitoring Platform — Complete Guide

> **Project:** Centralized Infrastructure Monitoring & Observability Platform
> **Server:** `monitor01` — DigitalOcean droplet, Ubuntu Server 24.04 LTS, 8 GB RAM, 154 GB SSD
> **Status:** Core platform deployed and running (~20–25% of total project)
> **Last updated:** 2026-08-04
> **Companion doc:** [PROJECT-JOURNAL.md](PROJECT-JOURNAL.md) — running log of decisions, incidents, and status

This document explains **everything done so far**, **what every tool is and why it exists**, **how the pieces fit together**, and **what comes next**. It assumes strong sysadmin knowledge but zero prior experience with monitoring/observability tools.

---

## Table of Contents

1. [The Big Picture — What Are We Building?](#1-the-big-picture--what-are-we-building)
2. [Core Concepts You Must Understand](#2-core-concepts-you-must-understand)
3. [Phase 1 — Server Preparation (DONE)](#3-phase-1--server-preparation-done)
4. [Phase 2 — Docker & Docker Compose (DONE)](#4-phase-2--docker--docker-compose-done)
5. [Phase 3 — The Monitoring Stack (DONE)](#5-phase-3--the-monitoring-stack-done)
6. [How the Pieces Fit Together](#6-how-the-pieces-fit-together)
7. [The Directory Structure Explained](#7-the-directory-structure-explained)
8. [What We Fixed Along the Way](#8-what-we-fixed-along-the-way)
9. [What Is NOT Done Yet](#9-what-is-not-done-yet)
10. [The Roadmap — Remaining Phases](#10-the-roadmap--remaining-phases)
11. [Daily Operations Cheat Sheet](#11-daily-operations-cheat-sheet)
12. [Report for the Team Lead](#12-report-for-the-team-lead)
13. [Important Warnings & Things to Know](#13-important-warnings--things-to-know)
14. [Glossary](#14-glossary)

---

## 1. The Big Picture — What Are We Building?

We are building **one central server that watches everything else** in the data center.

Right now, if a disk fills up on a Proxmox host, a switch port dies, an SSL certificate expires, or MySQL slows down — you find out when something breaks and a user complains. The goal of this project is to flip that:

- **See** the health of every server, VM, switch, firewall, database, and website on dashboards.
- **Get alerted** (Telegram/Email/Slack) *before* things break — e.g., "disk 85% full", "SSL expires in 7 days".
- **Search logs** from all machines in one place instead of SSH-ing into each box and grepping.

The industry word for all of this is **observability**. It has three pillars:

| Pillar | What it is | Example | Tool we use |
|---|---|---|---|
| **Metrics** | Numbers measured over time | CPU is at 73% at 14:05 | Prometheus |
| **Logs** | Text events from apps/OS | `sshd: Failed password for root from 1.2.3.4` | Loki |
| **Alerts** | Notifications when a rule fires | "RAM > 90% for 5 minutes → send Telegram" | Alertmanager |

**Grafana** sits on top of all three and draws the dashboards.

### The architecture in one picture

```
        YOUR DATA CENTER (on-premises)                  DIGITALOCEAN (cloud)
 ┌────────────────────────────────────────┐      ┌──────────────────────────────┐
 │  Proxmox hosts ──┐                     │      │        monitor01             │
 │  Linux VMs ──────┤                     │      │  ┌────────────────────────┐  │
 │  pfSense ────────┤  metrics & logs     │      │  │ Prometheus  (metrics)  │  │
 │  Cisco/HP ───────┼────────────────────────────┼─▶│ Loki        (logs)     │  │
 │  switches        │  flow over the      │      │  │ Alertmanager(alerts)   │  │
 │  Dell iDRAC ─────┤  network to the     │      │  │ Grafana     (dashboards)│ │
 │  MySQL/PgSQL ────┤  monitoring server  │      │  └────────────────────────┘  │
 │  Node.js apps ───┘                     │      │     you view dashboards      │
 └────────────────────────────────────────┘      │     in your browser here     │
                                                 └──────────────────────────────┘
```

**Key mental model:** the DigitalOcean server is the *control plane* — it collects, stores, and displays. The actual data originates from your on-prem infrastructure. Nothing is being monitored yet; we have only built the collector side.

### Why the monitor is in the cloud (hybrid architecture decision)

We deliberately chose a **hybrid** setup: the monitoring platform runs on DigitalOcean, and the on-prem infrastructure will connect to it **over a WireGuard VPN tunnel** rather than the open internet. The reasoning:

- **Off-site resilience** — if the data center loses power or internet, the monitor survives and can alert you that the site is down. An on-prem monitor dies with the outage it should be reporting.
- **No exposed infrastructure** — with WireGuard, no on-prem device ever needs a port opened to the internet; metrics and logs travel encrypted inside the tunnel.
- **Central visibility & remote access** — one place the whole team can reach from anywhere.

---

## 2. Core Concepts You Must Understand

These five concepts are the foundation. Everything else builds on them.

### 2.1 Metrics vs Logs (they are NOT the same)

- A **metric** is a number with a timestamp: `cpu_usage{host="web01"} = 73.2 @ 14:05:30`. Metrics are tiny, cheap to store for months, and perfect for graphs and alerts.
- A **log** is a line of text: `2026-08-04 14:05:31 nginx: 502 Bad Gateway /api/checkout`. Logs are bulky, but they tell you *why* something happened.

Typical workflow: a metric alert tells you *something is wrong* ("error rate spiked"), then you jump to logs to find out *what exactly*.

### 2.2 Prometheus PULLS — it does not receive

This surprises everyone coming from tools like Zabbix agents pushing data. Prometheus works the other way around:

1. Every monitored system runs a tiny web server (an **exporter**) that exposes current numbers at an HTTP URL, e.g. `http://server:9100/metrics`.
2. Prometheus visits ("**scrapes**") each of those URLs on a schedule (default every 15–60s).
3. It stores what it saw in its own time-series database on disk.

You can literally `curl http://any-exporter:port/metrics` and read the numbers as plain text. That's all an exporter is — a page of numbers refreshed on demand.

**Consequence:** to monitor a machine, you install an exporter on it (or near it), then add its address to Prometheus's config. Prometheus never installs anything remotely.

### 2.3 Exporters — the adapters of the ecosystem

An **exporter** translates "some system's internal state" into the metrics format Prometheus understands. There's an exporter for almost everything:

| Exporter | What it monitors | Runs where |
|---|---|---|
| **node_exporter** | Linux CPU, RAM, disk, network, load | On every Linux box |
| **snmp_exporter** | Switches, firewalls, printers — anything speaking SNMP | On the monitoring server (asks devices remotely) |
| **blackbox_exporter** | Websites, ping, DNS, SSL expiry — "does it respond from outside?" | On the monitoring server |
| **mysqld_exporter** | MySQL internals | Next to MySQL |
| **postgres_exporter** | PostgreSQL internals | Next to PostgreSQL |
| **redis_exporter** | Redis internals | Next to Redis |

Devices that can't run software (switches, iDRAC) are monitored *remotely*: the SNMP exporter on monitor01 queries them over SNMP and translates the answers for Prometheus.

### 2.4 Labels — how everything is organized

Every metric carries **labels** — key/value tags like `{instance="web01", job="linux", datacenter="dc1"}`. Labels are how you slice data in Grafana ("show CPU for *all* Proxmox hosts") and how you scope alerts ("only page for `env=production`"). You'll meet them constantly in PromQL (Prometheus's query language).

### 2.5 Grafana displays; it does not collect

Grafana is *only* a visualization layer. It holds zero data. When you look at a dashboard, Grafana queries Prometheus (metrics) or Loki (logs) live and draws the result. If Prometheus is empty, Grafana shows empty graphs — which is exactly our current state, because no infrastructure is connected yet.

---

## 3. Phase 1 — Server Preparation (DONE)

Before any monitoring software, the server itself was hardened like any production Linux box. This is standard sysadmin work you already know — listed here for the record:

| Item | What was done | Why |
|---|---|---|
| OS | Ubuntu Server 24.04.4 LTS + all security updates | LTS = 5 years of patches |
| Hostname | `monitor01` | Clear identity in logs/alerts |
| Firewall | UFW configured | Only necessary ports open |
| Fail2Ban | Installed | Auto-bans SSH brute-force IPs |
| Time sync | Chrony | **Critical for monitoring** — metrics/logs are timestamped; clock drift makes graphs and alert timing lie |
| Admin tools | htop, curl, vim, etc. | Day-to-day troubleshooting |

Nothing exotic here — but note the Chrony point: accurate time matters more on a monitoring server than almost anywhere else, because every data point it stores is timestamped.

---

## 4. Phase 2 — Docker & Docker Compose (DONE)

### What Docker is (from zero)

Docker runs applications in **containers** — isolated boxes that bundle an app with all its dependencies. Think of a container as "a lightweight VM without a kernel": it shares the host's kernel but has its own filesystem, network, and process space.

Why this matters for us: our stack is 6+ separate applications, each with different dependencies and versions. Without Docker you'd install and upgrade each one by hand on Ubuntu, and they could conflict. With Docker:

- Each service (Grafana, Prometheus, …) runs in its own container from an official pre-built **image**.
- Upgrading = pull a new image, restart the container. Rolling back = point at the old image.
- Wiping a container never touches its data, because data lives in **volumes** (see below).

### Key Docker concepts used in this project

| Concept | What it is | In our project |
|---|---|---|
| **Image** | Read-only template ("the installer") | `grafana/grafana:latest`, `prom/prometheus:latest`, etc. |
| **Container** | A running instance of an image | `grafana`, `prometheus`, `loki`, … |
| **Volume** | Persistent disk area that survives container deletion | Prometheus's metric database, Grafana's settings |
| **Network** | Private virtual LAN between containers | The `monitoring` network — containers reach each other by *name* (e.g. Grafana talks to `http://prometheus:9090`) |
| **Docker Compose** | One YAML file (`docker-compose.yml`) that describes the whole stack; `docker compose up -d` starts everything | `/opt/monitoring/compose/docker-compose.yml` |

### Why Compose specifically

`docker-compose.yml` is **infrastructure as code**: the entire platform — which services, which versions, which ports, which volumes — is described in one version-controllable file. Disaster recovery becomes: new server → install Docker → copy `/opt/monitoring` → `docker compose up -d`. Minutes, not days.

---

## 5. Phase 3 — The Monitoring Stack (DONE)

Six containers are now running. Here is each one explained properly:

### 5.1 Prometheus — the metrics engine (port 9090)

The heart of the platform. It:

- **Scrapes** exporters on a schedule and stores the numbers in its own time-series database (TSDB) on disk.
- Provides **PromQL**, a query language for those numbers (e.g. `avg(rate(node_cpu_seconds_total[5m]))`).
- **Evaluates alert rules** you define ("fire if disk > 85% for 10m") and hands fired alerts to Alertmanager.

Prometheus is *not* long-term archival storage by default — typical retention is 15–90 days, tunable. That's plenty for operations.

### 5.2 Grafana — the face of the platform (port 3000)

The web UI where humans look at everything. It connects to **datasources** (Prometheus, Loki) and renders **dashboards** — panels of graphs, gauges, and tables. It also handles users/teams/permissions, so your team can log in and view without touching the underlying systems. Default login is `admin`/`admin` (it forces a password change) — this is one reason we don't expose it publicly yet.

### 5.3 Loki — the log database (port 3100)

"Prometheus, but for logs." Loki receives log lines shipped from your machines, indexes them *by labels only* (host, app, level — not full text), which makes it far lighter than an ELK/Elasticsearch stack. You search logs through Grafana with **LogQL** (looks a lot like PromQL). Loki does nothing until log **shippers** (Grafana Alloy — Phase 8) are installed on the machines.

### 5.4 Alertmanager — the alert dispatcher (port 9093)

Prometheus decides *when* an alert fires; Alertmanager decides *what happens next*:

- **Routes** alerts to the right channel (Telegram, Email, Slack) based on labels/severity.
- **Groups** related alerts (30 VMs down on one host = 1 notification, not 30).
- **Silences** alerts during planned maintenance.
- **Deduplicates** so you're not spammed every evaluation cycle.

### 5.5 Blackbox Exporter — the outside-in prober (port 9115)

Everything else measures from *inside*. Blackbox checks from the *outside*, like a user would: "Does https://yoursite.com return 200? How fast? Is the SSL cert valid, and when does it expire? Does the host answer ping? Does DNS resolve?" Prometheus tells it which targets to probe; it reports back success/latency/cert-expiry as metrics.

### 5.6 SNMP Exporter — the network-device translator (port 9116)

Switches and firewalls can't run node_exporter, but they all speak **SNMP** — a decades-old protocol exposing device stats (port status, bandwidth, CPU, temperature). This exporter sits on monitor01, queries your Cisco/HP switches and pfSense over SNMP, and translates the answers into Prometheus metrics. Configuration is per-device-family (you'll generate config for your specific switch models in Phase 5).

### Verified working

The stack was brought up with `docker compose up -d` — all 6 images pulled and all 6 containers started successfully. Health should be confirmed with:

```bash
docker ps                                  # all containers "Up"
curl http://localhost:9090/-/healthy       # Prometheus  → "Prometheus Server is Healthy."
curl http://localhost:3100/ready           # Loki        → "ready"
curl http://localhost:9093/-/healthy       # Alertmanager → OK
```

---

## 6. How the Pieces Fit Together

The complete data flow, once everything is connected:

```
                        ┌─────────────────────────────────────────────┐
                        │              monitor01 (Docker)             │
                        │                                             │
 Linux servers ─ node_exporter ──┐                                    │
 Switches ── SNMP ── snmp_exporter ─┐                                 │
 Websites ◀── probes ── blackbox_exporter ─┤                          │
 Databases ─ mysqld/postgres/redis_exporter ┤                         │
                        │           ▼      (scrapes every 15-60s)     │
                        │      ┌──────────┐  alert rules  ┌──────────────┐
                        │      │PROMETHEUS│──────fire────▶│ ALERTMANAGER │──▶ Telegram
                        │      └────┬─────┘               └──────────────┘    Email
                        │           │ queries                          │      Slack
 App/OS logs ── Alloy ──────┐       ▼                                  │
                        │   ▼  ┌─────────┐                             │
                        │ ┌────┤ GRAFANA │ ◀── your browser (dashboards)
                        │ │LOKI└─────────┘                             │
                        │ └────┘  queries                              │
                        └─────────────────────────────────────────────┘
```

Read it as three flows:

1. **Metrics flow:** exporters expose numbers → Prometheus scrapes and stores them → Grafana graphs them.
2. **Alert flow:** Prometheus evaluates rules → fires alerts → Alertmanager routes them to Telegram/Email/Slack.
3. **Log flow:** Alloy (agent on each machine, not yet deployed) ships logs → Loki stores them → Grafana searches them.

---

## 7. The Directory Structure Explained

Everything lives under `/opt/monitoring` on the server:

```
/opt/monitoring
├── compose/        # docker-compose.yml — THE definition of the whole stack
├── prometheus/     # prometheus.yml (scrape config) + targets/ + alert rules
├── grafana/        # provisioning files: datasources & dashboards as code
├── loki/           # Loki config (retention, storage)
├── alertmanager/   # routing config: who gets which alert, on which channel
├── blackbox/       # probe modules (http_2xx, icmp, tcp, dns…)
├── snmp/           # SNMP module definitions per device family
├── alloy/          # (future) log/metric agent configs to roll out to machines
├── nginx/          # (future) reverse-proxy + TLS config
├── node-exporter/  # (future) node exporter bits for the monitoring host itself
├── configs/        # shared/misc configuration
├── scripts/        # helper scripts (backups, maintenance)
└── backups/        # backup destination for configs & data
```

**The rule:** configuration lives in these directories on the host and is *mounted into* the containers. The containers themselves are disposable; this directory tree (plus the Docker volumes with stored data) **is** the platform. Backing up `/opt/monitoring` + volumes = backing up everything.

Planned Prometheus layout (Phase 5) keeps targets modular so adding a device = editing one small file:

```
prometheus/
├── prometheus.yml          # main config
└── targets/
    ├── linux.yml           # every Linux server's node_exporter address
    ├── proxmox.yml
    ├── pfsense.yml
    ├── switches.yml
    ├── databases.yml
    ├── applications.yml
    └── websites.yml
```

---

## 8. What We Fixed Along the Way

Worth remembering because it's the most common class of Docker Compose failure:

**Error:** `error while interpolating volumes.alertmanager_data.external: failed to cast to expected type: invalid boolean: true"`

**Cause:** a YAML syntax slip in `docker-compose.yml` — a stray quote after a boolean (`external: true"` instead of `external: true`).

**Lesson:** Compose errors that mention "interpolating" or "cast to expected type" are almost always YAML syntax problems (stray quotes, wrong indentation, tabs instead of spaces), not Docker problems. Two useful checks:

```bash
docker compose config     # parses & validates the file, prints the resolved result
docker compose config -q  # quiet: exit code only — good for scripts
```

The file was corrected in vim and the stack started cleanly afterward.

---

## 9. What Is NOT Done Yet

**Crucial framing: the platform is running but is monitoring nothing.** Prometheus has (almost) no targets, Loki receives no logs, no dashboards exist, no alert rules exist, and no notification channels are wired up.

Not yet connected:

- **Servers:** Linux servers, Proxmox hosts, VMs, WHM/Plesk panels
- **Network:** pfSense firewall, Cisco switches, HP switches, HikVision NVR
- **Hardware:** Dell PowerEdge R710/R720 via iDRAC, RAID controllers, temperatures/fans/PSUs
- **Databases:** MySQL, PostgreSQL, Redis
- **Applications:** Node.js (PM2), Python, PHP, Nginx, Apache
- **External checks:** website availability, SSL expiry, DNS, internet connectivity
- **Logs:** no central log collection (Alloy not deployed anywhere)
- **Dashboards:** none provisioned
- **Alerting:** no rules, no Telegram/Email/Slack integration
- **Security:** services are not yet behind Nginx/HTTPS/auth — **do not expose ports 3000/9090/9093/3100 to the internet in this state** (see §13); WireGuard VPN to on-prem not yet set up
- **Documentation:** the agreed SRS (what the system must do) and TRD (how it's implemented) have not been written yet

---

## 10. The Roadmap — Remaining Phases

In deliberate order — each phase builds on the previous:

| Phase | What | Why this order |
|---|---|---|
| **4. Secure access** | Nginx reverse proxy, HTTPS (Let's Encrypt), auth; close all ports except 80/443; WireGuard VPN tunnel to on-prem | Lock the doors *before* the platform holds real infrastructure data |
| **5. Metrics collection** | node_exporter on monitor01 first → then Proxmox, pfSense, switches (SNMP), iDRAC, DB exporters | **Monitor the monitoring server first** — a known-good baseline makes every later problem easier to isolate |
| **6. Dashboards** | Infrastructure, network, database, application dashboards (provisioned from files, not clicked together) | Only useful once data exists |
| **7. Alerting** | Alert rules + Telegram/Email/Slack routing | Only meaningful once dashboards prove data is correct — alert on data you trust |
| **8. Central logging** | Grafana Alloy on all machines → Loki | Log correlation on top of a working metrics base |
| **9. Automation** | Auto-discovery, backup monitoring, SSL sweeps, capacity planning | Polish once fundamentals are solid |

**The single most important next step:** install node_exporter on monitor01 itself and build the first dashboard for it. Small, self-contained, and it proves the whole pipeline (exporter → Prometheus → Grafana) end to end before any external device is involved.

---

## 11. Daily Operations Cheat Sheet

All commands run on `monitor01`, from `/opt/monitoring/compose` (or add `-f /opt/monitoring/compose/docker-compose.yml`):

```bash
# ---- Status ----
docker ps                          # what's running (look at STATUS column)
docker compose ps                  # same, compose-scoped
docker stats --no-stream           # CPU/RAM per container

# ---- Logs (container logs, for troubleshooting the stack itself) ----
docker logs prometheus --tail=50
docker logs grafana --tail=50 -f   # -f = follow live

# ---- Start / Stop / Restart ----
docker compose up -d               # start everything (and apply compose changes)
docker compose restart grafana     # restart one service
docker compose down                # stop stack (volumes/data are KEPT)
# NEVER run: docker compose down -v   ← the -v DELETES volumes = all stored data

# ---- After editing a config file ----
docker compose config -q                       # validate compose YAML first
docker compose restart prometheus              # reload that service
# Prometheus also supports live reload without restart:
curl -X POST http://localhost:9090/-/reload

# ---- Health checks ----
curl http://localhost:9090/-/healthy           # Prometheus
curl http://localhost:3100/ready               # Loki
curl http://localhost:9093/-/healthy           # Alertmanager

# ---- Upgrading the stack ----
docker compose pull && docker compose up -d    # pull new images, recreate changed containers
```

---

## 12. Report for the Team Lead

Copy-paste ready:

---

**Progress Report — Centralized Monitoring Platform**

**Summary:** The central monitoring platform is deployed and operational. The foundation (hardened server, container runtime, and all six core monitoring services) is complete. No production infrastructure is connected yet — onboarding begins next.

**Completed:**

- **Phase 1 — Server preparation:** Dedicated DigitalOcean server (`monitor01`, Ubuntu 24.04 LTS) hardened: UFW firewall, Fail2Ban, Chrony time sync, security updates, admin tooling.
- **Phase 2 — Container platform:** Docker Engine + Docker Compose with a dedicated internal network, persistent volumes, and a structured config tree under `/opt/monitoring`. The whole stack is defined as code in one compose file → reproducible, easy to upgrade, back up, and recover.
- **Phase 3 — Core services deployed and running:**
  - Grafana (dashboards/visualization)
  - Prometheus (metrics collection & storage)
  - Loki (centralized log storage)
  - Alertmanager (alert routing/notifications)
  - Blackbox Exporter (website/SSL/ping/DNS checks)
  - SNMP Exporter (network device monitoring)

**Not yet done:** No servers, network devices, databases, or applications are connected yet; dashboards, alert rules, notification channels, and log collection are not configured; services are not yet behind HTTPS/auth.

**Next milestones (in order):**
1. Secure access — Nginx reverse proxy + HTTPS + authentication; only ports 80/443 public.
2. First metrics — node_exporter on the monitoring server itself as a known-good baseline, with first dashboard.
3. Infrastructure onboarding — Proxmox, pfSense, Cisco/HP switches, iDRAC, databases, applications, websites.
4. Dashboards → alerting (Telegram/Email/Slack) → centralized logging (Grafana Alloy).

**Estimated overall progress:** ~20–25%. The platform build is the smaller half of the project; the larger half is onboarding infrastructure and building dashboards, alerts, and operational workflows on top.

---

## 13. Important Warnings & Things to Know

1. **Security is the #1 open risk right now.** If the compose file publishes ports 3000/9090/9093/3100 on a public DigitalOcean IP, those UIs are reachable from the internet. Prometheus and Loki have **no authentication at all** by default. Until Phase 4 (Nginx + HTTPS + auth) is done, either keep UFW blocking those ports or access them only via SSH tunnel:
   `ssh -L 3000:localhost:3000 root@monitor01` → then open `http://localhost:3000` locally.

2. **Grafana ≠ monitoring.** Grafana only *displays*. If a graph is empty, the problem is almost always upstream (exporter down, Prometheus not scraping) — check Prometheus's **Status → Targets** page first.

3. **Prometheus pulls.** Nothing appears until an exporter exists *and* Prometheus is told to scrape it. Adding a machine is always: install/point an exporter → add target to Prometheus config → reload.

4. **`:latest` image tags are convenient but risky in production.** A future `docker compose pull` could jump a major version unexpectedly. Before calling this production, pin versions (e.g. `grafana/grafana:11.1.0`) so upgrades are deliberate.

5. **Never `docker compose down -v`.** The `-v` flag deletes volumes — i.e., all stored metrics, logs, and Grafana settings. Plain `down` is safe.

6. **The monitoring server needs monitoring too** — it's the first target in Phase 5. It should also eventually alert *externally* if it dies (a "dead man's switch"), since a dead monitor can't report its own death.

7. **Config as code, always.** Datasources, dashboards, and alerts will be provisioned from files under `/opt/monitoring`, not clicked together in UIs. That's what makes the platform reproducible and reviewable.

8. **Time sync matters.** If a monitored machine's clock drifts, its metrics/logs land at wrong timestamps and correlation breaks. Chrony/NTP on every monitored machine, not just monitor01.

---

## 14. Glossary

| Term | Meaning |
|---|---|
| **Observability** | The practice of understanding system state via metrics, logs, and traces |
| **Metric** | A numeric measurement with a timestamp and labels |
| **Time series** | One metric tracked over time (e.g. CPU of web01) |
| **TSDB** | Time-Series Database — Prometheus's storage engine |
| **Scrape** | Prometheus fetching `/metrics` from a target over HTTP |
| **Target** | An endpoint Prometheus scrapes (usually an exporter) |
| **Exporter** | Small service exposing a system's stats in Prometheus format |
| **PromQL / LogQL** | Query languages for Prometheus (metrics) / Loki (logs) |
| **Label** | Key/value tag on metrics & logs, used to filter/group (`host=web01`) |
| **Alert rule** | A PromQL condition that fires an alert when true for a set duration |
| **Silence** | Temporary mute of alerts (e.g. during maintenance) |
| **SNMP** | Simple Network Management Protocol — how switches/firewalls expose stats |
| **Blackbox monitoring** | Probing a service from outside, like a user (HTTP, ping, DNS) |
| **Whitebox monitoring** | Metrics from inside a system (node_exporter, DB exporters) |
| **Grafana Alloy** | Grafana's agent for shipping logs/metrics from machines (successor to Promtail) |
| **Reverse proxy** | Front server (Nginx) that terminates HTTPS/auth and forwards to internal services |
| **Provisioning (Grafana)** | Defining datasources/dashboards as files instead of via the UI |
| **Retention** | How long stored data is kept before deletion |
| **Container / Image / Volume** | Running app box / its template / its persistent data area |
| **Infrastructure as code** | Defining systems in version-controlled files (our compose + configs) |
| **Dead man's switch** | An "always-firing" heartbeat alert; if it stops arriving, the monitor itself is down |
