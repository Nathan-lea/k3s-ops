#!/bin/bash
# 隐私信息检查脚本
# 扫描将被 git 跟踪的文件，检查是否存在本地/敏感信息泄漏风险。
# 供 pre-push 钩子调用；也可手动运行：bash scripts/privacy-check.sh
# 退出码: 0 = 无风险（通过）; 1 = 发现风险
set -u

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "[privacy-check] 错误: 当前不在 git 仓库中"
  exit 2
fi
cd "$(git rev-parse --show-toplevel)" || exit 2

# 当前 git 跟踪/待跟踪的全部文件
# 注意: core.quotepath=false 保证中文/特殊字符文件名以原始 UTF-8 输出,否则 ls-files
# 会用引号+八进制转义(如 "docs/01-\346\226\207.md"),导致后续 [ -f ] 判断失效而漏检。
mapfile -t FILES < <(git -c core.quotepath=false ls-files --cached --others --exclude-standard 2>/dev/null)
if [ "${#FILES[@]}" -eq 0 ]; then
  echo "[privacy-check] 没有可检查的文件"
  exit 0
fi

# ===== 允许清单（项目设计内、已确认可公开的值）=====
# 本 k3s 项目刻意定义了以下内网拓扑（VM/Vagrant 与 k3s 默认网络），属于有意内容:
ALLOW_IPS=(
  "192.168.56.0" "192.168.56.10" "192.168.56.11" "192.168.56.20"
  "10.42.0.0" "10.42.1.0" "10.43.0.0" "10.43.1.0" "10.43.197.0"
  "10.0.2.15" "10.0.2.2"
)
# 已确认接受的演示占位密码（设计的一部分，用户明确选择不处理）
ALLOW_PASS_VALUES=("admin" "\${TOKEN}" '{{' '********' "s3cret" "abc")

# 已知的"非用户本地路径"（系统/容器/教程演示路径，不构成隐私泄漏）
# 规则1 会拦截 /data/、/mnt/、/root/ 等疑似本机路径；以下为明确非本机数据路径，予以豁免。
ALLOW_PATH_PATTERNS=(
  "/data/current"       # k3s 节点内置二进制固定路径 (/var/lib/rancher/k3s/data/current/...)
  "/data/test.txt"      # 05章容器内 PV 演示挂载路径（教程刻意内容）
)

# 检查脚本自身（内含正则字符串，不参与内容扫描）
ALLOW_SELF_FILES=("scripts/privacy-check.sh")

# ===== 工具函数 =====
is_allow_ip() { for a in "${ALLOW_IPS[@]}"; do [ "$1" = "$a" ] && return 0; done; return 1; }
is_allow_pass() { for a in "${ALLOW_PASS_VALUES[@]}"; do case "$1" in *"$a"*) return 0;; esac; done; return 1; }
is_self() { for a in "${ALLOW_SELF_FILES[@]}"; do [ "$1" = "$a" ] && return 0; done; return 1; }

declare -a ISSUES=()
declare -i FAIL=0

add_issue() { ISSUES+=("  $1"); FAIL=1; }

# 对每个文件进行内容检查
for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  is_self "$f" && continue
  # 跳过二进制
  grep -aqI "" "$f" 2>/dev/null || continue

  # 规则1: 本地绝对路径(如 /home/、/Users/、/data/;排除 JSON 补丁路径 /data/<数字> 与系统标准路径)
  # 命中的每一行都必须是 ALLOW_PATH_PATTERNS 中的已知路径才放行,否则视为泄漏
  hits=$(grep -aoE "(/home/[a-zA-Z_][^\"']*|/Users/[^\"']*|/data/[a-zA-Z_][^\"']*|/mnt/[^\"']*|/root/[^\"']*|/rootfs/[^\"']*)" "$f" 2>/dev/null | sort -u || true)
  if [ -n "$hits" ]; then
    leak=""
    while IFS= read -r p; do
      ok=""
      for a in "${ALLOW_PATH_PATTERNS[@]}"; do
        case "$p" in *"$a"*) ok=1; break ;; esac
      done
      [ -z "$ok" ] && leak=1
    done <<< "$hits"
    [ -n "$leak" ] && add_issue "[绝对路径] $f"
  fi

  # 规则2: 私钥内容
  # 注意: 模式以 ----- 开头, 必须用 -e 防止被 grep 当作命令行选项
  if grep -aqE -e "-----BEGIN (RSA |EC |DSA |OPENSSH |)PRIVATE KEY-----" "$f" 2>/dev/null; then
    add_issue "[私钥] $f"
  fi

  # 规则3: kubeconfig 私钥/证书字段(base64 数据)
  if grep -aqE "(client-key-data|client-certificate-data|certificate-authority-data|client-key:|client-certificate:)" "$f" 2>/dev/null; then
    add_issue "[kubeconfig私钥数据] $f"
  fi

  # 规则4: 云/平台 API 密钥
  if grep -aqE "(AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|ghp_[0-9A-Za-z]{36}|xox[baprs]-[0-9A-Za-z-]{10,}|sk-[A-Za-z0-9_-]{20,}|-----BEGIN CERTIFICATE-----)" "$f" 2>/dev/null; then
    add_issue "[API密钥] $f"
  fi

  # 规则5: 硬编码密码字段(排除变量引用与已接受的演示值)
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    val="${line#*=}"; val="${val#*:}"; val="${val%%, *}"
    val=$(printf '%s' "$val" | sed 's/^[[:space:]"'"'"']*//; s/[[:space:]"'"'"']*$//')
    # 排除空值/变量引用/已接受占位
    [ -z "$val" ] && continue
    case "$val" in
      *'$'*|\{\{*|'*'*) continue ;;
    esac
    is_allow_pass "$val" && continue
    add_issue "[明文密码: $f -> ${line%%:*}...= $val]"
  done < <(grep -aiE "\b(password|passwd|pwd|secret|api[_-]?key|access[_-]?key|bootstrap[_-]?password|adminpassword)\s*[:=]\s*" "$f" 2>/dev/null || true)

  # 规则6: 内网 IP(不在 allowed 清单内的完整私有地址 → 可能是真实拓扑泄漏)
  while IFS= read -r ip; do
    [ -z "$ip" ] && continue
    is_allow_ip "$ip" || add_issue "[私有IP(未在白名单): $f -> $ip]"
  done < <(grep -aoE "((192\.168\.(1[0-9]|2[0-9]))|(10\.(0|[1-9]|[12][0-9]|3[01])\.)|(172\.(1[6-9]|2[0-9]|3[01])\.))[0-9]{1,3}\.[0-9]{1,3}" "$f" 2>/dev/null | sort -u || true)

  # 规则7: 邮箱/手机号
  if grep -aqE "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|1[3-9][0-9]{9}" "$f" 2>/dev/null; then
    add_issue "[邮箱/手机号] $f"
  fi

  # 规则8: 敏感文件名
  case "$f" in
    *kubeconfig*|*.pem|*.key|*.p12|*.pfx|*.jks|*id_rsa*|*id_ed25519*|*.env|*.env.*)
      case "$f" in scripts/get-kubeconfig.sh) ;; *) add_issue "[敏感文件: $f]" ;; esac ;;
  esac
done

# ===== 输出 =====
if [ "$FAIL" -eq 1 ]; then
  echo "[privacy-check] ❌ 发现以下隐私/敏感信息，已阻止本次操作:"
  printf '%s\n' "${ISSUES[@]}" | sort -u
  echo ""
  echo "  请处理后再继续。若确认某值属项目设计,可将其加入 scripts/privacy-check.sh 的 ALLOW_* 清单。"
  echo "  如需本次临时跳过(不推荐): git -c core.hooksPath=/dev/null push ..."
  exit 1
else
  echo "[privacy-check] ✅ 未发现隐私泄漏风险 (检查 ${#FILES[@]} 个文件)"
  exit 0
fi
