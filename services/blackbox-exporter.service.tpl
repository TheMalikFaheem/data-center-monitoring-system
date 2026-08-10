# blackbox-exporter.service — rendered by install-blackbox-exporter.sh.
# Tokens: {{LISTEN}}

[Unit]
Description=Blackbox Exporter — probes HTTP, TCP, ICMP, DNS endpoints
Documentation=https://github.com/prometheus/blackbox_exporter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=blackbox_exporter
Group=blackbox_exporter
ExecStart=/usr/local/bin/blackbox_exporter \
    --config.file=/etc/blackbox_exporter/blackbox.yml \
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
