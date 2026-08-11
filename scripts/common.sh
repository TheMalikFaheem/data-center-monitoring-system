#!/usr/bin/env bash
#
# common.sh — shared library for the monitoring platform installers.
#
# Source this file, never execute it:
#   source "$(dirname "$0")/common.sh"
#
# Every function here is used by more than one script. Component-specific
# logic belongs in the install-<component>.sh scripts, not here.
#
# Scripts that source this library must set:  set -Eeuo pipefail
# (the -E is required so the ERR trap installed by setup_error_trap also
# fires for failures inside functions).

# Refuse direct execution — this file only makes sense when sourced.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "common.sh is a library — source it, don't run it" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="$REPO_DIR/configs"
TEMPLATE_DIR="$REPO_DIR/templates"
SERVICE_DIR="$REPO_DIR/services"
DOWNLOAD_DIR="$REPO_DIR/.downloads"   # tarball cache — survives re-runs, gitignored
ROLLBACK_DIR="$REPO_DIR/.rollback"    # previous binaries parked here during upgrades
BIN_DIR="/usr/local/bin"
LOG_DIR="/var/log/monitoring"
LOG_FILE="$LOG_DIR/install.log"

# ---------------------------------------------------------------------------
# Health endpoints — one entry per component the framework knows about.
# Always 127.0.0.1, never "localhost": localhost may resolve to ::1 while
# our services bind IPv4 only. node_exporter has no /-/healthy endpoint;
# a 200 from /metrics is its health check.
# ---------------------------------------------------------------------------
declare -A HEALTH_URL=(
    [prometheus]="http://127.0.0.1:9090/-/healthy"
    [node_exporter]="http://127.0.0.1:9100/metrics"
    [alertmanager]="http://127.0.0.1:9093/-/healthy"
    [grafana]="http://127.0.0.1:3000/api/health"
    [loki]="http://127.0.0.1:3100/ready"
    [alloy]="http://127.0.0.1:12345/-/ready"
    [blackbox_exporter]="http://127.0.0.1:9115/metrics"
    [snmp_exporter]="http://127.0.0.1:9116/metrics"
    [process_exporter]="http://127.0.0.1:9256/metrics"
    # Phase 3 — database exporters
    [mysqld_exporter]="http://127.0.0.1:9104/metrics"
    [postgres_exporter]="http://127.0.0.1:9187/metrics"
    [redis_exporter]="http://127.0.0.1:9121/metrics"
)

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
# log <info|warn|error> <message...>
# Prints to stderr (colored on a terminal) and appends to the install log
# when running with enough privilege. Unprivileged read-only commands
# (healthcheck, monitorctl versions) just skip the file quietly.
log() {
    local level=$1; shift
    local ts color='' reset=''
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    if [[ -t 2 ]]; then
        case $level in
            info)  color='\033[0;32m' ;;
            warn)  color='\033[0;33m' ;;
            error) color='\033[0;31m' ;;
        esac
        reset='\033[0m'
    fi
    printf '%b[%s] [%-5s]%b %s\n' "$color" "$ts" "$level" "$reset" "$*" >&2
    if mkdir -p "$LOG_DIR" 2>/dev/null && [[ -w "$LOG_DIR" ]]; then
        printf '[%s] [%-5s] %s\n' "$ts" "$level" "$*" >> "$LOG_FILE"
    fi
}

# die <message...> — log an error, run any pending rollback, and exit.
die() {
    log error "$@"
    # Inside a command substitution we are in a subshell: the parent's
    # rollback stack is not ours to run (running our copy would double-execute
    # it). Just exit; the parent's ERR trap does the one authoritative rollback.
    if (( BASH_SUBSHELL > 0 )); then
        exit 1
    fi
    run_rollback
    exit 1
}

# ---------------------------------------------------------------------------
# Rollback
#
# "Clean rollback" means: on failure, system files return to their pre-run
# state; user data only ever survives. Each state-changing helper pushes an
# undo command ONLY for changes it actually made this run — pre-existing
# users, directories, data and configs are never rolled back.
# ---------------------------------------------------------------------------
declare -a _ROLLBACK=()
declare -a _TMPDIRS=()

push_rollback() { _ROLLBACK+=("$*"); }

# pop_rollback — remove the most recently pushed rollback step.
# Use when you've already executed the undo action inline and don't
# want the error trap to run it again (e.g. restart after quiesce copy).
pop_rollback() {
    if (( ${#_ROLLBACK[@]} > 0 )); then
        unset '_ROLLBACK[-1]'
    fi
}

run_rollback() {
    local n=${#_ROLLBACK[@]} i
    if (( n > 0 )); then
        log warn "rolling back $n step(s), most recent first"
        for (( i = n - 1; i >= 0; i-- )); do
            log warn "  undo: ${_ROLLBACK[i]}"
            eval "${_ROLLBACK[i]}" || log warn "  rollback step failed — continuing"
        done
        _ROLLBACK=()
    fi
    _cleanup_tmpdirs
}

_cleanup_tmpdirs() {
    local d
    for d in "${_TMPDIRS[@]}"; do
        rm -rf "$d"
    done
    _TMPDIRS=()
}

setup_error_trap() {
    trap '_rc=$?; log error "aborted (exit $_rc) at ${BASH_SOURCE[0]}:${LINENO}"; run_rollback; exit $_rc' ERR
}

# Call once at the very end of a successful install: disarms the trap,
# forgets the undo stack, removes temp dirs.
finish_install() {
    trap - ERR
    _ROLLBACK=()
    _cleanup_tmpdirs
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "this command must run as root (try: sudo $0)"
    fi
}

require_ubuntu_2404() {
    if [[ "${FORCE_OS:-0}" == "1" ]]; then
        log warn "FORCE_OS=1 set — skipping OS check"
        return 0
    fi
    if [[ ! -r /etc/os-release ]]; then
        die "/etc/os-release not found — is this even Linux?"
    fi
    local id version arch
    id=$(. /etc/os-release && echo "$ID")
    version=$(. /etc/os-release && echo "$VERSION_ID")
    if [[ "$id" != "ubuntu" || "$version" != "24.04" ]]; then
        die "this framework targets Ubuntu 24.04 (found: $id $version) — set FORCE_OS=1 to override"
    fi
    arch=$(dpkg --print-architecture)
    if [[ "$arch" != "amd64" ]]; then
        die "this framework downloads linux-amd64 binaries (found arch: $arch)"
    fi
}

# require_commands <cmd...> — installs missing ones via apt. The command name
# is used as the package name, which holds for everything we need (curl, tar,
# unzip); base tools like sha256sum missing would mean a broken system anyway.
require_commands() {
    local missing=() cmd
    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    if (( ${#missing[@]} == 0 )); then
        return 0
    fi
    log warn "missing commands: ${missing[*]} — installing via apt"
    # Lists on fresh cloud images can be weeks stale; superseded .debs 404.
    # Best-effort refresh (warn, don't die): the install below is the real gate.
    DEBIAN_FRONTEND=noninteractive \
        apt-get -o DPkg::Lock::Timeout=300 update \
        || log warn "apt-get update failed — trying install with existing package lists"
    # DPkg::Lock::Timeout: fresh droplets often run unattended-upgrades at
    # boot; wait for the lock instead of failing. NEEDRESTART_MODE=a stops
    # Ubuntu 24.04's interactive "restart services?" dialog.
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
        apt-get -o DPkg::Lock::Timeout=300 install -y "${missing[@]}" \
        || die "failed to apt-install: ${missing[*]}"
}

# check_port_free <port> — die if something already listens there, naming the
# process (classic surprise: cockpit already owning 9090).
check_port_free() {
    local port=$1 out
    out=$(ss -tlnpH "sport = :$port" 2>/dev/null || true)
    if [[ -n "$out" ]]; then
        die "port $port is already in use: $out"
    fi
}

# check_disk_space <path> <min_mb>
check_disk_space() {
    local path=$1 min_mb=$2 avail_mb
    avail_mb=$(df -Pm "$path" | awk 'NR==2 {print $4}')
    if (( avail_mb < min_mb )); then
        die "not enough disk space on $path: ${avail_mb}MB free, need ${min_mb}MB"
    fi
}

# Warn (don't fail) if the clock is not NTP-synced — Prometheus timestamps
# every sample with the local clock, so a skewed clock poisons the data.
check_time_sync() {
    local synced
    synced=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)
    if [[ "$synced" != "yes" ]]; then
        log warn "system clock is not NTP-synchronized — fix this (chrony) before trusting metrics"
    fi
}

# Report UFW state. We never enable UFW from a script: enabling a firewall
# over SSH without an OpenSSH allow rule locks you out. See docs/runbook.md.
check_ufw() {
    if ! command -v ufw >/dev/null 2>&1; then
        log warn "ufw not installed — services bind 127.0.0.1, but install ufw as a backstop"
        return 0
    fi
    local status
    status=$(ufw status 2>/dev/null || true)
    if ! grep -q "Status: active" <<<"$status"; then
        log warn "ufw is inactive — enable it manually after 'ufw allow OpenSSH' (see docs/runbook.md)"
    fi
}

# ---------------------------------------------------------------------------
# Config parsing and templating
# ---------------------------------------------------------------------------
# yaml_get <file> <key>
# The configs/*.yml files are constrained to FLAT `key: "value"` lines (see
# their header comments) so we need no yq/python dependency. Handles double
# quotes, values containing ':' (listen addresses), and trailing comments on
# unquoted values. Returns 1 if the key is absent.
yaml_get() {
    local file=$1 key=$2 val
    if [[ ! -r "$file" ]]; then
        return 1
    fi
    val=$(awk -v k="$key" '
        $0 ~ "^" k "[[:space:]]*:" {
            line = $0
            sub(/^[^:]*:[[:space:]]*/, "", line)
            if (line ~ /^"/) { sub(/^"/, "", line); sub(/".*$/, "", line) }
            else             { sub(/[[:space:]]*#.*$/, "", line)
                               sub(/[[:space:]]+$/, "", line) }
            print line
            exit
        }' "$file")
    if [[ -z "$val" ]]; then
        return 1
    fi
    printf '%s\n' "$val"
}

# get_version <component> → pinned version from versions.yml, or die.
get_version() {
    local component=$1 v
    v=$(yaml_get "$CONFIG_DIR/versions.yml" "$component") \
        || die "no version pinned for '$component' in configs/versions.yml"
    printf '%s\n' "$v"
}

# get_env <key> [default] — environment.local.yml (per-server, gitignored)
# overrides environment.yml (tracked defaults); falls back to <default>.
get_env() {
    local key=$1 default=${2-__nodefault__} v
    if v=$(yaml_get "$CONFIG_DIR/environment.local.yml" "$key"); then
        printf '%s\n' "$v"
        return 0
    fi
    if v=$(yaml_get "$CONFIG_DIR/environment.yml" "$key"); then
        printf '%s\n' "$v"
        return 0
    fi
    if [[ "$default" != "__nodefault__" ]]; then
        printf '%s\n' "$default"
        return 0
    fi
    die "no value for '$key' in configs/environment(.local).yml and no default given"
}

# render_template <template> <dest> KEY=VALUE...
# Replaces {{KEY}} tokens. Deliberately NOT envsubst: Prometheus/Alertmanager
# configs legitimately contain literal '$' and Go '{{ }}' templating, which
# envsubst would silently mangle. Dies if any {{TOKEN}} is left unrendered.
render_template() {
    local src=$1 dest=$2; shift 2
    if [[ ! -r "$src" ]]; then
        die "template not found: $src"
    fi
    local content kv
    content=$(<"$src")
    for kv in "$@"; do
        # The replacement MUST be quoted: bash 5.2's patsub_replacement (on by
        # default) would otherwise expand '&' in the value to the matched token.
        content=${content//"{{${kv%%=*}}}"/"${kv#*=}"}
    done
    if grep -Eq '\{\{[A-Z_]+\}\}' <<<"$content"; then
        die "unrendered {{TOKEN}} left after rendering $src — missing a KEY=VALUE argument?"
    fi
    printf '%s\n' "$content" > "$dest"
}

# ---------------------------------------------------------------------------
# Download, verify, extract
# ---------------------------------------------------------------------------
download_file() {
    local url=$1 dest=$2
    log info "downloading $(basename "$dest")"
    curl -fsSL --retry 3 --connect-timeout 10 -o "$dest" "$url" \
        || die "download failed: $url"
}

# _sha256_matches <file> <sums_file> — quiet check; rc 1 on missing entry or
# mismatch. sha256sums files list "HASH  FILENAME" (binary-mode entries may
# prefix the name with '*').
_sha256_matches() {
    local file=$1 sums=$2 expected actual
    expected=$(awk -v f="$(basename "$file")" '$2 == f || $2 == ("*" f) {print $1; exit}' "$sums")
    if [[ -z "$expected" ]]; then
        return 1
    fi
    actual=$(sha256sum "$file" | awk '{print $1}')
    [[ "$expected" == "$actual" ]]
}

verify_sha256() {
    local file=$1 sums=$2
    if ! _sha256_matches "$file" "$sums"; then
        die "CHECKSUM FAILURE for $(basename "$file") against $(basename "$sums") — refusing to install"
    fi
    log info "checksum OK: $(basename "$file")"
}

# fetch_and_verify <tarball_url> <sums_url>
# Downloads (or reuses a cached copy of) a release tarball, verifies it
# against the project's published sha256sums file, prints the local path.
# The sums file is always fetched fresh; a corrupt cached tarball is
# discarded and re-downloaded once.
fetch_and_verify() {
    local tarball_url=$1 sums_url=$2
    local tarball="$DOWNLOAD_DIR/$(basename "$tarball_url")"
    local sums="$DOWNLOAD_DIR/$(basename "$tarball_url").sha256sums"
    mkdir -p "$DOWNLOAD_DIR"
    download_file "$sums_url" "$sums"
    if [[ -f "$tarball" ]] && _sha256_matches "$tarball" "$sums"; then
        log info "using cached $(basename "$tarball") (checksum OK)"
    else
        rm -f "$tarball"
        download_file "$tarball_url" "$tarball"
        verify_sha256 "$tarball" "$sums"
    fi
    printf '%s\n' "$tarball"
}

# extract_tarball <tarball> <out_varname> — extracts into a temp dir (cleaned
# up on both success and rollback) and stores the single top-level directory
# in the named variable. Call it DIRECTLY, never via $(...): a command
# substitution runs in a subshell, where the _TMPDIRS bookkeeping (and any
# die → rollback) would be lost.
extract_tarball() {
    local tarball=$1 tmp topdir
    local -n _extract_out=$2
    tmp=$(mktemp -d /tmp/monitoring-extract.XXXXXX)
    _TMPDIRS+=("$tmp")
    tar -xzf "$tarball" -C "$tmp" || die "failed to extract $(basename "$tarball")"
    topdir=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d -print -quit)
    if [[ -z "$topdir" ]]; then
        die "unexpected layout inside $(basename "$tarball")"
    fi
    _extract_out=$topdir
}

# ---------------------------------------------------------------------------
# System state changes (all idempotent, all rollback-aware)
# ---------------------------------------------------------------------------
create_system_user() {
    local user=$1
    if getent passwd "$user" >/dev/null; then
        log info "system user '$user' already exists"
        return 0
    fi
    useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$user" \
        || die "failed to create system user '$user'"
    push_rollback "userdel $user"
    log info "created system user '$user'"
}

# create_dir <path> <owner[:group]> <mode>
# Only a directory created by THIS run is removed on rollback; pre-existing
# directories (and any data in them) are never touched.
create_dir() {
    local path=$1 owner=$2 mode=$3
    if [[ ! -d "$path" ]]; then
        mkdir -p "$path"
        push_rollback "rm -rf $path"
    fi
    chown "$owner" "$path"
    chmod "$mode" "$path"
}

# install_binary <src_path> <name> — installs into /usr/local/bin. A binary
# being replaced is parked in .rollback/ first, so a failed upgrade restores
# the previous version.
install_binary() {
    local src=$1 name=$2 oldver
    if [[ -e "$BIN_DIR/$name" ]]; then
        oldver=$(installed_version "$name")
        mkdir -p "$ROLLBACK_DIR"
        cp -f "$BIN_DIR/$name" "$ROLLBACK_DIR/$name-${oldver:-unknown}"
        push_rollback "cp -f $ROLLBACK_DIR/$name-${oldver:-unknown} $BIN_DIR/$name"
        log info "parked previous $name (${oldver:-unknown}) in .rollback/"
    else
        push_rollback "rm -f $BIN_DIR/$name"
    fi
    install -m 0755 -o root -g root "$src" "$BIN_DIR/$name" || die "failed to install $name"
    log info "installed $name → $BIN_DIR/$name"
}

# install_unit <service_name> <template> KEY=VALUE...
# Renders the systemd unit template. An existing, differing unit is backed up
# (and restored on rollback); an identical unit is left alone.
install_unit() {
    local name=$1 template=$2; shift 2
    local unit="/etc/systemd/system/$name.service" tmp bak
    tmp=$(mktemp)
    render_template "$template" "$tmp" "$@"
    if [[ -f "$unit" ]]; then
        if cmp -s "$tmp" "$unit"; then
            rm -f "$tmp"
            log info "$name.service unchanged"
            return 0
        fi
        bak="$unit.bak.$(date +%Y%m%d%H%M%S)"
        cp -f "$unit" "$bak"
        push_rollback "cp -f $bak $unit && systemctl daemon-reload"
        log info "existing $name.service backed up to $bak"
    else
        push_rollback "rm -f $unit && systemctl daemon-reload"
    fi
    install -m 0644 -o root -g root "$tmp" "$unit"
    rm -f "$tmp"
    systemctl daemon-reload
    log info "installed $name.service"
}

enable_start_service() {
    local name=$1
    if systemctl is-enabled "$name" >/dev/null 2>&1; then
        # The stop undo matters on upgrades: without it, a failed post-restart
        # health gate would restore the old binary on disk while the NEW
        # process kept running (the installers' "systemctl start" undo is a
        # no-op on an active unit). Popping this stop first kills the new
        # process, so the restored old binary genuinely starts afterwards.
        push_rollback "systemctl stop $name"
        systemctl restart "$name"
    else
        push_rollback "systemctl disable --now $name"
        systemctl enable --now "$name"
    fi
    log info "$name.service enabled and started"
}

# ---------------------------------------------------------------------------
# Health and versions
# ---------------------------------------------------------------------------
# wait_for_http <url> [timeout_s] — poll until the URL answers 2xx.
wait_for_http() {
    local url=$1 timeout=${2:-30} waited=0
    while ! curl -fsS -m 2 -o /dev/null "$url" 2>/dev/null; do
        sleep 1
        waited=$(( waited + 1 ))
        if (( waited >= timeout )); then
            return 1
        fi
    done
    return 0
}

# installed_version <binary> — prints "3.6.0", or nothing if the binary is
# absent OR broken; ALWAYS exits 0 so set -e callers treat "broken" exactly
# like "not installed" (an interrupted install must be repairable by a
# re-run, not a dead end). Every Prometheus-ecosystem binary prints
# "name, version X.Y.Z (...)" as the first line of --version output.
installed_version() {
    local bin=$1 exe out
    # Prefer the fixed install path: cron/systemd PATH often lacks
    # /usr/local/bin, which would misreport installed components as missing.
    exe="$BIN_DIR/$bin"
    if [[ ! -f "$exe" || ! -x "$exe" ]]; then
        exe=$(command -v "$bin") || return 0
    fi
    # Scan ALL fields of the first output line for a semver-shaped token
    # (X.Y.Z or X.Y with optional v/V prefix). This handles:
    #   - Prometheus ecosystem: "name, version 3.6.0 (...)"  → field 3 = "3.6.0"
    #   - redis_exporter:       "redis_exporter version v1.80.0 (go...)" → field 3
    #   - Any binary where the version happens to be at a different position
    # The awk regex anchors on ^ and $ so partial token matches (e.g.
    # "127.0.0.1:9121") are not accepted as version strings.
    out=$({ "$exe" --version 2>&1 || true; } | awk '
        NR==1 {
            for (i = 1; i <= NF; i++) {
                t = $i
                sub(/^[Vv]/, "", t)   # strip leading V or v
                if (t ~ /^[0-9]+[.][0-9]+([.][0-9]+)?$/) { print t; exit }
            }
        }
    ')
    # Only emit something version-shaped — bash error text would otherwise be
    # parsed as a version.
    if [[ "$out" =~ ^[0-9]+\.[0-9]+ ]]; then
        printf '%s\n' "$out"
    fi
    return 0
}

# verify_service_health <component> <expected_version>
# The shared post-install gate: unit active, health endpoint answering,
# installed version matches the pin. Component name == binary name ==
# systemd service name for everything the framework installs.
verify_service_health() {
    local component=$1 expected=$2 actual
    if ! systemctl is-active --quiet "$component"; then
        journalctl -u "$component" -n 20 --no-pager >&2 || true
        die "$component.service is not active — last journal lines above"
    fi
    if ! wait_for_http "${HEALTH_URL[$component]}" 30; then
        die "$component did not answer at ${HEALTH_URL[$component]} within 30s"
    fi
    actual=$(installed_version "$component")
    if [[ "$actual" != "$expected" ]]; then
        die "$component reports version '$actual', expected '$expected'"
    fi
    log info "$component healthy: active, answering, version $actual"
}

# ---------------------------------------------------------------------------
# Prometheus scrape job registration
# ---------------------------------------------------------------------------
# add_prometheus_scrape_job <job_name> — reads YAML config from stdin and
# appends it to /etc/prometheus/prometheus.yml if the job is not already
# registered. Validates with promtool and reloads Prometheus.
#
# Since scrape_configs: is the last top-level key in prometheus.yml, YAML
# list items appended at EOF are valid and become part of that sequence.
#
# Usage (heredoc ensures proper indentation):
#   add_prometheus_scrape_job "my_job" <<'YAML'
#
#     - job_name: my_job
#       static_configs:
#         - targets: ['127.0.0.1:9999']
#   YAML
add_prometheus_scrape_job() {
    local job_name="$1"
    local config prom_config="/etc/prometheus/prometheus.yml"
    config=$(cat)   # read the YAML snippet from stdin

    if [[ ! -f "$prom_config" ]]; then
        log warn "prometheus.yml not found at $prom_config — skipping scrape job '$job_name'"
        log warn "Install Prometheus first, then re-run: monitorctl install ${job_name%_*}"
        return 0
    fi

    if grep -q "job_name: ${job_name}" "$prom_config" 2>/dev/null; then
        log info "prometheus scrape job '$job_name' already registered — skipping"
        return 0
    fi

    log info "registering prometheus scrape job: $job_name"
    local bak="$prom_config.pre-${job_name}.$(date +%Y%m%d%H%M%S)"
    cp -f "$prom_config" "$bak"

    # Append the config block at EOF (valid YAML: scrape_configs is last key)
    printf '%s\n' "$config" >> "$prom_config"

    if ! promtool check config "$prom_config"; then
        cp -f "$bak" "$prom_config"
        die "promtool rejected prometheus.yml after adding '$job_name' — original restored from $bak"
    fi

    if systemctl is-active --quiet prometheus 2>/dev/null; then
        systemctl reload prometheus
        log info "prometheus reloaded — scrape job '$job_name' now active"
    else
        log warn "prometheus not running — '$job_name' added to config but not yet reloaded"
    fi
}
