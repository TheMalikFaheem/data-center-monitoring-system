# 🔧 Configuration Guide — What You Need to Change
**Every value you must replace, in which file, at which line, and what to put there.**

> ⚠️ Read this top to bottom before deploying. It covers everything you need to fill in.

---

## TWO FILES. THAT'S IT.

| File | Where | Contains | In Git? |
|---|---|---|---|
| `configs/inventory.yml` | Your Mac + monitoring server | Device IPs, website URLs | ✅ Yes — no secrets |
| `configs/environment.local.yml` | Monitoring server ONLY | Passwords, tokens, credentials | ❌ No — gitignored, never push |

---

## STEP 0 — Assign a Static LAN IP to the Monitoring Server

Before anything else, your monitoring server needs a fixed IP on your LAN so it never changes.

**In pfSense:**
1. On the monitoring server, find the MAC address:
   ```bash
   ip link show | grep "link/ether"
   ```
2. pfSense web UI → **Services → DHCP Server → LAN**
3. Scroll to **DHCP Static Mappings** → **Add**
4. Enter the MAC address → assign a fixed IP (e.g. `192.168.1.50`)
5. Click Save → Apply Changes

---

## STEP 1 — Set the Monitor Server IP (the one value that ties everything together)

**File:** `configs/environment.local.yml` on the monitoring server  
**Create this file** if it doesn't exist:
```bash
nano /opt/monitoring/configs/environment.local.yml
```

Add this **first**:
```yaml
# ── THE MOST IMPORTANT VALUE ──────────────────────────────────────────────────
# The LAN IP of this monitoring server. Used in SSH tunnel hints and Loki URLs.
monitor_server_ip: "192.168.1.50"    # ← PUT YOUR MONITORING SERVER LAN IP HERE
```

This is the only value referenced throughout the codebase. Change it once here — done.

---

## STEP 2 — Edit `configs/inventory.yml` — Your Real Device IPs & URLs

**File:** [`configs/inventory.yml`](file:///Users/malikfaheemahmad/Documents/data-center-monitoring/configs/inventory.yml)  
Edit on your Mac → `git push` → `git pull` on the monitoring server.

---

### 2A — Linux Servers & Proxmox Hosts
**Lines 37–51** — your LAN IPs for each server:

```yaml
# BEFORE (placeholder):            AFTER (your real values):
  - ip: 10.0.0.10                    - ip: 192.168.1.10     ← Proxmox host 1 LAN IP
    alias: proxmox01                   alias: proxmox01      ← any name, no spaces
    role: hypervisor                   role: hypervisor

  - ip: 10.0.0.11                    - ip: 192.168.1.11     ← Proxmox host 2 LAN IP
    alias: proxmox02                   alias: proxmox02
    role: hypervisor                   role: hypervisor

  - ip: 10.0.0.20                    - ip: 192.168.1.20     ← App server LAN IP
    alias: app01                       alias: app-server-01
    role: app                          role: app

  - ip: 10.0.0.21                    - ip: 192.168.1.30     ← DB server LAN IP
    alias: db01                        alias: db-server-01
    role: db                           role: db
```

> ℹ️ For each server here, you must also run `agent-bootstrap.sh` on that server (Step 5 below).

---

### 2B — pfSense Firewall
**Line 87** — your pfSense LAN interface IP:

```yaml
# BEFORE:                            AFTER:
  - ip: 10.0.0.1                       - ip: 192.168.1.1   ← pfSense LAN IP (usually ends in .1)
    alias: pfsense                       alias: pfsense
    module: if_mib                       module: if_mib
```

---

### 2C — Network Switches
**Lines 93–99** — your switch management IPs:

```yaml
# BEFORE:                            AFTER:
  - ip: 10.0.0.2                       - ip: 192.168.1.2   ← core switch management IP
    alias: core-switch-01                alias: core-switch-01
    module: if_mib                       module: if_mib     ← keep for generic/HP/Cisco
                                                            ← use "cisco" for Cisco-specific
                                                            ← use "mikrotik" for MikroTik

  - ip: 10.0.0.3                       - ip: 192.168.1.3   ← second switch (delete if only one)
    alias: access-switch-01              alias: access-switch-01
    module: if_mib                       module: if_mib
```

---

### 2D — Dell iDRAC (Hardware Health Monitoring)
**Lines 106–110** — your iDRAC management IPs:

```yaml
# BEFORE:                            AFTER:
  - ip: 10.0.0.100                     - ip: 192.168.2.100  ← iDRAC management IP
    alias: idrac-server01                alias: idrac-dell01  ← any name
    module: idrac                        module: idrac        ← always "idrac"

  - ip: 10.0.0.101                     - ip: 192.168.2.101  ← second iDRAC (delete if one server)
    alias: idrac-server02                alias: idrac-dell02
    module: idrac                        module: idrac
```

> ⚠️ The iDRAC IP is **NOT** the server's regular LAN IP. It's a separate IP on the dedicated iDRAC/management port. Find it in: iDRAC Settings → Network, or check your network switch for the iDRAC port MAC.

---

### 2E — Websites & HTTPS Endpoints
**Lines 131–137** — your real URLs:

```yaml
# BEFORE:                            AFTER:
  - url: https://yourdomain.com          - url: https://yourcompany.com
    alias: main-website                    alias: main-website

  - url: https://yourapp.com             - url: https://app.yourcompany.com
    alias: web-app                         alias: web-app

  - url: https://yourapp.com/health      - url: https://api.yourcompany.com/health
    alias: web-app-health                  alias: api-health
```

> ℹ️ Works for any HTTPS URL. Checks: HTTP response (must be 2xx), response time, SSL cert expiry.

---

### 2F — TCP Port Probes
**Lines 155–161** — your database/service server IPs:

```yaml
# BEFORE:                            AFTER:
  - host: 10.0.0.20:3306               - host: 192.168.1.30:3306   ← MySQL server IP
    alias: mysql-prod                    alias: mysql-prod

  - host: 10.0.0.21:5432               - host: 192.168.1.31:5432   ← PostgreSQL server IP
    alias: postgres-prod                 alias: postgres-prod

  - host: 10.0.0.20:6379               - host: 192.168.1.30:6379   ← Redis server IP
    alias: redis-prod                    alias: redis-prod
```

---

### 2G — Database Section (bottom of inventory.yml)
**Lines 192, 198, 204** — same IPs, no port:

```yaml
# BEFORE:                            AFTER:
databases:
  mysql:
    enabled: true
    host: 10.0.0.20                    host: 192.168.1.30   ← MySQL server IP

  postgresql:
    enabled: true
    host: 10.0.0.21                    host: 192.168.1.31   ← PostgreSQL server IP

  redis:
    enabled: true
    host: 10.0.0.20                    host: 192.168.1.30   ← Redis server IP
```

---

## STEP 3 — Complete `environment.local.yml` on the Monitoring Server

Add all of the following to `/opt/monitoring/configs/environment.local.yml`:

```yaml
# ─────────────────────────────────────────────────────────────────────────────
# environment.local.yml — stays on this server only, NEVER pushed to GitHub
# ─────────────────────────────────────────────────────────────────────────────

# ── The monitoring server's own LAN IP ─────────────────────────────────────
monitor_server_ip: "192.168.1.50"          # ← YOUR MONITORING SERVER LAN IP

# ── Grafana admin login ──────────────────────────────────────────────────────
grafana_admin_password: "ChooseAStrongPassword123!"
# Rules: min 8 chars, mix letters+numbers. You'll use this to log into Grafana.

# ── Telegram alerts ─────────────────────────────────────────────────────────
# HOW TO SET UP:
#   1. Open Telegram → search @BotFather → /newbot → follow steps
#   2. Copy the token it gives you (format: 1234567890:ABCdef...)
#   3. Send a message to your new bot
#   4. Open in browser: https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates
#   5. Find "chat":{"id": -123456789} — that number is the chat_id
#      (negative = group chat, positive = direct message to you)
telegram_bot_token: "YOUR_TELEGRAM_BOT_TOKEN_HERE"
telegram_chat_id: "YOUR_TELEGRAM_CHAT_ID_HERE"

# ── MySQL monitoring credentials ────────────────────────────────────────────
# First create the user on your MySQL server (run in MySQL):
#   CREATE USER 'exporter'@'%' IDENTIFIED BY 'choose_a_password';
#   GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'exporter'@'%';
#   FLUSH PRIVILEGES;
mysql_dsn: "exporter:YOUR_MYSQL_EXPORTER_PASSWORD@tcp(YOUR_MYSQL_SERVER_IP:3306)/"
# Example: "exporter:MyPass123@tcp(192.168.1.30:3306)/"

# ── PostgreSQL monitoring credentials ───────────────────────────────────────
# First create the user on your PostgreSQL server (run in psql):
#   CREATE USER exporter WITH PASSWORD 'choose_a_password';
#   GRANT pg_monitor TO exporter;
postgres_dsn: "postgresql://exporter:YOUR_POSTGRES_EXPORTER_PASSWORD@YOUR_POSTGRES_SERVER_IP:5432/postgres?sslmode=disable"
# Example: "postgresql://exporter:MyPass123@192.168.1.31:5432/postgres?sslmode=disable"

# ── Redis monitoring ─────────────────────────────────────────────────────────
# No password (default Redis):
redis_addr: "redis://YOUR_REDIS_SERVER_IP:6379"
# With password (if requirepass is set in redis.conf):
# redis_addr: "redis://:YOUR_REDIS_PASSWORD@YOUR_REDIS_SERVER_IP:6379"
# Example: "redis://192.168.1.30:6379"

# ── nginx / HTTPS — OPTIONAL ─────────────────────────────────────────────────
# You DON'T need this for a local LAN setup. Skip it.
# Only add these if you want the dashboards accessible via a URL on your LAN
# using an internal domain (e.g. monitor.local or monitor.yourdomain.com).
# nginx_domain: "monitor.yourdomain.com"
# nginx_admin_user: "admin"
# nginx_admin_password: "ChooseAStrongPassword!"
```

---

## STEP 4 — Apply Everything on the Monitoring Server

```bash
cd /opt/monitoring

# Pull latest code
git pull --ff-only

# Fill in inventory.yml with real IPs (from Step 2), then:
sudo ./scripts/apply-inventory.sh

# Deploy remaining components
sudo ./monitorctl install grafana
sudo ./monitorctl install alloy
sudo ./monitorctl install watchdog

# Wire Telegram into alertmanager
sudo ./monitorctl install alertmanager --reinstall

# Verify all components are healthy
./monitorctl health
```

---

## STEP 5 — Onboard Each Linux Server (Proxmox, app servers, DB servers)

Run this command **on each server** (not on the monitoring server):

```bash
# Metrics only (node_exporter):
curl -fsSL https://raw.githubusercontent.com/TheMalikFaheem/data-center-monitoring-system/main/scripts/agent-bootstrap.sh \
    | sudo bash

# Metrics + logs (node_exporter + Alloy for log shipping):
curl -fsSL https://raw.githubusercontent.com/TheMalikFaheem/data-center-monitoring-system/main/scripts/agent-bootstrap.sh \
    | sudo bash -s -- --with-alloy --loki-url "http://192.168.1.50:3100"
#                                                        ↑
#                               Replace with your monitoring server LAN IP
```

After running on all servers, back on the monitoring server:
```bash
sudo ./scripts/apply-inventory.sh
```

---

## STEP 6 — Enable SNMP on Network Devices

### pfSense
1. pfSense web UI → **Services → SNMP**
2. ✅ Enable
3. Community String: `public`
4. Bind Interface: `LAN`
5. Save

### Cisco Switch
```
configure terminal
snmp-server community public RO
end
write memory
```

### HP / Aruba Switch
```
snmp-server community public
write memory
```

### Dell iDRAC
1. iDRAC web UI → **iDRAC Settings → Connectivity → SNMP**
2. ✅ SNMP Agent: Enabled
3. SNMP Protocol: SNMPv2
4. Community Name: `public`
5. Apply

---

## STEP 7 — Access Grafana (SSH Tunnel)

Since all services are loopback-only, access them via SSH tunnel from your workstation:

```bash
# Open tunnels (run on your workstation/Mac):
ssh -L 3000:127.0.0.1:3000 \
    -L 9090:127.0.0.1:9090 \
    -L 9093:127.0.0.1:9093 \
    root@192.168.1.50      # ← your monitoring server LAN IP

# Then open in browser:
# Grafana:      http://localhost:3000  (login: admin / your grafana_admin_password)
# Prometheus:   http://localhost:9090
# Alertmanager: http://localhost:9093
```

---

## STEP 8 — Verify Everything Works

```bash
# On the monitoring server:
./monitorctl health                # all PASS

# Check Prometheus sees all your devices:
curl -s 'http://127.0.0.1:9090/api/v1/targets' \
    | python3 -m json.tool | grep '"health"'
# Every target should show: "health":"up"

# Send a test Telegram alert:
curl -XPOST http://127.0.0.1:9093/api/v2/alerts \
  -H 'Content-Type: application/json' \
  -d '[{"labels":{"alertname":"TestAlert","severity":"warning","instance":"monitoring-server"},"annotations":{"summary":"Test alert — safe to ignore"}}]'
# → You should receive a Telegram message within 30 seconds
```

---

## ✅ Summary — Complete Checklist

```
□ Assign static LAN IP to monitoring server (pfSense DHCP reservation)
□ Set monitor_server_ip in environment.local.yml
□ Fill in inventory.yml — device IPs and website URLs
□ Set grafana_admin_password in environment.local.yml
□ Set telegram_bot_token + telegram_chat_id in environment.local.yml
□ Set mysql_dsn in environment.local.yml (if monitoring MySQL)
□ Set postgres_dsn in environment.local.yml (if monitoring PostgreSQL)
□ Set redis_addr in environment.local.yml (if monitoring Redis)
□ Run: sudo ./scripts/apply-inventory.sh
□ Run: sudo ./monitorctl install grafana alloy watchdog
□ Run: sudo ./monitorctl install alertmanager --reinstall
□ Run agent-bootstrap.sh on each Linux/Proxmox server
□ Enable SNMP on pfSense, switches, iDRAC
□ Verify: ./monitorctl health → all PASS
□ Test Telegram alert fires
```
