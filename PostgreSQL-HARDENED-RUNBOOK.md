# PostgreSQL Observability — Hardened Runbook

This runbook describes a production-style deployment for:
- Grafana
- Prometheus
- postgres_exporter (multi-DB)
- NGINX reverse proxy with self-signed TLS
- Prometheus recording rules for unified KPI/SLO metrics

> This stack is Prometheus-only for metrics ingestion and dashboarding.

---

## 0) Prerequisites

1. Docker Engine + Docker Compose plugin installed.
2. Host can reach all PostgreSQL endpoints used in `EXPORTER_N_DSN` values.
3. TLS certificate subject values set in `.env` (or accept defaults).
4. Required tools available for validation: `curl`, `jq`, `openssl`.

---

## 1) Core hardening recommendations

1. Expose only NGINX externally (`8443`, optional `80` redirect).
2. Keep Grafana internal-only (no direct host port bind).
3. Keep Prometheus localhost-only (`127.0.0.1:9090`).
4. Disable Grafana signup and enforce secure cookies.
5. Move DSNs/passwords out of `.env` to a secret store for production.
6. Pin image versions (avoid floating `latest`) in production.

---

## 2) Baseline deployment flow

```bash
cp .env.example .env
vi .env
sudo ./deploy_stack.sh
```

Expected deploy behavior:

- regenerates stack configs from `.env`
- generates TLS cert if missing
- starts/updates containers
- applies firewall rules (when enabled)
- runs smoke tests and datasource-binding checks (when enabled)

OCI datasource plugin behavior (optional):

- When `ENABLE_OCI_PLUGINS=true`, Grafana installs plugin IDs from:
  - `OCI_METRICS_PLUGIN_ID`
  - `OCI_LOGS_PLUGIN_ID`
- Plugin IDs are merged with `GRAFANA_INSTALL_PLUGINS` and deduplicated.

---

## 3) Operations

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

---

## 4) Multi-exporter scaling

Add more PostgreSQL targets by increasing exporter count and DSNs in `.env`:

```env
EXPORTER_COUNT=3
EXPORTER_3_NAME=postgres_exporter_analytics
EXPORTER_3_DSN=postgresql://monitor_user:REPLACE_ME@10.10.1.84:5432/postgres?sslmode=require
EXPORTER_TARGETS=postgres_exporter_primary:9187,postgres_exporter_reporting:9187,postgres_exporter_analytics:9187
```

Apply changes:

```bash
sudo ./deploy_stack.sh
```

---

## 5) Validation

```bash
sudo ./smoke_test.sh
curl -s http://127.0.0.1:9090/api/v1/targets | jq '.data.activeTargets[] | {scrapeUrl,health,lastError}'
```

Dashboard/API binding check:

```bash
sudo ./check_grafana_bindings.sh
```

Recording rules validation (optional):

```bash
curl -s http://127.0.0.1:9090/api/v1/rules | jq '.data.groups[] | {name, file}'
```

---

## 6) Change management and rollback

1. Keep `.env` changes in version control (without secrets) for auditable diffs.
2. Apply config changes with `sudo ./deploy_stack.sh`.
3. If rollout fails, restore previous `.env` and redeploy.
4. Use `sudo ./destroy_stack.sh` only for container teardown; use `--purge-data` only when intentional.

---

## 7) Data and cert lifecycle

- Grafana data persists in `${BASE_DIR}/data/grafana`.
- Prometheus TSDB persists in `${BASE_DIR}/data/prometheus`.
- Prometheus recording rules are generated at `${BASE_DIR}/prometheus/recording-rules.yml`.
- Rotate certs periodically with `sudo ./rotate_certs.sh`.
- `rotate_certs.sh` writes timestamped cert/key backups before replacement.

---

## 8) Unified dashboard behavior

The generated unified dashboard includes:

1. SLO-focused KPIs with thresholds (availability, deadlocks, replication lag, connection utilization, SQL latency).
2. WAL/checkpoint pressure views.
3. Autovacuum and dead tuple health.
4. Cardinality-safe top SQL visualizations (`queryid + short_query`).

This improves triage speed and reduces expensive ad-hoc query load in Grafana panels.
