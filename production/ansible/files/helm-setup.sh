#!/bin/bash
# =============================================================================
# helm-setup.sh —— 在第一个 server 节点上准备 helm（幂等）
# =============================================================================
# 由 production/ansible/playbooks/30-addons.yml 通过 command + environment 调用，
# 参数全部走环境变量，便于单独手动跑：
#
#   HELM_VERSION=v3.16.3 HELM_BIN=/usr/local/bin/helm bash helm-setup.sh
#   HELM_VERSION=v3.16.3 HELM_ARTIFACT=/opt/k3s-artifacts/helm bash helm-setup.sh   # 离线
#
# 为什么不用系统包管理器: 发行版自带的 helm 版本常常过旧，而 chart 对 helm 版本有要求。
# =============================================================================
set -euo pipefail

HELM_VERSION="${HELM_VERSION:-v3.16.3}"
HELM_BIN="${HELM_BIN:-/usr/local/bin/helm}"
HELM_DOWNLOAD_URL="${HELM_DOWNLOAD_URL:-}"
HELM_ARTIFACT="${HELM_ARTIFACT:-}"

log() { printf '[helm-setup] %s\n' "$*"; }

_arch() {
  case "$(uname -m)" in
    x86_64|amd64)   echo amd64 ;;
    aarch64|arm64)  echo arm64 ;;
    armv7l|armv7)   echo arm   ;;
    *) echo "unsupported:$(uname -m)" >&2; return 1 ;;
  esac
}

_installed_version_ok() {
  command -v "${HELM_BIN}" >/dev/null 2>&1 || return 1
  local out
  out="$("${HELM_BIN}" version --short 2>/dev/null || true)"
  case "${out}" in
    "${HELM_VERSION}"*) return 0 ;;
    *) log "已存在的 helm 版本为 ${out:-未知}，与目标 ${HELM_VERSION} 不一致，将替换"; return 1 ;;
  esac
}

_install_binary() { # $1 = 源文件
  install -m 0755 "$1" "${HELM_BIN}"
  log "已安装: $("${HELM_BIN}" version --short)"
}

main() {
  if _installed_version_ok; then
    log "helm ${HELM_VERSION} 已就绪（${HELM_BIN}）"
    exit 0
  fi

  local arch tmp
  arch="$(_arch)"

  if [ -n "${HELM_ARTIFACT}" ] && [ -f "${HELM_ARTIFACT}" ]; then
    log "使用离线制品安装: ${HELM_ARTIFACT}"
    _install_binary "${HELM_ARTIFACT}"
    exit 0
  fi

  local url="${HELM_DOWNLOAD_URL}"
  if [ -z "${url}" ]; then
    url="https://get.helm.sh/helm-${HELM_VERSION}-linux-${arch}.tar.gz"
  fi

  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    log "缺少 curl/wget，无法下载 helm。离线环境请准备 ${HELM_ARTIFACT:-<artifacts>/helm} 后重试"
    exit 1
  fi

  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' EXIT

  log "下载 helm ${HELM_VERSION} (linux-${arch})"
  log "  来源: ${url}"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 20 --max-time 600 -o "${tmp}/helm.tgz" "${url}"
  else
    wget -q -T 600 -O "${tmp}/helm.tgz" "${url}"
  fi

  tar -xzf "${tmp}/helm.tgz" -C "${tmp}"
  if [ ! -f "${tmp}/linux-${arch}/helm" ]; then
    log "压缩包里没有 linux-${arch}/helm，下载可能不完整"
    exit 1
  fi

  _install_binary "${tmp}/linux-${arch}/helm"
}

main "$@"
