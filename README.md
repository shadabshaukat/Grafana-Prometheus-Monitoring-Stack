# PostgreSQL Observability Stack (Prometheus + Grafana)

This stack is intentionally **Prometheus-centric** for PostgreSQL metrics and Grafana visualization, with optional OCI datasource plugin installation for Grafana.

Included components:
- Grafana
- Prometheus
- postgres_exporter (multi-endpoint)
- NGINX TLS reverse proxy
- Prometheus recording rules for unified KPI/SLO calculations

All operational scripts are environment-driven via `.env` (single source of truth).

This repository supports local and server deployments with the same workflow:

- macOS (Docker Desktop)
- Oracle Linux / RHEL
- Ubuntu Linux

---

## Architecture

- `nginx` is exposed on `${NGINX_HTTPS_PORT}` (default `8443`) and `${NGINX_HTTP_PORT}` (`80` redirect).
- `grafana` is private behind NGINX.
- `prometheus` is bound to `${PROM_BIND_ADDRESS}:${PROM_PORT}` (default localhost only).
- one or more `postgres_exporter_*` services scrape PostgreSQL endpoints defined by DSN.
- Grafana can auto-install OCI datasource plugins using `.env` toggles.

---

## Repository layout

```text
.
├── .env
├── .env.example
├── README.md
├── PostgreSQL-HARDENED-RUNBOOK.md
├── generate_configs.sh
├── deploy_stack.sh
├── check_grafana_bindings.sh
├── start_stack.sh
├── stop_stack.sh
├── destroy_stack.sh
├── rotate_certs.sh
├── smoke_test.sh
└── lib/
    └── common.sh
```

---

## Quick start

```bash
cp .env.example .env
vi .env
sudo ./deploy_stack.sh
```

Set at minimum:

- `BASE_DIR`
- `GRAFANA_ADMIN_PASSWORD`
- `EXPORTER_COUNT`
- `EXPORTER_TARGETS`
- `EXPORTER_N_NAME` / `EXPORTER_N_DSN`

Optional (OCI plugin auto-install):

- `ENABLE_OCI_PLUGINS=true`
- `OCI_METRICS_PLUGIN_ID=oci-metrics-datasource`
- `OCI_LOGS_PLUGIN_ID=oci-logs-datasource`

Example (2 exporters):

```env
EXPORTER_COUNT=2
EXPORTER_1_NAME=postgres_exporter_primary
EXPORTER_1_DSN=postgresql://monitor_user:REPLACE_ME@10.10.1.82:5432/postgres?sslmode=require
EXPORTER_2_NAME=postgres_exporter_reporting
EXPORTER_2_DSN=postgresql://monitor_user:REPLACE_ME@10.10.1.83:5432/postgres?sslmode=require
EXPORTER_TARGETS=postgres_exporter_primary:9187,postgres_exporter_reporting:9187
```

Access Grafana:

```text
https://<host-ip>:8443
```

---

## Operations

```bash
sudo ./deploy_stack.sh
sudo ./start_stack.sh
sudo ./stop_stack.sh
sudo ./destroy_stack.sh
sudo ./destroy_stack.sh --purge-data
sudo ./rotate_certs.sh
sudo ./smoke_test.sh
sudo ./check_grafana_bindings.sh
```

Notes:

- `deploy_stack.sh` regenerates configs, ensures certs, starts containers, applies firewall rules, and runs health checks.
- `check_grafana_bindings.sh` verifies dashboard panels explicitly use the Prometheus datasource UID from `.env`.

By default, deploy also runs smoke test and Grafana datasource-binding validation:

```env
RUN_SMOKE_TEST_AFTER_DEPLOY=true
RUN_GRAFANA_BINDING_CHECK_AFTER_DEPLOY=true
```

---

## What gets generated

`generate_configs.sh` writes:

- Prometheus config with:
  - `prometheus` scrape job
  - `postgres_exporters` scrape job
- Prometheus recording rules (`recording-rules.yml`) for reusable dashboard KPIs
- Grafana Prometheus datasource provisioning
- Unified PostgreSQL dashboard (`postgresql-unified-insights.json`)
- NGINX TLS reverse proxy config
- `docker-compose.yaml` with nginx, grafana, prometheus, and N exporters

Optional additional scrape jobs can be appended by setting:

```env
PROM_ADDITIONAL_SCRAPE_CONFIG=/opt/observability-stack/prometheus/extra-scrape-config.yml
```

---

## Multi-exporter scaling

Increase exporter count and add DSNs:

```env
EXPORTER_COUNT=3
EXPORTER_3_NAME=postgres_exporter_analytics
EXPORTER_3_DSN=postgresql://monitor_user:REPLACE_ME@10.10.1.84:5432/postgres?sslmode=require
EXPORTER_TARGETS=postgres_exporter_primary:9187,postgres_exporter_reporting:9187,postgres_exporter_analytics:9187
```

Then redeploy:

```bash
sudo ./deploy_stack.sh
```

---

## Dashboard scope

Generated dashboard: `postgresql-unified-insights.json`

Includes structured, production-oriented sections:

- **SLO & alerting signals** (availability, connection saturation, deadlocks, replication lag, SQL latency)
- **Core workload** (TPS/session states)
- **WAL/checkpoint/storage pressure**
- **Autovacuum & table health**
- **Locks/replication/exporter health**
- **Cardinality-safe SQL performance** (`queryid + short_query`)

Key metrics include:

- availability (`pg_up`)
- active connections / saturation
- TPS (commit + rollback) via recording rules
- cache hit ratio
- deadlocks rate
- replication replay lag
- checkpoint rate and write/sync pressure
- dead tuples and autovacuum rates
- database size
- top SQL by total execution time and call volume (via `pg_stat_statements` custom query, cardinality-safe grouping)

Dashboard variables:

- `instance` (exporter instance)
- `datname` (database)

---

## TLS and certificate rotation

- Initial self-signed cert is generated automatically during deploy (if missing).
- Rotate at any time:

```bash
sudo ./rotate_certs.sh
# or custom validity days
sudo ./rotate_certs.sh 180
```

`rotate_certs.sh` keeps timestamped backups of previous cert/key and restarts NGINX.

---

## Platform support

- macOS (Docker Desktop)
- Oracle Linux / RHEL (`firewalld` automation when enabled)
- Ubuntu (`ufw` automation when enabled)

Disable firewall automation if required:

```env
ENABLE_FIREWALL=false
```

Firewall behavior is auto-detected in scripts:

- `firewalld` (Oracle Linux / RHEL)
- `ufw` (Ubuntu)
- skipped when unavailable or disabled

---

## Security notes

- Replace demo credentials and DSN passwords before production.
- Prefer external secret stores over plaintext `.env` in production.
- Keep Prometheus localhost-bound unless remote access is required.
- Pin image versions instead of floating `latest` in hardened environments.

---

## Troubleshooting

Regenerate stack configs:

```bash
sudo ./generate_configs.sh --force
cat "$(grep '^BASE_DIR=' .env | cut -d'=' -f2)/docker-compose.yaml"
```

Check container/service health:

```bash
sudo ./smoke_test.sh
```

Inspect Prometheus targets:

```bash
curl -s http://127.0.0.1:9090/api/v1/targets | jq '.data.activeTargets[] | {scrapeUrl,health,lastError}'
```

---

## Notes

- Default Grafana datasource is Prometheus (`GRAFANA_DS_UID=prometheus`).
- OCI datasource plugins can be auto-installed in Grafana via `.env` (`ENABLE_OCI_PLUGINS`, `OCI_METRICS_PLUGIN_ID`, `OCI_LOGS_PLUGIN_ID`).
- `postgres_exporter` collects metrics, not PostgreSQL logs.
- Keep Prometheus host bind on localhost unless you explicitly want remote access.
