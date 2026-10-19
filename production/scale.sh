#!/usr/bin/env bash
# =============================================================================
# production/scale.sh —— 集群扩缩容与日常运维
# =============================================================================
# 用法:
#   ./production/scale.sh status                 # 查看当前集群与 ipam.yml 的差异
#   ./production/scale.sh apply                  # 扩容：把 ipam.yml 里新增的节点拉进集群
#   ./production/scale.sh remove xxx-k8s-03      # 缩容：摘除节点（不自动删 ipam 条目）
#   ./production/scale.sh upgrade --version vX.Y.Z+k3sN [--serial 1]
#   ./production/scale.sh backup                 # 在第一个 server 上做 etcd snapshot
#
# 设计:
#   - ipam.yml 是唯一事实源。扩容 = 往 ipam.yml 里加条目，然后 apply。
#   - 缩容不会自动改 ipam.yml（保留人工审核），只做集群侧操作，完成后提示你删条目。
#   - 所有操作幂等。
# =============================================================================
set -euo pipefail

PROD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROD_DIR="${PROD_SCRIPT_DIR}"

# shellcheck source=lib/config.sh
. "${PROD_DIR}/lib/config.sh"
# shellcheck source=lib/ipam.sh
. "${PROD_DIR}/lib/ipam.sh"
# shellcheck source=lib/inventory.sh
. "${PROD_DIR}/lib/inventory.sh"

usage() {
  cat <<'EOF'
用法: production/scale.sh <命令> [参数]

命令:
  status                            查看集群与 ipam.yml 的差异
  apply                             扩容：把 ipam.yml 里新增节点拉进集群
  remove <hostname>                 缩容：摘除节点（先做 etcd member 清理）
  upgrade --version <ver> [--serial N]
                                    升级 k3s 二进制并重启（逐节点，保证可用性）
  backup                            在第一个 server 上创建 etcd snapshot

示例:
  ./production/scale.sh apply
  ./production/scale.sh remove xxx-k8s-03
  ./production/scale.sh upgrade --version v1.31.4+k3s1 --serial 1
EOF
}

# -----------------------------------------------------------------------------
# 通用函数
# -----------------------------------------------------------------------------
load_all() {
  if ! prod_validate_config; then
    log_error "配置校验失败"
    exit 1
  fi
  if ! ipam_validate; then
    log_error "IPAM 校验失败"
    exit 1
  fi
}

inventory_generate_quiet() {
  inventory_generate >/dev/null 2>&1
}

run_script() { # $1 = production/ 下的脚本路径
  local s="${PROD_DIR}/$1"
  [ -f "${s}" ] || { log_error "找不到脚本: ${s}"; exit 1; }
  log_mark "执行: $1"
  bash "${s}" | tee -a "${LOG_FILE}"
  local rc="${PIPESTATUS[0]}"
  if [ "${rc}" -ne 0 ]; then
    log_error "$1 失败（rc=${rc}），日志: ${LOG_FILE}"
    exit "${rc}"
  fi
}

run_playbook() { # $1 = playbook（playbooks/ 下的文件名或绝对路径）；其余参数原样透传给 ansible-playbook
  local ref="$1"
  shift
  local pb="${ref}"
  case "${ref}" in
    /*) ;;
    *) pb="${PLAYBOOK_DIR}/${ref}" ;;
  esac
  [ -f "${pb}" ] || { log_error "找不到 playbook: ${pb}"; exit 1; }
  local -a cmd=(ansible-playbook "${pb}"
    -i "${INVENTORY_HOSTS_FILE}"
    -e "@${INVENTORY_EXTRA_VARS_FILE}"
    "$@")
  log_mark "执行: ${pb} $*"
  "${cmd[@]}" | tee -a "${LOG_FILE}"
  local rc="${PIPESTATUS[0]}"
  if [ "${rc}" -ne 0 ]; then
    log_error "${pb} 失败（rc=${rc}），日志: ${LOG_FILE}"
    exit "${rc}"
  fi
  log_mark "${pb} 完成"
}

# -----------------------------------------------------------------------------
# status
# -----------------------------------------------------------------------------
cmd_status() {
  load_all
  inventory_generate_quiet

  log_mark "集群状态 vs ipam.yml"
  local ipam_hosts_str
  ipam_hosts_str="$(ipam_hosts | tr '\n' ' ')"

  KUBECONFIG="${PROD_DIR}/kubeconfig"
  export KUBECONFIG

  if [ ! -f "${KUBECONFIG}" ]; then
    log_warn "找不到 ${KUBECONFIG}，先跑 bootstrap.sh 或检查文件是否存在"
    return 0
  fi

  log_info "ipam.yml 里的节点: ${ipam_hosts_str}"
  echo ""
  kubectl get nodes -o wide || log_warn "无法连接集群"
  echo ""
  echo "组件:"
  kubectl get pods -A 2>/dev/null | grep -E '^(NAMESPACE|kube-system|ingress-nginx|cert-manager|cattle-system|local-path-storage|nfs-provisioner)' || true
}

# -----------------------------------------------------------------------------
# apply（扩容）
# -----------------------------------------------------------------------------
cmd_apply() {
  load_all
  inventory_generate_quiet

  log_mark "扩容：把 ipam.yml 新增节点拉进集群"
  log_info "当前 ipam 节点: $(ipam_hosts | tr '\n' ' ')"

  # 与 bootstrap 同一条流水线：新增节点也要先建 ops 账号、装系统前置、再装 k3s。
  # 已存在节点上这些步骤都是幂等的（ssh-setup 只补缺失的公钥，10/20 只补差异）。
  run_script scripts/ssh-setup.sh
  run_playbook 05-preflight.yml
  run_playbook 10-os-init.yml
  run_playbook 20-k3s-cluster.yml
  # 最后全量跑一次 addons：应用 ipam.yml 里新增的节点 label，并保证 helm release 一致
  run_playbook 30-addons.yml

  log_mark "扩容完成"
}

# -----------------------------------------------------------------------------
# remove（缩容）
# -----------------------------------------------------------------------------
cmd_remove() {
  local target="$1"
  if [ -z "${target}" ]; then
    log_error "用法: scale.sh remove <hostname>"
    exit 1
  fi

  load_all

  local full_host
  if full_host="$(ipam_resolve_host "${target}")"; then
    target="${full_host}"
  fi

  if ! ipam_has_host "${target}"; then
    log_error "ipam.yml 里找不到节点: ${target}"
    exit 1
  fi

  local role
  role="$(ipam_node_role "${target}")"

  # 生成 inventory 之前先把摘除目标告诉生成器：它会据此落一个 remove_target 组，
  # 让 50-scale-remove.yml 的 hosts: remove_target 直接命中（hosts: 不做模板展开）。
  export PROD_REMOVE_TARGET="${target}"
  inventory_generate_quiet

  log_info "将摘除: ${target}（角色: ${role}）"
  log_info "注意: 此操作会停止 k3s 服务、清空 /var/lib/rancher/k3s、从集群删节点、清 etcd member"
  log_warn "请确认已做好数据备份（scale.sh backup）"

  # inventory 仍包含该节点（要连上去摘除它）；prod_remove_* 供 playbook 内判断用
  run_playbook 50-scale-remove.yml \
    -e "prod_remove_target=${target}" \
    -e "prod_remove_role=${role}"

  log_mark "缩容完成：${target} 已摘除"
  log_warn "现在可以从 config/ipam.yml 里删除 ${target} 那一条，然后重新跑 scale.sh status 确认"
}

# -----------------------------------------------------------------------------
# upgrade
# -----------------------------------------------------------------------------
cmd_upgrade() {
  local version="" serial=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --version) version="$2"; shift 2 ;;
      --serial)  serial="$2"; shift 2 ;;
      *) log_error "未知参数: $1"; exit 1 ;;
    esac
  done

  if [ -z "${version}" ]; then
    log_error "必须指定 --version，例如 v1.31.4+k3s1"
    exit 1
  fi

  load_all
  # 传给 inventory 生成器（k3s_download_url 由它推导），也让后续日志能看出目标版本
  export K3S_RESOLVED_VERSION="${version}"
  inventory_generate_quiet

  log_mark "升级 k3s 到 ${version}（serial=${serial}）"
  # 60-upgrade：下载新二进制 → 重启服务 → 等 node Ready
  run_playbook "${PLAYBOOK_DIR}/60-upgrade.yml" \
    -e "k3s_upgrade_version=${version}" \
    --serial "${serial}"

  log_mark "升级完成：${version}"
}

# -----------------------------------------------------------------------------
# backup
# -----------------------------------------------------------------------------
cmd_backup() {
  load_all
  inventory_generate_quiet

  log_mark "在第一个 server 上创建 etcd snapshot"
  # 70-backup 只在 server 组上跑（--limit 限定到首个 server）
  run_playbook "${PLAYBOOK_DIR}/70-backup.yml" \
    --limit "$(ipam_first_server_host)"

  log_mark "备份完成"
}

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------
main() {
  local sub="${1:-}"
  shift || true
  case "${sub}" in
    status)   cmd_status ;;
    apply)    cmd_apply ;;
    remove)   cmd_remove "${1:-}" ;;
    upgrade)  cmd_upgrade "$@" ;;
    backup)   cmd_backup ;;
    -h|--help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
