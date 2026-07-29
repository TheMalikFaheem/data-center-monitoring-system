# Monitoring Coverage — Per-Target Reference

For each target: **how to collect it**, **what metrics matter**, **what to alert on**.
Architecture and rollout order live in [README.md](README.md).

---

## 1. pfSense (Dell R710)

### Collection

| Method | Setup | Covers |
|---|---|---|
| `node_exporter` | Install from pfSense package manager (`net-mgmt/node_exporter`) | Host CPU, RAM, disk, load, uptime |
| SNMP (`bsnmpd`) | *Services → SNMP*, enable v2c + the **pf** module | Interfaces, pf state table, NAT |
| Syslog | *Status → System Logs → Settings* → remote server = Alloy:514 | Firewall block/pass, VPN, DHCP, gateway events |
| NetFlow | Install `softflowd` package → export to ntopng | Per-host/per-protocol bandwidth |
| Blackbox / ICMP | From the monitoring host | WAN reachability, latency, loss |

### Metrics

**Internet lines (up/down)**
`dpinger` gateway monitoring gives latency, stddev, and packet loss per WAN. Export via SNMP or scrape the gateway status page. Supplement with Blackbox ICMP to two independent anchors per line (e.g. `1.1.1.1` and `8.8.8.8`) so a single anchor's outage doesn't look like a WAN failure.

Track per gateway: `up/down`, RTT, RTT stddev (**jitter**), loss %, and time-since-last-flap.

**Bandwidth**
SNMP IF-MIB 64-bit counters — always `ifHCInOctets` / `ifHCOutOctets`, never the 32-bit versions (they wrap in ~5 minutes on a gigabit link). Per interface: throughput, `ifInErrors`, `ifOutErrors`, `ifInDiscards`, `ifOperStatus`. Graph as % of committed line rate so saturation is obvious at a glance.

**NAT & state table**
BEGEMOT-PF-MIB is the key here:
- `pfStateCount` / `pfStateLimit` → **alert at >80%**; state exhaustion drops new connections silently and looks exactly like "the internet is broken"
- `pfCounterMatch`, `pfCounterBadOffset`, `pfCounterStateMismatch`
- `pfStatesInserts` / `pfStatesRemovals` rate → connection churn
- Per-rule and per-label counters (`pfLabels*`) → traffic per firewall rule

**Also worth capturing**
CPU per core (NAT/IPS is single-thread bound), `mbuf` cluster usage (exhaustion = hard packet drops), IPsec/OpenVPN tunnel state and peer count, DHCP pool utilisation, CARP state if HA, package update availability, and public IP change detection.

### Alerts
`P1` WAN down >2 min · gateway loss >5% for 5 min · pf states >90% · IPsec tunnel down
`P2` pf states >80% · WAN latency 2× baseline · interface errors rising · mbuf >75% · public IP changed
`P3` pfSense update available · unusual block-rate spike

---

## 2. Switches — Cisco & HP/Aruba

### Collection
SNMP v3 (auth+priv) preferred; v2c with a read-only community and an ACL if v3 isn't available. Poll every 60 s via `snmp_exporter`, generated from vendor MIBs with `generator.yml`. Add LibreNMS if you want auto-discovery and topology maps for free.

Also enable: syslog → Alloy, SNMP traps → `snmptrapd`, LLDP for neighbour discovery, and Oxidized for config backup.

### Metrics

**Standard MIBs (both vendors)**

| OID | Meaning |
|---|---|
| `ifHCInOctets` / `ifHCOutOctets` | Per-port throughput (64-bit) |
| `ifInErrors` / `ifOutErrors` / `ifInDiscards` | Errors and drops — **rising CRC errors mean a bad cable or SFP** |
| `ifOperStatus` / `ifAdminStatus` | Link state vs. intended state |
| `ifHighSpeed` | Negotiated speed — catches a gigabit port that silently fell to 100 Mb |
| `sysUpTime` | A reset here = unplanned reboot |
| `ENTITY-SENSOR-MIB` | Temperature, voltage, fan RPM |
| `POWER-ETHERNET-MIB` | PoE draw per port and per PSU budget |
| `LLDP-MIB` | Neighbour table → auto topology map |

**Cisco-specific**
`CISCO-PROCESS-MIB` (`cpmCPUTotal5minRev`), `CISCO-MEMORY-POOL-MIB`, `CISCO-ENVMON-MIB` (fan/PSU/temp status), `CISCO-STACK-MIB` for stack member health, `CISCO-STP-EXTENSIONS-MIB` for topology-change counts.

**HP/Aruba-specific**
`HP-ICF-CHASSIS` for fan/PSU/sensor status, plus the standard `ENTITY-*` MIBs. Aruba CX also exposes a REST API if these are newer units.

**Derived / log-based**
Port flap count (from syslog `LINK-3-UPDOWN`), MAC table size vs. platform limit, STP topology changes (a churning STP is a broadcast storm forming), config-change events, port-security violations, and uplink utilisation vs. access-port aggregate — your oversubscription ratio.

### Alerts
`P1` uplink/trunk port down · switch unreachable · STP topology change storm · PoE budget exhausted
`P2` CRC/input errors >10/min · temperature above threshold · PSU or fan failure · port flapping >3×/5 min · unexpected reboot · running config differs from startup config
`P3` port speed mismatch · MAC table >70% · daily config diff

---

## 3. HikVision NVR

SNMP on HikVision is minimal. The **ISAPI HTTP API** (digest auth) is where the real data is — worth a ~150-line Python exporter.

### ISAPI endpoints

| Endpoint | Yields |
|---|---|
| `/ISAPI/System/status` | CPU, memory, uptime, device temperature |
| `/ISAPI/System/deviceInfo` | Model, firmware version, serial |
| `/ISAPI/ContentMgmt/Storage` | **Per-HDD status, capacity, free space, SMART** |
| `/ISAPI/System/Video/inputs/channels` | Per-channel configuration |
| `/ISAPI/ContentMgmt/InputProxy/channels/status` | **Camera online / offline per channel** |
| `/ISAPI/ContentMgmt/record/tracks` | Recording status per channel |
| `/ISAPI/Event/notification/alertStream` | Live event stream: motion, video loss, tamper |

### Metrics to expose
`hikvision_camera_online{channel,name}` · `hikvision_hdd_status{disk}` (0=ok/1=error/2=uninitialized) · `hikvision_hdd_free_bytes` / `hikvision_hdd_total_bytes` · `hikvision_recording_active{channel}` · `hikvision_uptime_seconds` · `hikvision_temperature_celsius` · `hikvision_firmware_info`

### Complementary checks

- **ICMP per camera IP** via Blackbox — cheapest possible camera-down detection, independent of the NVR's own reporting.
- **RTSP frame check** — a periodic `ffprobe` against each stream verifies frames are actually flowing. A camera can be pingable and ONVIF-responsive while delivering a frozen or black image; only this catches it.
- **Retention-depth check** — query the oldest available recording per channel. If your 30-day retention has quietly become 4 days because storage filled or a disk dropped out, you want to know *before* someone requests footage.
- **PoE cross-reference** — the switch's per-port PoE draw tells you whether a "camera offline" is a network issue or a dead camera.

### Alerts
`P1` NVR unreachable · HDD failed or dropped from array · recording stopped on any channel · retention below contractual minimum
`P2` camera offline >5 min · storage >85% · RTSP stream frozen · NVR temperature high
`P3` firmware update available · camera offline pattern (same camera flapping daily)

---

## 4. Dell R710 / R720 — iDRAC & hardware

**Firmware reality:** R710 ships iDRAC6, R720 ships iDRAC7. **iDRAC6 does not support Redfish.** Use IPMI + SNMP as the common denominator across all three servers; optionally add a Redfish exporter for the R720s only (iDRAC7 firmware 2.40+).

### Collection

| Method | Tool | Covers |
|---|---|---|
| IPMI over LAN | `ipmi_exporter` (`-I lanplus`) | Temps, fans, PSU watts, voltages, chassis intrusion, power state |
| SNMP | `snmp_exporter` + `IDRAC-MIB-SMIv2` | Global health, RAID/PERC, physical + virtual disks, memory ECC, PSU redundancy |
| SNMP traps | `snmptrapd` | Hardware faults are **trap-driven** — polling can miss transient events |
| Redfish *(R720 only)* | `idrac_exporter` | Richer inventory, structured health |
| Syslog | iDRAC → Alloy:514 | Lifecycle Controller log, remote console access, auth failures |

### Metrics

**Thermal & power** — inlet temperature (the number that matters for room cooling), CPU temps, per-fan RPM, PSU input watts (each PSU separately), 12 V / 5 V / 3.3 V rails, total chassis power draw.

> Track PSU wattage across all three servers and you get real-time electricity cost, a PUE estimate, and the data to justify retiring the R710 — a 2009-era server often costs more in power annually than a replacement.

**Storage** — PERC RAID controller status, **battery/BBU health** (a dead BBU silently disables write-back cache and tanks your I/O), per-physical-disk state, predictive-failure flags, virtual disk state (Optimal / Degraded / Failed), rebuild progress, hot-spare presence, and per-disk SMART via `smartctl_exporter` with `-d megaraid,N`.

**Memory & CPU** — correctable ECC error *rate* (a climbing rate predicts a DIMM failure days ahead), uncorrectable ECC, DIMM inventory, CPU presence and throttling.

**Other** — PSU redundancy state, chassis intrusion, iDRAC reachability, firmware/BIOS versions (drift across a cluster), and remote-console session logging.

### Alerts
`P1` any physical disk failed · virtual disk degraded or failed · uncorrectable ECC · inlet temp >35 °C · PSU failure · server unreachable
`P2` predictive disk failure · PSU redundancy lost · fan failure or RPM out of range · RAID BBU degraded · correctable ECC rate rising · RAID rebuild in progress
`P3` firmware/BIOS drift across cluster · no hot spare configured · power draw trend

---

## 5. Proxmox VE

### Collection

**`prometheus-pve-exporter`** — one instance, API-token auth, scrapes the whole cluster. Yields node status, per-VM/LXC status and resource use, storage capacity per datastore, HA state, and cluster quorum.

**`node_exporter` on each PVE host** — with `--collector.zfs`, `--collector.systemd`, `--collector.textfile`, `--collector.hwmon`. This is the ground truth the API can't give you.

**`smartctl_exporter` on each host** — physical disk health beneath the RAID/ZFS layer.

> **Shortcut:** Proxmox has a built-in metric server (*Datacenter → Metric Server*) that speaks InfluxDB line protocol. VictoriaMetrics accepts that protocol natively — so you can push PVE metrics straight in with zero exporters. Useful as a belt-and-braces second path.

### Metrics

**Cluster** — quorum status (**loss of quorum freezes the cluster**), corosync ring health and link status, node membership, HA resource state, and node-to-node latency (corosync is latency-sensitive; >2 ms causes trouble).

**Per host** — CPU per core, load average, memory including **PSI pressure stall** (`node_pressure_*` — a far better saturation signal than plain memory-used), swap use and swap-in *rate*, network per NIC including bond member state, and disk I/O latency and queue depth per device.

**Storage — the one that bites**
- **LVM-thin pool `Data%` and `Meta%`** → **alert at 75%**. A thin pool hitting 100% corrupts guest filesystems. Metadata exhaustion does the same and fills much faster than you expect.
- **ZFS**: pool health, scrub status and last-scrub age, resilver progress, per-vdev errors (read/write/checksum), fragmentation, ARC size and hit ratio, and pool capacity — **ZFS performance degrades sharply above 80% full**.
- Per-datastore free space, and snapshot count and age per VM (forgotten snapshots quietly consume the pool).

**Backups — do not skip this**
Job success/failure, duration trend, **output size** (a backup that suddenly shrank 90% is broken but "successful"), and **time since last successful backup per VM**. Alert on absence: `time() - pve_backup_last_success > 26h`. If you run Proxmox Backup Server, add its exporter for datastore usage, GC status, verify-job results, and deduplication ratio.

**Updates** — a `node_exporter` textfile-collector script on a daily cron:

```bash
#!/bin/bash
# /usr/local/bin/apt-metrics.sh → /var/lib/node_exporter/textfile/apt.prom
{
  echo "# TYPE node_available_updates gauge"
  echo "node_available_updates $(apt-get -s upgrade 2>/dev/null | grep -c ^Inst)"
  echo "# TYPE node_security_updates gauge"
  echo "node_security_updates $(apt-get -s upgrade 2>/dev/null | grep ^Inst | grep -ci security)"
  echo "# TYPE node_reboot_required gauge"
  echo "node_reboot_required $([ -f /var/run/reboot-required ] && echo 1 || echo 0)"
} > /var/lib/node_exporter/textfile/apt.prom.$$ \
  && mv /var/lib/node_exporter/textfile/apt.prom.$$ /var/lib/node_exporter/textfile/apt.prom
```

Add Proxmox subscription/repo status and PVE version drift across nodes.

### Alerts
`P1` cluster quorum lost · node down · ZFS pool DEGRADED/FAULTED · thin pool >90% · no successful backup in 26 h · corosync link down
`P2` thin pool >75% · ZFS pool >80% · scrub overdue >35 d · storage >85% · swap-in rate sustained · backup duration 2× baseline · HA resource migration
`P3` pending updates · reboot required · snapshots older than 7 d · PVE version drift

---

## 6. Virtual machines

`node_exporter` in every Linux VM, `windows_exporter` in every Windows VM, plus `qemu-guest-agent` (gives PVE the in-guest IP and enables filesystem-freeze for consistent backups).

### Metrics that only in-guest agents can give you

**CPU steal time** — `rate(node_cpu_seconds_total{mode="steal"}[5m])`. This is the metric that explains "the VM feels slow but the graphs look fine". Sustained steal >5% means the host is oversubscribed. The hypervisor's own "VM CPU %" is blind to this.

**PSI pressure stall** — `node_pressure_cpu_waiting_seconds_total`, `node_pressure_memory_stalled_seconds_total`, `node_pressure_io_stalled_seconds_total`. Directly measures "how long did work wait for a resource" — a much earlier and cleaner saturation signal than utilisation percentages.

**Also** — memory available vs. cached (never alert on "used"; Linux uses all of it), disk usage **and inode usage** (inode exhaustion presents as "no space left" with the disk half empty), filesystem read-only remounts, disk I/O latency, TCP retransmits and socket state counts, `systemd` failed-unit count, NTP/chrony offset (clock skew breaks TLS, auth, and replication), open file descriptors vs. limit, and entropy availability.

**Per-process** — `process_exporter` with named groups so you track `mysqld`, `php-fpm`, `node`, and `redis-server` individually: CPU, RSS, open FDs, thread count, and **restart detection via start-time changes**.

### Alerts
`P1` VM down · filesystem read-only · disk >95% · inodes >95% · OOM kill event
`P2` CPU steal >5% for 10 min · memory available <10% · disk >85% · PSI I/O stall rising · systemd unit failed · clock offset >1 s · FD usage >80% of limit
`P3` disk projected full within 7 d (`predict_linear`) · pending updates

---

## 7. System logs

### Pipeline
Grafana Alloy on every host and VM → Loki. Alloy also runs a **syslog receiver on 514** for appliances (pfSense, switches, NVR, iDRAC, UPS) and can ingest `snmptrapd` output.

**Sources:** journald, `/var/log/{syslog,auth.log,kern.log}`, nginx/apache access + error, MySQL slow-query and error logs, PostgreSQL logs, php-fpm, pm2, application logs, Proxmox task logs, and cPanel/Plesk logs.

**At ingest:** parse into structured labels (host, service, severity, vhost, status code), drop noisy debug lines, and — importantly — **use low-cardinality labels only**. Never label by request ID, user ID, or IP; that shreds Loki's index.

### Log-derived alert rules

These catch failures that metrics never surface:

| Pattern | Why it matters |
|---|---|
| `Out of memory: Killed process` | OOM killer — the process died and metrics just show a gap |
| `Remounting filesystem read-only` | Silent, total application failure |
| `I/O error`, `medium error`, `SMART` | Disk dying underneath the RAID layer |
| `Machine Check Exception` | CPU or memory hardware fault |
| RAID `degraded` / `rebuild` | mdadm / PERC state change |
| `Failed password` burst from one IP | SSH brute force |
| `sudo:` / `useradd` / `usermod` | Privilege change |
| segfault / core dump | Application crash |
| Certbot renewal failure | Cert will expire in ~30 days with no further warning |
| `error` rate spike per vhost | The fastest generic outage signal you have |

**Also convert logs to metrics** — Alloy's `loki.metric.*` stages turn log patterns into counters, so you can alert on rates without a full LogQL query, and build "errors per vhost per minute" panels straight from access logs.

---

## 8. Databases

### MySQL / MariaDB — `mysqld_exporter`

Grant a dedicated user `PROCESS, REPLICATION CLIENT, SELECT` with a low `MAX_USER_CONNECTIONS`.

**Watch:** `Threads_connected` vs `max_connections` (**alert at 80%** — hitting the cap locks out even root), `Threads_running` (the real load signal — >CPU count means queuing), InnoDB buffer pool hit ratio and size vs. dataset, row lock waits and average lock time, deadlock count, **replication: `Seconds_Behind_Master`, IO/SQL thread state, and last error** (a stopped slave is silent by default), slow query count and `Created_tmp_disk_tables` (missing indexes), `Aborted_connects` (auth failures or network drops), table-open-cache misses, and InnoDB log-wait rate.

Enable `performance_schema` and the slow query log → ship to Loki for query-level analysis.

`P1` MySQL down · replication stopped or errored · connections >95%
`P2` replication lag >60 s · connections >80% · buffer pool hit <95% · deadlocks rising · disk temp tables spiking

### PostgreSQL — `postgres_exporter`

**Watch:** connections vs `max_connections` per database and per user, transaction commit/rollback rate, cache hit ratio (**should be >99%**), deadlocks, **longest-running transaction** (a forgotten `BEGIN` blocks autovacuum and bloats tables indefinitely), replication lag in bytes and seconds plus **replication slot lag** (an inactive slot with a growing backlog will fill your WAL disk and take the primary down), WAL generation rate, autovacuum activity and dead-tuple count per table, table and index bloat, `pg_stat_statements` top queries by total time, and checkpoint frequency and write timing.

`P1` Postgres down · replication broken · replication slot lag >10 GB · disk-full risk from WAL
`P2` connections >80% · cache hit <95% · transaction open >1 h · dead tuples high · deadlocks rising

### Redis — `redis_exporter`

**Watch:** `used_memory` vs `maxmemory` (**alert at 80%**), evicted keys per second (evictions on a cache are normal; evictions on a session or queue store mean **silent data loss**), keyspace hit ratio, connected and **blocked** clients, `rdb_last_save_age` and `aof_last_bgrewrite_status`, replication link status and offset lag, `rdb_last_bgsave_status`, slowlog length, command latency percentiles, and expired vs. evicted key ratio.

`P1` Redis down · memory >95% with evictions on a persistence-backed store · replication link down · last save >24 h
`P2` memory >80% · eviction rate rising · blocked clients >0 sustained · slowlog growing

### Others
MongoDB (`mongodb_exporter`), Elasticsearch (`elasticsearch_exporter`), ClickHouse (native `/metrics`), RabbitMQ (built-in Prometheus plugin), Memcached (`memcached_exporter`).

### For every database
Backup age and size (textfile collector on the backup script), **restore testing** — a monthly automated restore into a scratch VM with a row-count assertion, since an untested backup is a hypothesis not a backup — data directory disk usage and growth trend, and per-database size for tenant capacity planning.

---

## 9. Applications

### Uptime & SSL — the highest-value, lowest-effort layer

**`blackbox_exporter`** for alerting rules:

| Metric | Use |
|---|---|
| `probe_success` | Up/down |
| `probe_http_status_code` | Detects a 200→500 flip |
| `probe_duration_seconds` | End-to-end latency, broken down by phase |
| `probe_ssl_earliest_cert_expiry` | **Cert expiry — alert at 21 d, 14 d, 7 d** |
| `probe_http_content_length` | A page that returns 200 but is suddenly empty |
| `fail_if_body_not_matches_regexp` | Asserts the page rendered real content, not a friendly error page |

Modules to configure: `http_2xx`, `http_post_2xx` (API health endpoints), `tcp_connect` (DB ports, SMTP, IMAP), `icmp`, `dns` (check your own zones resolve, and that your resolvers answer), and `smtp_starttls` (mail certs expire too, and nobody monitors them).

**`ssl_exporter`** adds what Blackbox misses: certs as files on disk, **full-chain validation including intermediate expiry**, and issuer-change detection.

**Uptime Kuma** alongside — a friendly per-service uptime SLA view and a public status page for customers. Complements, doesn't replace, the Prometheus rules.

**Beyond HTTP 200:** synthetic transactions with Playwright or k6 — script a real login, a search, a checkout. "The homepage returns 200" and "users can log in" are very different claims.

### Node.js / PM2

Best signal comes from `prom-client` inside the app: request rate, error rate, duration histogram (**RED method**), event-loop lag (`nodejs_eventloop_lag_seconds` — the definitive Node health metric), heap used vs. limit, GC pause duration, and active handles.

For process-level data, a textfile collector from `pm2 jlist`:

```bash
#!/bin/bash
# cron */1 — pm2 restart count is your crash-loop detector
pm2 jlist 2>/dev/null | jq -r '.[] |
  "pm2_restarts{name=\"\(.name)\"} \(.pm2_env.restart_time)
pm2_uptime_seconds{name=\"\(.name)\"} \(.pm2_env.pm_uptime / 1000)
pm2_memory_bytes{name=\"\(.name)\"} \(.monit.memory)
pm2_cpu_percent{name=\"\(.name)\"} \(.monit.cpu)
pm2_status{name=\"\(.name)\"} \(if .pm2_env.status == "online" then 1 else 0 end)"' \
  > /var/lib/node_exporter/textfile/pm2.prom.$$ \
  && mv /var/lib/node_exporter/textfile/pm2.prom.$$ /var/lib/node_exporter/textfile/pm2.prom
```

**`increase(pm2_restarts[15m]) > 3` is your crash-loop alarm** — the app looks "up" on every check while restarting continuously.

### Python

`prometheus_client` with the appropriate middleware — `prometheus-fastapi-instrumentator`, `django-prometheus`, or the Flask WSGI wrapper. Use **multiprocess mode** under Gunicorn/uWSGI or your metrics will be per-worker and wrong.

Track request rate / error rate / latency percentiles, uncaught exception count, and worker saturation. For Celery, add `celery-exporter`: queue depth per queue (**the leading indicator of backlog**), task success/failure by task name, task duration, and worker liveness.

### PHP

`php-fpm_exporter` against the pool status page: **active vs. idle vs. total processes**, **listen queue length** (>0 means requests are waiting — you're out of workers), max children reached count, slow request count, and per-pool breakdown.

For web servers: `nginx-prometheus-exporter` (`stub_status`) or `apache_exporter` (`mod_status`) for connections, requests/s, and worker states. Then derive per-vhost request rate, status-code distribution, and latency percentiles from access logs via Alloy's log-to-metric stages — this gets you real per-site RED metrics without touching application code.

App-level instrumentation via `promphp/prometheus_client_php` where you control the code.

### WHM / cPanel

No mature off-the-shelf exporter — a small custom one against the WHM API v1 is the way:

| API call | Yields |
|---|---|
| `listaccts` | Account count, suspended accounts, package distribution |
| `servicestatus` | httpd, exim, dovecot, named, mysql, cpsrvd up/down |
| `loadavg` | Server load |
| `showbw` | Bandwidth per account |
| `get_disk_usage` | Disk quota per account |

**Also:** `exim -bpc` for **mail queue depth** (the classic early warning that a customer account is compromised and sending spam), bounce rate, deferred mail count, cPanel license expiry, backup job status, and per-account inode usage.

**RBL / blacklist monitoring** — check your mail IPs against Spamhaus, Barracuda, and SpamCop on a schedule. Listing kills deliverability within minutes and you will otherwise find out from an angry customer. This is a genuine gap for anyone running WHM.

### Plesk

Same shape via the Plesk REST API (`/api/v2/`) and the `plesk` CLI: subscription and domain counts, per-subscription disk and traffic usage, service states, license expiry, backup status, and per-domain PHP version (for EOL tracking).

### Alerts
`P1` site down >2 min · SSL expires <7 d · SSL chain invalid · pm2 crash loop · php-fpm queue backing up · mail queue >5000 · IP on a blacklist · Celery queue depth exploding
`P2` SSL expires <21 d · error rate >1% · p95 latency 2× baseline · event-loop lag >100 ms · php-fpm max children reached · service restart detected
`P3` SSL expires <30 d · PHP/Node/Python version EOL approaching · license expiry <30 d

---

## 10. What's missing from the original list

Ranked by impact. Details behind the summary in [README.md § 7](README.md).

### 1. UPS / power — the biggest gap
**NUT (Network UPS Tools)** + `nut_exporter`, or SNMP if your UPS has a network management card. Track battery charge %, estimated runtime remaining, input and output voltage, load %, battery age and last self-test result, and on-battery events.

Critically, NUT also **triggers automated graceful shutdown** of your Proxmox hosts when runtime drops below a threshold. Without it, a long outage means unclean shutdown of every VM — and unclean shutdowns are where filesystem corruption and failed RAID rebuilds come from.

`P1` on battery · runtime <10 min · battery replacement indicated · self-test failed

### 2. PDU metering
Metered or switched PDUs over SNMP: per-outlet amperage, per-bank load, total kW. Tells you your true power headroom, prevents tripping a breaker when you add a server, and — with switched PDUs — gives you remote power-cycling for a wedged machine.

### 3. Environmental sensors
Room temperature and humidity, cold-aisle vs. hot-aisle delta, and a **water-leak sensor** under any AC unit. A ~$60 ESP32 + SHT31 exporting to Prometheus, or a commercial unit over SNMP. Add a door contact sensor for physical access logging — correlated with your NVR footage, that's a complete physical-security record.

`P1` room temp >30 °C · water detected · humidity outside 40–60%

### 4. Internet line quality over time
**Smokeping** (or Blackbox ICMP at 10 s resolution) per WAN: latency distribution, jitter, and loss plotted continuously. Add a periodic speedtest exporter for actual throughput vs. your committed rate.

This is the artifact you send the ISP when they insist the line is fine. Up/down monitoring cannot prove intermittent packet loss; a month of Smokeping graphs can.

### 5. NetFlow / traffic analysis — ntopng
SNMP tells you the pipe is full. **NetFlow tells you which host, which protocol, and which remote endpoint.** Install `softflowd` on pfSense, export to ntopng, and you get top talkers, per-host bandwidth, application-protocol breakdown, and historical flow search. During a saturation incident this turns a 40-minute investigation into a 40-second one.

### 6. Backup monitoring as a first-class concern
Not just "did the job report success" — track time since last success per VM and per database, backup size trend, restore-test results, and off-site copy lag. **Alert on absence** (`time() - last_success > 26h`), because the most common backup failure is one that quietly stopped being scheduled.

### 7. Config backup & drift — Oxidized
Git-versioned configs for every switch and pfSense, pulled nightly with a diff notification on change. When something breaks at 2 a.m. after "nobody changed anything", the diff is the answer. Pair with `etckeeper` or Ansible drift-checks on the servers.

### 8. Security monitoring
- **CrowdSec** — lightweight behavioural detection with a **pfSense firewall bouncer** and nginx/apache bouncers. Blocks in real time and benefits from a community blocklist.
- **Wazuh** — HIDS: file-integrity monitoring on `/etc` and web roots (**catches web-shell uploads**, which matters a lot for shared hosting), rootkit detection, **CVE detection per host** from package inventory, log correlation, and CIS/PCI compliance reporting.
- **Suricata** on pfSense or a switch SPAN port for IDS, logs into Loki and Wazuh.

For a shared-hosting environment, FIM on customer web roots is the single highest-value security control here.

### 9. Certificate inventory beyond web
iDRAC certs, switch management certs, internal CA expiry, mail server certs, VPN certs. All expire, none are usually monitored, all cause confusing outages when they do.

### 10. NetBox as source of truth
Racks, devices, IPs, VLANs, circuits, and cabling — plus a **Prometheus HTTP service-discovery endpoint** so adding a device to NetBox automatically adds it to monitoring. This is what stops your target lists rotting six months in.

### 11. SLOs and error budgets
Define availability and latency objectives for your key services; **Sloth** generates the Prometheus recording and alerting rules from a short spec. Multi-window burn-rate alerts are dramatically less noisy than threshold alerts and tell you whether a problem actually threatens your commitments.

### 12. Capacity planning
Grafana dashboards using `predict_linear(node_filesystem_avail_bytes[7d], 30*24*3600) < 0` — "which disks fill within 30 days". Same technique for RAM growth, VM density per host, connection-pool headroom, and bandwidth trend against your committed rate. Turns emergencies into purchase orders.

### 13. Change correlation
Push deploy and maintenance events into Grafana as **annotations**. When a graph turns bad, the vertical line showing "deployed v2.3.1" answers the question immediately.

### 14. Public status page
Uptime Kuma or Gatus, hosted off-site. When the DC is down, a status page inside the DC is useless — which is exactly when customers are looking for it.

---

## 11. Quick reference — exporter per target

| Target | Exporter | Port |
|---|---|---|
| pfSense | node_exporter + snmp_exporter + softflowd | 9100 / 9116 |
| Cisco / HP switches | snmp_exporter (+ LibreNMS) | 9116 |
| HikVision NVR | custom ISAPI exporter + blackbox | 9xxx / 9115 |
| Dell iDRAC 6/7 | ipmi_exporter + snmp_exporter | 9290 / 9116 |
| Proxmox cluster | prometheus-pve-exporter | 9221 |
| PVE hosts & VMs | node_exporter + smartctl_exporter | 9100 / 9633 |
| Windows VMs | windows_exporter | 9182 |
| Processes | process_exporter | 9256 |
| MySQL / MariaDB | mysqld_exporter | 9104 |
| PostgreSQL | postgres_exporter | 9187 |
| Redis | redis_exporter | 9121 |
| Nginx / Apache | nginx-prometheus-exporter / apache_exporter | 9113 / 9117 |
| PHP-FPM | php-fpm_exporter | 9253 |
| Node.js / PM2 | prom-client + pm2 textfile collector | app / 9100 |
| Python | prometheus_client middleware | app |
| Celery | celery-exporter | 9808 |
| WHM / cPanel | custom WHM API v1 exporter | 9xxx |
| Plesk | custom REST API exporter | 9xxx |
| Websites & SSL | blackbox_exporter + ssl_exporter | 9115 / 9219 |
| UPS | nut_exporter | 9199 |
| Logs | Grafana Alloy → Loki | 12345 → 3100 |
| SNMP traps | snmptrapd → Alloy | 162 |
| NetFlow | softflowd → ntopng | 3002 |
