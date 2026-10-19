#!/bin/bash
# =============================================================================
# selftest.sh —— lib/ipam.sh 与 lib/config.sh 的正反例自测（只读，不碰任何机器）
# =============================================================================
# 为什么要有：这两个库是"一条命令"能否安全开箱的关键，而它们的失败路径平时很难
# 被触发到（改配置才能看到报错）。把正反例固化下来，改库之后跑一遍就知道有没有
# 把某条校验改坏。
#
# 用法:
#   ./production/scripts/selftest.sh          # 全跑
#   ./production/scripts/selftest.sh ipam     # 只跑 IPAM
#   ./production/scripts/selftest.sh config   # 只跑配置
#
# 退出码: 0 = 全部符合预期；1 = 有用例不符预期
# =============================================================================
set -uo pipefail

PROD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/opencode/selftest.XXXXXX 2>/dev/null || mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASS=0
FAIL=0

expect() { # $1=描述 $2=pass|fail  其余为要执行的命令
  local desc="$1" want="$2"
  shift 2
  local out rc why
  out="$("$@" 2>&1)"; rc=$?
  # 失败原因：优先取第一行带 ERROR/配置错误/IPAM 的，取不到就退化成最后一行非空输出
  why="$(printf '%s\n' "${out}" | grep -m1 -o '配置错误.*\|\[ERROR\].*' | head -1)"
  [ -n "${why}" ] || why="$(printf '%s\n' "${out}" | grep -v '^[[:space:]]*$' | tail -1)"
  if [ "${want}" = "fail" ]; then
    if [ "${rc}" -ne 0 ]; then
      printf '  PASS(拒绝) %s\n        └─ %s\n' "${desc}" "${why}"
      PASS=$((PASS + 1))
    else
      printf '  FAIL(应拒绝却通过) %s\n' "${desc}"; FAIL=$((FAIL + 1))
    fi
  else
    if [ "${rc}" -eq 0 ]; then
      printf '  PASS(通过) %s\n' "${desc}"; PASS=$((PASS + 1))
    else
      printf '  FAIL(应通过却拒绝) %s\n        └─ %s\n' "${desc}" "${why}"
      FAIL=$((FAIL + 1))
    fi
  fi
}

# ---------------------------------------------------------------------------
# IPAM
# ---------------------------------------------------------------------------
test_ipam() {
  echo "IPAM 正反例（${PROD_DIR}/lib/ipam.sh）"

  ipam_case() { # $1=描述 $2=期望 $3=nodes yaml
    cat > "${WORK}/ipam.yml" <<YAML
subnet: 192.168.100.0/24
gateway: 192.168.100.1
domain: k8s.example.com
nodes:
$3
YAML
    ipam_run "$1" "$2"
  }

  ipam_raw() { # $1=描述 $2=期望 $3=整个 ipam.yml 内容（不套模板）
    printf '%s\n' "$3" > "${WORK}/ipam.yml"
    ipam_run "$1" "$2"
  }

  ipam_run() {
    expect "$1" "$2" bash -c "IPAM_FILE='${WORK}/ipam.yml'; . '${PROD_DIR}/lib/config.sh'; . '${PROD_DIR}/lib/ipam.sh'; ipam_validate"
  }

  # ---- 正例：合法拓扑 + 仅告警不该中断 ----
  ipam_case "1 台 server（最小集群）" pass \
    "  - {hostname: xxx-k8s-01, ip: 192.168.100.11, role: server}"
  ipam_case "2 server + 1 agent" pass \
    "  - {hostname: xxx-k8s-01, ip: 192.168.100.11, role: server}
  - {hostname: xxx-k8s-02, ip: 192.168.100.12, role: server}
  - {hostname: xxx-k8s-03, ip: 192.168.100.13, role: agent}"
  ipam_case "偶数台 server（只告警，不中断）" pass \
    "  - {hostname: xxx-k8s-01, ip: 192.168.100.11, role: server}
  - {hostname: xxx-k8s-02, ip: 192.168.100.12, role: server}"
  ipam_case "短名 hostname（只告警，不中断）" pass \
    "  - {hostname: k8s-01, ip: 192.168.100.11, role: server}"
  ipam_raw "没有 subnet（跳过网段校验，不中断）" pass \
"nodes:
  - {hostname: xxx-k8s-01, ip: 10.9.9.11, role: server}"

  # ---- 反例：都必须拒绝 ----
  ipam_case "一台 server 都没有" fail \
    "  - {hostname: xxx-k8s-01, ip: 192.168.100.11, role: agent}"
  ipam_case "IP 重复" fail \
    "  - {hostname: xxx-k8s-01, ip: 192.168.100.11, role: server}
  - {hostname: xxx-k8s-02, ip: 192.168.100.11, role: server}"
  ipam_case "hostname 重复" fail \
    "  - {hostname: xxx-k8s-01, ip: 192.168.100.11, role: server}
  - {hostname: xxx-k8s-01, ip: 192.168.100.12, role: server}"
  ipam_case "角色非法（master）" fail \
    "  - {hostname: xxx-k8s-01, ip: 192.168.100.11, role: master}"
  ipam_case "IP 越界（999）" fail \
    "  - {hostname: xxx-k8s-01, ip: 192.168.100.999, role: server}"
  ipam_case "IP 不在 subnet 内" fail \
    "  - {hostname: xxx-k8s-01, ip: 10.9.9.9, role: server}"
  ipam_case "IP 与 gateway 冲突" fail \
    "  - {hostname: xxx-k8s-01, ip: 192.168.100.1, role: server}"
  ipam_case "nodes 为空" fail ""
}

# ---------------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------------
test_config() {
  echo "配置正反例（${PROD_DIR}/lib/config.sh）"
  cp "${PROD_DIR}/config/cluster.env" "${WORK}/cluster.env"
  printf 'subnet: 192.168.100.0/24\nnodes:\n  - {hostname: xxx-k8s-01, ip: 192.168.100.11, role: server}\n' \
    > "${WORK}/ipam-nodom.yml"

  cfg() { # 覆盖若干 KEY=VAL（就地改测试副本）
    local kv k v
    for kv in "$@"; do
      k="${kv%%=*}"; v="${kv#*=}"
      if grep -q "^${k}=" "${WORK}/cluster.env"; then
        sed -i "s|^${k}=.*|${k}=${v}|" "${WORK}/cluster.env"
      else
        echo "${k}=${v}" >> "${WORK}/cluster.env"
      fi
    done
  }
  chk()     { bash -c "PROD_CONFIG_FILE='${WORK}/cluster.env'; IPAM_FILE='${PROD_DIR}/config/ipam.yml'; . '${PROD_DIR}/lib/config.sh'; prod_validate_config"; }
  chk_nodom(){ bash -c "PROD_CONFIG_FILE='${WORK}/cluster.env'; IPAM_FILE='${WORK}/ipam-nodom.yml'; . '${PROD_DIR}/lib/config.sh'; prod_validate_config"; }
  again()   { cp "${PROD_DIR}/config/cluster.env" "${WORK}/cluster.env"; }

  # ---- 正例 ----
  again;                                              expect "默认 cluster.env 合法" pass chk
  again; cfg K3S_VERSION=stable;                      expect "K3S_VERSION=stable" pass chk
  again; cfg K3S_VERSION=v1.31.4+k3s1;                expect "K3S_VERSION=具体版本" pass chk
  again; cfg USE_UFW=false;                           expect "USE_UFW=false" pass chk
  again; cfg INGRESS_ENABLED=false;                   expect "关掉 ingress" pass chk
  again; cfg RANCHER_ENABLED=false;                   expect "关掉 Rancher（无需 bootstrap 密码）" pass chk
  again; cfg RANCHER_TLS_SOURCE=secret CERT_MANAGER_ENABLED=false; \
                                                      expect "TLS=secret 时可以不装 cert-manager" pass chk
  again; cfg STORAGE_NFS_ENABLED=true NFS_SERVER=10.9.9.9 NFS_VERSION=4; \
                                                      expect "NFS 开启 + 真实 server + v4" pass chk

  # ---- 反例 ----
  again; cfg K3S_VERSION=;                            expect "K3S_VERSION 为空" fail chk
  again; cfg K3S_VERSION=1.31;                        expect "K3S_VERSION 格式不对" fail chk
  again; cfg K3S_INSTALL_MODE=foo;                    expect "K3S_INSTALL_MODE 非法" fail chk
  again; cfg CNI=calico;                              expect "CNI 非法（只允许 flannel/none）" fail chk
  again; cfg CLUSTER_NAME=;                           expect "CLUSTER_NAME 为空" fail chk
  again; cfg SSH_PORT=abc;                            expect "SSH_PORT 非数字" fail chk
  again; cfg SSH_PORT=99999;                          expect "SSH_PORT 越界" fail chk
  again; cfg INIT_SSH_PORT=;                          expect "INIT_SSH_PORT 为空" fail chk
  again; cfg ROOT_SSH_POLICY=maybe;                   expect "ROOT_SSH_POLICY 非法" fail chk
  again; cfg INGRESS_KIND=NodePort;                   expect "INGRESS_KIND 非法" fail chk
  again; cfg CHARTS_MODE=ftp;                         expect "CHARTS_MODE 非法" fail chk
  again; cfg RANCHER_TLS_SOURCE=bogus;                expect "RANCHER_TLS_SOURCE 非法" fail chk
  again; cfg RANCHER_TLS_SOURCE=rancher CERT_MANAGER_ENABLED=false; \
                                                      expect "非 secret 的 TLS 源必须先装 cert-manager" fail chk
  again; cfg RANCHER_BOOTSTRAP_PASSWORD=;             expect "RANCHER 开启但 bootstrap 密码为空" fail chk
  again; cfg CLUSTER_DOMAIN= RANCHER_HOSTNAME=;       expect "RANCHER 开启但 hostname/domain/ipam.domain 全空" fail chk_nodom
  again; cfg ACME_EMAIL=notanemail;                   expect "ACME_EMAIL 格式不对" fail chk
  again; cfg LOCALDISK_PATH=;                         expect "LOCALDISK 开启但路径为空" fail chk
  again; cfg LOCALDISK_RECLAIM_POLICY=Delete2;        expect "localdisk 回收策略非法" fail chk
  again; cfg STORAGE_NFS_ENABLED=true;                expect "NFS 开启但 server 还是占位值" fail chk
  again; cfg STORAGE_NFS_ENABLED=true NFS_SERVER=10.9.9.9 NFS_VERSION=v4; \
                                                      expect "NFS_VERSION 非数字" fail chk
  again; cfg STORAGE_NFS_ENABLED=true NFS_SERVER=10.9.9.9 NFS_PATH=; \
                                                      expect "NFS_PATH 为空" fail chk
  again; cfg IN_CLUSTER_NFS=true;                     expect "IN_CLUSTER_NFS=true 但 NFS 未启用" fail chk
  again; cfg NFS_DEFAULT_SC=true LOCALDISK_DEFAULT_SC=false; \
                                                      expect "NFS_DEFAULT_SC=true 但 NFS 未启用" fail chk
  again; cfg STORAGE_NFS_ENABLED=true NFS_SERVER=10.9.9.9 NFS_DEFAULT_SC=true; \
                                                      expect "两个默认 StorageClass 同时为 true" fail chk
}

# ---------------------------------------------------------------------------
case "${1:-all}" in
  ipam)   test_ipam ;;
  config) test_config ;;
  all)    test_ipam; echo ""; test_config ;;
  *) echo "用法: $0 [ipam|config|all]"; exit 2 ;;
esac

echo ""
echo "结果: 通过 ${PASS}，失败 ${FAIL}"
[ "${FAIL}" -eq 0 ] || exit 1
