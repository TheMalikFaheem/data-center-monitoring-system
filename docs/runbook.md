# Operator Runbook — Monitoring Platform

This is the working manual for the native (systemd-based) monitoring platform.
It assumes you are comfortable with Linux administration but new to
Prometheus-style monitoring, so each section starts with the *why*.

---

## 1. A five-minute primer on how this stack works

- **Metric** — a number with a name and labels, sampled over time.
  `node_cpu_seconds_total{cpu="0",mode="idle"}` is a metric.
- **Exporter** — a small daemon that reads some system (the kernel, MySQL, a
  switch via SNMP) and publishes its state as metrics on an HTTP page,
  conventionally at `/metrics`. `node_exporter` is the exporter for Linux
  host metrics: CPU, RAM, disk, network, filesystems.
- **Scrape** — Prometheus *pulls*: every `scrape_interval` (15s here) it does
  an HTTP GET on each exporter's `/metrics` page and stores what it finds.
  Nothing pushes to Prometheus. If you can `curl` the endpoint, Prometheus
  can scrape it.
- **Target** — one endpoint Prometheus scrapes. The list of targets lives in
  `/etc/prometheus/prometheus.yml` under `scrape_configs`.
- **TSDB / retention** — Prometheus stores samples in its own time-series
  database under `/var/lib/prometheus`, and deletes data older than the
  retention window (30 days here). Disk usage is roughly proportional to
  (number of series × retention).
- **Later**: Grafana draws dashboards *from* Prometheus; Alertmanager routes
  alerts *fired by* Prometheus rules; Loki does for logs what Prometheus does
  for metrics. None of them collect anything themselves.

---

## 2. One-time cutover on monitor01

The server's current `/opt/monitoring` was hand-made and has its own
unrelated git history. Replace it with a clone of this repo — GitHub becomes
the single source of truth.

```bash
# 1. Preserve the old directory (delete it only after Phase 1 verifies)
mv /opt/monitoring /opt/monitoring.pre-framework.$(date +%Y%m%d)

# 2. Clone this repository in its place
git clone https://github.com/TheMalikFaheem/data-center-monitoring-system.git /opt/monitoring
cd /opt/monitoring

# 3. Create the per-server override file (gitignored — never committed)
cat > configs/environment.local.yml <<'EOF'
# environment.local.yml — values specific to THIS server.
# Same flat "key: "value"" format as environment.yml.
# monitor01 currently uses only the shared defaults, so this starts empty.
EOF

# 4. Sanity check against the old configs, then you're done
diff -r /opt/monitoring.pre-framework.*/configs configs || true
```

**Steady-state deploys from now on:** edit on the Mac → commit → push → on
the server:

```bash
cd /opt/monitoring && git pull --ff-only
```

`--ff-only` guarantees the server never grows local commits. Server-local
state lives only in gitignored files (`environment.local.yml`, `.downloads/`,
`.rollback/`).

---

## 3. Installing components

```bash
cd /opt/monitoring
sudo ./monitorctl install node_exporter
sudo ./monitorctl install prometheus
```

What every installer does, in order: preflight checks → read the pinned
version from `configs/versions.yml` → download the official release →
**verify its SHA256 against the project's published checksum file** → create
a dedicated system user → install the binary to `/usr/local/bin` → write
config under `/etc/<service>` → install a hardened systemd unit → start →
verify health. On any failure it rolls back what it changed and leaves the
system clean.

Re-running an installer is always safe:

- already at the pinned version → verifies health and exits ("nothing to do")
- version in `versions.yml` is newer → clean upgrade, data and config kept
- `--reinstall` flag → forces a reinstall at the same version

---

## 4. Reaching the web UIs (before nginx exists)

Every service binds `127.0.0.1` only — nothing is reachable from the
network on purpose. Until the nginx + HTTPS phase, use an SSH tunnel from
your Mac:

```bash
ssh -L 9090:127.0.0.1:9090 root@107.170.11.210
# keep that session open, then browse http://localhost:9090
```

In the Prometheus UI, **Status → Targets** is the page that matters: every
target should show **UP**.

---

## 5. Firewall (manual, on purpose)

The scripts *check* UFW but never *change* it — enabling a firewall over SSH
with the wrong rules locks you out of a cloud server permanently. Do it once,
by hand, in this exact order:

```bash
ufw default deny incoming
ufw default allow outgoing
ufw limit OpenSSH        # rate-limited allow — brute-force protection for free
ufw enable
ufw status verbose       # expect: deny incoming; 22/tcp LIMIT
```

Ports 80/443 get their allow rules in the nginx phase. The monitoring ports
(9090, 9100, 3000…) never get UFW rules — loopback binding is the primary
control and UFW default-deny is the backstop.

---

## 6. Verification checklist (run after installing, paste results back)

```bash
cd /opt/monitoring

# deploy state
git status                                   # clean, no local commits

# services
systemctl is-active prometheus node_exporter    # active / active
systemctl is-enabled prometheus node_exporter   # enabled / enabled

# framework's own view
./monitorctl health                          # all PASS
./monitorctl versions                        # no DRIFT

# the actual observability payoff: Prometheus is scraping both targets
curl -fsS 'http://127.0.0.1:9090/api/v1/targets' | grep -o '"health":"[a-z]*"'
# expect: "health":"up" twice

# network posture: loopback only
sudo ss -tlnp | grep -E '9090|9100'          # both 127.0.0.1

# idempotency: re-run is a no-op
sudo ./monitorctl install prometheus         # "nothing to do", exit 0

# resilience: systemd restarts a killed service
sudo pkill -9 prometheus; sleep 8; systemctl is-active prometheus   # active

# install log
sudo tail -30 /var/log/monitoring/install.log
```

Optional final check: `sudo reboot`, then `./monitorctl health` → all PASS.

---

## 7. Upgrading a component

1. On the Mac: change the version in `configs/versions.yml`, commit, push.
2. On the server:

```bash
cd /opt/monitoring && git pull --ff-only
./monitorctl versions        # shows DRIFT on the changed component
sudo ./monitorctl update     # re-runs only the drifted installers
```

The upgrade path stops the service, parks the old binary in `.rollback/`,
installs the new one, restarts, and health-checks. If anything fails, the
old binary is restored and the service restarted on the previous version.
The TSDB and your config edits are never touched by upgrades.

---

## 8. Where everything lives

| What | Where |
|---|---|
| Framework (this repo) | `/opt/monitoring` |
| Binaries | `/usr/local/bin/prometheus`, `promtool`, `node_exporter` |
| Prometheus config | `/etc/prometheus/prometheus.yml` |
| Metric data (TSDB) | `/var/lib/prometheus` |
| Textfile-collector drop dir | `/var/lib/node_exporter/textfile` (any `*.prom` file becomes metrics) |
| systemd units | `/etc/systemd/system/prometheus.service`, `node_exporter.service` |
| Install log | `/var/log/monitoring/install.log` |
| Service logs | `journalctl -u prometheus` / `journalctl -u node_exporter` |
| Download cache / parked old binaries | `/opt/monitoring/.downloads` / `.rollback` (gitignored) |

---

## 9. Rules the framework lives by (so you know what it will never do)

- **Your config edits are sacred.** If `/etc/prometheus/prometheus.yml`
  exists, the installer never overwrites it. A differing fresh render is
  saved as `prometheus.yml.new` next to it for you to diff.
- **Data survives everything.** Rollback only ever removes things the
  current run created. A pre-existing TSDB is untouchable.
- **Versions come from one file.** No installer contains a version number;
  `configs/versions.yml` is the only place they exist.
- **Nothing listens on the network** until the reverse-proxy phase decides
  what is exposed, with TLS and auth in front of it.

---

## 10. Troubleshooting

**Service won't start** — `journalctl -u <service> -n 50 --no-pager`. The
installer already prints the last 20 lines when its health gate fails.

**`curl localhost:9090` fails but the service is active** — use
`127.0.0.1`, not `localhost`: the services bind IPv4 loopback, and
`localhost` can resolve to `::1`. Every script in this repo uses `127.0.0.1`
for this reason.

**Port already in use at install** — the preflight names the process. The
classic collision is Cockpit, which also uses 9090.

**Config change rejected** — validate first, then reload without a restart:
`promtool check config /etc/prometheus/prometheus.yml && systemctl reload prometheus`.

**AppArmor** — enabled on Ubuntu 24.04, but it has no profiles for
`/usr/local/bin` binaries, so it will not interfere. Don't chase it as a
ghost when debugging.

**Install failed halfway** — read `/var/log/monitoring/install.log`; the
rollback trail is logged step by step. The system is left as it was before
the run.

---

## 11. Phase 2 — Alertmanager, Loki, Alloy, Grafana

### 11.1 Before you start

Grafana's admin password must exist in the gitignored per-server override file
**before** running the grafana installer. This file is never committed:

```bash
# On monitor01:
cat >> /opt/monitoring/configs/environment.local.yml <<'EOF'
grafana_admin_password: "choose_a_strong_password_here"
EOF
```

### 11.2 Install (in dependency order)

```bash
cd /opt/monitoring
git pull --ff-only

# Option A — install each component individually (recommended first time):
sudo ./monitorctl install alertmanager
sudo ./monitorctl install loki
sudo ./monitorctl install alloy
sudo ./monitorctl install grafana

# Option B — install all at once (uses INSTALL_ORDER from monitorctl):
sudo ./monitorctl install all
```

What `install alertmanager` does beyond the standard skeleton:
- installs `/etc/alertmanager/alertmanager.yml` (with email/webhook stubs)
- creates `/etc/prometheus/rules/` and installs `host.rules.yml`
- **patches the running `prometheus.yml`** to add `rule_files:` + `alerting:` block
- reloads Prometheus without a restart — rules take effect immediately

### 11.3 Verification

```bash
# All six components healthy:
./monitorctl health

# Versions match the pins:
./monitorctl versions

# Individual endpoint checks:
curl -s http://127.0.0.1:9093/-/healthy      # alertmanager → OK
curl -s http://127.0.0.1:3100/ready          # loki         → ready
curl -s http://127.0.0.1:12345/-/ready       # alloy        → ready
curl -s http://127.0.0.1:3000/api/health     # grafana      → {"database":"ok",...}

# Prometheus sees all targets UP (should be 2 after P1, Alertmanager adds itself):
curl -s 'http://127.0.0.1:9090/api/v1/targets' | grep -o '"health":"[a-z]*"'

# Alertmanager rules loaded (expect host.rules.yml rules listed):
curl -s 'http://127.0.0.1:9090/api/v1/rules' | python3 -m json.tool | grep -A2 '"name"'

# Alloy is shipping logs (Loki should have data within 30s of Alloy starting):
curl -s 'http://127.0.0.1:3100/loki/api/v1/query?query={job="journal"}' \
    | python3 -m json.tool | head -20
```

### 11.4 SSH tunnels for web UIs (all four components)

Open one multi-port tunnel session, or four separate ones:

```bash
# Single command — opens all four UIs at once:
ssh -L 9090:127.0.0.1:9090 \
    -L 9093:127.0.0.1:9093 \
    -L 3100:127.0.0.1:3100 \
    -L 3000:127.0.0.1:3000 \
    root@107.170.11.210

# Then browse:
#   http://localhost:9090   Prometheus
#   http://localhost:9093   Alertmanager
#   http://localhost:3100   Loki (API only — use Grafana's Explore for queries)
#   http://localhost:3000   Grafana (login: admin / your grafana_admin_password)
```

Grafana's **Explore → Loki** page is the log browser. Select the `Loki`
datasource, use label selectors like `{job="journal", unit="prometheus.service"}`.

### 11.5 Alertmanager: configuring notifications

The initial `alertmanager.yml` is a working but silent config (null receiver).
When ready to receive alerts:

**Email (recommended for getting started):**

1. Add SMTP credentials to `configs/environment.local.yml`:
   ```yaml
   smtp_smarthost: "smtp.gmail.com:587"
   smtp_from: "alerts@yourdomain.com"
   smtp_auth_username: "alerts@yourdomain.com"
   smtp_auth_password: "your_app_password"
   alert_email_to: "oncall@yourdomain.com"
   ```

2. Re-run the installer (idempotent — saves a `.new` diff file):
   ```bash
   sudo ./monitorctl install alertmanager --reinstall
   ```

3. Or edit `/etc/alertmanager/alertmanager.yml` directly:
   - uncomment the `smtp_*` lines under `global:`
   - add the `email` receiver
   - add a route that points to it
   - validate and reload:
     ```bash
     amtool check-config /etc/alertmanager/alertmanager.yml
     systemctl reload alertmanager
     ```

**Test the pipeline end-to-end:**
```bash
# Fire a test alert via Alertmanager's API:
curl -XPOST http://127.0.0.1:9093/api/v2/alerts \
    -H 'Content-Type: application/json' \
    -d '[{"labels":{"alertname":"TestAlert","severity":"warning","instance":"monitor01"},"annotations":{"summary":"Integration test — safe to ignore"}}]'

# Check it appears in the Alertmanager UI or fires to your notification channel.
```

### 11.6 Managing alert rules

Rules live in `/etc/prometheus/rules/`. The framework installs `host.rules.yml`
with conservative thresholds for InstanceDown, CPU, memory, and disk. To add
or change rules:

```bash
# Edit (or add a new file):
nano /etc/prometheus/rules/host.rules.yml

# Validate BEFORE reloading:
promtool check rules /etc/prometheus/rules/host.rules.yml

# Reload without restarting Prometheus (keeps TSDB hot):
systemctl reload prometheus

# Confirm rules loaded:
curl -s http://127.0.0.1:9090/api/v1/rules | python3 -m json.tool | grep '"name"'
```

### 11.7 Where Phase 2 data lives

| What | Where |
|---|---|
| Alertmanager config | `/etc/alertmanager/alertmanager.yml` |
| Alertmanager state | `/var/lib/alertmanager` |
| Alert rules | `/etc/prometheus/rules/*.yml` |
| Alloy config | `/etc/alloy/config.alloy` |
| Loki config | `/etc/loki/loki.yml` |
| Loki log chunks | `/var/lib/loki/chunks` |
| Grafana config | `/etc/grafana/grafana.ini` |
| Grafana provisioning | `/etc/grafana/provisioning/` |
| Grafana dashboards | `/var/lib/grafana/dashboards/` |
| Grafana database | `/var/lib/grafana/grafana.db` |
| Service logs | `journalctl -u alertmanager\|loki\|alloy\|grafana-server` |

