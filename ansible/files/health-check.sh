#!/bin/bash
# k3s cluster health check
# 该脚本既可在 VM 节点上以 root 运行，也可在宿主机直接运行
# 日志路径：优先 LOG_FILE 环境变量 → 默认 /var/log/k3s-health.log（VM）→ 不可写时降级
set -euo pipefail

LOG_FILE="${LOG_FILE:-/var/log/k3s-health.log}"
if ! touch "${LOG_FILE}" 2>/dev/null; then
  # 非 root 且 /var/log 不可写（如宿主机直接执行）→ 降级到临时目录
  LOG_FILE="${TMPDIR:-/tmp}/k3s-health.log"
  touch "${LOG_FILE}" 2>/dev/null || LOG_FILE=""
fi

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

log() {
  local level="$1"; shift
  if [ -n "${LOG_FILE}" ]; then
    echo "[${TIMESTAMP}] [${level}] $*" >> "${LOG_FILE}"
  fi
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
