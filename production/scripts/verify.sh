#!/usr/bin/env bash
# =============================================================================
# production/scripts/verify.sh —— 部署后自检（只读，不改任何东西）
# =============================================================================
# 干的事:
#   1. 从 production/kubeconfig（或 KUBECONFIG）拉节点/组件状态
#   2. 检查关键组件是否 Ready（k3s 控制面、ingress、cert-manager、Rancher、StorageClass）
#   3. 检查 80/443 是否被 ingress 占用
#   4. 打印访问入口（Rancher URL、kubeconfig 路径）
#
# 什么时候用: bootstrap.sh 跑完后；或者日常想确认集群健康。
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROD_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../lib/config.sh
. "${PROD_DIR}/lib/config.sh"
# shellcheck source=../lib/ipam.sh
. "${PROD_DIR}/lib/ipam.sh"

prod_require_cmd kubectl
if ! ipam_validate; then
  log_error "ipam.yml 校验失败，中止自检"
  exit 1
fi

KUBECONFIG="${KUBECONFIG:-${PROD_DIR}/kubeconfig}"
export KUBECONFIG

HOST="$(ipam_first_server_host)"
IP="$(ipam_first_server_ip)"

log_mark "集群自检"
log_info "KUBECONFIG: ${KUBECONFIG}"

# -----------------------------------------------------------------------------
# 1. 节点
# -----------------------------------------------------------------------------
log_mark "节点状态"
if ! kubectl get nodes -o wide; then
  log_error "无法连接集群（检查 ${KUBECONFIG} 与 VPN/网络）"
  exit 1
fi

# -----------------------------------------------------------------------------
# 2. 组件
# -----------------------------------------------------------------------------
check_deploy() { # $1=ns  $2=deploy 名  $3=显示名
  local ready
  ready="$(kubectl -n "$1" get deploy "$2" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  if [ "${ready:-0}" -ge 1 ] 2>/dev/null; then
    log_info "  ✅ $3: ${ready} 副本就绪"
  else
    log_warn "  ⚠️ $3: 未就绪（namespace=$1, deploy=$2）"
  fi
}

log_mark "关键组件"
# ingress
check_deploy ingress-nginx ingress-nginx-controller "ingress-nginx"
# cert-manager
check_deploy cert-manager cert-manager "cert-manager"
check_deploy cert-manager cert-manager-webhook "cert-manager-webhook"
check_deploy cert-manager cert-manager-cainjector "cert-manager-cainjector"
# localdisk provisioner
if prod_bool "${LOCALDISK_ENABLED}"; then
  check_deploy local-path-storage local-path-provisioner "localdisk provisioner"
fi
# rancher
if prod_bool "${RANCHER_ENABLED}"; then
  check_deploy cattle-system rancher "Rancher"
fi

# -----------------------------------------------------------------------------
# 3. StorageClass
# -----------------------------------------------------------------------------
log_mark "StorageClass"
kubectl get storageclass

# -----------------------------------------------------------------------------
# 4. 端口
# -----------------------------------------------------------------------------
log_mark "ingress 端口（80/443）"
if ss -tln 2>/dev/null | grep -qE ':(80|443)\b'; then
  log_info "  ✅ 80/443 已监听"
else
  log_warn "  ⚠️ 80/443 未监听（检查 ingress-nginx controller pod）"
fi

# -----------------------------------------------------------------------------
# 5. 入口
# -----------------------------------------------------------------------------
log_mark "访问入口"
if prod_bool "${RANCHER_ENABLED}"; then
  log_info "Rancher: https://${RANCHER_HOSTNAME}/（Host 头需为 ${RANCHER_HOSTNAME}，任意节点 IP 皆可访问）"
fi
log_info "kubeconfig: ${KUBECONFIG}"
log_info "  export KUBECONFIG=${KUBECONFIG} && kubectl get nodes"

log_mark "自检完成"
