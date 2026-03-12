#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/common.sh"

load_env

if [[ "$BASE_DIR" == /opt/* ]]; then
  require_root
fi

DASH_UID="${1:-$GRAFANA_UNIFIED_DASH_UID}"
API_BASE_URL="${GRAFANA_API_BASE_URL:-https://${LOCAL_TEST_HOST}:${NGINX_HTTPS_PORT}}"
AUTH_HEADER="${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}"

command -v curl >/dev/null 2>&1 || die "curl is required but not found"
command -v jq >/dev/null 2>&1 || die "jq is required but not found"

log "Checking dashboard datasource bindings via Grafana API"
log "Grafana API base: $API_BASE_URL"
log "Dashboard UID: $DASH_UID"

log "[1/4] Verifying required datasources exist"
curl -ksSf -u "$AUTH_HEADER" "$API_BASE_URL/api/datasources/uid/${GRAFANA_DS_UID}" >/dev/null
log "Prometheus datasource uid '${GRAFANA_DS_UID}' found"

if [[ "$OCI_DS_ENABLED" == "true" ]]; then
  curl -ksSf -u "$AUTH_HEADER" "$API_BASE_URL/api/datasources/uid/${OCI_DS_UID}" >/dev/null
  log "OCI datasource uid '${OCI_DS_UID}' found"
fi

log "[2/4] Fetching unified dashboard JSON"
dashboard_json="$(curl -ksSf -u "$AUTH_HEADER" "$API_BASE_URL/api/dashboards/uid/${DASH_UID}")"

echo "$dashboard_json" | jq -e --arg uid "$DASH_UID" '.dashboard.uid == $uid' >/dev/null
log "Dashboard '${DASH_UID}' exists"

log "[3/4] Running datasource binding assertions"
jq_filter="$(cat <<'JQ'
def ds_uid($ds):
  if $ds == null then ""
  elif ($ds | type) == "object" then ($ds.uid // $ds.name // "")
  elif ($ds | type) == "string" then $ds
  else ""
  end;

def ds_type($ds):
  if $ds == null then ""
  elif ($ds | type) == "object" then ($ds.type // "")
  else ""
  end;

def flatten_panels($arr):
  [ $arr[]? as $p | $p, (flatten_panels($p.panels // []))[] ];

(flatten_panels(.dashboard.panels // [])) as $all_panels
| ($all_panels | map(select(.type != "row"))) as $metric_panels
| ($metric_panels | map(select((.title // "") | startswith("OCI ")))) as $oci_panels
| ($metric_panels | map(select(((.title // "") | startswith("OCI ")) | not))) as $prom_panels
| [
    (if ($metric_panels | length) == 0 then "Dashboard has no non-row panels" else empty end),
    (if ($oci_panels | length) == 0 then "No OCI panels detected (expected title prefix: OCI )" else empty end),
    (if ($prom_panels | length) == 0 then "No Prometheus panels detected" else empty end),

    ($metric_panels[]
      | select(ds_uid(.datasource) == "" or ds_uid(.datasource) == "-- Dashboard --")
      | "Panel \(.title): panel datasource is empty or -- Dashboard --"),

    ($metric_panels[] as $p
      | ($p.targets // [])[]?
      | select((has("datasource")) and (ds_uid(.datasource) == "" or ds_uid(.datasource) == "-- Dashboard --"))
      | "Panel \($p.title): target \(.refId // "?") datasource is empty or -- Dashboard --"),

    ($oci_panels[]
      | select(ds_uid(.datasource) != $oci_uid or ds_type(.datasource) != "oci-metrics-datasource")
      | "Panel \(.title): expected panel datasource uid=\($oci_uid), type=oci-metrics-datasource"),

    ($oci_panels[] as $p
      | ($p.targets // [])[]?
      | select(ds_uid(.datasource) != $oci_uid or ds_type(.datasource) != "oci-metrics-datasource")
      | "Panel \($p.title): target \(.refId // "?") missing explicit OCI datasource uid=\($oci_uid), type=oci-metrics-datasource"),

    ($prom_panels[]
      | select(ds_uid(.datasource) != $prom_uid or ds_type(.datasource) != "prometheus")
      | "Panel \(.title): expected panel datasource uid=\($prom_uid), type=prometheus")
  ]
| map(select(. != null and . != ""))
| .[]
JQ
)"

violations="$({
  echo "$dashboard_json" | jq -r \
    --arg prom_uid "$GRAFANA_DS_UID" \
    --arg oci_uid "$OCI_DS_UID" \
    "$jq_filter"
} | sed '/^$/d')"

if [[ -n "$violations" ]]; then
  warn "Datasource binding check failed with the following issues:"
  printf '%s\n' "$violations" | sed 's/^/ - /'
  die "Grafana datasource binding validation failed"
fi

log "[4/4] All datasource binding checks passed"
