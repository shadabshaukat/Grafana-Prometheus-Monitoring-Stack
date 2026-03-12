#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/common.sh"

load_env

FORCE="false"
if [[ "${1:-}" == "--force" ]]; then
  FORCE="true"
fi

should_write() {
  local path="$1"
  if [[ "$FORCE" == "true" ]]; then
    return 0
  fi
  [[ ! -f "$path" ]]
}

write_file() {
  local path="$1"
  if [[ -f "$path" && "$FORCE" != "true" ]]; then
    log "[SKIP] $path exists (use --force to overwrite)"
    return
  fi
  cat > "$path"
  log "[OK] wrote $path"
}

mkdir -p \
  "$NGINX_CONF_DIR" "$CERT_DIR" "$PROM_DIR" "$PGEXP_DIR" \
  "$GRAFANA_DS_DIR" "$GRAFANA_DASH_PROV_DIR" "$GRAFANA_DASH_DIR" \
  "$GRAFANA_DATA_DIR" "$PROM_DATA_DIR"

if [[ "$ENABLE_CHOWN" == "true" ]]; then
  chown -R 472:472 "$GRAFANA_DATA_DIR" || true
  chown -R 65534:65534 "$PROM_DATA_DIR" || true
fi

if should_write "$PROM_DIR/prometheus.yml"; then
  write_file "$PROM_DIR/prometheus.yml" <<EOF_PROM
global:
  scrape_interval: ${PROM_SCRAPE_INTERVAL}

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:${PROM_PORT}']

  - job_name: postgres_exporters
    static_configs:
      - targets:
EOF_PROM

  IFS=',' read -r -a exporter_targets <<< "$EXPORTER_TARGETS"
  for t in "${exporter_targets[@]}"; do
    printf "          - %s\n" "$t" >> "$PROM_DIR/prometheus.yml"
  done
else
  log "[SKIP] $PROM_DIR/prometheus.yml append phase skipped"
fi

write_file "$PGEXP_DIR/queries.yaml" <<'EOF_Q'
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
EOF_Q

write_file "$GRAFANA_DS_DIR/datasources.yml" <<EOF_DS
apiVersion: 1
datasources:
  - name: ${GRAFANA_DS_NAME}
    uid: ${GRAFANA_DS_UID}
    type: prometheus
    access: proxy
    url: http://prometheus:${PROM_PORT}
    isDefault: true
    editable: true
EOF_DS

write_file "$GRAFANA_DASH_PROV_DIR/dashboards.yml" <<'EOF_DP'
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
EOF_DP

write_file "$NGINX_CONF_DIR/default.conf" <<EOF_NGX
server {
  listen ${NGINX_HTTP_PORT};
  server_name _;
  return 301 https://\$host:${NGINX_HTTPS_PORT}\$request_uri;
}

server {
  listen ${NGINX_HTTPS_PORT} ssl http2;
  server_name _;

  ssl_certificate     /etc/nginx/certs/grafana.crt;
  ssl_certificate_key /etc/nginx/certs/grafana.key;
  ssl_protocols TLSv1.2 TLSv1.3;

  add_header X-Frame-Options SAMEORIGIN always;
  add_header X-Content-Type-Options nosniff always;
  add_header Referrer-Policy strict-origin-when-cross-origin always;

  location / {
    proxy_pass http://grafana:${GRAFANA_INTERNAL_PORT};
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
  }
}
EOF_NGX

if should_write "$BASE_DIR/docker-compose.yaml"; then
  write_file "$BASE_DIR/docker-compose.yaml" <<EOF_DC
services:
  nginx:
    image: ${NGINX_IMAGE}
    container_name: ${NGINX_CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "${NGINX_BIND_ADDRESS}:${NGINX_HTTPS_PORT}:${NGINX_HTTPS_PORT}"
      - "${NGINX_BIND_ADDRESS}:${NGINX_HTTP_PORT}:${NGINX_HTTP_PORT}"
    volumes:
      - ${NGINX_CONF_DIR}/default.conf:/etc/nginx/conf.d/default.conf:ro
      - ${CERT_DIR}:/etc/nginx/certs:ro
    depends_on:
      - grafana
    networks: [monitoring]

  grafana:
    image: ${GRAFANA_IMAGE}
    container_name: ${GRAFANA_CONTAINER_NAME}
    restart: unless-stopped
    environment:
      GF_SECURITY_ADMIN_USER: ${GRAFANA_ADMIN_USER}
      GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_ADMIN_PASSWORD}
      GF_USERS_ALLOW_SIGN_UP: "${GRAFANA_ALLOW_SIGNUP}"
      GF_SECURITY_COOKIE_SECURE: "${GRAFANA_COOKIE_SECURE}"
      GF_SECURITY_COOKIE_SAMESITE: ${GRAFANA_COOKIE_SAMESITE}
      GF_INSTALL_PLUGINS: ${GRAFANA_INSTALL_PLUGINS}
    volumes:
      - ${GRAFANA_DATA_DIR}:/var/lib/grafana
      - ${BASE_DIR}/grafana/provisioning:/etc/grafana/provisioning:ro
      - ${GRAFANA_DASH_DIR}:/var/lib/grafana/dashboards:ro
    networks: [monitoring]

  prometheus:
    image: ${PROM_IMAGE}
    container_name: ${PROM_CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "${PROM_BIND_ADDRESS}:${PROM_PORT}:${PROM_PORT}"
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --web.enable-lifecycle
      - --web.listen-address=:${PROM_PORT}
    volumes:
      - ${PROM_DIR}/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ${PROM_DATA_DIR}:/prometheus
    networks: [monitoring]
EOF_DC

  for i in $(seq 1 "$EXPORTER_COUNT"); do
    name_var="EXPORTER_${i}_NAME"
    dsn_var="EXPORTER_${i}_DSN"
    name="${!name_var:-}"
    dsn="${!dsn_var:-}"
    if [[ -z "$name" || -z "$dsn" ]]; then
      warn "Skipping exporter index $i (missing ${name_var} or ${dsn_var})"
      continue
    fi
    cat >> "$BASE_DIR/docker-compose.yaml" <<EOF_EXP

  ${name}:
    image: ${PG_EXPORTER_IMAGE}
    container_name: ${name}
    restart: unless-stopped
    environment:
      DATA_SOURCE_NAME: ${dsn}
    command:
      - --extend.query-path=/etc/postgres_exporter/queries.yaml
    volumes:
      - ${PGEXP_DIR}/queries.yaml:/etc/postgres_exporter/queries.yaml:ro
    networks: [monitoring]
EOF_EXP
  done

  cat >> "$BASE_DIR/docker-compose.yaml" <<'EOF_END'

networks:
  monitoring:
    name: monitoring
    driver: bridge
EOF_END
else
  log "[SKIP] $BASE_DIR/docker-compose.yaml append phase skipped"
fi

log "All stack config files generated under $BASE_DIR"