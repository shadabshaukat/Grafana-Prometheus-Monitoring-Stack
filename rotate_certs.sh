#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/common.sh"

load_env

DAYS="${1:-$CERT_DAYS}"

if [[ "$BASE_DIR" == /opt/* ]]; then
  require_root
fi

mkdir -p "$CERT_DIR"

TS="$(date +%Y%m%d-%H%M%S)"
if [[ -f "$CERT_DIR/grafana.crt" ]]; then
  cp "$CERT_DIR/grafana.crt" "$CERT_DIR/grafana.crt.bak-$TS"
fi
if [[ -f "$CERT_DIR/grafana.key" ]]; then
  cp "$CERT_DIR/grafana.key" "$CERT_DIR/grafana.key.bak-$TS"
fi

openssl req -x509 -nodes -days "$DAYS" -newkey rsa:4096 \
  -keyout "$CERT_DIR/grafana.key" \
  -out "$CERT_DIR/grafana.crt" \
  -subj "$(cert_subject)"

chmod 600 "$CERT_DIR/grafana.key"

log "Restarting NGINX container to load new certificate..."
docker restart "$NGINX_CONTAINER_NAME"

log "New certificate details:"
openssl x509 -in "$CERT_DIR/grafana.crt" -noout -subject -enddate
