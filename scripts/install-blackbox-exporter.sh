#!/usr/bin/env bash
#
# install-blackbox-exporter.sh — install or upgrade Blackbox Exporter as a
# native systemd service and register its scrape jobs with Prometheus.
#
# Blackbox exporter probes HTTP, HTTPS, TCP, ICMP, and DNS endpoints from
# Prometheus's perspective. After install, add target URLs to the scrape jobs
# in /etc/prometheus/prometheus.yml (see docs/runbook.md §12).
#
# ICMP probes require net_raw capability. This installer grants it to the
# binary via setcap so the service can run unprivileged.
#
#   Version:   configs/versions.yml            (blackbox_exporter)
#   Settings:  configs/environment(.local).yml (blackbox_exporter_listen)
#
# Usage: sudo ./scripts/install-blackbox-exporter.sh [--reinstall]

set -Eeuo pipefail
source "$(dirname "$(readlink -f "$0")")/common.sh"

COMPONENT="blackbox_exporter"
REINSTALL=0
if [[ "${1:-}" == "--reinstall" ]]; then
    REINSTALL=1
fi

setup_error_trap
log info "=== $COMPONENT installer starting ==="

# --- 1. Preflight ----------------------------------------------------------
require_root
require_ubuntu_2404
require_commands curl tar sha256sum
check_disk_space /var/lib 256
check_ufw

# --- 2. Resolve versions and settings --------------------------------------
TARGET=$(get_version "$COMPONENT")
CURRENT=$(installed_version "$COMPONENT")
LISTEN=$(get_env blackbox_exporter_listen "127.0.0.1:9115")

# --- 3. Decide what to do --------------------------------------------------
if [[ -n "$CURRENT" && $REINSTALL -eq 0 && "$CURRENT" != "$TARGET" ]]; then
    log info "upgrading $COMPONENT $CURRENT → $TARGET"
elif [[ -n "$CURRENT" && $REINSTALL -eq 0 ]]; then
    if systemctl is-enabled --quiet "$COMPONENT" 2>/dev/null \
       && systemctl is-active --quiet "$COMPONENT"; then
        log info "$COMPONENT $TARGET already installed — verifying health"
        verify_service_health "$COMPONENT" "$TARGET"
        log info "nothing to do"
        exit 0
    fi
    log warn "$COMPONENT $TARGET binary present but service not healthy — repairing"
else
    log info "installing $COMPONENT $TARGET"
fi

if [[ -z "$CURRENT" ]]; then
    check_port_free "${LISTEN##*:}"
fi

# --- 4. Download and verify ------------------------------------------------
BASE="https://github.com/prometheus/blackbox_exporter/releases/download/v${TARGET}"
TARBALL=$(fetch_and_verify \
    "$BASE/blackbox_exporter-${TARGET}.linux-amd64.tar.gz" \
    "$BASE/sha256sums.txt")

# --- 5. User and directories -----------------------------------------------
create_system_user "$COMPONENT"
create_dir /etc/blackbox_exporter "root:blackbox_exporter" 0750

# --- 6. Stop running service -----------------------------------------------
if systemctl is-active --quiet "$COMPONENT"; then
    systemctl stop "$COMPONENT"
    push_rollback "systemctl start $COMPONENT"
fi

# --- 7. Install binary -----------------------------------------------------
extract_tarball "$TARBALL" EXTRACTED
install_binary "$EXTRACTED/blackbox_exporter" "blackbox_exporter"

# Grant net_raw capability for ICMP probes — binary runs as non-root.
# setcap is idempotent: re-applying the same cap is a no-op.
if command -v setcap >/dev/null 2>&1; then
    setcap cap_net_raw+ep "$BIN_DIR/blackbox_exporter" \
        && log info "cap_net_raw granted to blackbox_exporter (ICMP probes enabled)" \
        || log warn "setcap failed — ICMP probes will not work; HTTP/TCP probes unaffected"
else
    log warn "setcap not found — install libcap2-bin if ICMP probes are needed"
fi

# --- 8. Configuration ------------------------------------------------------
CONFIG="/etc/blackbox_exporter/blackbox.yml"
TMP_CFG=$(mktemp)
# blackbox.yml.tpl has no {{TOKEN}} placeholders — it's config-only.
cp "$TEMPLATE_DIR/blackbox.yml.tpl" "$TMP_CFG"

if [[ ! -f "$CONFIG" ]]; then
    install -m 0640 -o root -g blackbox_exporter "$TMP_CFG" "$CONFIG"
    push_rollback "rm -f $CONFIG"
    log info "installed $CONFIG"
elif ! cmp -s "$TMP_CFG" "$CONFIG"; then
    install -m 0640 -o root -g blackbox_exporter "$TMP_CFG" "$CONFIG.new"
    log warn "existing blackbox.yml unchanged; fresh template saved as $CONFIG.new"
else
    log info "blackbox.yml unchanged"
fi
rm -f "$TMP_CFG"

# --- 9. systemd unit, start, verify ----------------------------------------
install_unit "$COMPONENT" "$SERVICE_DIR/blackbox-exporter.service.tpl" \
    "LISTEN=$LISTEN"
enable_start_service "$COMPONENT"
verify_service_health "$COMPONENT" "$TARGET"

# --- 10. Register Prometheus scrape jobs ------------------------------------
# Two jobs: HTTP probes and TCP probes. Start with example targets — edit
# /etc/prometheus/prometheus.yml to add your real URLs/hosts.
add_prometheus_scrape_job "blackbox_http" <<'YAML'

  # ── Blackbox HTTP probes ──────────────────────────────────────────────────
  # Edit the targets list to add the URLs you want to monitor.
  # Each target is probed every scrape_interval (15s by default).
  - job_name: blackbox_http
    metrics_path: /probe
    params:
      module: [http_2xx]
    static_configs:
      - targets:
          # Add your URLs here:
          - https://google.com    # example — replace or remove
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: 127.0.0.1:9115
YAML

add_prometheus_scrape_job "blackbox_tcp" <<'YAML'

  # ── Blackbox TCP probes ───────────────────────────────────────────────────
  # Add host:port pairs to probe TCP connectivity (database ports, SSH, etc.).
  - job_name: blackbox_tcp
    metrics_path: /probe
    params:
      module: [tcp_connect]
    static_configs:
      - targets: []   # add e.g. "db.example.com:3306" or "192.168.1.1:22"
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: 127.0.0.1:9115
YAML

add_prometheus_scrape_job "blackbox_icmp" <<'YAML'

  # ── Blackbox ICMP probes ─────────────────────────────────────────────────
  # Add IP addresses of hosts to ping. Requires cap_net_raw on the binary.
  - job_name: blackbox_icmp
    metrics_path: /probe
    params:
      module: [icmp]
    static_configs:
      - targets: []   # add e.g. "192.168.1.1" or "8.8.8.8"
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: 127.0.0.1:9115
YAML

finish_install
log info "=== $COMPONENT $TARGET installed successfully ==="
log info "Edit /etc/prometheus/prometheus.yml → blackbox_http.targets to add your URLs"
log info "Then: promtool check config /etc/prometheus/prometheus.yml && systemctl reload prometheus"
