#!/usr/bin/env bash
#
# install-watchdog.sh — install the monitoring stack watchdog.
#
# The watchdog is a systemd timer that fires every 5 minutes, runs
# healthcheck.sh, and on failure posts a MonitoringStackDegraded alert
# directly to Alertmanager (bypassing Prometheus, which may be down).
#
# No binary downloads. No version pinning. No rollback needed.
# The watchdog depends only on: bash, curl, and the monitoring repo scripts.
#
# After install:
#   systemctl status monitoring-watchdog.timer
#   systemctl list-timers monitoring-watchdog.timer
#   journalctl -u monitoring-watchdog -f
#
# Usage: sudo ./scripts/install-watchdog.sh

set -Eeuo pipefail
source "$(dirname "$(readlink -f "$0")")/common.sh"

COMPONENT="watchdog"

setup_error_trap
log info "=== monitoring watchdog installer starting ==="

require_root
require_ubuntu_2404
require_commands curl

# --- 1. Verify dependencies present ----------------------------------------
[[ -f "$REPO_DIR/scripts/healthcheck.sh" ]] \
    || die "healthcheck.sh not found — install the monitoring framework first"
[[ -f "$REPO_DIR/scripts/watchdog-alert.sh" ]] \
    || die "watchdog-alert.sh not found — is the repo up to date?"

# --- 2. Check if already installed -----------------------------------------
if systemctl is-enabled --quiet monitoring-watchdog.timer 2>/dev/null \
   && systemctl is-active --quiet monitoring-watchdog.timer 2>/dev/null; then
    log info "monitoring-watchdog.timer already active — reinstalling to pick up changes"
    systemctl stop monitoring-watchdog.timer 2>/dev/null || true
    systemctl disable monitoring-watchdog.timer 2>/dev/null || true
fi

# --- 3. Install watchdog-alert.sh to /usr/local/bin/ -----------------------
install -m 0755 -o root -g root \
    "$REPO_DIR/scripts/watchdog-alert.sh" \
    "$BIN_DIR/watchdog-alert"
log info "installed watchdog-alert → $BIN_DIR/watchdog-alert"

# --- 4. Install systemd units -----------------------------------------------
install -m 0644 -o root -g root \
    "$SERVICE_DIR/monitoring-watchdog.service" \
    /etc/systemd/system/monitoring-watchdog.service
log info "installed monitoring-watchdog.service"

install -m 0644 -o root -g root \
    "$SERVICE_DIR/monitoring-watchdog.timer" \
    /etc/systemd/system/monitoring-watchdog.timer
log info "installed monitoring-watchdog.timer"

# --- 5. Create log directory (watchdog-alert.sh writes dead letters here) --
mkdir -p /var/log/monitoring
chmod 0750 /var/log/monitoring
log info "log directory: /var/log/monitoring"

# --- 6. Enable and start timer ---------------------------------------------
systemctl daemon-reload
systemctl enable --now monitoring-watchdog.timer
log info "monitoring-watchdog.timer enabled and started"

# --- 7. Fire one immediate health check to confirm everything works --------
log info "running first health check..."
systemctl start monitoring-watchdog.service || {
    log warn "first health check reported a failure — check: journalctl -u monitoring-watchdog"
    log warn "this is NOT an installer failure; the watchdog is working correctly"
}

# --- 8. Verify timer is active ---------------------------------------------
systemctl is-active --quiet monitoring-watchdog.timer \
    || die "monitoring-watchdog.timer did not activate"

log info ""
log info "=== watchdog installed successfully ==="
log info "Next fire: $(systemctl list-timers monitoring-watchdog.timer --no-pager 2>/dev/null | grep monitoring | awk '{print $1, $2}' || echo 'see: systemctl list-timers')"
log info "View logs: journalctl -u monitoring-watchdog -n 20"
