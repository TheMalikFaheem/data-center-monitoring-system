#!/usr/bin/env bash
#
# apply-inventory.sh — read configs/inventory.yml and register all targets
# into the live Prometheus configuration.
#
# Run this on monitor01 every time you update inventory.yml:
#   sudo ./scripts/apply-inventory.sh
#
# What it does:
#   - Reads every section of configs/inventory.yml
#   - Patches /etc/prometheus/prometheus.yml with real targets
#   - Validates the result with promtool
#   - Hot-reloads Prometheus (no restart, no data loss)
#   - Prints a summary of what changed

set -Eeuo pipefail
source "$(dirname "$(readlink -f "$0")")/common.sh"

setup_error_trap
require_root

INVENTORY="$REPO_DIR/configs/inventory.yml"
PROM_YML="/etc/prometheus/prometheus.yml"

[[ -f "$INVENTORY" ]] || die "configs/inventory.yml not found — create it first (see configs/inventory.yml template)"
[[ -f "$PROM_YML"  ]] || die "prometheus.yml not found — is Prometheus installed? Run: sudo ./monitorctl install prometheus"

log info "=== apply-inventory: reading $INVENTORY ==="

# ── Backup prometheus.yml ─────────────────────────────────────────────────────
BACKUP="$PROM_YML.pre-inventory.$(date +%Y%m%d%H%M%S)"
cp "$PROM_YML" "$BACKUP"
push_rollback "cp -f $BACKUP $PROM_YML"
log info "backed up prometheus.yml → $BACKUP"

CHANGED=0

# ── Helper: parse simple YAML list items ──────────────────────────────────────
# Extracts field value from inventory.yml section blocks.
# Usage: _inv_field "alias" "  - ip: 1.2.3.4\n    alias: foo\n    role: bar"
_inv_field() {
    local field="$1" block="$2"
    printf '%s\n' "$block" | grep -m1 "^[[:space:]]*${field}:" | sed "s/.*${field}:[[:space:]]*//" | tr -d '"'
}

# ── Helper: append target to a Prometheus job ─────────────────────────────────
_append_target_to_job() {
    local job="$1" target="$2" labels="$3"
    if grep -q "\"${target}\"" "$PROM_YML" 2>/dev/null; then
        log info "  target $target already in prometheus.yml — skipping"
        return 0
    fi

    local entry="
  # Added by apply-inventory.sh — $(date '+%Y-%m-%d %H:%M:%S')
  - targets: [\"${target}\"]
    labels:
${labels}"

    awk -v job="$job" -v entry="$entry" '
        /^  - job_name: / && found { print entry; found=0 }
        /^  - job_name: '"'"'?'"$job"''"'"'?$/ { found=1 }
        { print }
        END { if (found) print entry }
    ' "$PROM_YML" > "${PROM_YML}.new"
    mv "${PROM_YML}.new" "$PROM_YML"
    CHANGED=1
}

# ═════════════════════════════════════════════════════════════════════════════
# 1. NODES — Linux servers running node_exporter
# ═════════════════════════════════════════════════════════════════════════════
log info "--- processing nodes (node_exporter) ---"

# Read all node blocks from inventory.yml
IN_NODES=0
BLOCK=""
while IFS= read -r line; do
    if [[ "$line" =~ ^nodes: ]]; then
        IN_NODES=1; continue
    fi
    if [[ $IN_NODES -eq 1 ]]; then
        # Stop at next top-level section
        if [[ "$line" =~ ^[a-z] ]] && [[ ! "$line" =~ ^[[:space:]] ]]; then
            IN_NODES=0
            # Process last block
            if [[ -n "$BLOCK" ]]; then
                ip=$(_inv_field "ip" "$BLOCK")
                alias=$(_inv_field "alias" "$BLOCK")
                role=$(_inv_field "role" "$BLOCK")
                [[ -z "$ip" ]] && { BLOCK=""; continue; }
                target="${ip}:9100"
                labels="      instance: \"${alias:-$ip}\"
      role: \"${role:-server}\"
      job: node"
                log info "  node: $alias ($target)"
                _append_target_to_job "node" "$target" "$labels"
                BLOCK=""
            fi
            continue
        fi
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]ip: ]]; then
            # Process previous block before starting new one
            if [[ -n "$BLOCK" ]]; then
                ip=$(_inv_field "ip" "$BLOCK")
                alias=$(_inv_field "alias" "$BLOCK")
                role=$(_inv_field "role" "$BLOCK")
                [[ -n "$ip" ]] && {
                    target="${ip}:9100"
                    labels="      instance: \"${alias:-$ip}\"
      role: \"${role:-server}\"
      job: node"
                    log info "  node: $alias ($target)"
                    _append_target_to_job "node" "$target" "$labels"
                }
            fi
            BLOCK="$line"
        else
            BLOCK+=$'\n'"$line"
        fi
    fi
done < "$INVENTORY"
# Process final block if file ends in nodes section
if [[ $IN_NODES -eq 1 && -n "$BLOCK" ]]; then
    ip=$(_inv_field "ip" "$BLOCK")
    alias=$(_inv_field "alias" "$BLOCK")
    role=$(_inv_field "role" "$BLOCK")
    [[ -n "$ip" ]] && {
        target="${ip}:9100"
        labels="      instance: \"${alias:-$ip}\"
      role: \"${role:-server}\"
      job: node"
        log info "  node: $alias ($target)"
        _append_target_to_job "node" "$target" "$labels"
    }
fi

# ═════════════════════════════════════════════════════════════════════════════
# 2. SNMP DEVICES — switches, pfSense, iDRAC
# ═════════════════════════════════════════════════════════════════════════════
log info "--- processing SNMP devices ---"

IN_SNMP=0
BLOCK=""
while IFS= read -r line; do
    if [[ "$line" =~ ^snmp_devices: ]]; then
        IN_SNMP=1; continue
    fi
    if [[ $IN_SNMP -eq 1 ]]; then
        if [[ "$line" =~ ^[a-z] ]] && [[ ! "$line" =~ ^[[:space:]] ]]; then
            IN_SNMP=0
            if [[ -n "$BLOCK" ]]; then
                ip=$(_inv_field "ip" "$BLOCK")
                alias=$(_inv_field "alias" "$BLOCK")
                module=$(_inv_field "module" "$BLOCK")
                [[ -n "$ip" ]] && {
                    log info "  snmp: $alias ($ip) module=$module"
                    if ! grep -q "\"${ip}\"" "$PROM_YML" 2>/dev/null; then
                        SNMP_ENTRY="
  # SNMP: ${alias} — added by apply-inventory.sh $(date '+%Y-%m-%d')
  - targets: [\"${ip}\"]
    labels:
      instance: \"${alias}\"
      module: \"${module:-if_mib}\""
                        awk -v entry="$SNMP_ENTRY" '
                            /^  - job_name:.*snmp/ { found=1 }
                            found && /^  - job_name: / && !/snmp/ { print entry; found=0 }
                            { print }
                            END { if (found) print entry }
                        ' "$PROM_YML" > "${PROM_YML}.new"
                        mv "${PROM_YML}.new" "$PROM_YML"
                        CHANGED=1
                    else
                        log info "  $ip already present — skipping"
                    fi
                }
                BLOCK=""
            fi
            continue
        fi
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]ip: ]]; then
            if [[ -n "$BLOCK" ]]; then
                ip=$(_inv_field "ip" "$BLOCK")
                alias=$(_inv_field "alias" "$BLOCK")
                module=$(_inv_field "module" "$BLOCK")
                [[ -n "$ip" ]] && {
                    log info "  snmp: $alias ($ip)"
                    if ! grep -q "\"${ip}\"" "$PROM_YML" 2>/dev/null; then
                        SNMP_ENTRY="
  # SNMP: ${alias}
  - targets: [\"${ip}\"]
    labels:
      instance: \"${alias}\"
      module: \"${module:-if_mib}\""
                        awk -v entry="$SNMP_ENTRY" '
                            /^  - job_name:.*snmp/ { found=1 }
                            found && /^  - job_name: / && !/snmp/ { print entry; found=0 }
                            { print }
                            END { if (found) print entry }
                        ' "$PROM_YML" > "${PROM_YML}.new"
                        mv "${PROM_YML}.new" "$PROM_YML"
                        CHANGED=1
                    fi
                }
            fi
            BLOCK="$line"
        else
            BLOCK+=$'\n'"$line"
        fi
    fi
done < "$INVENTORY"

# ═════════════════════════════════════════════════════════════════════════════
# 3. WEBSITES — HTTP/HTTPS blackbox probes
# ═════════════════════════════════════════════════════════════════════════════
log info "--- processing websites (blackbox HTTP) ---"

IN_WEB=0
BLOCK=""
while IFS= read -r line; do
    if [[ "$line" =~ ^websites: ]]; then
        IN_WEB=1; continue
    fi
    if [[ $IN_WEB -eq 1 ]]; then
        if [[ "$line" =~ ^[a-z] ]] && [[ ! "$line" =~ ^[[:space:]] ]]; then
            IN_WEB=0
            if [[ -n "$BLOCK" ]]; then
                url=$(_inv_field "url" "$BLOCK")
                alias=$(_inv_field "alias" "$BLOCK")
                [[ -n "$url" ]] && {
                    log info "  website: $alias ($url)"
                    _append_target_to_job "blackbox_http" "$url" "      instance: \"${alias:-$url}\""
                }
                BLOCK=""
            fi
            continue
        fi
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]url: ]]; then
            if [[ -n "$BLOCK" ]]; then
                url=$(_inv_field "url" "$BLOCK")
                alias=$(_inv_field "alias" "$BLOCK")
                [[ -n "$url" ]] && {
                    log info "  website: $alias ($url)"
                    _append_target_to_job "blackbox_http" "$url" "      instance: \"${alias:-$url}\""
                }
            fi
            BLOCK="$line"
        else
            BLOCK+=$'\n'"$line"
        fi
    fi
done < "$INVENTORY"

# ═════════════════════════════════════════════════════════════════════════════
# 4. TCP PROBES
# ═════════════════════════════════════════════════════════════════════════════
log info "--- processing TCP probes (blackbox TCP) ---"

IN_TCP=0
BLOCK=""
while IFS= read -r line; do
    if [[ "$line" =~ ^tcp_probes: ]]; then
        IN_TCP=1; continue
    fi
    if [[ $IN_TCP -eq 1 ]]; then
        if [[ "$line" =~ ^[a-z] ]] && [[ ! "$line" =~ ^[[:space:]] ]]; then
            IN_TCP=0
            if [[ -n "$BLOCK" ]]; then
                host=$(_inv_field "host" "$BLOCK")
                alias=$(_inv_field "alias" "$BLOCK")
                [[ -n "$host" ]] && {
                    log info "  tcp: $alias ($host)"
                    _append_target_to_job "blackbox_tcp" "$host" "      instance: \"${alias:-$host}\""
                }
                BLOCK=""
            fi
            continue
        fi
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]host: ]]; then
            if [[ -n "$BLOCK" ]]; then
                host=$(_inv_field "host" "$BLOCK")
                alias=$(_inv_field "alias" "$BLOCK")
                [[ -n "$host" ]] && {
                    log info "  tcp: $alias ($host)"
                    _append_target_to_job "blackbox_tcp" "$host" "      instance: \"${alias:-$host}\""
                }
            fi
            BLOCK="$line"
        else
            BLOCK+=$'\n'"$line"
        fi
    fi
done < "$INVENTORY"

# ═════════════════════════════════════════════════════════════════════════════
# 5. Validate and reload
# ═════════════════════════════════════════════════════════════════════════════
log info "--- validating prometheus.yml ---"
if ! promtool check config "$PROM_YML" 2>&1; then
    log error "promtool rejected updated prometheus.yml — restoring backup"
    cp -f "$BACKUP" "$PROM_YML"
    die "apply-inventory failed — backup restored"
fi
log info "prometheus.yml valid ✓"

if [[ $CHANGED -eq 1 ]]; then
    log info "--- reloading Prometheus ---"
    PROM_LISTEN=$(get_env prometheus_listen "127.0.0.1:9090")
    if curl -sf --connect-timeout 5 -X POST \
        "http://${PROM_LISTEN}/-/reload" > /dev/null 2>&1; then
        log info "Prometheus hot-reloaded ✓"
    else
        systemctl reload prometheus 2>/dev/null \
            || systemctl restart prometheus
        log info "Prometheus reloaded via systemctl"
    fi

    log info ""
    log info "=== apply-inventory complete ==="
    log info "New targets are being scraped. Check Prometheus → Status → Targets"
    log info "SSH tunnel: ssh -L 9090:127.0.0.1:9090 root@107.170.11.210 → http://localhost:9090"
else
    log info "=== apply-inventory: no changes needed (all targets already registered) ==="
fi
