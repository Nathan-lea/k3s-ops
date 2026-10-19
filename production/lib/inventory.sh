#!/bin/bash
# =============================================================================
# Ansible 清单生成器 —— ipam.yml + cluster.env 的唯一落地出口
# =============================================================================
# 用法: source production/lib/config.sh
#       source production/lib/ipam.sh
#       source production/lib/inventory.sh
#       inventory_generate          # 生成 hosts.yml 与 extra_vars.yml
#
# 产出（两个文件都在 .gitignore 里，因为含真实 IP 与密码）:
#   ansible/inventory/hosts.yml        Ansible inventory（ansible_host/user/port/key）
#   ansible/inventory/extra_vars.yml   父角色需要的全部 k3s_* 变量 + production 自己的 prod.*
#
# 为什么必须有这一层：父仓库的 ansible/inventory.yml 是空占位，group_vars/* 在独立
# inventory 下不会加载，所以这里是这些变量的**唯一写入点**。要改集群参数就改
# config/cluster.env 或 config/ipam.yml，不要手改生成物（下次生成会被覆盖）。
# =============================================================================

INVENTORY_HOSTS_FILE="${INVENTORY_DIR}/hosts.yml"
INVENTORY_EXTRA_VARS_FILE="${INVENTORY_DIR}/extra_vars.yml"

# 需要传给生成器的配置项（config.sh 里都有同名变量）
_INV_ENV_KEYS=(
  CLUSTER_NAME CLUSTER_DOMAIN
  K3S_VERSION K3S_INSTALL_MODE K3S_DOWNLOAD_URL
  POD_CIDR SVC_CIDR CNI DISABLE_TRAEFIK DISABLE_SERVICELB TAINT_SERVER
  USE_UFW UFW_ALLOW_CIDR SSH_PORT TIMEZONE CHRONY_SERVERS OPS_USER APT_UPDATE_CACHE
  LOCALDISK_ENABLED LOCALDISK_PATH LOCALDISK_SC_NAME LOCALDISK_DEFAULT_SC
  LOCALDISK_RECLAIM_POLICY LOCALDISK_IMAGE LOCALDISK_HELPER_IMAGE
  STORAGE_NFS_ENABLED IN_CLUSTER_NFS NFS_SERVER NFS_PATH NFS_VERSION
  NFS_SC_NAME NFS_RECLAIM_POLICY NFS_ARCHIVE_ON_DELETE NFS_PROVISIONER_IMAGE NFS_DEFAULT_SC
  INGRESS_ENABLED INGRESS_CHART_VERSION INGRESS_KIND
  INGRESS_HTTP_PORT INGRESS_HTTPS_PORT INGRESS_NODE_SELECTOR
  CERT_MANAGER_ENABLED CERT_MANAGER_CHART_VERSION ACME_EMAIL
  RANCHER_ENABLED RANCHER_CHART_VERSION RANCHER_HOSTNAME RANCHER_REPLICAS
  RANCHER_BOOTSTRAP_PASSWORD RANCHER_TLS_SOURCE
  CHARTS_MODE ARTIFACTS_DIR REGISTRY_ENDPOINT REGISTRY_PATH_PREFIX
  REGISTRY_USERNAME REGISTRY_PASSWORD HELM_VERSION HELM_DOWNLOAD_URL
  ENABLE_LIMITS PROD_REMOVE_TARGET
)

# 默认镜像加速（与父仓库 docs/manual-deployment.md 中验证过的清单一致）
_default_containerd_mirrors_yaml() {
  cat <<'YAML'
docker.io: ["https://docker.1panel.live", "https://docker-0.unsee.tech"]
registry.k8s.io: ["https://docker.1panel.live"]
registry.k8s.io/ingress-nginx: ["https://docker.1panel.live"]
quay.io: ["https://docker.1panel.live"]
gcr.io: ["https://gcr.mirrors.ustc.edu.cn"]
YAML
}

# REGISTRY_MIRRORS="host=url,host2=url2" → YAML 片段
_mirrors_yaml_from_env() {
  python3 -c '
import sys
out = {}
for pair in sys.argv[1].split(","):
    pair = pair.strip()
    if not pair:
        continue
    host, _, url = pair.partition("=")
    if not host or not url:
        raise SystemExit("REGISTRY_MIRRORS 格式错误（应为 host=url,host2=url2）: " + pair)
    out.setdefault(host.strip(), []).append(url.strip())
for k, v in out.items():
    print("%s: [%s]" % (k, ", ".join("\"%s\"" % i for i in v)))
' "${REGISTRY_MIRRORS}"
}

inventory_generate() {
  mkdir -p "${INVENTORY_DIR}"

  local mirrors_yaml
  if [ -n "${REGISTRY_MIRRORS}" ]; then
    mirrors_yaml="$(_mirrors_yaml_from_env)"
  else
    mirrors_yaml="$(_default_containerd_mirrors_yaml)"
  fi

  local -a env_args=()
  local k
  for k in "${_INV_ENV_KEYS[@]}"; do
    env_args+=("${k}=${!k}")
  done
  env_args+=(
    "OPS_SSH_KEY=${OPS_SSH_KEY}"
    "MIRRORS_YAML=${mirrors_yaml}"
    "K3S_RESOLVED_VERSION=${K3S_RESOLVED_VERSION:-${K3S_VERSION}}"
    "CHART_DIR=${CHARTS_DIR}"
    "PROD_DIR_IN=${PROD_DIR}"
    "FIRST_SERVER_HOST=$(ipam_first_server_host)"
    "FIRST_SERVER_IP=$(ipam_first_server_ip)"
  )

  # ---- 1) Ansible inventory -------------------------------------------------
  env "${env_args[@]}" python3 - "${IPAM_FILE}" "${INVENTORY_HOSTS_FILE}" <<'PY'
import os, sys, yaml

ipam_path, out_path = sys.argv[1], sys.argv[2]
with open(ipam_path) as f:
    cfg = yaml.safe_load(f) or {}
nodes = cfg.get('nodes') or []
E = os.environ

def host_vars(n):
    return {
        'ansible_host': str(n.get('ip')),
        'ansible_port': int(E['SSH_PORT']),
        'ansible_user': E['OPS_USER'],
        'ansible_ssh_private_key_file': E['OPS_SSH_KEY'],
        'node_ip': str(n.get('ip')),
        'node_role': str(n.get('role') or '').strip(),
        'node_name': str(n.get('hostname')),
        'node_labels': n.get('labels') or {},
    }

buckets = {'server': {'hosts': {}}, 'agent': {'hosts': {}}}
for n in nodes:
    if not isinstance(n, dict):
        continue
    name = str(n.get('hostname') or '').strip()
    role = str(n.get('role') or '').strip()
    if not name or role not in buckets:
        continue
    buckets[role]['hosts'][name] = host_vars(n)

children = {
    'k3s_cluster': {'children': buckets},
    # 专用组：playbook 的 hosts: 关键字拿不到 inventory vars（host pattern 在
    # 模板展开之前就解析），所以这里直接落成组，hosts: first_server 无需模板即可用。
    'first_server': {'hosts': {E['FIRST_SERVER_HOST']: {}}},
}

# scale.sh remove 指定的摘除目标。group 始终存在（无目标时 hosts 为空），
# 这样 hosts: remove_target 永远是合法的 host pattern。
_rm = (E.get('PROD_REMOVE_TARGET') or '').strip()
children['remove_target'] = {'hosts': ({_rm: {}} if _rm else {})}

inv = {
    'all': {
        'vars': {
            'cluster_name': E['CLUSTER_NAME'],
            'first_server_host': E['FIRST_SERVER_HOST'],
            'first_server_ip': E['FIRST_SERVER_IP'],
        },
        'children': children,
    }
}

with open(out_path, 'w') as f:
    f.write('# 由 production/lib/inventory.sh 自动生成 —— 不要手改\n')
    yaml.safe_dump(inv, f, allow_unicode=True, sort_keys=False, default_flow_style=False)
PY

  # ---- 2) extra_vars -------------------------------------------------------
  env "${env_args[@]}" python3 - "${INVENTORY_EXTRA_VARS_FILE}" "${IPAM_FILE}" <<'PY'
import os, sys, yaml

out_path, ipam_path = sys.argv[1], sys.argv[2]
E = os.environ

def b(name, default=False):
    v = E.get(name, '')
    if v == '':
        return default
    return str(v).lower() in ('true', '1', 'yes', 'on')

def i(name, default=0):
    try:
        return int(str(E.get(name, default)).strip())
    except (TypeError, ValueError):
        return default

def s(name, default=''):
    v = E.get(name)
    return default if v is None else str(v)

version = E['K3S_RESOLVED_VERSION']
download_url = s('K3S_DOWNLOAD_URL') or \
    'https://github.com/k3s-io/k3s/releases/download/%s/k3s' % version

mirrors = yaml.safe_load(E['MIRRORS_YAML']) or {}
registry_credentials = {}

# Artifactory：把公共仓库整体指到内网 endpoint
if s('REGISTRY_ENDPOINT'):
    ep = s('REGISTRY_ENDPOINT')
    prefix = s('REGISTRY_PATH_PREFIX')

    def url(repo):
        return 'https://%s/%s' % (ep, ('%s/%s' % (prefix, repo)) if prefix else repo)

    mirrors = {
        'docker.io': [url('docker-remote')],
        'registry.k8s.io': [url('k8s-remote')],
        'quay.io': [url('quay-remote')],
        'gcr.io': [url('gcr-remote')],
    }
    if s('REGISTRY_USERNAME'):
        registry_credentials[ep] = {
            'username': s('REGISTRY_USERNAME'),
            'password': s('REGISTRY_PASSWORD'),
        }

chart_dir = E['CHART_DIR']
charts_mode = s('CHARTS_MODE', 'local')
expected_charts = []
if charts_mode == 'local':
    if b('INGRESS_ENABLED', True):
        expected_charts.append('%s/ingress-nginx-%s.tgz' % (chart_dir, s('INGRESS_CHART_VERSION')))
    if b('CERT_MANAGER_ENABLED', True):
        expected_charts.append('%s/cert-manager-%s.tgz' % (chart_dir, s('CERT_MANAGER_CHART_VERSION')))
    if b('RANCHER_ENABLED', True):
        expected_charts.append('%s/rancher-%s.tgz' % (chart_dir, s('RANCHER_CHART_VERSION')))

# 节点标签（ipam.yml 的 labels）→ ["<node> k=v", ...]，供 kubectl label 逐条应用
with open(ipam_path) as f:
    _ipam = yaml.safe_load(f) or {}
node_labels = []
for _n in (_ipam.get('nodes') or []):
    if not isinstance(_n, dict):
        continue
    _host = str(_n.get('hostname') or '').strip()
    for _k, _v in (_n.get('labels') or {}).items():
        node_labels.append('%s %s=%s' % (_host, _k, _v))

prod = {
    'cluster_name': s('CLUSTER_NAME'),
    'cluster_domain': s('CLUSTER_DOMAIN'),
    'localdisk': {
        'enabled': b('LOCALDISK_ENABLED', True),
        'path': s('LOCALDISK_PATH', '/opt/k8s-local-path'),
        'sc_name': s('LOCALDISK_SC_NAME', 'localdisk'),
        'is_default': b('LOCALDISK_DEFAULT_SC', True),
        'reclaim_policy': s('LOCALDISK_RECLAIM_POLICY', 'Retain'),
        'image': s('LOCALDISK_IMAGE'),
        'helper_image': s('LOCALDISK_HELPER_IMAGE'),
        'namespace': 'local-path-storage',
    },
    'nfs': {
        'enabled': b('STORAGE_NFS_ENABLED', True),
        'in_cluster': b('IN_CLUSTER_NFS', False),
        'server': s('NFS_SERVER'),
        'path': s('NFS_PATH', '/nfs-share'),
        'version': i('NFS_VERSION', 4),
        'sc_name': s('NFS_SC_NAME', 'nfs-client'),
        'is_default': b('NFS_DEFAULT_SC', False),
        'reclaim_policy': s('NFS_RECLAIM_POLICY', 'Delete'),
        'archive_on_delete': b('NFS_ARCHIVE_ON_DELETE', False),
        'image': s('NFS_PROVISIONER_IMAGE'),
        'namespace': 'nfs-provisioner',
        'in_cluster_namespace': 'nfs-system',
    },
    'ingress': {
        'enabled': b('INGRESS_ENABLED', True),
        'chart_version': s('INGRESS_CHART_VERSION'),
        'kind': s('INGRESS_KIND', 'DaemonSet'),
        'http_port': i('INGRESS_HTTP_PORT', 80),
        'https_port': i('INGRESS_HTTPS_PORT', 443),
        'node_selector': s('INGRESS_NODE_SELECTOR'),
        'namespace': 'ingress-nginx',
        'release': 'ingress-nginx',
    },
    'certmanager': {
        'enabled': b('CERT_MANAGER_ENABLED', True),
        'chart_version': s('CERT_MANAGER_CHART_VERSION'),
        'acme_email': s('ACME_EMAIL'),
        'namespace': 'cert-manager',
        'release': 'cert-manager',
    },
    'rancher': {
        'enabled': b('RANCHER_ENABLED', True),
        'chart_version': s('RANCHER_CHART_VERSION'),
        'hostname': s('RANCHER_HOSTNAME'),
        'replicas': i('RANCHER_REPLICAS', 1),
        'bootstrap_password': s('RANCHER_BOOTSTRAP_PASSWORD'),
        'tls_source': s('RANCHER_TLS_SOURCE', 'rancher'),
        'certmanager_version': s('CERT_MANAGER_CHART_VERSION'),
        'namespace': 'cattle-system',
        'release': 'rancher',
    },
    'helm': {
        'version': s('HELM_VERSION'),
        'download_url': s('HELM_DOWNLOAD_URL'),
        'bin': s('HELM_BIN'),
    },
    'charts_mode': charts_mode,
    'charts_dir': chart_dir,
    'artifacts_dir': E['ARTIFACTS_DIR'],
    'registry_endpoint': s('REGISTRY_ENDPOINT'),
}

extra = {
    'cluster_name': s('CLUSTER_NAME'),
    'prod_dir': E['PROD_DIR_IN'],
    'prod': prod,

    # ---- k3s 路径与版本（父角色变量名，勿改）----
    'k3s_version': version,
    'k3s_install_dir': '/usr/local/bin',
    'k3s_config_dir': '/etc/rancher/k3s',
    'k3s_data_dir': '/var/lib/rancher/k3s',
    'k3s_server_bin': '/usr/local/bin/k3s',
    'k3s_token_dir': '/var/lib/rancher/k3s/server',
    'k3s_token_file': '/var/lib/rancher/k3s/server/node-token',
    'k3s_etcd_snapshot_dir': '/var/lib/rancher/k3s/server/db/snapshots',
    'k3s_download_url': download_url,
    # offline：节点上的 k3s 二进制由 scripts/offline-load.sh 预先分发，不要覆盖
    'k3s_skip_download': s('K3S_INSTALL_MODE') == 'offline',

    # ---- k3s 配置（父模板读取，键名勿改）----
    'k3s_config': {
        'disable_traefik': b('DISABLE_TRAEFIK', True),
        'disable_servicelb': b('DISABLE_SERVICELB', True),
        # localdisk 自管时必须关掉 k3s 内置 local-storage，否则它会覆盖 /var/lib/rancher/k3s/storage
        'disable_local_storage': b('LOCALDISK_ENABLED', True),
        'flannel_backend': 'vxlan' if s('CNI') == 'flannel' else 'none',
        'taint_server': b('TAINT_SERVER', False),
        'cluster_cidr': s('POD_CIDR'),
        'service_cidr': s('SVC_CIDR'),
    },

    # ---- containerd ----
    'containerd_mirrors': mirrors,
    'containerd_registry_credentials': registry_credentials,

    # ---- 服务器初始化（production 自有变量，10-os-init.yml 使用）----
    'use_ufw': b('USE_UFW', True),
    'ufw_allow_cidr': s('UFW_ALLOW_CIDR'),
    'prod_ssh_port': i('SSH_PORT', 22),
    'prod_timezone': s('TIMEZONE', 'Asia/Shanghai'),
    'prod_chrony_servers': s('CHRONY_SERVERS'),
    'prod_ops_user': s('OPS_USER', 'ops'),
    'prod_localdisk_path': s('LOCALDISK_PATH'),
    'prod_enable_limits': b('ENABLE_LIMITS', True),
    'prod_apt_update': b('APT_UPDATE_CACHE', True),

    # ---- 离线 chart 校验（05-preflight.yml 使用）----
    'prod_expected_charts': expected_charts,

    # ---- IPAM 里的节点标签（30-addons.yml 逐条 kubectl label 应用）----
    'prod_node_labels': node_labels,
}

with open(out_path, 'w') as f:
    f.write('# 由 production/lib/inventory.sh 自动生成 —— 不要手改\n')
    yaml.safe_dump(extra, f, allow_unicode=True, sort_keys=False, default_flow_style=False)
PY
}

inventory_show_summary() {
  log_info "inventory : ${INVENTORY_HOSTS_FILE}"
  log_info "extra vars: ${INVENTORY_EXTRA_VARS_FILE}"
  log_info "  server: $(ipam_servers | tr '\n' ' ')"
  log_info "  agent : $(ipam_agents | tr '\n' ' ')"
  log_info "  init  : $(ipam_first_server_host) ($(ipam_first_server_ip))"
}
