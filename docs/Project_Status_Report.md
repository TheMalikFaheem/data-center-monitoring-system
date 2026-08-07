# Project Status Report — Centralized Monitoring Platform

| | |
|---|---|
| **Date** | 2026-08-07 |
| **Project** | Centralized Infrastructure Monitoring & Observability Platform |
| **Repository** | github.com/TheMalikFaheem/data-center-monitoring-system |
| **Central server** | `monitor01` — DigitalOcean, Ubuntu 24.04 LTS, 8 GB RAM, 107.170.11.210 |
| **Status** | Phase 1 (core framework) built, audited, and deployed to GitHub — server verification in progress |

---

## 1. Executive summary

The project is building one platform that monitors the entire on-prem data
center — Proxmox, Dell PowerEdge/iDRAC, pfSense, Cisco/HP switches,
databases, applications, websites, and logs — from a hardened cloud server.

A Docker-based proof of concept validated the technology stack (Prometheus,
Grafana, Loki, Alertmanager) and was then deliberately retired: its
networking and configuration problems showed the architecture would not
scale to real onboarding. The platform is being rebuilt as **native systemd
services deployed by a custom installer framework** (`monitorctl`), so the
entire monitoring stack can be reproduced on any fresh Ubuntu 24.04 server
from a git clone and a handful of commands.

As of this report the framework core is complete: a shared installer
library, installers for Prometheus and node_exporter, an operator CLI,
hardened service units, and an operator runbook — all version-pinned,
checksum-verified, health-gated, and able to roll themselves back on
failure. The code passed a 15-agent adversarial audit (10 verified defects
found and fixed before production use). The remaining Phase 1 work is the
verification run on `monitor01`.

## 2. Objective

- Central visibility: metrics, logs, dashboards, and alerts in one place.
- Proactive alerting (email/Telegram/Slack) before users notice failures.
- Reproducibility: the monitoring server itself must be rebuildable from
  version control in minutes, not from memory.
- A maintainable foundation that one person can operate and extend.

## 3. What has been done

### 3.1 Proof of concept (v1 — Docker, retired)

- Provisioned and hardened `monitor01` (updates, chrony, fail2ban, UFW, swap).
- Deployed Prometheus, Grafana, Loki, Alertmanager, Blackbox and SNMP
  exporters via Docker Compose; all containers ran successfully.
- Onboarding the first real target exposed structural problems: mixed
  container/host networking, Docker DNS resolution failures, and a Grafana
  config-mount restart loop.
- **Decision:** treat v1 as a successful experiment, remove Docker entirely,
  and rebuild natively. (~1.7 GB reclaimed; documented in
  `Monitoring_Platform_Architecture_Review_and_Rebuild_Proposal.docx`.)

### 3.2 Installer framework (v3 — current, built 2026-08-07)

Everything below is committed and pushed to the GitHub repository:

| Deliverable | Purpose |
|---|---|
| `monitorctl` | Operator CLI: `install`, `status`, `health`, `versions`, `update` |
| `configs/versions.yml` | Every component version pinned in ONE place |
| `configs/environment.yml` (+ gitignored `environment.local.yml`) | Tracked defaults + per-server overrides |
| `scripts/common.sh` | Shared library: preflight checks, SHA256-verified downloads, templating, systemd install, health gate, rollback stack |
| `scripts/install-prometheus.sh`, `scripts/install-node-exporter.sh` | First two installers; every future installer follows the same 9-step skeleton |
| `scripts/healthcheck.sh` | PASS/FAIL table per component (service active + HTTP health + version vs pin); cron/watchdog-ready exit codes |
| `services/*.tpl`, `templates/*.tpl` | Hardened systemd units and Prometheus config templates |
| `docs/runbook.md` | Operator manual, including a monitoring primer and the cutover procedure |
| `Project.md`, `README.md` | Project state, architecture, roadmap, decision log |

**Framework guarantees** (each verified in code review/audit):

- Downloads are verified against the project's published SHA256 checksums;
  a mismatch refuses to install.
- Installers are idempotent: re-run = health-checked no-op; changed pin =
  clean upgrade; interrupted install = repairable by re-running.
- Existing configuration files are never overwritten; user data (the
  metrics database) is never deleted, not even by rollback.
- Every service runs as its own unprivileged system user with systemd
  hardening, bound to `127.0.0.1` only — nothing is network-reachable
  until the reverse-proxy phase exposes it deliberately behind TLS.
- Failures roll back to the pre-run state and log every undo step to
  `/var/log/monitoring/install.log`.

### 3.3 Quality assurance (2026-08-07)

The first live run on `monitor01` hit one real bug (a SIGPIPE race that
made `monitorctl` reject its own valid component names). That prompted a
full adversarial audit before proceeding: 4 independent review passes
(shell strict-mode semantics, rollback simulation, systemd/Ubuntu runtime
behavior, CLI walkthrough), findings cross-checked by dedicated verifier
agents. **Result: 20 raw findings → 10 confirmed real → all 10 fixed**,
including:

- A rollback hole where a failed *upgrade* restored the old binary on disk
  while the new process kept running (disk/runtime version divergence).
- A corrupt binary (e.g. after power loss mid-install) permanently
  blocking re-installation.
- A bash 5.2 behavior (`patsub_replacement`) that would corrupt any
  config value containing `&`.
- The health checker reporting green for a component that isn't installed.
- `--reinstall` flags being silently dropped by the CLI.

All fixes are in commit `0412188` on `main`.

### 3.4 Server state right now

- `/opt/monitoring` on `monitor01` is a clone of the GitHub repository
  (the old hand-built directory is preserved as
  `/opt/monitoring.pre-framework.<date>`).
- Nothing is installed yet — the first install attempt hit the bug fixed
  above, before any system change was made.

## 4. What happens next

### 4.1 Immediate (Phase 1 completion — on monitor01)

1. `git pull --ff-only` in `/opt/monitoring` to receive the audit fixes.
2. Create `configs/environment.local.yml` (empty for now).
3. `./monitorctl install node_exporter`, then `./monitorctl install prometheus`.
4. Run the verification checklist (runbook §6): services active/enabled,
   `monitorctl health` all PASS, both scrape targets `up`, ports bound to
   loopback only, idempotent re-run, kill-and-autorestart test.
5. Firewall sanity: keep UFW default-deny + SSH; remove the Docker-era
   80/443 allows until nginx exists.
6. First look at live metrics through an SSH tunnel
   (`ssh -L 9090:127.0.0.1:9090 root@monitor01` → http://localhost:9090).

Phase 1 is declared **done** when that checklist passes; the old
`.pre-framework` backup directory can then be deleted.

### 4.2 Roadmap

| Phase | Contents | State |
|---|---|---|
| **P1 — Core** | Framework + Prometheus + node_exporter on monitor01 | **verification in progress** |
| P2 — Platform | Alertmanager, Loki, Grafana (apt, version-pinned), Alloy; alerting wired to email/Telegram | next — installers generated once P1 verifies |
| P3 — Exporters | blackbox (websites/SSL), snmp (switches, pfSense), process, mysqld, postgres, redis | |
| P4 — Operations | backup.sh / restore.sh / uninstall.sh | |
| P5 — Edge | nginx + certbot HTTPS as the single public entry; authenticated remote_write + Loki push so on-prem agents can reach the droplet; UFW 80/443 | |
| P6 — Watchdog | systemd timer → healthcheck.sh → Alertmanager (the monitor monitors itself) | |
| P7+ — Onboarding | Proxmox, pfSense, Cisco/HP, iDRAC, databases, applications, websites, dashboards, per-team alert routing | |

## 5. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Monitoring server itself fails | Phase 6 watchdog + external uptime check; whole platform rebuildable from git in minutes |
| Bad upgrade of a component | Versions pinned; upgrade path parks the old binary and rolls back on a failed health gate |
| Configuration drift on the server | Server pulls with `--ff-only` only; local state confined to gitignored files; `monitorctl versions` flags drift |
| Exposure of monitoring endpoints | Loopback-only binds now; TLS + auth via nginx before anything is exposed (P5) |
| Single person dependency | Runbook documents operation from primer level up; every install is one command |

## 6. Operating model (steady state)

```
edit on workstation → commit → push to GitHub
        ↓
on monitor01:  git pull --ff-only
        ↓
sudo ./monitorctl install <new component>     (or: monitorctl update)
        ↓
./monitorctl health   → all PASS
```

Upgrading any component = change one line in `configs/versions.yml`,
push, pull, `monitorctl update`.

---

*Historical documents from the Docker era are preserved in `docs/` for
reference. The operator manual is `docs/runbook.md`.*
