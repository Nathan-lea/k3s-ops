#!/bin/bash
# =============================================================================
# production/ 共享配置库
# =============================================================================
# 用法: source production/lib/config.sh
#
# 提供:
#   PROD_DIR / ROLES_DIR / ANSIBLE_DIR / INVENTORY_DIR / STATE_DIR
#   CHARTS_DIR / ARTIFACTS_DIR / LOG_DIR / LOG_FILE
#   prod_validate_config   — 校验主配置的取值与互斥关系（失败即退出）
#   prod_bool <value>      — true/1/yes/on → 0，其余 → 1
#   prod_require_cmd <cmd> — 缺命令即退出
#   prod_log_path          — 打印本次运行的日志路径
#
# 读取顺序（后者覆盖前者）:
#   1) 调用方的环境变量（最高优先级，便于 CI 覆盖）
#   2) config/cluster.env
#   3) config/cluster.env.local
#
# 注意: 本文件会被其他脚本 source，所以这里不设置 set -e，由调用方决定。
# =============================================================================

PROD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROD_DIR="$(cd "${PROD_LIB_DIR}/.." && pwd)"

# production/ 是自包含目录：roles 与日志库都在自己树内，可整体拷走
ROLES_DIR="${PROD_DIR}/ansible/roles"
ANSIBLE_DIR="${PROD_DIR}/ansible"
INVENTORY_DIR="${ANSIBLE_DIR}/inventory"
PLAYBOOK_DIR="${ANSIBLE_DIR}/playbooks"
ANSIBLE_CFG="${ANSIBLE_DIR}/ansible.cfg"
STATE_DIR="${PROD_DIR}/.state"
CHARTS_DIR="${PROD_DIR}/charts"
LOG_DIR="${PROD_DIR}/logs"
LOG_FILE="${LOG_DIR}/production.log"

CONFIG_FILE="${PROD_DIR}/config/cluster.env"
# 允许外部覆盖主配置路径（自测 / CI 用；正常运行就是 config/cluster.env）
if [ -n "${PROD_CONFIG_FILE:-}" ]; then
  CONFIG_FILE="${PROD_CONFIG_FILE}"
fi
CONFIG_LOCAL_FILE="${PROD_DIR}/config/cluster.env.local"
# 允许调用方预先指定 ipam 文件（自测 / CI 用；正常运行就是 config/ipam.yml）
IPAM_FILE="${IPAM_FILE:-${PROD_DIR}/config/ipam.yml}"

# =============================================================================
# 1. 记住调用方显式设置的环境变量（它们优先级最高）
# =============================================================================
_PROD_OVERRIDE_KEYS=(
  CLUSTER_NAME CLUSTER_DOMAIN
  K3S_VERSION K3S_CHANNEL_URL K3S_INSTALL_MODE K3S_DOWNLOAD_URL
  CNI POD_CIDR SVC_CIDR DISABLE_TRAEFIK DISABLE_SERVICELB TAINT_SERVER
  SSH_PORT INIT_SSH_PORT INIT_SSH_USER INIT_SSH_PASSWORD OPS_USER OPS_SSH_KEY
  OPS_SUDO_NOPASSWD DISABLE_ROOT_SSH_AFTER_INIT ROOT_SSH_POLICY
  TIMEZONE CHRONY_SERVERS APT_UPDATE_CACHE USE_UFW UFW_ALLOW_CIDR ENABLE_LIMITS
  LOCALDISK_ENABLED LOCALDISK_PATH LOCALDISK_SC_NAME LOCALDISK_DEFAULT_SC
  LOCALDISK_RECLAIM_POLICY LOCALDISK_IMAGE LOCALDISK_HELPER_IMAGE
  STORAGE_NFS_ENABLED IN_CLUSTER_NFS NFS_SERVER NFS_PATH NFS_VERSION
  NFS_SC_NAME NFS_RECLAIM_POLICY NFS_ARCHIVE_ON_DELETE NFS_PROVISIONER_IMAGE NFS_DEFAULT_SC
  INGRESS_ENABLED INGRESS_CHART_VERSION INGRESS_KIND
  INGRESS_HTTP_PORT INGRESS_HTTPS_PORT INGRESS_NODE_SELECTOR
  CERT_MANAGER_ENABLED CERT_MANAGER_CHART_VERSION ACME_EMAIL
  RANCHER_ENABLED RANCHER_CHART_VERSION RANCHER_HOSTNAME RANCHER_REPLICAS
  RANCHER_BOOTSTRAP_PASSWORD RANCHER_TLS_SOURCE
  CHARTS_MODE ARTIFACTS_DIR REGISTRY_MIRRORS REGISTRY_ENDPOINT
  REGISTRY_PATH_PREFIX REGISTRY_USERNAME REGISTRY_PASSWORD
  HELM_VERSION HELM_DOWNLOAD_URL HELM_BIN
)

declare -A _PROD_SAVED=()
for _k in "${_PROD_OVERRIDE_KEYS[@]}"; do
  if [ -n "${!_k+set}" ]; then _PROD_SAVED["$_k"]="${!_k}"; fi
done
unset _k

# =============================================================================
# 2. 默认值（文件缺失时也能跑出可读的错误）
# =============================================================================
: "${CLUSTER_NAME:=}"
: "${CLUSTER_DOMAIN:=}"
: "${K3S_VERSION:=latest}"
: "${K3S_CHANNEL_URL:=https://update.k3s.io/v1-release/channels/stable}"
: "${K3S_INSTALL_MODE:=online}"
: "${K3S_DOWNLOAD_URL:=}"
: "${CNI:=flannel}"
: "${POD_CIDR:=10.42.0.0/16}"
: "${SVC_CIDR:=10.43.0.0/16}"
: "${DISABLE_TRAEFIK:=true}"
: "${DISABLE_SERVICELB:=true}"
: "${TAINT_SERVER:=false}"
: "${SSH_PORT:=22}"
# 首次用 root 连上去时节点还在系统默认端口；SSH_PORT 是"收紧之后"ops 用的端口
: "${INIT_SSH_PORT:=22}"
: "${INIT_SSH_USER:=root}"
: "${INIT_SSH_PASSWORD:=}"
: "${OPS_USER:=ops}"
: "${OPS_SSH_KEY:=}"
: "${OPS_SUDO_NOPASSWD:=true}"
: "${DISABLE_ROOT_SSH_AFTER_INIT:=true}"
: "${ROOT_SSH_POLICY:=prohibit-password}"
: "${TIMEZONE:=Asia/Shanghai}"
: "${CHRONY_SERVERS:=}"
: "${APT_UPDATE_CACHE:=true}"
: "${USE_UFW:=true}"
: "${UFW_ALLOW_CIDR:=}"
: "${ENABLE_LIMITS:=true}"
# 仅 scale.sh remove 使用：要摘除的节点名（空表示不摘除任何节点）
: "${PROD_REMOVE_TARGET:=}"
: "${LOCALDISK_ENABLED:=true}"
: "${LOCALDISK_PATH:=/opt/k8s-local-path}"
: "${LOCALDISK_SC_NAME:=localdisk}"
: "${LOCALDISK_DEFAULT_SC:=true}"
: "${LOCALDISK_RECLAIM_POLICY:=Retain}"
: "${LOCALDISK_IMAGE:=rancher/local-path-provisioner:v0.0.30}"
: "${LOCALDISK_HELPER_IMAGE:=rancher/mirrored-library-busybox:1.36.1}"
: "${STORAGE_NFS_ENABLED:=true}"
: "${IN_CLUSTER_NFS:=false}"
: "${NFS_SERVER:=}"
: "${NFS_PATH:=/nfs-share}"
: "${NFS_VERSION:=4}"
: "${NFS_SC_NAME:=nfs-client}"
: "${NFS_RECLAIM_POLICY:=Delete}"
: "${NFS_ARCHIVE_ON_DELETE:=false}"
: "${NFS_PROVISIONER_IMAGE:=registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2}"
: "${NFS_DEFAULT_SC:=false}"
: "${INGRESS_ENABLED:=true}"
: "${INGRESS_CHART_VERSION:=4.11.0}"
: "${INGRESS_KIND:=DaemonSet}"
: "${INGRESS_HTTP_PORT:=80}"
: "${INGRESS_HTTPS_PORT:=443}"
: "${INGRESS_NODE_SELECTOR:=}"
: "${CERT_MANAGER_ENABLED:=true}"
: "${CERT_MANAGER_CHART_VERSION:=v1.20.2}"
: "${ACME_EMAIL:=}"
: "${RANCHER_ENABLED:=true}"
: "${RANCHER_CHART_VERSION:=2.15.2}"
: "${RANCHER_HOSTNAME:=}"
: "${RANCHER_REPLICAS:=1}"
: "${RANCHER_BOOTSTRAP_PASSWORD:=}"
: "${RANCHER_TLS_SOURCE:=rancher}"
: "${CHARTS_MODE:=local}"
: "${ARTIFACTS_DIR:=artifacts}"
: "${REGISTRY_MIRRORS:=}"
: "${REGISTRY_ENDPOINT:=}"
: "${REGISTRY_PATH_PREFIX:=}"
: "${REGISTRY_USERNAME:=}"
: "${REGISTRY_PASSWORD:=}"
: "${HELM_VERSION:=v3.16.3}"
: "${HELM_DOWNLOAD_URL:=}"
: "${HELM_BIN:=}"

# =============================================================================
# 3. 加载配置文件
# =============================================================================
if [ -f "${CONFIG_FILE}" ]; then
  # shellcheck disable=SC1090
  . "${CONFIG_FILE}"
else
  echo "[ERROR] 找不到主配置: ${CONFIG_FILE}" >&2
  return 1 2>/dev/null || exit 1
fi

if [ -f "${CONFIG_LOCAL_FILE}" ]; then
  # shellcheck disable=SC1090
  . "${CONFIG_LOCAL_FILE}"
fi

# 4. 把调用方的环境变量放回最高优先级
for _k in "${!_PROD_SAVED[@]}"; do
  printf -v "$_k" '%s' "${_PROD_SAVED[$_k]}"
done
unset _k

# =============================================================================
# 5. 归一化
# =============================================================================
# ARTIFACTS_DIR 允许相对路径（相对 production/）
case "${ARTIFACTS_DIR}" in
  /*) ;;
  *) ARTIFACTS_DIR="${PROD_DIR}/${ARTIFACTS_DIR}" ;;
esac

# CLUSTER_DOMAIN 留空则取 ipam.yml 的 domain
if [ -z "${CLUSTER_DOMAIN}" ] && [ -f "${IPAM_FILE}" ]; then
  CLUSTER_DOMAIN="$(python3 -c "
import yaml
with open('${IPAM_FILE}') as f:
    print((yaml.safe_load(f) or {}).get('domain') or '')
" 2>/dev/null || true)"
fi

# RANCHER_HOSTNAME 缺省 = rancher.<domain>；domain 也没有就留空（后面校验会提示）
if [ -z "${RANCHER_HOSTNAME}" ] && [ -n "${CLUSTER_DOMAIN}" ]; then
  RANCHER_HOSTNAME="rancher.${CLUSTER_DOMAIN}"
fi

# 变量引用未展开的兜底：cluster.env 里写 `rancher.${CLUSTER_DOMAIN}` 而 domain 为空时
case "${RANCHER_HOSTNAME}" in
  *'${'*|'') RANCHER_HOSTNAME="" ;;
esac

# 运维私钥：留空则用固定路径（ssh-setup.sh 会生成它）
if [ -z "${OPS_SSH_KEY}" ]; then
  OPS_SSH_KEY="${STATE_DIR}/ops_id_ed25519"
fi

# k3s 解析后的版本（preflight 阶段由 prod_resolve_k3s_version 填写）
: "${K3S_RESOLVED_VERSION:=}"

# 日志库（自带实现，自包含所需）。它会强制 LOG_FILE=${LOG_DIR}/k3s-ops.log，
# 所以这里先把我们要的文件名存下来，加载完再改回去（LOG_DIR 它用 `:-` 不会覆盖）。
_PROD_LOG_FILE="${LOG_FILE}"
# shellcheck source=logging.sh
. "${PROD_LIB_DIR}/logging.sh"
LOG_FILE="${_PROD_LOG_FILE}"
unset _PROD_LOG_FILE

# Ansible 期望的环境变量
export ANSIBLE_CONFIG="${ANSIBLE_CFG}"
export ANSIBLE_ROLES_PATH="${ROLES_DIR}"

# =============================================================================
# 工具函数
# =============================================================================

# 布尔判定: true/1/yes/on（大小写不敏感）→ 0
prod_bool() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

prod_require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    if declare -F log_error >/dev/null 2>&1; then
      log_error "缺少依赖命令: $1${2:+（$2）}"
    else
      echo "[ERROR] 缺少依赖命令: $1${2:+（$2）}" >&2
    fi
    exit 1
  fi
}

prod_log_path() { printf '%s' "${LOG_FILE}"; }

# 判断某变量是否还是示例占位值
_prod_is_placeholder() {
  case "$1" in
    ""|*example.com*|xxx-k8s*|*ChangeMe*) return 0 ;;
    *) return 1 ;;
  esac
}

# =============================================================================
# 配置校验（bootstrap.sh / scale.sh 都会调）
# =============================================================================
prod_validate_config() {
  local rc=0
  local msg

  _fail() { log_error "配置错误: $1"; rc=1; }

  [ -n "${CLUSTER_NAME}" ] || _fail "CLUSTER_NAME 不能为空（config/cluster.env）"
  # 空值尤其要拦：默认值是在读文件之前套用的，文件里显式写空会绕过默认值
  case "${K3S_VERSION}" in
    '') _fail "K3S_VERSION 不能为空（写 latest 走 stable channel，或写具体版本如 v1.31.4+k3s1）" ;;
    latest|stable|testing) ;;
    v[0-9]*.*) ;;
    *) _fail "K3S_VERSION 格式不对（当前: ${K3S_VERSION}）：应为 latest/stable/testing 或 vMAJOR.MINOR.PATCH[+k3sN]" ;;
  esac
  case "${K3S_INSTALL_MODE}" in
    online|offline) ;;
    *) _fail "K3S_INSTALL_MODE 只能是 online 或 offline（当前: ${K3S_INSTALL_MODE}）" ;;
  esac
  case "${CNI}" in
    flannel|none) ;;
    *) _fail "CNI 只能是 flannel 或 none（当前: ${CNI}）" ;;
  esac
  case "${ROOT_SSH_POLICY}" in
    prohibit-password|no|yes) ;;
    *) _fail "ROOT_SSH_POLICY 只能是 prohibit-password / no / yes（当前: ${ROOT_SSH_POLICY}）" ;;
  esac
  case "${RANCHER_TLS_SOURCE}" in
    rancher|letsEncrypt|secret) ;;
    *) _fail "RANCHER_TLS_SOURCE 只能是 rancher / letsEncrypt / secret（当前: ${RANCHER_TLS_SOURCE}）" ;;
  esac
  case "${CHARTS_MODE}" in
    local|repo) ;;
    *) _fail "CHARTS_MODE 只能是 local 或 repo（当前: ${CHARTS_MODE}）" ;;
  esac
  case "${INGRESS_KIND}" in
    DaemonSet|Deployment) ;;
    *) _fail "INGRESS_KIND 只能是 DaemonSet 或 Deployment（当前: ${INGRESS_KIND}）" ;;
  esac
  case "${SSH_PORT}" in
    ''|*[!0-9]*) _fail "SSH_PORT 必须是数字（当前: ${SSH_PORT}）" ;;
    *) [ "${SSH_PORT}" -ge 1 ] && [ "${SSH_PORT}" -le 65535 ] || _fail "SSH_PORT 超出范围（当前: ${SSH_PORT}）" ;;
  esac
  case "${INIT_SSH_PORT}" in
    ''|*[!0-9]*) _fail "INIT_SSH_PORT 必须是数字（当前: ${INIT_SSH_PORT}）" ;;
    *) [ "${INIT_SSH_PORT}" -ge 1 ] && [ "${INIT_SSH_PORT}" -le 65535 ] || _fail "INIT_SSH_PORT 超出范围（当前: ${INIT_SSH_PORT}）" ;;
  esac

  if prod_bool "${LOCALDISK_ENABLED}"; then
    [ -n "${LOCALDISK_PATH}" ] || _fail "LOCALDISK_ENABLED=true 时 LOCALDISK_PATH 不能为空"
    case "${LOCALDISK_PATH}" in
      /*) ;;
      *) _fail "LOCALDISK_PATH 必须是绝对路径（当前: ${LOCALDISK_PATH}）" ;;
    esac
    case "${LOCALDISK_RECLAIM_POLICY}" in
      Retain|Delete) ;;
      *) _fail "LOCALDISK_RECLAIM_POLICY 只能是 Retain 或 Delete" ;;
    esac
  fi

  if prod_bool "${LOCALDISK_DEFAULT_SC}" && prod_bool "${NFS_DEFAULT_SC}"; then
    _fail "LOCALDISK_DEFAULT_SC 与 NFS_DEFAULT_SC 不能同时为 true（一个集群只应有一个默认 StorageClass）"
  fi

  if prod_bool "${STORAGE_NFS_ENABLED}"; then
    if [ -z "${NFS_PATH}" ]; then
      _fail "STORAGE_NFS_ENABLED=true 时 NFS_PATH 不能为空"
    fi
    if ! prod_bool "${IN_CLUSTER_NFS}"; then
      if _prod_is_placeholder "${NFS_SERVER}"; then
        _fail "NFS_SERVER 还是占位值（'${NFS_SERVER}'）。请填真实 NFS 服务器，或把 STORAGE_NFS_ENABLED 改成 false"
      fi
    fi
    case "${NFS_VERSION}" in
      ''|*[!0-9]*) _fail "NFS_VERSION 必须是数字（当前: ${NFS_VERSION}）" ;;
    esac
  else
    if prod_bool "${NFS_DEFAULT_SC}"; then
      _fail "NFS_DEFAULT_SC=true 要求 STORAGE_NFS_ENABLED=true（否则没有 nfs-client StorageClass）"
    fi
    if prod_bool "${IN_CLUSTER_NFS}"; then
      _fail "IN_CLUSTER_NFS=true 要求 STORAGE_NFS_ENABLED=true（集群内 NFS 就是给 nfs-client 用的）"
    fi
  fi

  if prod_bool "${RANCHER_ENABLED}"; then
    if [ -z "${RANCHER_HOSTNAME}" ]; then
      _fail "RANCHER_ENABLED=true 时 RANCHER_HOSTNAME 不能为空（设置 CLUSTER_DOMAIN 或直接写 RANCHER_HOSTNAME）"
    fi
    [ -n "${RANCHER_BOOTSTRAP_PASSWORD}" ] || _fail "RANCHER_ENABLED=true 时 RANCHER_BOOTSTRAP_PASSWORD 不能为空"
    # rancher chart 自身不含 cert-manager 子 chart：CRD 缺失时证书签不出来，直接拦在配置阶段
    if [ "${RANCHER_TLS_SOURCE}" != "secret" ] && ! prod_bool "${CERT_MANAGER_ENABLED}"; then
      _fail "RANCHER_TLS_SOURCE=${RANCHER_TLS_SOURCE} 需要集群已安装 cert-manager（CERT_MANAGER_ENABLED=true）"
    fi
  fi

  if prod_bool "${CERT_MANAGER_ENABLED}" && [ -n "${ACME_EMAIL}" ]; then
    case "${ACME_EMAIL}" in
      *@*.*) ;;
      *) _fail "ACME_EMAIL 看起来不是邮箱（当前: ${ACME_EMAIL}）" ;;
    esac
  fi

  if [ "${K3S_INSTALL_MODE}" = "offline" ] && [ ! -x "${ARTIFACTS_DIR}/k3s" ]; then
    msg="${ARTIFACTS_DIR}/k3s 不存在或不可执行"
    _fail "${msg}（K3S_INSTALL_MODE=offline）"
  fi

  # 自带 roles / 日志库必须齐全（缺失说明拷贝不完整）
  if [ ! -d "${ROLES_DIR}/k3s-common" ]; then
    _fail "找不到自带 roles: ${ROLES_DIR}/k3s-common（production/ 拷贝不完整）"
  fi
  if [ ! -f "${PROD_LIB_DIR}/logging.sh" ]; then
    _fail "找不到自带日志库: ${PROD_LIB_DIR}/logging.sh（production/ 拷贝不完整）"
  fi

  return "${rc}"
}

# =============================================================================
# k3s 版本解析（bootstrap 的 preflight 步骤调用）
# =============================================================================
# K3S_VERSION=latest 时通过 K3S_CHANNEL_URL 拿到当前稳定版；channel 端点返回的是
# 一个 HTML 跳转页（不是 302），所以先试 redirect_url，再退回正则抓取正文。
prod_resolve_k3s_version() {
  if [ -n "${K3S_RESOLVED_VERSION:-}" ]; then
    return 0
  fi

  if [ "${K3S_VERSION}" != "latest" ]; then
    K3S_RESOLVED_VERSION="${K3S_VERSION}"
    log_info "k3s 版本（配置指定）: ${K3S_RESOLVED_VERSION}"
    return 0
  fi

  if [ "${K3S_INSTALL_MODE}" = "offline" ]; then
    if [ -f "${ARTIFACTS_DIR}/k3s.version" ]; then
      K3S_RESOLVED_VERSION="$(tr -d '[:space:]' < "${ARTIFACTS_DIR}/k3s.version")"
      log_info "k3s 版本（离线制品 k3s.version）: ${K3S_RESOLVED_VERSION}"
      return 0
    fi
    log_error "K3S_VERSION=latest 且 K3S_INSTALL_MODE=offline，但 ${ARTIFACTS_DIR}/k3s.version 不存在"
    log_error "  修复: 在有网的机器上跑 scripts/fetch-artifacts.sh，或把 K3S_VERSION 钉成具体版本"
    return 1
  fi

  prod_require_cmd curl
  local loc body
  loc="$(curl -sS -o /dev/null -w '%{redirect_url}' --max-time 20 "${K3S_CHANNEL_URL}" 2>/dev/null || true)"
  case "${loc}" in
    */tag/*) K3S_RESOLVED_VERSION="${loc##*/tag/}" ;;
  esac

  if [ -z "${K3S_RESOLVED_VERSION}" ]; then
    body="$(curl -sS --max-time 20 "${K3S_CHANNEL_URL}" 2>/dev/null || true)"
    K3S_RESOLVED_VERSION="$(printf '%s' "${body}" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+' | head -n1)"
  fi

  case "${K3S_RESOLVED_VERSION}" in
    v[0-9]*+k3s[0-9]*)
      log_info "k3s 版本（stable channel 解析）: ${K3S_RESOLVED_VERSION}"
      ;;
    *)
      log_error "无法从 ${K3S_CHANNEL_URL} 解析 k3s 稳定版（得到: '${K3S_RESOLVED_VERSION}'）"
      log_error "  修复: 检查网络，或把 K3S_VERSION 直接钉成版本号（如 v1.36.5+k3s1）"
      K3S_RESOLVED_VERSION=""
      return 1
      ;;
  esac
}
