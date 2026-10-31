#!/bin/bash
# k3s-ops 测试脚手架
# Usage: source tests/lib/harness.sh
#
# 提供:
#   guard_stubs          — 确认外部命令解析到 stub，否则中止（防止误伤真实 VM）
#   check                — 断言 vagrant/ansible 调用参数与退出码
#   ok / bad             — 简单断言
#   assert_yaml_file     — 断言文件是合法 YAML
#   assert_no_log_pollution — 断言文件未混入日志输出
#   new_tmpdir           — 创建受管的临时目录
#   cleanup_all          — 清理所有临时资源（trap EXIT 自动调用）
#   repo_fingerprint / assert_repo_untouched — 仓库敏感文件指纹保护
#
# 隔离原则（本项目踩过的坑，务必保持）：
#   1. stub 外部命令（vagrant / ansible-playbook / kubectl），并用 guard_stubs
#      确认 stub 真的生效 —— 否则会真的操作 VirtualBox 里的 VM
#   2. LOG_DIR 指向临时目录 —— 否则测试日志会污染 logs/k3s-ops.log
#   3. 有文件副作用的命令在临时 CWD 中执行 —— 否则会覆盖真实 kubeconfig
#   4. 计数一律用 bash 数组 + 显式 nullglob：
#      - 不开 nullglob 时，glob 无匹配会把模式字符串本身算作 1 个元素
#      - `ls -1 <无匹配glob>` 会退化成"列出当前目录"，返回莫名其妙的数字
#   5. 永远不要用 log_cmd 包裹"输出被重定向到文件"的命令：
#      log_cmd 自身的 echo 也会被重定向写进目标文件

set -uo pipefail

TESTS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${TESTS_LIB_DIR}/../.." && pwd)"
STUB_BIN="${TESTS_LIB_DIR}/../stubs"

# ===== 隔离 1: stub 外部命令 =====
export PATH="${STUB_BIN}:${PATH}"
export VAGRANT_STUB_LOG="${VAGRANT_STUB_LOG:-}"
export ANSIBLE_STUB_LOG="${ANSIBLE_STUB_LOG:-}"

# 确认 vagrant / ansible-playbook 解析到 stub。任何一条不满足就拒绝运行：
# stub 失效时 bash 会跳过不可执行文件继续搜索 PATH，从而命中真实 vagrant，
# 那就会真的启停/销毁 VM —— 这是本项目最危险的一个测试陷阱。
guard_stubs() {
  local cmd resolved expected
  for cmd in vagrant ansible-playbook; do
    resolved="$(command -v "${cmd}" 2>/dev/null || echo '<not found>')"
    expected="${STUB_BIN}/${cmd}"
    if [ "${resolved}" != "${expected}" ]; then
      echo "ABORT: \`${cmd}\` 解析到 ${resolved}，期望 stub ${expected}"
      echo "       请检查 ${STUB_BIN}/${cmd} 是否存在且可执行（chmod +x）"
      exit 99
    fi
  done
}

# ===== 隔离 2: 日志不落进仓库 =====
export LOG_DIR="${LOG_DIR:-$(mktemp -d)}"

# ===== 临时资源管理 =====
declare -a _TEST_TMPDIRS=()

new_tmpdir() {
  local d
  d="$(mktemp -d)"
  _TEST_TMPDIRS+=("${d}")
  echo "${d}"
}

cleanup_all() {
  local d
  for d in "${_TEST_TMPDIRS[@]+"${_TEST_TMPDIRS[@]}"}"; do
    [ -n "${d}" ] && rm -rf "${d}"
  done
  [ -n "${LOG_DIR:-}" ] && rm -rf "${LOG_DIR}"
  return 0
}

# ===== 仓库敏感文件指纹保护 =====
# 测试前后比对，确保测试绝不可能损坏仓库里的真实文件
repo_fingerprint() {
  {
    [ -f "${PROJECT_DIR}/kubeconfig" ] && md5sum "${PROJECT_DIR}/kubeconfig"
    [ -f "${PROJECT_DIR}/logs/k3s-ops.log" ] && md5sum "${PROJECT_DIR}/logs/k3s-ops.log"
  } 2>/dev/null | md5sum | cut -d' ' -f1
}

assert_repo_untouched() {
  local label="${1:-仓库}"
  if [ "$(repo_fingerprint)" = "${REPO_FINGERPRINT_BEFORE:-}" ]; then
    ok "${label}敏感文件未被改动"
  else
    bad "${label}敏感文件被改动了！请检查测试的副作用隔离"
  fi
}

# ===== 断言 =====
PASS=0
FAIL=0
FAILED_CASES=()

ok()  { echo "  PASS  $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL + 1)); FAILED_CASES+=("$1"); }

section() { echo; echo "=== $* ==="; }

# 期望值匹配：NONE 表示"不应有任何调用"，否则按 glob 匹配（支持 * ?）
# 用 [[ == ]] 而非 [ != ]，因为后者不做通配符匹配
matches() {
  local expect="$1" got="$2"
  if [ "${expect}" = "NONE" ]; then
    [ -z "${got}" ]
  else
    [[ "${got}" == ${expect} ]]
  fi
}

# check <描述> <期望的 vagrant 调用> <期望的 ansible 调用> <期望退出码> -- <命令...>
#   期望值 NONE = 不应调用；空串 = 忽略该项
check() {
  local desc="$1" expect_v="$2" expect_a="$3" expect_rc="$4"
  shift 5  # 含 "--"

  : > "${VAGRANT_STUB_LOG}"
  : > "${ANSIBLE_STUB_LOG}"
  local out rc
  out="$("$@" 2>&1)"; rc=$?

  local got_v got_a
  got_v="$(sed 's/^VAGRANT_CALL: //' "${VAGRANT_STUB_LOG}" | tr '\n' ';')"
  got_a="$(sed 's/^ANSIBLE_CALL: //' "${ANSIBLE_STUB_LOG}" | tr '\n' ';')"

  local okflag=1 why=""
  if [ -n "${expect_v}" ] && ! matches "${expect_v}" "${got_v}"; then
    okflag=0; why="${why}\n        vagrant 期望 [${expect_v}]\n        vagrant 实际 [${got_v}]"
  fi
  if [ -n "${expect_a}" ] && ! matches "${expect_a}" "${got_a}"; then
    okflag=0; why="${why}\n        ansible 期望 [${expect_a}]\n        ansible 实际 [${got_a}]"
  fi
  if [ "${rc}" -ne "${expect_rc}" ]; then
    okflag=0; why="${why}\n        退出码 期望 ${expect_rc} 实际 ${rc}"
  fi

  if [ "${okflag}" -eq 1 ]; then
    ok "${desc}"
  else
    bad "${desc}${why}"
    echo "${out}" | grep -E 'ERROR' | head -2 | sed 's/^/        /'
  fi
}

# 断言文件是合法 YAML
assert_yaml_file() {
  local file="$1" desc="$2"
  if python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "${file}" 2>/dev/null; then
    ok "${desc}"
  else
    bad "${desc}（${file} 不是合法 YAML）"
  fi
}

# 断言文件里没有混入 log_cmd / log_info 的输出
assert_no_log_pollution() {
  local file="$1" desc="$2"
  if [ -f "${file}" ] && ! grep -qE '^(===|---|\[INFO\]|\[CMD\]|\[DEBUG\])' "${file}"; then
    ok "${desc}"
  else
    bad "${desc}（${file} 混入了日志输出）"
  fi
}

# 统计目录下匹配 VBoxHeadless 日志的数量。
# 必须开 nullglob，否则 glob 无匹配时模式字符串会被算作 1 个元素。
count_vbox_logs() {
  local dir="$1"
  local -a files=()
  shopt -s nullglob
  files=( "${dir}"/*VBoxHeadless-*.log )
  shopt -u nullglob
  echo "${#files[@]}"
}

# 打印小结并按结果返回退出码
summary() {
  local name="$1"
  echo
  echo "────────────────────────────────────────"
  echo "${name}: ${PASS} passed, ${FAIL} failed"
  if [ "${FAIL}" -ne 0 ]; then
    printf '  失败用例:\n'
    printf '    - %s\n' "${FAILED_CASES[@]}"
    return 1
  fi
  return 0
}

# 供各测试脚本在结尾统一调用
finish() {
  local name="$1"
  local rc=0
  summary "${name}" || rc=1
  exit "${rc}"
}
