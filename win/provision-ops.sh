#!/usr/bin/env bash
# =============================================================================
# provision-ops.sh —— 在工作机（role: ops）里引导整套操作环境（幂等）
# =============================================================================
# 由 Windows 侧的 win/up.ps1 通过 `vagrant ssh k3s-demo-ops -c ...` 调用，
# 也可以在工作机里手动重跑：
#
#   bash /vagrant/win/provision-ops.sh
#   bash /vagrant/win/provision-ops.sh --skip-apt      # apt 已装好
#   bash /vagrant/win/provision-ops.sh --skip-tools    # 跳过 kubectl/helm 下载
#
# 做 8 件事：
#   1. 装系统依赖（python3-venv / pip / rsync / curl / python3-yaml）
#   2. 建独立 venv 装 ansible-core + community.general/ansible.posix/kubernetes.core
#   3. 把仓库 rsync 到 ~/k3s-ops（不放 /vagrant 跑：vboxsf 是 0777，Ansible 拒绝）
#   4. 用 Windows 拓扑覆盖副本里的 vagrant/nodes.yml
#   5. 复制节点私钥到 ~/.ssh/k3s-ops/<host> 并 chmod 600
#   6. 生成 ansible/inventory.yml（scripts/gen-inventory.py）与 shim 映射 JSON
#   7. 装 kubectl / helm，并把 helm 分发到各个集群节点（deploy playbook 在节点上跑 helm）
#   8. 把 vagrant shim 装到 /usr/local/bin/vagrant
#
# 为什么 helm 要分发到节点：ansible/playbooks/nginx-ingress-deploy.yml 与
# rancher-deploy.yml 是 hosts: server[0]，helm 命令实际在 server-1 上执行，
# 而它们的 helm bootstrap 走 raw.githubusercontent.com —— 本网络不可达。
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../lib/logging.sh
source "${SRC_DIR}/lib/logging.sh"

DEST="${K3S_OPS_DEST:-$HOME/k3s-ops}"
KEY_DIR="$HOME/.ssh/k3s-ops"
VENV="$HOME/.venv/k3s-ops"
LOCAL_BIN="$HOME/.local/bin"
SHIM_JSON="$HOME/.k3s-ops-shim.json"
HELM_VERSION="${HELM_VERSION:-v3.16.3}"
HELM_SETUP="${SRC_DIR}/production/ansible/files/helm-setup.sh"

SKIP_APT=0
SKIP_TOOLS=0
LOG_DIR="${LOG_DIR:-$HOME/k3s-ops/logs}"

usage() {
  sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-apt)   SKIP_APT=1 ;;
    --skip-tools) SKIP_TOOLS=1 ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
  shift
done

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"
fi

TOTAL_STEPS=8
STEP=0
step() {
  STEP=$((STEP + 1))
  echo
  log_info "[${STEP}/${TOTAL_STEPS}] $*"
}

die() {
  log_error "$*"
  exit 1
}

# 读拓扑：nodes_field <python 表达式，变量 n 为节点 dict> → 每行一个结果
nodes_field() {
  python3 - "${NODES_FILE}" "$1" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
expr = sys.argv[2]
for n in cfg.get("nodes") or []:
    print(eval(expr, {"__builtins__": {}}, {"n": n}))
PY
}

# 读拓扑：每行 "<name> <ip>"，工作机（role: ops）被排除
nodes_pairs() {
  python3 - "${NODES_FILE}" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
for n in cfg.get("nodes") or []:
    if n.get("role") in ("server", "agent"):
        print("%s %s" % (n["name"], n["ip"]))
PY
}

cluster_name() {
  python3 - "${NODES_FILE}" <<'PY'
import sys, yaml
print(yaml.safe_load(open(sys.argv[1], encoding="utf-8"))["cluster_name"])
PY
}

# ===== 1. 系统依赖 =====
step_apt() {
  if [ "${SKIP_APT}" = "1" ]; then
    log_info "跳过 apt（--skip-apt）"
    return 0
  fi
  export DEBIAN_FRONTEND=noninteractive
  log_info "apt-get update"
  ${SUDO} apt-get update -qq || die "apt-get update 失败（检查网络或换源）"
  log_info "安装 python3-venv / python3-pip / python3-yaml / rsync / curl"
  ${SUDO} apt-get install -y -qq \
    python3-venv python3-pip python3-yaml rsync curl ca-certificates openssh-client \
    || die "apt-get install 失败"
}

# ===== 2. Ansible =====
step_ansible() {
  if [ ! -x "${VENV}/bin/ansible-playbook" ]; then
    log_info "创建 venv: ${VENV}"
    python3 -m venv "${VENV}" || die "python3 -m venv 失败"
  fi

  # 钉在 <2.18：Ubuntu 22.04 的控制节点 Python 是 3.10，ansible-core 2.18+ 要求 3.11+
  if ! "${VENV}/bin/ansible-playbook" --version >/dev/null 2>&1; then
    log_info "安装 ansible-core（首次会下载几十 MB）"
    "${VENV}/bin/pip" install -q --upgrade pip
    "${VENV}/bin/pip" install -q "ansible-core>=2.16,<2.18" pyyaml kubernetes \
      || die "pip 安装 ansible-core 失败（检查 pypi 可达性）"
  else
    log_info "ansible 已就绪: $("${VENV}/bin/ansible-playbook" --version | head -1)"
  fi

  # 合集缺失时才装；已装则跳过（幂等）
  local missing
  missing="$("${VENV}/bin/ansible-galaxy" collection list 2>/dev/null \
    | grep -E '^(community\.general|ansible\.posix|kubernetes\.core) ' | wc -l)"
  if [ "${missing}" -lt 3 ]; then
    log_info "安装 Ansible 合集（community.general / ansible.posix / kubernetes.core）"
    "${VENV}/bin/ansible-galaxy" collection install -q \
      community.general ansible.posix kubernetes.core \
      || die "ansible-galaxy 安装合集失败（检查 galaxy.ansible.com 可达性）"
  else
    log_info "Ansible 合集已就绪"
  fi
}

# ===== 3. 仓库副本 =====
step_rsync() {
  if [ ! -d /vagrant ]; then
    log_warn "/vagrant 不存在：手动运行时会退回使用当前仓库 ${SRC_DIR}"
  fi
  mkdir -p "${DEST}"
  log_info "同步 ${SRC_DIR} → ${DEST}"
  # -rlt 而不是 -a：vboxsf 不支持改属主/权限，-a 会刷一堆错误
  rsync -rlt --delete \
    --exclude '.git/' --exclude '.vagrant/' --exclude 'logs/' --exclude 'kubeconfig' \
    --exclude '*.log' --exclude 'tmp/' \
    "${SRC_DIR}/" "${DEST}/" || die "rsync 失败"
  mkdir -p "${DEST}/logs"
}

# ===== 4. 拓扑 =====
step_nodes() {
  [ -f "${SCRIPT_DIR}/nodes.windows.yml" ] || die "找不到 ${SCRIPT_DIR}/nodes.windows.yml"
  install -m 0644 "${SCRIPT_DIR}/nodes.windows.yml" "${DEST}/vagrant/nodes.yml"
  log_info "拓扑已就位（含 ops 工作机，k3s-ops.sh 会按 role 过滤）"
}

# ===== 5. 私钥 =====
step_keys() {
  mkdir -p "${KEY_DIR}"
  chmod 700 "${KEY_DIR}"
  local name ip host key missing=0
  while read -r name ip; do
    [ -n "${name}" ] || continue
    host="$(cluster_name)-${name}"
    key="/vagrant/.vagrant/machines/${host}/virtualbox/private_key"
    if [ ! -f "${key}" ]; then
      log_warn "缺少私钥: ${key}"
      missing=1
      continue
    fi
    install -m 0600 "${key}" "${KEY_DIR}/${host}"
  done < <(nodes_pairs)

  if [ "${missing}" = "1" ]; then
    die "有节点私钥缺失。回 Windows 执行 win\\up.ps1（或 vagrant reload）后重试"
  fi
  log_info "私钥已就位: ${KEY_DIR}"
}

# ===== 6. inventory + shim 映射 =====
step_inventory() {
  export PATH="${VENV}/bin:${LOCAL_BIN}:${PATH}"
  log_info "生成 inventory"
  python3 "${DEST}/scripts/gen-inventory.py" \
    --nodes "${DEST}/vagrant/nodes.yml" \
    --key-dir "${KEY_DIR}" \
    --out "${DEST}/ansible/inventory.yml" \
    --check || die "inventory 生成失败"

  log_info "生成 shim 映射: ${SHIM_JSON}"
  python3 - "${DEST}/vagrant/nodes.yml" "${KEY_DIR}" "${SHIM_JSON}" <<'PY'
import json, os, sys, yaml

nodes_yml, key_dir, out = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = yaml.safe_load(open(nodes_yml, encoding="utf-8"))
cluster = cfg["cluster_name"]
data = {"cluster_name": cluster, "user": "vagrant", "nodes": {}}
for n in cfg.get("nodes") or []:
    host = "%s-%s" % (cluster, n["name"])
    data["nodes"][host] = {
        "short": n["name"],
        "ip": n["ip"],
        "user": "vagrant",
        "key": os.path.join(key_dir, host),
    }
with open(out, "w", encoding="utf-8", newline="\n") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=2, sort_keys=True)
    fh.write("\n")
PY
  [ -s "${SHIM_JSON}" ] || die "shim 映射生成失败"
}

# ===== 7. kubectl / helm =====
kubectl_version() {
  python3 - "${NODES_FILE}" <<'PY'
import re, sys, yaml
v = yaml.safe_load(open(sys.argv[1], encoding="utf-8")).get("k3s_version", "")
print("v" + v.lstrip("v").split("+")[0])
PY
}

install_kubectl() {
  local ver; ver="$(kubectl_version)"
  if command -v kubectl >/dev/null 2>&1 && kubectl version --client >/dev/null 2>&1 \
     && kubectl version --client 2>/dev/null | grep -q "${ver}"; then
    log_info "kubectl ${ver} 已就绪"
    return 0
  fi
  local target="${LOCAL_BIN}/kubectl"
  local first_name first_ip host
  read -r first_name first_ip < <(nodes_pairs | head -1)
  log_info "下载 kubectl ${ver}（dl.k8s.io）"
  if curl -fsSL --connect-timeout 20 --max-time 300 -o "${target}.part" \
      "https://dl.k8s.io/release/${ver}/bin/linux/amd64/kubectl"; then
    chmod 0755 "${target}.part"
    mv "${target}.part" "${target}"
    log_info "kubectl 安装完成: $("${target}" version --client | head -1)"
    return 0
  fi
  log_warn "dl.k8s.io 不可达，回退：从第一个 server 复制 k3s 二进制当 kubectl 用"
  rm -f "${target}.part"
  host="$(cluster_name)-${first_name}"
  if scp -q -i "${KEY_DIR}/${host}" -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null "vagrant@${first_ip}:/usr/local/bin/k3s" "${LOCAL_BIN}/k3s" 2>/dev/null; then
    chmod 0755 "${LOCAL_BIN}/k3s"
    ln -sf k3s "${target}"
    log_info "已用 k3s 二进制代替 kubectl（功能等价，只是版本号显示为 k3s）"
    return 0
  fi
  die "kubectl 获取失败：dl.k8s.io 与节点回退都不可用。请手动下载后放到 ${target}"
}

install_helm() {
  if [ ! -f "${HELM_SETUP}" ]; then
    log_warn "缺少 ${HELM_SETUP}，跳过 helm"
    return 0
  fi
  HELM_VERSION="${HELM_VERSION}" HELM_BIN="${LOCAL_BIN}/helm" \
    bash "${HELM_SETUP}" || die "helm 安装失败"
}

distribute_helm() {
  local helm_bin="${LOCAL_BIN}/helm"
  [ -x "${helm_bin}" ] || { log_warn "本机没有 helm，跳过分发"; return 0; }
  local name ip host
  while read -r name ip; do
    [ -n "${name}" ] || continue
    host="$(cluster_name)-${name}"
    if ssh -n -i "${KEY_DIR}/${host}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
         -o ConnectTimeout=10 "vagrant@${ip}" 'command -v helm >/dev/null && helm version --short' 2>/dev/null \
         | grep -q "${HELM_VERSION}"; then
      log_info "  ${host}: helm 已就绪"
      continue
    fi
    log_info "  ${host}: 分发 helm ${HELM_VERSION}"
    scp -q -i "${KEY_DIR}/${host}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "${helm_bin}" "vagrant@${ip}:/tmp/helm-k3s-ops" \
      || die "向 ${host} 传 helm 失败"
    ssh -n -i "${KEY_DIR}/${host}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "vagrant@${ip}" 'sudo install -m 0755 /tmp/helm-k3s-ops /usr/local/bin/helm && rm -f /tmp/helm-k3s-ops' \
      || die "${host} 上安装 helm 失败"
  done < <(nodes_pairs)
}

step_tools() {
  if [ "${SKIP_TOOLS}" = "1" ]; then
    log_info "跳过工具链（--skip-tools）"
    return 0
  fi
  mkdir -p "${LOCAL_BIN}"
  install_kubectl
  install_helm
  distribute_helm
}

# ===== 8. 环境变量 + shim =====
step_env() {
  local rc="$HOME/.bashrc"
  touch "${rc}"
  if ! grep -q 'k3s-ops >>>' "${rc}" 2>/dev/null; then
    cat >> "${rc}" <<EOF

# >>> k3s-ops >>>
# 工作机环境（由 win/provision-ops.sh 生成，删掉这一段即可还原）
export PATH="${VENV}/bin:${LOCAL_BIN}:\$PATH"
# 关键：k3s-ops.sh 会 cd 到仓库根目录再调 ansible-playbook，
# 不加这个变量就找不到 ansible/ansible.cfg → roles_path 失效 → install/add-node 全挂
export ANSIBLE_CONFIG="${DEST}/ansible/ansible.cfg"
export KUBECONFIG="${DEST}/kubeconfig"
# <<< k3s-ops <<<
EOF
    log_info "环境变量已写入 ${rc}"
  else
    log_info "环境变量已存在，跳过"
  fi

  local shim_src="${DEST}/win/guest/bin/vagrant"
  [ -f "${shim_src}" ] || shim_src="${SCRIPT_DIR}/guest/bin/vagrant"
  [ -f "${shim_src}" ] || die "找不到 shim 源文件 guest/bin/vagrant"
  if ! cmp -s "${shim_src}" /usr/local/bin/vagrant 2>/dev/null; then
    ${SUDO} install -m 0755 "${shim_src}" /usr/local/bin/vagrant
    log_info "vagrant shim 已安装到 /usr/local/bin/vagrant"
  else
    log_info "vagrant shim 已是最新"
  fi

  # 非交互 shell（vagrant ssh -c / ssh host cmd）不读 ~/.bashrc，需要 profile.d
  local profiled="/etc/profile.d/k3s-ops.sh"
  local tmp; tmp="$(mktemp)"
  {
    echo '# 由 k3s-ops win/provision-ops.sh 生成'
    echo "export PATH=\"${VENV}/bin:${LOCAL_BIN}:\$PATH\""
    echo "export ANSIBLE_CONFIG=\"${DEST}/ansible/ansible.cfg\""
    echo "export KUBECONFIG=\"${DEST}/kubeconfig\""
  } > "${tmp}"
  if ! cmp -s "${tmp}" "${profiled}" 2>/dev/null; then
    ${SUDO} install -m 0644 "${tmp}" "${profiled}"
    log_info "环境变量已写入 ${profiled}"
  else
    log_info "${profiled} 已是最新"
  fi
  rm -f "${tmp}"
}

# ===== 汇总 =====
main() {
  LOG_DIR="${LOG_DIR}" log_init
  NODES_FILE="${DEST}/vagrant/nodes.yml"

  if [ ! -d /vagrant ]; then
    log_warn "没有 /vagrant 挂载点：本脚本应在工作机（role: ops）里运行"
  fi

  step_apt
  step_ansible
  step_rsync
  # rsync 之后 DEST 才是完整副本，重新指向副本里的拓扑
  NODES_FILE="${DEST}/vagrant/nodes.yml"
  step_nodes
  step_keys
  step_inventory
  step_tools
  step_env

  echo
  log_info "工作机准备完成。下一步："
  echo "  cd ${DEST}"
  echo "  ./k3s-ops.sh install        # 首次安装集群（约 5-10 分钟）"
  echo "  ./k3s-ops.sh kubeconfig     # 把 127.0.0.1 改写成 192.168.56.10"
  echo "  kubectl get nodes"
}

main "$@"
