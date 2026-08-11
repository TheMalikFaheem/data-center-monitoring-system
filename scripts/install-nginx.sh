#!/usr/bin/env bash
#
# install-nginx.sh — install nginx as a reverse proxy for the monitoring stack
# and obtain a Let's Encrypt SSL certificate via certbot.
#
# PREREQUISITES (must be done by operator before running this installer):
#
#   1. Point your domain's A record to this server's public IP.
#      Example: monitor01.example.com → 203.0.113.42
#
#   2. Set in configs/environment.local.yml:
#        nginx_domain: "monitor01.example.com"
#        nginx_admin_password: "your-strong-password-here"
#
#   3. Open ports 80 and 443 in your cloud firewall / UFW:
#        ufw allow 80/tcp comment "nginx HTTP (ACME challenge)"
#        ufw allow 443/tcp comment "nginx HTTPS"
#
# WHAT THIS INSTALLER DOES
#   - installs nginx from the Ubuntu system repo
#   - installs certbot + python3-certbot-nginx
#   - renders the nginx reverse proxy config from templates/
#   - sets up HTTP basic auth credentials for Prometheus, Alertmanager, push endpoints
#   - runs certbot to obtain/renew the SSL certificate
#   - enables UFW rules (if UFW is active)
#   - enables and starts nginx
#   - configures Prometheus --web.enable-remote-write-receiver flag (for remote_write)
#
# AFTER INSTALL — connect on-prem agents:
#   Prometheus remote_write: https://<domain>/api/v1/write  (basic auth)
#   Loki push:               https://<domain>/loki/loki/api/v1/push (basic auth)
#   Credentials:             nginx_admin_user / nginx_admin_password
#
# Usage: sudo ./scripts/install-nginx.sh [--reinstall] [--no-certbot]
#   --reinstall   re-render config and reload even if already installed
#   --no-certbot  skip certbot (HTTP only, for testing behind a reverse proxy)

set -Eeuo pipefail
source "$(dirname "$(readlink -f "$0")")/common.sh"

COMPONENT="nginx"
REINSTALL=0
NO_CERTBOT=0
for arg in "$@"; do
    case "$arg" in
        --reinstall)  REINSTALL=1 ;;
        --no-certbot) NO_CERTBOT=1 ;;
    esac
done

setup_error_trap
log info "=== nginx reverse proxy installer starting ==="

# --- 1. Preflight -----------------------------------------------------------
require_root
require_ubuntu_2404
require_commands apt-get

# --- 2. Read required settings ----------------------------------------------
DOMAIN=$(yaml_get "$CONFIG_DIR/environment.local.yml" "nginx_domain" 2>/dev/null || true)
if [[ -z "$DOMAIN" ]]; then
    die "nginx_domain is not set in configs/environment.local.yml.
Set it before running this installer:
  echo 'nginx_domain: \"monitor01.example.com\"' >> configs/environment.local.yml
  echo 'nginx_admin_password: \"your-strong-password\"' >> configs/environment.local.yml
DNS MUST point ${DOMAIN:-your-domain} to this server's IP before certbot can run."
fi

ADMIN_USER=$(yaml_get "$CONFIG_DIR/environment.local.yml" "nginx_admin_user" 2>/dev/null || echo "admin")
ADMIN_PASS=$(yaml_get "$CONFIG_DIR/environment.local.yml" "nginx_admin_password" 2>/dev/null || true)
if [[ -z "$ADMIN_PASS" ]]; then
    die "nginx_admin_password is not set in configs/environment.local.yml.
  echo 'nginx_admin_password: \"your-strong-password\"' >> configs/environment.local.yml"
fi

CERTBOT_EMAIL=$(yaml_get "$CONFIG_DIR/environment.local.yml" "nginx_certbot_email" 2>/dev/null || true)

# Read port settings from environment
GRAFANA_PORT=$(yaml_get "$CONFIG_DIR/environment.yml" "grafana_listen" 2>/dev/null || echo "127.0.0.1:3000")
GRAFANA_PORT="${GRAFANA_PORT##*:}"
PROMETHEUS_PORT=$(yaml_get "$CONFIG_DIR/environment.yml" "prometheus_listen" 2>/dev/null || echo "127.0.0.1:9090")
PROMETHEUS_PORT="${PROMETHEUS_PORT##*:}"
ALERTMANAGER_PORT=$(yaml_get "$CONFIG_DIR/environment.yml" "alertmanager_listen" 2>/dev/null || echo "127.0.0.1:9093")
ALERTMANAGER_PORT="${ALERTMANAGER_PORT##*:}"
LOKI_PORT=$(yaml_get "$CONFIG_DIR/environment.yml" "loki_listen" 2>/dev/null || echo "127.0.0.1:3100")
LOKI_PORT="${LOKI_PORT##*:}"

log info "domain:      $DOMAIN"
log info "admin user:  $ADMIN_USER"
log info "grafana:     :$GRAFANA_PORT"
log info "prometheus:  :$PROMETHEUS_PORT"
log info "alertmanager :$ALERTMANAGER_PORT"
log info "loki:        :$LOKI_PORT"
[[ $NO_CERTBOT -eq 1 ]] && log warn "--no-certbot: HTTP-only mode (no SSL certificate)"

# --- 3. Check if already installed ------------------------------------------
if [[ $REINSTALL -eq 0 ]] && dpkg -l nginx 2>/dev/null | grep -q '^ii' \
   && [[ -f /etc/nginx/sites-enabled/monitoring ]]; then
    log info "nginx already installed — verifying and reloading"
    nginx -t && systemctl reload nginx
    log info "nothing to do (use --reinstall to force reconfiguration)"
    exit 0
fi

# --- 4. Install nginx and certbot from system repos -------------------------
log info "installing nginx + certbot..."
apt-get update -q
apt-get install -y nginx certbot python3-certbot-nginx apache2-utils
log info "nginx + certbot installed"

# apache2-utils provides htpasswd

# --- 5. Render nginx config from template -----------------------------------
log info "rendering nginx config..."
RENDERED_CONF=$(mktemp)
sed \
    -e "s/{{DOMAIN}}/$DOMAIN/g" \
    -e "s/{{GRAFANA_PORT}}/$GRAFANA_PORT/g" \
    -e "s/{{PROMETHEUS_PORT}}/$PROMETHEUS_PORT/g" \
    -e "s/{{ALERTMANAGER_PORT}}/$ALERTMANAGER_PORT/g" \
    -e "s/{{LOKI_PORT}}/$LOKI_PORT/g" \
    "$TEMPLATE_DIR/nginx-monitoring.conf.tpl" > "$RENDERED_CONF"

# --- 6. Configure basic auth credentials ------------------------------------
log info "setting up basic auth..."
# htpasswd -B = bcrypt (strong)
htpasswd -Bbn "$ADMIN_USER" "$ADMIN_PASS" > /etc/nginx/.htpasswd-monitoring
chmod 0640 /etc/nginx/.htpasswd-monitoring
chown root:www-data /etc/nginx/.htpasswd-monitoring
log info "htpasswd written to /etc/nginx/.htpasswd-monitoring"

# --- 7. Install config (HTTP-only version first for certbot ACME) -----------
# certbot --nginx needs the server_name directive to be present before
# it can do the HTTP-01 challenge. We install the full template which
# references the SSL cert paths. If SSL certs don't exist yet, certbot
# will add them. We use a temporary HTTP-only override if certs are absent.

SITES_AVAIL="/etc/nginx/sites-available/monitoring"
SITES_ENABLED="/etc/nginx/sites-enabled/monitoring"

if [[ $NO_CERTBOT -eq 1 ]]; then
    # HTTP-only config — no SSL blocks
    cat > "$SITES_AVAIL" << HTTPONLY
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location /prometheus/ {
        auth_basic           "Monitoring — Prometheus";
        auth_basic_user_file /etc/nginx/.htpasswd-monitoring;
        proxy_pass http://127.0.0.1:${PROMETHEUS_PORT}/;
        proxy_set_header Host              \$host;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    location /alertmanager/ {
        auth_basic           "Monitoring — Alertmanager";
        auth_basic_user_file /etc/nginx/.htpasswd-monitoring;
        proxy_pass http://127.0.0.1:${ALERTMANAGER_PORT}/;
        proxy_set_header Host              \$host;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    location / {
        proxy_pass http://127.0.0.1:${GRAFANA_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header Upgrade           \$http_upgrade;
        proxy_set_header Connection        "upgrade";
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    location /nginx-health { return 200 "OK\n"; add_header Content-Type text/plain; }
}
HTTPONLY
    log warn "HTTP-only mode — Grafana, Prometheus, and Alertmanager available via HTTP only"
else
    # Install the full HTTPS template. If certs don't exist yet, certbot
    # will be run below and nginx reloaded afterward.
    if [[ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
        # Create a minimal HTTP-only config first so nginx starts
        cat > "$SITES_AVAIL" << PRE_CERT
server {
    listen 80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 200 "nginx running — certbot pending\n"; }
}
PRE_CERT
    else
        install -m 0644 "$RENDERED_CONF" "$SITES_AVAIL"
    fi
fi

# Remove the default site to avoid conflicts
rm -f /etc/nginx/sites-enabled/default

# Enable our site
ln -sf "$SITES_AVAIL" "$SITES_ENABLED"

# Create ACME challenge web root
mkdir -p /var/www/certbot

# Test config before starting
nginx -t || die "nginx config test failed — review $SITES_AVAIL"

# --- 8. Start nginx ---------------------------------------------------------
if systemctl is-active --quiet nginx; then
    systemctl reload nginx
    log info "nginx reloaded"
else
    systemctl enable --now nginx
    log info "nginx enabled and started"
fi

# --- 9. Obtain SSL certificate (certbot) ------------------------------------
if [[ $NO_CERTBOT -eq 0 ]]; then
    if [[ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
        log info "obtaining Let's Encrypt certificate for $DOMAIN..."
        if [[ -n "$CERTBOT_EMAIL" ]]; then
            certbot --nginx \
                -d "$DOMAIN" \
                --agree-tos \
                --non-interactive \
                --email "$CERTBOT_EMAIL" \
                --redirect \
                || die "certbot failed — check that DNS for $DOMAIN points to this server's IP"
        else
            certbot --nginx \
                -d "$DOMAIN" \
                --agree-tos \
                --non-interactive \
                --register-unsafely-without-email \
                --redirect \
                || die "certbot failed — check DNS.
To set an email: echo 'nginx_certbot_email: \"you@example.com\"' >> configs/environment.local.yml"
        fi
        log info "SSL certificate obtained"
    else
        log info "SSL certificate already exists — skipping certbot"
    fi

    # Now install the full HTTPS config (certbot may have already done this)
    if nginx -T 2>/dev/null | grep -q "ssl_certificate"; then
        log info "HTTPS config already active (certbot handled it)"
    else
        install -m 0644 "$RENDERED_CONF" "$SITES_AVAIL"
        nginx -t && systemctl reload nginx
        log info "HTTPS config installed and nginx reloaded"
    fi

    # Set up certbot auto-renewal timer
    systemctl enable --now certbot.timer 2>/dev/null \
        || log warn "certbot.timer not found — check certbot installed correctly"
    log info "certbot auto-renewal: $(systemctl is-enabled certbot.timer 2>/dev/null || echo 'unknown')"
fi

# --- 10. Configure UFW -------------------------------------------------------
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
    log info "configuring UFW rules..."
    ufw allow 'Nginx Full' 2>/dev/null \
        || { ufw allow 80/tcp; ufw allow 443/tcp; }
    log info "UFW: ports 80 and 443 opened"
else
    log warn "UFW not active — open ports 80 and 443 in your cloud firewall manually"
fi

# --- 11. Enable Prometheus remote_write receiver ----------------------------
# Add --web.enable-remote-write-receiver to Prometheus service so on-prem
# agents can push metrics via the /api/v1/write endpoint.
PROM_SERVICE="/etc/systemd/system/prometheus.service"
if [[ -f "$PROM_SERVICE" ]] && ! grep -q "web.enable-remote-write-receiver" "$PROM_SERVICE"; then
    log info "enabling Prometheus remote_write receiver..."
    sed -i 's|--web.listen-address=|--web.enable-remote-write-receiver \\\n    --web.listen-address=|' "$PROM_SERVICE"
    systemctl daemon-reload
    systemctl restart prometheus
    log info "Prometheus remote_write receiver enabled and restarted"
fi

rm -f "$RENDERED_CONF"

log info ""
log info "=== nginx installed successfully ==="
if [[ $NO_CERTBOT -eq 0 ]]; then
    log info "Grafana:      https://$DOMAIN/"
    log info "Prometheus:   https://$DOMAIN/prometheus/  (user: $ADMIN_USER)"
    log info "Alertmanager: https://$DOMAIN/alertmanager/  (user: $ADMIN_USER)"
    log info ""
    log info "On-prem agent remote_write: https://$DOMAIN/api/v1/write"
    log info "On-prem agent Loki push:    https://$DOMAIN/loki/loki/api/v1/push"
    log info "Credentials: $ADMIN_USER / <your nginx_admin_password>"
else
    log info "Grafana:      http://$DOMAIN/  (HTTP only — run without --no-certbot for HTTPS)"
fi
