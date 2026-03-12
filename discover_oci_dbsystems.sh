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

if ! oci psql db-system list --help >/dev/null 2>&1; then
  die "Your OCI CLI does not support 'oci psql db-system list'. Please upgrade OCI CLI to a version with PostgreSQL service commands."
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
if ! oci_output="$({
  oci psql db-system list \
    --compartment-id "$COMPARTMENT_ID" \
    --all \
    --config-file "$OCI_CONFIG_FILE" \
    --profile "$PROFILE" \
    --region "$OCI_PROM_REGION" \
    --output json
} 2>&1)"; then
  printf '%s\n' "$oci_output" >&2
  die "OCI CLI request failed while listing DB Systems. Check OCI_CONFIG_FILE, OCI_CONFIG_PROFILE, OCI_PROM_REGION, and IAM permissions."
fi

if ! printf '%s' "$oci_output" | jq -e . >/dev/null 2>&1; then
  printf '%s\n' "$oci_output" >&2
  die "OCI CLI returned non-JSON output; cannot parse DB System IDs."
fi

ids="$(printf '%s' "$oci_output" | jq -r '(.data[]?.id // empty), (.data.items[]?.id // empty)' | paste -sd, -)"

printf '%s\n' "$ids"
