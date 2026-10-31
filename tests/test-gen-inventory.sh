#!/bin/bash
# 测试：scripts/gen-inventory.py（从 nodes.yml 生成 Ansible inventory）
#
# 覆盖：
#   A. 默认拓扑（Linux）生成的 inventory 结构正确
#   B. Windows 拓扑里的 role: ops 工作机被排除
#   C. 缺 server 时报错退出（不生成半成品）
#   D. --stdout 不落盘
#   E. 幂等：两次生成结果逐字节相同
#   F. --check 自检通过
#   G. 仓库敏感文件未被测试改动
#
# 说明：gen-inventory.py 是只读生成器（只写 --out 指定的文件），
# 不调用 vagrant/ansible-playbook，所以无需 stub 保护 VM。

set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

GEN="${PROJECT_DIR}/scripts/gen-inventory.py"
TMP="$(new_tmpdir)"
trap cleanup_all EXIT

REPO_FINGERPRINT_BEFORE="$(repo_fingerprint)"

# assert_inv <file> <python 断言表达式>
# 表达式里可用 inv（已解析的 dict）与 hostvars（_meta.hostvars）
assert_inv() {
  local file="$1" expr="$2" desc="$3"
  local out
  out="$(python3 - "$file" "$expr" <<'PY' 2>&1
import json, subprocess, sys, yaml
path, expr = sys.argv[1], sys.argv[2]
inv = yaml.safe_load(open(path, encoding="utf-8"))
hostvars = {}
try:
    listing = subprocess.run(["ansible-inventory", "-i", path, "--list"],
                             capture_output=True, text=True, timeout=60)
    if listing.returncode == 0:
        hostvars = json.loads(listing.stdout).get("_meta", {}).get("hostvars", {})
except FileNotFoundError:
    pass
if not eval(expr):
    print("assertion failed: " + expr)
    sys.exit(1)
PY
)"; local rc=$?
  if [ "${rc}" -eq 0 ]; then
    ok "${desc}"
  else
    bad "${desc} (${out})"
  fi
}

section "A. 默认拓扑（vagrant/nodes.yml）"
INV_A="${TMP}/inv-a.yml"
out="$("${GEN}" --nodes "${PROJECT_DIR}/vagrant/nodes.yml" --out "${INV_A}" 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ] && [ -f "${INV_A}" ]; then
  ok "生成成功"
else
  bad "生成失败 rc=${rc}: ${out}"
fi

assert_inv "${INV_A}" "inv['all']['vars']['cluster_name'] == 'k3s-demo'" "透传 cluster_name"
assert_inv "${INV_A}" "inv['all']['vars']['first_server_ip'] == '192.168.56.10'" "first_server_ip 来自拓扑"
assert_inv "${INV_A}" "inv['all']['vars']['first_server_host'] == 'k3s-demo-server-1'" "first_server_host 用完整主机名"
assert_inv "${INV_A}" "inv['all']['vars']['k3s_version'] == 'v1.30.2+k3s2'" "透传 k3s_version"
assert_inv "${INV_A}" "'containerd_mirrors' not in inv['all']['vars']" "不复制 group_vars 已定义的值（containerd_mirrors）"
assert_inv "${INV_A}" "'k3s_download_url' not in inv['all']['vars']" "不复制 group_vars 已定义的值（k3s_download_url）"
assert_inv "${INV_A}" "sorted(inv['all']['children']['server']['hosts']) == ['k3s-demo-server-1']" "server 组"
assert_inv "${INV_A}" "sorted(inv['all']['children']['agent']['hosts']) == ['k3s-demo-agent-1']" "agent 组"
assert_inv "${INV_A}" "sorted(inv['all']['children']['new_server']['hosts']) == ['k3s-demo-server-1']" "补 new_server 组（add-server 依赖）"
assert_inv "${INV_A}" "sorted(inv['all']['children']['new_agent']['hosts']) == ['k3s-demo-agent-1']" "补 new_agent 组（add-agent 依赖）"
assert_inv "${INV_A}" "sorted(inv['all']['children']['target_node']['hosts']) == ['k3s-demo-agent-1', 'k3s-demo-server-1']" "补 target_node 组（remove-node 依赖）"
assert_inv "${INV_A}" "hostvars['k3s-demo-agent-1']['ansible_host'] == '192.168.56.20' and hostvars['k3s-demo-agent-1']['node_role'] == 'agent'" "hostvars 含 ansible_host / node_role"
assert_inv "${INV_A}" "hostvars['k3s-demo-server-1']['ansible_user'] == 'vagrant'" "hostvars 含 ansible_user（group_vars 里没有）"
assert_inv "${INV_A}" "hostvars['k3s-demo-server-1']['ansible_ssh_private_key_file'].endswith('/k3s-demo-server-1')" "私钥路径按完整主机名"
assert_inv "${INV_A}" "'&id' not in open(path, encoding='utf-8').read()" "不输出 YAML 锚点（可读性）"

section "B. Windows 拓扑（含 role: ops）"
WIN_NODES="${TMP}/nodes.windows.yml"
python3 - "${PROJECT_DIR}/vagrant/nodes.yml" "${WIN_NODES}" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
cfg["nodes"].append({"name": "ops", "role": "ops", "ip": "192.168.56.5",
                     "cpus": 1, "memory": 1024})
yaml.safe_dump(cfg, open(sys.argv[2], "w", encoding="utf-8"), sort_keys=False, allow_unicode=True)
PY
INV_B="${TMP}/inv-b.yml"
out="$("${GEN}" --nodes "${WIN_NODES}" --out "${INV_B}" 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ]; then
  ok "生成成功"
else
  bad "生成失败 rc=${rc}: ${out}"
fi
assert_inv "${INV_B}" "hostvars and not [h for h in hostvars if h.endswith('-ops')]" "工作机不出现在 inventory 中"
assert_inv "${INV_B}" "len(inv['all']['children']['target_node']['hosts']) == 2" "target_node 仍只含集群节点"

section "C. 缺 server 时报错"
NO_SERVER="${TMP}/nodes.noserver.yml"
python3 - "${PROJECT_DIR}/vagrant/nodes.yml" "${NO_SERVER}" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
cfg["nodes"] = [n for n in cfg["nodes"] if n["role"] != "server"]
yaml.safe_dump(cfg, open(sys.argv[2], "w", encoding="utf-8"), sort_keys=False, allow_unicode=True)
PY
OUT_C="${TMP}/inv-c.yml"
out="$("${GEN}" --nodes "${NO_SERVER}" --out "${OUT_C}" 2>&1)"; rc=$?
if [ "${rc}" -eq 2 ] && [ ! -f "${OUT_C}" ]; then
  ok "退出码 2 且不生成文件"
else
  bad "期望 rc=2 且无输出文件，实际 rc=${rc}: ${out}"
fi

section "D. --stdout 不落盘"
OUT_D="${TMP}/inv-d.yml"
out="$("${GEN}" --nodes "${PROJECT_DIR}/vagrant/nodes.yml" --out "${OUT_D}" --stdout 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ] && [ ! -f "${OUT_D}" ] && [[ "${out}" == *"cluster_name: k3s-demo"* ]]; then
  ok "打印到标准输出，未写 --out"
else
  bad "行为不符 rc=${rc} exists=$([ -f "${OUT_D}" ] && echo yes || echo no)"
fi

section "E. 幂等"
INV_E1="${TMP}/inv-e1.yml"
INV_E2="${TMP}/inv-e2.yml"
"${GEN}" --nodes "${PROJECT_DIR}/vagrant/nodes.yml" --out "${INV_E1}" >/dev/null 2>&1
"${GEN}" --nodes "${PROJECT_DIR}/vagrant/nodes.yml" --out "${INV_E2}" >/dev/null 2>&1
if cmp -s "${INV_E1}" "${INV_E2}"; then
  ok "两次生成逐字节相同"
else
  bad "两次生成结果不同（可能存在时间戳等非确定因素）"
fi

section "F. --check 自检"
out="$("${GEN}" --nodes "${PROJECT_DIR}/vagrant/nodes.yml" --out "${TMP}/inv-f.yml" --check 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ]; then
  ok "ansible-inventory 能解析且关键变量正确"
else
  bad "自检失败 rc=${rc}: ${out}"
fi

section "G. 仓库敏感文件未被测试改动"
assert_repo_untouched

finish "test-gen-inventory"
