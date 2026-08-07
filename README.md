# data-center-monitoring-system

Installer framework for a centralized monitoring platform (Prometheus,
Grafana, Loki, Alertmanager + exporters) as **native systemd services** on
Ubuntu 24.04 — no Docker. Clone it onto a fresh server, run one command per
component, and every install is version-pinned, checksum-verified,
health-checked, and rolls itself back on failure.

```bash
git clone https://github.com/TheMalikFaheem/data-center-monitoring-system.git /opt/monitoring
cd /opt/monitoring
sudo ./monitorctl install node_exporter
sudo ./monitorctl install prometheus
./monitorctl health
```

## Layout

| Path | Purpose |
|---|---|
| `monitorctl` | Operator CLI: `install` · `status` · `health` · `versions` · `update` |
| `configs/versions.yml` | Every component version, pinned in one place |
| `configs/environment.yml` | Tracked defaults; `environment.local.yml` (gitignored) overrides per server |
| `scripts/common.sh` | Shared library: preflight, download + SHA256 verify, templating, rollback, health gate |
| `scripts/install-*.sh` | One installer per component, all the same 9-step skeleton |
| `templates/` · `services/` | Config and systemd unit templates (`{{TOKEN}}` substitution) |
| `docs/runbook.md` | **Start here to operate it** — includes a monitoring primer |
| `Project.md` | Project state, architecture, roadmap, decision log |

## Principles

- Versions live only in `versions.yml`; `monitorctl update` reconciles drift.
- Existing configs are never overwritten; data is never deleted, not even by rollback.
- Everything binds `127.0.0.1` until the nginx+HTTPS phase exposes it deliberately.
- Failed installs roll back to a clean system and log every undo step to
  `/var/log/monitoring/install.log`.

Upgrading = change one version in `versions.yml`, push, `git pull --ff-only`
on the server, `sudo ./monitorctl update`.
