#!/bin/bash
# k3s-ops — k3s 全生命周期管理 CLI
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
VAGRANT_DIR="${SELF_DIR}/vagrant"
ANSIBLE_DIR="${SELF_DIR}/ansible"
PLAYBOOK_DIR="${ANSIBLE_DIR}/playbooks"

source "${SELF_DIR}/lib/logging.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  init                       检查环境依赖
  up [node]                  vagrant up（可选指定节点）
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

# --- Command: init ---
cmd_init() {
  log_info "Checking environment dependencies..."
  bash "${SELF_DIR}/scripts/bootstrap.sh"
}

# --- Command: up ---
cmd_up() {
  cd "${SELF_DIR}"
  if [ $# -ge 1 ]; then
    log_cmd "Starting VM: ${1}" vagrant up "${1}"
  else
    log_cmd "Starting all VMs" vagrant up
  fi
}

# --- Command: install ---
cmd_install() {
  cd "${SELF_DIR}"
  log_cmd "Installing k3s cluster" run_playbook "k3s-cluster.yml"
  log_mark "kubeconfig: ${SELF_DIR}/kubeconfig"
}

# --- Command: add-node ---
cmd_add_node() {
  local node_name="$1"
  if [ -z "$node_name" ]; then
    log_error "Usage: $(basename "$0") add-node <node_name>"
    exit 1
  fi

  cd "${SELF_DIR}"

  # Determine role from nodes.yml
  role=$(python3 -c "
import yaml
with open('${VAGRANT_DIR}/nodes.yml') as f:
    cfg = yaml.safe_load(f)
for n in cfg['nodes']:
    if n['name'] == '${node_name}':
        print(n['role'])
        break
")
  if [ -z "$role" ]; then
    log_error "Node '${node_name}' not found in vagrant/nodes.yml"
    exit 1
  fi

  local full_host="${cluster_name}-${node_name}"

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
  local full_host="${cluster_name}-${node_name}"

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
  log_info "Access Rancher: https://${first_server_ip}:30443"
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
  log_info "nginx-ingress HTTP: http://${first_server_ip}:30080"
}

# --- Command: status ---
cmd_status() {
  cd "${SELF_DIR}"
  log_info "Cluster health check..."
  if [ -f "${SELF_DIR}/kubeconfig" ]; then
    KUBECONFIG="${SELF_DIR}/kubeconfig" bash "${ANSIBLE_DIR}/files/health-check.sh"
  else
    log_info "No kubeconfig found locally. Running on first server..."
    vagrant ssh "${first_server_host}" -- "sudo bash -s" < "${ANSIBLE_DIR}/files/health-check.sh" 2>/dev/null || \
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
}

# --- Command: ssh ---
cmd_ssh() {
  local node_name="$1"
  if [ -z "$node_name" ]; then
    log_error "Usage: $(basename "$0") ssh <node_name>"
    exit 1
  fi
  cd "${SELF_DIR}"
  vagrant ssh "${cluster_name}-${node_name}"
}

# --- Command: kubeconfig ---
cmd_kubeconfig() {
  local node="${1:-server-1}"
  bash "${SELF_DIR}/scripts/get-kubeconfig.sh" "$node"
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
