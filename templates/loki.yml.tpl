# loki.yml — Loki configuration.
#
# Rendered from templates/loki.yml.tpl by install-loki.sh.
# The installer NEVER overwrites this file once it exists: if a newer render
# differs, it is saved as loki.yml.new for review.
#
# Tokens rendered:
#   {{HTTP_PORT}}    — from alertmanager_listen (port portion)
#   {{RETENTION}}    — from loki_retention in environment(.local).yml

auth_enabled: false

server:
  # Loki HTTP interface — Alloy pushes logs here; Grafana queries here.
  # Must match HEALTH_URL[loki] in scripts/common.sh.
  http_listen_address: 127.0.0.1
  http_listen_port: {{HTTP_PORT}}
  # gRPC is internal only; bind loopback so nothing leaks.
  grpc_listen_address: 127.0.0.1
  grpc_listen_port: 9096
  log_level: info

common:
  instance_addr: 127.0.0.1
  path_prefix: /var/lib/loki
  storage:
    filesystem:
      chunks_directory: /var/lib/loki/chunks
      rules_directory:  /var/lib/loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

# Schema v13 + TSDB index: current recommended config for single-node Loki 3.x
schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

# Retention is enforced by the compactor.
limits_config:
  retention_period: {{RETENTION}}
  # Generous ingestion limits for a single-server setup.
  ingestion_rate_mb: 16
  ingestion_burst_size_mb: 32
  per_stream_rate_limit: 4MB
  per_stream_rate_limit_burst: 8MB

compactor:
  working_directory: /var/lib/loki/compactor
  retention_enabled: true
  retention_delete_delay: 2h
  delete_request_store: filesystem

# Disable anonymous usage reporting to Grafana Labs.
analytics:
  reporting_enabled: false
