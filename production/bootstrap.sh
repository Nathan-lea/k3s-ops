#!/usr/bin/env bash
# =============================================================================
# production/bootstrap.sh —— 一键把 N 台装好系统的裸机变成可用的 k3s 集群
# =============================================================================
# 用法:
#   ./production/bootstrap.sh                      # 全流程（首次部署）
#   ./production/bootstrap.sh --steps 05,20        # 只跑指定阶段
#   ./production/bootstrap.sh --dry-run            # 只打印将要执行的命令
#   ./production/bootstrap.sh --skip-addons        # 只到 k3s 集群可用，不装附加组件
#
# 流水线（各阶段幂等，可反复执行）:
#   05-preflight.yml      只读预检：OS/资源/端口/离线 chart
#   ssh-setup.sh          root→ops（生成密钥、分发、验证 ops+密钥、收紧 root 登录）
#   10-os-init.yml        系统初始化：复用 k3s-common + 时区/chrony/limits/本地盘目录/ufw
#   20-k3s-cluster.yml    装 k3s：第一个 server init，其余 server 走 etcd join，agent 走 token
#   30-addons.yml         附加组件：localdisk / ingress / cert-manager / NFS / Rancher / 节点标签
#   kubeconfig.sh         生成 production/kubeconfig（server 指向首个 server 的 IP）
#   verify.sh             落地后自检
#
# 说明: production/ 依赖父仓库的 ansible/roles/* 与 lib/*，不能单独拷贝走。
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

# =============================================================================
# 参数
# =============================================================================
ALL_STEPS="05,ssh,10,20,30,kubeconfig,verify"
STEPS="${ALL_STEPS}"
DRY_RUN=0

usage() {
  cat <<'EOF'
用法: production/bootstrap.sh [选项]

选项:
  --steps 05,ssh,10,20,30,kubeconfig,verify   只跑指定阶段（默认全部）
  --skip-addons                                只到 k3s 集群可用，不装附加组件
  --dry-run                                    只打印将要执行的命令，不真正跑
  -h, --help                                   显示帮助

阶段:
  05          05-preflight.yml     只读预检：OS/资源/端口/离线 chart
  ssh         scripts/ssh-setup.sh root→ops（建账号、分发密钥、验证、收紧 root 登录）
  10          10-os-init.yml       系统初始化：复用 k3s-common + 时区/chrony/limits/本地盘/ufw
  20          20-k3s-cluster.yml   装 k3s：第一个 server init，其余 etcd join，agent token 加入
  30          30-addons.yml        附加组件：localdisk/ingress/cert-manager/NFS/Rancher/节点标签
  kubeconfig  scripts/kubeconfig.sh  生成 production/kubeconfig
  verify      scripts/verify.sh      落地后自检

环境变量优先级最高，可覆盖配置文件，例如:
  SSH_PORT=2222 INIT_SSH_USER=root INIT_SSH_PASSWORD=xxx ./production/bootstrap.sh
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --steps)         STEPS="$2"; shift 2 ;;
    --steps=*)       STEPS="${1#*=}"; shift ;;
    --skip-addons)   STEPS="05,ssh,10,20,kubeconfig,verify"; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) log_error "未知参数: $1"; usage; exit 1 ;;
  esac
done

want() { case ",${STEPS}," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

# =============================================================================
# 前置检查
# =============================================================================
mkdir -p "${STATE_DIR}" "${LOG_DIR}" "${INVENTORY_DIR}"

preflight_host_tools() {
  prod_require_cmd python3 "解析 ipam.yml 与生成 Ansible 变量都需要"
  prod_require_cmd ansible-playbook "需安装 ansible >= 2.15"
  if want ssh && [ "${SSH_PORT}" = "22" ]; then
    # sshpass 只在"用密码做首次分发"时需要；没有就走 ssh-copy-id 交互输入
    command -v sshpass >/dev/null 2>&1 || \
      log_warn "未安装 sshpass，ssh-setup.sh 会退化成交互式输入密码（apt-get install -y sshpass）"
  fi
  if [ "${CHARTS_MODE}" = "local" ]; then
    prod_require_cmd tar "CHARTS_MODE=local 时需要解包 chart"
  fi
}

check_config() {
  if ! prod_validate_config; then
    log_error "配置校验未通过，请修正 ${CONFIG_FILE} 后重试"
    exit 1
  fi
  if ! ipam_validate; then
    log_error "IPAM 校验未通过，请修正 ${IPAM_FILE} 后重试"
    exit 1
  fi
  local server_count
  server_count="$(ipam_count_servers)"
  if [ "${server_count}" -lt 1 ]; then
    log_error "ipam.yml 里至少要有一台 role: server"
    exit 1
  fi
  log_info "配置校验通过: server=${server_count} agent=$(($(ipam_count) - server_count))"
  log_info "集群: $(ipam_first_server_host) ($(ipam_first_server_ip)) ← init 节点"
}

# =============================================================================
# 执行器
# =============================================================================
run_playbook() { # $1=playbook 文件名（playbooks/ 下）; 其余参数原样透传给 ansible-playbook
  local ref="$1"
  shift
  local pb="${PLAYBOOK_DIR}/${ref}"
  [ -f "${pb}" ] || { log_error "找不到 playbook: ${pb}"; exit 1; }
  local -a cmd=(ansible-playbook "${pb}"
    -i "${INVENTORY_HOSTS_FILE}"
    -e "@${INVENTORY_EXTRA_VARS_FILE}"
    "$@")
  log_mark "执行: ${ref} $*"
  if [ "${DRY_RUN}" = "1" ]; then
    printf '[dry-run]'; printf ' %q' "${cmd[@]}"; printf '\n'
    return 0
  fi
  "${cmd[@]}" | tee -a "${LOG_FILE}"
  local rc="${PIPESTATUS[0]}"
  if [ "${rc}" -ne 0 ]; then
    log_error "${ref} 失败（rc=${rc}），日志: ${LOG_FILE}"
    exit "${rc}"
  fi
  log_mark "${ref} 完成"
}

run_script() { # $1=脚本路径
  local s="${PROD_DIR}/$1"
  [ -f "${s}" ] || { log_error "找不到脚本: ${s}"; exit 1; }
  log_mark "执行: $1"
  if [ "${DRY_RUN}" = "1" ]; then
    printf '[dry-run] bash %s\n' "${s}"
    return 0
  fi
  bash "${s}" | tee -a "${LOG_FILE}"
  local rc="${PIPESTATUS[0]}"
  if [ "${rc}" -ne 0 ]; then
    log_error "$1 失败（rc=${rc}），日志: ${LOG_FILE}"
    exit "${rc}"
  fi
}

# =============================================================================
# 主流程
# =============================================================================
main() {
  log_mark "k3s production bootstrap 开始"
  log_info "日志: ${LOG_FILE}"
  prod_require_cmd tee

  preflight_host_tools
  check_config

  if want 05; then
    # 版本解析（online 走 channel 端点；offline 读 artifacts/k3s.version）
    prod_resolve_k3s_version || exit 1
    inventory_generate
    inventory_show_summary
    run_playbook 05-preflight.yml
  else
    prod_resolve_k3s_version || exit 1
    inventory_generate
    log_warn "跳过 05-preflight 预检（--steps 未包含 05）"
  fi

  if want ssh; then
    run_script scripts/ssh-setup.sh
    # ssh-setup 之后切换到 ops 账号：重新生成 inventory（host_vars 里的 user 不变，
    # 真正的切换点是 ssh-setup.sh 已经把密钥装好、并且验证了 ops+密钥能连）
  else
    log_warn "跳过 ssh-setup（--steps 未包含 ssh）"
  fi

  if want 10; then
    run_playbook 10-os-init.yml
  fi

  if want 20; then
    run_playbook 20-k3s-cluster.yml
  fi

  if want 30; then
    run_playbook 30-addons.yml
  fi

  if want kubeconfig; then
    run_script scripts/kubeconfig.sh
  fi

  if want verify; then
    run_script scripts/verify.sh
  fi

  log_mark "k3s production bootstrap 全部完成"
  cat <<EOF

=============================================================================
集群已就绪

  kubeconfig : production/kubeconfig
              export KUBECONFIG=\$(pwd)/production/kubeconfig && kubectl get nodes
  Rancher    : $(prod_bool "${RANCHER_ENABLED}" && echo "https://${RANCHER_HOSTNAME}/（任意节点 IP 皆可，Host 头需为 ${RANCHER_HOSTNAME}）" || echo "未启用")
  日志       : ${LOG_FILE}

  登录方式: 只有 ops 用户可用密钥登录（root 已按配置收紧）
  运维入口: ./production/scale.sh {apply|remove|status|upgrade|backup}
=============================================================================
EOF
}

main
