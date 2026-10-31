#!/usr/bin/env bash
# =============================================================================
# run-in-guest.sh —— 在工作机里执行某个动作（由 Windows 侧 up.ps1 调用）
# =============================================================================
# 存在的唯一理由：`vagrant ssh -c "命令"` 走的是**非交互** shell，
# Ubuntu 的 ~/.bashrc 开头有 `case $- in *i*) ;; *) return;; esac`，
# 非交互时直接返回，PATH / ANSIBLE_CONFIG / KUBECONFIG 全都不会生效。
# 与其在 PowerShell 里拼一串嵌套引号，不如把动作收敛成这里的子命令。
#
# 用法：
#   bash /vagrant/win/guest/bin/run-in-guest.sh provision   # 引导工作机（幂等）
#   bash /vagrant/win/guest/bin/run-in-guest.sh install     # k3s-ops.sh install
#   bash /vagrant/win/guest/bin/run-in-guest.sh kubeconfig  # 改写 server 地址
#   bash /vagrant/win/guest/bin/run-in-guest.sh status      # 集群健康检查
#   bash /vagrant/win/guest/bin/run-in-guest.sh check       # 环境自检（不碰集群）
# =============================================================================
set -uo pipefail

DEST="${K3S_OPS_DEST:-$HOME/k3s-ops}"
VENV="$HOME/.venv/k3s-ops"
LOCAL_BIN="$HOME/.local/bin"

export PATH="${VENV}/bin:${LOCAL_BIN}:${PATH}"
export ANSIBLE_CONFIG="${DEST}/ansible/ansible.cfg"
export KUBECONFIG="${DEST}/kubeconfig"

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 2
}

need_project() {
  [ -d "${DEST}" ] || { echo "ERROR: ${DEST} 不存在，先跑 provision" >&2; exit 1; }
  cd "${DEST}" || exit 1
}

case "${1:-}" in
  provision)
    shift
    exec bash "${DEST}/win/provision-ops.sh" "$@"
    ;;
  install)
    need_project
    exec ./k3s-ops.sh install
    ;;
  kubeconfig)
    need_project
    exec ./k3s-ops.sh kubeconfig
    ;;
  status)
    need_project
    exec ./k3s-ops.sh status
    ;;
  check)
    need_project
    rc=0
    printf '%-28s %s\n' "python3"     "$(python3 -V 2>&1 || echo MISSING)"
    printf '%-28s %s\n' "ansible-playbook" "$(ansible-playbook --version 2>/dev/null | head -1 || echo MISSING)"
    printf '%-28s %s\n' "kubectl"     "$(kubectl version --client 2>/dev/null | head -1 || echo MISSING)"
    printf '%-28s %s\n' "helm"        "$(helm version --short 2>/dev/null || echo MISSING)"
    printf '%-28s %s\n' "vagrant(shim)" "$(vagrant --help >/dev/null 2>&1 && echo OK || echo MISSING)"
    printf '%-28s %s\n' "inventory"   "$([ -s ansible/inventory.yml ] && echo OK || echo MISSING)"
    printf '%-28s %s\n' "ANSIBLE_CONFIG" "${ANSIBLE_CONFIG}"
    ansible-inventory -i ansible/inventory.yml --list >/dev/null 2>&1 \
      && echo "inventory 可解析: OK" || { echo "inventory 可解析: FAIL" >&2; rc=1; }
    exit "${rc}"
    ;;
  *)
    usage
    ;;
esac
