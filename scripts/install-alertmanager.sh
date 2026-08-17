#!/usr/bin/env bash
#
# install-alertmanager.sh — install or upgrade Alertmanager as a native systemd
# service, then wire Prometheus → Alertmanager:
#   • creates /etc/prometheus/rules/ and installs host alert rules
#   • patches the running prometheus.yml to add the alerting: block and rule_files
#   • reloads Prometheus so rules take effect without a restart
#
#   Version:   configs/versions.yml            (alertmanager)
#   Settings:  configs/environment(.local).yml (alertmanager_listen)
#
# Usage: sudo ./scripts/install-alertmanager.sh [--reinstall]

set -Eeuo pipefail
source "$(dirname "$(readlink -f "$0")")/common.sh"

COMPONENT="alertmanager"
REINSTALL=0
if [[ "${1:-}" == "--reinstall" ]]; then
    REINSTALL=1
fi

setup_error_trap
log info "=== $COMPONENT installer starting ==="

# --- 1. Preflight ----------------------------------------------------------
require_root
require_ubuntu_2404
require_commands curl tar sha256sum promtool
# amtool is NOT a separate apt package — it ships inside the alertmanager
# tarball and is installed by install_binary() at step 7 below.
check_disk_space /var/lib 512
check_time_sync
check_ufw

# --- 2. Resolve versions and settings --------------------------------------
TARGET=$(get_version "$COMPONENT")
CURRENT=$(installed_version "$COMPONENT")
LISTEN=$(get_env alertmanager_listen "127.0.0.1:9093")

# --- _wire_prometheus_alertmanager (defined here; called at step 10) -------
# Idempotent: installs alert rules and patches prometheus.yml to add the
# alerting: block and rule_files entry, then reloads Prometheus.
_wire_prometheus_alertmanager() {
    local prom_config="/etc/prometheus/prometheus.yml"
    local rules_dir="/etc/prometheus/rules"

    # ── Install alert rules ───────────────────────────────────────────────
    if [[ ! -d "$rules_dir" ]]; then
        mkdir -p "$rules_dir"
        chown root:prometheus "$rules_dir"
        chmod 750 "$rules_dir"
        log info "created $rules_dir"
    fi

    # Install all rule files from templates/rules/
    for rules_src in "$TEMPLATE_DIR"/rules/*.yml; do
        [[ -e "$rules_src" ]] || continue
        local rules_dest="$rules_dir/$(basename "$rules_src")"
        if [[ ! -f "$rules_dest" ]] || ! cmp -s "$rules_src" "$rules_dest"; then
            install -m 0640 -o root -g prometheus "$rules_src" "$rules_dest"
            log info "installed alert rules → $rules_dest"
        else
            log info "$(basename "$rules_src") unchanged"
        fi
    done

    # ── Patch prometheus.yml ──────────────────────────────────────────────
    if [[ ! -f "$prom_config" ]]; then
        log warn "prometheus.yml not found at $prom_config — skipping Prometheus wiring"
        log warn "Run 'monitorctl install prometheus' first, then re-run this installer."
        return 0
    fi

    local already_wired=0
    grep -q 'rules/\*\.yml\|rules/host\.rules' "$prom_config" 2>/dev/null \
        && grep -q '9093' "$prom_config" 2>/dev/null \
        && already_wired=1

    if [[ $already_wired -eq 1 ]]; then
        log info "prometheus.yml already contains alertmanager config — skipping patch"
        return 0
    fi

    log info "patching prometheus.yml: adding rule_files and alerting block"
    local bak="$prom_config.pre-alertmanager.$(date +%Y%m%d%H%M%S)"
    cp -f "$prom_config" "$bak"
    push_rollback "cp -f $bak $prom_config && systemctl reload prometheus"

    # Replace `rule_files: []` with the directory glob.
    # The sed uses a literal newline (\n) which GNU sed supports.
    sed -i "s|^rule_files: \[\]|rule_files:\n  - /etc/prometheus/rules/*.yml|" "$prom_config"

    # Uncomment the alerting block (lines written by install-prometheus.sh
    # from the template's Phase 2 comment block).
    sed -i 's|^# alerting:|alerting:|' "$prom_config"
    sed -i 's|^#   alertmanagers:|  alertmanagers:|' "$prom_config"
    sed -i 's|^#     - static_configs:|    - static_configs:|' "$prom_config"
    sed -i 's|^#         - targets: \["127.0.0.1:9093"\]|        - targets: ["127.0.0.1:9093"]|' "$prom_config"

    # Validate — if promtool rejects the patch, restore and die.
    if ! promtool check config "$prom_config"; then
        cp -f "$bak" "$prom_config"
        die "promtool rejected patched prometheus.yml — original restored from $bak"
    fi

    # Reload Prometheus (no restart — data and scrape state are preserved).
    if systemctl is-active --quiet prometheus; then
        systemctl reload prometheus
        log info "Prometheus reloaded — alertmanager + rule_files now active"
    else
        log warn "prometheus.service is not running — config patched but not reloaded"
        log warn "Start Prometheus, then: promtool check config $prom_config && systemctl reload prometheus"
    fi
}

# --- 3. Decide what to do --------------------------------------------------
if [[ -n "$CURRENT" && $REINSTALL -eq 0 && "$CURRENT" != "$TARGET" ]]; then
    log info "upgrading $COMPONENT $CURRENT → $TARGET"
elif [[ -n "$CURRENT" && $REINSTALL -eq 0 ]]; then
    if systemctl is-enabled --quiet "$COMPONENT" 2>/dev/null \
       && systemctl is-active --quiet "$COMPONENT"; then
        log info "$COMPONENT $TARGET already installed — verifying health"
        verify_service_health "$COMPONENT" "$TARGET"
        # Still run the prometheus wiring in case it was skipped previously
        _wire_prometheus_alertmanager
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
BASE="https://github.com/prometheus/alertmanager/releases/download/v${TARGET}"
TARBALL=$(fetch_and_verify \
    "$BASE/alertmanager-${TARGET}.linux-amd64.tar.gz" \
    "$BASE/sha256sums.txt")

# --- 5. User and directories -----------------------------------------------
create_system_user "$COMPONENT"
create_dir /etc/alertmanager "root:alertmanager" 0750
create_dir /var/lib/alertmanager "alertmanager:alertmanager" 0750

# --- 6. Stop running service before swapping binary ------------------------
if systemctl is-active --quiet "$COMPONENT"; then
    systemctl stop "$COMPONENT"
    push_rollback "systemctl start $COMPONENT"
fi

# --- 7. Install binaries ---------------------------------------------------
extract_tarball "$TARBALL" EXTRACTED
install_binary "$EXTRACTED/alertmanager" "alertmanager"
install_binary "$EXTRACTED/amtool"       "amtool"

# --- 8. Configuration ------------------------------------------------------
CONFIG="/etc/alertmanager/alertmanager.yml"
TMP_CFG=$(mktemp)

# alertmanager.yml.tpl contains stub {{TOKEN}} placeholders for optional channels.
# We render with empty stubs for the commented-out tokens (they stay commented).
# The real values come from environment.local.yml when the operator fills them in.
render_template "$TEMPLATE_DIR/alertmanager.yml.tpl" "$TMP_CFG" \
    "SMTP_SMARTHOST=$(get_env smtp_smarthost "smtp.example.com:587")" \
    "SMTP_FROM=$(get_env smtp_from "alertmanager@example.com")" \
    "SMTP_AUTH_USER=$(get_env smtp_auth_username "alertmanager@example.com")" \
    "SMTP_AUTH_PASSWORD=$(get_env smtp_auth_password "changeme")" \
    "ALERT_EMAIL_TO=$(get_env alert_email_to "admin@example.com")" \
    "TELEGRAM_BOT_TOKEN=$(get_env telegram_bot_token "")" \
    "TELEGRAM_CHAT_ID=$(get_env telegram_chat_id "0")"

if [[ ! -f "$CONFIG" ]]; then
    install -m 0640 -o root -g alertmanager "$TMP_CFG" "$CONFIG"
    push_rollback "rm -f $CONFIG"
    log info "installed $CONFIG"
elif ! cmp -s "$TMP_CFG" "$CONFIG"; then
    install -m 0640 -o root -g alertmanager "$TMP_CFG" "$CONFIG.new"
    log warn "existing alertmanager.yml left untouched; fresh render saved as $CONFIG.new for review"
else
    log info "alertmanager.yml unchanged"
fi
rm -f "$TMP_CFG"

# Validate before (re)starting.
amtool check-config "$CONFIG" || die "amtool rejected $CONFIG — fix the config before starting"

# --- 9. systemd unit, start, verify ----------------------------------------
install_unit "$COMPONENT" "$SERVICE_DIR/alertmanager.service.tpl" \
    "LISTEN=$LISTEN"
enable_start_service "$COMPONENT"
verify_service_health "$COMPONENT" "$TARGET"

# --- 10. Wire Prometheus → Alertmanager ------------------------------------
_wire_prometheus_alertmanager

finish_install
log info "=== $COMPONENT $TARGET installed successfully ==="
log info "Alertmanager UI: ssh -L 9093:127.0.0.1:9093 root@<server_ip> → http://localhost:9093"
log info "To enable notifications: fill in configs/environment.local.yml and re-run this installer"
