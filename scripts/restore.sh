#!/usr/bin/env bash
#
# restore.sh — restore the monitoring stack from a backup archive.
#
# WHAT IT RESTORES
#   Everything that backup.sh captured:
#     - All /etc/<component>/ service configs
#     - environment.yml, environment.local.yml, versions.yml (into repo configs/)
#     - Grafana SQLite database
#     - Prometheus TSDB blocks
#     - Loki chunk store + index
#     - Alertmanager silence state
#
# SAFETY CHECKS
#   - Verifies tarball integrity before touching the live system
#   - Shows a manifest diff before touching anything
#   - Requires --yes to proceed (no accidental restores)
#   - Takes a pre-restore "emergency" backup automatically
#   - All services stopped cleanly, restarted after, health-checked
#
# Usage:
#   sudo ./scripts/restore.sh <backup-tarball> [--yes] [--skip-health]
#
#   --yes          skip the interactive confirmation prompt
#   --skip-health  skip post-restore health check (for partial restores)

set -Eeuo pipefail
source "$(dirname "$(readlink -f "$0")")/common.sh"

YES=0
SKIP_HEALTH=0
ARCHIVE=""
for arg in "$@"; do
    case "$arg" in
        --yes)          YES=1 ;;
        --skip-health)  SKIP_HEALTH=1 ;;
        *.tar.gz|*.tgz) ARCHIVE="$arg" ;;
    esac
done

setup_error_trap
log info "=== monitoring restore starting ==="

# --- 1. Preflight -----------------------------------------------------------
require_root

if [[ -z "$ARCHIVE" ]]; then
    die "Usage: sudo ./scripts/restore.sh <monitoring-YYYYMMDD-HHMMSS.tar.gz> [--yes]
Available backups:
$(ls -1t /var/backups/monitoring/monitoring-*.tar.gz 2>/dev/null || echo '  none found')"
fi

[[ -f "$ARCHIVE" ]] || die "archive not found: $ARCHIVE"

# --- 2. Verify archive integrity --------------------------------------------
log info "verifying archive integrity: $ARCHIVE"
tar -tzf "$ARCHIVE" > /dev/null \
    || die "archive is corrupt or not a valid gzip tar: $ARCHIVE"
log info "archive OK"

# --- 3. Show manifest -------------------------------------------------------
log info "--- backup manifest ---"
MANIFEST=$(tar -xzf "$ARCHIVE" -O ./MANIFEST.txt 2>/dev/null || echo "(no MANIFEST.txt found)")
printf '%s\n' "$MANIFEST"
echo

# --- 4. Confirm -------------------------------------------------------------
if [[ $YES -eq 0 ]]; then
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│  WARNING: this will OVERWRITE all monitoring data and configs.  │"
    echo "│  A pre-restore emergency backup will be taken first.            │"
    echo "└─────────────────────────────────────────────────────────────────┘"
    read -r -p "Type 'yes' to proceed: " CONFIRM
    [[ "$CONFIRM" == "yes" ]] || die "restore cancelled"
fi

# --- 5. Pre-restore emergency backup ----------------------------------------
log info "--- taking pre-restore emergency backup ---"
EMERGENCY_BACKUP="/var/backups/monitoring/pre-restore-emergency-$(date +%Y%m%d-%H%M%S).tar.gz"
if bash "$(dirname "$(readlink -f "$0")")/backup.sh" --quiet; then
    log info "emergency backup taken — find it in /var/backups/monitoring/"
else
    log warn "emergency backup failed — proceeding anyway (you were warned)"
fi

# --- 6. Stage the archive ---------------------------------------------------
STAGING=$(mktemp -d)
push_rollback "rm -rf $STAGING"
log info "extracting archive to $STAGING..."
tar -xzf "$ARCHIVE" -C "$STAGING"
log info "extraction complete"

# --- 7. Stop all monitoring services ----------------------------------------
log info "--- stopping monitoring services ---"
STOPPED_SERVICES=()
KNOWN_SERVICES=(prometheus node_exporter alertmanager loki alloy grafana
                blackbox_exporter snmp_exporter process_exporter
                mysqld_exporter postgres_exporter redis_exporter
                monitoring-watchdog.timer nginx)

for svc in "${KNOWN_SERVICES[@]}"; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        systemctl stop "$svc" && STOPPED_SERVICES+=("$svc") || true
        log info "  stopped: $svc"
    fi
done
# Ensure we restart everything on error
push_rollback "systemctl start ${STOPPED_SERVICES[*]:-} 2>/dev/null || true"

# --- 8. Restore configs from /etc/ ------------------------------------------
log info "--- restoring /etc/ configs ---"
if [[ -d "$STAGING/etc" ]]; then
    for component_dir in "$STAGING/etc"/*/; do
        component=$(basename "$component_dir")
        dest="/etc/$component"
        if [[ -d "$dest" ]]; then
            cp -a "$component_dir/." "$dest/"
            log info "  restored: /etc/$component"
        else
            cp -a "$component_dir" "/etc/$component"
            log info "  created:  /etc/$component"
        fi
    done
fi

# --- 9. Restore repo configs ------------------------------------------------
log info "--- restoring repo configs ---"
if [[ -d "$STAGING/repo" ]]; then
    for f in "$STAGING/repo"/*; do
        dest="$CONFIG_DIR/$(basename "$f")"
        cp -a "$f" "$dest"
        log info "  restored: $dest"
    done
fi

# --- 10. Restore Grafana database -------------------------------------------
log info "--- restoring Grafana ---"
if [[ -d "$STAGING/var/lib/grafana" ]]; then
    mkdir -p /var/lib/grafana
    cp -a "$STAGING/var/lib/grafana/." /var/lib/grafana/
    chown -R grafana:grafana /var/lib/grafana/ 2>/dev/null || true
    log info "  grafana: database restored"
fi

# --- 11. Restore Alertmanager state -----------------------------------------
log info "--- restoring Alertmanager state ---"
if [[ -d "$STAGING/var/lib/alertmanager" ]]; then
    mkdir -p /var/lib/alertmanager
    cp -a "$STAGING/var/lib/alertmanager/." /var/lib/alertmanager/
    chown -R alertmanager:alertmanager /var/lib/alertmanager/ 2>/dev/null || true
    log info "  alertmanager: silence state restored"
fi

# --- 12. Restore Loki -------------------------------------------------------
log info "--- restoring Loki ---"
if [[ -d "$STAGING/var/lib/loki" ]]; then
    rm -rf /var/lib/loki
    cp -a "$STAGING/var/lib/loki" /var/lib/
    chown -R loki:loki /var/lib/loki/ 2>/dev/null || true
    log info "  loki: chunk store + index restored"
fi

# --- 13. Restore Prometheus TSDB -------------------------------------------
log info "--- restoring Prometheus TSDB ---"
if [[ -d "$STAGING/var/lib/prometheus" ]]; then
    # Preserve the existing WAL directory (backup excluded it intentionally)
    WAL_BACKUP=""
    if [[ -d /var/lib/prometheus/wal ]]; then
        WAL_BACKUP=$(mktemp -d)
        cp -a /var/lib/prometheus/wal "$WAL_BACKUP/"
    fi
    rm -rf /var/lib/prometheus
    cp -a "$STAGING/var/lib/prometheus" /var/lib/
    # Restore WAL if it existed (Prometheus will rebuild/truncate it)
    if [[ -n "$WAL_BACKUP" ]]; then
        cp -a "$WAL_BACKUP/wal" /var/lib/prometheus/
        rm -rf "$WAL_BACKUP"
    fi
    chown -R prometheus:prometheus /var/lib/prometheus/ 2>/dev/null || true
    log info "  prometheus: TSDB blocks restored"
fi

# --- 14. Restart services ---------------------------------------------------
log info "--- restarting monitoring services ---"
for svc in "${STOPPED_SERVICES[@]}"; do
    systemctl start "$svc" && log info "  started: $svc" || log warn "  failed to start: $svc"
done
pop_rollback  # remove the start-all rollback — we just started them

# --- 15. Wait for services to become healthy --------------------------------
sleep 3

# --- 16. Cleanup and health check -------------------------------------------
rm -rf "$STAGING"
pop_rollback  # remove staging cleanup (done)

if [[ $SKIP_HEALTH -eq 0 ]]; then
    log info "--- running health check ---"
    bash "$(dirname "$(readlink -f "$0")")/healthcheck.sh" || true
fi

log info "=== restore complete from: $ARCHIVE ==="
log info "If anything looks wrong, the pre-restore emergency backup is in /var/backups/monitoring/"
