# prometheus.yml — main Prometheus configuration.
#
# Rendered from templates/prometheus.yml.tpl by install-prometheus.sh.
# The installer NEVER overwrites this file once it exists: if a newer render
# differs, it is saved next to this file as prometheus.yml.new for review.
# After editing, validate and reload with:
#   promtool check config /etc/prometheus/prometheus.yml
#   systemctl reload prometheus

global:
  # How often Prometheus pulls ("scrapes") /metrics from every target.
  scrape_interval: {{SCRAPE_INTERVAL}}
  # How often alerting/recording rules are evaluated (rules arrive in Phase 2).
  evaluation_interval: {{SCRAPE_INTERVAL}}
  # Attached to every metric that leaves this server (remote write, federation).
  external_labels:
    monitor: {{HOSTNAME}}
    env: {{ENV_LABEL}}

# Alerting/recording rule files will be listed here in Phase 2.
rule_files: []

# Phase 2: uncomment once Alertmanager is installed.
# alerting:
#   alertmanagers:
#     - static_configs:
#         - targets: ["127.0.0.1:9093"]

scrape_configs:
  # Prometheus scrapes its own /metrics endpoint — the monitor monitors itself.
  - job_name: prometheus
    static_configs:
      - targets: ["127.0.0.1:9090"]

  # Host metrics for this server (CPU, RAM, disk, network) via node_exporter.
  # Remote hosts join this job later via configs/inventory.yml (Phase 3+).
  - job_name: node
    static_configs:
      - targets: ["127.0.0.1:9100"]
