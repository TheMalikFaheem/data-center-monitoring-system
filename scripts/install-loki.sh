#!/usr/bin/env bash
#
# install-loki.sh — install or upgrade Loki as a native systemd service.
#
# Loki releases a single statically-linked binary in a .zip archive (not a
# tarball). This installer downloads the zip, verifies its SHA256 against
# Grafana's published sha256sum.txt, extracts the binary, and follows the
# same 9-step skeleton as all other installers in this framework.
#
#   Version:   configs/versions.yml            (loki)
#   Settings:  configs/environment(.local).yml (loki_listen, loki_retention)
#
# Usage: sudo ./scripts/install-loki.sh [--reinstall]

set -Eeuo pipefail
source "$(dirname "$(readlink -f "$0")")/common.sh"

COMPONENT="loki"
REINSTALL=0
if [[ "${1:-}" == "--reinstall" ]]; then
    REINSTALL=1
fi

setup_error_trap
log info "=== $COMPONENT installer starting ==="

# --- 1. Preflight ----------------------------------------------------------
require_root
require_ubuntu_2404
require_commands curl unzip sha256sum
check_disk_space /var/lib 1024   # Loki index + chunks grow with log volume
check_time_sync
check_ufw

# --- 2. Resolve versions and settings --------------------------------------
TARGET=$(get_version "$COMPONENT")
CURRENT=$(installed_version "$COMPONENT")
LISTEN=$(get_env loki_listen "127.0.0.1:3100")
RETENTION=$(get_env loki_retention "30d")

# Parse host and port from listen address.
LOKI_HOST="${LISTEN%%:*}"
LOKI_PORT="${LISTEN##*:}"

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
    log warn "$COMPONENT $TARGET binary present but service missing/disabled/inactive — repairing"
else
    log info "installing $COMPONENT $TARGET"
fi

if [[ -z "$CURRENT" ]]; then
    check_port_free "$LOKI_PORT"
fi

# --- 4. Download and verify ------------------------------------------------
# Loki releases a zip (not tarball). fetch_and_verify handles the download
# and checksum; we unzip inline below since extract_tarball is tar-specific.
BASE="https://github.com/grafana/loki/releases/download/v${TARGET}"
ZIP_NAME="loki-linux-amd64.zip"
ZIP_URL="$BASE/$ZIP_NAME"
SUMS_URL="$BASE/sha256sum.txt"

ZIP_FILE="$DOWNLOAD_DIR/$ZIP_NAME"
SUMS_FILE="$DOWNLOAD_DIR/$ZIP_NAME.sha256sums"
mkdir -p "$DOWNLOAD_DIR"

# Always fetch a fresh checksum file; reuse the zip only if checksum still matches.
download_file "$SUMS_URL" "$SUMS_FILE"
if [[ -f "$ZIP_FILE" ]] && _sha256_matches "$ZIP_FILE" "$SUMS_FILE"; then
    log info "using cached $ZIP_NAME (checksum OK)"
else
    rm -f "$ZIP_FILE"
    download_file "$ZIP_URL" "$ZIP_FILE"
    verify_sha256 "$ZIP_FILE" "$SUMS_FILE"
fi

# Extract the single binary from the zip into a temp directory.
EXTRACT_TMP=$(mktemp -d /tmp/monitoring-extract.XXXXXX)
_TMPDIRS+=("$EXTRACT_TMP")
unzip -q "$ZIP_FILE" -d "$EXTRACT_TMP" || die "failed to extract $ZIP_NAME"

# Grafana zips the binary as 'loki-linux-amd64' (no extension).
LOKI_BIN="$EXTRACT_TMP/loki-linux-amd64"
if [[ ! -f "$LOKI_BIN" ]]; then
    # Fallback: find any file named 'loki*' in the extracted dir.
    LOKI_BIN=$(find "$EXTRACT_TMP" -maxdepth 2 -name 'loki*' -type f -print -quit)
    [[ -n "$LOKI_BIN" ]] || die "could not find loki binary inside $ZIP_NAME"
fi

# --- 5. User and directories -----------------------------------------------
create_system_user "$COMPONENT"
create_dir /etc/loki "root:loki" 0750
create_dir /var/lib/loki "loki:loki" 0750
create_dir /var/lib/loki/chunks  "loki:loki" 0750
create_dir /var/lib/loki/rules   "loki:loki" 0750
create_dir /var/lib/loki/compactor "loki:loki" 0750

# --- 6. Stop the running service before swapping its binary ----------------
if systemctl is-active --quiet "$COMPONENT"; then
    systemctl stop "$COMPONENT"
    push_rollback "systemctl start $COMPONENT"
fi

# --- 7. Install the binary -------------------------------------------------
install_binary "$LOKI_BIN" "loki"

# --- 8. Configuration ------------------------------------------------------
CONFIG="/etc/loki/loki.yml"
TMP_CFG=$(mktemp)
render_template "$TEMPLATE_DIR/loki.yml.tpl" "$TMP_CFG" \
    "HTTP_PORT=$LOKI_PORT" \
    "RETENTION=$RETENTION"

if [[ ! -f "$CONFIG" ]]; then
    install -m 0640 -o root -g loki "$TMP_CFG" "$CONFIG"
    push_rollback "rm -f $CONFIG"
    log info "installed $CONFIG"
elif ! cmp -s "$TMP_CFG" "$CONFIG"; then
    install -m 0640 -o root -g loki "$TMP_CFG" "$CONFIG.new"
    log warn "existing loki.yml left untouched; fresh render saved as $CONFIG.new for review"
else
    log info "loki.yml unchanged"
fi
rm -f "$TMP_CFG"

# Loki validates its own config on startup; no equivalent of promtool here.

# --- 9. systemd unit, start, verify ----------------------------------------
install_unit "$COMPONENT" "$SERVICE_DIR/loki.service.tpl"
enable_start_service "$COMPONENT"
verify_service_health "$COMPONENT" "$TARGET"

finish_install
log info "=== $COMPONENT $TARGET installed successfully ==="
log info "Loki ready endpoint: http://127.0.0.1:3100/ready"
log info "Alloy (installed next) will push logs to http://127.0.0.1:3100/loki/api/v1/push"
