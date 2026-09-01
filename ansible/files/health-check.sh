#!/bin/bash
# k3s cluster health check
# 该脚本运行在 VM 节点上，日志记录到 VM 本地文件
set -euo pipefail

LOG_FILE="${LOG_FILE:-/var/log/k3s-healthcheck.log}"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

log() {
  local level="$1"; shift
  echo "[${TIMESTAMP}] [${level}] $*" >> "${LOG_FILE}"
  echo "[${level}] $*"
}

log "INFO" "=== Cluster Health Check ==="

log "INFO" "--- Node Status ---"
kubectl get nodes -o wide 2>/dev/null || log "ERROR" "Cannot reach cluster"

log "INFO" "--- System Pods ---"
kubectl get pods -n kube-system -o wide 2>/dev/null || log "ERROR" "Cannot get system pods"

log "INFO" "--- Node Conditions ---"
for node in $(kubectl get nodes -o name 2>/dev/null); do
  log "INFO" "Node: ${node}"
  kubectl describe "$node" | grep -A5 "Conditions:" 2>/dev/null || true
done

log "INFO" "--- etcd Status ---"
k3s etcd-snapshot list 2>/dev/null || log "WARN" "Cannot list etcd snapshots"

log "INFO" "--- Disk Usage ---"
df -h /var/lib/rancher/k3s/ 2>/dev/null || log "WARN" "Cannot check disk usage"

log "INFO" "--- k3s Service Status ---"
for svc in k3s k3s-agent; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    log "INFO" "${svc}: running"
  fi
done

log "INFO" "=== Health Check Complete ==="
