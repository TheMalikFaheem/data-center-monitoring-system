#!/usr/bin/env bash
#
# uninstall.sh — cleanly remove one or all monitoring stack components.
#
# By default: stops the service, removes binary and service unit, removes
# /etc/<component>/ configs. DATA DIRECTORIES ARE PRESERVED by default.
#
# Flags:
#   --purge        also delete data directories (TSDB, Grafana, Loki, ...)
#   --keep-config  do NOT remove /etc/<component>/ config directories
#   --yes          skip the interactive confirmation prompt
#
# Usage:
#   sudo ./scripts/uninstall.sh <component>       # remove one component
#   sudo ./scripts/uninstall.sh all               # remove everything
#   sudo ./scripts/uninstall.sh all --purge       # remove everything + data
#   sudo ./scripts/uninstall.sh prometheus --purge

set -Eeuo pipefail
source "$(dirname "$(readlink -f "$0")")/common.sh"

PURGE=0
KEEP_CONFIG=0
YES=0
TARGETS=()
for arg in "$@"; do
    case "$arg" in
        --purge)       PURGE=1 ;;
        --keep-config) KEEP_CONFIG=1 ;;
        --yes)         YES=1 ;;
        -*)            log warn "unknown flag '$arg'" ;;
        *)             TARGETS+=("$arg") ;;
    esac
done

setup_error_trap
log info "=== monitoring uninstall starting ==="

require_root

if [[ ${#TARGETS[@]} -eq 0 ]]; then
    die "Usage: sudo ./scripts/uninstall.sh <component|all> [--purge] [--keep-config] [--yes]
Components: prometheus node_exporter alertmanager loki alloy grafana
            blackbox_exporter snmp_exporter process_exporter
            mysqld_exporter postgres_exporter redis_exporter
            watchdog nginx"
fi

# ---------------------------------------------------------------------------
# Component registry
# Each entry: "user config_dir data_dir binaries... (space-separated)"
# Special values: '-' means "none"
# ---------------------------------------------------------------------------
declare -A COMP_USER COMP_CONFIG COMP_DATA COMP_BINS COMP_APT COMP_SERVICE

COMP_USER[prometheus]="prometheus"
COMP_CONFIG[prometheus]="/etc/prometheus"
COMP_DATA[prometheus]="/var/lib/prometheus"
COMP_BINS[prometheus]="prometheus promtool"
COMP_APT[prometheus]=""
COMP_SERVICE[prometheus]="prometheus"

COMP_USER[node_exporter]="node_exporter"
COMP_CONFIG[node_exporter]=""
COMP_DATA[node_exporter]=""
COMP_BINS[node_exporter]="node_exporter"
COMP_APT[node_exporter]=""
COMP_SERVICE[node_exporter]="node_exporter"

COMP_USER[alertmanager]="alertmanager"
COMP_CONFIG[alertmanager]="/etc/alertmanager"
COMP_DATA[alertmanager]="/var/lib/alertmanager"
COMP_BINS[alertmanager]="alertmanager amtool"
COMP_APT[alertmanager]=""
COMP_SERVICE[alertmanager]="alertmanager"

COMP_USER[loki]="loki"
COMP_CONFIG[loki]="/etc/loki"
COMP_DATA[loki]="/var/lib/loki"
COMP_BINS[loki]="loki logcli"
COMP_APT[loki]=""
COMP_SERVICE[loki]="loki"

COMP_USER[alloy]="alloy"
COMP_CONFIG[alloy]="/etc/alloy"
COMP_DATA[alloy]="/var/lib/alloy"
COMP_BINS[alloy]="alloy"
COMP_APT[alloy]="alloy"
COMP_SERVICE[alloy]="alloy"

COMP_USER[grafana]="grafana"
COMP_CONFIG[grafana]="/etc/grafana"
COMP_DATA[grafana]="/var/lib/grafana"
COMP_BINS[grafana]="grafana grafana_bin"
COMP_APT[grafana]="grafana"
COMP_SERVICE[grafana]="grafana-server"

COMP_USER[blackbox_exporter]="blackbox_exporter"
COMP_CONFIG[blackbox_exporter]="/etc/blackbox_exporter"
COMP_DATA[blackbox_exporter]=""
COMP_BINS[blackbox_exporter]="blackbox_exporter"
COMP_APT[blackbox_exporter]=""
COMP_SERVICE[blackbox_exporter]="blackbox_exporter"

COMP_USER[snmp_exporter]="snmp_exporter"
COMP_CONFIG[snmp_exporter]="/etc/snmp_exporter"
COMP_DATA[snmp_exporter]=""
COMP_BINS[snmp_exporter]="snmp_exporter"
COMP_APT[snmp_exporter]=""
COMP_SERVICE[snmp_exporter]="snmp_exporter"

COMP_USER[process_exporter]="root"
COMP_CONFIG[process_exporter]="/etc/process_exporter"
COMP_DATA[process_exporter]=""
COMP_BINS[process_exporter]="process_exporter"
COMP_APT[process_exporter]=""
COMP_SERVICE[process_exporter]="process_exporter"

COMP_USER[mysqld_exporter]="mysqld_exporter"
COMP_CONFIG[mysqld_exporter]="/etc/mysqld_exporter"
COMP_DATA[mysqld_exporter]=""
COMP_BINS[mysqld_exporter]="mysqld_exporter"
COMP_APT[mysqld_exporter]=""
COMP_SERVICE[mysqld_exporter]="mysqld_exporter"

COMP_USER[postgres_exporter]="postgres_exporter"
COMP_CONFIG[postgres_exporter]="/etc/postgres_exporter"
COMP_DATA[postgres_exporter]=""
COMP_BINS[postgres_exporter]="postgres_exporter"
COMP_APT[postgres_exporter]=""
COMP_SERVICE[postgres_exporter]="postgres_exporter"

COMP_USER[redis_exporter]="redis_exporter"
COMP_CONFIG[redis_exporter]="/etc/redis_exporter"
COMP_DATA[redis_exporter]=""
COMP_BINS[redis_exporter]="redis_exporter redis_exporter_bin"
COMP_APT[redis_exporter]=""
COMP_SERVICE[redis_exporter]="redis_exporter"

COMP_USER[watchdog]="root"
COMP_CONFIG[watchdog]=""
COMP_DATA[watchdog]=""
COMP_BINS[watchdog]="watchdog-alert"
COMP_APT[watchdog]=""
COMP_SERVICE[watchdog]="monitoring-watchdog"

COMP_USER[nginx]="www-data"
COMP_CONFIG[nginx]="/etc/nginx/sites-available/monitoring"
COMP_DATA[nginx]=""
COMP_BINS[nginx]="nginx"
COMP_APT[nginx]="nginx"
COMP_SERVICE[nginx]="nginx"

ALL_COMPONENTS=(prometheus node_exporter alertmanager loki alloy grafana
                blackbox_exporter snmp_exporter process_exporter
                mysqld_exporter postgres_exporter redis_exporter
                watchdog nginx)

# Expand "all"
FINAL_TARGETS=()
for t in "${TARGETS[@]}"; do
    if [[ "$t" == "all" ]]; then
        FINAL_TARGETS=("${ALL_COMPONENTS[@]}")
        break
    fi
    [[ -n "${COMP_SERVICE[$t]:-}" ]] \
        || die "unknown component '$t'. Valid: ${ALL_COMPONENTS[*]}"
    FINAL_TARGETS+=("$t")
done

# --- Confirmation -----------------------------------------------------------
echo
echo "Components to remove: ${FINAL_TARGETS[*]}"
[[ $PURGE -eq 1 ]] && echo "  *** --purge: data directories WILL be deleted ***"
[[ $KEEP_CONFIG -eq 1 ]] && echo "  --keep-config: /etc/ configs will be preserved"
echo

if [[ $YES -eq 0 ]]; then
    read -r -p "Proceed? [y/N] " CONFIRM
    [[ "${CONFIRM,,}" =~ ^y ]] || { log info "cancelled"; exit 0; }
fi

# ---------------------------------------------------------------------------
# Uninstall function
# ---------------------------------------------------------------------------
uninstall_component() {
    local comp=$1
    local svc user config data bins apt_pkg

    svc="${COMP_SERVICE[$comp]}"
    user="${COMP_USER[$comp]:-}"
    config="${COMP_CONFIG[$comp]:-}"
    data="${COMP_DATA[$comp]:-}"
    bins="${COMP_BINS[$comp]:-}"
    apt_pkg="${COMP_APT[$comp]:-}"

    log info "--- uninstalling $comp ---"

    # 1. Stop and disable service
    for s in $svc "${svc}.timer"; do
        if systemctl is-active --quiet "$s" 2>/dev/null; then
            systemctl stop "$s" && log info "  stopped: $s" || true
        fi
        if systemctl is-enabled --quiet "$s" 2>/dev/null; then
            systemctl disable "$s" && log info "  disabled: $s" || true
        fi
    done

    # 2. Remove systemd unit files
    for s in $svc "${svc}.timer" "${svc}.service"; do
        for d in /etc/systemd/system /lib/systemd/system; do
            local f="$d/$s"
            [[ "$f" == *.service ]] || f="$d/${s}.service"
            # also check timer
            for ext in .service .timer ""; do
                local candidate="$d/${s}${ext}"
                if [[ -f "$candidate" ]]; then
                    rm -f "$candidate"
                    log info "  removed unit: $candidate"
                fi
            done
        done
    done

    # monitoring-watchdog has non-standard names
    if [[ "$comp" == "watchdog" ]]; then
        rm -f /etc/systemd/system/monitoring-watchdog.service \
              /etc/systemd/system/monitoring-watchdog.timer
        log info "  removed: watchdog units"
    fi

    systemctl daemon-reload

    # 3. Remove binaries from /usr/local/bin/
    for b in $bins; do
        local bpath="$BIN_DIR/$b"
        if [[ -f "$bpath" ]]; then
            rm -f "$bpath"
            log info "  removed binary: $bpath"
        fi
    done

    # 4. APT removal (alloy, grafana, nginx)
    if [[ -n "$apt_pkg" ]]; then
        if dpkg -l "$apt_pkg" 2>/dev/null | grep -q '^ii'; then
            if [[ $PURGE -eq 1 ]]; then
                apt-get purge -y "$apt_pkg" && log info "  apt purge: $apt_pkg" || true
            else
                apt-get remove -y "$apt_pkg" && log info "  apt remove: $apt_pkg" || true
            fi
        fi
        # Remove apt repo files for alloy/grafana
        case "$apt_pkg" in
            alloy)   rm -f /etc/apt/sources.list.d/grafana.list ;;
            grafana) rm -f /etc/apt/sources.list.d/grafana.list ;;
            nginx)   : ;;  # keep system nginx apt source
        esac
    fi

    # 5. Remove config directory (unless --keep-config)
    if [[ $KEEP_CONFIG -eq 0 && -n "$config" && -d "$config" ]]; then
        rm -rf "$config"
        log info "  removed config: $config"
    elif [[ $KEEP_CONFIG -eq 1 && -n "$config" && -d "$config" ]]; then
        log info "  kept config: $config (--keep-config)"
    fi

    # 6. Remove data directory ONLY with --purge
    if [[ $PURGE -eq 1 && -n "$data" && -d "$data" ]]; then
        rm -rf "$data"
        log warn "  PURGED data: $data"
    elif [[ -n "$data" && -d "$data" ]]; then
        log info "  preserved data: $data (use --purge to delete)"
    fi

    # 7. Remove system user (skip root, skip apt-managed users)
    if [[ -n "$user" && "$user" != "root" && "$user" != "www-data" \
          && -z "$apt_pkg" ]]; then
        if id "$user" &>/dev/null; then
            userdel "$user" 2>/dev/null && log info "  removed user: $user" || true
        fi
    fi

    # 8. Remove Prometheus scrape job (best-effort via comment sentinel)
    # The scrape job was added by the installer; removing it requires YAML
    # surgery which is risky. Log a note instead.
    if [[ "$comp" != "prometheus" && -f /etc/prometheus/prometheus.yml ]]; then
        local job_name
        job_name=$(grep -oP 'job_name:\s+\K\S+' \
            "/opt/monitoring/scripts/install-${comp//_/-}.sh" 2>/dev/null | head -1 || true)
        if [[ -n "$job_name" ]]; then
            log warn "  NOTE: prometheus scrape job '$job_name' still in prometheus.yml"
            log warn "        Remove the job_name: $job_name block manually if desired"
        fi
    fi

    log info "  $comp removed"
}

# ---------------------------------------------------------------------------
# Run uninstalls in reverse install order (most-dependent first)
# ---------------------------------------------------------------------------
# Reverse the target list for safe teardown
readarray -t REVERSED < <(printf '%s\n' "${FINAL_TARGETS[@]}" | tac)

for comp in "${REVERSED[@]}"; do
    uninstall_component "$comp"
done

log info "=== uninstall complete ==="
[[ $PURGE -eq 0 ]] && log info "Data directories preserved. Run with --purge to remove them."
