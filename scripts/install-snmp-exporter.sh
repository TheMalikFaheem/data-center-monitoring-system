#!/usr/bin/env bash
#
# install-snmp-exporter.sh — install or upgrade SNMP Exporter as a native
# systemd service for polling network devices (switches, routers, iDRAC, UPS).
#
# The official release tarball ships a pre-built snmp.yml containing 400+
# MIB definitions for common vendor equipment. This installer uses it as-is.
# To add custom MIBs, use the snmp_exporter generator tool (separate workflow
# documented in docs/runbook.md §12).
#
# After install, add your device IPs to the blackbox_snmp scrape job in
# /etc/prometheus/prometheus.yml. Each device is its own target with a
# `module` param that matches an snmp.yml auth/walk profile.
#
#   Version:   configs/versions.yml            (snmp_exporter)
#   Settings:  configs/environment(.local).yml (snmp_exporter_listen)
#
# Usage: sudo ./scripts/install-snmp-exporter.sh [--reinstall]

set -Eeuo pipefail
source "$(dirname "$(readlink -f "$0")")/common.sh"

COMPONENT="snmp_exporter"
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
LISTEN=$(get_env snmp_exporter_listen "127.0.0.1:9116")

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
BASE="https://github.com/prometheus/snmp_exporter/releases/download/v${TARGET}"
TARBALL=$(fetch_and_verify \
    "$BASE/snmp_exporter-${TARGET}.linux-amd64.tar.gz" \
    "$BASE/sha256sums.txt")

# --- 5. User and directories -----------------------------------------------
create_system_user "$COMPONENT"
create_dir /etc/snmp_exporter "root:snmp_exporter" 0750

# --- 6. Stop running service -----------------------------------------------
if systemctl is-active --quiet "$COMPONENT"; then
    systemctl stop "$COMPONENT"
    push_rollback "systemctl start $COMPONENT"
fi

# --- 7. Install binary and bundled snmp.yml --------------------------------
extract_tarball "$TARBALL" EXTRACTED
install_binary "$EXTRACTED/snmp_exporter" "snmp_exporter"

# The release tarball includes a pre-built snmp.yml with 400+ vendor MIBs.
# Copy it only on first install; never overwrite operator customizations.
SNMP_CONFIG="/etc/snmp_exporter/snmp.yml"
if [[ ! -f "$SNMP_CONFIG" ]]; then
    if [[ -f "$EXTRACTED/snmp.yml" ]]; then
        install -m 0640 -o root -g snmp_exporter "$EXTRACTED/snmp.yml" "$SNMP_CONFIG"
        push_rollback "rm -f $SNMP_CONFIG"
        log info "installed bundled snmp.yml → $SNMP_CONFIG"
    else
        log warn "snmp.yml not found in tarball — $SNMP_CONFIG must be created manually"
        log warn "See: https://github.com/prometheus/snmp_exporter/tree/main/generator"
    fi
else
    log info "snmp.yml already exists — not overwriting operator customizations"
fi

# --- 8. systemd unit, start, verify ----------------------------------------
install_unit "$COMPONENT" "$SERVICE_DIR/snmp-exporter.service.tpl" \
    "LISTEN=$LISTEN"
enable_start_service "$COMPONENT"
verify_service_health "$COMPONENT" "$TARGET"

# --- 9. Register Prometheus scrape job -------------------------------------
add_prometheus_scrape_job "snmp" <<'YAML'

  # ── SNMP device polling ───────────────────────────────────────────────────
  # Each target is a network device IP. The module param selects which
  # snmp.yml auth/walk profile to use (if_mib covers most switches/routers).
  # Common modules: if_mib, mikrotik, cisco, apc_ups, pdu_eaton, printer_mib
  #
  # scrape_interval is set to 60s (overrides the global 15s) because SNMP
  # walks are slow. scrape_timeout must be less than scrape_interval.
  - job_name: snmp
    scrape_interval: 60s
    scrape_timeout: 30s
    metrics_path: /snmp
    params:
      module: [if_mib]
      auth: [public_v2]
    static_configs:
      - targets: []   # add device IPs: "192.168.1.1", "10.0.0.254"
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: 127.0.0.1:9116
YAML

finish_install
log info "=== $COMPONENT $TARGET installed successfully ==="
log info "snmp.yml installed with default MIBs at /etc/snmp_exporter/snmp.yml"
log info "Edit /etc/prometheus/prometheus.yml → snmp.targets to add your device IPs"
log info "Supported modules: if_mib, cisco, mikrotik, apc_ups — see /etc/snmp_exporter/snmp.yml"
