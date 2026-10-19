# production/ 一键部署方案设计（公司级测试 + 生产通用简化版）

- 日期：2026-10-19
- 状态：待确认（批准后才进入 writing-plans）
- 位置：`k3s-ops/production/`

---

## 1. 一句话目标

在**已装好最小系统的 3 台服务器**上，改好两个配置文件，执行 `./production/bootstrap.sh`，一条命令得到
**可用集群**：k3s（HA 控制面，IPAM 首个 server 为 init 节点）+ hostNetwork nginx-ingress（宿主机 80/443，
无 NodePort）+ 两种 PVC（本地盘 / NFS）+ cert-manager（内网 CA 签发）+ Rancher（走 Ingress + 内网证书），
并输出 `production/kubeconfig`。后续用 `./production/scale.sh` 增删 server/agent。

第二条目标：这套东西**公司测试环境和生产环境用同一份代码**，差别只落在配置文件上。

---

## 2. 用户明确给出的约束（用户说的，视为已定）

1. SSH 前置：`root` + **密码**登录；生成并下发运维账号 `ops` 及其登录密钥；初始化后只能 `ops` 登录。
2. 静态 IP；主机名形如 `xxx-k8s-01`，`xxx` 前缀可配置；IPAM 写在设置文件里。
3. 暂时**不需要 VIP**。
4. nginx-ingress **不保留 NodePort**；前置 LB 以后可能有，现在没有。
5. localdisk 路径以配置文件为准（用户先举例 `/nfs-share`，后改为默认 `/opt/k8s-local-path`）。
6. 外部 NFS：`nfs-server.example.com`、路径 `/nfs-share`、v4、可读写；也支持集群内部署 NFS；IP/路径以配置文件为准。
7. 时区 `Asia/Shanghai`；统一 chrony；SSH 端口可改；关闭 swap；内核参数无额外要求；防火墙用 ufw。
8. k3s 默认最新稳定版，可配置。
9. 内网镜像仓库后期用 Artifactory，保留 `registries.yaml`；支持离线部署。
10. 动态分配服务器的 VM 模板以配置文件为准。
11. CNI 默认 Flannel，以配置文件为准。
12. `config/ipam.yml` 为**唯一事实源**：脚本从中读 `hostname/ip/role`，首个 `role=server` 为集群 init 节点。
13. 初始化时创建 `ops` 与 `/etc/sudoers.d/ops`（`ops ALL=(ALL) NOPASSWD:ALL`），后续可手动改为需密码。
14. `cluster.env` 增加 `SSH_PORT`（默认 22）；`ssh-setup.sh` 先下发密钥，**验证 `ops`+密钥可连之后**再按
    `DISABLE_ROOT_SSH_AFTER_INIT=true` 调整 `sshd_config`（建议先 `prohibit-password`，必要时再 `no`）。
15. ufw 可选：`USE_UFW=true/false`，false 时跳过 ufw 任务；与现有 firewalld 逻辑不冲突（按开关选择）。
16. nginx-ingress：`hostNetwork: true`、`controller.service.enabled=false`，直接监听宿主机 80/443，无 NodePort。
17. `LOCALDISK_PATH` 默认 `/opt/k8s-local-path`；目录按配置创建并设权限；**配置文件优先**。
18. `IN_CLUSTER_NFS=true/false`：开启时预部署简易 NFS Server 并与 `nfs-subdir-external-provisioner` 配合；
    关闭时仅用外部 NFS。
19. 生成 `production/kubeconfig` 并提示设置 `KUBECONFIG`。
20. 最小校验：`bootstrap.sh` 校验 ipam 至少一条 `role: server`；`scale.sh remove` 防误删（含"不能删最后一台 server"）。
21. `terraform/` 只放 `README.md` 与 `vm_template.yml.example`，暂不生成 `main.tf`。

## 3. 本轮问答补充确认的约束

22. **"就绪"清单** = k3s + hostNetwork nginx-ingress + 两种 StorageClass + cert-manager + Rancher。
    metrics-server 用 k3s 自带，不额外上监控栈。
23. **ingress 用 DaemonSet**（每个节点各一个副本，hostNetwork），因此**任意节点 IP 的 80/443 都能访问**，
    不需要 VIP、不需要前置 LB。

---

## 4. 目标 / 非目标 / 反目标

### 4.1 目标（goals）

- 一条命令从裸机到可用；幂等，可重复执行。
- 全部可变项收敛到 `production/config/cluster.env` + `production/config/ipam.yml` 两个文件。
- Ansible **复用现有 roles**（`ansible/roles/k3s-common` / `k3s-server` / `k3s-agent` / `k3s-manage`），
  生产侧只新增薄 playbook（OS 初始化、集群、addons、扩缩容）。
- 扩缩容脚本化、声明式（改 `ipam.yml` → `scale.sh apply`），删除需显式确认且带保护。
- 为 KVM/Proxmox 的 Terraform 动态分配留好接口（目录 + 变量契约 + README），但**不实现**。
- 离线/内网镜像仓库可切换。

### 4.2 非目标（non-goals，本期不做）

- 不做 VIP（kube-vip）、不做 MetalLB、不启用 ServiceLB。
- 不做 Cluster Autoscaler / Karpenter / CAPI。
- 不生成 `main.tf`，不接管 VM 创建。
- 不做监控栈（Prometheus/Grafana/Loki）、不做 Velero、不做 Kyverno、不做 Gateway API、不做 GitOps。
- 不做多集群管理、不做跨机房/跨可用区编排。
- 不替换现有 Vagrant 教学环境（两者并存，互不干扰）。

### 4.3 反目标（anti-goals，做到就算失败）

- 需要人工在多台机器上分步敲命令才能装完。
- 同一份配置在测试环境和生产环境要改代码才能用。
- 把明文密码/私钥/`kubeconfig` 提交进仓库，或让 `privacy-check.sh` 拦不住。
- 破坏现有 Vagrant 环境或 `k3s-ops.sh` 的行为。
- 脚本"看起来能跑"但无任何可执行的验证手段。

---

## 5. 可复用资产与耦合

| 资产 | 复用方式 | 说明 |
|---|---|---|
| `ansible/roles/k3s-common` | 直接复用 | 内含 swap/内核模块/sysctl/registries.yaml/ufw 逻辑；按开关使用 |
| `ansible/roles/k3s-server` | 直接复用 | init / join / config 模板 |
| `ansible/roles/k3s-agent` | 直接复用 | join |
| `ansible/roles/k3s-manage` | 直接复用 | `remove-node` 用于缩容 |
| `lib/logging.sh` | 复用（覆盖 `LOG_DIR`/`LOG_FILE`） | 生产侧日志落 `production/logs/` |
| `scripts/privacy-check.sh` | 复用 | 需同步维护 `ALLOW_*` 白名单 |
| `docs/ingress-80-443-exposure.md` | 作为 hostNetwork 方案依据 | 本文取其"DaemonSet + hostNetwork + ClusterIP/无 Service"结论 |

**耦合声明**：`production/` **必须位于 k3s-ops 仓库内**，通过相对路径 `../ansible/roles`、`../lib/` 引用父仓库。
它不是一个可单独拷走的目录。理由：用户明确要求复用现有 roles。preflight 会校验父仓库路径存在。

**需要改动的父仓库文件（4 处，全部向后兼容、默认行为不变）**：

| # | 文件 | 改动 | 为什么不能在生产侧绕开 |
|---|---|---|---|
| P1 | `ansible/roles/k3s-server/templates/config.yaml.j2` | `flannel-backend: vxlan` → `flannel-backend: {{ k3s_flannel_backend \| default('vxlan') }}` | 约束 11 要求 CNI 可配置；模板写死则只能改模板 |
| P2 | 同模板 | `disable:` 列表增加 `local-storage`（由 `k3s_config.disable_local_storage` 控制，默认 false） | 见 §12 第 1 项：内置 local-path 的路径不可配，必须停用它改用自管 provisioner |
| P3 | `ansible/roles/k3s-common/tasks/main.yml` | `include_tasks: firewall.yml` 加 `when: use_ufw \| default(true)` | `k3s-server`/`k3s-agent` 角色**内部**会 `include_role: k3s-common`，生产侧无法阻止 ufw 任务被执行 |
| P4 | `scripts/privacy-check.sh` | 规则 8 增加**精确文件名**豁免：`production/config/cluster.env`、`production/config/cluster.env.local.example`；`ALLOW_IPS` 增加示例网段 `192.168.100.0/.1/.11/.12/.13` 等 | 该脚本按 `*.env`/`*.env.*` 判敏感文件，而 `cluster.env` 这个文件名是用户指定的（约束 14）；规则 6 会把示例内网 IP 一律判为泄漏 |

P3、P4 的理由值得说明：这两处**不是**为了生产功能，而是"复用现有代码"与"不改现有行为"之间的必然摩擦点。
四处改动的默认值都与现状一致，现有 Vagrant 流程不受影响。

---

## 6. 目录结构

```
production/
├── README.md                     # 使用说明（唯一入口文档）
├── bootstrap.sh                  # 一条命令：全流程
├── scale.sh                      # 扩缩容：apply / remove / list
├── config/
│   ├── cluster.env               # 主配置（可提交，含占位值）
│   ├── cluster.env.local.example # 本机覆盖示例（含密码等，实际文件 gitignore）
│   ├── ipam.yml                  # 唯一事实源：hostname/ip/role
│   └── registries.yaml.example   # 内部仓库/离线镜像配置示例
├── lib/
│   ├── config.sh                 # 读 cluster.env + .local + IPAM，导出全局变量
│   ├── ipam.sh                   # 解析 ipam.yml（hostname/ip/role/first server/校验）
│   └── inventory.sh              # 由 ipam 生成 Ansible inventory 与 extra_vars（唯一写入点）
├── ansible/
│   ├── ansible.cfg               # inventory/roles_path/ssh 默认值
│   ├── inventory/                # 生成物（gitignore）：hosts.yml、extra_vars.yml
│   ├── playbooks/
│   │   ├── 05-preflight.yml      # 节点可达性、基础包、目录
│   │   ├── 10-os-init.yml        # 服务器初始化（复用 k3s-common + 时区/chrony/limits/hosts/localdisk 目录）
│   │   ├── 20-k3s-cluster.yml    # 复用 roles：server init/join + agent join + 取 kubeconfig
│   │   ├── 30-addons.yml         # helm / localdisk / ingress / cert-manager / NFS / Rancher
│   │   ├── 40-scale-add.yml      # 新节点：os-init + join
│   │   └── 50-scale-remove.yml   # 缩容：drain + 删除节点
│   └── files/
│       ├── chrony.conf.j2
│       ├── limits-k8s.conf
│       └── helm-setup.sh            # 在首个 server 上安装/校验 helm（在线下载或本地 artifact）
├── addons/
│   ├── nginx-ingress/values.yaml.j2
│   ├── localdisk/manifests.yaml.j2      # 自管 local-path-provisioner（停用 k3s 内置 local-storage）
│   ├── cert-manager/values.yaml.j2
│   ├── cert-manager/issuers.yaml.j2     # 自签 → CA → ClusterIssuer 链
│   ├── nfs-provisioner/manifests.yaml.j2  # 自管 nfs-subdir-external-provisioner
│   ├── in-cluster-nfs/manifests.yaml.j2
│   ├── rancher/values.yaml.j2
│   └── rancher/certificate.yaml.j2
├── charts/                       # 离线 chart（*.tgz 被 .gitignore 排除；用 scripts/fetch-artifacts.sh 拉取）
├── artifacts/                    # 离线二进制/镜像（gitignore）：k3s、helm、images/*.tar
├── scripts/
│   ├── ssh-setup.sh              # root+密码 → ops 用户+密钥 → 验证 → 按开关加固 root
│   ├── kubeconfig.sh             # 拉取/改写 → production/kubeconfig
│   ├── fetch-artifacts.sh        # 在有网的机器上把 k3s/helm/charts 拉到 charts+artifacts（离线准备）
│   ├── offline-load.sh           # 离线分发：k3s 二进制 + 镜像 tar 导入每个节点
│   └── verify.sh                 # 装完自检（节点 Ready / 80,443 / SC / PVC / Rancher）
├── terraform/
│   ├── README.md
│   └── vm_template.yml.example
├── logs/                         # 运行日志（gitignore）
└── .state/                       # nodes.json 等状态（gitignore）
```

`.gitignore` 追加：`production/kubeconfig`、`production/logs/`、`production/.state/`、
`production/ansible/inventory/*.yml`、`production/artifacts/*`、`production/config/cluster.env.local`、
`production/config/registries.yaml`。

---

## 7. 配置契约

### 7.1 `config/ipam.yml`（唯一事实源）

```yaml
subnet: 192.168.100.0/24         # 仅用于校验 IP 合法性与冲突检查，不做自动分配
gateway: 192.168.100.1
dns:
  - 192.168.100.1
domain: k8s.example.com          # 可选：Ingress 主机名后缀

nodes:
  - hostname: xxx-k8s-01         # 完整主机名，权威来源
    ip: 192.168.100.11
    role: server                 # server | agent；文件里第一个 server 即集群 init 节点
  - hostname: xxx-k8s-02
    ip: 192.168.100.12
    role: server
  - hostname: xxx-k8s-03
    ip: 192.168.100.13
    role: agent
    labels:                      # 可选，落成 Node label
      node-role.example.com/ingress: "true"
```

**集群名只有一个来源**：`cluster.env` 的 `CLUSTER_NAME`（用于 kubeconfig context、`.state/nodes.json` 命名、
主机名前缀校验）。`ipam.yml` **不再**有 `cluster_name` 字段，避免双份真相。
`ipam.yml` 也**不提供** per-node 存储路径与 `taints`（见 §16 D13/D14）。

校验规则（`lib/ipam.sh`，失败即退出）：

- 至少 1 条节点；至少 1 条 `role: server`（约束 20）；`role` 只能是 `server|agent`。
- `hostname` 全局唯一；`ip` 全局唯一且落在 `subnet` 内；`ip` 不能等于 `gateway`。
- 文件顺序决定 init 节点：**第一条 `role: server`**（约束 12）。该节点若在集群已初始化后被移出 ipam，直接报错。
- hostname 不以 `CLUSTER_NAME` 开头 → 告警（不致命，便于查错）。
- 只做上述最小校验，不猜用户意图（IP 是否被占用交给 `05-preflight.yml` 的连通性/SSH 探测）。

### 7.2 `config/cluster.env`（主配置，可提交）

```bash
# ---- 集群标识 ----
CLUSTER_NAME=xxx-k8s
CLUSTER_DOMAIN=k8s.example.com          # Ingress 主机名后缀，留空则用 IPAM 的 domain

# ---- k3s ----
K3S_VERSION=latest                      # latest | v1.31.5+k3s1 ；latest 走 K3S_CHANNEL_URL 解析
K3S_CHANNEL_URL=https://update.k3s.io/v1-release/channels/stable
K3S_INSTALL_MODE=online                 # online | offline
CNI=flannel                             # flannel | none（none 供后续自装 Calico/Cilium）
POD_CIDR=10.42.0.0/16
SVC_CIDR=10.43.0.0/16
DISABLE_TRAEFIK=true
DISABLE_SERVICELB=true                  # 与第 44 章结论一致
TAINT_SERVER=false                      # 小集群 server 可跑业务

# ---- SSH / 账号 ----
SSH_PORT=22
INIT_SSH_USER=root
INIT_SSH_PASSWORD=                      # 留空则从环境变量 INIT_SSH_PASSWORD 或交互读取
OPS_USER=ops
OPS_SSH_KEY=                            # 留空则自动生成 production/.state/ops_id_ed25519
OPS_SUDO_NOPASSWD=true
DISABLE_ROOT_SSH_AFTER_INIT=true
ROOT_SSH_POLICY=prohibit-password       # prohibit-password | no

# ---- OS 初始化 ----
TIMEZONE=Asia/Shanghai
CHRONY_SERVERS="ntp.aliyun.com iburst"
USE_UFW=true
UFW_ALLOW_CIDR=192.168.100.0/24
ENABLE_LIMITS=true

# ---- 存储 ----
LOCALDISK_PATH=/opt/k8s-local-path      # 约束 17
LOCALDISK_ENABLED=true                  # true→停用 k3s 内置 local-storage，改用自管 provisioner
LOCALDISK_SC_NAME=localdisk             # StorageClass 名（用户口径：localdisk）
LOCALDISK_DEFAULT_SC=true
LOCALDISK_RECLAIM_POLICY=Retain         # Retain | Delete（本地盘建议 Retain，防误删数据）
LOCALDISK_IMAGE=rancher/local-path-provisioner:v0.0.30
STORAGE_NFS_ENABLED=true
IN_CLUSTER_NFS=false                    # 约束 18
NFS_SERVER=nfs-server.example.com
NFS_PATH=/nfs-share
NFS_VERSION=4
NFS_SC_NAME=nfs-client
NFS_DEFAULT_SC=false                    # 与 LOCALDISK_DEFAULT_SC 互斥（都为 true 时 preflight 报错）
NFS_RECLAIM_POLICY=Delete
NFS_PROVISIONER_IMAGE=registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2

# ---- Helm（addons 阶段在首个 server 上执行）----
HELM_VERSION=v3.16.3
HELM_DOWNLOAD_URL=                      # 留空用官方 get.helm.sh；内网填镜像
HELM_BIN=                               # 留空则用上面两者；离线时指向 artifacts/helm

# ---- Ingress ----
INGRESS_ENABLED=true
INGRESS_CHART_VERSION=4.11.0
INGRESS_KIND=DaemonSet
INGRESS_HTTP_PORT=80
INGRESS_HTTPS_PORT=443
INGRESS_NODE_SELECTOR=                  # 空=所有节点

# ---- Addons ----
CERT_MANAGER_ENABLED=true
CERT_MANAGER_CHART_VERSION=v1.20.2
ACME_EMAIL=                             # 留空则只用内网 CA，不建 Let's Encrypt issuer
RANCHER_ENABLED=true
RANCHER_HOSTNAME=rancher.${CLUSTER_DOMAIN}
RANCHER_CHART_VERSION=2.15.2
RANCHER_REPLICAS=1
RANCHER_BOOTSTRAP_PASSWORD=admin        # 演示值；生产改 .local
RANCHER_TLS_SOURCE=rancher              # rancher | cert-manager（默认自签；切换即可换成内网 CA）

# ---- 制品 / 仓库 ----
CHARTS_MODE=local                       # local=用 production/charts/*.tgz；repo=用 Helm 仓库
ARTIFACTS_DIR=${PROD_DIR}/artifacts
K3S_DOWNLOAD_URL=                       # 留空则用官方 GitHub；离线/内网填镜像
REGISTRY_MIRRORS=                       # 留空则沿用父仓库默认加速；Artifactory 时填内网地址
REGISTRY_ENDPOINT=                      # 例 artifactory.example.com
REGISTRY_USERNAME=                      # 建议放 .local 或环境变量
REGISTRY_PASSWORD=
```

**分层规则**：`cluster.env` 可提交（占位值）；`cluster.env.local`（gitignore）在后覆盖，放真实密码/仓库凭据。
`lib/config.sh` 读取顺序：`cluster.env` → `cluster.env.local` → 环境变量。

### 7.3 生成物（不进 git）

`ansible/inventory/hosts.yml`（由 `generate-inventory` 从 ipam 生成）：

```yaml
all:
  children:
    server:
      hosts:
        xxx-k8s-01: {ansible_host: 192.168.100.11, node_role: server, node_ip: 192.168.100.11}
        xxx-k8s-02: {ansible_host: 192.168.100.12, node_role: server, node_ip: 192.168.100.12}
    agent:
      hosts:
        xxx-k8s-03: {ansible_host: 192.168.100.13, node_role: agent,  node_ip: 192.168.100.13}
```

`ansible/inventory/extra_vars.yml`：`cluster_name`、`k3s_version`、`first_server_ip`、`first_server_host`、
`k3s_config`（含 `disable_traefik`/`disable_servicelb`/`taint_server`/`cluster_cidr`/`service_cidr`/`flannel_backend`）、
`k3s_*` 路径变量、`containerd_mirrors`、`prod_dir`。
> 说明：这些键与 `ansible/group_vars/all.yml` 同名同义；因为使用独立 inventory，父仓库的 group_vars 不会自动加载，
> 由生成器显式写入（含默认值）。生成器是**唯一写入点**，避免双份真相。

---

## 8. `bootstrap.sh` 执行流程

```
bootstrap.sh [--ssh-only|--os-only|--skip-os|--addons-only] [--yes] [--root-password <pw>] [--no-hardening]
```

| 步骤 | 动作 | 失败策略 |
|---|---|---|
| 0 | `lib/config.sh` 读配置；`lib/ipam.sh` 校验 IPAM（≥1 server、唯一性、首 server 为 init） | 立即退出 |
| 1 | `05-preflight.yml`：校验父仓库路径、依赖命令（`ansible`/`python3`/`ssh`、需要时 `sshpass`）、SSH 端口可达、目标机是否已有集群、**helm 来源可用性**（在线可下载 / 离线 `artifacts/helm` 存在）、`LOCALDISK_DEFAULT_SC` 与 `NFS_DEFAULT_SC` 互斥 | 立即退出 |
| 2 | `scripts/ssh-setup.sh`：root+密码 → 建 `ops`/sudoers/密钥 → **验证 `ops`+密钥登录成功** → 按开关加固 root | 验证失败则**不改** `sshd_config`，退出 |
| 3 | `10-os-init.yml`（以 `ops` + 密钥，`become: true`）：主机名、chrony+时区、关 swap、内核模块/sysctl、limits、ufw（可选）、创建 `LOCALDISK_PATH`、`/etc/hosts` 写入集群节点、基础包 | 立即退出 |
| 4 | `20-k3s-cluster.yml`（`serial: 1`）：第一个 server `cluster-init: true` → 其余 server etcd join → agent join → 拉 kubeconfig | `any_errors_fatal` |
| 5 | `scripts/kubeconfig.sh`：改写 server 地址为首个 server IP、context 名 `${CLUSTER_NAME}` → `production/kubeconfig`（0600），打印 `export KUBECONFIG=` 提示 | 立即退出 |
| 6 | `30-addons.yml`（在首个 server 上执行）：安装/校验 helm → localdisk provisioner → nginx-ingress（DaemonSet/hostNetwork）→ cert-manager + 内网 CA → NFS（外部或集群内）→ Rancher | 立即退出 |
| 7 | `scripts/verify.sh` + 打印访问信息 | 汇总报告，非致命项只告警 |

幂等：步骤 2/3/4 都可重复执行；步骤 4 通过"首个 server 的 `/var/lib/rancher/k3s/server/db/etcd` 是否存在"、
"其余 server 是否已有 etcd 目录"判断 init 还是 join（复用现有 role 逻辑）；addons 用 `helm upgrade --install --wait`。

`--skip-os` / `--addons-only` / `--ssh-only` 用于断点续跑。步骤 5 的 `--addons-only` 前置是 kubeconfig 可用。

---

## 9. SSH 初始化与加固（`scripts/ssh-setup.sh`，约束 1/13/14）

用 `ssh` + `sshpass`（或 `SSH_ASKPASS`）直连，不依赖 Ansible，便于在"目标机还没有 python"时也能跑。

对每台节点：

1. **连通性**：`ssh -o BatchMode=yes -p $SSH_PORT root@ip true` 探测；失败则用密码登录。
2. **建运维账号**：`useradd -m -s /bin/bash ops`（幂等）；`usermod -aG sudo ops`（若组存在）。
3. **sudoers**：写 `/etc/sudoers.d/ops`，内容 `ops ALL=(ALL) NOPASSWD:ALL`，`chmod 0440`，
   写前用 `visudo -c -f` 校验（约束 13）。`OPS_SUDO_NOPASSWD=false` 时改写为需密码形式。
4. **密钥**：控制端生成 `production/.state/ops_id_ed25519`（无口令，`chmod 600`；不存在才生成），
   公钥写入 `~ops/.ssh/authorized_keys`（`0700`/`0600`，属主 `ops`）。
5. **验证（硬门槛）**：`ssh -i <key> -p $SSH_PORT -o BatchMode=yes ops@ip 'sudo -n true'`。
   **不通过则中止本机加固，保留 root 登录**，并明确报错。
6. **加固 root**（仅当 `DISABLE_ROOT_SSH_AFTER_INIT=true`）：
   在 `/etc/ssh/sshd_config.d/99-k3s-ops-hardening.conf` 写
   `PermitRootLogin <ROOT_SSH_POLICY>`（默认 `prohibit-password`），端口非 22 时写 `Port`；
   `sshd -t` 校验后 `systemctl reload sshd`。**保留**端口修改但不动 `PasswordAuthentication`
   （用户要求"先 prohibit-password，必要时再设 no"，改 `no` 由人工把 `ROOT_SSH_POLICY` 改为 `no` 后重跑本脚本）。

`ssh-setup.sh` 同时把 `SSH_PORT` 写进 `sshd_config.d/99-k3s-ops-hardening.conf`（约束 7），
若端口变更则同步提示后续 inventory 使用新端口。

---

## 10. OS 初始化（`10-os-init.yml`，约束 7/15/17）

复用 `k3s-common` 角色的能力，**顺序与分工**：

| 项 | 归属 | 说明 |
|---|---|---|
| 主机名 | 生产 playbook | `hostname` 模块设为 ipam 的 `hostname`；写 `/etc/hosts` 全节点互解 |
| 时区 + chrony | 生产 playbook | `timedatectl set-timezone Asia/Shanghai`；装 chrony、写 `CHRONY_SERVERS`、启服务、`chronyc waitsync` |
| 关 swap | 复用 `k3s-common` | `swapoff -a` + 清 fstab |
| 内核模块/sysctl | 复用 `k3s-common` | `overlay`/`br_netfilter` + 3 个 sysctl 键 |
| registries.yaml | 复用 `k3s-common`（`containerd.yml`） | 由 `containerd_mirrors` 生成；Artifactory 时由生成器写出 `configs.<endpoint>.auth` |
| limits | 生产 playbook | `/etc/security/limits.d/99-k8s.conf`（`nofile`/`nproc`），`ENABLE_LIMITS=true` 时 |
| ufw | 复用 `k3s-common` **条件化** | 按 `USE_UFW` 决定是否 include `firewall.yml`；`UFW_ALLOW_CIDR` 放行内网，k3s 端口用现有清单 |
| localdisk 目录 | 生产 playbook | `LOCALDISK_ENABLED=true` 时，每个节点创建 `LOCALDISK_PATH`，`0777`（provisioner 的 helper pod 需可写） |
| 基础包 | 生产 playbook | 复用 `k3s-common/vars` 的 `packages` 列表并安装（含 `nfs-common`） |
| ufw/防火墙 | 见 §12 与 P3 | `USE_UFW` 关时父角色也不再写 ufw 规则（父角色 P3 改动） |

`10-os-init.yml` **直接复用 `k3s-common` 角色**（`roles: [k3s-common]`），拿到 swap / 内核模块 / sysctl /
`registries.yaml` / 防火墙（受 `use_ufw` 门控，见 P3）全部能力；随后在同一 playbook 里追加
主机名、`/etc/hosts`、时区 + chrony、limits、基础包、`LOCALDISK_PATH` 目录这些父角色没有的项。

> 权衡说明：父角色 `main.yml` 原本**无条件** include `firewall.yml`，`USE_UFW=false` 就失效。
> 与其在生产侧绕开父角色、把 swap/内核/sysctl 抄一遍（会有两处需要同步维护的真相），
> 不如加 P3 那一行 `when: use_ufw | default(true)`——默认值不动，现有行为完全不变，且生产侧保持"整段复用"。

ufw 说明（约束 15）：`USE_UFW=false` 时**整段跳过**，不安装也不改 ufw；`true` 时放行
`6443/10250/8472/2379/2380` + `SSH_PORT` + `UFW_ALLOW_CIDR` 内的常用端口（80/443 必须放行，因为 ingress 用宿主机端口）。

---

## 11. k3s 安装（`20-k3s-cluster.yml`，约束 8/11/12）

- 复用 `k3s-server`（init/join）与 `k3s-agent` 两个 role，role 内部的判断条件
  （`node_ip == first_server_ip`、`/var/lib/rancher/k3s/server/db/etcd` 是否存在）保持不变。
- 自写薄 playbook：`hosts: all`、`serial: 1`、`any_errors_fatal: true`、`become: true`，
  `roles:` 按 `node_role` 分发；`post_tasks` 在首个 server 上 `fetch` kubeconfig 到 `production/`（临时名）。
- `K3S_VERSION=latest`：preflight 阶段解析 `K3S_CHANNEL_URL` 得到具体版本号，写入 `extra_vars.yml`
  的 `k3s_version` 与 `k3s_download_url`；离线模式跳过解析，用 `artifacts/k3s` 并只写 `k3s_version`。
- CNI：`CNI=flannel` → `flannel-backend: vxlan`；`CNI=none` → `flannel-backend: none`
  （需要配合自装 CNI，本期只留开关，文档写明）。
- server 不设污点（`TAINT_SERVER=false`），小集群 server 可跑业务。
- `ipam.yml` 里 per-node 的 `labels` 由 `post_tasks` 在首个 server 上 `kubectl label --overwrite node <host> k=v` 落位。
- HA：3 台 server 时 etcd 为 3 成员；**`serial: 1` 严格串行**，避免 etcd 同时加入导致抖动。

---

## 12. Addons（`30-addons.yml`，约束 16/17/18/19 + 问答 22/23）

**执行位置与方式（我的取舍）**：在**首个 server** 上以 root 执行 `helm`/`kubectl` CLI（`shell` 模块），
`KUBECONFIG=/etc/rancher/k3s/k3s.yaml`。
理由：kubeconfig 已在节点上；节点在目标网络内（能到内网 Artifactory）；不需要控制端装
`kubernetes.core` 依赖或目标机装 python k8s 库。
`CHARTS_MODE=local` 时用 `production/charts/*.tgz`（`copy` 后 `helm upgrade --install <tgz>`），
`repo` 模式才 `helm repo add`。

顺序与要点：

0. **helm 就位**：`files/helm-setup.sh` 在首个 server 上检测 `helm`；缺失则安装——
   `K3S_INSTALL_MODE=offline` 或 `HELM_BIN` 已给路径时用本地 artifact，
   否则从 `HELM_DOWNLOAD_URL`（留空=官方 `get.helm.sh`）下载 `HELM_VERSION` 的
   `linux-amd64` tarball 解到 `/usr/local/bin`。装完 `helm version` 校验。
   > 父仓库把 helm 当**控制端**工具（`~/.local/bin/helm`），k3s 的 `install.yml` 只装 `k3s`/`kubectl`。
   > 目标是"一条命令"，所以 helm 由 bootstrap 自己解决，而不是要求用户预装。
1. **localdisk（本地盘）**：**停用 k3s 内置 local-storage**（`k3s_config.disable_local_storage=true`），
   改为**自管清单** `addons/localdisk/manifests.yaml.tpl`（SA + RBAC + ConfigMap + Deployment + StorageClass）：
   `storageClass.name=LOCALDISK_SC_NAME`（默认 `localdisk`）、默认类注解由 `LOCALDISK_DEFAULT_SC` 控制、
   `reclaimPolicy=LOCALDISK_RECLAIM_POLICY`、`configmap.config.nodePathMap[0].paths=[LOCALDISK_PATH]`、
   `setup` 用 `mkdir -m 0777 -p "$VOL_DIR"`；镜像 `LOCALDISK_IMAGE`（默认
   `rancher/local-path-provisioner:v0.0.30`）。`LOCALDISK_PATH` 目录已在第 10 步于所有节点创建。
   > **原本想用 Helm chart**，但 `charts.rancher.io` 已不再收录 `local-path-provisioner`，官方 chart 只存在于
   > GitHub 仓库内（本机 GitHub releases 不可达）。自管清单反而更省事：**零额外 chart**、完全离线友好、
   > 且我们要改的三个点（SC 名、路径、回收策略）本来就是"改模板"最直接。
   >
   > **为什么不直接改 k3s 的 `local-path-config` ConfigMap**：已在本集群实测，k3s 把内置组件写成
   > 磁盘上的 `/var/lib/rancher/k3s/server/manifests/local-storage.yaml`，manifest 控制器每次启动都会
   > 按该文件重新 apply。只 patch ConfigMap 会在 k3s 重启/升级后被**悄悄还原**，PVC 数据落回
   > `/var/lib/rancher/k3s/storage`——属于"数据落到错误磁盘"的隐蔽故障。
2. **nginx-ingress**：`kind: DaemonSet`、`hostNetwork: true`、`dnsPolicy: ClusterFirstWithHostNet`、
   `service.enabled: false`（**无 NodePort**）、`reportNodeInternalIp`、
   `updateStrategy: RollingUpdate(maxUnavailable: 1)`、`INGRESS_NODE_SELECTOR` 可限范围（约束 4/16/23）。
   `addons/nginx-ingress/values.yaml` 为落盘契约，`helm --wait` 后校验每个节点 `ss -tlnp` 有 80/443。
3. **cert-manager**（约束 + 问答 22）：`crds.enabled=true`、`installCRDs=true` 双写兼容 chart 版本差异。
   随后 apply 签发链：`ClusterIssuer/selfsigned-bootstrap`（selfsigned）→
   `Certificate/internal-ca`（ns `cert-manager`）→ `ClusterIssuer/internal-ca`（ca，`ca.secretName=internal-ca`）。
   `ACME_EMAIL` 非空时追加 `ClusterIssuer/letsencrypt`（DNS-01 未配置则只建 HTTP-01，文档注明）。
4. **NFS**（约束 6/18）：**自管清单** `addons/nfs-provisioner/manifests.yaml.tpl`
   （SA + RBAC + Deployment + StorageClass），镜像 `NFS_PROVISIONER_IMAGE`
   （默认 `registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2`），
   `NFS_SERVER`/`NFS_PATH`/`mountOptions=[nfsvers=NFS_VERSION]`/`storageClass.name=NFS_SC_NAME`
   （默认 `nfs-client`）/`reclaimPolicy=NFS_RECLAIM_POLICY`。
   > 上游 chart（`kubernetes-sigs/nfs-subdir-external-provisioner`）只在 GitHub releases 分发，
   > 本机 **GitHub 不可达**（下载中断），故与 localdisk 一致改为自管清单，零 chart 依赖。
   - `IN_CLUSTER_NFS=false`（**默认**）：直接用外部 NFS（`NFS_SERVER`/`NFS_PATH`/`NFS_VERSION`）。
   - `IN_CLUSTER_NFS=true`：先在 ns `nfs-system` 部署简易 NFS Server
     （Deployment + Service `nfs-server`，导出卷用 `localdisk` PVC 落在 `LOCALDISK_PATH`），
     再把 provisioner 指向 `nfs-server.nfs-system.svc.cluster.local`。
     ⚠️ **内网无 NFS Server 镜像（答复 A4）**，因此该分支默认关闭且**未验证**；`manifests.yaml` 与
     镜像清单保留在仓库，等你解决镜像来源后再启用。文档明确写"单副本 = 单点"。
   - 默认 SC 归属：`LOCALDISK_DEFAULT_SC` 与 `NFS_DEFAULT_SC` 互斥（preflight 报错）。
     选 NFS 作默认时，清单渲染把 `is-default-class=true` 给 `nfs-client`，并确保 `localdisk` 上没有该注解。
5. **Rancher**（问答 22，答复 A5）：默认 `RANCHER_TLS_SOURCE=rancher`——交给 Rancher 自签（按 `RANCHER_HOSTNAME` 生成），
   最少依赖、离线可用。`helm upgrade --install rancher`：`ingress.enabled=true`、`ingressClassName=nginx`、
   `tls.source=rancher`、注解 `nginx.ingress.kubernetes.io/proxy-body-size: 100m`。
   切 `RANCHER_TLS_SOURCE=cert-manager` 时改走内网 CA：先 apply `Certificate/rancher-tls`
   （`dnsNames=[RANCHER_HOSTNAME]`，issuer `internal-ca`）并等 Ready，再以
   `tls.source=secret`、`tls.secretName=rancher-tls` 安装。两条路径由同一变量切换，代码路径都保留。
   `replicas=RANCHER_REPLICAS`（默认 1，文档标注 SPOF）。
6. **metrics-server**：k3s 自带且默认启用，**不做任何事**（确保 `disable` 列表里没有它）。

访问模型（约束 4/23）：DNS 把 `RANCHER_HOSTNAME` 指向**任意**节点 IP（或全部）；80/443 由每节点的
ingress DaemonSet 直接服务。没有 VIP、没有前置 LB。未来加 LB 只需把 LB 后端指向节点 80/443。

---

## 13. 扩缩容（`scale.sh`，约束 12/20）

```
scale.sh apply                 # 声明式：diff ipam.yml 与 .state/nodes.json，只加不删
scale.sh remove -n <hostname> [--yes] [--purge-ipam]
scale.sh list                  # 列出 ipam 与集群实际节点差异
```

- **apply**：读取 ipam，与 `.state/nodes.json` 比较；新增节点依次执行
  `ssh-setup.sh <node>` → `10-os-init.yml -l <node>` → `40-scale-add.yml -l <node>`
  （server 走 `k3s-server` join；agent 走 `k3s-agent`）→ 校验 `Ready` → 更新 state。
  已存在节点直接跳过（幂等）。
- **remove** 保护（约束 20）：
  1. 节点必须在 ipam 与集群中都存在，否则报错；
  2. 是集群 **init 节点** → 拒绝（提示手工处理）；
  3. 若是 server 且删除后 server 数 < 1 → 拒绝；删除后 server 数 < 3 → 强提示并要求 `--yes`；
  4. 删除后总节点数 = 0 → 拒绝；
  5. 无 `--yes` 时打印影响并要求确认。
  通过后：`50-scale-remove.yml`（cordon/drain → `k3s-manage` 的 `remove-node` → 清理）→
  `--purge-ipam` 时同步删 `ipam.yml` 条目 → 更新 state。
- `terraform/` 接入点（**只留接口，不实现**）：`vm_template.yml.example` 定义
  `name/role/cpus/memory/disk/image/network/labels`，与 `ipam.yml` 的节点字段一一对应；
  `scale.sh apply` 预留 `--provision=terraform` 钩子，本期显式报"未实现"。

---

## 14. 离线与内网仓库（约束 9）

- `K3S_INSTALL_MODE=online`：下载 k3s 二进制（`K3S_DOWNLOAD_URL` 可指向内网镜像）。
- `K3S_INSTALL_MODE=offline`：要求 `artifacts/k3s` 存在（版本自定并写入 `extra_vars.yml`），
  由 `scripts/offline-load.sh` 分发；`artifacts/images/*.tar` 用 `k3s ctr images import` 导入每个节点。
- `CHARTS_MODE=local`：`charts/*.tgz`，只需 **3 个** chart：
  `ingress-nginx-4.11.0.tgz`、`cert-manager-v1.20.2.tgz`、`rancher-2.15.2.tgz`。
  ⚠️ 父仓库 `.gitignore` 里已有 `*.tgz`（"体积大，不入库"），所以 chart 包**不会随 git 走**：
  交付时用 `scripts/fetch-artifacts.sh` 在有网的机器上把它们拉到 `production/charts/`。
  `CHARTS_MODE=repo`：`helm repo add` + `update`（需要网络或内网 ChartMuseum/Artifactory）。
- **不需要 chart 的组件**：`localdisk` 与 NFS provisioner 走自管清单（见 §12 第 1、4 项），
  因此离线时只需解决镜像（`LOCALDISK_IMAGE`、`NFS_PROVISIONER_IMAGE`）。
- `registries.yaml`：由 `containerd_mirrors` + `REGISTRY_ENDPOINT` 生成；
  Artifactory 凭据只从 `cluster.env.local`/环境变量取，**不进 git**。

---

## 15. 验证与证据（约束 + 诚实边界）

**本轮的验证边界（答复 A1：不真机验证）**：没有 3 台真机，**不声称端到端可用**。本轮只交付静态证据：

| 证据 | 命令 | 本轮要求 |
|---|---|---|
| shell 语法 | `bash -n` / `shellcheck` | 全部脚本通过 |
| playbook 语法 | `ansible-playbook --syntax-check` | 6 个 playbook 全部通过 |
| IPAM/配置逻辑 | `production/scripts/selftest.sh`（45 条正反例，改库后可重跑） | 全部按预期通过/报错 |
| 隐私 | `bash scripts/privacy-check.sh` | 通过（按 P4/D12 扩白名单后） |
| 一致性 | README ↔ 脚本 ↔ 配置文件三方交叉核对 | 无悬空引用 |

**明确留白（在 README 中显著标注）**：`bootstrap.sh` 端到端、hostNetwork ingress 实际占 80/443、
两种 StorageClass 实际出 PVC、Rancher 登录 —— 均**未在真机验证**，首次真机运行请按 README 的
"首次运行检查清单"逐项确认。

证据落盘：`production/logs/`、`production/.state/`、以及 `docs/superpowers/specs/` 下的运行记录（如执行则补）。

**本轮实际结果（2026-10-19 静态校验）**：

| 证据 | 命令 | 结果 |
|---|---|---|
| shell 语法 | `bash -n` 12 个脚本 | ✅ 全通过 |
| shellcheck | `shellcheck -S warning` | ✅ 无 error；遗留 SC2034 属跨文件引用（`config.sh` 是被 source 的变量库），非缺陷 |
| playbook 语法 | `ansible-playbook --syntax-check` 6 个 | ✅ 全通过 |
| host pattern | `ansible-playbook --list-hosts` | ✅ `first_server` 命中 1 台、`remove_target` 命中指定节点 |
| IPAM 正例 ×5 | 默认拓扑 / 2 server+1 agent / 偶数台 server / 短名 hostname / 无 subnet | ✅ 全部通过（后三项仅告警，符合设计） |
| IPAM 反例 ×7 | 0 台 server / IP 重复 / hostname 重复 / 非法角色 / 非法 IP / 网段外 / 等于网关 / 空 nodes | ✅ 全部按预期拒绝 |
| 配置正例 ×8 | 默认 / K3S_VERSION=stable·具体版本 / `USE_UFW=false` / 关 ingress / 关 Rancher / TLS=secret 免 cert-manager / NFS 真实 server | ✅ 全部通过 |
| 配置反例 ×22 | K3S_VERSION 空·格式错 / K3S_INSTALL_MODE / CNI / CLUSTER_NAME / SSH_PORT·INIT_SSH_PORT / ROOT_SSH_POLICY / INGRESS_KIND / CHARTS_MODE / RANCHER_TLS_SOURCE·证书依赖·密码·hostname / ACME_EMAIL / LOCALDISK 路径·回收策略 / NFS 占位·版本·路径·IN_CLUSTER·默认 SC / 双默认 SC | ✅ 全部按预期拒绝 |

以上 IPAM 与配置用例固化在 **`production/scripts/selftest.sh`**（45 条，可重复跑）。
| bootstrap 冒烟 | `--dry-run --steps 05,ssh,10` | ✅ 版本解析 + inventory 生成 + 命令打印正常 |
| 重复内容扫描 | 连续重复行 / 同一 5 行块 ×3 | ✅ 无 |
| 隐私 | `bash scripts/privacy-check.sh` | ✅ 通过（169 个文件） |

---

## 16. 我做的决定（builder 需知，用户可推翻）

| # | 决定 | 理由 |
|---|---|---|
| D1 | `production/` 依赖父仓库（`../ansible/roles`、`../lib/`），不可单拷 | 用户要求复用现有 roles |
| D2 | 父仓库只做 4 处**向后兼容**改动（P1–P4，见 §5），默认行为不变 | CNI 可配置、localdisk 可配路径、ufw 可关、`cluster.env` 文件名是硬需求；四处都绕不过去 |
| D3 | 自写薄 playbook，不复用父仓库的 playbook（roles 复用） | 父 playbook 写死 kubeconfig 输出路径与 Vagrant 假设 |
| D4 | addons 用 `helm` CLI 在首个 server 上跑，不用 `kubernetes.core` | 少依赖，节点网络更可能通内网仓库 |
| D5 | StorageClass 名用 `localdisk`（自管清单），不用内置 `local-path` | 内置 local-path 的路径只能靠打 ConfigMap 补丁，实测会被 k3s 启动时按 `manifests/local-storage.yaml` 还原 |
| D6 | Rancher 走 Ingress + cert-manager 内网证书，不用 NodePort | 约束 4「不保留 NodePort」+ 问答 23 |
| D7 | SSH 加固用 `sshd_config.d/99-*.conf` 片段，默认 `prohibit-password` | 可回滚、不破坏发行版主配置 |
| D8 | 步骤 2 验证不通过就**不动** `sshd_config` | 用户约束 14 的硬要求：密钥生效再禁 root |
| D9 | `10-os-init.yml` **直接复用 `k3s-common` 角色**，不绕开它 | 绕开会把 swap/内核/sysctl 抄成第二份真相；P3 让 `use_ufw` 生效即可 |
| D10 | `K3S_VERSION=latest` 在 preflight 解析成具体版本 | 幂等/可复现；离线模式用 artifact 版本 |
| D11 | `ipam.yml` 校验只做最小集 | 不做 IPAM 分配器，避免越权猜测 |
| D12 | `privacy-check.sh` 白名单按**精确文件名/IP**扩充（非通配），并保留对其它 `.env`、其它内网 IP 的拦截 | 否则钩子会拦推送；精确匹配保证检查仍然有效 |
| D13 | `ipam.yml` **去掉** per-node `localdisk_path` | 单条 `nodePathMap` 表达不了 per-node 路径；要 per-node 就得放弃"一份配置一个路径"的简单性 |
| D14 | `ipam.yml` **去掉** `taints` | k3s 侧污点已由 `TAINT_SERVER` 覆盖；节点污点还会牵动 ingress DaemonSet 的 tolerations，超出"简化版"范围 |
| D15 | 集群名唯一来源 = `cluster.env` 的 `CLUSTER_NAME`；`ipam.yml` 删掉 `cluster_name` | 消除两处集群名不一致导致 state/context 错乱的可能 |
| D16 | bootstrap 自己安装 `helm` 到首个 server（在线下载或本地 artifact） | 否则"一条命令"变成"先自己装 helm" |
| D17 | `helm` 装完后不校验 chart value 的具体渲染，靠 `helm --wait` + §15 的 verify 脚本兜底 | 避免过度设计 |

---

## 17. 已确认的答复（2026-10-19）

| # | 问题 | 用户答复 | 对方案的影响 |
|---|---|---|---|
| A1 | 是否真机验证 | **本轮不真机验证** | 交付证据降级为静态校验：`--syntax-check`、`shellcheck`、ipam/config 正反例自测；端到端由用户在真机跑。§15 按此调整 |
| A2 | 本地盘路线 | **选 (a)**：自管 `local-path-provisioner`，SC 名 `localdisk` | §12 第 1 项与 D5 按 (a) 实现；离线需 `local-path-provisioner` tarball |
| A3 | 离线 chart 来源 | **由我尝试下载**；当前**无本地 Helm 仓、无 Artifactory** | 结果：`rancher-2.15.2.tgz` 拉取成功；`nfs-subdir-external-provisioner` 的 tarball 只能从 **GitHub releases** 取，本机不可达 → 该组件与 `localdisk` 一并改为**自管清单**（零 chart）。最终 `CHARTS_MODE=local` 只需 3 个 chart |
| A4 | 集群内 NFS 镜像 | **内网无该镜像** | `IN_CLUSTER_NFS=true` 分支降级为**文档说明 + 不默认启用**；`manifests.yaml` 保留但标注"需先解决镜像来源" |
| A5 | Rancher 证书 | **先走 Rancher 自签**，保留更换接口 | `RANCHER_TLS_SOURCE=rancher` 为默认；`cert-manager` 分支代码路径保留，切一个变量即可 |
| A6 | 与 `k3s-ops.sh` 关系 | **并存且相互独立** | `production/` 不修改 `k3s-ops.sh`、不读写 `vagrant/`；两者只共享 `ansible/roles` 与 `lib/` |

---

## 18. 实现同步（写码过程中与方案的差异，以本节为准）

方案是"想"，这一节是"做"。以下条目与前文冲突时，以本节为准。

### 18.1 父仓库改动：从 4 处扩到 6 处（修正 D2）

| # | 文件 | 改动 | 为什么绕不过 |
|---|---|---|---|
| P1 | `ansible/roles/k3s-server/templates/config.yaml.j2` | `flannel-backend` 参数化（`k3s_config.flannel_backend \| default('vxlan')`） | 约束 11：CNI 默认 Flannel、可配 |
| P2 | 同上 | `disable:` 列表按 `k3s_config.disable_local_storage` 追加 `local-storage` | D5/A2：自管 localdisk 时必须关掉内置的，否则两个 provisioner 抢同一个 PV 名 |
| P3 | `ansible/roles/k3s-common/tasks/main.yml` | `firewall.yml` 外面套 `when: use_ufw \| default(true)` | 约束 15：`USE_UFW=false` 必须真的不碰防火墙；`default(true)` 保住老用法 |
| P4 | `scripts/privacy-check.sh` | 精确文件名豁免 `production/config/cluster.env{,.local.example}`、`production/scripts/kubeconfig.sh`；`ALLOW_IPS` 加 `192.168.100.*`；`ALLOW_PASS_VALUES` 加 `ChangeMe`；`ALLOW_PATH_PATTERNS` 加 `/data/k8s-local-path` | 否则 pre-push 钩子拦住本项目自己的文件（D12） |
| P5 | `ansible/roles/k3s-common/templates/registries.yaml.j2` | 渲染可选 `configs.<host>.auth`（来源 `containerd_registry_credentials`，默认 `auth: {}`） | 约束 9：Artifactory 私有仓库需要 basic auth，否则 k3s 拉镜像 401 |
| P6 | `ansible/roles/{k3s-server,k3s-agent}/tasks/install.yml` | `get_url` 套 `when: not (k3s_skip_download \| default(false))` | 约束 9：离线部署时二进制由 `offline-load.sh` 预置，不能再让 `get_url` 去联网 |

P5/P6 的变量都带 `default()`，父仓库老 playbook 行为不变。

### 18.2 `hosts:` 不做模板展开 → inventory 里落真实 group

`hosts: "{{ first_server_host }}"` 在本机 Ansible 版本下**解析失败**（`--syntax-check` 和 `--list-hosts` 都报
`Error processing keyword 'hosts': ... is undefined`）。host pattern 的展开早于 task 期的模板渲染，
inventory vars 和 `-e` extra vars 都救不了。

做法：`lib/inventory.sh` 直接落两个**真实 group**，playbook 用裸 group 名：

- `first_server` —— 含 ipam.yml 里第一条 `role: server` 的节点；playbook 20/30/50 用 `hosts: first_server`
- `remove_target` —— **始终存在**（无目标时 `hosts: {}`），避免 pattern 不存在时报错；
  由 `scale.sh remove` 在生成 inventory 前 `export PROD_REMOVE_TARGET=<节点>` 填充；
  playbook 50 的目标 play 用 `hosts: remove_target`

`first_server_host` 仍保留在 `all.vars` 里，供 task 内的 `delegate_to:` 等场景使用（task 期模板是好的）。

### 18.3 存储默认值：NFS 默认关闭

`STORAGE_NFS_ENABLED` 默认 `false`。否则开箱就是占位的 `NFS_SERVER`，preflight 硬拦，
"一条命令"第一行就失败。要启用：填真实 `NFS_SERVER` 再改回 `true`（或 `IN_CLUSTER_NFS=true`）。

配套加了两条互斥校验（都在 `config.sh`）：

- `NFS_DEFAULT_SC=true` 但 `STORAGE_NFS_ENABLED=false` → 报错（没有 nfs-client SC 可当默认）
- `IN_CLUSTER_NFS=true` 但 `STORAGE_NFS_ENABLED=false` → 报错（集群内 NFS 就是给 nfs-client 用的）

### 18.4 端口与证书的两处事实修正

- **`INIT_SSH_PORT` vs `SSH_PORT`**：初始 root 首连端口与之后 ops 端口分开。hardening 在改端口后会
  **回连新端口确认可用**才收紧 root（约束 14 的"密钥必须先能用"扩展到端口变更场景）。
- **`RANCHER_TLS_SOURCE` 的合法值只有 `rancher | letsEncrypt | secret`**（读 `rancher-2.15.2.tgz` 的
  `values.schema.json` 确认）。chart 里**没有** cert-manager 子 chart，所以：
  - `secret` 模式必须自己先放好 Secret，cert-manager 可以不开
  - `letsEncrypt` / `rancher` 模式都需要 cert-manager **先于** rancher 装好 —— 流水线顺序已保证（30 号 playbook 内先 cert-manager 再 rancher）
  - 默认 `rancher`（自签名），与 A5 一致

### 18.5 其它落地细节（方案里没写细的）

- **k3s stable 版本解析**：channel endpoint 返回的是 HTML body（不是 302），所以 `prod_resolve_k3s_version`
  先试 `%{redirect_url}`，失败再从 body 里 grep `v<semver>+k3s<n>`。
- **`charts/*.tgz` 不进 git**（根 `.gitignore` 有 `*.tgz`），由 `scripts/fetch-artifacts.sh` 拉取；
  `charts/README.md` 说明要哪几个、放哪。
- **节点 label**：`lib/inventory.sh` 把 `ipam.yml` 的 `labels` 预先拼成 `prod_node_labels`，
  `30-addons.yml` 用 `kubectl label node --overwrite` 应用 —— 扩容后重跑 30 号即可，不用手工。
- **`scale.sh apply` 跑完整流水线**（ssh → 05 → 10 → 20 → 30），新加节点和 bootstrap 走同一条路；
  已存在节点上每一步都是幂等的，不会被反复改。
- **缩容清 etcd member**：k3s 没有 `etcdctl` 子命令，在**剩余**的 server 上用 `/usr/bin/etcdctl`
  （k3s 依赖里自带）执行 `member remove`；找不到就大声警告让用户手工处理，不额外装 `etcd-client` 包。
- **playbook 20 的版本错位**：发现节点上 `/usr/local/bin/k3s` 版本不对时，只有在**集群尚未初始化**
  （etcd 数据目录不存在）时才删掉重装；已初始化的集群只警告，不半升级。
- **`production/` 的示例网段固定用 `192.168.100.0/24`**，已加进 `privacy-check.sh` 的 `ALLOW_IPS`
  （与 Vagrant 用的 `192.168.56.0/24` 区分开）。
