[Unit]
Description=Prometheus (managed by the monitoring framework)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=prometheus
Group=prometheus
ExecStart=/usr/local/bin/prometheus \
    --config.file=/etc/prometheus/prometheus.yml \
    --storage.tsdb.path=/var/lib/prometheus \
    --storage.tsdb.retention.time={{RETENTION}} \
    --web.listen-address={{LISTEN}}
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

# Hardening — safe defaults for a Go daemon that only writes its data dir.
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/var/lib/prometheus
ProtectHome=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
