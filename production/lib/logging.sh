#!/bin/bash
# k3s-ops 共享日志库
# Usage: source lib/logging.sh
#
# 提供以下函数:
#   log_init          — 初始化日志（自动创建目录、轮转）
#   log_info          — INFO 级别日志
#   log_warn          — WARN 级别日志
#   log_error         — ERROR 级别日志
#   log_debug         — DEBUG 级别日志
#   log_cmd           — 记录命令开始/结束（含耗时）

# 自动定位日志目录（相对于 lib/..）
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null || echo '.')"
PROJECT_DIR="$(cd "${LIB_DIR}/.." && pwd 2>/dev/null || echo '.')"
LOG_DIR="${LOG_DIR:-${PROJECT_DIR}/logs}"
LOG_FILE="${LOG_DIR}/k3s-ops.log"

# 颜色（终端支持时启用）
if [ -t 1 ]; then
  readonly C_INFO="\033[0;32m"
  readonly C_WARN="\033[1;33m"
  readonly C_ERROR="\033[0;31m"
  readonly C_CMD="\033[0;36m"
  readonly C_NC="\033[0m"
else
  readonly C_INFO=""
  readonly C_WARN=""
  readonly C_ERROR=""
  readonly C_CMD=""
  readonly C_NC=""
fi

# 内部：获取时间戳（跨平台兼容）
_timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

# 内部：获取文件大小（bytes），兼容 Linux / macOS
_file_size() {
  local f="$1"
  if [ -f "$f" ]; then
    # Linux: stat -c%s, macOS: stat -f%z
    stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

# 内部：写入日志文件
_log_write() {
  local level="$1"
  shift
  local msg="$*"
  local ts
  ts="$(_timestamp)"
  echo "[${ts}] [${level}] ${msg}" >> "${LOG_FILE}"
}

# 初始化日志系统
# 用法: log_init
log_init() {
  mkdir -p "${LOG_DIR}" 2>/dev/null || true

  # 日志文件超 10MB 时轮转（最多保留 5 个归档）
  local max_size=10485760  # 10MB
  local current_size
  current_size=$(_file_size "${LOG_FILE}")
  if [ "${current_size}" -gt "${max_size}" ] 2>/dev/null; then
    for i in 5 4 3 2 1; do
      local prev=$((i - 1))
      [ -f "${LOG_FILE}.${prev}" ] && mv "${LOG_FILE}.${prev}" "${LOG_FILE}.${i}" 2>/dev/null || true
    done
    mv "${LOG_FILE}" "${LOG_FILE}.1" 2>/dev/null || true
  fi

  _log_write "INIT" "=== k3s-ops session started ==="
}

# 日志函数
log_info()  { local m="$*"; _log_write "INFO"  "${m}"; echo -e "${C_INFO}[INFO]${C_NC}  ${m}"; }
log_warn()  { local m="$*"; _log_write "WARN"  "${m}"; echo -e "${C_WARN}[WARN]${C_NC}  ${m}"; }
log_error() { local m="$*"; _log_write "ERROR" "${m}"; echo -e "${C_ERROR}[ERROR]${C_NC} ${m}" >&2; }
log_debug() { local m="$*"; _log_write "DEBUG" "${m}"; echo -e "[DEBUG] ${m}"; }

# 记录命令执行
# 用法: log_cmd <command_description> <command_and_args...>
# 示例: log_cmd "Starting k3s install" vagrant up
log_cmd() {
  local desc="$1"
  shift
  local ts
  ts="$(_timestamp)"

  _log_write "CMD" "=== ${desc} (PID=$$) ==="
  echo -e "${C_CMD}=== ${desc} ...${C_NC}"

  local start_time
  start_time="$(date +%s)"

  # 执行命令
  "$@"
  local exit_code=$?

  local end_time
  end_time="$(date +%s)"
  local elapsed=$((end_time - start_time))

  if [ ${exit_code} -eq 0 ]; then
    _log_write "CMD" "--- ${desc} completed (${elapsed}s) ---"
    echo -e "${C_CMD}--- ${desc} done (${elapsed}s) ---${C_NC}"
  else
    _log_write "CMD" "!!! ${desc} FAILED (exit=${exit_code}, ${elapsed}s) !!!"
    echo -e "${C_ERROR}!!! ${desc} FAILED (exit=${exit_code}) !!!${C_NC}"
  fi

  return ${exit_code}
}

# 记录函数调用（无命令执行，仅标记）
# 用法: log_mark <message>
log_mark() {
  local msg="$*"
  _log_write "MARK" "${msg}"
  echo -e "${C_CMD}--- ${msg} ---${C_NC}"
}
