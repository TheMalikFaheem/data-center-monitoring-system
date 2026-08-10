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
# Notification channels are configured in environment.local.yml (gitignored).
# Fill in the environment.local.yml keys and re-run the installer, or edit
# this file directly and reload.

global:
  # How long to wait before declaring an alert resolved if no "resolved" firing
  # arrives from Prometheus. Set conservatively — too short causes alert flap.
  resolve_timeout: 5m

  # ── Email (optional) ───────────────────────────────────────────────────────
  # Uncomment and fill in environment.local.yml:
  #   smtp_smarthost: "smtp.example.com:587"
  #   smtp_from: "alertmanager@example.com"
  #   smtp_auth_username: "alertmanager@example.com"
  #   smtp_auth_password: "your_app_password"
  # smtp_smarthost: '{{SMTP_SMARTHOST}}'
  # smtp_from: '{{SMTP_FROM}}'
  # smtp_auth_username: '{{SMTP_AUTH_USER}}'
  # smtp_auth_password: '{{SMTP_AUTH_PASSWORD}}'
  # smtp_require_tls: true

# ── Routing tree ─────────────────────────────────────────────────────────────
# By default all alerts go to the "null" receiver (fires, logs, goes nowhere).
# Add real receivers below and route to them when ready.
route:
  group_by: ['alertname', 'instance', 'job']
  group_wait: 30s           # wait 30s before sending first notification
  group_interval: 5m        # minimum gap between group notifications
  repeat_interval: 4h       # resend if still firing after 4h
  receiver: 'null'

  # Example: route critical alerts to email (uncomment once smtp is configured)
  # routes:
  #   - match:
  #       severity: critical
  #     receiver: email
  #     repeat_interval: 1h

# ── Receivers ─────────────────────────────────────────────────────────────────
receivers:
  - name: 'null'
    # Intentionally empty: a named receiver that discards everything.
    # Replace or add routes above to send alerts to real channels.

  # ── Email receiver ─────────────────────────────────────────────────────────
  # Uncomment, fill in, and add a route above to enable.
  # - name: email
  #   email_configs:
  #     - to: '{{ALERT_EMAIL_TO}}'
  #       send_resolved: true
  #       html: '{{ template "email.default.html" . }}'

  # ── Webhook (e.g. Telegram bot, PagerDuty, custom HTTP endpoint) ──────────
  # - name: webhook
  #   webhook_configs:
  #     - url: 'http://127.0.0.1:5001/alert'
  #       send_resolved: true

# ── Inhibition ─────────────────────────────────────────────────────────────
# Silence child alerts when a parent fires.
# Example: suppress all alerts for an instance when InstanceDown fires for it.
inhibit_rules:
  - source_match:
      alertname: InstanceDown
    target_match_re:
      alertname: .+
    equal:
      - instance
