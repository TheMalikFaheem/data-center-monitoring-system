# nginx-monitoring.conf.tpl — reverse proxy for the monitoring stack.
# Rendered by install-nginx.sh. Tokens: {{DOMAIN}} {{GRAFANA_PORT}} {{PROMETHEUS_PORT}}
# {{ALERTMANAGER_PORT}} {{LOKI_PORT}}
#
# Architecture after this is deployed:
#
#   Internet → 443/TLS → nginx → :3000 Grafana         (/ — Grafana handles its own auth)
#                              → :9090 Prometheus       (/prometheus/ — basic auth)
#                              → :9093 Alertmanager     (/alertmanager/ — basic auth)
#                              → :9090 remote_write     (/api/v1/write — basic auth, for on-prem agents)
#                              → :3100 Loki push        (/loki/ — basic auth, for on-prem Alloy)
#
#   Internet → 80 → nginx → 301 redirect to HTTPS (except /.well-known/acme-challenge/)
#
# BASIC AUTH is used for Prometheus, Alertmanager, and the push endpoints.
# Credentials: /etc/nginx/.htpasswd-monitoring (managed by install-nginx.sh)
# Grafana has its own login page — nginx does not add auth in front of it.
#
# To add a monitoring scrape target for a new on-prem server, have its Alloy
# config point to: https://{{DOMAIN}}/loki/loki/api/v1/push  (basic auth)
# And Prometheus remote_write to: https://{{DOMAIN}}/api/v1/write (basic auth)

# Rate limiting — apply to push endpoints to prevent abuse
limit_req_zone $binary_remote_addr zone=push_limit:10m rate=100r/s;

# ── HTTP server — ACME challenge + redirect ───────────────────────────────
server {
    listen 80;
    listen [::]:80;
    server_name {{DOMAIN}};

    # Let's Encrypt ACME HTTP-01 challenge (certbot needs this)
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
        try_files $uri =404;
    }

    # Everything else → HTTPS
    location / {
        return 301 https://$host$request_uri;
    }
}

# ── HTTPS main server ─────────────────────────────────────────────────────
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name {{DOMAIN}};

    # SSL — managed by certbot; do not edit these paths by hand
    ssl_certificate     /etc/letsencrypt/live/{{DOMAIN}}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/{{DOMAIN}}/privkey.pem;

    # Modern TLS configuration (Mozilla Intermediate, 2024)
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;

    # HSTS — tell browsers to always use HTTPS for this domain
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;

    # Proxy timeouts (Grafana dashboards can be slow on first load)
    proxy_connect_timeout 10s;
    proxy_send_timeout    60s;
    proxy_read_timeout    60s;
    proxy_buffering       off;

    # ── Grafana — public (Grafana handles its own login) ─────────────────
    location / {
        proxy_pass http://127.0.0.1:{{GRAFANA_PORT}};
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        # WebSocket support for Grafana Live
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    # ── Prometheus — basic auth required ─────────────────────────────────
    location /prometheus/ {
        auth_basic           "Monitoring — Prometheus";
        auth_basic_user_file /etc/nginx/.htpasswd-monitoring;

        proxy_pass http://127.0.0.1:{{PROMETHEUS_PORT}}/;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        # Fix relative links in Prometheus UI when served from /prometheus/
        sub_filter_once off;
        proxy_redirect off;
    }

    # ── Alertmanager — basic auth required ───────────────────────────────
    location /alertmanager/ {
        auth_basic           "Monitoring — Alertmanager";
        auth_basic_user_file /etc/nginx/.htpasswd-monitoring;

        proxy_pass http://127.0.0.1:{{ALERTMANAGER_PORT}}/;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_redirect off;
    }

    # ── Prometheus remote_write — for on-prem Alloy agents ───────────────
    # On-prem server Alloy config:
    #   remote_write { endpoint { url = "https://{{DOMAIN}}/api/v1/write"
    #     basic_auth { username = "admin" password = "..." } } }
    location /api/v1/write {
        auth_basic           "Monitoring — remote write";
        auth_basic_user_file /etc/nginx/.htpasswd-monitoring;

        limit_req zone=push_limit burst=200 nodelay;

        proxy_pass http://127.0.0.1:{{PROMETHEUS_PORT}}/api/v1/write;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_request_buffering off;
        client_max_body_size 32m;
    }

    # ── Loki push endpoint — for on-prem Alloy agents ────────────────────
    # On-prem server Alloy config:
    #   loki.write "default" { endpoint { url = "https://{{DOMAIN}}/loki/loki/api/v1/push"
    #     basic_auth { username = "admin" password = "..." } } }
    location /loki/ {
        auth_basic           "Monitoring — Loki push";
        auth_basic_user_file /etc/nginx/.htpasswd-monitoring;

        limit_req zone=push_limit burst=200 nodelay;

        proxy_pass http://127.0.0.1:{{LOKI_PORT}}/;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_request_buffering off;
        client_max_body_size 32m;
    }

    # ── Health endpoint — unauthenticated (for load balancer probes) ──────
    location /nginx-health {
        access_log off;
        return 200 "OK\n";
        add_header Content-Type text/plain;
    }
}
