# Getting Started — No Monitoring Experience Needed

This guide assumes you know how to run a server, but have **never used Prometheus, Grafana, or Docker**. Every command is copy-paste. After each step there's a "you should see" so you know it worked.

**Time needed:** about 90 minutes for Steps 1–11. You get useful alerts by Step 10.

---

## What you're building

By the end of this guide you will have one web page showing whether every website you host is up, how fast it responds, and how many days until each SSL certificate expires — plus Telegram messages on your phone when something breaks.

That's Phase 0. Later phases add your switches, firewall, servers, and databases. **Don't try to do everything at once.** Get this working first.

---

## The pieces, in plain language

You're installing six small programs. Here's what each one actually does:

| Program | What it does | Think of it as |
|---|---|---|
| **Prometheus** | Every 30 seconds it asks each machine and website "how are you doing?" and remembers every answer | The clipboard that writes everything down |
| **Node exporter** | A tiny program that sits on a server and answers Prometheus' questions about CPU, RAM, disk | The thing being asked |
| **Blackbox exporter** | Visits your websites from outside, like a customer would | A robot visitor |
| **Grafana** | Draws the graphs and dashboards you look at | The screen |
| **Alertmanager** | Sends you a message when a rule is broken, and stops it sending 40 messages about one problem | The messenger |
| **Uptime Kuma** | A simple all-in-one version — click, type a URL, get alerts. Easiest possible start | Training wheels (useful ones) |

One important idea: **Prometheus reaches out to things, they don't report in to it.** So the monitoring server needs network permission to reach your devices — not the other way around. This matters when you write pfSense rules later.

**Docker** runs each of these six programs in its own sealed box ("container"), so they can't conflict with each other or mess up the operating system. You never install these programs directly — Docker downloads and runs them for you.

---

## Step 1 — Make a virtual machine on Proxmox

You already run Proxmox, so this is the fastest start. In the Proxmox web interface:

1. Click **Create VM** (top right)
2. **Name:** `monitoring`
3. **OS:** upload/select the **Ubuntu Server 24.04 LTS** ISO ([download here](https://ubuntu.com/download/server))
4. **System:** leave defaults, but tick **Qemu Agent**
5. **Disk:** `60 GB`
6. **CPU:** `2 cores`
7. **Memory:** `4096 MB`
8. **Network:** your normal bridge

> **A word about where this lives.** Ideally monitoring runs on a *separate physical machine*, because if your Proxmox cluster dies, you want monitoring to survive and tell you why. Starting as a VM is fine and gets you value today — just move it to a small dedicated box (a cheap mini-PC is plenty) once you're relying on it. Step 15 covers why this matters.

---

## Step 2 — Install Ubuntu Server

Start the VM, open its console in Proxmox, and follow the installer. Accept the defaults except:

- **Set a username and password** you'll remember
- **Tick "Install OpenSSH server"** ← important, otherwise you can't connect to it
- Skip all the "featured server snaps"

When it finishes, reboot and log in at the console.

Now find its IP address:

```bash
hostname -I
```

**You should see** something like `192.168.1.60`. Write it down — this guide calls it `<SERVER-IP>` from now on.

---

## Step 3 — Connect from your Mac

Back on your Mac, open Terminal:

```bash
ssh yourusername@<SERVER-IP>
```

Type `yes` if it asks about authenticity, then your password.

**You should see** the Ubuntu welcome message and a prompt ending in `$`. Everything from here runs on the monitoring server, not your Mac.

---

## Step 4 — Install Docker

Copy and paste this whole block:

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
```

The second line lets you use Docker without typing `sudo` every time. For that to take effect you must log out and back in:

```bash
exit
```

Then reconnect (`ssh yourusername@<SERVER-IP>`) and check it worked:

```bash
docker run --rm hello-world
```

**You should see** "Hello from Docker!" — if you get "permission denied", you skipped the logout/login.

---

## Step 5 — Download this project

Install the GitHub tool and log in (same flow you used on your Mac):

```bash
sudo snap install gh
gh auth login
```

Answer: **GitHub.com** → **HTTPS** → **Yes** → **Login with a web browser**. It shows a code; open the URL on any device, paste the code, approve.

Now download the project:

```bash
gh repo clone TheMalikFaheem/data-center-monitoring-system
cd data-center-monitoring-system
ls
```

**You should see** `README.md  COVERAGE.md  GETTING-STARTED.md  docker-compose.yml  prometheus  grafana  alertmanager  blackbox`

---

## Step 6 — Set your password

The stack needs a Grafana admin password. Create your settings file:

```bash
cp .env.example .env
nano .env
```

Change `changeme` to a real password, and set your timezone. Save with **Ctrl+O**, **Enter**, then exit with **Ctrl+X**.

```
GRAFANA_ADMIN_PASSWORD=your-real-password-here
TZ=Asia/Karachi
```

> This `.env` file is git-ignored on purpose — it never gets uploaded to GitHub.

---

## Step 7 — Start everything

```bash
docker compose up -d
```

First run takes 2–3 minutes while it downloads. The `-d` means "run in the background".

**You should see** a list ending with `Started` for each of the six containers. Confirm:

```bash
docker compose ps
```

**You should see** all six with status `Up`. If any says `Restarting` or `Exited`, jump to [When something goes wrong](#when-something-goes-wrong).

---

## Step 8 — Check it's collecting

Open a browser on your Mac and go to:

```
http://<SERVER-IP>:9090/targets
```

**You should see** a page listing your scrape jobs. `prometheus`, `node`, and `blackbox-icmp` should show green **UP**. `blackbox-http` will be checking `example.com` for now — we'll fix that next.

This page is your single best troubleshooting tool. Anything red here means Prometheus can't reach that thing, and it tells you why.

---

## Step 9 — Your first real win (Uptime Kuma)

This is the fastest path to something genuinely useful. Go to:

```
http://<SERVER-IP>:3001
```

1. Create an admin account (first visit only)
2. Click **Add New Monitor**
3. **Monitor Type:** HTTP(s)
4. **Friendly Name:** whatever you'll recognise
5. **URL:** one of your real websites, e.g. `https://yoursite.com`
6. **Heartbeat Interval:** `60` seconds
7. Click **Save**

**You should see** a green bar appear within a minute, with response time in milliseconds and — scroll down — the **certificate expiry in days**.

Now add every site you host. This takes a few minutes of clicking and immediately gives you something you didn't have before.

---

## Step 10 — Alerts on your phone

Still in Uptime Kuma. First, create a Telegram bot — do this in the Telegram app:

1. Search for **@BotFather**, start a chat
2. Send `/newbot`
3. Give it a name and a username ending in `bot`
4. **It replies with a token** like `7823456789:AAF...` — copy it
5. Search for **@userinfobot**, start it, and it replies with **your chat ID** (a number) — copy that too

Back in Uptime Kuma:

1. **Settings** (top right) → **Notifications** → **Setup Notification**
2. **Notification Type:** Telegram
3. Paste the **Bot Token** and **Chat ID**
4. Click **Test** — your phone should buzz
5. Tick **Apply on all existing monitors**, then **Save**

**You should see** a test message on your phone. You now have working alerting. Genuinely — if you stop here, you've covered the most common cause of "we found out from a customer".

Keep that bot token handy; Step 14 reuses it.

---

## Step 11 — Grafana dashboards

```
http://<SERVER-IP>:3000
```

Log in with `admin` and the password you set in Step 6. Prometheus is already connected — nothing to configure.

Now import two ready-made dashboards that other people built:

1. Left menu → **Dashboards** → **New** → **Import**
2. In "Import via grafana.com" type **`1860`** → **Load** → select **Prometheus** → **Import**
3. Repeat with **`7587`**

**You should see:**
- Dashboard `1860` (*Node Exporter Full*) — full CPU/RAM/disk/network graphs for your monitoring server. This is the dashboard you'll use for every server you add.
- Dashboard `7587` (*Blackbox Exporter*) — website status and SSL expiry.

Take five minutes to click around 1860. Understanding this one dashboard is most of what you need to know about Grafana.

---

## Step 12 — Add your own devices (5 minutes, high value)

Right now Prometheus pings `1.1.1.1` and `8.8.8.8`. Let's add your real gear. Back in the SSH session:

```bash
nano prometheus/targets/ping.yml
```

Uncomment the examples (delete the `#` at the start of the lines) and replace with your real IPs — pfSense, both switches, the NVR, all three iDRAC cards, each camera. Save (**Ctrl+O**, **Enter**, **Ctrl+X**), then:

```bash
docker compose exec prometheus kill -HUP 1
```

That tells Prometheus to re-read its config without restarting.

**You should see** the new devices appear at `http://<SERVER-IP>:9090/targets` within a minute, under `blackbox-icmp`.

This is basic — just "does it answer ping" — but it means you'll know within three minutes when any device on that list drops off the network. That's a real gap closed for five minutes of typing.

Do the same for `prometheus/targets/websites.yml` with your real sites, so the Prometheus SSL alerts cover them too.

---

## Step 13 — Add your servers and VMs

To get CPU/RAM/disk from a machine, install node exporter **on that machine**. On any Debian, Ubuntu, or Proxmox host, it's one command:

```bash
sudo apt update && sudo apt install -y prometheus-node-exporter
```

That's it — it installs, starts, and survives reboots. Verify from the monitoring server:

```bash
curl -s http://<THAT-MACHINE-IP>:9100/metrics | head -5
```

**You should see** lines of text starting with `#`. That's the machine answering.

If you get nothing, its firewall is blocking port 9100. Allow it *only* from the monitoring server:

```bash
sudo ufw allow from <MONITORING-SERVER-IP> to any port 9100
```

Then register it on the monitoring server:

```bash
nano prometheus/targets/servers.yml
```

Uncomment and edit the examples — put the real IP and give each machine a `host:` name you'll recognise. Then reload:

```bash
docker compose exec prometheus kill -HUP 1
```

**You should see** the machine in Grafana dashboard 1860 — pick it from the dropdown at the top.

Repeat for all three Proxmox hosts and every VM. Once you've done three by hand, tell me and I'll write an Ansible playbook to do the rest in one command.

---

## Step 14 — Telegram for the deeper alerts

Uptime Kuma alerts on websites. Prometheus alerts on everything else — disk filling, CPU steal, clock drift, certificates, devices unreachable. Point those at Telegram too, reusing the bot from Step 10:

```bash
echo 'PASTE_YOUR_BOT_TOKEN_HERE' > alertmanager/telegram_token
chmod 600 alertmanager/telegram_token
nano alertmanager/alertmanager.yml
```

Find these four commented lines and delete the `#` from each, then put your chat ID in:

```yaml
    telegram_configs:
      - bot_token_file: /etc/alertmanager/telegram_token
        chat_id: -1001234567890
        parse_mode: HTML
```

Save, then restart:

```bash
docker compose restart alertmanager
docker compose logs alertmanager | tail -20
```

**You should see** no error lines. Check `http://<SERVER-IP>:9093` to see current alerts and confirm the receiver loaded.

To test it end-to-end, temporarily add a fake IP to `ping.yml` — you should get a Telegram message about three minutes later. Remove it afterwards.

---

## Step 15 — The one thing people always forget

Your monitoring server watches everything. **Nothing watches your monitoring server.**

If the power fails, or the Proxmox host running this VM dies, monitoring dies with it — and you receive **zero alerts**, which feels exactly like everything being fine.

The fix is a "deadman's switch". Prometheus already fires a permanent alert called `Watchdog` every 30 seconds (look at the bottom of `prometheus/rules/alerts.yml`). You need something *outside your building* to notice when it **stops**.

The simplest version, free: sign up at [healthchecks.io](https://healthchecks.io), create a check with a 5-minute period, and have Alertmanager ping its URL for the Watchdog alert. If your DC goes dark, healthchecks emails you within minutes.

I can wire this up when you're ready — it's about ten lines of config. Until then, be aware of the gap.

---

## Everyday commands

Run these from inside the project folder (`cd data-center-monitoring-system`):

| What you want | Command |
|---|---|
| Start everything | `docker compose up -d` |
| Stop everything | `docker compose down` |
| Restart one thing | `docker compose restart grafana` |
| See what's running | `docker compose ps` |
| Watch logs live | `docker compose logs -f` |
| Logs for one thing | `docker compose logs prometheus \| tail -50` |
| Reload Prometheus config | `docker compose exec prometheus kill -HUP 1` |
| Update to newer versions | `docker compose pull && docker compose up -d` |
| Disk used by monitoring | `docker system df` |

Your data survives `docker compose down` — it lives in Docker volumes, not the containers.

---

## When something goes wrong

**A container keeps restarting**

```bash
docker compose logs <name> | tail -30
```

Almost always a typo in a `.yml` file. YAML is fussy about indentation — use spaces, never tabs.

**A target shows red on the /targets page**

Read the error text next to it. The usual causes:
- `connection refused` → the program isn't running on that machine, or wrong port
- `context deadline exceeded` → a firewall is silently dropping it (pfSense rule needed)
- `no such host` → typo in the IP or hostname

**Grafana says "no data"**

Check the same query works in Prometheus first: go to `http://<SERVER-IP>:9090`, paste `up` in the box, press Execute. If Prometheus has no data, the problem is collection, not Grafana.

**I edited a config and now it won't start**

```bash
git diff                  # see exactly what you changed
git checkout <filename>   # undo your changes to one file
```

**Check a config file is valid before restarting**

```bash
docker compose exec prometheus promtool check config /etc/prometheus/prometheus.yml
docker compose exec prometheus promtool check rules /etc/prometheus/rules/alerts.yml
```

**Everything is broken, start clean** (deletes collected history, keeps configs):

```bash
docker compose down -v && docker compose up -d
```

---

## Glossary

**Metric** — one measured number with a name, e.g. `node_memory_MemAvailable_bytes`.

**Label** — a tag on a metric that says which thing it came from, e.g. `host="db01"`. Labels are how you filter graphs.

**Target** — something Prometheus collects from.

**Scrape** — one round of collecting. Yours happens every 30 seconds.

**Exporter** — a small program that translates something's status into metrics Prometheus understands. There's one for nearly everything: MySQL, Redis, SNMP switches, iDRAC, Proxmox.

**PromQL** — Prometheus' query language. `up` is a valid query. So is `rate(node_cpu_seconds_total[5m])`. You'll rarely write it from scratch; imported dashboards contain it already.

**Rule / alert rule** — a saved PromQL query plus a threshold. When it's true for long enough, an alert fires.

**`for: 5m`** — how long a condition must stay true before alerting. This is what stops a two-second network blip waking you up.

**Container** — one program in a sealed box. **Image** — the downloadable template a container is made from. **Volume** — a folder Docker manages that survives container deletion; this is where your history lives.

**Cardinality** — how many unique label combinations exist. High cardinality (labelling by request ID, user ID, or IP) is the main way people accidentally break Prometheus. Label by host, service, and site — never by anything unique per request.

---

## What next

You've done Phase 0. From [README.md](README.md), the remaining phases in order:

- **Phase 1 — Compute.** node exporter on all Proxmox hosts and VMs, plus the Proxmox cluster exporter. Gets you CPU steal time and per-VM resource use.
- **Phase 2 — Infrastructure.** SNMP for pfSense and your switches, IPMI for the three iDRACs, a custom exporter for the HikVision NVR. Real per-port bandwidth, PSU and fan health, camera status.
- **Phase 3 — Logs.** Loki, so you can search every log from every machine in one box.
- **Phase 4 — Services.** MySQL, Postgres, Redis, PHP-FPM, PM2, WHM.
- **Phase 5 — Physical.** UPS monitoring (**the biggest gap in your current setup** — see [README § 7](README.md)), temperature sensors, NetFlow.

[COVERAGE.md](COVERAGE.md) has the exact metrics and thresholds for every one of these when you get there.

**Suggested order if you want my opinion:** finish Step 12 and 13 for all your machines, then do UPS monitoring from Phase 5 out of order — it's the one gap that can cost you data rather than just visibility.
