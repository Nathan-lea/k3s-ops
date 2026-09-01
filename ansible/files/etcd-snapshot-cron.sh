#!/bin/bash
# etcd snapshot backup script
# 该脚本运行在 VM 节点上，日志记录到 VM 本地文件
# Usage: ./etcd-snapshot-cron.sh [retention_days]

set -euo pipefail

SNAPSHOT_DIR="${SNAPSHOT_DIR:-/var/lib/rancher/k3s/server/db/snapshots}"
RETENTION_DAYS="${1:-7}"
DATE_TAG=$(date +%Y%m%d-%H%M%S)
SNAPSHOT_NAME="etcd-snapshot-${DATE_TAG}"
LOG_FILE="${LOG_FILE:-/var/log/k3s-backup.log}"

log() {
  local level="$1"; shift
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[${ts}] [${level}] $*" >> "${LOG_FILE}"
}

log "INFO" "Starting etcd snapshot..."

k3s etcd-snapshot save \
  --snapshot-dir="${SNAPSHOT_DIR}" \
  --snapshot-name="${SNAPSHOT_NAME}" \
  2>&1 | while IFS= read -r line; do log "INFO" "${line}"; done

log "INFO" "Snapshot created: ${SNAPSHOT_NAME}"

# Cleanup old snapshots
find "${SNAPSHOT_DIR}" -name "etcd-snapshot-*" -mtime "+${RETENTION_DAYS}" -delete
log "INFO" "Cleaned up snapshots older than ${RETENTION_DAYS} days"
