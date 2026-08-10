# process-exporter.yml — process-exporter group configuration.
#
# Rendered from templates/process-exporter.yml.tpl by install-process-exporter.sh.
# The installer NEVER overwrites this file once it exists.
#
# After editing, reload: systemctl reload process_exporter
#
# Groups define WHICH processes to track. Each group gets its own set of
# metrics (CPU, memory, file descriptors, threads, etc.).
# The "name" is used as the label value in Prometheus metrics.
#
# Matching strategies (can combine any):
#   cmdline: regex match on full command line (most flexible)
#   exe:     exact match on binary name (no path)
#   comm:    match on /proc/<pid>/comm (first 15 chars of binary name)
#   pid:     list of specific PIDs (fragile across restarts — avoid)
#
# See: https://github.com/ncabatoff/process-exporter#configuration

process_names:
  # ── Monitoring stack ──────────────────────────────────────────────────────
  - name: prometheus
    cmdline:
      - /usr/local/bin/prometheus

  - name: node_exporter
    cmdline:
      - /usr/local/bin/node_exporter

  - name: alertmanager
    cmdline:
      - /usr/local/bin/alertmanager

  - name: loki
    cmdline:
      - /usr/local/bin/loki

  - name: alloy
    exe:
      - alloy

  - name: grafana
    exe:
      - grafana-server

  # ── System services ───────────────────────────────────────────────────────
  - name: sshd
    exe:
      - sshd

  - name: nginx
    exe:
      - nginx

  - name: systemd
    exe:
      - systemd

  # ── Database engines ──────────────────────────────────────────────────────
  # Uncomment when these run on monitor01 (more likely in P7+ onboarding):
  # - name: mysql
  #   exe:
  #     - mysqld
  #
  # - name: postgres
  #   exe:
  #     - postgres
  #
  # - name: redis
  #   exe:
  #     - redis-server

  # ── Catch-all: anything not matched above ─────────────────────────────────
  # Shows as a single "other" group so unknown processes don't become noise.
  - name: "{{.Comm}}"
    cmdline:
      - .+
