#!/bin/bash
# k3s-ops 节点名解析库
# Usage: source lib/nodes.sh
#
# 提供以下函数:
#   normalize_host     — 短名/完整主机名 → 完整主机名
#   host_exists        — 校验完整主机名是否在 nodes.yml 中
#   node_role          — 查询节点角色（server/agent）
#   resolve_host       — 归一化 + 校验，结果写入全局 RESOLVED_HOST
#
# 规则：所有接受节点名的命令都接受两种写法
#   短名         agent-1
#   完整主机名   k3s-demo-agent-1

LIB_NODES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${LIB_NODES_DIR}/.." && pwd)"
NODES_YML="${NODES_DIR:-${PROJECT_DIR}}/vagrant/nodes.yml"

# 集群名：调用方已导出则复用，否则从 nodes.yml 读取
if [ -z "${CLUSTER_NAME:-}" ]; then
  CLUSTER_NAME="$(python3 -c "
import yaml
with open('${NODES_YML}') as f:
    print(yaml.safe_load(f)['cluster_name'])
" 2>/dev/null)"
fi

# 归一化：短名与完整主机名都接受
normalize_host() {
  local name="$1"
  case "${name}" in
    "${CLUSTER_NAME}-"*) echo "${name}" ;;
    *)                  echo "${CLUSTER_NAME}-${name}" ;;
  esac
}

# 读取 nodes.yml 指定的字段（第二个参数为字段名）
_node_field() {
  local host="$1" field="$2"
  python3 -c "
import yaml
with open('${NODES_YML}') as f:
    cfg = yaml.safe_load(f)
nodes = {'${CLUSTER_NAME}-' + n['name']: n for n in cfg.get('nodes', [])}
node = nodes.get('$host')
if node is not None:
    print(node.get('$field', ''))
" 2>/dev/null
}

# 完整主机名是否存在于 nodes.yml（是则返回 0）
host_exists() {
  [ -n "$(_node_field "$1" name)" ]
}

# 查询节点角色，无此节点时输出为空
node_role() {
  _node_field "$1" role
}

# 归一化 + 校验：成功时 RESOLVED_HOST 为完整主机名，
# 节点不存在则报错并退出 1
resolve_host() {
  RESOLVED_HOST="$(normalize_host "$1")"
  if ! host_exists "${RESOLVED_HOST}"; then
    log_error "Node '$1' not found in ${NODES_YML}"
    exit 1
  fi
}
