# Centralized Data Center Monitoring — Project State

**Goal:** one platform that watches everything in the on-prem data center —
Proxmox hosts and VMs, Dell PowerEdge/iDRAC, pfSense, Cisco/HP switches,
MySQL/PostgreSQL/Redis, Node.js/Python/PHP apps, websites and SSL, plus
centralized logs — with dashboards and alerting.

**Central server:** `monitor01` — DigitalOcean droplet, Ubuntu 24.04 LTS,
8 GB RAM, 107.170.11.210. On-prem infrastructure will connect to it securely
(VPN/TLS) in later phases.

---

## How we got here (short version)

1. **v1 (Docker PoC)** — Prometheus, Grafana, Loki, Alertmanager and
   exporters ran in Docker Compose. It proved the stack works, but mixed
   container/host networking, Docker DNS quirks, and a Grafana config-mount
   restart loop showed the architecture wouldn't scale to real onboarding.
   The Docker-era documents in [docs/](docs/) are kept as historical record.
2. **v2 decision** — Docker was completely removed from monitor01. Everything
   is now installed natively and managed by systemd, deployed by this repo's
   installer framework instead of hand-typed commands.

## Architecture (v3 — native)

```
                 your workstation (SSH tunnel; later: HTTPS via nginx)
                          │
   ┌──────────────────────┴─ monitor01 (Ubuntu 24.04, systemd) ────────────┐
   │                                                                       │
   │  Grafana ──reads── Prometheus ──scrapes── node_exporter (this host)   │
   │  (P2)              │    │                 exporters on other hosts (P3+)
   │                    │    └──fires──▶ Alertmanager ──▶ email/Telegram (P2)
   │  Loki ◀──ships── Alloy (logs)  (P2)                                   │
   │                                                                       │
   │  everything binds 127.0.0.1 · nginx+HTTPS is the only future entry (P5)
   └───────────────────────────────────────────────────────────────────────┘
```

## The framework

Instead of installation commands, this repo *is* the deployment:

- `configs/versions.yml` — every component version, pinned in one place
- `configs/environment.yml` — tracked defaults; `environment.local.yml`
  (gitignored) holds per-server overrides
- `scripts/common.sh` — shared library: preflight checks, download +
  SHA256 verification, templating, systemd install, health gate, rollback
- `scripts/install-*.sh` — one installer per component, all following the
  same 9-step skeleton
- `monitorctl` — the operator CLI: `install`, `status`, `health`,
  `versions`, `update`
- `docs/runbook.md` — how to operate all of it, including a monitoring
  primer

Deploy loop: edit on the Mac → push to GitHub → `git pull --ff-only` on the
server → `sudo ./monitorctl install|update`.

## Roadmap

| Phase | Contents | Status |
|---|---|---|
| **P1 — Core** | framework, `monitorctl`, Prometheus + node_exporter installers, runbook | **built — awaiting verification on monitor01** |
| **P2 — Platform** | Alertmanager, Loki, Alloy, Grafana; alerting wired; host rules; Node Exporter Full dashboard | **built — deploy after P1 verification** |
| **P3 — Exporters** | blackbox (HTTP/TCP/ICMP), snmp, process, mysqld, postgres, redis | **built — deploy after P2 verification** |
| P4 — Operations | backup.sh, restore.sh, uninstall.sh | |
| P5 — Edge | nginx + certbot HTTPS; authenticated remote_write/Loki push for on-prem agents; UFW 80/443 | |
| P6 — Watchdog | systemd timer → healthcheck.sh → Alertmanager | |
| P7+ — Onboarding | Proxmox, pfSense, switches, iDRAC, databases, apps, websites, dashboards | |

## Decisions log

- **Native over Docker** — fewer moving parts, no container networking layer
  between Prometheus and what it monitors, systemd as the one supervisor.
- **Pull-based monitoring, loopback-only binds** — nothing is exposed until
  nginx terminates TLS with auth in front (P5); until then, SSH tunnels.
- **Flat YAML configs, no yq/python dependency** — parsed by ~15 lines of
  awk; the flatness is a documented contract in each file's header.
- **Installers are idempotent state machines** — install / healthy-no-op /
  upgrade, with checksum verification, health gates and honest rollback.
- **UFW is never touched by scripts** — a firewall enabled over SSH with the
  wrong rules is a permanent lockout; the runbook has the manual steps.
