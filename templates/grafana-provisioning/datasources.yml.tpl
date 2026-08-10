# datasources.yml — Grafana datasource provisioning.
#
# Rendered from templates/grafana-provisioning/datasources.yml.tpl by
# install-grafana.sh and installed to:
#   /etc/grafana/provisioning/datasources/monitoring.yml
#
# Tokens rendered:
#   {{PROMETHEUS_URL}}  — from prometheus_listen in environment(.local).yml
#   {{LOKI_URL}}        — from loki_listen in environment(.local).yml
#   {{SCRAPE_INTERVAL}} — from scrape_interval in environment(.local).yml
#
# To add a new datasource: edit this template, re-run the installer.
# To modify a provisioned datasource: edit the rendered file at the path
# above and systemctl restart grafana-server (or wait for Grafana to reload).

apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://{{PROMETHEUS_URL}}
    isDefault: true
    jsonData:
      timeInterval: "{{SCRAPE_INTERVAL}}"
      # Enables Prometheus exemplar support (requires Prometheus >= 2.x)
      exemplarTraceIdDestinations: []
    version: 1
    editable: false     # prevent UI edits from diverging from provisioning

  - name: Loki
    type: loki
    access: proxy
    url: http://{{LOKI_URL}}
    jsonData:
      # Link Loki log lines to Prometheus traces (if Tempo is added in a future phase)
      derivedFields: []
    version: 1
    editable: false
