#!/usr/bin/env bash
#
# agent-bootstrap.sh — standalone agent installer for on-prem servers.
#
# Installs node_exporter (+ optionally Alloy for log shipping) on a target
# server. Designed to work with `curl | bash` since it is self-contained
# and does NOT source common.sh.
#
# USAGE (run on each server you want to monitor):
#
#   # Metrics only (node_exporter):
#   curl -fsSL https://raw.githubusercontent.com/TheMalikFaheem/data-center-monitoring-system/main/scripts/agent-bootstrap.sh \
#       | sudo bash
#
#   # Metrics + logs (node_exporter + Alloy → central Loki):
#   curl -fsSL https://raw.githubusercontent.com/TheMalikFaheem/data-center-monitoring-system/main/scripts/agent-bootstrap.sh \
#       | sudo bash -s -- --with-alloy --loki-url "http://YOUR_MONITOR_SERVER_IP:3100"
#                                                           ↑
#   Replace with your monitoring server IP (e.g. 192.168.1.50)
#   Find it in: configs/environment.local.yml → monitor_server_ip
#
# THEN on monitor01, add the new server to Prometheus:
#   sudo /opt/monitoring/scripts/add-agent-target.sh <new-server-ip>
#
# VERSIONS — keep in sync with configs/versions.yml on monitor01:
NODE_EXPORTER_VERSION="1.9.1"
ALLOY_VERSION="1.18.1"

set -euo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
WITH_ALLOY=0
LOKI_URL=""
NODE_LISTEN="0.0.0.0:9100"   # must be 0.0.0.0 so Prometheus can scrape it remotely

for arg in "$@"; do
    case "$arg" in
        --with-alloy)    WITH_ALLOY=1 ;;
        --loki-url=*)    LOKI_URL="${arg#--loki-url=}" ;;
        --loki-url)      : ;;  # handled by next iteration (shift not available in for)
        --listen=*)      NODE_LISTEN="${arg#--listen=}" ;;
    esac
done

# ── Helpers ──────────────────────────────────────────────────────────────────
log()  { printf '[%s] [%-5s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >&2; }
die()  { log "error" "$*"; exit 1; }
info() { log "info " "$*"; }
warn() { log "warn " "$*"; }

[[ $EUID -eq 0 ]] || die "run as root: sudo bash agent-bootstrap.sh"

BIN_DIR="/usr/local/bin"
DOWNLOAD_DIR="/var/cache/monitoring-agent"
mkdir -p "$DOWNLOAD_DIR"

# ── SHA256 verification helper ────────────────────────────────────────────────
verify_download() {
    local url="$1" dest="$2" sums_url="$3" filename
    filename=$(basename "$dest")

    if [[ ! -f "$dest" ]]; then
        info "downloading $filename..."
        curl -fsSL --retry 3 --connect-timeout 15 -o "$dest" "$url" \
            || die "download failed: $url"
    fi

    local sums_file="$DOWNLOAD_DIR/${filename}.sha256sums"
    info "verifying checksum..."
    curl -fsSL --retry 3 --connect-timeout 10 -o "$sums_file" "$sums_url" \
        || die "checksum download failed: $sums_url"

    local expected actual
    expected=$(grep " ${filename}$\| ${filename} " "$sums_file" | awk '{print $1}' | head -1)
    [[ -n "$expected" ]] || die "filename '$filename' not found in checksum file"
    actual=$(sha256sum "$dest" | awk '{print $1}')
    [[ "$expected" == "$actual" ]] || die "CHECKSUM FAILURE: $filename"
    info "checksum OK: $filename"
}

# ============================================================================
# 1. Install node_exporter
# ============================================================================
info "=== installing node_exporter $NODE_EXPORTER_VERSION ==="

NE_BASE="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}"
NE_TARBALL="node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
NE_TAR="$DOWNLOAD_DIR/$NE_TARBALL"

verify_download \
    "$NE_BASE/$NE_TARBALL" \
    "$NE_TAR" \
    "$NE_BASE/sha256sums.txt"

# Extract and install
EXTRACT=$(mktemp -d)
tar -xzf "$NE_TAR" -C "$EXTRACT" --strip-components=1
install -m 0755 -o root -g root "$EXTRACT/node_exporter" "$BIN_DIR/node_exporter"
rm -rf "$EXTRACT"
info "installed node_exporter → $BIN_DIR/node_exporter"

# Create system user
if ! id node_exporter &>/dev/null; then
    useradd -r -s /sbin/nologin -M -d /nonexistent \
        -c "node_exporter system account" node_exporter
    info "created system user 'node_exporter'"
fi

# Install systemd unit
cat > /etc/systemd/system/node_exporter.service << UNIT
[Unit]
Description=Prometheus node_exporter — managed by monitoring-agent
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=node_exporter
Group=node_exporter
ExecStart=$BIN_DIR/node_exporter --web.listen-address=$NODE_LISTEN
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now node_exporter
sleep 2
systemctl is-active --quiet node_exporter || die "node_exporter failed to start"

SERVER_IP=$(hostname -I | awk '{print $1}')
info "=== node_exporter installed: http://${SERVER_IP}:9100/metrics ==="

# ============================================================================
# 2. Install Alloy (optional — for log shipping to central Loki)
# ============================================================================
if [[ $WITH_ALLOY -eq 1 ]]; then
    [[ -n "$LOKI_URL" ]] || die "--with-alloy requires --loki-url=http://<monitor01-ip>:3100"
    info "=== installing Alloy $ALLOY_VERSION ==="

    # Detect OS family
    OS_ID=$(. /etc/os-release && echo "${ID:-}")
    case "$OS_ID" in
        ubuntu|debian)
            info "Debian/Ubuntu detected — installing Alloy via apt"
            mkdir -p /etc/apt/keyrings
            curl -fsSL https://apt.grafana.com/gpg.key \
                | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
            echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
                > /etc/apt/sources.list.d/grafana.list
            apt-get update -q
            DEBIAN_FRONTEND=noninteractive apt-get install -y "alloy=${ALLOY_VERSION}-1" \
                || DEBIAN_FRONTEND=noninteractive apt-get install -y alloy
            ;;
        almalinux|rocky|rhel|centos|fedora)
            info "RHEL/AlmaLinux detected — installing Alloy via dnf"
            if [[ ! -f /etc/yum.repos.d/grafana.repo ]]; then
                cat > /etc/yum.repos.d/grafana.repo <<'REPO'
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
exclude=*beta*
REPO
            fi
            dnf install -y "alloy-${ALLOY_VERSION}" \
                || dnf install -y alloy
            ;;
        *)
            die "unsupported OS: $OS_ID — install Alloy manually and re-run without --with-alloy"
            ;;
    esac

    # Write Alloy config — ships journald → Loki
    mkdir -p /etc/alloy
    cat > /etc/alloy/config.alloy << ALLOY_CFG
// Alloy agent config — managed by monitoring-agent bootstrap.
// Ships journald logs to central Loki at ${LOKI_URL}.

loki.write "central" {
    endpoint {
        url = "${LOKI_URL}/loki/api/v1/push"
    }
}

loki.source.journal "journald" {
    forward_to    = [loki.write.central.receiver]
    relabel_rules = loki.relabel.add_host.rules
}

loki.relabel "add_host" {
    forward_to = []
    rule {
        target_label = "host"
        replacement  = "$(hostname -s)"
    }
    rule {
        target_label = "job"
        replacement  = "agent-journald"
    }
}
ALLOY_CFG

    systemctl daemon-reload
    systemctl enable --now alloy
    sleep 2
    systemctl is-active --quiet alloy || warn "alloy may not have started — check: journalctl -u alloy"
    info "=== Alloy installed — shipping logs → ${LOKI_URL} ==="
fi


# ============================================================================
# 3. Firewall — open node_exporter port to Prometheus server
# ============================================================================
NE_PORT="${NODE_LISTEN##*:}"
if command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
    firewall-cmd --permanent --add-port="${NE_PORT}/tcp"
    firewall-cmd --reload
    info "firewalld: port ${NE_PORT}/tcp opened permanently"
elif command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow "${NE_PORT}/tcp" comment "node_exporter (Prometheus scrape)"
    info "UFW: port ${NE_PORT}/tcp opened"
else
    warn "No active firewall detected — ensure port ${NE_PORT} is reachable from your monitoring server (192.168.7.66)"
fi


# ============================================================================
# Summary
# ============================================================================
cat <<SUMMARY

╔═══════════════════════════════════════════════════════════════════╗
║  Agent bootstrap complete                                         ║
╠═══════════════════════════════════════════════════════════════════╣
║  node_exporter: http://${SERVER_IP}:${NE_PORT}/metrics
$([ $WITH_ALLOY -eq 1 ] && echo "║  Alloy → Loki:  $LOKI_URL")
╠═══════════════════════════════════════════════════════════════════╣
║  Next: on monitor01, add this server to Prometheus:               ║
║    sudo /opt/monitoring/scripts/add-agent-target.sh ${SERVER_IP}
╚═══════════════════════════════════════════════════════════════════╝

SUMMARY
