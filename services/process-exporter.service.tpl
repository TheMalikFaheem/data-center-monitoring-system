# process-exporter.service — rendered by install-process-exporter.sh.
# Tokens: {{LISTEN}}

[Unit]
Description=Process Exporter — exposes named process metrics to Prometheus
Documentation=https://github.com/ncabatoff/process-exporter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/local/bin/process_exporter \
    --config.path=/etc/process_exporter/process-exporter.yml \
    --web.listen-address={{LISTEN}}
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5s
TimeoutStopSec=20s

# process-exporter reads /proc — it must run as root or with CAP_SYS_PTRACE.
# NoNewPrivileges blocks privilege escalation without restricting /proc reads.
NoNewPrivileges=yes
PrivateTmp=yes
ReadWritePaths=/var/log/monitoring

[Install]
WantedBy=multi-user.target
