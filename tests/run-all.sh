#!/bin/bash
# 运行全部测试
# 用法:
#   bash tests/run-all.sh              # 跑全部
#   bash tests/run-all.sh test-down    # 只跑名字包含 test-down 的
#
# 退出码 0 = 全部通过

set -uo pipefail
cd "$(dirname "$0")" || exit 2

FILTER="${1:-}"
TOTAL_FAIL=0
RESULTS=()

for t in test-*.sh; do
  [ -f "${t}" ] || continue
  if [ -n "${FILTER}" ] && [[ "${t}" != *"${FILTER}"* ]]; then
    continue
  fi

  echo
  echo "════════════════════════════════════════"
  echo "  ${t}"
  echo "════════════════════════════════════════"
  if bash "${t}"; then
    RESULTS+=("✅ ${t}")
  else
    rc=$?
    if [ "${rc}" -eq 99 ]; then
      echo "ABORTED: stub 未生效，测试拒绝运行以免影响真实 VM"
    fi
    RESULTS+=("❌ ${t} (exit=${rc})")
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
  fi
done

echo
echo "════════════════════════════════════════"
echo "  总览"
echo "════════════════════════════════════════"
for r in "${RESULTS[@]}"; do echo "  ${r}"; done
echo
if [ "${TOTAL_FAIL}" -eq 0 ]; then
  echo "全部通过"
  exit 0
fi
echo "${TOTAL_FAIL} 个测试文件失败"
exit 1
