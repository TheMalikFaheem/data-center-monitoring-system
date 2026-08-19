#!/usr/bin/env bash
#
# install-mysqld-exporter.sh — install or upgrade MySQL Exporter as a native
# systemd service.
#
# REQUIREMENTS: MySQL DSN must be set in configs/environment.local.yml:
#   mysql_dsn: "exporter:password@tcp(127.0.0.1:3306)/"
#
# The DSN is written to /etc/mysqld_exporter/.my.cnf (owner mysqld_exporter,
# mode 0600) so it is NEVER visible in ps output or journalctl.
#
# For remote MySQL instances (on-prem data center), use the full TCP DSN:
#   mysql_dsn: "exporter:pass@tcp(db.internal:3306)/"
#
# Recommended MySQL user (minimum privileges):
#   CREATE USER 'exporter'@'%' IDENTIFIED BY 'password';
#   GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'exporter'@'%';
#   FLUSH PRIVILEGES;
#
#   Version:   configs/versions.yml            (mysqld_exporter)
#   Settings:  configs/environment(.local).yml (mysqld_exporter_listen, mysql_dsn)
#
# Usage: sudo ./scripts/install-mysqld-exporter.sh [--reinstall]

set -Eeuo pipefail
source "$(dirname "$(readlink -f "$0")")/common.sh"

COMPONENT="mysqld_exporter"
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
LISTEN=$(get_env mysqld_exporter_listen "127.0.0.1:9104")

# DSN is required — die with clear instructions if absent.
MYSQL_DSN=$(yaml_get "$CONFIG_DIR/environment.local.yml" "mysql_dsn" 2>/dev/null || true)
if [[ -z "$MYSQL_DSN" ]]; then
    die "mysql_dsn is not set in configs/environment.local.yml.
Add it before running this installer:
  echo 'mysql_dsn: \"exporter:password@tcp(127.0.0.1:3306)/\"' >> configs/environment.local.yml
Minimum MySQL privileges:
  GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'exporter'@'%';"
fi

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
BASE="https://github.com/prometheus/mysqld_exporter/releases/download/v${TARGET}"
TARBALL=$(fetch_and_verify \
    "$BASE/mysqld_exporter-${TARGET}.linux-amd64.tar.gz" \
    "$BASE/sha256sums.txt")

# --- 5. User and directories -----------------------------------------------
create_system_user "$COMPONENT"
create_dir /etc/mysqld_exporter "root:mysqld_exporter" 0750

# --- 6. Stop running service -----------------------------------------------
if systemctl is-active --quiet "$COMPONENT"; then
    systemctl stop "$COMPONENT"
    push_rollback "systemctl start $COMPONENT"
fi

# --- 7. Install binary -----------------------------------------------------
extract_tarball "$TARBALL" EXTRACTED
install_binary "$EXTRACTED/mysqld_exporter" "mysqld_exporter"

# --- 8. Write credentials file (.my.cnf) -----------------------------------
# DSN format for .my.cnf: [client] section with user/password/host.
# mysqld_exporter --config.my-cnf reads this file; it never appears in ps.
MYCNF="/etc/mysqld_exporter/.my.cnf"
# Parse user, password, host from DSN: user:password@tcp(host:port)/
DSN_USER="${MYSQL_DSN%%:*}"
DSN_PASS="${MYSQL_DSN#*:}"; DSN_PASS="${DSN_PASS%%@*}"
DSN_HOST="${MYSQL_DSN##*tcp(}"; DSN_HOST="${DSN_HOST%%)*}"

cat > "$MYCNF" <<MYCNF_EOF
[client]
user=${DSN_USER}
password=${DSN_PASS}
host=${DSN_HOST%%:*}
port=${DSN_HOST##*:}
MYCNF_EOF
chmod 0600 "$MYCNF"
chown "mysqld_exporter:mysqld_exporter" "$MYCNF"
push_rollback "rm -f $MYCNF"
log info "credentials written → $MYCNF (mode 0600)"

# --- 9. systemd unit, start, verify ----------------------------------------
install_unit "$COMPONENT" "$SERVICE_DIR/mysqld-exporter.service.tpl" \
    "LISTEN=$LISTEN"
enable_start_service "$COMPONENT"
verify_service_health "$COMPONENT" "$TARGET"

# --- 10. Register Prometheus scrape job ------------------------------------
add_prometheus_scrape_job "mysqld" <<'YAML'

  # ── MySQL metrics ─────────────────────────────────────────────────────────
  - job_name: mysqld
    static_configs:
      - targets: ['127.0.0.1:9104']
YAML

finish_install
log info "=== $COMPONENT $TARGET installed successfully ==="
log info "MySQL metrics available at http://127.0.0.1:9104/metrics"
log info "To update the DSN: edit configs/environment.local.yml and re-run with --reinstall"
