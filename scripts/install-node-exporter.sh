#!/usr/bin/env bash
#
# install-node-exporter.sh — install or upgrade node_exporter as a native
# systemd service.
#
#   Version:        configs/versions.yml        (node_exporter)
#   Listen address: configs/environment(.local).yml (node_exporter_listen)
#
# Usage: sudo ./scripts/install-node-exporter.sh [--reinstall]
#
# Behavior:
#   not installed              → fresh install
#   installed at pinned ver    → verify health, exit 0 (no-op)
#   installed at other ver     → upgrade (stop, swap binary, restart)
#   --reinstall                → force reinstall even at the pinned version

set -Eeuo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

COMPONENT="node_exporter"
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
check_disk_space /var/lib 512
check_time_sync
check_ufw

# --- 2. Resolve versions and settings --------------------------------------
TARGET=$(get_version "$COMPONENT")
CURRENT=$(installed_version "$COMPONENT")
LISTEN=$(get_env node_exporter_listen "127.0.0.1:9100")

# --- 3. Decide what to do --------------------------------------------------
MODE="install"
if [[ -n "$CURRENT" && $REINSTALL -eq 0 ]]; then
    if [[ "$CURRENT" == "$TARGET" ]]; then
        log info "$COMPONENT $TARGET already installed — verifying health"
        verify_service_health "$COMPONENT" "$TARGET"
        log info "nothing to do"
        exit 0
    fi
    MODE="upgrade"
    log info "upgrading $COMPONENT $CURRENT → $TARGET"
else
    log info "installing $COMPONENT $TARGET"
fi

# Only meaningful on a truly fresh install — on upgrade/reinstall the port
# is legitimately held by our own running service.
if [[ -z "$CURRENT" ]]; then
    check_port_free "${LISTEN##*:}"
fi

# --- 4. Download and verify ------------------------------------------------
BASE="https://github.com/prometheus/node_exporter/releases/download/v${TARGET}"
TARBALL=$(fetch_and_verify \
    "$BASE/node_exporter-${TARGET}.linux-amd64.tar.gz" \
    "$BASE/sha256sums.txt")

# --- 5. User and directories -----------------------------------------------
create_system_user "$COMPONENT"
# textfile collector dir: any *.prom file dropped here (e.g. by a cron job)
# is exposed as metrics — see docs/runbook.md.
create_dir /var/lib/node_exporter "node_exporter:node_exporter" 0755
create_dir /var/lib/node_exporter/textfile "node_exporter:node_exporter" 0755

# --- 6. Stop the running service before swapping its binary ----------------
if systemctl is-active --quiet "$COMPONENT"; then
    systemctl stop "$COMPONENT"
    push_rollback "systemctl start $COMPONENT"
fi

# --- 7. Install the binary -------------------------------------------------
EXTRACTED=$(extract_tarball "$TARBALL")
install_binary "$EXTRACTED/node_exporter" "$COMPONENT"

# --- 8. systemd unit -------------------------------------------------------
install_unit "$COMPONENT" "$SERVICE_DIR/node-exporter.service.tpl" "LISTEN=$LISTEN"

# --- 9. Start and verify ---------------------------------------------------
enable_start_service "$COMPONENT"
verify_service_health "$COMPONENT" "$TARGET"

finish_install
log info "=== $COMPONENT $TARGET installed successfully ==="
