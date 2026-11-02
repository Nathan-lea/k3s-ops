#!/bin/bash
# 测试：节点名解析 + down 子命令行为
#
# 覆盖：
#   A. 短名 / 完整主机名都能解析（up/down/ssh/add-node/remove-node）
#   B. add-node 按角色选对 playbook
#   C. 节点不存在时报错且不调用 vagrant
#   D. down 的选项组合
#   E. kubeconfig 的节点名解析 + 产物必须是合法 YAML
#   F. 集群名不再硬编码
#   F2. 拉取失败 / 拉到非 kubeconfig 内容时报错
#   G. 仓库敏感文件未被测试改动

set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

K3S="${PROJECT_DIR}/k3s-ops.sh"
export VAGRANT_STUB_LOG="$(new_tmpdir)/vagrant.log"
export ANSIBLE_STUB_LOG="$(new_tmpdir)/ansible.log"
export KUBECTL_STUB_LOG="$(new_tmpdir)/kubectl.log"
trap cleanup_all EXIT

guard_stubs
REPO_FINGERPRINT_BEFORE="$(repo_fingerprint)"

section "A. 短名与完整主机名都应解析为 k3s-demo-agent-1"
for form in "agent-1" "k3s-demo-agent-1"; do
  check "down ${form}"            "halt k3s-demo-agent-1;" "" 0 -- "${K3S}" down "${form}"
  check "ssh ${form}"             "ssh k3s-demo-agent-1;"  "" 0 -- "${K3S}" ssh "${form}"
  check "up ${form}"              "up k3s-demo-agent-1;"   "" 0 -- "${K3S}" up "${form}"
  check "add-node ${form}"        "" "*/k3s-add-agent.yml -l k3s-demo-agent-1;" 0 -- "${K3S}" add-node "${form}"
  check "remove-node -n ${form}"  "" "*/k3s-remove-node.yml -l k3s-demo-agent-1;" 0 -- "${K3S}" remove-node -n "${form}"
done

section "B. add-node 按角色选对 playbook"
for form in "server-1" "k3s-demo-server-1"; do
  check "add-node ${form}" "" "*/k3s-add-server.yml -l k3s-demo-server-1;" 0 -- "${K3S}" add-node "${form}"
done

section "C. 不存在的节点应报错且不调用 vagrant"
for cmd in down ssh up add-node; do
  check "${cmd} bogus" "NONE" "NONE" 1 -- "${K3S}" "${cmd}" bogus
done
check "remove-node -n bogus" "NONE" "NONE" 1 -- "${K3S}" remove-node -n bogus
check "down k3s-demo-agent-9（带前缀但不存在）" "NONE" "NONE" 1 -- "${K3S}" down k3s-demo-agent-9

section "D. down 选项"
check "down（无参数）→ halt"              "halt;"    "" 0 -- "${K3S}" down
check "down -f → halt -f"                 "halt -f;" "" 0 -- "${K3S}" down -f
check "down -s → suspend"                 "suspend;" "" 0 -- "${K3S}" down -s
check "down --force → 长选项"              "halt -f;" "" 0 -- "${K3S}" down --force
check "down --suspend → 长选项"            "suspend;" "" 0 -- "${K3S}" down --suspend
check "down agent-1 -f（选项顺序颠倒）"    "halt -f k3s-demo-agent-1;" "" 0 -- "${K3S}" down agent-1 -f
check "down -f -s（互斥）"                "NONE" "NONE" 1 -- "${K3S}" down -f -s
check "down -x（未知选项）"                "NONE" "NONE" 1 -- "${K3S}" down -x
check "down a b（位置参数过多）"            "NONE" "NONE" 1 -- "${K3S}" down a b
check "down（缺参数时打印 usage）"          "NONE" "NONE" 0 -- "${K3S}" down --help

section "E. kubeconfig：节点名解析 + 产物必须是合法 YAML"
KUBE_TMP="$(new_tmpdir)"
for form in "__default__" "server-1" "k3s-demo-server-1"; do
  : > "${VAGRANT_STUB_LOG}"
  rm -f "${KUBE_TMP}/kubeconfig"
  if [ "${form}" = "__default__" ]; then
    ( cd "${KUBE_TMP}" && "${K3S}" kubeconfig ) >/dev/null 2>&1
    label="<默认 server-1>"
  else
    ( cd "${KUBE_TMP}" && "${K3S}" kubeconfig "${form}" ) >/dev/null 2>&1
    label="${form}"
  fi

  got_v="$(sed 's/^VAGRANT_CALL: //' "${VAGRANT_STUB_LOG}" | tr '\n' ';')"
  if [[ "${got_v}" == *k3s-demo-k3s-demo* ]]; then
    # 历史 bug：集群名硬编码 + 前缀重复拼接
    bad "kubeconfig ${label} → 主机名出现双前缀: ${got_v}"
  elif ! [[ "${got_v}" == *"ssh k3s-demo-server-1"* ]]; then
    bad "kubeconfig ${label} → 未连到 k3s-demo-server-1: ${got_v}"
  else
    ok "kubeconfig ${label} → 解析到 k3s-demo-server-1"
    assert_yaml_file "${KUBE_TMP}/kubeconfig" "kubeconfig ${label} → 产物是合法 YAML"
    assert_no_log_pollution "${KUBE_TMP}/kubeconfig" "kubeconfig ${label} → 产物未混入日志"
  fi
done
check "kubeconfig bogus" "NONE" "NONE" 1 -- "${K3S}" kubeconfig bogus

section "F. 集群名不再硬编码（换 cluster_name 后主机名随之变化）"
FAKE="$(new_tmpdir)"
mkdir -p "${FAKE}/vagrant"
sed 's/^cluster_name: .*/cluster_name: my-cluster/' "${PROJECT_DIR}/vagrant/nodes.yml" > "${FAKE}/vagrant/nodes.yml"
DEST_TMP="$(new_tmpdir)/kubeconfig"
: > "${VAGRANT_STUB_LOG}"
NODES_DIR="${FAKE}" bash "${PROJECT_DIR}/scripts/get-kubeconfig.sh" server-1 "${DEST_TMP}" >/dev/null 2>&1
if grep -qa 'ssh my-cluster-server-1' "${VAGRANT_STUB_LOG}"; then
  ok "cluster_name=my-cluster 时主机名变为 my-cluster-server-1"
else
  bad "集群名仍被硬编码: $(cat "${VAGRANT_STUB_LOG}" | tr '\n' ';')"
fi

section "F2. 拉取失败 / 内容非 kubeconfig 时应报错退出"
# vagrant 返回非 0
BAD_STUB="$(new_tmpdir)"
printf '#!/bin/bash\nexit 1\n' > "${BAD_STUB}/vagrant"
chmod +x "${BAD_STUB}/vagrant"
BAD_DEST="$(new_tmpdir)/kubeconfig"
PATH="${BAD_STUB}:${PATH}" bash "${PROJECT_DIR}/scripts/get-kubeconfig.sh" server-1 "${BAD_DEST}" >/dev/null 2>&1
if [ ! -s "${BAD_DEST}" ]; then
  ok "vagrant 失败时报错且不留下半成品文件"
else
  bad "vagrant 失败却写出了文件（$(wc -c < "${BAD_DEST}" 2>/dev/null) 字节）"
fi

# vagrant 返回 0 但内容是错误信息（例如权限不足的 Permission denied）
JUNK_STUB="$(new_tmpdir)"
printf '#!/bin/bash\necho "cat: /etc/rancher/k3s/k3s.yaml: Permission denied"\nexit 0\n' > "${JUNK_STUB}/vagrant"
chmod +x "${JUNK_STUB}/vagrant"
JUNK_DEST="$(new_tmpdir)/kubeconfig"
out="$(PATH="${JUNK_STUB}:${PATH}" bash "${PROJECT_DIR}/scripts/get-kubeconfig.sh" server-1 "${JUNK_DEST}" 2>&1)"; rc=$?
if [ "${rc}" -ne 0 ] && grep -q 'not a valid kubeconfig' <<< "${out}"; then
  ok "拉到非 kubeconfig 内容时报错（权限问题不会再静默通过）"
else
  bad "非 kubeconfig 内容未被拦截 (rc=${rc}): ${out}"
fi

section "G. status 命令在宿主机可执行（health-check 日志路径可写）"
STATUS_LOG="$(new_tmpdir)/health-check.log"
out="$(LOG_FILE="${STATUS_LOG}" KUBECONFIG="${PROJECT_DIR}/kubeconfig" \
        bash "${PROJECT_DIR}/ansible/files/health-check.sh" 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ] && [ -s "${STATUS_LOG}" ]; then
  ok "health-check.sh 以非 root 运行成功并写入指定 LOG_FILE"
else
  bad "health-check.sh 失败 rc=${rc}: ${out}"
fi
# 不传 LOG_FILE 时应自动降级而不是崩溃
rm -f /tmp/k3s-health.log
out="$(TMPDIR="$(new_tmpdir)" bash "${PROJECT_DIR}/ansible/files/health-check.sh" 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ]; then
  ok "health-check.sh 在 /var/log 不可写时自动降级，退出码 0"
else
  bad "health-check.sh 降级失败 rc=${rc}: ${out}"
fi

section "H. 仓库敏感文件未被测试改动"
assert_repo_untouched

finish "test-node-names"
