# snmp-exporter.service — rendered by install-snmp-exporter.sh.
# Tokens: {{LISTEN}}

[Unit]
Description=SNMP Exporter — exports SNMP data from network devices to Prometheus
Documentation=https://github.com/prometheus/snmp_exporter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=snmp_exporter
Group=snmp_exporter
ExecStart=/usr/local/bin/snmp_exporter \
    --config.file=/etc/snmp_exporter/snmp.yml \
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
