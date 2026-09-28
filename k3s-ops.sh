#!/bin/bash
# k3s-ops — k3s 全生命周期管理 CLI
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
VAGRANT_DIR="${SELF_DIR}/vagrant"
ANSIBLE_DIR="${SELF_DIR}/ansible"
PLAYBOOK_DIR="${ANSIBLE_DIR}/playbooks"

source "${SELF_DIR}/lib/logging.sh"
source "${SELF_DIR}/lib/nodes.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  init                       检查环境依赖
  up [node]                  vagrant up（可选指定节点）
  down [node] [options]      关闭 VM 释放资源（-f 强制关机 / -s 挂起）
  install                    首次完整安装 k3s 集群
  add-node <node>            将新节点加入集群
  remove-node -n <name>      移除指定节点
  upgrade -v <version>       升级 k3s 版本
  backup                     etcd 快照备份
  restore -f <snapshot>      从快照恢复
  deploy-rancher             部署 Rancher UI
  reset-rancher-admin        重置 Rancher admin 密码
  deploy-ingress             部署 nginx-ingress
  status                     集群健康检查
  destroy                    销毁所有 VM
  ssh <node>                 SSH 到指定节点
  kubeconfig [node]          获取 kubeconfig

Examples:
  $(basename "$0") init
  $(basename "$0") up
  $(basename "$0") down
  $(basename "$0") down agent-1
  $(basename "$0") down --suspend
  $(basename "$0") install
  $(basename "$0") add-node server-2
  $(basename "$0") remove-node -n agent-1
  $(basename "$0") upgrade -v v1.31.0+k3s1
  $(basename "$0") destroy
EOF
  exit 0
}

# --- Helper: run ansible-playbook with inventory ---
run_playbook() {
  local playbook="$1"
  shift
  ansible-playbook -i "${ANSIBLE_DIR}/inventory.yml" \
    "${PLAYBOOK_DIR}/${playbook}" \
    "$@"
}

# --- Helper: read nodes.yml ---
read_nodes_yml() {
  python3 -c "
import yaml, sys
with open('${VAGRANT_DIR}/nodes.yml') as f:
    cfg = yaml.safe_load(f)

nodes = cfg.get('nodes', [])
servers = [n for n in nodes if n['role'] == 'server']
agents = [n for n in nodes if n['role'] == 'agent']

print(f'CLUSTER_NAME={cfg[\"cluster_name\"]}')
print(f'FIRST_SERVER_IP={servers[0][\"ip\"]}')
print(f'FIRST_SERVER_HOST={cfg[\"cluster_name\"]}-{servers[0][\"name\"]}')
print(f'K3S_VERSION={cfg[\"k3s_version\"]}')
"
}

# --- Helper: 归一化节点名为 Vagrant 完整主机名 ---
# 短名(agent-1) 与完整主机名(k3s-demo-agent-1) 都接受

# --- 内部: 归档 VirtualBox 产生的 VM 日志 ---
# VBox 把 *VBoxHeadless-*.log 写进启动进程的 CWD（即项目根），
# 而 VirtualBox 7.x 已移除 VBoxManage set logfile，无法改写入位置，
# 只能在 VM 启停后事后归档到 logs/vbox/。
# 仅保留最近 ${VBOX_LOG_KEEP:-20} 个，避免无限增长。
_archive_vbox_logs() {
  local keep="${VBOX_LOG_KEEP:-20}"
  local dest="${SELF_DIR}/logs/vbox"

  shopt -s nullglob
  local -a files=( "${SELF_DIR}"/*VBoxHeadless-*.log )
  shopt -u nullglob
  [ "${#files[@]}" -eq 0 ] && return 0

  mkdir -p "${dest}"
  mv "${files[@]}" "${dest}/"
  log_debug "Archived ${#files[@]} VirtualBox log(s) to logs/vbox/"

  # 按修改时间保留最新 keep 个
  local -a stale=()
  mapfile -t stale < <(ls -1t "${dest}"/*VBoxHeadless-*.log 2>/dev/null | tail -n "+$((keep + 1))")
  if [ "${#stale[@]}" -gt 0 ]; then
    rm -f "${stale[@]}"
    log_debug "Pruned ${#stale[@]} old VirtualBox log(s) (keep latest ${keep})"
  fi
}

# --- Command: init ---
cmd_init() {
  log_info "Checking environment dependencies..."
  bash "${SELF_DIR}/scripts/bootstrap.sh"
}

# --- Command: up ---
cmd_up() {
  cd "${SELF_DIR}"
  if [ $# -ge 1 ]; then
    resolve_host "${1}"
    log_cmd "Starting VM: ${RESOLVED_HOST}" vagrant up "${RESOLVED_HOST}"
  else
    log_cmd "Starting all VMs" vagrant up
  fi
  _archive_vbox_logs
}

# --- Command: down ---
# 关闭 VM 释放宿主机资源：默认优雅关机，可选强制或挂起
cmd_down() {
  local force=0 suspend=0

  # 选项与位置参数分离：getopts 遇到第一个非选项参数就停止，
  # 不预先分离的话 `down agent-1 -f` 里的 -f 会被静默丢弃。
  # 同时把 --long 归一化为短选项（getopts 不支持长选项）。
  local -a opts=() ops=()
  local a
  for a in "$@"; do
    case "$a" in
      --force)   opts+=("-f") ;;
      --suspend) opts+=("-s") ;;
      --help)    opts+=("-h") ;;
      -*)        opts+=("${a}") ;;
      *)         ops+=("${a}") ;;
    esac
  done

  if [ ${#ops[@]} -gt 1 ]; then
    log_error "Too many arguments: ${ops[*]}"
    log_error "Usage: $(basename "$0") down [node] [-f|--force] [-s|--suspend]"
    exit 1
  fi

  set -- ${opts[@]+"${opts[@]}"}
  while getopts ":fsh" opt; do
    case "$opt" in
      f) force=1 ;;
      s) suspend=1 ;;
      h) usage ;;
      :) log_error "Option -${OPTARG} requires an argument"; exit 1 ;;
      *) log_error "Unknown option: -${OPTARG}"; exit 1 ;;
    esac
  done

  if [ "${force}" -eq 1 ] && [ "${suspend}" -eq 1 ]; then
    log_error "Cannot use both -f (--force) and -s (--suspend)"
    exit 1
  fi

  cd "${SELF_DIR}"

  local action="halt" verb="Halting"
  if [ "${suspend}" -eq 1 ]; then
    action="suspend"
    verb="Suspending"
  fi

  local -a vcmd=("vagrant" "${action}")
  [ "${force}" -eq 1 ] && vcmd+=("-f")

  if [ ${#ops[@]} -ge 1 ]; then
    resolve_host "${ops[0]}"
    vcmd+=("${RESOLVED_HOST}")
    log_cmd "${verb} VM: ${RESOLVED_HOST}" "${vcmd[@]}"
  else
    log_cmd "${verb} all VMs" "${vcmd[@]}"
  fi

  log_info "Start again with: $(basename "$0") up"
  _archive_vbox_logs
}

# --- Command: install ---
cmd_install() {
  cd "${SELF_DIR}"
  log_cmd "Installing k3s cluster" run_playbook "k3s-cluster.yml"
  log_mark "kubeconfig: ${SELF_DIR}/kubeconfig"
}

# --- Command: add-node ---
cmd_add_node() {
  # 用 ${1:-} 而非 $1：set -u 下缺参数会直接崩，来不及打印 usage
  local node_name="${1:-}"
  if [ -z "$node_name" ]; then
    log_error "Usage: $(basename "$0") add-node <node_name>"
    exit 1
  fi

  cd "${SELF_DIR}"

  resolve_host "${node_name}"
  local full_host="${RESOLVED_HOST}"
  local role
  role="$(node_role "${full_host}")"

  if [ "$role" = "server" ]; then
    log_cmd "Adding server node: ${full_host}" run_playbook "k3s-add-server.yml" -l "${full_host}"
  else
    log_cmd "Adding agent node: ${full_host}" run_playbook "k3s-add-agent.yml" -l "${full_host}"
  fi
}

# --- Command: remove-node ---
cmd_remove_node() {
  local node_name=""
  while getopts "n:" opt; do
    case "$opt" in
      n) node_name="$OPTARG" ;;
      *) exit 1 ;;
    esac
  done

  if [ -z "$node_name" ]; then
    log_error "Usage: $(basename "$0") remove-node -n <node_name>"
    exit 1
  fi

  cd "${SELF_DIR}"
  resolve_host "${node_name}"
  local full_host="${RESOLVED_HOST}"

  log_cmd "Removing node: ${full_host}" run_playbook "k3s-remove-node.yml" -l "${full_host}"
  log_info "You can now run: vagrant destroy ${full_host}"
}

# --- Command: upgrade ---
cmd_upgrade() {
  local version=""
  while getopts "v:" opt; do
    case "$opt" in
      v) version="$OPTARG" ;;
      *) exit 1 ;;
    esac
  done

  if [ -z "$version" ]; then
    log_error "Usage: $(basename "$0") upgrade -v <version>"
    exit 1
  fi

  cd "${SELF_DIR}"
  log_cmd "Upgrading k3s to ${version}" run_playbook "k3s-upgrade.yml" -e "k3s_upgrade_version=${version}"
}

# --- Command: backup ---
cmd_backup() {
  cd "${SELF_DIR}"
  log_cmd "Creating etcd snapshot backup" run_playbook "k3s-backup.yml"
}

# --- Command: restore ---
cmd_restore() {
  local snapshot_file=""
  while getopts "f:" opt; do
    case "$opt" in
      f) snapshot_file="$OPTARG" ;;
      *) exit 1 ;;
    esac
  done

  if [ -z "$snapshot_file" ]; then
    log_error "Usage: $(basename "$0") restore -f <snapshot_file>"
    exit 1
  fi

  cd "${SELF_DIR}"
  log_warn "Restoring from snapshot: ${snapshot_file}"
  log_warn "This will stop all server nodes and restart the cluster!"
  read -rp "Continue? [y/N] " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    log_info "Restore cancelled."
    exit 0
  fi

  log_cmd "Restoring from snapshot" run_playbook "k3s-restore.yml" -e "snapshot_file=${snapshot_file}"
}

# --- Command: deploy-rancher ---
cmd_deploy_rancher() {
  cd "${SELF_DIR}"
  log_cmd "Deploying Rancher" run_playbook "rancher-deploy.yml"
  log_info "Access Rancher: https://${FIRST_SERVER_IP}:30443"
}

# --- Command: reset-rancher-admin ---
cmd_reset_rancher_admin() {
  cd "${SELF_DIR}"
  log_cmd "Resetting Rancher admin password" run_playbook "rancher-reset-admin.yml"
}

# --- Command: deploy-ingress ---
cmd_deploy_ingress() {
  cd "${SELF_DIR}"
  log_cmd "Deploying nginx-ingress" run_playbook "nginx-ingress-deploy.yml"
  log_info "nginx-ingress HTTP: http://${FIRST_SERVER_IP}:30080"
}

# --- Command: status ---
cmd_status() {
  cd "${SELF_DIR}"
  log_info "Cluster health check..."
  if [ -f "${SELF_DIR}/kubeconfig" ]; then
    # 宿主机上以普通用户运行，日志需落在项目 logs/ 下（/var/log 不可写）
    LOG_FILE="${SELF_DIR}/logs/health-check.log" \
      KUBECONFIG="${SELF_DIR}/kubeconfig" \
      bash "${ANSIBLE_DIR}/files/health-check.sh" || \
      log_error "Health check failed"
  else
    log_info "No kubeconfig found locally. Running on first server..."
    vagrant ssh "${FIRST_SERVER_HOST}" -- "sudo bash -s" < "${ANSIBLE_DIR}/files/health-check.sh" 2>/dev/null || \
      log_error "Cannot reach cluster. Is it running?"
  fi
}

# --- Command: destroy ---
cmd_destroy() {
  cd "${SELF_DIR}"
  log_warn "This will DESTROY all VMs. Are you sure?"
  read -rp "Type 'yes' to confirm: " confirm
  if [ "$confirm" != "yes" ]; then
    log_info "Destroy cancelled."
    exit 0
  fi
  log_cmd "Destroying all VMs" vagrant destroy -f
  _archive_vbox_logs
}

# --- Command: ssh ---
cmd_ssh() {
  local node_name="${1:-}"
  if [ -z "$node_name" ]; then
    log_error "Usage: $(basename "$0") ssh <node_name>"
    exit 1
  fi
  cd "${SELF_DIR}"
  resolve_host "${node_name}"
  vagrant ssh "${RESOLVED_HOST}"
}

# --- Command: kubeconfig ---
# 节点名短名与完整主机名都接受；结果写入项目根目录的 kubeconfig
cmd_kubeconfig() {
  local node="${1:-server-1}"
  resolve_host "${node}"
  bash "${SELF_DIR}/scripts/get-kubeconfig.sh" "${RESOLVED_HOST}"
}

# ============================================================

# --- Main ---
mkdir -p /tmp/ansible-cache 2>/dev/null || true

# 初始化日志
log_init

# Parse cluster info
eval "$(read_nodes_yml 2>/dev/null || true)"

if [ $# -eq 0 ]; then
  usage
fi

SUBCOMMAND="$1"
shift

case "$SUBCOMMAND" in
  init)              cmd_init "$@" ;;
  up)                cmd_up "$@" ;;
  down)              cmd_down "$@" ;;
  install)           cmd_install "$@" ;;
  add-node)          cmd_add_node "$@" ;;
  remove-node)       cmd_remove_node "$@" ;;
  upgrade)           cmd_upgrade "$@" ;;
  backup)            cmd_backup "$@" ;;
  restore)           cmd_restore "$@" ;;
  deploy-rancher)    cmd_deploy_rancher "$@" ;;
  reset-rancher-admin) cmd_reset_rancher_admin "$@" ;;
  deploy-ingress)    cmd_deploy_ingress "$@" ;;
  status)            cmd_status "$@" ;;
  destroy)           cmd_destroy "$@" ;;
  ssh)               cmd_ssh "$@" ;;
  kubeconfig)        cmd_kubeconfig "$@" ;;
  *)                 usage ;;
esac
