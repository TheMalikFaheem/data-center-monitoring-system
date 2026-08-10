#!/usr/bin/env bash
#
# install-alloy.sh — install or upgrade Grafana Alloy as a systemd service
# via Grafana's official signed apt repository.
#
# Alloy is the log/metrics shipping agent that replaces Promtail. It reads
# the systemd journal and pushes log streams to Loki.
#
# Unlike the binary installers, Alloy is managed by apt. The installer:
#   • adds the Grafana apt repo and GPG key (idempotent)
#   • installs Alloy at the pinned version
#   • renders /etc/alloy/config.alloy from the template
#   • uses the apt-provided systemd unit (no custom unit template)
#
# VERSION PIN NOTES:
#   apt versions often have a suffix (e.g. "1.11.1-1"). We install the
#   version whose apt string STARTS WITH the pinned version. installed_version
#   uses `alloy --version` → "alloy, version 1.11.1 (...)" — field $3 = X.Y.Z,
#   which matches the pin as stored in versions.yml.
#
#   Version:   configs/versions.yml            (alloy)
#   Settings:  configs/environment(.local).yml (loki_listen)
#
# Usage: sudo ./scripts/install-alloy.sh [--reinstall]

set -Eeuo pipefail
source "$(dirname "$(readlink -f "$0")")/common.sh"

COMPONENT="alloy"
REINSTALL=0
if [[ "${1:-}" == "--reinstall" ]]; then
    REINSTALL=1
fi

setup_error_trap
log info "=== $COMPONENT installer starting ==="

# --- 1. Preflight ----------------------------------------------------------
require_root
require_ubuntu_2404
require_commands curl gpg
check_disk_space /var/lib 256
check_ufw

# --- 2. Resolve versions and settings --------------------------------------
TARGET=$(get_version "$COMPONENT")
CURRENT=$(installed_version "$COMPONENT")
LOKI_LISTEN=$(get_env loki_listen "127.0.0.1:3100")

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

# --- 4. Add Grafana apt repository (idempotent) ----------------------------
_add_grafana_apt_repo() {
    local keyring="/etc/apt/keyrings/grafana.gpg"
    local sources="/etc/apt/sources.list.d/grafana.list"

    if [[ ! -f "$keyring" ]]; then
        log info "adding Grafana apt GPG key"
        mkdir -p /etc/apt/keyrings
        curl -fsSL --retry 3 --connect-timeout 10 \
            "https://apt.grafana.com/gpg.key" \
            | gpg --dearmor -o "$keyring" \
            || die "failed to download Grafana GPG key"
        chmod 644 "$keyring"
        push_rollback "rm -f $keyring"
        log info "Grafana GPG key installed → $keyring"
    else
        log info "Grafana GPG key already present"
    fi

    if [[ ! -f "$sources" ]]; then
        log info "adding Grafana apt sources"
        cat > "$sources" <<'EOF'
deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main
EOF
        push_rollback "rm -f $sources"
        DEBIAN_FRONTEND=noninteractive \
            apt-get -o DPkg::Lock::Timeout=300 update \
            || log warn "apt update failed after adding Grafana repo — continuing"
        log info "Grafana apt sources added → $sources"
    else
        log info "Grafana apt sources already present"
    fi
}

_add_grafana_apt_repo

# --- 5. Find exact apt version string for the pinned version ---------------
# apt version strings may have a suffix (e.g. "1.11.1-1"). We look for an
# apt version that starts with the pinned version and use it for pinned install.
APT_VER=$(apt-cache show alloy 2>/dev/null \
    | awk -v v="$TARGET" '$1=="Version:" && $2 ~ "^"v {print $2; exit}')

if [[ -z "$APT_VER" ]]; then
    # Refresh and retry once — the cache may predate the repo addition.
    log warn "alloy $TARGET not found in apt cache — refreshing"
    DEBIAN_FRONTEND=noninteractive \
        apt-get -o DPkg::Lock::Timeout=300 update \
        || log warn "apt update failed — trying with stale cache"
    APT_VER=$(apt-cache show alloy 2>/dev/null \
        | awk -v v="$TARGET" '$1=="Version:" && $2 ~ "^"v {print $2; exit}')
fi

if [[ -z "$APT_VER" ]]; then
    die "alloy $TARGET not available in Grafana apt repo — check configs/versions.yml"
fi
log info "resolved alloy apt version: $APT_VER"

# --- 6. Install via apt ----------------------------------------------------
log info "installing alloy=$APT_VER via apt"
DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
    apt-get -o DPkg::Lock::Timeout=300 install -y "alloy=$APT_VER" \
    || die "apt-get install alloy=$APT_VER failed"

# apt provides /usr/bin/alloy. The framework's installed_version() checks
# /usr/local/bin/ first then falls back to PATH, so it will find /usr/bin/alloy.
log info "alloy $APT_VER installed via apt"

# --- 7. Render Alloy config ------------------------------------------------
CONFIG="/etc/alloy/config.alloy"
TMP_CFG=$(mktemp)
render_template "$TEMPLATE_DIR/alloy-config.alloy.tpl" "$TMP_CFG" \
    "HOSTNAME=$(hostname)" \
    "LOKI_URL=$LOKI_LISTEN"

if [[ ! -f "$CONFIG" ]]; then
    # The apt package may create a placeholder config; replace it.
    install -m 0640 -o root -g alloy "$TMP_CFG" "$CONFIG" \
        || install -m 0640 -o root -g root "$TMP_CFG" "$CONFIG"
    log info "installed $CONFIG"
elif ! cmp -s "$TMP_CFG" "$CONFIG"; then
    install -m 0640 -o root -g alloy "$TMP_CFG" "$CONFIG.new" \
        || install -m 0640 -o root -g root "$TMP_CFG" "$CONFIG.new"
    log warn "existing config.alloy left untouched; fresh render saved as $CONFIG.new for review"
else
    log info "config.alloy unchanged"
fi
rm -f "$TMP_CFG"

# --- 8. Enable and start the apt-provided service --------------------------
# The apt package installs alloy.service; we just enable and (re)start it.
if systemctl is-enabled --quiet "$COMPONENT" 2>/dev/null; then
    push_rollback "systemctl stop $COMPONENT"
    systemctl restart "$COMPONENT"
else
    push_rollback "systemctl disable --now $COMPONENT"
    systemctl enable --now "$COMPONENT"
fi
log info "$COMPONENT.service enabled and started"

# --- 9. Health check -------------------------------------------------------
verify_service_health "$COMPONENT" "$TARGET"

finish_install
log info "=== $COMPONENT $TARGET installed successfully ==="
log info "Alloy UI: ssh -L 12345:127.0.0.1:12345 root@<server_ip> → http://localhost:12345"
log info "Alloy is shipping journald logs to Loki at http://$LOKI_LISTEN"
