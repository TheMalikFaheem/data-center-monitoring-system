#!/usr/bin/env bash
#
# watchdog-alert.sh — fire a MonitoringStackDegraded alert directly to
# Alertmanager when the monitoring watchdog detects a failed component.
#
# This script is called by monitoring-watchdog.service when healthcheck.sh
# exits non-zero. It bypasses Prometheus entirely (because Prometheus itself
# may be the component that's down) and posts directly to the Alertmanager
# API. If Alertmanager is also down, the failure is written to a dead-letter
# file and logged to journald for systemd-based notification.
#
# Called by: monitoring-watchdog.service (ExecStart)
# Do not call directly; healthcheck.sh exit status is the trigger.
#
# Environment:
#   ALERTMANAGER_URL   default: http://127.0.0.1:9093
#   WATCHDOG_LABEL     default: monitor01 (reported as 'instance' label)

set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/common.sh"

ALERTMANAGER_URL="${ALERTMANAGER_URL:-http://127.0.0.1:9093}"
WATCHDOG_LABEL="${WATCHDOG_LABEL:-$(hostname -s 2>/dev/null || echo monitor01)}"
DEAD_LETTER="/var/log/monitoring/watchdog-dead-letter.log"

# Collect which components are unhealthy (non-zero exit from healthcheck)
FAILED_COMPONENTS=()
HEALTH_OUTPUT=""
while IFS= read -r line; do
    HEALTH_OUTPUT+="$line\n"
    # Parse lines like: "prometheus    FAIL   PASS   PASS (3.6.0)"
    if echo "$line" | grep -qE 'FAIL|error|warn'; then
        COMP=$(echo "$line" | awk '{print $1}')
        [[ -n "$COMP" ]] && FAILED_COMPONENTS+=("$COMP")
    fi
done < <("$REPO_DIR/scripts/healthcheck.sh" 2>&1 || true)

SUMMARY="monitoring components degraded on ${WATCHDOG_LABEL}"
if [[ ${#FAILED_COMPONENTS[@]} -gt 0 ]]; then
    SUMMARY="failed: ${FAILED_COMPONENTS[*]}"
fi

ALERT_JSON=$(cat <<JSON
[
  {
    "labels": {
      "alertname": "MonitoringStackDegraded",
      "severity": "critical",
      "instance": "${WATCHDOG_LABEL}",
      "job":      "monitoring-watchdog"
    },
    "annotations": {
      "summary":     "${SUMMARY}",
      "description": "The monitoring-watchdog systemd timer detected that one or more monitoring stack components are not healthy. Run: monitorctl health"
    },
    "endsAt": "$(date -u -d '+10 minutes' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
               || date -u -v +10M '+%Y-%m-%dT%H:%M:%SZ')"
  }
]
JSON
)

# --- Attempt 1: POST to Alertmanager ----------------------------------------
if curl -sf --connect-timeout 5 --max-time 10 \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$ALERT_JSON" \
    "${ALERTMANAGER_URL}/api/v2/alerts" >/dev/null 2>&1; then
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] alert posted to Alertmanager: $SUMMARY"
    exit 0
fi

# --- Attempt 2: Alertmanager is also down — dead letter ---------------------
mkdir -p "$(dirname "$DEAD_LETTER")"
{
    echo "=== $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="
    echo "Alertmanager unreachable at ${ALERTMANAGER_URL}"
    echo "Health check output:"
    printf '%b' "$HEALTH_OUTPUT"
    echo "Alert payload:"
    echo "$ALERT_JSON"
    echo
} >> "$DEAD_LETTER"

# Emit to journald so systemd can pick it up (visible in: journalctl -u monitoring-watchdog)
echo "ALERT: monitoring stack degraded — Alertmanager unreachable. See $DEAD_LETTER" >&2

# Exit 1 so systemd marks the unit as failed → administrators can see it in:
#   systemctl --failed
#   journalctl -u monitoring-watchdog --since "1 hour ago"
exit 1
