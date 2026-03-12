#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/common.sh"

load_env

if [[ "$BASE_DIR" == /opt/* || "$ENABLE_FIREWALL" == "true" ]]; then
  require_root
fi

log "Starting observability stack..."
compose_cmd up -d

if [[ "$ENABLE_FIREWALL" == "true" ]]; then
  log "Ensuring firewall ports are open..."
  firewall_open_ports
fi

log "Current container status:"
compose_cmd ps

log "Stack started"
