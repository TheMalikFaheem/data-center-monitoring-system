[Unit]
Description=Prometheus Node Exporter (managed by the monitoring framework)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=node_exporter
Group=node_exporter
ExecStart=/usr/local/bin/node_exporter \
    --web.listen-address={{LISTEN}} \
    --collector.textfile.directory=/var/lib/node_exporter/textfile
Restart=on-failure
RestartSec=5

# Hardening — conservative on purpose. node_exporter must read broadly under
# /proc and /sys, and ProtectHome=read-only (not true) so a real /home mount
# still shows up in filesystem metrics. Over-hardening exporters is the
# classic source of silently missing metrics.
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
