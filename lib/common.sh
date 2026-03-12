#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE_DEFAULT="$SCRIPT_DIR/.env"

log() { printf '%s\n' "[$(date +%H:%M:%S)] $*"; }
warn() { printf '%s\n' "[WARN] $*"; }
die() { printf '%s\n' "[ERROR] $*" >&2; exit 1; }

load_env() {
  local env_file="${ENV_FILE:-$ENV_FILE_DEFAULT}"

  if [[ ! -f "$env_file" ]]; then
    if [[ -f "$SCRIPT_DIR/.env.example" ]]; then
      die "Missing $env_file. Copy $SCRIPT_DIR/.env.example to $env_file and customize values."
    else
      die "Missing $env_file"
    fi
  fi

  # shellcheck disable=SC1090
  set -a; source "$env_file"; set +a

  : "${BASE_DIR:=/opt/observability-stack}"
  : "${ENV_NAME:=default}"
  : "${NGINX_HTTP_PORT:=80}"
  : "${NGINX_HTTPS_PORT:=8443}"
  : "${NGINX_BIND_ADDRESS:=0.0.0.0}"
  : "${NGINX_IMAGE:=nginx:stable-alpine}"
  : "${NGINX_CONTAINER_NAME:=nginx-grafana}"
  : "${PROM_BIND_ADDRESS:=127.0.0.1}"
  : "${LOCAL_TEST_HOST:=127.0.0.1}"
  : "${PROM_PORT:=9090}"
  : "${PROM_SCRAPE_INTERVAL:=15s}"
  : "${PROM_IMAGE:=prom/prometheus:latest}"
  : "${PROM_CONTAINER_NAME:=prometheus}"
  : "${GRAFANA_INTERNAL_PORT:=3000}"
  : "${GRAFANA_IMAGE:=grafana/grafana-oss:latest}"
  : "${GRAFANA_CONTAINER_NAME:=grafana}"
  : "${GRAFANA_ADMIN_USER:=admin}"
  : "${GRAFANA_ADMIN_PASSWORD:=ChangeThisNow!StrongPass123}"
  : "${GRAFANA_ALLOW_SIGNUP:=false}"
  : "${GRAFANA_COOKIE_SECURE:=true}"
  : "${GRAFANA_COOKIE_SAMESITE:=strict}"
  : "${GRAFANA_INSTALL_PLUGINS:=oci-metrics-datasource,oci-logs-datasource}"
  : "${GRAFANA_DS_NAME:=Prometheus}"
  : "${GRAFANA_DS_UID:=prometheus}"
  : "${OCI_DS_ENABLED:=true}"
  : "${OCI_DS_NAME:=Oracle Cloud Infrastructure Metrics}"
  : "${OCI_DS_UID:=oci-metrics}"
  : "${OCI_CONFIG_PROFILE:=DEFAULT}"
  : "${OCI_CONFIG_FILE:=/Users/shadab/.oci/config}"
  : "${OCI_PRIVATE_KEY_FILE:=/Users/shadab/.oci/oci_api_key.pem}"
  : "${OCI_REGION:=ap-tokyo-1}"
  : "${OCI_TENANCY_OCID:=ocid1.tenancy.oc1..aaaaaaaafhegmvy2da7xzh2b5jbmhdkfr4cr4e37m5filt4zgxs6mfl7icua}"
  : "${OCI_USER_OCID:=ocid1.user.oc1..aaaaaaaa5cq3iewffep5nzqb7qzoe6mpj45gt4kndvzwvuxzzavpbiucqqaq}"
  : "${OCI_FINGERPRINT:=de:50:15:13:af:bd:76:fa:f4:77:ad:d4:af:70:a5:d6}"
  : "${OCI_PRIVATE_KEY_PEM_SNIPPET:=-----BEGIN PRIVATE KEY-----\\n<PASTE_PRIVATE_KEY_CONTENT>\\n-----END PRIVATE KEY-----}"
  : "${OCI_PG_COMPARTMENT_OCID:=ocid1.compartment.oc1..<REPLACE_ME>}"
  : "${OCI_PG_RESOURCE_GROUP:=postgresql}"
  : "${PG_EXPORTER_IMAGE:=prometheuscommunity/postgres-exporter:latest}"
  : "${ENABLE_CHOWN:=true}"
  : "${ENABLE_FIREWALL:=true}"
  : "${FIREWALL_BACKEND:=auto}"
  : "${EXPORTER_COUNT:=2}"
  : "${EXPORTER_TARGETS:=postgres_exporter_primary:9187,postgres_exporter_reporting:9187}"
  : "${EXPORTER_1_NAME:=postgres_exporter_primary}"
  : "${EXPORTER_1_DSN:=postgresql://monitor_user:REPLACE_ME@10.10.1.82:5432/postgres?sslmode=require}"
  : "${EXPORTER_2_NAME:=postgres_exporter_reporting}"
  : "${EXPORTER_2_DSN:=postgresql://monitor_user:REPLACE_ME@10.10.1.83:5432/postgres?sslmode=require}"
  : "${CERT_DAYS:=365}"
  : "${CERT_COUNTRY:=AU}"
  : "${CERT_STATE:=NSW}"
  : "${CERT_LOCALITY:=Sydney}"
  : "${CERT_ORG:=Observability}"
  : "${CERT_OU:=Platform}"
  : "${CERT_CN:=grafana.local}"
  : "${RUN_SMOKE_TEST_AFTER_DEPLOY:=true}"
  : "${HEALTHCHECK_MAX_RETRIES:=30}"
  : "${HEALTHCHECK_SLEEP_SECONDS:=2}"

  NGINX_CONF_DIR="$BASE_DIR/nginx/conf.d"
  CERT_DIR="$BASE_DIR/nginx/certs"
  PROM_DIR="$BASE_DIR/prometheus"
  PGEXP_DIR="$BASE_DIR/postgres-exporter"
  GRAFANA_DS_DIR="$BASE_DIR/grafana/provisioning/datasources"
  GRAFANA_DASH_PROV_DIR="$BASE_DIR/grafana/provisioning/dashboards"
  GRAFANA_DASH_DIR="$BASE_DIR/grafana/dashboards"
  GRAFANA_DATA_DIR="$BASE_DIR/data/grafana"
  PROM_DATA_DIR="$BASE_DIR/data/prometheus"
}

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    die "Please run as root/sudo"
  fi
}

is_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]]
}

detect_os() {
  case "$(uname -s)" in
    Darwin) OS_FAMILY="darwin" ;;
    Linux) OS_FAMILY="linux" ;;
    *) OS_FAMILY="other" ;;
  esac
}

compose_cmd() {
  docker compose -f "$BASE_DIR/docker-compose.yaml" "$@"
}

cert_subject() {
  printf '/C=%s/ST=%s/L=%s/O=%s/OU=%s/CN=%s' \
    "$CERT_COUNTRY" "$CERT_STATE" "$CERT_LOCALITY" "$CERT_ORG" "$CERT_OU" "$CERT_CN"
}

resolve_firewall_backend() {
  detect_os

  if [[ "$ENABLE_FIREWALL" != "true" ]]; then
    echo "none"
    return
  fi

  if [[ "$FIREWALL_BACKEND" != "auto" ]]; then
    echo "$FIREWALL_BACKEND"
    return
  fi

  if [[ "$OS_FAMILY" != "linux" ]]; then
    echo "none"
    return
  fi

  if command -v firewall-cmd >/dev/null 2>&1; then
    echo "firewalld"
  elif command -v ufw >/dev/null 2>&1; then
    echo "ufw"
  else
    echo "none"
  fi
}

firewall_open_ports() {
  local backend
  backend="$(resolve_firewall_backend)"
  case "$backend" in
    firewalld)
      firewall-cmd --permanent --add-port="${NGINX_HTTPS_PORT}/tcp" >/dev/null || true
      firewall-cmd --permanent --add-port="${NGINX_HTTP_PORT}/tcp" >/dev/null || true
      firewall-cmd --reload >/dev/null || true
      ;;
    ufw)
      ufw allow "${NGINX_HTTPS_PORT}/tcp" >/dev/null || true
      ufw allow "${NGINX_HTTP_PORT}/tcp" >/dev/null || true
      ;;
    none)
      warn "Firewall automation skipped (backend=$backend)"
      ;;
    *)
      warn "Unknown firewall backend '$backend', skipping"
      ;;
  esac
}

firewall_close_ports() {
  local backend
  backend="$(resolve_firewall_backend)"
  case "$backend" in
    firewalld)
      firewall-cmd --permanent --remove-port="${NGINX_HTTPS_PORT}/tcp" >/dev/null || true
      firewall-cmd --permanent --remove-port="${NGINX_HTTP_PORT}/tcp" >/dev/null || true
      firewall-cmd --reload >/dev/null || true
      ;;
    ufw)
      ufw delete allow "${NGINX_HTTPS_PORT}/tcp" >/dev/null || true
      ufw delete allow "${NGINX_HTTP_PORT}/tcp" >/dev/null || true
      ;;
    none)
      :
      ;;
  esac
}
