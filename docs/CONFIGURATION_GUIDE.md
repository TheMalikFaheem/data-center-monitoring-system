# 🔧 Configuration Guide — What You Need to Change
**Every value you must replace, in which file, at which line, and what to put there.**

> ⚠️ This is the ONLY file you need to read before going live. Follow it top to bottom.

---

## HOW THIS WORKS

There are **two types of config files**:

| File | What it is | In Git? |
|---|---|---|
| `configs/inventory.yml` | Your devices, servers, URLs | ✅ Yes — no secrets |
| `configs/environment.local.yml` | Passwords, tokens, credentials | ❌ No — gitignored, stays on server only |

Everything sensitive (passwords, API tokens) goes **only** in `environment.local.yml` on `monitor01`. Never in `inventory.yml`.

---

## STEP 1 — Edit `configs/inventory.yml`
**File location on your Mac:** [`configs/inventory.yml`](file:///Users/malikfaheemahmad/Documents/data-center-monitoring/configs/inventory.yml)  
**File location on monitor01:** `/opt/monitoring/configs/inventory.yml`  
**What it does:** Tells Prometheus what to monitor. Fill in your real IPs and URLs.

---

### 1A — Your Linux Servers & Proxmox Hosts
**Lines 37–51** — Replace the placeholder IPs with your real server IPs.

```yaml
# BEFORE (placeholder):
  - ip: 10.0.0.10
    alias: proxmox01
    role: hypervisor

  - ip: 10.0.0.11
    alias: proxmox02
    role: hypervisor

  - ip: 10.0.0.20
    alias: app01
    role: app

  - ip: 10.0.0.21
    alias: db01
    role: db

# AFTER (your real values — example):
  - ip: 192.168.1.10        ← PUT YOUR PROXMOX HOST 1 IP HERE
    alias: proxmox01        ← give it any name you want (no spaces)
    role: hypervisor

  - ip: 192.168.1.11        ← PUT YOUR PROXMOX HOST 2 IP HERE
    alias: proxmox02
    role: hypervisor

  - ip: 192.168.1.20        ← PUT YOUR APP SERVER IP HERE
    alias: app-server-01
    role: app

  - ip: 192.168.1.30        ← PUT YOUR DATABASE SERVER IP HERE
    alias: db-server-01
    role: db
```

> ℹ️ The IP must be the **LAN IP** of the server — the one reachable from monitor01 over your VPN or network tunnel. For each server you add here, you must also run `agent-bootstrap.sh` on that server (see Step 4).

---

### 1B — pfSense Firewall
**Line 87** — Replace with your pfSense LAN IP.

```yaml
# BEFORE:
  - ip: 10.0.0.1
    alias: pfsense
    module: if_mib

# AFTER:
  - ip: 192.168.1.1         ← PUT YOUR PFSENSE LAN IP HERE
    alias: pfsense
    module: if_mib
```

> ℹ️ This is the IP pfSense has on its LAN interface (not WAN). Usually ends in `.1`.

---

### 1C — Network Switches
**Lines 93–99** — Replace with your switch management IPs.

```yaml
# BEFORE:
  - ip: 10.0.0.2
    alias: core-switch-01
    module: if_mib

  - ip: 10.0.0.3
    alias: access-switch-01
    module: if_mib

# AFTER:
  - ip: 192.168.1.2         ← PUT YOUR CORE SWITCH MANAGEMENT IP HERE
    alias: core-switch-01   ← give it any name
    module: if_mib          ← leave as if_mib for Cisco/HP/generic switches
                            ← change to "cisco" for Cisco-specific metrics
                            ← change to "mikrotik" for MikroTik devices

  - ip: 192.168.1.3         ← PUT YOUR SECOND SWITCH IP (or delete these lines)
    alias: access-switch-01
    module: if_mib
```

> ℹ️ The management IP is the IP you use to SSH into or access the switch web UI.

---

### 1D — Dell iDRAC (Server Hardware Monitoring)
**Lines 106–110** — Replace with your iDRAC management IPs.

```yaml
# BEFORE:
  - ip: 10.0.0.100
    alias: idrac-server01
    module: idrac

  - ip: 10.0.0.101
    alias: idrac-server02
    module: idrac

# AFTER:
  - ip: 192.168.2.100       ← PUT YOUR IDRAC MANAGEMENT IP HERE
    alias: idrac-server01   ← give it any name
    module: idrac           ← always "idrac" for Dell iDRAC

  - ip: 192.168.2.101       ← PUT YOUR SECOND IDRAC IP (or delete if you have only one)
    alias: idrac-server02
    module: idrac
```

> ⚠️ The iDRAC IP is NOT the same as the server's regular LAN IP. It's a separate IP on the dedicated management port (usually on a dedicated management network or VLAN). Find it in iDRAC Settings → Network.

---

### 1E — Your Websites & Apps (HTTP/SSL Monitoring)
**Lines 131–137** — Replace with your real website URLs.

```yaml
# BEFORE:
  - url: https://yourdomain.com
    alias: main-website

  - url: https://yourapp.com
    alias: web-app

  - url: https://yourapp.com/health
    alias: web-app-health

# AFTER:
  - url: https://yourcompany.com       ← PUT YOUR WEBSITE URL HERE
    alias: main-website

  - url: https://app.yourcompany.com   ← PUT YOUR APP URL HERE
    alias: web-app

  - url: https://api.yourcompany.com/health   ← PUT ANY HEALTH ENDPOINT HERE
    alias: api-health
```

> ℹ️ Add as many URLs as you want. Each one gets: HTTP status check + response time + SSL certificate expiry monitoring. Use the full URL with `https://`.

---

### 1F — TCP Port Probes (Database Port Connectivity)
**Lines 155–161** — Replace with your database server IPs.

```yaml
# BEFORE:
  - host: 10.0.0.20:3306
    alias: mysql-prod

  - host: 10.0.0.21:5432
    alias: postgres-prod

  - host: 10.0.0.20:6379
    alias: redis-prod

# AFTER:
  - host: 192.168.1.30:3306    ← YOUR MYSQL SERVER IP:PORT
    alias: mysql-prod

  - host: 192.168.1.31:5432    ← YOUR POSTGRESQL SERVER IP:PORT
    alias: postgres-prod

  - host: 192.168.1.30:6379    ← YOUR REDIS SERVER IP:PORT
    alias: redis-prod
```

---

### 1G — Database Section IPs
**Lines 192, 198, 204** — Also update the database section at the bottom.

```yaml
# BEFORE:
databases:
  mysql:
    enabled: true
    host: 10.0.0.20

  postgresql:
    enabled: true
    host: 10.0.0.21

  redis:
    enabled: true
    host: 10.0.0.20

# AFTER:
databases:
  mysql:
    enabled: true
    host: 192.168.1.30       ← SAME AS YOUR MYSQL SERVER IP (no port)

  postgresql:
    enabled: true
    host: 192.168.1.31       ← SAME AS YOUR POSTGRESQL SERVER IP (no port)

  redis:
    enabled: true
    host: 192.168.1.30       ← SAME AS YOUR REDIS SERVER IP (no port)
```

---

## STEP 2 — Create `configs/environment.local.yml` on monitor01

**This file lives ONLY on `monitor01`. Never edit or push it to GitHub.**  
Create it by running this on monitor01:

```bash
nano /opt/monitoring/configs/environment.local.yml
```

Then paste and fill in ALL of the following:

```yaml
# ─────────────────────────────────────────────────────────────────────────────
# environment.local.yml — monitor01 secrets and overrides
# NEVER commit this file. It is gitignored.
# ─────────────────────────────────────────────────────────────────────────────

# ── REQUIRED: Grafana admin password ─────────────────────────────────────────
# You will use this to log into http://localhost:3000 after Grafana is installed.
grafana_admin_password: "PUT_A_STRONG_PASSWORD_HERE"
#
# Example: grafana_admin_password: "MySecurePass2026!"
# Rules: at least 12 characters, mix of letters, numbers, symbols

# ── REQUIRED: Telegram bot for alerts ────────────────────────────────────────
# HOW TO GET THESE:
#   1. Open Telegram → search @BotFather → send /newbot → follow prompts
#   2. BotFather gives you a token like: 123456789:ABCDefGhIjKlMnOpQrStUv
#   3. Start a chat with your new bot (send it any message)
#   4. Open this URL in browser to get your chat_id:
#      https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates
#   5. Look for: "chat":{"id": -123456789}  ← that number is your chat_id
#      (negative number = group chat, positive = direct message to you)
telegram_bot_token: "PUT_YOUR_BOT_TOKEN_HERE"
telegram_chat_id: "PUT_YOUR_CHAT_ID_HERE"
#
# Example:
#   telegram_bot_token: "7123456789:AAFake_example_token_xyz"
#   telegram_chat_id: "-1001234567890"    ← group chat (negative)
#   telegram_chat_id: "987654321"         ← direct message (positive)

# ── REQUIRED for MySQL monitoring ─────────────────────────────────────────────
# First create the user IN MySQL (run these SQL commands on your MySQL server):
#   CREATE USER 'exporter'@'%' IDENTIFIED BY 'choose_a_password_here';
#   GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'exporter'@'%';
#   FLUSH PRIVILEGES;
# Then put the credentials here:
mysql_dsn: "exporter:PUT_MYSQL_EXPORTER_PASSWORD_HERE@tcp(PUT_MYSQL_SERVER_IP_HERE:3306)/"
#
# Example:
#   mysql_dsn: "exporter:MyExporterPass123@tcp(192.168.1.30:3306)/"

# ── REQUIRED for PostgreSQL monitoring ───────────────────────────────────────
# First create the user IN PostgreSQL (run these SQL commands):
#   CREATE USER exporter WITH PASSWORD 'choose_a_password_here';
#   GRANT pg_monitor TO exporter;
# Then put the credentials here:
postgres_dsn: "postgresql://exporter:PUT_POSTGRES_EXPORTER_PASSWORD_HERE@PUT_POSTGRES_SERVER_IP_HERE:5432/postgres?sslmode=disable"
#
# Example:
#   postgres_dsn: "postgresql://exporter:MyExporterPass123@192.168.1.31:5432/postgres?sslmode=disable"

# ── REQUIRED for Redis monitoring ────────────────────────────────────────────
# If Redis has NO password (default):
redis_addr: "redis://PUT_REDIS_SERVER_IP_HERE:6379"
# If Redis HAS a password (requirepass in redis.conf):
# redis_addr: "redis://:PUT_REDIS_PASSWORD_HERE@PUT_REDIS_SERVER_IP_HERE:6379"
#
# Example (no password):   redis_addr: "redis://192.168.1.30:6379"
# Example (with password): redis_addr: "redis://:RedisPass123@192.168.1.30:6379"

# ── OPTIONAL: HTTPS via nginx ─────────────────────────────────────────────────
# Only needed if you want https://monitor.yourdomain.com instead of SSH tunnel.
# Requirements BEFORE enabling:
#   1. You must own a domain name
#   2. Point an A record: monitor.yourdomain.com → 107.170.11.210
#   3. Open ports 80 and 443 in DigitalOcean firewall
# Then fill in:
# nginx_domain: "monitor.yourdomain.com"       ← your subdomain
# nginx_admin_user: "admin"                     ← login username for web UI
# nginx_admin_password: "PUT_STRONG_PASSWORD_HERE"
# nginx_certbot_email: "you@yourdomain.com"     ← for SSL cert expiry emails

# ── OPTIONAL: Email alerts (alternative to Telegram) ─────────────────────────
# smtp_smarthost: "smtp.gmail.com:587"
# smtp_from: "alerts@yourdomain.com"
# smtp_auth_username: "alerts@yourdomain.com"
# smtp_auth_password: "YOUR_GMAIL_APP_PASSWORD"   ← not your Gmail password!
#                                                     Gmail → Settings → App Passwords
# alert_email_to: "you@yourdomain.com"

# ── OPTIONAL: Custom SNMP community string ───────────────────────────────────
# Only change this if your switches/pfSense/iDRAC use a different SNMP community.
# Default "public" works for most default configurations.
# snmp_community: "public"
```

---

## STEP 3 — Apply the Changes (run on monitor01)

After filling in both files, run these commands on monitor01:

```bash
cd /opt/monitoring

# Pull latest code from GitHub
git pull --ff-only

# Apply inventory (registers all your devices in Prometheus)
sudo ./scripts/apply-inventory.sh

# Re-render alertmanager with your Telegram credentials
sudo ./monitorctl install alertmanager --reinstall

# Deploy Grafana (will download 9 dashboards automatically)
sudo ./monitorctl install grafana

# Deploy Alloy (log shipping)
sudo ./monitorctl install alloy

# Deploy Watchdog (self-monitoring)
sudo ./monitorctl install watchdog

# Verify everything
./monitorctl health
```

---

## STEP 4 — Onboard Each On-Prem Server

For **every** Linux server (Proxmox hosts, app servers, DB servers) that you added to `inventory.yml`, run this command **on that server** (not on monitor01):

```bash
# Run on the target server (as root):
curl -fsSL https://raw.githubusercontent.com/TheMalikFaheem/data-center-monitoring-system/main/scripts/agent-bootstrap.sh \
    | sudo bash
```

This installs `node_exporter` on that server and opens the monitoring port.

After running it on all servers, go back to monitor01 and run:
```bash
sudo ./scripts/apply-inventory.sh
```

---

## STEP 5 — Enable SNMP on Network Devices

### pfSense
1. Log in to pfSense web UI
2. Go to: **Services → SNMP**
3. ✅ Enable: checked
4. Community String: `public`
5. Bind Interface: `LAN`
6. Click **Save**

### Cisco Switch (via console/SSH)
```
configure terminal
snmp-server community public RO
snmp-server location "Server Room"
snmp-server contact "Your Name"
end
write memory
```

### HP / Aruba Switch (via console/SSH)
```
snmp-server community public
write memory
```

### Dell iDRAC
1. Log in to iDRAC web UI
2. Go to: **iDRAC Settings → Connectivity → SNMP**
3. ✅ SNMP Agent: Enabled
4. SNMP Protocol: **SNMPv2**
5. Community Name: `public`
6. Click **Apply**

---

## STEP 6 — Set Up Database Monitoring Users

### MySQL / MariaDB
Connect to your MySQL server and run:

```sql
-- Create the monitoring user (replace 'your_password_here' with a real password)
CREATE USER 'exporter'@'%' IDENTIFIED BY 'your_password_here';
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'exporter'@'%';
FLUSH PRIVILEGES;
```

Then in `environment.local.yml` on monitor01:
```yaml
mysql_dsn: "exporter:your_password_here@tcp(YOUR_MYSQL_IP:3306)/"
```

Then run:
```bash
sudo ./monitorctl install mysqld_exporter --reinstall
```

### PostgreSQL
Connect to your PostgreSQL server and run:

```sql
-- Create the monitoring user (replace 'your_password_here' with a real password)
CREATE USER exporter WITH PASSWORD 'your_password_here';
GRANT pg_monitor TO exporter;
```

Then in `environment.local.yml` on monitor01:
```yaml
postgres_dsn: "postgresql://exporter:your_password_here@YOUR_POSTGRES_IP:5432/postgres?sslmode=disable"
```

Then run:
```bash
sudo ./monitorctl install postgres_exporter --reinstall
```

### Redis
No user to create. Just need the Redis server IP (and password if set).

In `environment.local.yml` on monitor01:
```yaml
# If Redis has no password:
redis_addr: "redis://YOUR_REDIS_IP:6379"

# If Redis requires a password:
redis_addr: "redis://:your_redis_password@YOUR_REDIS_IP:6379"
```

Then run:
```bash
sudo ./monitorctl install redis_exporter --reinstall
```

---

## ✅ Completion Checklist

After doing all the above, verify everything is working:

```bash
# On monitor01:
./monitorctl health           # all PASS

# Check Prometheus sees all targets:
curl -s 'http://127.0.0.1:9090/api/v1/targets' | python3 -m json.tool | grep '"health"'
# Every target should show "health":"up"

# Test Telegram (fire a test alert):
curl -XPOST http://127.0.0.1:9093/api/v2/alerts \
  -H 'Content-Type: application/json' \
  -d '[{"labels":{"alertname":"TestAlert","severity":"warning","instance":"monitor01"},"annotations":{"summary":"Test — safe to ignore"}}]'
# → You should receive a Telegram message within 30 seconds
```

---

## 📋 Summary — Files to Edit

| File | On Mac or Server? | What to change |
|---|---|---|
| `configs/inventory.yml` | Mac (then `git push`) | All device IPs and website URLs |
| `configs/environment.local.yml` | monitor01 ONLY (never git push) | Grafana password, Telegram token, DB credentials |

That is the complete list. Two files. Everything else is automated.
