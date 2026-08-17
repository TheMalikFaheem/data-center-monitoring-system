# alertmanager.yml — Alertmanager configuration.
#
# Rendered from templates/alertmanager.yml.tpl by install-alertmanager.sh.
# The installer NEVER overwrites this file once it exists: if a newer render
# differs, it is saved next to this file as alertmanager.yml.new for review.
#
# After editing, validate and reload with:
#   amtool check-config /etc/alertmanager/alertmanager.yml
#   systemctl reload alertmanager
#
# ── HOW TO ENABLE TELEGRAM ALERTS ─────────────────────────────────────────────
# 1. Create a Telegram bot:
#    - Open Telegram → search @BotFather → /newbot → follow prompts
#    - Copy the bot token (format: 123456789:ABCDef...)
#
# 2. Get your chat ID:
#    - Send any message to your bot
#    - Open: https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates
#    - Find "chat":{"id": -123456789} — that number is your chat ID
#    - For a group: add the bot to the group, send a message, get the group chat ID
#
# 3. Add to configs/environment.local.yml (gitignored — never committed):
#    telegram_bot_token: "123456789:ABCDef_your_token_here"
#    telegram_chat_id: "-123456789"   # negative for groups, positive for direct
#
# 4. Re-render this config:
#    sudo ./monitorctl install alertmanager --reinstall
#
# ── HOW TO ENABLE EMAIL ALERTS ────────────────────────────────────────────────
# Add to configs/environment.local.yml:
#   smtp_smarthost: "smtp.gmail.com:587"
#   smtp_from: "alerts@yourdomain.com"
#   smtp_auth_username: "alerts@yourdomain.com"
#   smtp_auth_password: "your_gmail_app_password"  # Gmail: Settings → App Passwords
#   alert_email_to: "you@yourdomain.com"

global:
  resolve_timeout: 5m

  # ── SMTP / Email (optional) ───────────────────────────────────────────────
  # Uncomment after adding smtp_* keys to environment.local.yml
  # smtp_smarthost: '{{SMTP_SMARTHOST}}'
  # smtp_from: '{{SMTP_FROM}}'
  # smtp_auth_username: '{{SMTP_AUTH_USER}}'
  # smtp_auth_password: '{{SMTP_AUTH_PASSWORD}}'
  # smtp_require_tls: true

# ── Routing tree ──────────────────────────────────────────────────────────────
# How alerts flow to receivers.
# Priority: critical → telegram-critical, warning → telegram-warning, rest → null
route:
  group_by: ['alertname', 'instance', 'job']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  receiver: 'null'                     # default: discard (change to telegram or email when ready)

  routes:
    # Critical alerts — fire immediately, repeat every hour
    - match:
        severity: critical
      receiver: telegram               # ← change to 'email' if you prefer email
      group_wait: 10s
      repeat_interval: 1h

    # Warning alerts — standard timing
    - match:
        severity: warning
      receiver: telegram               # ← change to 'email' or 'null' to silence warnings
      repeat_interval: 4h

    # SSL certificate expiry — informational, one notification per day
    - match:
        alertname: SSLCertExpiringSoon
      receiver: telegram
      repeat_interval: 24h

# ── Receivers ────────────────────────────────────────────────────────────────
receivers:
  - name: 'null'
    # Intentionally empty — discards alerts silently.

  # ── Telegram receiver ─────────────────────────────────────────────────────
  # Requires: telegram_bot_token + telegram_chat_id in environment.local.yml
  # See setup instructions at the top of this file.
  - name: telegram
    telegram_configs:
      - bot_token: '{{TELEGRAM_BOT_TOKEN}}'
        chat_id: {{TELEGRAM_CHAT_ID}}
        send_resolved: true
        parse_mode: 'HTML'
        message: |
          {{ if eq .Status "firing" }}🔴{{ else }}✅{{ end }} <b>{{ .GroupLabels.alertname }}</b>
          {{ range .Alerts }}
          <b>Instance:</b> {{ .Labels.instance }}
          <b>Severity:</b> {{ .Labels.severity }}
          <b>Summary:</b> {{ .Annotations.summary }}
          {{ if .Annotations.description }}<b>Detail:</b> {{ .Annotations.description }}{{ end }}
          {{ end }}

  # ── Email receiver ────────────────────────────────────────────────────────
  # Uncomment + add smtp_* keys to environment.local.yml to enable.
  # - name: email
  #   email_configs:
  #     - to: '{{ALERT_EMAIL_TO}}'
  #       send_resolved: true
  #       html: '{{ template "email.default.html" . }}'

# ── Inhibition rules ──────────────────────────────────────────────────────────
# Suppress child alerts when a higher-level alert is already firing.
inhibit_rules:
  # If a host is completely down, don't also fire CPU/memory/disk alerts for it
  - source_match:
      alertname: InstanceDown
    target_match_re:
      alertname: .+
    equal:
      - instance

  # If an SNMP device is unreachable, don't fire interface-level alerts for it
  - source_match:
      alertname: SNMPTargetDown
    target_match_re:
      alertname: InterfaceDown|HighInterfaceErrors
    equal:
      - instance
