#!/usr/bin/env bash
# =============================================================================
# production/scripts/offline-load.sh —— 离线模式：把制品分发到节点
# =============================================================================
# 干的事（仅 K3S_INSTALL_MODE=offline 时需要）:
#   1. 用 rsync 把 artifacts/k3s 推到每台节点的 /usr/local/bin/k3s（先放 /tmp 再 mv，避免写一半）
#   2. 用 rsync 把 artifacts/images/*.tar 推到每台节点，用 k3s ctr 导入 containerd
#
# 前置条件:
#   - artifacts/k3s 存在（先在有网机器跑 scripts/fetch-artifacts.sh）
#   - artifacts/images/*.tar 存在（可选；没有就只分发二进制，镜像导入跳过）
#
# 幂等：分发前比对 sha256，一致就跳过；镜像导入会先查 label 判断是否已导入。
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROD_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../lib/config.sh
. "${PROD_DIR}/lib/config.sh"
# shellcheck source=../lib/ipam.sh
. "${PROD_DIR}/lib/ipam.sh"

if [ "${K3S_INSTALL_MODE}" != "offline" ]; then
  log_warn "K3S_INSTALL_MODE=${K3S_INSTALL_MODE}（非 offline），本脚本无需执行"
  exit 0
fi

prod_require_cmd ssh
prod_require_cmd rsync
prod_require_cmd sha256sum
if ! ipam_validate; then
  log_error "ipam.yml 校验失败，中止离线分发"
  exit 1
fi

K3S_BIN="${ARTIFACTS_DIR}/k3s"
IMG_DIR="${ARTIFACTS_DIR}/images"

if [ ! -x "${K3S_BIN}" ]; then
  log_error "找不到可执行的 ${K3S_BIN}"
  log_error "修复: 在有网机器执行 bash production/scripts/fetch-artifacts.sh，再把 artifacts/ 拷过来"
  exit 1
fi

REMOTE_TMP="/tmp/k3s-offline"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=15 -o IdentitiesOnly=yes -i "${OPS_SSH_KEY}" -p "${SSH_PORT}")

remote() { # $1=ip  $2=cmd
  ssh "${SSH_OPTS[@]}" "${OPS_USER}@$1" "$2"
}

log_mark "离线分发制品（k3s ${K3S_RESOLVED_VERSION:-${K3S_VERSION}}）"
log_info "源: ${K3S_BIN}"
[ -d "${IMG_DIR}" ] && log_info "镜像: ${IMG_DIR} ($(ls -1 "${IMG_DIR}"/*.tar 2>/dev/null | wc -l) 个 tar)" \
  || log_info "镜像: 未找到 ${IMG_DIR}，跳过镜像导入"

while read -r host; do
  [ -n "${host}" ] || continue
  ip="$(ipam_node_ip "${host}")"
  log_mark "节点 ${host} (${ip})"

  # 确保目标目录存在（用 ops + sudo）
  remote "${ip}" "sudo mkdir -p ${REMOTE_TMP} && sudo chown -R \$(id -un): \$(id -gn) ${REMOTE_TMP} 2>/dev/null || sudo chmod 777 ${REMOTE_TMP}" || true

  # 1. k3s 二进制
  local_sum="$(sha256sum "${K3S_BIN}" | awk '{print $1}')"
  remote_sum="$(remote "${ip}" "sudo sha256sum /usr/local/bin/k3s 2>/dev/null | awk '{print \$1}' || true")"
  if [ "${local_sum}" = "${remote_sum}" ]; then
    log_info "  ✅ k3s 二进制已一致（sha256 相同），跳过"
  else
    rsync -az -e "ssh ${SSH_OPTS[*]}" "${K3S_BIN}" "${OPS_USER}@${ip}:${REMOTE_TMP}/k3s"
    remote "${ip}" "sudo mv -f ${REMOTE_TMP}/k3s /usr/local/bin/k3s && sudo chmod 755 /usr/local/bin/k3s"
    log_info "  ✅ k3s 二进制已分发"
  fi

  # 2. 镜像 tar
  if [ -d "${IMG_DIR}" ]; then
    shopt -s nullglob
    for tar in "${IMG_DIR}"/*.tar; do
      base="$(basename "${tar}")"
      rsync -az -e "ssh ${SSH_OPTS[*]}" "${tar}" "${OPS_USER}@${ip}:${REMOTE_TMP}/${base}"
      if remote "${ip}" "sudo k3s ctr images import ${REMOTE_TMP}/${base} 2>&1"; then
        log_info "  ✅ 镜像已导入: ${base}"
      else
        log_warn "  ⚠️ 镜像导入失败（可能重复或镜像本身有问题）: ${base}"
      fi
    done
    shopt -u nullglob
  fi

  remote "${ip}" "rm -rf ${REMOTE_TMP}" || true
done < <(ipam_hosts)

log_mark "离线分发全部完成。现在可以跑 bash production/bootstrap.sh --steps 05,ssh,10,20,30"
