# Centralized Monitoring Platform — Project Journal

> Running log of decisions, architecture, implementation progress, rationale, and next steps.
> Companion document: [MONITORING-PROJECT-GUIDE.md](MONITORING-PROJECT-GUIDE.md) (concept explanations, cheat sheets, glossary).
> **Last updated:** 2026-08-04

---

## 1. Project Goal

Build a **centralized monitoring and observability platform** for a small on-premises data center. One central platform must eventually monitor:

### Networking & Hardware
- pfSense firewall — internet links, gateway status, NAT, bandwidth, VPN, firewall health, system health
- Cisco switches
- HP switches
- Other SNMP devices
- HikVision NVR
- Dell PowerEdge R710 / R720 servers
- Dell iDRAC (out-of-band hardware health)

### Virtualization
- Proxmox cluster, hosts, and VMs — VM/host resources, backups, snapshots, cluster health, storage, updates
- WHM / Plesk hosting panels

### Applications
- Node.js (PM2), Python, PHP
- Nginx, Apache

### Databases
- MySQL, PostgreSQL, Redis

### Websites & External Checks
- HTTP / HTTPS availability, SSL expiry, DNS, ping, TCP availability

### Logs (centralized)
- Linux system logs, application logs, database logs, Proxmox logs, pfSense logs, Nginx logs, SSH logs

---

## 2. Decision — Project Documentation (SRS + TRD)

Two documents were agreed to be produced for this project:

| Document | Stands for | Answers | Contents |
|---|---|---|---|
| **SRS** | System Requirements Specification | *What* must the system do? | Functional & non-functional requirements, scope, acceptance criteria |
| **TRD** | Technical Requirements Document | *How* will it be implemented? | Infrastructure, hardware, software, network, deployment, security, monitoring architecture |

**Decision:** create **both**. *(Status: not yet written — open item.)*

---

## 3. Platform Design

The chosen stack:

| Component | Role |
|---|---|
| Grafana | Dashboards & visualization |
| Prometheus | Metrics collection & storage |
| Loki | Centralized log storage |
| Alertmanager | Alert routing & notifications |
| Grafana Alloy | Log/metric shipping agent on monitored machines |
| Node Exporter | Linux host metrics |
| SNMP Exporter | Network device metrics |
| Blackbox Exporter | Website / SSL / ping / DNS probes |
| Database exporters | MySQL, PostgreSQL, Redis metrics |
| Nginx | Reverse proxy — the only publicly exposed service (HTTPS + auth) |

---

## 4. Decision — Cloud vs Local Monitoring Server

**Question:** should the monitoring server live in the cloud or on-prem?

**Decision: hybrid architecture.**
- DigitalOcean hosts the central monitoring platform.
- On-premises infrastructure connects to it **securely, preferably over a WireGuard VPN** — not over the open internet.

**Reasoning:**
- Centralized visibility across sites
- Off-site resilience — the monitor survives a data-center outage (and can report it)
- Easier remote access for the team
- Avoids exposing on-prem infrastructure directly to the internet

---

## 5. Server Provisioned

| Property | Value |
|---|---|
| Provider | DigitalOcean |
| OS | Ubuntu Server 24.04.4 LTS |
| RAM | 8 GB |
| Disk | 154 GB SSD |
| Hostname | `monitor01` |
| Deployment model | Docker |

---

## 6. Phase 1 — Ubuntu Preparation ✅ DONE

Completed:
- All packages updated
- Hostname set (`monitor01`)
- Chrony (time sync), Fail2Ban, UFW firewall
- System & monitoring utilities installed
- Directory structure created under `/opt/monitoring`:

```
/opt/monitoring/{alertmanager, alloy, backups, blackbox, compose, configs,
                 grafana, loki, nginx, node-exporter, prometheus, scripts,
                 snmp, snmp-exporter}
```

Also recommended (status to confirm): swap file, automatic security updates, further hardening.

---

## 7. Phase 2 — Docker Platform ✅ DONE

- Docker Engine + Docker Compose installed
- Docker daemon configured
- Docker network created: `monitoring`
- Persistent named volumes created: `grafana_data`, `prometheus_data`, `loki_data`, `alertmanager_data`

---

## 8. Phase 3 — Core Monitoring Stack ✅ DONE

Deployed via Docker Compose; all images pulled and all containers started successfully:

- Grafana
- Prometheus
- Loki
- Alertmanager
- Blackbox Exporter
- SNMP Exporter

---

## 9. Incident Log

### #1 — Docker Compose fails to start: `invalid boolean: true"`

- **Error:** `error while interpolating volumes.alertmanager_data.external: failed to cast to expected type: invalid boolean: true"`
- **Cause:** YAML syntax slip in `docker-compose.yml` — stray quote after a boolean (`external: true"`).
- **Fix:** corrected the file in vim; stack redeployed cleanly.
- **Lesson:** validate before deploying — `docker compose config -q` catches this class of error.

---

## 10. Current Architecture

```
Ubuntu 24.04 → Docker Engine → Docker Compose
                     │
   ┌───────┬─────────┼─────────┬────────────┬──────────────┐
 Grafana Prometheus Loki  Alertmanager  Blackbox Exp.  SNMP Exp.
```

**No monitored devices are connected yet** — the platform runs but collects (almost) nothing.

---

## 11. Status Board

### Completed ✅
- Ubuntu preparation & server hardening
- Docker Engine + Docker Compose
- `monitoring` Docker network
- Persistent volumes
- All six core monitoring containers running

### Pending ⏳
- Nginx reverse proxy + HTTPS
- WireGuard VPN to on-prem
- Grafana provisioning (datasources, dashboards)
- Alert rules + notification channels
- Grafana Alloy rollout (centralized logging)
- Node Exporter (starting with monitor01 itself)
- Onboarding: Proxmox, pfSense, Cisco, HP, Dell iDRAC, HikVision NVR
- Database exporters: MySQL, PostgreSQL, Redis
- Application monitoring: Node.js, Python, PHP
- Website + SSL monitoring
- Backup automation
- SRS + TRD documents

---

## 12. Key Concepts (one-liners)

- **Grafana** — displays dashboards only; holds no data.
- **Prometheus** — *pulls* (scrapes) metrics from exporters and stores them.
- **Loki** — stores logs shipped to it by agents.
- **Alertmanager** — routes, groups, and silences alerts fired by Prometheus.
- **Exporters** — small services that expose a system's stats in Prometheus format: node_exporter, snmp_exporter, blackbox_exporter, mysqld_exporter, postgres_exporter, redis_exporter.

*(Full from-zero explanations: see the [guide](MONITORING-PROJECT-GUIDE.md).)*

---

## 13. Agreed Production Improvements

Before calling the deployment production-grade:

- Internal-only Docker network; **only Nginx exposed publicly** (80/443)
- HTTPS everywhere
- Container health checks
- Resource limits per container
- Automatic Grafana provisioning (datasources/dashboards as files)
- Persistent, version-controlled configuration (Infrastructure as Code)
- Pinned image versions (no `:latest` in production)
- Backup strategy for configs + volumes

---

## 14. Progress Estimate

**~20–25% complete.** Foundation done. The bulk of remaining work is infrastructure integration, dashboards, alerting, and centralized logging.

---

## 15. Planned Order of Work

1. Secure Nginx reverse proxy + HTTPS
2. WireGuard VPN between on-prem and monitor01
3. Provision Grafana (datasources first)
4. **Monitor monitor01 itself** (node_exporter — known-good baseline)
5. Connect Proxmox
6. Connect pfSense
7. Connect Cisco & HP switches
8. Connect Dell iDRAC (+ HikVision NVR via SNMP/probes)
9. Database exporters (MySQL, PostgreSQL, Redis)
10. Application monitoring (Node.js/PM2, Python, PHP)
11. Centralized logging (Grafana Alloy → Loki)
12. Build dashboards
13. Configure alerting (Telegram / Email / Slack)
14. Backup & disaster recovery

---

## 16. Team Lead Summary

**Accomplished:**
- Built the foundation of a centralized monitoring platform on a hardened, production-ready Ubuntu server.
- Installed and configured Docker as the deployment platform.
- Deployed the complete core observability stack (Grafana, Prometheus, Loki, Alertmanager, Blackbox & SNMP exporters).
- Established the base architecture for onboarding all data-center infrastructure.

**Current blockers / open items:**
- No monitoring targets onboarded yet.
- Dashboards and alerting pending.
- Secure reverse proxy (HTTPS) and WireGuard VPN pending.
- SRS/TRD documentation pending.

**Overall status:** the monitoring platform foundation is **operational and ready for infrastructure integration**.
