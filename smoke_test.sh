#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/common.sh"

load_env

if [[ "$BASE_DIR" == /opt/* ]]; then
  require_root
fi

log "[1/7] Container status"
compose_cmd ps

log "[2/7] Grafana endpoint"
curl -ksSf "https://${LOCAL_TEST_HOST}:${NGINX_HTTPS_PORT}/login" >/dev/null
log "Grafana endpoint OK"

log "[3/7] Prometheus readiness"
curl -sSf "http://${LOCAL_TEST_HOST}:${PROM_PORT}/-/ready" >/dev/null
log "Prometheus readiness OK"

log "[4/7] Prometheus targets up count"
UP_COUNT="$(curl -s "http://${LOCAL_TEST_HOST}:${PROM_PORT}/api/v1/targets" | jq '[.data.activeTargets[] | select(.health=="up")] | length')"
log "Targets UP: $UP_COUNT"

log "[5/7] postgres_exporter metrics present"
curl -s "http://${LOCAL_TEST_HOST}:${PROM_PORT}/api/v1/label/__name__/values" | jq -r '.data[]' | grep -E '^pg_up$|^pg_stat_database_numbackends$' >/dev/null
log "Core postgres metrics found"

log "[6/7] NGINX certificate validity"
openssl x509 -in "$BASE_DIR/nginx/certs/grafana.crt" -noout -enddate

log "[7/7] Recent logs (tail)"
docker logs --tail 20 "$NGINX_CONTAINER_NAME" || true
docker logs --tail 20 "$GRAFANA_CONTAINER_NAME" || true
docker logs --tail 20 "$PROM_CONTAINER_NAME" || true

log "Smoke test passed"
