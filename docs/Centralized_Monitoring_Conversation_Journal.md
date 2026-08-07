# Centralized Monitoring Platform - Conversation Log & Project Journal

> This document summarizes the complete technical discussion from this
> chat session, including decisions, architecture, implementation
> progress, rationale, and next steps.

------------------------------------------------------------------------

# 1. Initial Goal

The objective is to build a **centralized monitoring and observability
platform** for a small on-premises data center.

The platform should monitor:

## Networking & Hardware

-   pfSense Firewall
    -   Internet links
    -   Gateway status
    -   NAT
    -   Bandwidth
    -   VPN
    -   Firewall health
    -   System health
-   Cisco Switches
-   HP Switches
-   SNMP devices
-   HikVision NVR
-   Dell PowerEdge R710/R720 servers
-   Dell iDRAC

## Virtualization

-   Proxmox Cluster
-   Proxmox Hosts
-   Virtual Machines
-   VM resources
-   Host resources
-   Backups
-   Snapshots
-   Cluster health
-   Storage
-   Updates
-   WHM/Plesk

## Applications

-   NodeJS (PM2)
-   Python
-   PHP
-   Nginx
-   Apache

## Databases

-   MySQL
-   PostgreSQL
-   Redis

## Websites

-   HTTP
-   HTTPS
-   SSL Expiry
-   DNS
-   Ping
-   TCP availability

## Logs

-   Linux logs
-   Application logs
-   Database logs
-   Proxmox logs
-   pfSense logs
-   Nginx logs
-   SSH logs

------------------------------------------------------------------------

# 2. Discussion: SRS vs TRD

We discussed the documentation required before implementation.

## SRS

System Requirements Specification

Purpose:

-   What the system must do
-   Functional requirements
-   Non-functional requirements
-   Scope
-   Acceptance criteria

------------------------------------------------------------------------

## TRD

Technical Requirements Document

Purpose:

-   How the solution will be implemented
-   Infrastructure
-   Hardware
-   Software
-   Network
-   Deployment
-   Security
-   Monitoring architecture

Decision:

Both documents should be created for this project.

------------------------------------------------------------------------

# 3. Monitoring Platform Design

The proposed platform consists of:

-   Grafana
-   Prometheus
-   Loki
-   Alertmanager
-   Grafana Alloy
-   Node Exporter
-   SNMP Exporter
-   Blackbox Exporter
-   Database Exporters
-   Nginx Reverse Proxy

------------------------------------------------------------------------

# 4. Cloud vs Local Monitoring Discussion

Question:

Should the monitoring server be cloud-based?

Decision:

A hybrid architecture is preferred.

DigitalOcean hosts the central monitoring platform.

On-premises infrastructure connects securely (preferably through
WireGuard VPN).

Reasoning:

-   Centralized visibility
-   Off-site resilience
-   Easier remote access
-   Avoid exposing infrastructure directly to the Internet

------------------------------------------------------------------------

# 5. DigitalOcean Server

A new server was provisioned.

Server:

-   Ubuntu Server 24.04.4 LTS
-   8 GB RAM
-   154 GB SSD
-   Docker deployment model

Hostname changed to:

monitor01

------------------------------------------------------------------------

# 6. Phase 1 - Ubuntu Preparation

Completed:

-   Updated packages
-   Hostname configured
-   Chrony
-   Fail2Ban
-   UFW
-   System tools
-   Monitoring utilities
-   Directory structure

Created:

/opt/monitoring

with folders:

-   alertmanager
-   alloy
-   backups
-   blackbox
-   compose
-   configs
-   grafana
-   loki
-   nginx
-   node-exporter
-   prometheus
-   scripts
-   snmp
-   snmp-exporter

Recommendation also included:

-   Swap file
-   Automatic updates
-   Security hardening

------------------------------------------------------------------------

# 7. Phase 2 - Docker Platform

Installed:

-   Docker Engine
-   Docker Compose
-   Docker Network

Created:

Docker network:

monitoring

Docker volumes:

-   grafana_data
-   prometheus_data
-   loki_data
-   alertmanager_data

Configured Docker daemon.

------------------------------------------------------------------------

# 8. Phase 3 - Core Monitoring Stack

Docker Compose deployed:

-   Grafana
-   Prometheus
-   Loki
-   Alertmanager
-   Blackbox Exporter
-   SNMP Exporter

Images downloaded successfully.

Containers started successfully.

------------------------------------------------------------------------

# 9. First Docker Compose Issue

An error occurred:

invalid boolean: true"

Cause:

YAML formatting issue in docker-compose.yml.

Resolution:

The compose file was corrected and successfully redeployed.

------------------------------------------------------------------------

# 10. Current Architecture

Ubuntu → Docker → Docker Compose

Services:

-   Grafana
-   Prometheus
-   Loki
-   Alertmanager
-   Blackbox Exporter
-   SNMP Exporter

No monitored devices have been connected yet.

------------------------------------------------------------------------

# 11. Current Status

Completed

✓ Ubuntu preparation

✓ Server hardening

✓ Docker installation

✓ Docker Compose

✓ Monitoring network

✓ Persistent volumes

✓ Core monitoring containers

------------------------------------------------------------------------

Pending

-   Nginx Reverse Proxy
-   HTTPS
-   Grafana provisioning
-   Datasources
-   Dashboards
-   Alert Rules
-   Grafana Alloy
-   Node Exporter
-   Proxmox
-   pfSense
-   Cisco
-   HP
-   Dell iDRAC
-   MySQL
-   PostgreSQL
-   Redis
-   NodeJS
-   Python
-   PHP
-   Website Monitoring
-   SSL Monitoring
-   Centralized Logging
-   Backup automation

------------------------------------------------------------------------

# 12. Important Concepts Discussed

Grafana

Displays dashboards only.

Prometheus

Collects metrics from exporters.

Loki

Stores logs.

Alertmanager

Routes alerts.

Exporters

Expose metrics.

Examples:

-   Node Exporter
-   SNMP Exporter
-   Blackbox Exporter
-   mysqld_exporter
-   postgres_exporter
-   redis_exporter

------------------------------------------------------------------------

# 13. Suggested Production Improvements

Instead of a simple Docker Compose deployment:

Recommended production architecture:

-   Internal Docker network
-   Only Nginx exposed publicly
-   HTTPS
-   Health checks
-   Resource limits
-   Automatic Grafana provisioning
-   Persistent configuration
-   Version-controlled Docker Compose
-   Backup strategy
-   Infrastructure-as-Code approach

------------------------------------------------------------------------

# 14. Progress Estimate

Approximately 20--25%.

Foundation complete.

Most remaining work consists of integrating infrastructure, configuring
dashboards, alerting, and centralized logging.

------------------------------------------------------------------------

# 15. Next Planned Phases

1.  Secure Nginx reverse proxy
2.  HTTPS
3.  Provision Grafana
4.  Monitor monitor01 itself
5.  Connect Proxmox
6.  Connect pfSense
7.  Connect Cisco & HP
8.  Connect Dell iDRAC
9.  Configure database exporters
10. Configure application monitoring
11. Configure centralized logging
12. Build dashboards
13. Configure alerting
14. Backup and disaster recovery

------------------------------------------------------------------------

# 16. Team Lead Summary

Current accomplishment:

-   Built the foundation of a centralized monitoring platform.
-   Prepared a production-ready Ubuntu server.
-   Installed and configured Docker.
-   Deployed the core observability stack.
-   Established the base architecture for future onboarding of
    infrastructure.

Current blockers:

-   Monitoring targets have not yet been onboarded.
-   Dashboards and alerting are pending.
-   Secure reverse proxy and HTTPS are pending.

Overall status:

The monitoring platform foundation is operational and ready for
infrastructure integration.
