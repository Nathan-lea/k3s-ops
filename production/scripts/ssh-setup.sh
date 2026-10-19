#!/usr/bin/env bash
# =============================================================================
# production/scripts/ssh-setup.sh —— 初始化阶段：创建 ops 账号 + 密钥 + 收紧 root
# =============================================================================
# 干的事（在 ipam.yml 的每台节点上）:
#   1. 用 INIT_SSH_USER/INIT_SSH_PASSWORD（默认 root+密码）连上节点
#   2. 创建 OPS_USER（默认 ops）+ sudo 免密 + 分发公钥
#   3. 用 ops + 私钥**真实验证一遍**能登进去
#   4. 验证通过才收紧 sshd：PermitRootLogin（ROOT_SSH_POLICY，先试 prohibit-password）
#      可选：把 SSH 端口改成 SSH_PORT
#   5. 验证失败则原样退出，**绝不改 sshd_config**（防止把自己关在门外）
#
# 幂等：已存在的用户/密钥不会重复添加；sshd 配置文件每次覆盖重写。
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROD_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../lib/config.sh
. "${PROD_DIR}/lib/config.sh"
# shellcheck source=../lib/ipam.sh
. "${PROD_DIR}/lib/ipam.sh"

prod_require_cmd ssh
prod_require_cmd ssh-keygen

# 远程脚本通过环境变量传参（本文件里 heredoc 都是 quoted，不会本地展开）
export OPS_USER OPS_PUB OPS_SSH_KEY OPS_SUDO_NOPASSWD SSH_PORT INIT_SSH_USER ROOT_SSH_POLICY

if ! ipam_validate; then
  log_error "ipam.yml 校验失败，中止 ssh 设置"
  exit 1
fi

# 首次连上去用的端口。节点是刚装好的系统，sshd 一般还在默认端口；
# SSH_PORT 是"收紧之后"ops 应该用的端口，两者可以不同。
INIT_PORT="${INIT_SSH_PORT:-22}"

# =============================================================================
# 本地密钥
# =============================================================================
mkdir -p "$(dirname "${OPS_SSH_KEY}")"
if [ ! -f "${OPS_SSH_KEY}" ]; then
  log_info "生成运维私钥: ${OPS_SSH_KEY}"
  ssh-keygen -t ed25519 -N "" -f "${OPS_SSH_KEY}" -q
  chmod 600 "${OPS_SSH_KEY}"
else
  log_info "复用已有私钥: ${OPS_SSH_KEY}"
fi
OPS_PUB="$(cat "${OPS_SSH_KEY}.pub")"
export OPS_PUB OPS_USER OPS_SSH_KEY SSH_PORT

# =============================================================================
# 密码来源：env → 交互
# =============================================================================
if [ -z "${INIT_SSH_PASSWORD:-}" ]; then
  log_warn "未设置 INIT_SSH_PASSWORD，将在输入密码后继续（供每台节点做首次 root 登录）"
  read -rs -p "首次 root 密码: " INIT_SSH_PASSWORD
  printf '\n'
fi
export INIT_SSH_PASSWORD

# =============================================================================
# 远程调用工具
# =============================================================================
_init_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=15 -o BatchMode=no)

# root 首连（密码）：节点还在 INIT_SSH_PORT
as_init() { # $1=ip  $2=stdin 里的脚本内容
  if command -v sshpass >/dev/null 2>&1; then
    SSHPASS="${INIT_SSH_PASSWORD}" sshpass -e \
      ssh "${_init_opts[@]}" -o PreferredAuthentications=password \
      -o PubkeyAuthentication=no -p "${INIT_SSH_PORT}" \
      "${INIT_SSH_USER}@$1" 'bash -s' <<<"$2"
  else
    ssh "${_init_opts[@]}" -p "${INIT_SSH_PORT}" "${INIT_SSH_USER}@$1" 'bash -s' <<<"$2"
  fi
}

# ops 登录（密钥）：端口由调用方决定（收紧前后分别用 INIT_SSH_PORT / SSH_PORT）
as_ops() { # $1=ip  $2=端口  $3=要跑的命令
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=15 -o IdentitiesOnly=yes \
    -i "${OPS_SSH_KEY}" -p "$2" "${OPS_USER}@$1" "$3"
}

# =============================================================================
# 节点侧脚本
# =============================================================================
PROVISION_SCRIPT=$(cat <<'REMOTE'
set -eu
user="${OPS_USER}"
pub="${OPS_PUB}"

if ! id "$user" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$user"
  echo "[node] 已创建用户 $user"
else
  echo "[node] 用户 $user 已存在"
fi

usermod -aG sudo "$user" 2>/dev/null || usermod -aG wheel "$user" 2>/dev/null || true

install -d -m 0700 -o "$user" -g "$user" "/home/$user/.ssh"
touch "/home/$user/.ssh/authorized_keys"
chmod 600 "/home/$user/.ssh/authorized_keys"
if ! grep -qxF "$pub" "/home/$user/.ssh/authorized_keys"; then
  echo "$pub" >> "/home/$user/.ssh/authorized_keys"
  echo "[node] 已分发公钥到 $user"
else
  echo "[node] 公钥已在 $user 的 authorized_keys 中"
fi
chown -R "$user:$user" "/home/$user/.ssh"

if [ "${OPS_SUDO_NOPASSWD}" = "true" ]; then
  echo "$user ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$user"
  chmod 440 "/etc/sudoers.d/$user"
  visudo -cf "/etc/sudoers.d/$user" >/dev/null
  echo "[node] 已配置 sudo 免密"
fi
REMOTE
)

HARDEN_SCRIPT=$(cat <<'REMOTE'
set -eu
policy="${ROOT_SSH_POLICY}"
port="${SSH_PORT}"
dropin=/etc/ssh/sshd_config.d/99-k3s-ops-hardening.conf

mkdir -p /etc/ssh/sshd_config.d
backup="$(mktemp)"
cp /etc/ssh/sshd_config "$backup"

# Port 可以累加：必须先把主配置里的 Port 注释掉，改端口才能生效
# （只注释未被注释的 `Port <数字>` 行；`# Port ...` 不会命中这条正则）
if [ "$port" != "22" ]; then
  sed -i -E 's/^([[:space:]]*)Port[[:space:]]+([0-9]+)/\1# Port \2/' /etc/ssh/sshd_config
fi

{
  echo "# 由 k3s-ops production/scripts/ssh-setup.sh 生成，可手工调整"
  if [ "$port" != "22" ]; then
    echo "Port $port"
  fi
  echo "PermitRootLogin $policy"
} > "$dropin"

if ! sshd -t; then
  echo "[node] sshd 配置校验失败，还原" >&2
  rm -f "$dropin"
  cp "$backup" /etc/ssh/sshd_config
  rm -f "$backup"
  exit 1
fi
rm -f "$backup"

# systemd 服务名在不同发行版可能是 ssh / sshd
if systemctl is-active --quiet ssh; then
  systemctl reload ssh
elif systemctl is-active --quiet sshd; then
  systemctl reload sshd
else
  systemctl restart ssh
fi

echo "[node] 已收紧 sshd: PermitRootLogin=$policy$([ "$port" != "22" ] && echo ", Port=$port")"
REMOTE
)

# =============================================================================
# 主流程
# =============================================================================
log_mark "初始化运维账号与 SSH（root → ${OPS_USER}）"
log_info "私钥: ${OPS_SSH_KEY}    公钥端口: ${SSH_PORT}    初始化用户: ${INIT_SSH_USER}"

FAIL=0
while read -r host; do
  [ -n "${host}" ] || continue
  ip="$(ipam_node_ip "${host}")"
  log_mark "节点 ${host} (${ip})"

  # 1. 首次用 root 建账号 / 分发公钥
  if as_init "${ip}" "${PROVISION_SCRIPT}"; then
    log_info "  ✅ ${OPS_USER} 账号与公钥就绪"
  else
    log_error "  ❌ ${INIT_SSH_USER}@${ip} 建账号失败（检查密码/网络/端口 INIT_SSH_PORT=${INIT_SSH_PORT}）"
    FAIL=1
    continue
  fi

  # 2. 真实验证 ops + 私钥（此刻 sshd 还在原端口）
  if verify="$(as_ops "${ip}" "${INIT_SSH_PORT}" 'whoami' 2>&1)" && [ "${verify}" = "${OPS_USER}" ]; then
    log_info "  ✅ ${OPS_USER} + 私钥登录验证通过"
  else
    log_error "  ❌ ${OPS_USER} + 私钥验证失败: ${verify}"
    log_error "     为安全起见，本节点的 sshd 配置未做任何改动"
    FAIL=1
    continue
  fi

  # 3. sudo 免密验证（后续所有 ansible 任务都依赖它）
  if as_ops "${ip}" "${INIT_SSH_PORT}" 'sudo -n true' 2>/dev/null; then
    log_info "  ✅ ${OPS_USER} sudo 免密验证通过"
  else
    log_error "  ❌ ${OPS_USER} 无法免密 sudo（检查 /etc/sudoers.d/${OPS_USER}）"
    FAIL=1
    continue
  fi

  # 4. 收紧 root 登录 / 改端口
  if prod_bool "${DISABLE_ROOT_SSH_AFTER_INIT}"; then
    # ROOT_SSH_POLICY 默认 prohibit-password；若你的运维方式依赖 root+密码，
    # 把它改成 no 之前请确保 ops 密钥已就绪（上面第 2 步已验证）
    if as_init "${ip}" "${HARDEN_SCRIPT}"; then
      log_info "  ✅ 已收紧 root 登录: PermitRootLogin=${ROOT_SSH_POLICY}"
      # 端口可能被改掉，改完必须再连一次确认还进得去（否则就是把自己关在门外）
      if [ "${SSH_PORT}" != "${INIT_SSH_PORT}" ]; then
        sleep 1
        if as_ops "${ip}" "${SSH_PORT}" 'true' 2>/dev/null; then
          log_info "  ✅ 新端口 ${SSH_PORT} 验证通过"
        else
          log_error "  ❌ 改成 SSH_PORT=${SSH_PORT} 后连不上了，请用 ${INIT_SSH_PORT} 端口登上去检查 /etc/ssh/sshd_config.d/"
          FAIL=1
          continue
        fi
      fi
    else
      log_warn "  ⚠️ 收紧 sshd 失败（可能需要手工检查 /etc/ssh/sshd_config.d/）"
    fi
  else
    log_info "  ⏭️ DISABLE_ROOT_SSH_AFTER_INIT=false，跳过 sshd 收紧"
  fi
done < <(ipam_hosts)

if [ "${FAIL}" -ne 0 ]; then
  log_error "部分节点的 SSH 初始化未完成，请按上面提示修复后重跑：bash production/scripts/ssh-setup.sh"
  exit 1
fi

log_mark "SSH 初始化全部完成。后续 ansible 任务将以 ${OPS_USER}@<节点>:${SSH_PORT} 连接"
