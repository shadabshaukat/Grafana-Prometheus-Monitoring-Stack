# OCI PostgreSQL Observability — Hardened Runbook

This runbook provides a production-style setup for:
- Grafana
- Prometheus
- postgres_exporter (multi-DB)
- NGINX reverse proxy with self-signed TLS
- Firewall guidance
- Unified dashboard strategy for OCI PostgreSQL (DB OCI Stats + SQL Query Monitoring)

> **Important (current build):** This repository is now **env-driven**.  
> The operational source of truth is: `.env`, `lib/common.sh`, and these scripts:  
> `generate_configs.sh`, `deploy_stack.sh`, `destroy_stack.sh`, `rotate_certs.sh`, `smoke_test.sh`.

---

## 1) Hardening recommendations

1. Expose only NGINX externally (`8443`, optional `80` redirect).
2. Keep Grafana internal-only (no direct host port bind).
3. Keep Prometheus localhost-only (`127.0.0.1:9090`).
4. Disable Grafana signup and enforce secure cookies.
5. Store credentials in secrets/env files (avoid plaintext DSN in compose).
6. Enable `pg_stat_statements` and custom exporter queries.
7. Add alerting (deadlocks, lag, rollback ratio, high connections, vacuum debt).
8. Pin image versions in production (avoid floating `latest`).

---

## 2) End-to-end commands

### 2.1 Create directories

```bash
sudo mkdir -p /opt/observability-stack/{nginx/certs,nginx/conf.d,prometheus,postgres-exporter,grafana/provisioning/datasources,grafana/provisioning/dashboards,grafana/dashboards,data/grafana,data/prometheus}
sudo chown -R 472:472 /opt/observability-stack/data/grafana
sudo chown -R 65534:65534 /opt/observability-stack/data/prometheus
```

### 2.2 Generate self-signed certificate

```bash
sudo openssl req -x509 -nodes -days 365 -newkey rsa:4096 \
  -keyout /opt/observability-stack/nginx/certs/grafana.key \
  -out /opt/observability-stack/nginx/certs/grafana.crt \
  -subj "/C=AU/ST=NSW/L=Sydney/O=Observability/OU=Platform/CN=grafana.local"

sudo chmod 600 /opt/observability-stack/nginx/certs/grafana.key
```

### 2.3 NGINX config

```bash
sudo tee /opt/observability-stack/nginx/conf.d/default.conf > /dev/null <<'EOF'
server {
  listen 80;
  server_name _;
  return 301 https://$host$request_uri;
}

server {
  listen 8443 ssl http2;
  server_name _;

  ssl_certificate     /etc/nginx/certs/grafana.crt;
  ssl_certificate_key /etc/nginx/certs/grafana.key;
  ssl_protocols TLSv1.2 TLSv1.3;

  add_header X-Frame-Options SAMEORIGIN always;
  add_header X-Content-Type-Options nosniff always;
  add_header Referrer-Policy strict-origin-when-cross-origin always;

  location / {
    proxy_pass http://grafana:3000;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
  }
}
EOF
```

### 2.4 Prometheus config (multi-exporter)

```bash
sudo tee /opt/observability-stack/prometheus/prometheus.yml > /dev/null <<'EOF'
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']

  - job_name: postgres_exporters
    static_configs:
      - targets:
          - postgres_exporter_primary:9187
          - postgres_exporter_reporting:9187
EOF
```

### 2.5 postgres_exporter custom queries (pg_stat_statements)

```bash
sudo tee /opt/observability-stack/postgres-exporter/queries.yaml > /dev/null <<'EOF'
pg_stat_statements_top:
  query: |
    SELECT
      s.queryid::text AS queryid,
      d.datname::text AS datname,
      regexp_replace(left(s.query, 120), E'[\n\r\t]+', ' ', 'g')::text AS short_query,
      s.calls::double precision AS calls,
      s.total_exec_time::double precision AS total_exec_time_ms,
      s.mean_exec_time::double precision AS mean_exec_time_ms,
      s.rows::double precision AS rows_processed
    FROM pg_stat_statements s
    JOIN pg_database d ON d.oid = s.dbid
    ORDER BY s.total_exec_time DESC
    LIMIT 25;
  metrics:
    - queryid: {usage: "LABEL", description: "Query ID"}
    - datname: {usage: "LABEL", description: "Database"}
    - short_query: {usage: "LABEL", description: "Truncated SQL"}
    - calls: {usage: "GAUGE", description: "Calls"}
    - total_exec_time_ms: {usage: "GAUGE", description: "Total exec ms"}
    - mean_exec_time_ms: {usage: "GAUGE", description: "Mean exec ms"}
    - rows_processed: {usage: "GAUGE", description: "Rows"}
EOF
```

### 2.6 Grafana datasource provisioning

```bash
sudo tee /opt/observability-stack/grafana/provisioning/datasources/datasources.yml > /dev/null <<'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: true
EOF
```

### 2.7 Grafana dashboard provider

```bash
sudo tee /opt/observability-stack/grafana/provisioning/dashboards/dashboards.yml > /dev/null <<'EOF'
apiVersion: 1
providers:
  - name: OCI-PostgreSQL
    orgId: 1
    folder: PostgreSQL
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards
EOF
```

### 2.8 Hardened docker-compose.yaml

```bash
sudo tee /opt/observability-stack/docker-compose.yaml > /dev/null <<'EOF'
services:
  nginx:
    image: nginx:stable-alpine
    container_name: nginx-grafana
    restart: unless-stopped
    ports:
      - "0.0.0.0:8443:8443"
      - "0.0.0.0:80:80"
    volumes:
      - /opt/observability-stack/nginx/conf.d/default.conf:/etc/nginx/conf.d/default.conf:ro
      - /opt/observability-stack/nginx/certs:/etc/nginx/certs:ro
    depends_on:
      - grafana
    networks: [monitoring]

  grafana:
    image: grafana/grafana-oss:latest
    container_name: grafana
    restart: unless-stopped
    environment:
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD: ChangeThisNow!StrongPass123
      GF_USERS_ALLOW_SIGN_UP: "false"
      GF_SECURITY_COOKIE_SECURE: "true"
      GF_SECURITY_COOKIE_SAMESITE: strict
      GF_INSTALL_PLUGINS: oci-metrics-datasource,oci-logs-datasource
    volumes:
      - /opt/observability-stack/data/grafana:/var/lib/grafana
      - /opt/observability-stack/grafana/provisioning:/etc/grafana/provisioning:ro
      - /opt/observability-stack/grafana/dashboards:/var/lib/grafana/dashboards:ro
    networks: [monitoring]

  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    restart: unless-stopped
    ports:
      - "127.0.0.1:9090:9090"
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --web.enable-lifecycle
    volumes:
      - /opt/observability-stack/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - /opt/observability-stack/data/prometheus:/prometheus
    networks: [monitoring]

  postgres_exporter_primary:
    image: prometheuscommunity/postgres-exporter:latest
    container_name: postgres_exporter_primary
    restart: unless-stopped
    environment:
      DATA_SOURCE_NAME: postgresql://monitor_user:REPLACE_ME@10.10.1.82:5432/postgres?sslmode=require
    command:
      - --extend.query-path=/etc/postgres_exporter/queries.yaml
    volumes:
      - /opt/observability-stack/postgres-exporter/queries.yaml:/etc/postgres_exporter/queries.yaml:ro
    networks: [monitoring]

  postgres_exporter_reporting:
    image: prometheuscommunity/postgres-exporter:latest
    container_name: postgres_exporter_reporting
    restart: unless-stopped
    environment:
      DATA_SOURCE_NAME: postgresql://monitor_user:REPLACE_ME@10.10.1.83:5432/postgres?sslmode=require
    command:
      - --extend.query-path=/etc/postgres_exporter/queries.yaml
    volumes:
      - /opt/observability-stack/postgres-exporter/queries.yaml:/etc/postgres_exporter/queries.yaml:ro
    networks: [monitoring]

networks:
  monitoring:
    name: monitoring
    driver: bridge
EOF
```

### 2.9 Deploy + firewall

```bash
cd /opt/observability-stack
sudo docker compose pull
sudo docker compose up -d

sudo firewall-cmd --permanent --add-port=8443/tcp
sudo firewall-cmd --permanent --add-port=80/tcp
sudo firewall-cmd --permanent --remove-port=3000/tcp || true
sudo firewall-cmd --reload
sudo firewall-cmd --list-ports
```

Access URL:

```text
https://<host-ip>:8443
```

---

## 3) Unified dashboard design (single dashboard)

Create one dashboard titled `OCI PostgreSQL Unified Insights` with two top-level rows:

### Row A: **DB OCI Stats**
- Connections
- TPS (commit + rollback)
- Cache Hit %
- Deadlocks/sec
- Replication Lag
- Checkpoint Pressure %
- (Optional via OCI Metrics datasource) DB node CPU/memory/storage/network panels

### Row B: **SQL Query Monitoring (RDS PI style)**
- Top SQL by total exec time (`pg_stat_statements_top_total_exec_time_ms`)
- Top SQL by mean exec time (`pg_stat_statements_top_mean_exec_time_ms`)
- Top SQL by calls (`pg_stat_statements_top_calls`)
- Rollback ratio %
- Temp bytes/transaction
- Top tables by dead tuple %
- Autovacuum cadence by table

> Keep datasource UID as `prometheus` for portability.

---

## 4) PostgreSQL prerequisites

```sql
CREATE USER monitor_user WITH PASSWORD 'REPLACE_ME';
GRANT pg_monitor TO monitor_user;
GRANT pg_read_all_stats TO monitor_user;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
```

If required in OCI PG parameters:
- set `shared_preload_libraries = 'pg_stat_statements'`
- restart database.

---

## 5) Add multiple DB endpoints

1. Duplicate exporter services in compose (`postgres_exporter_<name>`), each with its own DSN.
2. Add each exporter target in Prometheus scrape config.
3. Apply changes:

```bash
sudo docker compose -f /opt/observability-stack/docker-compose.yaml up -d
sudo docker restart prometheus
```

---

## 6) Validation commands

```bash
sudo docker compose -f /opt/observability-stack/docker-compose.yaml ps
curl -kI https://127.0.0.1:8443/
curl -s http://127.0.0.1:9090/-/ready && echo
curl -s http://127.0.0.1:9090/targets | grep -E "postgres_exporter|UP"
sudo docker logs --tail 80 nginx-grafana
sudo docker logs --tail 80 grafana
sudo docker logs --tail 80 prometheus
```

---

## 7) Destroy and rebuild steps

### 7.1 Safe destroy (keep persistent data)

```bash
cd /opt/observability-stack
sudo docker compose down

# Optional: clean unused images/networks
sudo docker image prune -f
sudo docker network prune -f
```

### 7.2 Full destroy (remove containers + data + generated config)

> Warning: this deletes Grafana and Prometheus persisted data.

```bash
cd /opt/observability-stack
sudo docker compose down -v --remove-orphans
sudo rm -rf /opt/observability-stack/data/grafana/*
sudo rm -rf /opt/observability-stack/data/prometheus/*
```

### 7.3 Rebuild from scratch

```bash
cd /opt/observability-stack

# regenerate configs (script provided below)
sudo /opt/observability-stack/generate-observability-configs.sh

# pull latest images and start
sudo docker compose pull
sudo docker compose up -d --force-recreate

# verify
sudo docker compose ps
curl -kI https://127.0.0.1:8443/
```

---

## 8) Script to generate all YAML/config files

Create this script:

```bash
sudo tee /opt/observability-stack/generate-observability-configs.sh > /dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="/opt/observability-stack"

mkdir -p \
  "$BASE_DIR/nginx/conf.d" \
  "$BASE_DIR/nginx/certs" \
  "$BASE_DIR/prometheus" \
  "$BASE_DIR/postgres-exporter" \
  "$BASE_DIR/grafana/provisioning/datasources" \
  "$BASE_DIR/grafana/provisioning/dashboards" \
  "$BASE_DIR/grafana/dashboards" \
  "$BASE_DIR/data/grafana" \
  "$BASE_DIR/data/prometheus"

chown -R 472:472 "$BASE_DIR/data/grafana"
chown -R 65534:65534 "$BASE_DIR/data/prometheus"

cat > "$BASE_DIR/prometheus/prometheus.yml" <<'YAML'
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']

  - job_name: postgres_exporters
    static_configs:
      - targets:
          - postgres_exporter_primary:9187
          - postgres_exporter_reporting:9187
YAML

cat > "$BASE_DIR/postgres-exporter/queries.yaml" <<'YAML'
pg_stat_statements_top:
  query: |
    SELECT
      s.queryid::text AS queryid,
      d.datname::text AS datname,
      regexp_replace(left(s.query, 120), E'[\n\r\t]+', ' ', 'g')::text AS short_query,
      s.calls::double precision AS calls,
      s.total_exec_time::double precision AS total_exec_time_ms,
      s.mean_exec_time::double precision AS mean_exec_time_ms,
      s.rows::double precision AS rows_processed
    FROM pg_stat_statements s
    JOIN pg_database d ON d.oid = s.dbid
    ORDER BY s.total_exec_time DESC
    LIMIT 25;
  metrics:
    - queryid: {usage: "LABEL", description: "Query ID"}
    - datname: {usage: "LABEL", description: "Database"}
    - short_query: {usage: "LABEL", description: "Truncated SQL"}
    - calls: {usage: "GAUGE", description: "Calls"}
    - total_exec_time_ms: {usage: "GAUGE", description: "Total exec ms"}
    - mean_exec_time_ms: {usage: "GAUGE", description: "Mean exec ms"}
    - rows_processed: {usage: "GAUGE", description: "Rows"}
YAML

cat > "$BASE_DIR/grafana/provisioning/datasources/datasources.yml" <<'YAML'
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: true
YAML

cat > "$BASE_DIR/grafana/provisioning/dashboards/dashboards.yml" <<'YAML'
apiVersion: 1
providers:
  - name: OCI-PostgreSQL
    orgId: 1
    folder: PostgreSQL
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards
YAML

cat > "$BASE_DIR/nginx/conf.d/default.conf" <<'NGINX'
server {
  listen 80;
  server_name _;
  return 301 https://$host:8443$request_uri;
}

server {
  listen 8443 ssl http2;
  server_name _;

  ssl_certificate     /etc/nginx/certs/grafana.crt;
  ssl_certificate_key /etc/nginx/certs/grafana.key;
  ssl_protocols TLSv1.2 TLSv1.3;

  add_header X-Frame-Options SAMEORIGIN always;
  add_header X-Content-Type-Options nosniff always;
  add_header Referrer-Policy strict-origin-when-cross-origin always;

  location / {
    proxy_pass http://grafana:3000;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
  }
}
NGINX

cat > "$BASE_DIR/docker-compose.yaml" <<'YAML'
services:
  nginx:
    image: nginx:stable-alpine
    container_name: nginx-grafana
    restart: unless-stopped
    ports:
      - "0.0.0.0:8443:8443"
      - "0.0.0.0:80:80"
    volumes:
      - /opt/observability-stack/nginx/conf.d/default.conf:/etc/nginx/conf.d/default.conf:ro
      - /opt/observability-stack/nginx/certs:/etc/nginx/certs:ro
    depends_on:
      - grafana
    networks: [monitoring]

  grafana:
    image: grafana/grafana-oss:latest
    container_name: grafana
    restart: unless-stopped
    environment:
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD: ChangeThisNow!StrongPass123
      GF_USERS_ALLOW_SIGN_UP: "false"
      GF_SECURITY_COOKIE_SECURE: "true"
      GF_SECURITY_COOKIE_SAMESITE: strict
      GF_INSTALL_PLUGINS: oci-metrics-datasource,oci-logs-datasource
    volumes:
      - /opt/observability-stack/data/grafana:/var/lib/grafana
      - /opt/observability-stack/grafana/provisioning:/etc/grafana/provisioning:ro
      - /opt/observability-stack/grafana/dashboards:/var/lib/grafana/dashboards:ro
    networks: [monitoring]

  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    restart: unless-stopped
    ports:
      - "127.0.0.1:9090:9090"
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --web.enable-lifecycle
    volumes:
      - /opt/observability-stack/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - /opt/observability-stack/data/prometheus:/prometheus
    networks: [monitoring]

  postgres_exporter_primary:
    image: prometheuscommunity/postgres-exporter:latest
    container_name: postgres_exporter_primary
    restart: unless-stopped
    environment:
      DATA_SOURCE_NAME: postgresql://monitor_user:REPLACE_ME@10.10.1.82:5432/postgres?sslmode=require
    command:
      - --extend.query-path=/etc/postgres_exporter/queries.yaml
    volumes:
      - /opt/observability-stack/postgres-exporter/queries.yaml:/etc/postgres_exporter/queries.yaml:ro
    networks: [monitoring]

  postgres_exporter_reporting:
    image: prometheuscommunity/postgres-exporter:latest
    container_name: postgres_exporter_reporting
    restart: unless-stopped
    environment:
      DATA_SOURCE_NAME: postgresql://monitor_user:REPLACE_ME@10.10.1.83:5432/postgres?sslmode=require
    command:
      - --extend.query-path=/etc/postgres_exporter/queries.yaml
    volumes:
      - /opt/observability-stack/postgres-exporter/queries.yaml:/etc/postgres_exporter/queries.yaml:ro
    networks: [monitoring]

networks:
  monitoring:
    name: monitoring
    driver: bridge
YAML

echo "All config files generated under $BASE_DIR"
EOF

sudo chmod +x /opt/observability-stack/generate-observability-configs.sh
```

Run the generator:

```bash
sudo /opt/observability-stack/generate-observability-configs.sh
```

---

## 9) One-command operational scripts

You now have the following scripts (generated in your working directory):

- `.env` / `.env.example` → all environment-specific parameters
- `lib/common.sh` → shared functions and `.env` loader used by all scripts
- `generate_configs.sh` → writes all YAML/config files under `/opt/observability-stack`
- `deploy_stack.sh` → one-command deploy (generate configs, create cert if missing, start stack, apply firewall)
- `destroy_stack.sh` → one-command destroy (optionally purge persisted data)
- `rotate_certs.sh` → rotate self-signed TLS cert and reload NGINX
- `smoke_test.sh` → post-rebuild smoke tests

Copy scripts to target path and make executable:

```bash
sudo cp /Users/shadab/Downloads/{generate_configs.sh,deploy_stack.sh,destroy_stack.sh,rotate_certs.sh,smoke_test.sh} /opt/observability-stack/
sudo chmod +x /opt/observability-stack/{generate_configs.sh,deploy_stack.sh,destroy_stack.sh,rotate_certs.sh,smoke_test.sh}
```

Also copy env + shared library:

```bash
sudo mkdir -p /opt/observability-stack/lib
sudo cp /Users/shadab/Downloads/.env /opt/observability-stack/.env
sudo cp /Users/shadab/Downloads/.env.example /opt/observability-stack/.env.example
sudo cp /Users/shadab/Downloads/lib/common.sh /opt/observability-stack/lib/common.sh
```

> To customize paths/ports/DB DSNs/plugin settings/container images, edit `/opt/observability-stack/.env` only.

### Deploy with one command

```bash
sudo /opt/observability-stack/deploy_stack.sh
```

### Destroy with one command

Keep data:

```bash
sudo /opt/observability-stack/destroy_stack.sh
```

Destroy + purge persisted Grafana/Prometheus data:

```bash
sudo /opt/observability-stack/destroy_stack.sh --purge-data
```

### Certificate rotation

Rotate for default 365 days:

```bash
sudo /opt/observability-stack/rotate_certs.sh
```

Rotate for custom validity (e.g., 180 days):

```bash
sudo /opt/observability-stack/rotate_certs.sh 180
```

### Post-rebuild smoke tests

```bash
sudo /opt/observability-stack/smoke_test.sh
```

---

## 10) Troubleshooting: `curl: (22) ... 502` during deploy

If you see this at deploy step `[5/6]`:

```text
curl: (22) The requested URL returned error: 502
```

It usually means **NGINX is up but Grafana is still starting** (startup race).  
This is expected sometimes on first pull/start.

### What has been improved

- `deploy_stack.sh` now has retry-based health checks.
- It waits for Grafana via NGINX using:
  - `HEALTHCHECK_MAX_RETRIES`
  - `HEALTHCHECK_SLEEP_SECONDS`
- On failure, it prints recent NGINX/Grafana logs automatically.

### Tune retries in `.env`

```env
HEALTHCHECK_MAX_RETRIES=30
HEALTHCHECK_SLEEP_SECONDS=2
```

For slow hosts, increase to e.g.:

```env
HEALTHCHECK_MAX_RETRIES=60
HEALTHCHECK_SLEEP_SECONDS=3
```

### Manual checks

```bash
sudo docker compose -f /opt/observability-stack/docker-compose.yaml ps
sudo docker logs --tail 120 nginx-grafana
sudo docker logs --tail 120 grafana
curl -kI https://127.0.0.1:8443/login
```

---

## 11) Recommended improvements

1. **Security & secrets**
   - Move DB DSNs and Grafana admin password from `.env` to a secrets backend (OCI Vault / Docker secrets).
   - Restrict TLS port source CIDRs (VPN/jump-host only).

2. **Reliability**
   - Pin image versions (avoid `latest`) and patch on schedule.
   - Add container healthchecks in compose (Grafana, NGINX, Prometheus, exporters).

3. **Observability maturity**
   - Add Prometheus alert rules + Alertmanager routing.
   - Add Grafana contact points and alert policies for lag, deadlocks, exporter down, high rollback ratio.

4. **Performance and scale**
   - Split exporters by workload tiers (OLTP/reporting/analytics).
   - Add recording rules for expensive PromQL panels.

5. **Ops hygiene**
   - Add CI checks: `bash -n`, `shellcheck`, and config generation smoke test.
   - Create `make` targets (`make deploy`, `make destroy`, `make test`) for operator consistency.

---

## 12) OCI Metrics datasource + OCI PostgreSQL metrics dashboard

The current build can auto-provision:

1. **Oracle Cloud Infrastructure Metrics** Grafana datasource (`oci-metrics-datasource`)  
2. **OCI PostgreSQL metrics dashboard** (`oci-postgresql-metrics.json`)
3. **OCI PostgreSQL unified insights dashboard** (`postgresql-unified-insights.json`)

### Required `.env` variables

```env
# OCI datasource toggle and identity
OCI_DS_ENABLED=true
OCI_DS_NAME="Oracle Cloud Infrastructure Metrics"
OCI_DS_UID=oci-metrics

# OCI auth profile reference
OCI_CONFIG_PROFILE=DEFAULT
OCI_CONFIG_FILE=/home/opc/.oci/config
OCI_PRIVATE_KEY_FILE=/home/opc/.oci/priv.key
OCI_CONTAINER_CONFIG_PATH=/etc/grafana/oci/config
OCI_CONTAINER_PRIVATE_KEY_PATH=/etc/grafana/oci/priv.key

# OCI identity values
OCI_TENANCY_OCID=ocid1.tenancy.oc1..<REPLACE_ME>
OCI_USER_OCID=ocid1.user.oc1..<REPLACE_ME>
OCI_REGION=ap-tokyo-1
OCI_FINGERPRINT=aa:bb:cc:dd:...

# Private key: either inline snippet OR read from OCI_PRIVATE_KEY_FILE
OCI_PRIVATE_KEY_PEM_SNIPPET="-----BEGIN PRIVATE KEY-----\nPASTE_PRIVATE_KEY_CONTENT_HERE\n-----END PRIVATE KEY-----"

# Dashboard defaults for OCI PostgreSQL metrics scope
OCI_PG_COMPARTMENT_OCID=ocid1.compartment.oc1..<REPLACE_ME>
OCI_PG_RESOURCE_GROUP=postgresql
```

### DEFAULT profile mapping used from your local OCI config

Current values extracted from `/Users/shadab/.oci/config` (`[DEFAULT]`):

- `OCI_CONFIG_PROFILE=DEFAULT`
- `OCI_CONFIG_FILE=/home/opc/.oci/config`
- `OCI_TENANCY_OCID=ocid1.tenancy.oc1..aaaaaaaafhegmvy2da7xzh2b5jbmhdkfr4cr4e37m5filt4zgxs6mfl7icua`
- `OCI_USER_OCID=ocid1.user.oc1..aaaaaaaa5cq3iewffep5nzqb7qzoe6mpj45gt4kndvzwvuxzzavpbiucqqaq`
- `OCI_REGION=ap-tokyo-1`
- `OCI_FINGERPRINT=de:50:15:13:af:bd:76:fa:f4:77:ad:d4:af:70:a5:d6`

### Private key snippet example format

```env
OCI_PRIVATE_KEY_PEM_SNIPPET=-----BEGIN PRIVATE KEY-----\nMIIEv...<redacted>...\n-----END PRIVATE KEY-----
```

> Keep `\n` escaped in `.env`.  
> If you keep the placeholder `PASTE_PRIVATE_KEY_CONTENT_HERE`, generator will try to load content from `OCI_PRIVATE_KEY_FILE`.
> Ensure `OCI_CONFIG_FILE` and `OCI_PRIVATE_KEY_FILE` exist on host; deploy mounts them into Grafana at `OCI_CONTAINER_CONFIG_PATH` and `OCI_CONTAINER_PRIVATE_KEY_PATH`.
> Generator is fail-fast for OCI auth: if config path is missing, or private key remains placeholder without a valid key file, generation exits with error.

### Optional: single datasource approach via Prometheus

If you want OCI metrics visible through Grafana Prometheus datasource only, ingest OCI metrics into Prometheus (e.g., OCI->OTel Collector->Prometheus endpoint) and append scrape jobs using:

```env
PROM_ADDITIONAL_SCRAPE_CONFIG=/opt/observability-stack/prometheus/extra-scrape-config.yml
```

`generate_configs.sh` appends this file to generated `prometheus.yml`.

### Deploy/redeploy to apply OCI datasource + dashboard

```bash
sudo ./deploy_stack.sh
```

Generated assets:

- `${BASE_DIR}/grafana/provisioning/datasources/datasources.yml`
- `${BASE_DIR}/grafana/dashboards/oci-postgresql-metrics.json`
- `${BASE_DIR}/grafana/dashboards/postgresql-unified-insights.json`

`postgresql-unified-insights.json` is generated natively by `generate_configs.sh` (bootstrapped from embedded structure) and does not require importing an external JSON dashboard file at runtime.

Unified dashboard datasource mapping:

- Prometheus panels → `GRAFANA_DS_UID`
- OCI panels → `OCI_DS_UID`

The OCI dashboard includes panels for:

- CPU Utilization
- Memory Utilization
- Storage Utilization
- Database Connections
- Read IOPS
- Write IOPS
