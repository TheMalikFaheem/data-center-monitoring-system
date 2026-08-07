#!/usr/bin/env bash
#
# healthcheck.sh — read-only health status of every installed component.
# Safe to run unprivileged; changes nothing. Exit code 0 only if every
# check passes (which makes this cron/watchdog-friendly later).
#
# Usage: ./scripts/healthcheck.sh [component]
#
# A component counts as "installed" when the framework's unit file exists
# at /etc/systemd/system/<component>.service.

set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

# Deliberately NOT `set -e`: failing checks are results to report, not
# reasons to abort.

COMPONENTS=(prometheus node_exporter alertmanager grafana loki alloy
            blackbox_exporter snmp_exporter process_exporter)
if [[ -n "${1:-}" ]]; then
    COMPONENTS=("$1")
fi

fail=0
found=0
printf '%-20s %-8s %-8s %s\n' "COMPONENT" "ACTIVE" "HTTP" "VERSION"

for c in "${COMPONENTS[@]}"; do
    [[ -f "/etc/systemd/system/$c.service" ]] || continue
    found=1

    active="PASS"
    systemctl is-active --quiet "$c" || { active="FAIL"; fail=1; }

    http="PASS"
    url=${HEALTH_URL[$c]:-}
    if [[ -n "$url" ]]; then
        curl -fsS -m 3 -o /dev/null "$url" 2>/dev/null || { http="FAIL"; fail=1; }
    else
        http="-"
    fi

    pinned=$(yaml_get "$CONFIG_DIR/versions.yml" "$c") || pinned=""
    inst=$(installed_version "$c")
    if [[ -z "$inst" ]]; then
        ver="FAIL (binary missing)"; fail=1
    elif [[ -z "$pinned" ]]; then
        ver="$inst (no pin)"
    elif [[ "$inst" == "$pinned" ]]; then
        ver="PASS ($inst)"
    else
        ver="FAIL ($inst, pinned $pinned)"; fail=1
    fi

    printf '%-20s %-8s %-8s %s\n' "$c" "$active" "$http" "$ver"
done

if [[ $found -eq 0 ]]; then
    echo "no components installed yet — run: monitorctl install <component>"
fi

exit $fail
