#!/usr/bin/env bash
#
# install-postgres-exporter.sh — install or upgrade PostgreSQL Exporter as a
# native systemd service.
#
# REQUIREMENTS: PostgreSQL DSN must be set in configs/environment.local.yml:
#   postgres_dsn: "postgresql://exporter:password@localhost:5432/postgres?sslmode=disable"
#
# The DSN is written to /etc/postgres_exporter/postgres_exporter.env as:
#   DATA_SOURCE_NAME=postgresql://...
# The systemd EnvironmentFile loads it — it NEVER appears in ps output.
#
# Recommended PostgreSQL user (minimum privileges):
#   CREATE USER exporter WITH PASSWORD 'password';
#   GRANT pg_monitor TO exporter;     -- PostgreSQL 10+
#   -- Or for older PostgreSQL:
#   -- GRANT SELECT ON pg_stat_database, pg_stat_user_tables TO exporter;
#
#   Version:   configs/versions.yml            (postgres_exporter)
#   Settings:  configs/environment(.local).yml (postgres_exporter_listen, postgres_dsn)
#
# Usage: sudo ./scripts/install-postgres-exporter.sh [--reinstall]

set -Eeuo pipefail
source "$(dirname "$(readlink -f "$0")")/common.sh"

COMPONENT="postgres_exporter"
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
LISTEN=$(get_env postgres_exporter_listen "127.0.0.1:9187")

POSTGRES_DSN=$(yaml_get "$CONFIG_DIR/environment.local.yml" "postgres_dsn" 2>/dev/null || true)
if [[ -z "$POSTGRES_DSN" ]]; then
    die "postgres_dsn is not set in configs/environment.local.yml.
Add it before running this installer:
  echo 'postgres_dsn: \"postgresql://exporter:password@localhost:5432/postgres?sslmode=disable\"' >> configs/environment.local.yml
Minimum PostgreSQL privileges (PostgreSQL 10+):
  CREATE USER exporter WITH PASSWORD 'password';
  GRANT pg_monitor TO exporter;"
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
BASE="https://github.com/prometheus-community/postgres_exporter/releases/download/v${TARGET}"
TARBALL=$(fetch_and_verify \
    "$BASE/postgres_exporter-${TARGET}.linux-amd64.tar.gz" \
    "$BASE/sha256sums.txt")

# --- 5. User and directories -----------------------------------------------
create_system_user "$COMPONENT"
create_dir /etc/postgres_exporter "root:postgres_exporter" 0750

# --- 6. Stop running service -----------------------------------------------
if systemctl is-active --quiet "$COMPONENT"; then
    systemctl stop "$COMPONENT"
    push_rollback "systemctl start $COMPONENT"
fi

# --- 7. Install binary -----------------------------------------------------
extract_tarball "$TARBALL" EXTRACTED
install_binary "$EXTRACTED/postgres_exporter" "postgres_exporter"

# --- 8. Write DSN environment file -----------------------------------------
ENV_FILE="/etc/postgres_exporter/postgres_exporter.env"
cat > "$ENV_FILE" <<ENV_EOF
# postgres_exporter DSN — loaded by systemd EnvironmentFile.
# Managed by install-postgres-exporter.sh; update via environment.local.yml.
DATA_SOURCE_NAME=${POSTGRES_DSN}
ENV_EOF
chmod 0600 "$ENV_FILE"
chown "postgres_exporter:postgres_exporter" "$ENV_FILE"
push_rollback "rm -f $ENV_FILE"
log info "DSN written → $ENV_FILE (mode 0600)"

# --- 9. systemd unit, start, verify ----------------------------------------
install_unit "$COMPONENT" "$SERVICE_DIR/postgres-exporter.service.tpl" \
    "LISTEN=$LISTEN"
enable_start_service "$COMPONENT"
verify_service_health "$COMPONENT" "$TARGET"

# --- 10. Register Prometheus scrape job ------------------------------------
add_prometheus_scrape_job "postgres" <<'YAML'

  # ── PostgreSQL metrics ────────────────────────────────────────────────────
  - job_name: postgres
    static_configs:
      - targets: ['127.0.0.1:9187']
YAML

finish_install
log info "=== $COMPONENT $TARGET installed successfully ==="
log info "PostgreSQL metrics available at http://127.0.0.1:9187/metrics"
log info "To update the DSN: edit configs/environment.local.yml and re-run with --reinstall"
