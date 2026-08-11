#!/usr/bin/env bash
#
# add-agent-target.sh — register a new monitored server in Prometheus.
#
# Run this on monitor01 AFTER running agent-bootstrap.sh on the new server.
#
# Usage:
#   sudo ./scripts/add-agent-target.sh <server-ip> [--label key=value ...] [--alias name]
#
# Examples:
#   sudo ./scripts/add-agent-target.sh 10.0.0.50
#   sudo ./scripts/add-agent-target.sh 10.0.0.50 --alias web01
#   sudo ./scripts/add-agent-target.sh 10.0.0.50 --alias db01 --label env=production
#
# What it does:
#   - Appends the server to the node_exporter scrape job in prometheus.yml
#   - Validates the updated config with promtool
#   - Reloads Prometheus (hot reload — no restart, no data loss)
#   - Verifies the new target appears in Prometheus targets API

set -Eeuo pipefail
source "$(dirname "$(readlink -f "$0")")/common.sh"

setup_error_trap
require_root

# ── Parse arguments ──────────────────────────────────────────────────────────
TARGET_IP=""
ALIAS=""
EXTRA_LABELS=()
NE_PORT="9100"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --alias)    ALIAS="$2"; shift 2 ;;
        --alias=*)  ALIAS="${1#--alias=}"; shift ;;
        --port)     NE_PORT="$2"; shift 2 ;;
        --port=*)   NE_PORT="${1#--port=}"; shift ;;
        --label)    EXTRA_LABELS+=("$2"); shift 2 ;;
        --label=*)  EXTRA_LABELS+=("${1#--label=}"); shift ;;
        -*)         log warn "unknown flag '$1'" ; shift ;;
        *)
            if [[ -z "$TARGET_IP" ]]; then
                TARGET_IP="$1"
            fi
            shift
            ;;
    esac
done

[[ -n "$TARGET_IP" ]] || die "Usage: sudo ./scripts/add-agent-target.sh <server-ip> [--alias name]"

PROM_YML="/etc/prometheus/prometheus.yml"
[[ -f "$PROM_YML" ]] || die "prometheus.yml not found at $PROM_YML — is Prometheus installed?"

ALIAS="${ALIAS:-$TARGET_IP}"
TARGET="${TARGET_IP}:${NE_PORT}"

log info "=== adding agent target: $TARGET (alias: $ALIAS) ==="

# ── Check the target isn't already registered ─────────────────────────────────
if grep -q "$TARGET" "$PROM_YML" 2>/dev/null; then
    log info "target $TARGET is already in prometheus.yml — nothing to do"
    exit 0
fi

# ── Verify the target is reachable before adding it ──────────────────────────
log info "checking connectivity to $TARGET..."
if curl -sf --connect-timeout 5 "http://${TARGET}/metrics" > /dev/null 2>&1; then
    log info "target reachable: http://${TARGET}/metrics ✓"
else
    log warn "cannot reach http://${TARGET}/metrics — adding anyway (check firewall/agent)"
fi

# ── Back up prometheus.yml ────────────────────────────────────────────────────
BACKUP="$PROM_YML.pre-add-${ALIAS}.$(date +%Y%m%d%H%M%S)"
cp "$PROM_YML" "$BACKUP"
push_rollback "cp -f $BACKUP $PROM_YML"
log info "backed up prometheus.yml → $BACKUP"

# ── Find the node_exporter job and append the new target ─────────────────────
# We look for the node job's static_configs and append the new target.
# Strategy: find the line with 'job_name: node' and insert our target into
# the static_configs targets list of that job. We use awk for safe insertion.

# Build the label string for the new target
INSTANCE_LABEL="instance: \"$ALIAS\""

# Build extra labels YAML (indented 8 spaces to match static_configs)
EXTRA_LABEL_YAML=""
for label in "${EXTRA_LABELS[@]}"; do
    key="${label%%=*}"
    val="${label#*=}"
    EXTRA_LABEL_YAML+="\n          ${key}: \"${val}\""
done

# Append a new static_configs entry to the node job.
# This is safer than trying to patch an existing targets: list because
# the exact format may vary.
NEW_ENTRY="
  # Agent: ${ALIAS} (${TARGET_IP}) — added $(date '+%Y-%m-%d %H:%M:%S') by add-agent-target.sh
  - targets: [\"${TARGET}\"]
    labels:
      instance: \"${ALIAS}\"
      job: node${EXTRA_LABEL_YAML}"

# Find the node job block and append after it.
# We use awk to insert our new static_config entry right before the next
# top-level `- job_name:` or end of file, inside the node job block.
awk -v new_entry="$NEW_ENTRY" '
    /^  - job_name: node$/ { in_node=1 }
    in_node && /^  - job_name: / && !/^  - job_name: node$/ {
        print new_entry
        in_node=0
    }
    { print }
    END { if (in_node) print new_entry }
' "$PROM_YML" > "${PROM_YML}.new"

mv "${PROM_YML}.new" "$PROM_YML"
log info "target $TARGET added to prometheus.yml"

# ── Validate with promtool ────────────────────────────────────────────────────
log info "validating prometheus.yml with promtool..."
if ! promtool check config "$PROM_YML" 2>&1; then
    log error "promtool rejected the updated prometheus.yml — restoring backup"
    cp -f "$BACKUP" "$PROM_YML"
    pop_rollback
    die "add-agent-target failed — backup restored"
fi
log info "prometheus.yml valid ✓"

# ── Hot reload Prometheus ─────────────────────────────────────────────────────
PROM_LISTEN=$(yaml_get "$CONFIG_DIR/environment.yml" "prometheus_listen" 2>/dev/null || echo "127.0.0.1:9090")
if curl -sf --connect-timeout 5 -X POST \
    "http://${PROM_LISTEN}/-/reload" > /dev/null 2>&1; then
    log info "Prometheus hot-reloaded — target '$ALIAS' now active"
else
    # Fallback: signal-based reload
    systemctl reload prometheus 2>/dev/null \
        || systemctl restart prometheus
    log info "Prometheus reloaded via systemctl"
fi

pop_rollback  # backup is no longer needed as rollback

# ── Wait and verify target appears in Prometheus ──────────────────────────────
log info "waiting for target to appear in Prometheus (~10s)..."
sleep 10

STATE=$(curl -s "http://${PROM_LISTEN}/api/v1/targets" 2>/dev/null \
    | grep -o "\"instance\":\"${TARGET}\"" | head -1 || true)

if [[ -n "$STATE" ]]; then
    log info "=== target $ALIAS ($TARGET) is now active in Prometheus ✓ ==="
else
    log warn "target not yet visible in Prometheus API — it may take one more scrape cycle (15s)"
    log warn "check: curl http://${PROM_LISTEN}/api/v1/targets | grep $TARGET_IP"
fi

log info ""
log info "View metrics: http://${PROM_LISTEN}/targets"
log info "In Grafana:   Dashboards → Node Exporter Full → select instance='$ALIAS'"
