#!/usr/bin/env bash
# =============================================================================
# production/scripts/fetch-artifacts.sh —— 在能联网的机器上准备离线制品
# =============================================================================
# 干的事（在**能访问互联网**的机器上跑，产出放进 production/charts 和 production/artifacts）:
#   1. 下载 k3s 二进制 + 版本号文件（artifacts/k3s、artifacts/k3s.version）
#   2. 下载 helm 二进制（artifacts/helm）
#   3. 下载 Helm chart 打包成 .tgz（charts/*.tgz，来自 Helm 仓库）
#
# 用法:
#   ./production/scripts/fetch-artifacts.sh              # 按 cluster.env 的版本拉取
#   ./production/scripts/fetch-artifacts.sh --only-chart # 只拉 chart（已有 k3s/helm 时）
#   ./production/scripts/fetch-artifacts.sh --only-bin   # 只拉 k3s/helm 二进制
#
# 产物怎么用:
#   1. 整个 production/charts 和 production/artifacts 目录拷到离线控制机
#   2. 在 cluster.env 里设 K3S_INSTALL_MODE=offline，CHARTS_MODE=local（默认就是 local）
#   3. 跑 bootstrap.sh，它会检测到 artifacts/k3s 存在并走离线路径
#
# 镜像离线（本脚本不负责，只给方法）:
#   # 在有网机器上
#   docker pull rancher/local-path-provisioner:v0.0.30
#   docker pull rancher/mirrored-library-busybox:1.36.1
#   docker pull registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2
#   docker pull <RANCHER 等其他镜像>
#   docker save -o images.tar <镜像列表...>
#   # 在离线节点上
#   k3s ctr images import images.tar
#
# ⚠️ 本脚本不做任何节点改动，只在控制机本地落文件，可反复执行。
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROD_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../lib/config.sh
. "${PROD_DIR}/lib/config.sh"

ONLY=""
for arg in "$@"; do
  case "$arg" in
    --only-chart) ONLY="chart" ;;
    --only-bin)   ONLY="bin" ;;
    -h|--help)    sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) log_error "未知参数: $arg"; exit 1 ;;
  esac
done

prod_require_cmd curl
prod_require_cmd tar
prod_require_cmd sha256sum

mkdir -p "${CHARTS_DIR}" "${ARTIFACTS_DIR}"

# -----------------------------------------------------------------------------
# k3s 版本解析（优先用 cluster.env 的显式值；latest 走 channel）
# -----------------------------------------------------------------------------
if [ "${K3S_VERSION}" != "latest" ]; then
  K3S_RESOLVED="${K3S_VERSION}"
else
  log_info "K3S_VERSION=latest，解析 stable channel..."
  K3S_RESOLVED="$(curl -fsSL "${K3S_CHANNEL_URL}" 2>/dev/null \
    | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+(\+k3s[0-9]+)?' | head -n1)"
  [ -n "${K3S_RESOLVED}" ] || { log_error "无法解析 k3s stable 版本，检查网络或在 cluster.env 里显式设 K3S_VERSION"; exit 1; }
fi
log_info "k3s 版本: ${K3S_RESOLVED}"

# -----------------------------------------------------------------------------
fetch_binaries() {
  # k3s
  local url="${K3S_DOWNLOAD_URL:-https://github.com/k3s-io/k3s/releases/download/${K3S_RESOLVED}/k3s}"
  log_info "下载 k3s 二进制: ${url}"
  if ! curl -fL --connect-timeout 20 --max-time 600 -o "${ARTIFACTS_DIR}/k3s" "${url}"; then
    log_error "下载 k3s 失败（可能需要 VPN/代理）"
    return 1
  fi
  chmod 755 "${ARTIFACTS_DIR}/k3s"
  printf '%s\n' "${K3S_RESOLVED}" > "${ARTIFACTS_DIR}/k3s.version"
  log_info "  → ${ARTIFACTS_DIR}/k3s (版本 ${K3S_RESOLVED})"

  # helm
  local helm_url="${HELM_DOWNLOAD_URL:-https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz}"
  log_info "下载 helm: ${helm_url}"
  if ! curl -fL --connect-timeout 20 --max-time 300 -o /tmp/helm.tgz "${helm_url}"; then
    log_error "下载 helm 失败"
    return 1
  fi
  tar -xzf /tmp/helm.tgz -C /tmp
  mv /tmp/linux-amd64/helm "${ARTIFACTS_DIR}/helm"
  chmod 755 "${ARTIFACTS_DIR}/helm"
  rm -rf /tmp/helm.tgz /tmp/linux-amd64
  log_info "  → ${ARTIFACTS_DIR}/helm"
}

# -----------------------------------------------------------------------------
fetch_charts() {
  # 清理旧的 .tgz 保证版本一致（只删本脚本管理的那些）
  log_info "准备 charts（清理旧 .tgz）..."
  rm -f "${CHARTS_DIR}"/ingress-nginx-*.tgz "${CHARTS_DIR}"/cert-manager-*.tgz "${CHARTS_DIR}"/rancher-*.tgz

  # ingress-nginx
  log_info "下载 ingress-nginx chart ${INGRESS_CHART_VERSION}"
  curl -fsSL --max-time 300 -o "${CHARTS_DIR}/ingress-nginx-${INGRESS_CHART_VERSION}.tgz" \
    "https://kubernetes.github.io/ingress-nginx/ingress-nginx-${INGRESS_CHART_VERSION}.tgz"
  log_info "  → charts/ingress-nginx-${INGRESS_CHART_VERSION}.tgz"

  # cert-manager
  log_info "下载 cert-manager chart ${CERT_MANAGER_CHART_VERSION}"
  curl -fsSL --max-time 300 -o "${CHARTS_DIR}/cert-manager-${CERT_MANAGER_CHART_VERSION}.tgz" \
    "https://charts.jetstack.io/cert-manager-${CERT_MANAGER_CHART_VERSION}.tgz"
  log_info "  → charts/cert-manager-${CERT_MANAGER_CHART_VERSION}.tgz"

  # rancher
  log_info "下载 rancher chart ${RANCHER_CHART_VERSION}"
  curl -fsSL --max-time 300 -o "${CHARTS_DIR}/rancher-${RANCHER_CHART_VERSION}.tgz" \
    "https://releases.rancher.com/server-charts/stable/rancher-${RANCHER_CHART_VERSION}.tgz"
  log_info "  → charts/rancher-${RANCHER_CHART_VERSION}.tgz"
}

# -----------------------------------------------------------------------------
if [ -z "${ONLY}" ] || [ "${ONLY}" = "bin" ]; then
  fetch_binaries
fi
if [ -z "${ONLY}" ] || [ "${ONLY}" = "chart" ]; then
  fetch_charts
fi

log_mark "离线制品准备完成"
log_info "charts 目录: ${CHARTS_DIR}"
log_info "artifacts 目录: ${ARTIFACTS_DIR}"
log_info "请将两个目录整体拷贝到离线控制机，然后在 cluster.env 里设 K3S_INSTALL_MODE=offline"
