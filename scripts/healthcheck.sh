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
source "$(dirname "$(readlink -f "$0")")/common.sh"

# Deliberately NOT `set -e`: failing checks are results to report, not
# reasons to abort.

COMPONENTS=(prometheus node_exporter alertmanager grafana loki alloy
            blackbox_exporter snmp_exporter process_exporter
            mysqld_exporter postgres_exporter redis_exporter)
if [[ -n "${1:-}" ]]; then
    if [[ -z "${HEALTH_URL[$1]:-}" ]]; then
        echo "unknown component '$1' — valid: ${!HEALTH_URL[*]}" >&2
        exit 2
    fi
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
    # Asking about a specific component that isn't installed is a failure
    # (a watchdog must not report green); an empty no-arg scan is just news.
    if [[ -n "${1:-}" ]]; then
        echo "'$1' is not installed — run: monitorctl install $1" >&2
        exit 2
    fi
    echo "no components installed yet — run: monitorctl install <component>"
fi

exit $fail
