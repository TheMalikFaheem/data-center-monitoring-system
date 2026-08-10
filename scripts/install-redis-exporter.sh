#!/usr/bin/env bash
#
# install-redis-exporter.sh — install or upgrade Redis Exporter as a native
# systemd service.
#
# REQUIREMENTS: Redis connection must be set in configs/environment.local.yml:
#   redis_addr: "redis://localhost:6379"        # no auth
#   redis_addr: "redis://:password@localhost:6379"  # with password
#
# The address and optional password are written to an EnvironmentFile loaded
# by systemd — credentials NEVER appear in ps output or journalctl.
#
# NOTE: redis_exporter's --version output includes a 'v' prefix (v1.80.0).
# common.sh:installed_version() strips the leading 'v' for comparison.
#
# NOTE: redis_exporter uses per-file SHA256 checksums (not a combined
# sha256sums.txt like the Prometheus project does). The installer handles this
# by downloading the .sha256 file and verifying inline.
#
#   Version:   configs/versions.yml            (redis_exporter)
#   Settings:  configs/environment(.local).yml (redis_exporter_listen, redis_addr)
#
# Usage: sudo ./scripts/install-redis-exporter.sh [--reinstall]

set -Eeuo pipefail
source "$(dirname "$(readlink -f "$0")")/common.sh"

COMPONENT="redis_exporter"
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
LISTEN=$(get_env redis_exporter_listen "127.0.0.1:9121")

REDIS_ADDR=$(yaml_get "$CONFIG_DIR/environment.local.yml" "redis_addr" 2>/dev/null || true)
if [[ -z "$REDIS_ADDR" ]]; then
    die "redis_addr is not set in configs/environment.local.yml.
Add it before running this installer:
  # No auth:
  echo 'redis_addr: \"redis://localhost:6379\"' >> configs/environment.local.yml
  # With password:
  echo 'redis_addr: \"redis://:yourpassword@localhost:6379\"' >> configs/environment.local.yml"
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
# redis_exporter tarball naming: redis_exporter-v1.80.0.linux-amd64.tar.gz
# (note: 'v' prefix in filename, dot before OS name)
# Checksum file: sha256sums.txt (multi-hash, standard sha256sum format)
# Confirmed assets via GitHub API: https://api.github.com/repos/oliver006/redis_exporter/releases/tags/v${VERSION}
BASE="https://github.com/oliver006/redis_exporter/releases/download/v${TARGET}"
TARBALL=$(fetch_and_verify \
    "$BASE/redis_exporter-v${TARGET}.linux-amd64.tar.gz" \
    "$BASE/sha256sums.txt")

# --- 5. User and directories -----------------------------------------------
create_system_user "$COMPONENT"
create_dir /etc/redis_exporter "root:redis_exporter" 0750

# --- 6. Stop running service -----------------------------------------------
if systemctl is-active --quiet "$COMPONENT"; then
    systemctl stop "$COMPONENT"
    push_rollback "systemctl start $COMPONENT"
fi

# --- 7. Install binary -----------------------------------------------------
extract_tarball "$TARBALL" EXTRACTED
install_binary "$EXTRACTED/redis_exporter" "redis_exporter"

# --- 8. Write connection environment file ----------------------------------
ENV_FILE="/etc/redis_exporter/redis_exporter.env"
cat > "$ENV_FILE" <<ENV_EOF
# redis_exporter connection — loaded by systemd EnvironmentFile.
# Managed by install-redis-exporter.sh; update via environment.local.yml.
REDIS_ADDR=${REDIS_ADDR}
ENV_EOF
chmod 0600 "$ENV_FILE"
chown "redis_exporter:redis_exporter" "$ENV_FILE"
push_rollback "rm -f $ENV_FILE"
log info "connection config written → $ENV_FILE (mode 0600)"

# --- 9. systemd unit, start, verify ----------------------------------------
install_unit "$COMPONENT" "$SERVICE_DIR/redis-exporter.service.tpl" \
    "LISTEN=$LISTEN"
enable_start_service "$COMPONENT"
verify_service_health "$COMPONENT" "$TARGET"

# --- 10. Register Prometheus scrape job ------------------------------------
add_prometheus_scrape_job "redis" <<'YAML'

  # ── Redis metrics ─────────────────────────────────────────────────────────
  - job_name: redis
    static_configs:
      - targets: ['127.0.0.1:9121']
YAML

finish_install
log info "=== $COMPONENT $TARGET installed successfully ==="
log info "Redis metrics available at http://127.0.0.1:9121/metrics"
log info "To update the connection: edit configs/environment.local.yml and re-run with --reinstall"
