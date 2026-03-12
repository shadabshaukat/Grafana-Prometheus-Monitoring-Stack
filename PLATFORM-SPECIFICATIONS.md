# Platform Specifications & Change History

## Purpose

This file is the canonical specification and running history for the platform in this repository.
If context is lost, review this file first to understand:

- current architecture
- expected behavior
- implemented enhancements
- operational constraints
- pending work

---

## Current Platform Definition

The platform is a PostgreSQL observability stack with:

- NGINX TLS reverse proxy
- Grafana
- Prometheus
- postgres_exporter fleet (multi-endpoint via DSN)

Primary telemetry path is **Prometheus metrics**.

> Note: postgres_exporter does **not** ingest PostgreSQL logs; it exports metrics only.

---

## Configuration Contract

The platform is fully environment-driven via `.env`.

### Key variable groups

1. **Core stack**: image names, container names, ports, base paths
2. **Exporter fleet**: `EXPORTER_COUNT`, `EXPORTER_TARGETS`, `EXPORTER_N_NAME`, `EXPORTER_N_DSN`
3. **Grafana**: admin credentials, datasource UID/name, plugin settings
4. **Security/TLS**: cert subject fields and validity days
5. **Ops controls**: firewall/chown toggles, deploy health check timings

### OCI plugin settings (new)

- `ENABLE_OCI_PLUGINS=true|false`
- `OCI_METRICS_PLUGIN_ID=oci-metrics-datasource`
- `OCI_LOGS_PLUGIN_ID=oci-logs-datasource`

Behavior:

- When enabled, OCI plugin IDs are merged into Grafana `GF_INSTALL_PLUGINS`.
- Merge is deduplicated and compatible with pre-existing `GRAFANA_INSTALL_PLUGINS` values.

---

## Implemented Enhancements (This Change Set)

### 1) Unified dashboard improvements

Implemented in generated `postgresql-unified-insights.json`:

- SLO/alerting row with thresholds for:
  - availability
  - connection utilization
  - deadlocks
  - replication lag
  - SQL average latency
- Time-series SLO signal panel for fast trend analysis
- WAL/checkpoint/storage pressure section
- Autovacuum/table health section
- Locks/replication/exporter health section
- Cardinality-safe SQL panels using `queryid + short_query`
- Improved dashboard readability and sectioning for operations

### 2) Prometheus recording rules

Generated file: `${BASE_DIR}/prometheus/recording-rules.yml`

Includes reusable KPIs for dashboard performance and consistency:

- `pg:availability:max`
- `pg:connections_utilization_percent`
- `pg:deadlocks_rate5m`
- `pg:replication_replay_lag_seconds:max`
- `pg:transactions_rate5m`
- `pg:cache_hit_percent`
- `pg:checkpoints_rate5m`
- `pg:autovacuum_dead_tuples`

`prometheus.yml` now loads this rules file via `rule_files`.

### 3) OCI plugins via env

Added `.env`/`.env.example` flags and defaults for OCI metrics/logs plugins.

### 4) Documentation sync

Updated:

- `README.md`
- `PostgreSQL-HARDENED-RUNBOOK.md`

to align docs with implementation changes above.

---

## Operational Validation Checklist

After deploy/regeneration:

1. `docker compose -f ${BASE_DIR}/docker-compose.yaml ps`
2. `curl -s http://127.0.0.1:${PROM_PORT}/-/ready`
3. `curl -s http://127.0.0.1:${PROM_PORT}/api/v1/rules | jq '.status'`
4. Verify Grafana dashboard UID: `postgresql-unified-insights`
5. Run: `./check_grafana_bindings.sh`

---

## Known Limitations

1. Platform is metrics-centric; logs are not ingested by postgres_exporter.
2. OCI plugin installation requires valid plugin IDs and internet/plugin access from Grafana container runtime.
3. `latest` image tags are still present by default; pin versions for production hardening.

---

## Change History

### 2026-03-13 — Unified dashboard + recording rules + OCI plugin env support

- Added OCI plugin env controls and defaults.
- Updated config generation to merge/install OCI plugins in Grafana.
- Added Prometheus recording rules generation and mount wiring.
- Reworked generated unified dashboard for SLO-first operations and cardinality-safe SQL views.
- Updated README and hardened runbook for behavior parity.
- Added this specifications/history document and context recovery prompt document.
