#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/common.sh"

load_env

if [[ "$BASE_DIR" == /opt/* || "$ENABLE_FIREWALL" == "true" ]]; then
  require_root
fi

log "Stopping observability stack..."
compose_cmd down

if [[ "$ENABLE_FIREWALL" == "true" ]]; then
  log "Closing firewall ports..."
  firewall_close_ports
fi

log "Stack stopped"
