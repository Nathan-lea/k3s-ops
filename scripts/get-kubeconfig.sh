#!/bin/bash
# Get kubeconfig from the first server node
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${SELF_DIR}/lib/logging.sh"
source "${SELF_DIR}/lib/nodes.sh"
log_init

# 第一个参数为节点名（短名或完整主机名都接受），第二个为输出路径
NODE="${1:-server-1}"
KUBECONFIG_DEST="${2:-./kubeconfig}"

resolve_host "${NODE}"
SERVER_HOST="${RESOLVED_HOST}"

log_info "Fetching kubeconfig from ${SERVER_HOST}..."
# 注意：这里不能用 log_cmd 包裹 —— 它的进度输出会随 stdout 重定向
# 一起写进 kubeconfig 文件，导致 YAML 损坏。
if ! vagrant ssh "${SERVER_HOST}" -- sudo cat /etc/rancher/k3s/k3s.yaml > "${KUBECONFIG_DEST}"; then
  log_error "Failed to get kubeconfig from ${SERVER_HOST}"
  exit 1
fi

# 校验拉到的确实是 kubeconfig（权限/命令出错时会拿到空文件或报错文本）
if ! grep -q '^apiVersion:' "${KUBECONFIG_DEST}" || ! grep -q 'server:' "${KUBECONFIG_DEST}"; then
  log_error "Fetched content is not a valid kubeconfig: ${KUBECONFIG_DEST}"
  exit 1
fi

log_info "Kubeconfig saved to ${KUBECONFIG_DEST}"

# Replace localhost with server IP
SERVER_IP=$(vagrant ssh "${SERVER_HOST}" -- ip addr show eth1 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
if [ -n "$SERVER_IP" ]; then
  sed -i "s/127.0.0.1/${SERVER_IP}/g" "$KUBECONFIG_DEST"
  log_info "Server address updated to ${SERVER_IP}"
fi
