#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/common.sh"

load_env

sanitize_oci_profile() {
  local raw="$1"
  printf '%s' "$raw" | tr -d '[:space:][]' | sed -E 's#[:/]+$##'
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_cmd oci
require_cmd jq

OCI_LIST_CMD=()
if oci psql db-system-collection list-db-systems --help >/dev/null 2>&1; then
  OCI_LIST_CMD=(oci psql db-system-collection list-db-systems)
elif oci psql db-system list --help >/dev/null 2>&1; then
  OCI_LIST_CMD=(oci psql db-system list)
else
  die "Your OCI CLI does not support PostgreSQL DBSystem list commands. Expected one of: 'oci psql db-system-collection list-db-systems' or 'oci psql db-system list'."
fi

PROFILE="$(sanitize_oci_profile "$OCI_CONFIG_PROFILE")"
[[ -n "$PROFILE" ]] || die "OCI_CONFIG_PROFILE is empty/invalid after sanitization: '$OCI_CONFIG_PROFILE'"

COMPARTMENT_ID="${OCI_PROM_COMPARTMENT_OCID:-${OCI_PG_COMPARTMENT_OCID:-}}"
[[ -n "$COMPARTMENT_ID" ]] || die "Set OCI_PROM_COMPARTMENT_OCID (or OCI_PG_COMPARTMENT_OCID) before discovery"

if [[ "$COMPARTMENT_ID" == *"<REPLACE_ME>"* ]]; then
  die "Compartment OCID appears to be placeholder: $COMPARTMENT_ID"
fi

[[ -f "$OCI_CONFIG_FILE" ]] || die "OCI config file not found: $OCI_CONFIG_FILE"

oci_output=""
oci_err_file="$(mktemp)"
if ! oci_output="$({
  "${OCI_LIST_CMD[@]}" \
    --compartment-id "$COMPARTMENT_ID" \
    --all \
    --config-file "$OCI_CONFIG_FILE" \
    --profile "$PROFILE" \
    --region "$OCI_PROM_REGION" \
    --output json
} 2>"$oci_err_file")"; then
  [[ -s "$oci_err_file" ]] && cat "$oci_err_file" >&2
  [[ -n "$oci_output" ]] && printf '%s\n' "$oci_output" >&2
  rm -f "$oci_err_file"
  die "OCI CLI request failed while listing DB Systems. Check OCI_CONFIG_FILE, OCI_CONFIG_PROFILE, OCI_PROM_REGION, and IAM permissions."
fi

if [[ -s "$oci_err_file" ]]; then
  printf '%s\n' "[WARN] OCI CLI emitted warnings during discovery (continuing):" >&2
  cat "$oci_err_file" >&2
fi
rm -f "$oci_err_file"

if ! printf '%s' "$oci_output" | jq -e . >/dev/null 2>&1; then
  printf '%s\n' "$oci_output" >&2
  die "OCI CLI returned non-JSON output; cannot parse DB System IDs."
fi

id_lines=""
if ! id_lines="$(
  printf '%s' "$oci_output" \
    | jq -r '
        (.data // empty)
        | ..
        | objects
        | .id?
        | select(type == "string")
      '
)"; then
  printf '%s\n' "$oci_output" >&2
  die "Failed to parse OCI DB System list JSON response."
fi

ids="$(printf '%s\n' "$id_lines" | awk 'NF && !seen[$0]++' | paste -sd, -)"

printf '%s\n' "$ids"
