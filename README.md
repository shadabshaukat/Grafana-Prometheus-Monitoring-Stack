# OCI PostgreSQL Observability Stack

[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Oracle%20Linux%20%7C%20RHEL%20%7C%20Ubuntu-blue)](#platform-support)
[![Runtime](https://img.shields.io/badge/runtime-Docker%20Compose-2496ED)](#architecture)
[![TLS](https://img.shields.io/badge/TLS-self--signed-orange)](#tls-and-certificate-rotation)

Production-style, environment-parameterized observability stack for OCI managed PostgreSQL using:

- **Grafana** (dashboards + visualization)
- **Prometheus** (metrics collection)
- **postgres_exporter** (PostgreSQL metrics)
- **NGINX** (TLS reverse proxy)

This repository is refactored so all operational scripts read from `.env` (single source of truth) and support deployment on:

- macOS (local development)
- Oracle Linux / RHEL
- Ubuntu Linux

---

## Architecture

- `nginx` exposed on `${NGINX_HTTPS_PORT}` (default `8443`) and `${NGINX_HTTP_PORT}` redirect.
- `grafana` private behind NGINX.
- `prometheus` bound to `${PROM_BIND_ADDRESS}:${PROM_PORT}` (default localhost only).
- one or more `postgres_exporter_*` services, each pointing to different DB DSN.

---

## Repository layout

```text
.
├── .env
├── .env.example
├── README.md
├── generate_configs.sh
├── deploy_stack.sh
├── destroy_stack.sh
├── rotate_certs.sh
├── smoke_test.sh
└── lib/
    └── common.sh
```

---

## Quick start

### 1) Copy and edit environment file

```bash
cp .env.example .env
vi .env
```

Set at minimum:

- `BASE_DIR`
- `GRAFANA_ADMIN_PASSWORD`
- `EXPORTER_COUNT`
- `EXPORTER_TARGETS`
- `EXPORTER_N_NAME` / `EXPORTER_N_DSN`

### 2) One-command deploy

```bash
sudo ./deploy_stack.sh
```

### 3) Access Grafana

```text
https://<host-ip>:${NGINX_HTTPS_PORT}
```

Default from `.env`: `https://<host-ip>:8443`

---

## One-command operations

### Deploy

```bash
sudo ./deploy_stack.sh
```

### Destroy (keep data)

```bash
sudo ./destroy_stack.sh
```

### Destroy (purge data)

```bash
sudo ./destroy_stack.sh --purge-data
```

### Rotate self-signed certificate

```bash
sudo ./rotate_certs.sh          # uses CERT_DAYS from .env
sudo ./rotate_certs.sh 180      # custom days
```

### Post-rebuild smoke tests

```bash
sudo ./smoke_test.sh
```

---

## Multi-database postgres_exporter scaling

This stack supports multiple PostgreSQL endpoints via environment variables.

### Add one more exporter

1. Increase exporter count:

```env
EXPORTER_COUNT=3
```

2. Add new exporter name + DSN:

```env
EXPORTER_3_NAME=postgres_exporter_analytics
EXPORTER_3_DSN=postgresql://monitor_user:REPLACE_ME@10.10.1.84:5432/postgres?sslmode=require
```

3. Add scrape target:

```env
EXPORTER_TARGETS=postgres_exporter_primary:9187,postgres_exporter_reporting:9187,postgres_exporter_analytics:9187
```

4. Redeploy:

```bash
sudo ./deploy_stack.sh
```

---

## Dashboard strategy (OCI managed PostgreSQL)

Build a **single unified dashboard** with two sections:

1. **DB OCI Stats**
   - connections, TPS, cache hit %, deadlocks, replication lag, checkpoint pressure
   - optional OCI plugin metrics (CPU, memory, storage throughput/IOPS)

2. **SQL Query Monitoring** (RDS Performance Insights style)
   - Top SQL by total/mean exec time
   - Top SQL by call volume
   - rollback ratio
   - temp bytes/txn
   - dead tuple ratio by table
   - autovacuum cadence

### OCI Metrics datasource auto-provisioning

This repo now provisions **Oracle Cloud Infrastructure Metrics** datasource (`oci-metrics-datasource`) when `OCI_DS_ENABLED=true`.

Set these values in `.env`:

```env
OCI_DS_ENABLED=true
OCI_DS_NAME="Oracle Cloud Infrastructure Metrics"
OCI_DS_UID=oci-metrics
OCI_CONFIG_PROFILE=DEFAULT
# Host paths (must exist on the VM host)
OCI_CONFIG_FILE=/home/opc/.oci/config
OCI_PRIVATE_KEY_FILE=/home/opc/.oci/priv.key
# Container paths used by Grafana datasource
OCI_CONTAINER_CONFIG_PATH=/etc/grafana/oci/config
OCI_CONTAINER_PRIVATE_KEY_PATH=/etc/grafana/oci/priv.key
OCI_TENANCY_OCID=ocid1.tenancy.oc1..<REPLACE_ME>
OCI_USER_OCID=ocid1.user.oc1..<REPLACE_ME>
OCI_REGION=ap-tokyo-1
OCI_FINGERPRINT=aa:bb:cc:...
OCI_PRIVATE_KEY_PEM_SNIPPET="-----BEGIN PRIVATE KEY-----\nPASTE_PRIVATE_KEY_CONTENT_HERE\n-----END PRIVATE KEY-----"
OCI_PG_COMPARTMENT_OCID=ocid1.compartment.oc1..<REPLACE_ME>
OCI_PG_RESOURCE_GROUP=postgresql
```

Notes:

- If `OCI_PRIVATE_KEY_PEM_SNIPPET` is left as placeholder and `OCI_PRIVATE_KEY_FILE` exists, generator reads key content from file automatically.
- Generator also mounts `OCI_CONFIG_FILE` and `OCI_PRIVATE_KEY_FILE` into Grafana container at `OCI_CONTAINER_CONFIG_PATH` / `OCI_CONTAINER_PRIVATE_KEY_PATH`.
- Keep `\\n` escaped if setting the full key inline in `.env`.

### New OCI PostgreSQL dashboard

The generator creates:

- `${BASE_DIR}/grafana/dashboards/oci-postgresql-metrics.json`
- `${BASE_DIR}/grafana/dashboards/postgresql-unified-insights.json`

`postgresql-unified-insights.json` is now **bootstrapped directly by the stack** (generated from `generate_configs.sh`) and does **not** require importing/migrating an external JSON at runtime.

It includes:

- PostgreSQL Prometheus panels (availability, connections, TPS, cache hit, deadlocks, DB size, top SQL)
- OCI Monitoring panels (CPU, memory, connections, read/write IOPS)

Datasource mapping is automatic:

- Prometheus panels use `GRAFANA_DS_UID`
- OCI panels use `OCI_DS_UID`

Panels include (OCI Monitoring datasource):

- CPU Utilization
- Memory Utilization
- Storage Utilization
- Database Connections
- Read IOPS
- Write IOPS

---

## TLS and certificate rotation

- Initial cert is generated automatically by `deploy_stack.sh` if missing.
- Rotate at any time with `rotate_certs.sh`.
- Script creates timestamped backups and restarts NGINX.

---

## Platform support

### macOS
- Docker Desktop recommended.
- Firewall steps are skipped automatically unless configured otherwise.

### Oracle Linux / RHEL
- `firewalld` automation supported (`firewall-cmd`).

### Ubuntu
- `ufw` automation supported when available.

Use `.env` to disable firewall automation:

```env
ENABLE_FIREWALL=false
```

---

## Security notes

- Replace demo passwords/DSNs before production use.
- Prefer secret stores (Vault/OCI Vault/K8s secrets) over plain `.env`.
- Restrict exposed ports and source CIDRs.
- Pin image versions and patch regularly.

---

## Troubleshooting

### Verify generated compose and config

```bash
sudo ./generate_configs.sh --force
cat "$(grep '^BASE_DIR=' .env | cut -d'=' -f2)/docker-compose.yaml"
```

### Check services

```bash
sudo ./smoke_test.sh
```

### Check Prometheus targets

```bash
curl -s http://127.0.0.1:9090/api/v1/targets | jq '.data.activeTargets[] | {scrapeUrl,health,lastError}'
```

---

## License / Usage

Internal project template for rapid PostgreSQL observability deployment.
