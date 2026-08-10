#!/usr/bin/env bash
#
# install-grafana.sh — install or upgrade Grafana OSS via the official signed
# Grafana apt repository, then provision datasources and dashboards.
#
# Grafana differs from the binary-based components in two ways:
#   1. Installation is via apt (same signed repo as Alloy).
#   2. Version detection uses dpkg-query, not `--version` output, because
#      Grafana's --version format differs from the Prometheus ecosystem.
#      A thin wrapper at /usr/local/bin/grafana translates it so that
#      the shared installed_version() and healthcheck.sh work correctly.
#
# What this installer does beyond the standard skeleton:
#   • Provisions Prometheus + Loki datasources (never overwrites existing)
#   • Sets up the dashboard provider pointing at /var/lib/grafana/dashboards/
#   • Downloads the Node Exporter Full dashboard (ID 1860) from grafana.com
#     (skips gracefully if offline — dashboard can be imported via UI)
#   • Configures grafana.ini: listen address from environment.yml, admin
#     password from environment.local.yml (REQUIRED — installer dies if absent)
#
#   Version:   configs/versions.yml            (grafana)
#   Settings:  configs/environment(.local).yml
#              grafana_listen           (default 127.0.0.1:3000)
#              grafana_admin_password   (REQUIRED in environment.local.yml)
#
# Usage: sudo ./scripts/install-grafana.sh [--reinstall]

set -Eeuo pipefail
source "$(dirname "$(readlink -f "$0")")/common.sh"

COMPONENT="grafana"
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
check_disk_space /var/lib 512
check_ufw

# --- 2. Resolve versions and settings --------------------------------------
TARGET=$(get_version "$COMPONENT")
LISTEN=$(get_env grafana_listen "127.0.0.1:3000")
PROMETHEUS_LISTEN=$(get_env prometheus_listen "127.0.0.1:9090")
LOKI_LISTEN=$(get_env loki_listen "127.0.0.1:3100")
SCRAPE_INTERVAL=$(get_env scrape_interval "15s")

GRAFANA_PORT="${LISTEN##*:}"
GRAFANA_ADDR="${LISTEN%%:*}"

# Admin password MUST come from environment.local.yml — it must not be
# committed. The installer dies here rather than silently using a weak default.
ADMIN_PASSWORD=$(yaml_get "$CONFIG_DIR/environment.local.yml" "grafana_admin_password" 2>/dev/null || true)
if [[ -z "$ADMIN_PASSWORD" ]]; then
    die "grafana_admin_password is not set in configs/environment.local.yml.
Add this key (gitignored) before running this installer:
  echo 'grafana_admin_password: \"your_strong_password\"' >> configs/environment.local.yml"
fi

# --- 3. Grafana version detection (dpkg-aware) -----------------------------
# The shared installed_version() function expects 'name, version X.Y.Z (...)'.
# We install a thin wrapper at /usr/local/bin/grafana to provide that format.
_grafana_installed_version() {
    dpkg-query -W -f='${Version}' grafana 2>/dev/null \
        | sed 's/[+~].*$//' \
        || true
}

CURRENT=$(_grafana_installed_version)

# --- _verify_grafana_health (defined here; called at step 14) --------------
_verify_grafana_health() {
    local url="${HEALTH_URL[grafana]}"
    local inst_ver
    if ! systemctl is-active --quiet grafana-server; then
        journalctl -u grafana-server -n 20 --no-pager >&2 || true
        die "grafana-server.service is not active — last journal lines above"
    fi
    if ! wait_for_http "$url" 30; then
        die "Grafana did not answer at $url within 30s"
    fi
    inst_ver=$(_grafana_installed_version)
    if [[ "$inst_ver" != "$TARGET" ]]; then
        die "Grafana reports version '$inst_ver', expected '$TARGET'"
    fi
    log info "grafana healthy: active, answering, version $inst_ver"
}

# --- 4. Decide what to do --------------------------------------------------
if [[ -n "$CURRENT" && $REINSTALL -eq 0 && "$CURRENT" != "$TARGET" ]]; then
    log info "upgrading $COMPONENT $CURRENT → $TARGET"
elif [[ -n "$CURRENT" && $REINSTALL -eq 0 ]]; then
    if systemctl is-enabled --quiet "grafana-server" 2>/dev/null \
       && systemctl is-active --quiet "grafana-server"; then
        log info "$COMPONENT $TARGET already installed — verifying health"
        _verify_grafana_health
        log info "nothing to do"
        exit 0
    fi
    log warn "$COMPONENT $TARGET installed but service missing/disabled/inactive — repairing"
else
    log info "installing $COMPONENT $TARGET"
fi

if [[ -z "$CURRENT" ]]; then
    check_port_free "$GRAFANA_PORT"
fi

# --- 5. Add Grafana apt repository (idempotent — shared with Alloy) --------
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
            || log warn "apt update failed — continuing"
    else
        log info "Grafana apt sources already present"
    fi
}

_add_grafana_apt_repo

# --- 6. Find exact apt version string for the pinned version ---------------
APT_VER=$(apt-cache show grafana 2>/dev/null \
    | awk -v v="$TARGET" '$1=="Version:" && $2 ~ "^"v {print $2; exit}')

if [[ -z "$APT_VER" ]]; then
    log warn "grafana $TARGET not found in apt cache — refreshing"
    DEBIAN_FRONTEND=noninteractive \
        apt-get -o DPkg::Lock::Timeout=300 update \
        || log warn "apt update failed — trying with stale cache"
    APT_VER=$(apt-cache show grafana 2>/dev/null \
        | awk -v v="$TARGET" '$1=="Version:" && $2 ~ "^"v {print $2; exit}')
fi

[[ -n "$APT_VER" ]] || die "grafana $TARGET not available in Grafana apt repo — check configs/versions.yml"
log info "resolved grafana apt version: $APT_VER"

# --- 7. Install via apt ----------------------------------------------------
log info "installing grafana=$APT_VER via apt"
DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
    apt-get -o DPkg::Lock::Timeout=300 install -y "grafana=$APT_VER" \
    || die "apt-get install grafana=$APT_VER failed"
log info "grafana $APT_VER installed via apt"

# --- 8. Install version wrapper -------------------------------------------
# Makes installed_version("grafana") and healthcheck.sh work correctly by
# emitting the standard "name, version X.Y.Z" format.
WRAPPER="$BIN_DIR/grafana"
cat > "$WRAPPER" <<'WRAPPER_EOF'
#!/usr/bin/env bash
# Grafana version wrapper for the monitoring framework.
# Installed by install-grafana.sh — do not edit by hand.
if [[ "${1:-}" == "--version" ]]; then
    ver=$(dpkg-query -W -f='${Version}' grafana 2>/dev/null | sed 's/[+~].*$//')
    echo "grafana, version ${ver:-unknown} (apt-managed)"
    exit 0
fi
exec /usr/sbin/grafana-server "$@"
WRAPPER_EOF
chmod 755 "$WRAPPER"
log info "installed grafana version wrapper → $WRAPPER"

# --- 9. Configure grafana.ini ----------------------------------------------
GRAFANA_INI="/etc/grafana/grafana.ini"
if [[ -f "$GRAFANA_INI" ]]; then
    INI_BAK="$GRAFANA_INI.pre-framework.$(date +%Y%m%d%H%M%S)"
    cp -f "$GRAFANA_INI" "$INI_BAK"
    push_rollback "cp -f $INI_BAK $GRAFANA_INI"
    log info "backed up grafana.ini → $INI_BAK"
fi

# Use Python-free ini editing with sed. The grafana.ini file uses standard
# INI format; we set only the keys that must change from defaults.
# Each sed targets the specific key under its section to avoid false matches.
_ini_set() {
    local section="$1" key="$2" value="$3"
    # If the key exists (commented or not), replace it; otherwise append to section.
    if grep -qE "^;?${key}\s*=" "$GRAFANA_INI"; then
        sed -i -E "s|^;?(${key}\s*=.*)$|${key} = ${value}|" "$GRAFANA_INI"
    else
        sed -i "/^\[${section}\]/a ${key} = ${value}" "$GRAFANA_INI"
    fi
}

# Bind to loopback only.
_ini_set "server" "http_addr" "$GRAFANA_ADDR"
_ini_set "server" "http_port" "$GRAFANA_PORT"

# Set admin password from environment.local.yml.
_ini_set "security" "admin_password" "$ADMIN_PASSWORD"

# Disable anonymous access and Grafana's own analytics/telemetry.
_ini_set "auth.anonymous" "enabled" "false"
_ini_set "analytics" "reporting_enabled" "false"
_ini_set "analytics" "check_for_updates" "false"

log info "grafana.ini configured"

# --- 10. Provision datasources ---------------------------------------------
PROV_DS_DIR="/etc/grafana/provisioning/datasources"
PROV_DS="$PROV_DS_DIR/monitoring.yml"
TMP_DS=$(mktemp)

render_template \
    "$TEMPLATE_DIR/grafana-provisioning/datasources.yml.tpl" \
    "$TMP_DS" \
    "PROMETHEUS_URL=$PROMETHEUS_LISTEN" \
    "LOKI_URL=$LOKI_LISTEN" \
    "SCRAPE_INTERVAL=$SCRAPE_INTERVAL"

mkdir -p "$PROV_DS_DIR"
if [[ ! -f "$PROV_DS" ]] || ! cmp -s "$TMP_DS" "$PROV_DS"; then
    install -m 0640 -o root -g grafana "$TMP_DS" "$PROV_DS" \
        || install -m 0640 -o root -g root "$TMP_DS" "$PROV_DS"
    log info "installed datasource provisioning → $PROV_DS"
else
    log info "datasource provisioning unchanged"
fi
rm -f "$TMP_DS"

# --- 11. Provision dashboard provider --------------------------------------
PROV_DASH_DIR="/etc/grafana/provisioning/dashboards"
PROV_DASH="$PROV_DASH_DIR/monitoring.yml"
mkdir -p "$PROV_DASH_DIR"

if [[ ! -f "$PROV_DASH" ]] || ! cmp -s "$TEMPLATE_DIR/grafana-provisioning/dashboards.yml" "$PROV_DASH"; then
    install -m 0640 -o root -g grafana \
        "$TEMPLATE_DIR/grafana-provisioning/dashboards.yml" \
        "$PROV_DASH" \
        || install -m 0640 -o root -g root \
            "$TEMPLATE_DIR/grafana-provisioning/dashboards.yml" \
            "$PROV_DASH"
    log info "installed dashboard provisioning → $PROV_DASH"
fi

# --- 12. Download Node Exporter Full dashboard (ID 1860) -------------------
DASH_DIR="/var/lib/grafana/dashboards"
mkdir -p "$DASH_DIR"
chown grafana:grafana "$DASH_DIR" 2>/dev/null || chown root:root "$DASH_DIR"

DASH_FILE="$DASH_DIR/node-exporter-full.json"
if [[ ! -f "$DASH_FILE" ]]; then
    log info "downloading Node Exporter Full dashboard (grafana.com ID 1860)"
    if curl -fsSL --retry 2 --connect-timeout 10 \
        "https://grafana.com/api/dashboards/1860/revisions/latest/download" \
        -o "$DASH_FILE"; then
        chown grafana:grafana "$DASH_FILE" 2>/dev/null || true
        log info "Node Exporter Full dashboard installed → $DASH_FILE"
    else
        log warn "dashboard download failed (offline?) — import manually from grafana.com ID 1860"
        rm -f "$DASH_FILE"
    fi
else
    log info "Node Exporter Full dashboard already present"
fi

# --- 13. Enable and start the apt-provided service -------------------------
if systemctl is-enabled --quiet "grafana-server" 2>/dev/null; then
    push_rollback "systemctl stop grafana-server"
    systemctl restart grafana-server
else
    push_rollback "systemctl disable --now grafana-server"
    systemctl enable --now grafana-server
fi
log info "grafana-server.service enabled and started"

# --- 14. Health check -------------------------------------------------------
_verify_grafana_health

finish_install
log info "=== $COMPONENT $TARGET installed successfully ==="
log info "Grafana UI: ssh -L 3000:127.0.0.1:3000 root@<server_ip> → http://localhost:3000"
log info "Login: admin / <your grafana_admin_password from environment.local.yml>"
log info "Datasources (Prometheus + Loki) are auto-provisioned."
log info "Node Exporter Full dashboard is pre-loaded under Dashboards → Browse."
