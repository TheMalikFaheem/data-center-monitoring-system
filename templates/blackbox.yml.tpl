# blackbox.yml — Blackbox Exporter module configuration.
#
# Rendered from templates/blackbox.yml.tpl by install-blackbox-exporter.sh.
# The installer NEVER overwrites this file once it exists.
#
# Each module defines HOW to probe a target. The WHAT (target URLs) lives in
# the Prometheus scrape config (prometheus.yml). See docs/runbook.md §12.
#
# After editing: amtool check-config is not available for blackbox; simply
# reload the service: systemctl reload blackbox_exporter

modules:
  # ── HTTP modules ──────────────────────────────────────────────────────────

  # Standard HTTP/HTTPS check: expects a 2xx response.
  # Use for public websites, APIs, and HTTPS certificate validity.
  http_2xx:
    prober: http
    timeout: 10s
    http:
      valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
      valid_status_codes: []   # empty = [200..299]
      method: GET
      follow_redirects: true
      preferred_ip_protocol: ip4
      tls_config:
        insecure_skip_verify: false  # set true ONLY for self-signed certs

  # POST probe — for endpoints that require POST (webhooks, health APIs).
  http_post_2xx:
    prober: http
    timeout: 10s
    http:
      method: POST
      headers:
        Content-Type: application/json
      valid_status_codes: []

  # ── TCP modules ───────────────────────────────────────────────────────────

  # TCP connectivity check — use for database ports, SSH, custom services.
  # Does NOT check TLS or application-layer responses; just confirms TCP connects.
  tcp_connect:
    prober: tcp
    timeout: 5s
    tcp:
      preferred_ip_protocol: ip4

  # TCP + TLS handshake verification — use for SMTP/IMAP/etc with STARTTLS.
  tcp_tls:
    prober: tcp
    timeout: 10s
    tcp:
      preferred_ip_protocol: ip4
      tls: true
      tls_config:
        insecure_skip_verify: false

  # ── ICMP modules ──────────────────────────────────────────────────────────

  # ICMP ping — use for network reachability of hosts that don't serve HTTP.
  # Requires CAP_NET_RAW or root. The unit runs as a dedicated user; ensure
  # the binary has the net_raw capability (install-blackbox-exporter.sh handles this).
  icmp:
    prober: icmp
    timeout: 5s
    icmp:
      preferred_ip_protocol: ip4

  # ── DNS modules ───────────────────────────────────────────────────────────

  # DNS resolution check — use to verify DNS servers return expected records.
  dns_soa:
    prober: dns
    timeout: 5s
    dns:
      preferred_ip_protocol: ip4
      query_name: "."
      query_type: "SOA"
