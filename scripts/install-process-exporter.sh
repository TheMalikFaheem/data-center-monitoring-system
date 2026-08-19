#!/usr/bin/env bash
#
# install-process-exporter.sh — install or upgrade process-exporter as a
# native systemd service.
#
# process-exporter exposes per-process-group metrics (CPU, memory, file
# descriptors, threads, open sockets) grouped by patterns defined in
# /etc/process_exporter/process-exporter.yml.
#
# NOTE: The upstream binary is named 'process-exporter' (with a dash) but the
# framework uses underscores as the component name (process_exporter). This
# installer renames the binary to process_exporter on install so that
# installed_version(), healthcheck.sh, and monitorctl versions all work.
#
# The service runs as root (required to read /proc for all users' processes).
# NoNewPrivileges prevents escalation.
#
#   Version:   configs/versions.yml            (process_exporter)
#   Settings:  configs/environment(.local).yml (process_exporter_listen)
#
# Usage: sudo ./scripts/install-process-exporter.sh [--reinstall]

set -Eeuo pipefail
source "$(dirname "$(readlink -f "$0")")/common.sh"

COMPONENT="process_exporter"
REINSTALL=0
if [[ "${1:-}" == "--reinstall" ]]; then
    REINSTALL=1
fi

setup_error_trap
log info "=== $COMPONENT installer starting ==="

# --- 1. Preflight ----------------------------------------------------------
require_root
require_supported_os
require_commands curl tar sha256sum
check_disk_space /var/lib 256
check_firewall

# --- 2. Resolve versions and settings --------------------------------------
TARGET=$(get_version "$COMPONENT")
CURRENT=$(installed_version "$COMPONENT")
LISTEN=$(get_env process_exporter_listen "127.0.0.1:9256")

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
# process-exporter tarball naming: hyphens throughout (not underscores).
# Confirmed filename: process-exporter-0.8.7.linux-amd64.tar.gz
# Checksum file:      checksums.txt (multi-hash, standard sha256sum format)
BASE="https://github.com/ncabatoff/process-exporter/releases/download/v${TARGET}"
TARBALL=$(fetch_and_verify \
    "$BASE/process-exporter-${TARGET}.linux-amd64.tar.gz" \
    "$BASE/checksums.txt")

# --- 5. Directories (no dedicated system user — service runs as root) -------
create_dir /etc/process_exporter "root:root" 0750

# --- 6. Stop running service -----------------------------------------------
if systemctl is-active --quiet "$COMPONENT"; then
    systemctl stop "$COMPONENT"
    push_rollback "systemctl start $COMPONENT"
fi

# --- 7. Install binary (renamed: process-exporter → process_exporter) ------
extract_tarball "$TARBALL" EXTRACTED

# The binary inside the tarball is 'process-exporter'; install it as
# 'process_exporter' (underscore) so installed_version() finds it at the
# expected path /usr/local/bin/process_exporter.
# Tarball layout: process-exporter-0.8.7.linux-amd64/process-exporter
EXPORTER_BIN="$EXTRACTED/process-exporter-${TARGET}.linux-amd64/process-exporter"
if [[ ! -f "$EXPORTER_BIN" ]]; then
    # Fallback: search anywhere in the extracted tree.
    EXPORTER_BIN=$(find "$EXTRACTED" -name "process-exporter" -type f -print -quit)
    [[ -n "$EXPORTER_BIN" ]] || die "could not find process-exporter binary in tarball"
fi
install_binary "$EXPORTER_BIN" "process_exporter"

# --- 8. Configuration ------------------------------------------------------
CONFIG="/etc/process_exporter/process-exporter.yml"
TMP_CFG=$(mktemp)
# process-exporter.yml.tpl uses {{.Comm}} Go template syntax internally
# (for the catch-all group) — this is NOT a framework {{TOKEN}}.
# We copy verbatim; no render_template needed.
cp "$TEMPLATE_DIR/process-exporter.yml.tpl" "$TMP_CFG"

if [[ ! -f "$CONFIG" ]]; then
    install -m 0640 -o root -g root "$TMP_CFG" "$CONFIG"
    push_rollback "rm -f $CONFIG"
    log info "installed $CONFIG"
elif ! cmp -s "$TMP_CFG" "$CONFIG"; then
    install -m 0640 -o root -g root "$TMP_CFG" "$CONFIG.new"
    log warn "existing process-exporter.yml unchanged; updated template saved as $CONFIG.new"
else
    log info "process-exporter.yml unchanged"
fi
rm -f "$TMP_CFG"

# --- 9. systemd unit, start, verify ----------------------------------------
install_unit "$COMPONENT" "$SERVICE_DIR/process-exporter.service.tpl" \
    "LISTEN=$LISTEN"
enable_start_service "$COMPONENT"
verify_service_health "$COMPONENT" "$TARGET"

# --- 10. Register Prometheus scrape job ------------------------------------
add_prometheus_scrape_job "process" <<'YAML'

  # ── Process group metrics ─────────────────────────────────────────────────
  # process-exporter groups processes by patterns in process-exporter.yml
  # and exposes per-group CPU, memory, fd, thread, and socket metrics.
  - job_name: process
    static_configs:
      - targets: ['127.0.0.1:9256']
YAML

finish_install
log info "=== $COMPONENT $TARGET installed successfully ==="
log info "Process groups configured at /etc/process_exporter/process-exporter.yml"
log info "Edit the config to add/remove groups, then: systemctl reload process_exporter"
