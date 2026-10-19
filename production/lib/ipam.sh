#!/bin/bash
# =============================================================================
# IPAM 库 —— config/ipam.yml 的唯一解析入口
# =============================================================================
# 用法: source production/lib/config.sh; source production/lib/ipam.sh
#
# 提供:
#   ipam_load                  — 解析并缓存 ipam.yml（其他函数自动调用）
#   ipam_validate              — 完整校验；有错返回 1（错误/告警打印到 stdout）
#   ipam_hosts                 — 按文件顺序输出所有 hostname
#   ipam_servers               — 按文件顺序输出 server 的 hostname
#   ipam_agents                — 按文件顺序输出 agent 的 hostname
#   ipam_first_server_host     — 第一条 role: server 的 hostname
#   ipam_first_server_ip
#   ipam_node_ip <host>
#   ipam_node_role <host>
#   ipam_node_labels <host>    — 输出 "k=v" 每行一个（可能为空）
#   ipam_has_host <host>
#   ipam_node_exists_ip <ip>   — 该 IP 是否已分配
#
# 依赖: python3 + PyYAML（ipam.yml 是 YAML，不手写解析器）
# =============================================================================

if [ -z "${IPAM_FILE:-}" ]; then
  echo "[ERROR] ipam.sh 需要先 source config.sh（缺 IPAM_FILE）" >&2
  return 1 2>/dev/null || exit 1
fi

declare -A IPAM_IP=()
declare -A IPAM_ROLE=()
declare -A IPAM_LABELS=()
declare -a IPAM_ORDER=()
declare -a IPAM_SERVERS=()
declare -a IPAM_AGENTS=()
_IPAM_LOADED=0

# 把 ipam.yml 归一化成 TSV: hostname \t ip \t role \t labels(k=v;k=v)
_ipam_tsv() {
  python3 - "$IPAM_FILE" <<'PY'
import sys, yaml
path = sys.argv[1]
with open(path) as f:
    cfg = yaml.safe_load(f) or {}
nodes = cfg.get('nodes') or []
for n in nodes:
    if not isinstance(n, dict):
        continue
    h = str(n.get('hostname') or '').strip()
    ip = str(n.get('ip') or '').strip()
    role = str(n.get('role') or '').strip()
    labels = n.get('labels') or {}
    lab = ';'.join('%s=%s' % (k, v) for k, v in labels.items())
    print('\t'.join([h, ip, role, lab]))
PY
}

ipam_load() {
  [ "${_IPAM_LOADED}" = "1" ] && return 0
  local h ip role lab
  while IFS=$'\t' read -r h ip role lab; do
    [ -n "${h}" ] || continue
    IPAM_ORDER+=("${h}")
    IPAM_IP["${h}"]="${ip}"
    IPAM_ROLE["${h}"]="${role}"
    IPAM_LABELS["${h}"]="${lab}"
    case "${role}" in
      server) IPAM_SERVERS+=("${h}") ;;
      agent)  IPAM_AGENTS+=("${h}") ;;
    esac
  done < <(_ipam_tsv)
  _IPAM_LOADED=1
}

# ---------------------------------------------------------------------------
# 校验
# ---------------------------------------------------------------------------
ipam_validate() {
  if [ ! -f "${IPAM_FILE}" ]; then
    echo "ERROR:找不到 IPAM 文件: ${IPAM_FILE}"
    return 1
  fi

  local out rc=0
  out="$(python3 - "${IPAM_FILE}" "${CLUSTER_NAME:-}" <<'PY'
import ipaddress, sys, yaml

path, cluster_name = sys.argv[1], sys.argv[2]
errors, warnings = [], []

try:
    with open(path) as f:
        cfg = yaml.safe_load(f)
except Exception as e:
    print('ERROR:ipam.yml 不是合法 YAML: %s' % e)
    sys.exit(1)

if not isinstance(cfg, dict):
    print('ERROR:ipam.yml 顶层必须是映射（key: value）')
    sys.exit(1)

nodes = cfg.get('nodes')
if not isinstance(nodes, list) or not nodes:
    print('ERROR:ipam.yml 缺少非空的 nodes 列表')
    sys.exit(1)

subnet = cfg.get('subnet')
net = None
if subnet:
    try:
        net = ipaddress.ip_network(str(subnet), strict=False)
    except Exception as e:
        errors.append('subnet 不是合法网段: %s (%s)' % (subnet, e))
else:
    warnings.append('未设置 subnet：将跳过"IP 是否在网段内"的校验')

gateway = str(cfg.get('gateway') or '')
seen_host, seen_ip = {}, {}
servers = 0
for idx, n in enumerate(nodes, start=1):
    where = 'nodes[%d]' % idx
    if not isinstance(n, dict):
        errors.append('%s 不是映射' % where)
        continue
    host = str(n.get('hostname') or '').strip()
    ip = str(n.get('ip') or '').strip()
    role = str(n.get('role') or '').strip()

    if not host:
        errors.append('%s 缺少 hostname' % where)
    if not ip:
        errors.append('%s 缺少 ip' % where)
    if role not in ('server', 'agent'):
        errors.append('%s 的 role 必须是 server 或 agent（当前: %r）' % (where, role))
    if role == 'server':
        servers += 1
    if host:
        if host in seen_host:
            errors.append('hostname 重复: %s' % host)
        seen_host[host] = idx
    if ip:
        if ip in seen_ip:
            errors.append('ip 重复: %s（%s 与 nodes[%d]）' % (ip, host, seen_ip[ip]))
        seen_ip[ip] = idx
        try:
            addr = ipaddress.ip_address(ip)
        except Exception:
            errors.append('%s 的 ip 不是合法 IPv4/IPv6: %s' % (where, ip))
            continue
        if net is not None:
            if addr.version != net.version:
                errors.append('%s 的 ip 与 subnet 版本不一致: %s' % (where, ip))
            elif addr not in net:
                errors.append('%s 的 ip %s 不在 subnet %s 内' % (where, ip, net))
            elif addr == net.network_address:
                errors.append('%s 的 ip %s 是网段地址，不能分配给节点' % (where, ip))
            elif addr == net.broadcast_address:
                errors.append('%s 的 ip %s 是广播地址，不能分配给节点' % (where, ip))
        if gateway and ip == gateway:
            errors.append('%s 的 ip %s 与 gateway 冲突' % (where, ip))
    if host and cluster_name and not host.startswith(cluster_name):
        warnings.append('hostname %s 未以 CLUSTER_NAME（%s）开头，确认是不是打错了' % (host, cluster_name))

if servers == 0:
    errors.append('至少要有一台 role: server（集群 init 节点）')
elif servers > 1 and servers % 2 == 0:
    warnings.append('server 数量为偶数（%d）：嵌入式 etcd 建议 1/3/5 台，偶数台不增加容错' % servers)

# 非 server 的第一条（role: server 的先后顺序决定谁是 init 节点）——给出显式提示
# 注意：这是每次都会出现的常规信息，不是告警，走 INFO 通道
infos = []
first_server_idx = next((i for i, n in enumerate(nodes, start=1)
                         if isinstance(n, dict) and n.get('role') == 'server'), None)
if first_server_idx is not None:
    infos.append('集群 init 节点 = nodes[%d]（%s）：这是 ipam.yml 里第一条 role: server'
                 % (first_server_idx, nodes[first_server_idx - 1].get('hostname')))

for e in errors:
    print('ERROR:' + e)
for w in warnings:
    print('WARN:' + w)
for i in infos:
    print('INFO:' + i)
sys.exit(1 if errors else 0)
PY
)"
  rc=$?

  local line
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    case "${line}" in
      ERROR:*) log_error "IPAM: ${line#ERROR:}" ;;
      WARN:*)  log_warn  "IPAM: ${line#WARN:}" ;;
      INFO:*)  log_info  "IPAM: ${line#INFO:}" ;;
      *)       log_info  "IPAM: ${line}" ;;
    esac
  done <<< "${out}"

  return "${rc}"
}

# ---------------------------------------------------------------------------
# 查询（自动 load）
# ---------------------------------------------------------------------------
ipam_hosts()           { ipam_load; printf '%s\n' "${IPAM_ORDER[@]}"; }
ipam_servers()         { ipam_load; printf '%s\n' "${IPAM_SERVERS[@]}"; }
ipam_agents()          { ipam_load; printf '%s\n' "${IPAM_AGENTS[@]}"; }
ipam_first_server_host() { ipam_load; printf '%s' "${IPAM_SERVERS[0]:-}"; }
ipam_first_server_ip()   { ipam_load; printf '%s' "${IPAM_IP[$(ipam_first_server_host)]:-}"; }
ipam_node_ip()         { ipam_load; printf '%s' "${IPAM_IP[${1}]:-}"; }
ipam_node_role()       { ipam_load; printf '%s' "${IPAM_ROLE[${1}]:-}"; }
ipam_node_labels()     { ipam_load; printf '%s' "${IPAM_LABELS[${1}]:-}" | tr ';' '\n'; }
ipam_has_host()        { ipam_load; [ -n "${IPAM_IP[${1}]:-}" ]; }
ipam_count()           { ipam_load; printf '%s' "${#IPAM_ORDER[@]}"; }
ipam_count_servers()   { ipam_load; printf '%s' "${#IPAM_SERVERS[@]}"; }

ipam_node_exists_ip() {
  ipam_load
  local h
  for h in "${IPAM_ORDER[@]}"; do
    [ "${IPAM_IP[${h}]}" = "${1}" ] && return 0
  done
  return 1
}

# 短名（xxx-k8s-01 → 01 / agent-1 → agent-1）与完整主机名都接受，归一化成完整主机名
ipam_resolve_host() {
  ipam_load
  local name="$1"
  if ipam_has_host "${name}"; then
    printf '%s' "${name}"
    return 0
  fi
  local candidate="${CLUSTER_NAME:-}-${name}"
  if ipam_has_host "${candidate}"; then
    printf '%s' "${candidate}"
    return 0
  fi
  # 只给序号（如 03 / 3）时也认
  local padded
  padded="$(printf '%02d' "${name}" 2>/dev/null || printf '%s' "${name}")"
  candidate="${CLUSTER_NAME:-}-k8s-${padded}"
  if ipam_has_host "${candidate}"; then
    printf '%s' "${candidate}"
    return 0
  fi
  return 1
}
