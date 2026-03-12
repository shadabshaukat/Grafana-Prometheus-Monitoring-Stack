#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/common.sh"

load_env

PURGE_DATA="false"

if [[ "${1:-}" == "--purge-data" ]]; then
  PURGE_DATA="true"
fi

if [[ "$BASE_DIR" == /opt/* || "$ENABLE_FIREWALL" == "true" ]]; then
  require_root
fi

if [[ ! -f "$BASE_DIR/docker-compose.yaml" ]]; then
  die "Compose file not found at $BASE_DIR/docker-compose.yaml"
fi

log "[1/3] Stopping and removing containers..."
compose_cmd down --remove-orphans

log "[2/3] Updating firewall rules (if enabled)..."
firewall_close_ports

if [[ "$PURGE_DATA" == "true" ]]; then
  log "[3/3] Purging persistent data..."
  rm -rf "$BASE_DIR/data/grafana"/*
  rm -rf "$BASE_DIR/data/prometheus"/*
else
  log "[3/3] Keeping persistent data (use --purge-data to delete it)."
fi

log "Done. Stack destroyed."
