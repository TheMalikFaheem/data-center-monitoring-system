# postgres-exporter.service — rendered by install-postgres-exporter.sh.
# Tokens: {{LISTEN}}
# DSN is passed via DATA_SOURCE_NAME environment variable from a secured file.

[Unit]
Description=PostgreSQL Exporter — exports PostgreSQL metrics to Prometheus
Documentation=https://github.com/prometheus-community/postgres_exporter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=postgres_exporter
Group=postgres_exporter
# Load the DSN from a secured env file — never put secrets on the command line.
EnvironmentFile=/etc/postgres_exporter/postgres_exporter.env
ExecStart=/usr/local/bin/postgres_exporter \
    --web.listen-address={{LISTEN}} \
    --collector.stat_bgwriter \
    --collector.stat_database \
    --collector.locks \
    --collector.replication \
    --collector.statio_user_tables \
    --collector.stat_user_tables
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
