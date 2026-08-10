# redis-exporter.service — rendered by install-redis-exporter.sh.
# Tokens: {{LISTEN}}
# Redis DSN is passed via environment file.

[Unit]
Description=Redis Exporter — exports Redis metrics to Prometheus
Documentation=https://github.com/oliver006/redis_exporter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=redis_exporter
Group=redis_exporter
EnvironmentFile=/etc/redis_exporter/redis_exporter.env
ExecStart=/usr/local/bin/redis_exporter \
    --web.listen-address={{LISTEN}}
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5s
TimeoutStopSec=20s

NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
ReadWritePaths=/var/log/monitoring

[Install]
WantedBy=multi-user.target
