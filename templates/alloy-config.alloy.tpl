// alloy-config.alloy — Grafana Alloy configuration (River syntax).
//
// Rendered from templates/alloy-config.alloy.tpl by install-alloy.sh.
// The installer NEVER overwrites /etc/alloy/config.alloy once it exists;
// a differing render is saved as config.alloy.new for review.
//
// After editing, validate and reload with:
//   alloy fmt /etc/alloy/config.alloy   (reformats in place)
//   systemctl reload alloy
//
// Tokens rendered:
//   {{HOSTNAME}}   — output of hostname(1) on the server
//   {{LOKI_URL}}   — from loki_listen in environment(.local).yml

// ── Logging ──────────────────────────────────────────────────────────────────
logging {
  level  = "info"
  format = "logfmt"
}

// ── Collect: systemd journal → Loki ──────────────────────────────────────────
// Reads all systemd journal entries and ships them to Loki.
// Phase 2: this host only.  Remote hosts are onboarded in P7+.
loki.source.journal "system" {
  forward_to = [loki.write.local.receiver]

  // Attach identifying labels to every log stream.
  labels = {
    job  = "journal",
    host = "{{HOSTNAME}}",
  }

  // Map selected journal fields to Loki stream labels.
  // These become queryable selectors in Grafana's Loki explorer.
  relabeling_rules {
    rule {
      source_labels = ["__journal__systemd_unit"]
      target_label  = "unit"
    }
    rule {
      source_labels = ["__journal_priority_keyword"]
      target_label  = "level"
    }
    rule {
      source_labels = ["__journal__hostname"]
      target_label  = "hostname"
    }
  }
}

// ── Ship: push to local Loki ──────────────────────────────────────────────────
loki.write "local" {
  endpoint {
    url = "http://{{LOKI_URL}}/loki/api/v1/push"
  }

  // External labels added to every batch Alloy sends.
  // Useful once multiple Alloy instances push to one Loki.
  external_labels = {
    alloy_host = "{{HOSTNAME}}",
  }
}
