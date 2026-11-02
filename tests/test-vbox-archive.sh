#!/bin/bash
# 测试：_archive_vbox_logs —— 把根目录的 VirtualBox 日志归档到 logs/vbox/
#
# 背景：VirtualBox 把每个 VM 进程的 *VBoxHeadless-*.log 写进启动进程的 CWD
#      （即项目根），而 VirtualBox 7.x 已移除 VBoxManage set logfile，
#      无法修改写入位置，所以只能在 up/down/destroy 之后事后归档。
#
# 本测试用假日志文件驱动，不产生真实 VBox 日志，并在退出时把根目录原有
# 的真实日志原样还原。

set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

K3S="${PROJECT_DIR}/k3s-ops.sh"
VBOX_DIR="${PROJECT_DIR}/logs/vbox"
export VAGRANT_STUB_LOG="$(new_tmpdir)/vagrant.log"
export ANSIBLE_STUB_LOG="$(new_tmpdir)/ansible.log"
trap cleanup_all EXIT

guard_stubs

# ---- 备份根目录已有的真实日志，测试结束后原样还原 ----
BACKUP="$(new_tmpdir)"
shopt -s nullglob
cp "${PROJECT_DIR}"/*VBoxHeadless-*.log "${BACKUP}/" 2>/dev/null
shopt -u nullglob
REAL_COUNT="$(count_vbox_logs "${PROJECT_DIR}")"

restore() {
  shopt -s nullglob
  rm -f "${PROJECT_DIR}"/*VBoxHeadless-*.log
  shopt -u nullglob
  rm -rf "${VBOX_DIR}"
  if [ "${REAL_COUNT}" -gt 0 ]; then
    mkdir -p "${VBOX_DIR}"
    cp "${BACKUP}"/*VBoxHeadless-*.log "${VBOX_DIR}/"
  fi
  return 0
}
# restore 必须先于 cleanup_all 执行（后者会删掉 BACKUP）
trap 'restore; cleanup_all' EXIT

mkfake() {
  printf 'fake vbox log %s\n' "$1" \
    > "${PROJECT_DIR}/2026-01-01-00-00-00.000-VBoxHeadless-${1}.log"
}

reset_env() {
  rm -rf "${VBOX_DIR}"
  shopt -s nullglob
  rm -f "${PROJECT_DIR}"/*VBoxHeadless-*.log
  shopt -u nullglob
}

section "1. 根目录的 VBox 日志被归档到 logs/vbox/"
reset_env
mkfake 90001; mkfake 90002
before="$(count_vbox_logs "${PROJECT_DIR}")"
VBOX_LOG_KEEP=100 "${K3S}" down >/dev/null 2>&1
after="$(count_vbox_logs "${PROJECT_DIR}")"
archived="$(count_vbox_logs "${VBOX_DIR}")"
if [ "${before}" -eq 2 ] && [ "${after}" -eq 0 ] && [ "${archived}" -eq 2 ]; then
  ok "根目录 2 个 → 全部移入 logs/vbox/（根目录剩 ${after} 个）"
else
  bad "before=${before} after=${after} archived=${archived}（期望 2/0/2）"
fi

section "2. 非 VBox 日志文件不应被移动"
reset_env
printf 'x\n' > "${PROJECT_DIR}/some-other-tool.log"
VBOX_LOG_KEEP=100 "${K3S}" down >/dev/null 2>&1
if [ -f "${PROJECT_DIR}/some-other-tool.log" ] && [ ! -f "${VBOX_DIR}/some-other-tool.log" ]; then
  ok "some-other-tool.log 留在原处，未被误归档"
  rm -f "${PROJECT_DIR}/some-other-tool.log"
else
  bad "some-other-tool.log 被误移动或丢失"
fi

section "3. 按修改时间保留最近 N 个（VBOX_LOG_KEEP=2）"
reset_env
mkfake 90003; mkfake 90004; mkfake 90005
touch -d '2020-01-01 00:00:00' "${PROJECT_DIR}"/*VBoxHeadless-90003*.log
touch -d '2020-06-01 00:00:00' "${PROJECT_DIR}"/*VBoxHeadless-90004*.log
touch -d '2020-12-31 00:00:00' "${PROJECT_DIR}"/*VBoxHeadless-90005*.log
VBOX_LOG_KEEP=2 "${K3S}" down >/dev/null 2>&1
if [ "$(count_vbox_logs "${VBOX_DIR}")" -eq 2 ] \
   && [ -f "${VBOX_DIR}"/*VBoxHeadless-90005*.log ] \
   && [ -f "${VBOX_DIR}"/*VBoxHeadless-90004*.log ] \
   && [ ! -f "${VBOX_DIR}"/*VBoxHeadless-90003*.log ] \
   && [ "$(count_vbox_logs "${PROJECT_DIR}")" -eq 0 ]; then
  ok "保留最新 2 个（90005/90004），最旧的 90003 已清理"
else
  bad "保留数=$(count_vbox_logs "${VBOX_DIR}")，内容: $(ls -1 "${VBOX_DIR}" 2>/dev/null | tr '\n' ' ')"
fi

section "4. up / destroy 同样触发归档"
reset_env
mkfake 90006
a="$(count_vbox_logs "${PROJECT_DIR}")"
VBOX_LOG_KEEP=100 "${K3S}" up >/dev/null 2>&1
b="$(count_vbox_logs "${PROJECT_DIR}")"
if [ "${a}" -eq 1 ] && [ "${b}" -eq 0 ] && [ -f "${VBOX_DIR}"/*VBoxHeadless-90006*.log ]; then
  ok "up 触发归档（1 → 0）"
else
  bad "up 未触发归档（${a} → ${b}）"
fi

mkfake 90007
echo "yes" | VBOX_LOG_KEEP=100 "${K3S}" destroy >/dev/null 2>&1
c="$(count_vbox_logs "${PROJECT_DIR}")"
if [ "${c}" -eq 0 ] && [ -f "${VBOX_DIR}"/*VBoxHeadless-90007*.log ]; then
  ok "destroy 触发归档"
else
  bad "destroy 未触发归档（根目录残留 ${c} 个）"
fi

section "5. destroy 被取消时保持零副作用"
reset_env
mkfake 90008
echo "n" | VBOX_LOG_KEEP=100 "${K3S}" destroy >/dev/null 2>&1
if [ "$(count_vbox_logs "${PROJECT_DIR}")" -eq 1 ] && [ "$(count_vbox_logs "${VBOX_DIR}")" -eq 0 ]; then
  ok "取消 destroy 时根目录文件保持不动"
else
  bad "取消 destroy 仍有副作用（root=$(count_vbox_logs "${PROJECT_DIR}") vbox=$(count_vbox_logs "${VBOX_DIR}")）"
fi

section "6. 根目录无 VBox 日志时静默返回，不创建 logs/vbox/"
reset_env
out="$(VBOX_LOG_KEEP=20 "${K3S}" down 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ] && [ "$(count_vbox_logs "${PROJECT_DIR}")" -eq 0 ] && [ ! -d "${VBOX_DIR}" ]; then
  ok "静默返回，未创建 logs/vbox/，退出码 0"
else
  bad "rc=${rc}，logs/vbox 存在=$([ -d "${VBOX_DIR}" ] && echo yes || echo no): ${out}"
fi

echo
echo "（已还原根目录原有的 ${REAL_COUNT} 个真实日志）"
finish "test-vbox-archive"
