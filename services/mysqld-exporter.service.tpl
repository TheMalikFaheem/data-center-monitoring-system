# mysqld-exporter.service — rendered by install-mysqld-exporter.sh.
# Tokens: {{LISTEN}}
# DSN is passed via the credentials file /etc/mysqld_exporter/.my.cnf

[Unit]
Description=MySQL Exporter — exports MySQL server metrics to Prometheus
Documentation=https://github.com/prometheus/mysqld_exporter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=mysqld_exporter
Group=mysqld_exporter
ExecStart=/usr/local/bin/mysqld_exporter \
    --config.my-cnf=/etc/mysqld_exporter/.my.cnf \
    --web.listen-address={{LISTEN}} \
    --collect.info_schema.tables \
    --collect.info_schema.innodb_metrics \
    --collect.global_status \
    --collect.global_variables \
    --collect.slave_status \
    --collect.auto_increment.columns \
    --collect.binlog_size
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
