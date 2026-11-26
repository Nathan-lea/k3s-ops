#!/bin/bash
# 测试：k3s-ops.sh CLI 统一生成运行时 inventory，并显式设置 ANSIBLE_CONFIG
#
# 覆盖：
#   A. install/add-node/remove-node/upgrade/backup/deploy-rancher 生成 inventory.generated.yml（或 K3S_OPS_INVENTORY）
#   B. ansible-playbook 调用使用生成的 inventory，且带 -l/extra vars
#   C. 生成的 inventory 含 target_node/new_server/new_agent/first_server
#   D. K3S_OPS_INVENTORY 可覆盖输出路径（不污染 repo 默认文件）
#   E. 仓库敏感文件未被改动

set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

guard_stubs

CLI="${PROJECT_DIR}/k3s-ops.sh"
TMP="$(new_tmpdir)"
export HOME="${TMP}/home"
mkdir -p "${HOME}"
export LOG_DIR="${TMP}/logs"
export VAGRANT_STUB_LOG="${TMP}/vagrant.log"
export ANSIBLE_STUB_LOG="${TMP}/ansible.log"
export K3S_OPS_INVENTORY="${TMP}/inventory.generated.yml"

# stub ansible-playbook 额外记录 ANSIBLE_CONFIG
ANSIBLE_CFG_LOG="${TMP}/ansible-cfg.log"
cat > "${TMP}/ansible-playbook" <<'STUB'
#!/bin/bash
echo "ANSIBLE_CALL: $*" >> "${ANSIBLE_STUB_LOG}"
echo "ANSIBLE_CONFIG=${ANSIBLE_CONFIG:-}" >> "${ANSIBLE_CFG_LOG:-/dev/null}"
exit 0
STUB
chmod +x "${TMP}/ansible-playbook"
export ANSIBLE_CFG_LOG
export PATH="${TMP}:${STUB_BIN}:${PATH}"

REPO_FINGERPRINT_BEFORE="$(repo_fingerprint)"
trap cleanup_all EXIT

assert_inv() {
  local file="$1" expr="$2" desc="$3"
  local out
  out="$(python3 - "$file" "$expr" <<'PY' 2>&1
import sys, yaml
path, expr = sys.argv[1], sys.argv[2]
inv = yaml.safe_load(open(path, encoding='utf-8'))
if not eval(expr):
    print('assertion failed:', expr)
    sys.exit(1)
PY
)"; local rc=$?
  if [ "${rc}" -eq 0 ]; then ok "${desc}"; else bad "${desc} (${out})"; fi
}

section "A. install 生成 inventory 并调用 ansible-playbook"
: > "${VAGRANT_STUB_LOG}"; : > "${ANSIBLE_STUB_LOG}"; : > "${ANSIBLE_CFG_LOG}"
out="$("${CLI}" install 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "install 退出码 0" || bad "install 退出码 ${rc}: ${out}"
[ -f "${K3S_OPS_INVENTORY}" ] && ok "生成 K3S_OPS_INVENTORY" || bad "未生成 inventory"
grep -q "ANSIBLE_CALL: .*k3s-cluster.yml" "${ANSIBLE_STUB_LOG}" && ok "调用 k3s-cluster.yml" || bad "未调用 k3s-cluster.yml"
grep -q "${K3S_OPS_INVENTORY}" "${ANSIBLE_STUB_LOG}" && ok "ansible 使用生成的 inventory" || bad "ansible 未使用生成的 inventory"
grep -q "ANSIBLE_CONFIG=${PROJECT_DIR}/ansible/ansible.cfg" "${ANSIBLE_CFG_LOG}" && ok "导出 ANSIBLE_CONFIG" || bad "未导出 ANSIBLE_CONFIG: $(cat "${ANSIBLE_CFG_LOG}")"

section "B. add-node/remove-node/upgrade/backup/deploy-rancher"
: > "${ANSIBLE_STUB_LOG}"
"${CLI}" add-node agent-1 >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] && ok "add-node 退出码 0" || bad "add-node 退出码 ${rc}"
grep -q "k3s-add-agent.yml.*-l k3s-demo-agent-1" "${ANSIBLE_STUB_LOG}" && ok "add-node 传递 -l 完整主机名" || bad "add-node 参数异常: $(cat "${ANSIBLE_STUB_LOG}")"

: > "${ANSIBLE_STUB_LOG}"
"${CLI}" remove-node -n agent-1 >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] && ok "remove-node 退出码 0" || bad "remove-node 退出码 ${rc}"
grep -q "k3s-remove-node.yml.*-l k3s-demo-agent-1" "${ANSIBLE_STUB_LOG}" && ok "remove-node 传递 -l 完整主机名" || bad "remove-node 参数异常: $(cat "${ANSIBLE_STUB_LOG}")"

: > "${ANSIBLE_STUB_LOG}"
"${CLI}" upgrade -v v1.31.0+k3s1 >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] && ok "upgrade 退出码 0" || bad "upgrade 退出码 ${rc}"
grep -q "k3s-upgrade.yml.*k3s_upgrade_version=v1.31.0+k3s1" "${ANSIBLE_STUB_LOG}" && ok "upgrade 传递版本参数" || bad "upgrade 参数异常: $(cat "${ANSIBLE_STUB_LOG}")"

: > "${ANSIBLE_STUB_LOG}"
"${CLI}" backup >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] && ok "backup 退出码 0" || bad "backup 退出码 ${rc}"
grep -q "k3s-backup.yml" "${ANSIBLE_STUB_LOG}" && ok "backup 调用 playbook" || bad "backup 未调用 playbook"

: > "${ANSIBLE_STUB_LOG}"
"${CLI}" deploy-rancher >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] && ok "deploy-rancher 退出码 0" || bad "deploy-rancher 退出码 ${rc}"
grep -q "rancher-deploy.yml" "${ANSIBLE_STUB_LOG}" && ok "deploy-rancher 调用 playbook" || bad "deploy-rancher 未调用 playbook"

section "C. 生成的 inventory 结构"
assert_inv "${K3S_OPS_INVENTORY}" "'k3s-demo-server-1' in inv['all']['children']['server']['hosts']" "server 组包含 server-1"
assert_inv "${K3S_OPS_INVENTORY}" "'k3s-demo-agent-1' in inv['all']['children']['agent']['hosts']" "agent 组包含 agent-1"
assert_inv "${K3S_OPS_INVENTORY}" "'k3s-demo-agent-1' in inv['all']['children']['new_agent']['hosts']" "new_agent 组包含 agent-1"
assert_inv "${K3S_OPS_INVENTORY}" "'k3s-demo-server-1' in inv['all']['children']['new_server']['hosts']" "new_server 组包含 server-1"
assert_inv "${K3S_OPS_INVENTORY}" "'k3s-demo-agent-1' in inv['all']['children']['target_node']['hosts']" "target_node 组包含 agent-1"
assert_inv "${K3S_OPS_INVENTORY}" "inv['all']['vars']['first_server_ip'] == '192.168.56.10'" "first_server_ip 正确"
assert_inv "${K3S_OPS_INVENTORY}" "inv['all']['vars']['first_server_host'] == 'k3s-demo-server-1'" "first_server_host 正确"

section "D. 默认不污染 tracked placeholder"
if [ ! -e "${PROJECT_DIR}/ansible/inventory.generated.yml" ]; then
  ok "repo 根目录未生成 inventory.generated.yml（使用了 K3S_OPS_INVENTORY 覆盖）"
else
  bad "repo 根目录出现 inventory.generated.yml"
fi

section "E. 仓库敏感文件未被改动"
assert_repo_untouched

finish "test-k3s-ops-inventory"
