#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/common.sh"

load_env

GEN_SCRIPT="$ROOT_DIR/generate_configs.sh"
SMOKE_SCRIPT="$ROOT_DIR/smoke_test.sh"

if [[ "$BASE_DIR" == /opt/* || "$ENABLE_FIREWALL" == "true" || "$ENABLE_CHOWN" == "true" ]]; then
  require_root
fi

if [[ ! -f "$GEN_SCRIPT" ]]; then
  die "Missing generator script: $GEN_SCRIPT"
fi

log "[1/6] Generating/refreshing config files..."
bash "$GEN_SCRIPT" --force

log "[2/6] Ensuring TLS certificate exists..."
mkdir -p "$CERT_DIR"
if [[ ! -f "$CERT_DIR/grafana.crt" || ! -f "$CERT_DIR/grafana.key" ]]; then
  openssl req -x509 -nodes -days "$CERT_DAYS" -newkey rsa:4096 \
    -keyout "$CERT_DIR/grafana.key" \
    -out "$CERT_DIR/grafana.crt" \
    -subj "$(cert_subject)"
  chmod 600 "$CERT_DIR/grafana.key"
fi

log "[3/6] Starting stack..."
compose_cmd pull
compose_cmd up -d

log "[4/6] Applying firewall rules (if enabled)..."
firewall_open_ports

log "[5/6] Running quick health checks..."
compose_cmd ps

health_ok=false
for i in $(seq 1 "$HEALTHCHECK_MAX_RETRIES"); do
  if curl -ksSf "https://${LOCAL_TEST_HOST}:${NGINX_HTTPS_PORT}/login" >/dev/null; then
    health_ok=true
    break
  fi
  log "Waiting for Grafana via NGINX... (${i}/${HEALTHCHECK_MAX_RETRIES})"
  sleep "$HEALTHCHECK_SLEEP_SECONDS"
done

if [[ "$health_ok" != "true" ]]; then
  warn "Grafana endpoint did not become ready in time. Showing recent logs:"
  docker logs --tail 80 "$NGINX_CONTAINER_NAME" || true
  docker logs --tail 80 "$GRAFANA_CONTAINER_NAME" || true
  die "Health check failed: https://${LOCAL_TEST_HOST}:${NGINX_HTTPS_PORT}/login"
fi

prom_ok=false
for i in $(seq 1 "$HEALTHCHECK_MAX_RETRIES"); do
  if curl -sSf "http://${LOCAL_TEST_HOST}:${PROM_PORT}/-/ready" >/dev/null; then
    prom_ok=true
    break
  fi
  log "Waiting for Prometheus... (${i}/${HEALTHCHECK_MAX_RETRIES})"
  sleep "$HEALTHCHECK_SLEEP_SECONDS"
done

if [[ "$prom_ok" != "true" ]]; then
  docker logs --tail 80 "$PROM_CONTAINER_NAME" || true
  die "Health check failed: http://${LOCAL_TEST_HOST}:${PROM_PORT}/-/ready"
fi

if [[ "$RUN_SMOKE_TEST_AFTER_DEPLOY" == "true" && -f "$SMOKE_SCRIPT" ]]; then
  log "Running smoke test script..."
  bash "$SMOKE_SCRIPT"
fi

log "[6/6] Done"
log "Grafana URL: https://<host-ip>:${NGINX_HTTPS_PORT}"
