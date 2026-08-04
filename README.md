# Data Center Monitoring System

Centralized infrastructure monitoring & observability platform for a small on-premises data center, built on **Grafana, Prometheus, Loki, and Alertmanager**, deployed with Docker Compose on a DigitalOcean server (`monitor01`, Ubuntu 24.04 LTS).

On-prem infrastructure (Proxmox, pfSense, Cisco/HP switches, Dell iDRAC, databases, applications, websites) will connect to the central platform over a WireGuard VPN.

## Documentation

| Document | What it covers |
|---|---|
| [MONITORING-PROJECT-GUIDE.md](MONITORING-PROJECT-GUIDE.md) | Complete from-zero guide: core concepts (metrics vs logs, exporters, scraping), every component explained, architecture, directory structure, operations cheat sheet, warnings, glossary |
| [PROJECT-JOURNAL.md](PROJECT-JOURNAL.md) | Running project log: decisions (hybrid cloud architecture, SRS/TRD), completed phases, incident log, status board, roadmap, team-lead summary |

## Current Status

Core platform deployed and running (~20–25% of project): Grafana, Prometheus, Loki, Alertmanager, Blackbox Exporter, and SNMP Exporter are up in Docker on `monitor01`. No infrastructure targets onboarded yet — next milestones are the Nginx reverse proxy + HTTPS, the WireGuard tunnel, and monitoring the monitoring server itself with node_exporter.
