#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/common.sh"

load_env

FORCE="false"
if [[ "${1:-}" == "--force" ]]; then
  FORCE="true"
fi

should_write() {
  local path="$1"
  if [[ "$FORCE" == "true" ]]; then
    return 0
  fi
  [[ ! -f "$path" ]]
}

write_file() {
  local path="$1"
  if [[ -f "$path" && "$FORCE" != "true" ]]; then
    log "[SKIP] $path exists (use --force to overwrite)"
    return
  fi
  cat > "$path"
  log "[OK] wrote $path"
}

mkdir -p \
  "$NGINX_CONF_DIR" "$CERT_DIR" "$PROM_DIR" "$PGEXP_DIR" \
  "$GRAFANA_DS_DIR" "$GRAFANA_DASH_PROV_DIR" "$GRAFANA_DASH_DIR" \
  "$GRAFANA_DATA_DIR" "$PROM_DATA_DIR"

if [[ "$ENABLE_CHOWN" == "true" ]]; then
  chown -R 472:472 "$GRAFANA_DATA_DIR" || true
  chown -R 65534:65534 "$PROM_DATA_DIR" || true
fi

if should_write "$PROM_DIR/prometheus.yml"; then
  write_file "$PROM_DIR/prometheus.yml" <<EOF_PROM
global:
  scrape_interval: ${PROM_SCRAPE_INTERVAL}

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:${PROM_PORT}']

  - job_name: postgres_exporters
    static_configs:
      - targets:
EOF_PROM

  IFS=',' read -r -a exporter_targets <<< "$EXPORTER_TARGETS"
  for t in "${exporter_targets[@]}"; do
    printf "          - %s\n" "$t" >> "$PROM_DIR/prometheus.yml"
  done
else
  log "[SKIP] $PROM_DIR/prometheus.yml generation skipped"
fi

if [[ -n "$PROM_ADDITIONAL_SCRAPE_CONFIG" ]]; then
  [[ -f "$PROM_ADDITIONAL_SCRAPE_CONFIG" ]] || die "PROM_ADDITIONAL_SCRAPE_CONFIG file not found: $PROM_ADDITIONAL_SCRAPE_CONFIG"
  cat "$PROM_ADDITIONAL_SCRAPE_CONFIG" >> "$PROM_DIR/prometheus.yml"
  log "Appended additional Prometheus scrape config from: $PROM_ADDITIONAL_SCRAPE_CONFIG"
fi

write_file "$PGEXP_DIR/queries.yaml" <<'EOF_Q'
pg_stat_statements_top:
  query: |
    SELECT
      s.queryid::text AS queryid,
      d.datname::text AS datname,
      regexp_replace(left(s.query, 120), E'[\n\r\t]+', ' ', 'g')::text AS short_query,
      s.calls::double precision AS calls,
      s.total_exec_time::double precision AS total_exec_time_ms,
      s.mean_exec_time::double precision AS mean_exec_time_ms,
      s.rows::double precision AS rows_processed
    FROM pg_stat_statements s
    JOIN pg_database d ON d.oid = s.dbid
    ORDER BY s.total_exec_time DESC
    LIMIT 25;
  metrics:
    - queryid: {usage: "LABEL", description: "Query ID"}
    - datname: {usage: "LABEL", description: "Database"}
    - short_query: {usage: "LABEL", description: "Truncated SQL"}
    - calls: {usage: "GAUGE", description: "Calls"}
    - total_exec_time_ms: {usage: "GAUGE", description: "Total exec ms"}
    - mean_exec_time_ms: {usage: "GAUGE", description: "Mean exec ms"}
    - rows_processed: {usage: "GAUGE", description: "Rows"}
EOF_Q

write_file "$GRAFANA_DS_DIR/datasources.yml" <<EOF_DS
apiVersion: 1
prune: true
datasources:
  - name: ${GRAFANA_DS_NAME}
    uid: ${GRAFANA_DS_UID}
    type: prometheus
    access: proxy
    url: http://prometheus:${PROM_PORT}
    isDefault: true
    editable: true
EOF_DS

write_file "$GRAFANA_DASH_PROV_DIR/dashboards.yml" <<'EOF_DP'
apiVersion: 1
providers:
  - name: PostgreSQL
    orgId: 1
    folder: PostgreSQL
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards
EOF_DP

ALL_VAR='$__all'
INSTANCE_VAR='$instance'
DATNAME_VAR='$datname'
MODE_VAR='$mode'

write_file "$GRAFANA_DASH_DIR/postgresql-unified-insights.json" <<EOF_DASH
{
  "title": "PostgreSQL Unified Insights",
  "uid": "postgresql-unified-insights",
  "schemaVersion": 39,
  "version": 1,
  "refresh": "30s",
  "editable": true,
  "time": {"from": "now-6h", "to": "now"},
  "tags": ["postgresql", "prometheus", "unified"],
  "templating": {
    "list": [
      {
        "name": "instance",
        "type": "query",
        "label": "DB Instance",
        "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
        "query": "label_values(pg_up, instance)",
        "refresh": 1,
        "includeAll": true,
        "multi": false,
        "current": {"text": "All", "value": "${ALL_VAR}"}
      },
      {
        "name": "datname",
        "type": "query",
        "label": "Database",
        "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
        "query": "label_values(pg_stat_database_xact_commit{instance=~\"${INSTANCE_VAR}\"}, datname)",
        "refresh": 1,
        "includeAll": true,
        "multi": false,
        "current": {"text": "All", "value": "${ALL_VAR}"}
      },
      {
        "name": "mode",
        "type": "query",
        "label": "Lock Mode",
        "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
        "query": "label_values(pg_locks_count{instance=~\"${INSTANCE_VAR}\"}, mode)",
        "refresh": 1,
        "includeAll": true,
        "multi": true,
        "current": {"text": "All", "value": "${ALL_VAR}"}
      }
    ]
  },
  "panels": [
    {
      "type": "row",
      "title": "PostgreSQL Core (Prometheus)",
      "gridPos": {"h": 1, "w": 24, "x": 0, "y": 0},
      "collapsed": false
    },
    {
      "type": "stat",
      "title": "Postgres Up",
      "gridPos": {"h": 4, "w": 3, "x": 0, "y": 1},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [{"refId": "A", "expr": "max(pg_up{instance=~\"${INSTANCE_VAR}\"})"}],
      "options": {"reduceOptions": {"calcs": ["lastNotNull"]}}
    },
    {
      "type": "stat",
      "title": "Uptime (days)",
      "gridPos": {"h": 4, "w": 3, "x": 3, "y": 1},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [{"refId": "A", "expr": "(time() - max(pg_postmaster_start_time_seconds{instance=~\"${INSTANCE_VAR}\"})) / 86400"}],
      "options": {"reduceOptions": {"calcs": ["lastNotNull"]}}
    },
    {
      "type": "stat",
      "title": "Max Connections",
      "gridPos": {"h": 4, "w": 3, "x": 6, "y": 1},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [{"refId": "A", "expr": "sum(pg_settings_max_connections{instance=~\"${INSTANCE_VAR}\"})"}],
      "options": {"reduceOptions": {"calcs": ["lastNotNull"]}}
    },
    {
      "type": "stat",
      "title": "Connection Utilization %",
      "gridPos": {"h": 4, "w": 3, "x": 9, "y": 1},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [{"refId": "A", "expr": "100 * sum(pg_stat_activity_count{instance=~\"${INSTANCE_VAR}\",datname=~\"${DATNAME_VAR}\"}) / clamp_min(sum(pg_settings_max_connections{instance=~\"${INSTANCE_VAR}\"}), 1)"}],
      "options": {"reduceOptions": {"calcs": ["lastNotNull"]}}
    },
    {
      "type": "stat",
      "title": "Active Sessions",
      "gridPos": {"h": 4, "w": 3, "x": 12, "y": 1},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [{"refId": "A", "expr": "sum(pg_stat_activity_count{instance=~\"${INSTANCE_VAR}\",datname=~\"${DATNAME_VAR}\",state=\"active\"})"}],
      "options": {"reduceOptions": {"calcs": ["lastNotNull"]}}
    },
    {
      "type": "stat",
      "title": "Idle Sessions",
      "gridPos": {"h": 4, "w": 3, "x": 15, "y": 1},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [{"refId": "A", "expr": "sum(pg_stat_activity_count{instance=~\"${INSTANCE_VAR}\",datname=~\"${DATNAME_VAR}\",state=~\"idle|idle in transaction|idle in transaction .*aborted.*\"})"}],
      "options": {"reduceOptions": {"calcs": ["lastNotNull"]}}
    },
    {
      "type": "stat",
      "title": "Cache Hit %",
      "gridPos": {"h": 4, "w": 3, "x": 18, "y": 1},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [{"refId": "A", "expr": "100 * sum(pg_stat_database_blks_hit{instance=~\"${INSTANCE_VAR}\",datname=~\"${DATNAME_VAR}\"}) / clamp_min(sum(pg_stat_database_blks_hit{instance=~\"${INSTANCE_VAR}\",datname=~\"${DATNAME_VAR}\"}) + sum(pg_stat_database_blks_read{instance=~\"${INSTANCE_VAR}\",datname=~\"${DATNAME_VAR}\"}), 1)"}],
      "options": {"reduceOptions": {"calcs": ["lastNotNull"]}}
    },
    {
      "type": "stat",
      "title": "Deadlocks / s",
      "gridPos": {"h": 4, "w": 3, "x": 21, "y": 1},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [{"refId": "A", "expr": "sum(rate(pg_stat_database_deadlocks{instance=~\"${INSTANCE_VAR}\",datname=~\"${DATNAME_VAR}\"}[5m]))"}],
      "options": {"reduceOptions": {"calcs": ["lastNotNull"]}}
    },
    {
      "type": "row",
      "title": "Workload & Sessions",
      "gridPos": {"h": 1, "w": 24, "x": 0, "y": 5},
      "collapsed": false
    },
    {
      "type": "timeseries",
      "title": "Transactions/s (Commit + Rollback)",
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 6},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [
        {"refId": "A", "expr": "sum(rate(pg_stat_database_xact_commit{instance=~\"${INSTANCE_VAR}\",datname=~\"${DATNAME_VAR}\"}[5m]))", "legendFormat": "commit"},
        {"refId": "B", "expr": "sum(rate(pg_stat_database_xact_rollback{instance=~\"${INSTANCE_VAR}\",datname=~\"${DATNAME_VAR}\"}[5m]))", "legendFormat": "rollback"}
      ]
    },
    {
      "type": "timeseries",
      "title": "Session States",
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 6},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [
        {"refId": "A", "expr": "sum(pg_stat_activity_count{instance=~\"${INSTANCE_VAR}\",datname=~\"${DATNAME_VAR}\",state=\"active\"})", "legendFormat": "active"},
        {"refId": "B", "expr": "sum(pg_stat_activity_count{instance=~\"${INSTANCE_VAR}\",datname=~\"${DATNAME_VAR}\",state=~\"idle|idle in transaction|idle in transaction .*aborted.*\"})", "legendFormat": "idle"}
      ]
    },
    {
      "type": "timeseries",
      "title": "Tuple Operations / s",
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 14},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [
        {"refId": "A", "expr": "sum(rate(pg_stat_database_tup_returned{instance=~\"${INSTANCE_VAR}\",datname=~\"${DATNAME_VAR}\"}[5m]))", "legendFormat": "returned"},
        {"refId": "B", "expr": "sum(rate(pg_stat_database_tup_fetched{instance=~\"${INSTANCE_VAR}\",datname=~\"${DATNAME_VAR}\"}[5m]))", "legendFormat": "fetched"},
        {"refId": "C", "expr": "sum(rate(pg_stat_database_tup_inserted{instance=~\"${INSTANCE_VAR}\",datname=~\"${DATNAME_VAR}\"}[5m]))", "legendFormat": "inserted"},
        {"refId": "D", "expr": "sum(rate(pg_stat_database_tup_updated{instance=~\"${INSTANCE_VAR}\",datname=~\"${DATNAME_VAR}\"}[5m]))", "legendFormat": "updated"},
        {"refId": "E", "expr": "sum(rate(pg_stat_database_tup_deleted{instance=~\"${INSTANCE_VAR}\",datname=~\"${DATNAME_VAR}\"}[5m]))", "legendFormat": "deleted"}
      ]
    },
    {
      "type": "timeseries",
      "title": "Read vs Write Tuple Throughput / s",
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 14},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [
        {"refId": "A", "expr": "sum(rate(pg_stat_database_tup_returned{instance=~\"${INSTANCE_VAR}\",datname=~\"${DATNAME_VAR}\"}[5m])) + sum(rate(pg_stat_database_tup_fetched{instance=~\"${INSTANCE_VAR}\",datname=~\"${DATNAME_VAR}\"}[5m]))", "legendFormat": "read tuple ops/s"},
        {"refId": "B", "expr": "sum(rate(pg_stat_database_tup_inserted{instance=~\"${INSTANCE_VAR}\",datname=~\"${DATNAME_VAR}\"}[5m])) + sum(rate(pg_stat_database_tup_updated{instance=~\"${INSTANCE_VAR}\",datname=~\"${DATNAME_VAR}\"}[5m])) + sum(rate(pg_stat_database_tup_deleted{instance=~\"${INSTANCE_VAR}\",datname=~\"${DATNAME_VAR}\"}[5m]))", "legendFormat": "write tuple ops/s"}
      ]
    },
    {
      "type": "row",
      "title": "Storage, WAL & Checkpoints",
      "gridPos": {"h": 1, "w": 24, "x": 0, "y": 22},
      "collapsed": false
    },
    {
      "type": "timeseries",
      "title": "Database Size (GiB)",
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 23},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [
        {"refId": "A", "expr": "sum(pg_database_size_bytes{instance=~\"${INSTANCE_VAR}\",datname=~\"${DATNAME_VAR}\"}) / 1073741824", "legendFormat": "db size GiB"}
      ]
    },
    {
      "type": "timeseries",
      "title": "Temp File (MiB/s)",
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 23},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [
        {"refId": "A", "expr": "sum(rate(pg_stat_database_temp_bytes{instance=~\"${INSTANCE_VAR}\",datname=~\"${DATNAME_VAR}\"}[5m])) / 1048576", "legendFormat": "temp MiB/s"}
      ]
    },
    {
      "type": "timeseries",
      "title": "Checkpoint Write vs Sync Time / s",
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 31},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [
        {"refId": "A", "expr": "sum(rate(pg_stat_bgwriter_checkpoint_write_time_total{instance=~\"${INSTANCE_VAR}\"}[5m]))", "legendFormat": "checkpoint write time/s"},
        {"refId": "B", "expr": "sum(rate(pg_stat_bgwriter_checkpoint_sync_time_total{instance=~\"${INSTANCE_VAR}\"}[5m]))", "legendFormat": "checkpoint sync time/s"}
      ]
    },
    {
      "type": "timeseries",
      "title": "BGWriter Buffers / s",
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 31},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [
        {"refId": "A", "expr": "sum(rate(pg_stat_bgwriter_buffers_backend_total{instance=~\"${INSTANCE_VAR}\"}[5m])) or sum(rate(pg_stat_bgwriter_buffers_backend_fsync_total{instance=~\"${INSTANCE_VAR}\"}[5m]))", "legendFormat": "backend"},
        {"refId": "B", "expr": "sum(rate(pg_stat_bgwriter_buffers_alloc_total{instance=~\"${INSTANCE_VAR}\"}[5m]))", "legendFormat": "alloc"},
        {"refId": "C", "expr": "sum(rate(pg_stat_bgwriter_buffers_checkpoint_total{instance=~\"${INSTANCE_VAR}\"}[5m]))", "legendFormat": "checkpoint"},
        {"refId": "D", "expr": "sum(rate(pg_stat_bgwriter_buffers_clean_total{instance=~\"${INSTANCE_VAR}\"}[5m]))", "legendFormat": "clean"}
      ]
    },
    {
      "type": "row",
      "title": "Locks, Replication & Process Health",
      "gridPos": {"h": 1, "w": 24, "x": 0, "y": 39},
      "collapsed": false
    },
    {
      "type": "timeseries",
      "title": "Locks by Mode",
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 40},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [
        {"refId": "A", "expr": "sum by (mode) (pg_locks_count{instance=~\"${INSTANCE_VAR}\",datname=~\"${DATNAME_VAR}\",mode=~\"${MODE_VAR}\"})", "legendFormat": "{{mode}}"}
      ]
    },
    {
      "type": "timeseries",
      "title": "Conflicts / Deadlocks / s",
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 40},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [
        {"refId": "A", "expr": "sum(rate(pg_stat_database_conflicts{instance=~\"${INSTANCE_VAR}\",datname=~\"${DATNAME_VAR}\"}[5m]))", "legendFormat": "conflicts/s"},
        {"refId": "B", "expr": "sum(rate(pg_stat_database_deadlocks{instance=~\"${INSTANCE_VAR}\",datname=~\"${DATNAME_VAR}\"}[5m]))", "legendFormat": "deadlocks/s"}
      ]
    },
    {
      "type": "timeseries",
      "title": "Replication Replay Lag (seconds)",
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 48},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [
        {"refId": "A", "expr": "max(pg_replication_delay_replay_lag_seconds{instance=~\"${INSTANCE_VAR}\"})", "legendFormat": "replay lag"}
      ]
    },
    {
      "type": "timeseries",
      "title": "Exporter Process (CPU + Open FDs)",
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 48},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [
        {"refId": "A", "expr": "avg(rate(process_cpu_seconds_total{instance=~\"${INSTANCE_VAR}\"}[5m]))", "legendFormat": "cpu seconds/s"},
        {"refId": "B", "expr": "avg(process_open_fds{instance=~\"${INSTANCE_VAR}\"})", "legendFormat": "open fds"}
      ]
    },
    {
      "type": "row",
      "title": "PostgreSQL Configuration Snapshot",
      "gridPos": {"h": 1, "w": 24, "x": 0, "y": 56},
      "collapsed": false
    },
    {
      "type": "stat",
      "title": "Shared Buffers (GiB)",
      "gridPos": {"h": 4, "w": 4, "x": 0, "y": 57},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [{"refId": "A", "expr": "avg(pg_settings_shared_buffers_bytes{instance=~\"${INSTANCE_VAR}\"}) / 1073741824"}],
      "options": {"reduceOptions": {"calcs": ["lastNotNull"]}}
    },
    {
      "type": "stat",
      "title": "Effective Cache Size (GiB)",
      "gridPos": {"h": 4, "w": 4, "x": 4, "y": 57},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [{"refId": "A", "expr": "avg(pg_settings_effective_cache_size_bytes{instance=~\"${INSTANCE_VAR}\"}) / 1073741824"}],
      "options": {"reduceOptions": {"calcs": ["lastNotNull"]}}
    },
    {
      "type": "stat",
      "title": "Work Mem (MiB)",
      "gridPos": {"h": 4, "w": 4, "x": 8, "y": 57},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [{"refId": "A", "expr": "avg(pg_settings_work_mem_bytes{instance=~\"${INSTANCE_VAR}\"}) / 1048576"}],
      "options": {"reduceOptions": {"calcs": ["lastNotNull"]}}
    },
    {
      "type": "stat",
      "title": "Maintenance Work Mem (MiB)",
      "gridPos": {"h": 4, "w": 4, "x": 12, "y": 57},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [{"refId": "A", "expr": "avg(pg_settings_maintenance_work_mem_bytes{instance=~\"${INSTANCE_VAR}\"}) / 1048576"}],
      "options": {"reduceOptions": {"calcs": ["lastNotNull"]}}
    },
    {
      "type": "stat",
      "title": "Max WAL Size (GiB)",
      "gridPos": {"h": 4, "w": 4, "x": 16, "y": 57},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [{"refId": "A", "expr": "avg(pg_settings_max_wal_size_bytes{instance=~\"${INSTANCE_VAR}\"}) / 1073741824"}],
      "options": {"reduceOptions": {"calcs": ["lastNotNull"]}}
    },
    {
      "type": "stat",
      "title": "Max Worker Processes",
      "gridPos": {"h": 4, "w": 4, "x": 20, "y": 57},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [{"refId": "A", "expr": "avg(pg_settings_max_worker_processes{instance=~\"${INSTANCE_VAR}\"})"}],
      "options": {"reduceOptions": {"calcs": ["lastNotNull"]}}
    },
    {
      "type": "stat",
      "title": "Max Parallel Workers",
      "gridPos": {"h": 4, "w": 4, "x": 0, "y": 61},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [{"refId": "A", "expr": "avg(pg_settings_max_parallel_workers{instance=~\"${INSTANCE_VAR}\"})"}],
      "options": {"reduceOptions": {"calcs": ["lastNotNull"]}}
    },
    {
      "type": "stat",
      "title": "Random Page Cost",
      "gridPos": {"h": 4, "w": 4, "x": 4, "y": 61},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [{"refId": "A", "expr": "avg(pg_settings_random_page_cost{instance=~\"${INSTANCE_VAR}\"})"}],
      "options": {"reduceOptions": {"calcs": ["lastNotNull"]}}
    },
    {
      "type": "stat",
      "title": "Seq Page Cost",
      "gridPos": {"h": 4, "w": 4, "x": 8, "y": 61},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [{"refId": "A", "expr": "avg(pg_settings_seq_page_cost{instance=~\"${INSTANCE_VAR}\"})"}],
      "options": {"reduceOptions": {"calcs": ["lastNotNull"]}}
    },
    {
      "type": "stat",
      "title": "Postmaster Start Time",
      "gridPos": {"h": 4, "w": 4, "x": 12, "y": 61},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [{"refId": "A", "expr": "max(pg_postmaster_start_time_seconds{instance=~\"${INSTANCE_VAR}\"} * 1000)"}],
      "options": {"reduceOptions": {"calcs": ["lastNotNull"]}}
    },
    {
      "type": "table",
      "title": "PostgreSQL Version (pg_static labels)",
      "gridPos": {"h": 8, "w": 8, "x": 16, "y": 61},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [
        {"refId": "A", "expr": "pg_static{instance=~\"${INSTANCE_VAR}\"}", "instant": true, "format": "table"}
      ]
    },
    {
      "type": "row",
      "title": "SQL Performance",
      "gridPos": {"h": 1, "w": 24, "x": 0, "y": 69},
      "collapsed": false
    },
    {
      "type": "stat",
      "title": "SQL Avg Latency (ms)",
      "gridPos": {"h": 4, "w": 6, "x": 0, "y": 70},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [
        {"refId": "A", "expr": "(sum(pg_stat_statements_top_total_exec_time_ms{instance=~\"${INSTANCE_VAR}\",datname=~\"${DATNAME_VAR}\"}) or sum(top_sql_performance_total_time{instance=~\"${INSTANCE_VAR}\"})) / clamp_min((sum(pg_stat_statements_top_calls{instance=~\"${INSTANCE_VAR}\",datname=~\"${DATNAME_VAR}\"}) or sum(top_sql_performance_calls{instance=~\"${INSTANCE_VAR}\"})), 1)"}
      ],
      "options": {"reduceOptions": {"calcs": ["lastNotNull"]}}
    },
    {
      "type": "timeseries",
      "title": "Top SQL Calls",
      "gridPos": {"h": 4, "w": 18, "x": 6, "y": 70},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [
        {"refId": "A", "expr": "topk(10, sum by (short_query) (pg_stat_statements_top_calls{instance=~\"${INSTANCE_VAR}\",datname=~\"${DATNAME_VAR}\"}) or sum by (query) (top_sql_statements_calls{instance=~\"${INSTANCE_VAR}\"}) or sum by (query) (top_sql_performance_calls{instance=~\"${INSTANCE_VAR}\"}))", "legendFormat": "{{short_query}}{{query}}"}
      ]
    },
    {
      "type": "timeseries",
      "title": "Top SQL Total Exec Time (ms)",
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 74},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [
        {"refId": "A", "expr": "topk(10, sum by (short_query) (pg_stat_statements_top_total_exec_time_ms{instance=~\"${INSTANCE_VAR}\",datname=~\"${DATNAME_VAR}\"}) or sum by (query) (top_sql_performance_total_time{instance=~\"${INSTANCE_VAR}\"}))", "legendFormat": "{{short_query}}{{query}}"}
      ]
    },
    {
      "type": "timeseries",
      "title": "Top SQL Mean Exec Time (ms)",
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 74},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [
        {"refId": "A", "expr": "topk(10, avg by (short_query) (pg_stat_statements_top_mean_exec_time_ms{instance=~\"${INSTANCE_VAR}\",datname=~\"${DATNAME_VAR}\"}) or avg by (query) (top_sql_statements_mean_time{instance=~\"${INSTANCE_VAR}\"}))", "legendFormat": "{{short_query}}{{query}}"}
      ]
    },
    {
      "type": "timeseries",
      "title": "Top SQL Rows Processed",
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 82},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [
        {"refId": "A", "expr": "topk(10, sum by (short_query) (pg_stat_statements_top_rows_processed{instance=~\"${INSTANCE_VAR}\",datname=~\"${DATNAME_VAR}\"}))", "legendFormat": "{{short_query}}"}
      ]
    },
    {
      "type": "timeseries",
      "title": "Top SQL Calls (TopK)",
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 82},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [
        {"refId": "A", "expr": "topk(10, sum by (short_query) (pg_stat_statements_top_calls{instance=~\"${INSTANCE_VAR}\",datname=~\"${DATNAME_VAR}\"}))", "legendFormat": "{{short_query}}"}
      ]
    },
    {
      "type": "row",
      "title": "Table Bloat (Optional Metrics)",
      "gridPos": {"h": 1, "w": 24, "x": 0, "y": 90},
      "collapsed": false
    },
    {
      "type": "timeseries",
      "title": "Table Bloat (%)",
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 91},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [
        {"refId": "A", "expr": "topk(10, table_bloat_bloat_size_percent{instance=~\"${INSTANCE_VAR}\"})", "legendFormat": "{{schema}}.{{table}}"}
      ]
    },
    {
      "type": "timeseries",
      "title": "Table Bloat Size (KB)",
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 91},
      "datasource": {"type": "prometheus", "uid": "${GRAFANA_DS_UID}"},
      "targets": [
        {"refId": "A", "expr": "topk(10, table_bloat_bloat_size_kb{instance=~\"${INSTANCE_VAR}\"})", "legendFormat": "{{schema}}.{{table}}"}
      ]
    }
  ]
}
EOF_DASH

write_file "$NGINX_CONF_DIR/default.conf" <<EOF_NGX
server {
  listen ${NGINX_HTTP_PORT};
  server_name _;
  return 301 https://\$host:${NGINX_HTTPS_PORT}\$request_uri;
}

server {
  listen ${NGINX_HTTPS_PORT} ssl http2;
  server_name _;

  ssl_certificate     /etc/nginx/certs/grafana.crt;
  ssl_certificate_key /etc/nginx/certs/grafana.key;
  ssl_protocols TLSv1.2 TLSv1.3;

  add_header X-Frame-Options SAMEORIGIN always;
  add_header X-Content-Type-Options nosniff always;
  add_header Referrer-Policy strict-origin-when-cross-origin always;

  location / {
    proxy_pass http://grafana:${GRAFANA_INTERNAL_PORT};
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
  }
}
EOF_NGX

if should_write "$BASE_DIR/docker-compose.yaml"; then
  write_file "$BASE_DIR/docker-compose.yaml" <<EOF_DC
services:
  nginx:
    image: ${NGINX_IMAGE}
    container_name: ${NGINX_CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "${NGINX_BIND_ADDRESS}:${NGINX_HTTPS_PORT}:${NGINX_HTTPS_PORT}"
      - "${NGINX_BIND_ADDRESS}:${NGINX_HTTP_PORT}:${NGINX_HTTP_PORT}"
    volumes:
      - ${NGINX_CONF_DIR}/default.conf:/etc/nginx/conf.d/default.conf:ro
      - ${CERT_DIR}:/etc/nginx/certs:ro
    depends_on:
      - grafana
    networks: [monitoring]

  grafana:
    image: ${GRAFANA_IMAGE}
    container_name: ${GRAFANA_CONTAINER_NAME}
    restart: unless-stopped
    environment:
      GF_SECURITY_ADMIN_USER: ${GRAFANA_ADMIN_USER}
      GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_ADMIN_PASSWORD}
      GF_USERS_ALLOW_SIGN_UP: "${GRAFANA_ALLOW_SIGNUP}"
      GF_SECURITY_COOKIE_SECURE: "${GRAFANA_COOKIE_SECURE}"
      GF_SECURITY_COOKIE_SAMESITE: ${GRAFANA_COOKIE_SAMESITE}
      GF_INSTALL_PLUGINS: "${GRAFANA_INSTALL_PLUGINS}"
    volumes:
      - ${GRAFANA_DATA_DIR}:/var/lib/grafana
      - ${BASE_DIR}/grafana/provisioning:/etc/grafana/provisioning:ro
      - ${GRAFANA_DASH_DIR}:/var/lib/grafana/dashboards:ro
    networks: [monitoring]

  prometheus:
    image: ${PROM_IMAGE}
    container_name: ${PROM_CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "${PROM_BIND_ADDRESS}:${PROM_PORT}:${PROM_PORT}"
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --web.enable-lifecycle
      - --web.listen-address=:${PROM_PORT}
    volumes:
      - ${PROM_DIR}/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ${PROM_DATA_DIR}:/prometheus
    networks: [monitoring]

EOF_DC

  for i in $(seq 1 "$EXPORTER_COUNT"); do
    name_var="EXPORTER_${i}_NAME"
    dsn_var="EXPORTER_${i}_DSN"
    name="${!name_var:-}"
    dsn="${!dsn_var:-}"
    if [[ -z "$name" || -z "$dsn" ]]; then
      warn "Skipping exporter index $i (missing ${name_var} or ${dsn_var})"
      continue
    fi
    cat >> "$BASE_DIR/docker-compose.yaml" <<EOF_EXP

  ${name}:
    image: ${PG_EXPORTER_IMAGE}
    container_name: ${name}
    restart: unless-stopped
    environment:
      DATA_SOURCE_NAME: ${dsn}
    command:
      - --extend.query-path=/etc/postgres_exporter/queries.yaml
    volumes:
      - ${PGEXP_DIR}/queries.yaml:/etc/postgres_exporter/queries.yaml:ro
    networks: [monitoring]
EOF_EXP
  done

  cat >> "$BASE_DIR/docker-compose.yaml" <<'EOF_END'

networks:
  monitoring:
    name: monitoring
    driver: bridge
EOF_END
else
  log "[SKIP] $BASE_DIR/docker-compose.yaml generation skipped"
fi

log "All stack config files generated under $BASE_DIR"
