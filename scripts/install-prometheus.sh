#!/usr/bin/env bash
#
# install-prometheus.sh — install or upgrade Prometheus as a native systemd
# service. Same skeleton as install-node-exporter.sh, plus: a second binary
# (promtool), a rendered config file, and promtool validation before start.
#
#   Version:   configs/versions.yml            (prometheus)
#   Settings:  configs/environment(.local).yml (prometheus_listen,
#              prometheus_retention, scrape_interval, external_label_env)
#
# Usage: sudo ./scripts/install-prometheus.sh [--reinstall]

set -Eeuo pipefail
source "$(dirname "$(readlink -f "$0")")/common.sh"

COMPONENT="prometheus"
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
check_disk_space /var/lib 2048   # TSDB grows with retention; 30d needs headroom
check_time_sync
check_firewall

# --- 2. Resolve versions and settings --------------------------------------
TARGET=$(get_version "$COMPONENT")
CURRENT=$(installed_version "$COMPONENT")
LISTEN=$(get_env prometheus_listen "127.0.0.1:9090")
RETENTION=$(get_env prometheus_retention "30d")
SCRAPE_INTERVAL=$(get_env scrape_interval "15s")
ENV_LABEL=$(get_env external_label_env "production")

# --- 3. Decide what to do --------------------------------------------------
MODE="install"
if [[ -n "$CURRENT" && $REINSTALL -eq 0 && "$CURRENT" != "$TARGET" ]]; then
    MODE="upgrade"
    log info "upgrading $COMPONENT $CURRENT → $TARGET"
elif [[ -n "$CURRENT" && $REINSTALL -eq 0 ]]; then
    # Binary already at the pin — but only short-circuit when the service is
    # genuinely installed and running; otherwise fall through and repair
    # (a crash or power loss mid-install can leave a binary with no unit).
    if systemctl is-enabled --quiet "$COMPONENT" 2>/dev/null \
       && systemctl is-active --quiet "$COMPONENT"; then
        log info "$COMPONENT $TARGET already installed — verifying health"
        verify_service_health "$COMPONENT" "$TARGET"
        log info "nothing to do"
        exit 0
    fi
    log warn "$COMPONENT $TARGET binary present but service missing/disabled/inactive — repairing"
else
    log info "installing $COMPONENT $TARGET"
fi

if [[ -z "$CURRENT" ]]; then
    check_port_free "${LISTEN##*:}"
fi

# --- 4. Download and verify ------------------------------------------------
BASE="https://github.com/prometheus/prometheus/releases/download/v${TARGET}"
TARBALL=$(fetch_and_verify \
    "$BASE/prometheus-${TARGET}.linux-amd64.tar.gz" \
    "$BASE/sha256sums.txt")

# --- 5. User and directories -----------------------------------------------
create_system_user "$COMPONENT"
create_dir /etc/prometheus "root:prometheus" 0750
create_dir /var/lib/prometheus "prometheus:prometheus" 0750   # the TSDB — never rolled back once it pre-exists

# --- 6. Stop the running service before swapping its binary ----------------
if systemctl is-active --quiet "$COMPONENT"; then
    systemctl stop "$COMPONENT"
    push_rollback "systemctl start $COMPONENT"
fi

# --- 7. Install the binaries -----------------------------------------------
extract_tarball "$TARBALL" EXTRACTED
install_binary "$EXTRACTED/prometheus" "prometheus"
install_binary "$EXTRACTED/promtool" "promtool"

# --- 8. Configuration ------------------------------------------------------
# An existing config is NEVER overwritten (operators edit it); a differing
# fresh render is saved as prometheus.yml.new for manual review instead.
CONFIG="/etc/prometheus/prometheus.yml"
TMP_CFG=$(mktemp)
render_template "$TEMPLATE_DIR/prometheus.yml.tpl" "$TMP_CFG" \
    "SCRAPE_INTERVAL=$SCRAPE_INTERVAL" \
    "HOSTNAME=$(hostname)" \
    "ENV_LABEL=$ENV_LABEL"
if [[ ! -f "$CONFIG" ]]; then
    install -m 0640 -o root -g prometheus "$TMP_CFG" "$CONFIG"
    push_rollback "rm -f $CONFIG"
    log info "installed $CONFIG"
elif ! cmp -s "$TMP_CFG" "$CONFIG"; then
    install -m 0640 -o root -g prometheus "$TMP_CFG" "$CONFIG.new"
    log warn "existing prometheus.yml left untouched; fresh render saved as prometheus.yml.new for review"
else
    log info "prometheus.yml unchanged"
fi
rm -f "$TMP_CFG"

# Validate before (re)starting — a bad config would put the service in a
# crash loop, which is much harder to read than a promtool error.
promtool check config "$CONFIG" || die "promtool rejected $CONFIG — fix the config before starting"

# --- 9. systemd unit, start, verify ----------------------------------------
install_unit "$COMPONENT" "$SERVICE_DIR/prometheus.service.tpl" \
    "LISTEN=$LISTEN" "RETENTION=$RETENTION"
enable_start_service "$COMPONENT"
verify_service_health "$COMPONENT" "$TARGET"

finish_install
log info "=== $COMPONENT $TARGET installed successfully ==="
MONITOR_IP=$(get_env monitor_server_ip "YOUR_MONITOR_SERVER_IP")
log info "UI (from your workstation): ssh -L 9090:127.0.0.1:9090 root@${MONITOR_IP} → http://localhost:9090"
