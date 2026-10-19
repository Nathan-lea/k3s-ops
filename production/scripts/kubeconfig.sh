#!/usr/bin/env bash
# =============================================================================
# production/scripts/kubeconfig.sh —— 生成 production/kubeconfig（server 指向真实 IP）
# =============================================================================
# bootstrap.sh 拉取父角色 init.yml 里 fetch 下来的 kubeconfig 时，server 字段是
# 127.0.0.1（只在首个 server 节点内部可用）。这个脚本把它改成首个 server 的真实 IP，
# 写到 production/kubeconfig，方便控制机直接 kubectl。
#
# 幂等：每次都重新拉取并覆盖，可以放心反复执行。
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROD_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../lib/config.sh
. "${PROD_DIR}/lib/config.sh"
# shellcheck source=../lib/ipam.sh
. "${PROD_DIR}/lib/ipam.sh"

prod_require_cmd ssh
if ! ipam_validate; then
  log_error "ipam.yml 校验失败，中止 kubeconfig 获取"
  exit 1
fi

HOST="$(ipam_first_server_host)"
IP="$(ipam_first_server_ip)"
OUT="${PROD_DIR}/kubeconfig"
K3S_KUBECONFIG_REMOTE="/etc/rancher/k3s/k3s.yaml"

log_mark "获取 kubeconfig（来自 ${HOST} / ${IP}）"

_tmp="$(mktemp)"
trap 'rm -f "${_tmp}"' EXIT

# 用 ops 私钥 + 配置里的 SSH 端口拉 kubeconfig
if ! ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
     -o ConnectTimeout=15 -i "${OPS_SSH_KEY}" -p "${SSH_PORT}" \
     "${OPS_USER}@${IP}" "sudo cat ${K3S_KUBECONFIG_REMOTE}" > "${_tmp}" 2>/dev/null; then
  log_error "拉取 kubeconfig 失败：无法通过 ${OPS_USER}@${IP}:${SSH_PORT} 访问 ${K3S_KUBECONFIG_REMOTE}"
  log_error "检查：bootstrap.sh 是否已执行到 20-k3s-cluster 阶段；ops 密钥是否可用"
  exit 1
fi

# 校验确实是 kubeconfig，不是报错文本
if ! grep -q '^apiVersion:' "${_tmp}" || ! grep -q 'server:' "${_tmp}"; then
  log_error "拉取到的内容不是合法 kubeconfig（检查 sudo 权限或节点路径）"
  exit 1
fi

# server 字段：127.0.0.1:6443 → <首个 server IP>:6443
sed "s|server: https://127.0.0.1:6443|server: https://${IP}:6443|g" "${_tmp}" > "${OUT}"
chmod 600 "${OUT}"

log_info "kubeconfig 已写入: ${OUT}"
log_info "  用法: export KUBECONFIG=$(printf '%q' "${OUT}") && kubectl get nodes"
log_info "  server: https://${IP}:6443"
