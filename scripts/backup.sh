#!/usr/bin/env bash
#
# backup.sh — consistent snapshot backup of the monitoring stack.
#
# WHAT IT BACKS UP
#   - /etc/<component>/        all service configs and credentials
#   - /opt/monitoring/configs/ environment.yml + environment.local.yml
#   - /var/lib/grafana/        Grafana SQLite database + plugins
#   - /var/lib/prometheus/     TSDB data (Prometheus briefly stopped)
#   - /var/lib/loki/           chunk store + index (Loki briefly stopped)
#   - /var/lib/alertmanager/   silence state
#
# OUTPUT
#   /var/backups/monitoring/monitoring-YYYYMMDD-HHMMSS.tar.gz
#
# ROTATION
#   Keeps the last KEEP_BACKUPS archives (default 7, override in env).
#   Controlled by: backup_keep: "7" in configs/environment.yml
#
# CRON EXAMPLE
#   Add to /etc/cron.d/monitoring-backup:
#     0 2 * * * root /opt/monitoring/scripts/backup.sh --quiet
#
# Usage: sudo ./scripts/backup.sh [--quiet] [--dry-run]
#   --quiet    suppress non-error output (for cron)
#   --dry-run  show what would be backed up without doing it

set -Eeuo pipefail
source "$(dirname "$(readlink -f "$0")")/common.sh"

QUIET=0
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --quiet)   QUIET=1 ;;
        --dry-run) DRY_RUN=1 ;;
    esac
done

[[ $QUIET -eq 1 ]] && exec 1>/dev/null   # suppress stdout for cron

setup_error_trap
log info "=== monitoring backup starting ==="

# --- 1. Preflight -----------------------------------------------------------
require_root

BACKUP_DIR="/var/backups/monitoring"
LOG_FILE="/var/log/monitoring/backup.log"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
ARCHIVE="$BACKUP_DIR/monitoring-${TIMESTAMP}.tar.gz"
STAGING=$(mktemp -d)
KEEP=$(yaml_get "$CONFIG_DIR/environment.yml" "backup_keep" 2>/dev/null || echo "7")
push_rollback "rm -rf $STAGING"

mkdir -p "$BACKUP_DIR" "$(dirname "$LOG_FILE")"
log info "archive → $ARCHIVE (keep last $KEEP)"
log info "staging → $STAGING"

# Redirect to log as well for cron visibility
exec &> >(tee -a "$LOG_FILE")

# --- 2. Collect component configs -------------------------------------------
log info "--- collecting configs ---"

# All /etc/<component>/ directories (exclude credentials with mode 0600 content
# by keeping the files but noting their sensitivity in the README)
CONFIG_DIRS=(
    /etc/prometheus
    /etc/alertmanager
    /etc/loki
    /etc/alloy
    /etc/grafana
    /etc/blackbox_exporter
    /etc/snmp_exporter
    /etc/process_exporter
    /etc/mysqld_exporter
    /etc/postgres_exporter
    /etc/redis_exporter
    /etc/nginx
)

mkdir -p "$STAGING/etc"
for dir in "${CONFIG_DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
        [[ $DRY_RUN -eq 0 ]] && cp -a "$dir" "$STAGING/etc/" || log info "[dry-run] would copy $dir"
        log info "  configs: $dir"
    fi
done

# Monitoring repo configs (environment.yml + environment.local.yml)
mkdir -p "$STAGING/repo"
for f in "$CONFIG_DIR/environment.yml" "$CONFIG_DIR/environment.local.yml" "$CONFIG_DIR/versions.yml"; do
    if [[ -f "$f" ]]; then
        [[ $DRY_RUN -eq 0 ]] && cp -a "$f" "$STAGING/repo/" || log info "[dry-run] would copy $f"
        log info "  configs: $f"
    fi
done

# Prometheus rules (may differ from repo if patched by wiring)
if [[ -d /etc/prometheus/rules ]]; then
    log info "  configs: /etc/prometheus/rules (already included)"
fi

# --- 3. Grafana database (safe to hot-copy: SQLite WAL mode) ----------------
log info "--- backing up Grafana ---"
if [[ -d /var/lib/grafana ]]; then
    mkdir -p "$STAGING/var/lib/grafana"
    if [[ $DRY_RUN -eq 0 ]]; then
        # grafana.db: SQLite WAL mode → consistent read without stopping service
        cp -a /var/lib/grafana/grafana.db "$STAGING/var/lib/grafana/" 2>/dev/null || true
        # Provisioned dashboard JSON files
        [[ -d /var/lib/grafana/dashboards ]] && \
            cp -a /var/lib/grafana/dashboards "$STAGING/var/lib/grafana/" 2>/dev/null || true
    fi
    log info "  grafana: hot-copy of grafana.db (WAL mode, consistent)"
fi

# --- 4. Alertmanager state (small, hot-copyable) ----------------------------
log info "--- backing up Alertmanager state ---"
if [[ -d /var/lib/alertmanager ]]; then
    mkdir -p "$STAGING/var/lib"
    [[ $DRY_RUN -eq 0 ]] && cp -a /var/lib/alertmanager "$STAGING/var/lib/" 2>/dev/null || true
    log info "  alertmanager: silence state"
fi

# --- 5. Loki — stop → copy → restart ----------------------------------------
log info "--- backing up Loki (brief stop) ---"
LOKI_STOPPED=0
if [[ -d /var/lib/loki ]]; then
    if systemctl is-active --quiet loki 2>/dev/null; then
        if [[ $DRY_RUN -eq 0 ]]; then
            log info "  stopping loki..."
            systemctl stop loki
            LOKI_STOPPED=1
            push_rollback "systemctl start loki"
        fi
    fi
    mkdir -p "$STAGING/var/lib"
    if [[ $DRY_RUN -eq 0 ]]; then
        cp -a /var/lib/loki "$STAGING/var/lib/"
        log info "  loki: chunk store + index copied"
    else
        log info "[dry-run] would stop loki, copy /var/lib/loki, restart"
    fi
fi

# --- 6. Prometheus TSDB — stop → copy → restart -----------------------------
log info "--- backing up Prometheus TSDB (brief stop) ---"
PROMETHEUS_STOPPED=0
if [[ -d /var/lib/prometheus ]]; then
    if systemctl is-active --quiet prometheus 2>/dev/null; then
        if [[ $DRY_RUN -eq 0 ]]; then
            log info "  stopping prometheus..."
            systemctl stop prometheus
            PROMETHEUS_STOPPED=1
            push_rollback "systemctl start prometheus"
        fi
    fi
    mkdir -p "$STAGING/var/lib"
    if [[ $DRY_RUN -eq 0 ]]; then
        # Exclude the wal/ directory: it's transient and large; TSDB recovers
        # from blocks alone on restart. This keeps backup size manageable.
        rsync -a --exclude='wal' /var/lib/prometheus/ "$STAGING/var/lib/prometheus/" \
            2>/dev/null || cp -a /var/lib/prometheus "$STAGING/var/lib/"
        log info "  prometheus: TSDB blocks copied (WAL excluded)"
    else
        log info "[dry-run] would stop prometheus, copy TSDB blocks, restart"
    fi
fi

# --- 7. Restart stopped services immediately --------------------------------
if [[ $DRY_RUN -eq 0 ]]; then
    if [[ $PROMETHEUS_STOPPED -eq 1 ]]; then
        systemctl start prometheus
        log info "  prometheus: restarted"
        pop_rollback  # remove the push_rollback for prometheus
    fi
    if [[ $LOKI_STOPPED -eq 1 ]]; then
        systemctl start loki
        log info "  loki: restarted"
        pop_rollback  # remove the push_rollback for loki
    fi
fi

# --- 8. Write manifest ------------------------------------------------------
if [[ $DRY_RUN -eq 0 ]]; then
    cat > "$STAGING/MANIFEST.txt" <<MANIFEST
monitoring-backup
timestamp: $TIMESTAMP
hostname:  $(hostname -f 2>/dev/null || hostname)
platform:  $(uname -sr)
created:   $(date -u '+%Y-%m-%d %H:%M:%S UTC')
contents:
  etc/            service configs (prometheus, alertmanager, loki, grafana, ...)
  repo/           environment.yml, environment.local.yml, versions.yml
  var/lib/grafana grafana.db (SQLite hot-copy)
  var/lib/loki/   chunk store + index (quiesced stop)
  var/lib/prometheus/ TSDB blocks (quiesced stop, WAL excluded)
  var/lib/alertmanager/ silence state

restore:   sudo ./scripts/restore.sh $ARCHIVE
MANIFEST
fi

# --- 9. Create archive ------------------------------------------------------
if [[ $DRY_RUN -eq 0 ]]; then
    log info "--- creating archive ---"
    tar -czf "$ARCHIVE" -C "$STAGING" .
    ARCHIVE_SIZE=$(du -sh "$ARCHIVE" | cut -f1)
    log info "archive created: $ARCHIVE ($ARCHIVE_SIZE)"
else
    log info "[dry-run] would create: $ARCHIVE"
fi

# --- 10. Cleanup staging directory ------------------------------------------
rm -rf "$STAGING"
pop_rollback  # remove the staging cleanup from rollback (already done)

# --- 11. Rotate old backups -------------------------------------------------
if [[ $DRY_RUN -eq 0 ]]; then
    log info "--- rotating backups (keeping last $KEEP) ---"
    # shellcheck disable=SC2012
    mapfile -t old < <(ls -1t "$BACKUP_DIR"/monitoring-*.tar.gz 2>/dev/null | tail -n +"$((KEEP + 1))")
    for f in "${old[@]}"; do
        rm -f "$f"
        log info "  removed: $f"
    done
    REMAINING=$(ls -1 "$BACKUP_DIR"/monitoring-*.tar.gz 2>/dev/null | wc -l)
    log info "backups on disk: $REMAINING"
fi

log info "=== backup complete: $ARCHIVE ==="
