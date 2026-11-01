# production/ 需求与早期设计存档（v0 → v1）

> **本文是历史存档，不是操作手册。**
>
> - 现行设计（权威）：[design.md](design.md)
> - 操作手册：[README.md](README.md)
>
> 保留本文的目的只有一个：能查清「当初的需求是什么、实现前是怎么设计的」。
> 与 `design.md` 冲突时，**一律以 `design.md` 为准**。

- 来源：2026-10-19 的需求会话 + 早期设计稿，经磁盘 carve 从已删除文件中还原
- 状态：**已归档（superseded）**

---

## 1. 需求原文（照录，未改错别字）

下面是需求提出时的原话：第一行是开场，其后是需求本体（第 1–11 条）与你补充的 10 个回答（第 12–21 条）。`prduction`、`服务嚣`、`loccaldisk`、`agentr` 等均为原文笔误，一律照录，以便和后来的实现对照。

根据你的 10 个回答，直接按此方案生成 `production/` 目录全套文件。

作一版简化的公司级测试环境和生产环境皆能用的一键部署k8s集群环境方案，放在项目根目录的prduction目录下，服务器前期会提供3台已经安装好的最小安装的服务嚣--安装k8s集群前需要初始化设置参数，后期可以执行脚本进行server、agentr 扩缩容，后面可能会用到Terraform进行动态服务嚣分配（kvm/proxmox），以当前环境参考为主略加变动，Ansible（复用 k3s-ops 现有 roles）+服务器初始化,nginx-ingress使用80、443端口监听，pvc使用localdisk和nfs,其他你补充--有疑问的你提出我来回答，做到靠近真实场景、好实现、易扩展 ,      同时1.ssh前期使用root+密码登录，生成并设置运维账号ops及登录密钥，初始化完成后只能使用ops登录运维 2.服务嚣主机ip按静态分配，主机名按xxx-k8s-01(其中xxx前缀可以在设置文件修改) ，IPAM也在设置文件中设置  3.暂时不需要VIP 4.nginx-insgress不需要保留nodeport,前置LB后期可能会有，目前没有 5.loccaldisk路径目录先假设在/nfs-share下，最终以配置文件为准 6.外部NFS Server假设为http://nfs-server.example.com、路径为/nfs-share、nfs版本为v4、可读写、支持在集群内部署NFS,IP、路径以最终以配置文件为准 7.时区Shanghai、统一chrony、ssh端口可以修改、关闭swap、内核参数无额外要求，防火墙使用ufw 8.k3s默认用最新稳定版并允许可配置 9.内网镜像仓库后期会用到Artifactory并保留registries.yaml,支持离线部署 10.动态分配服务器的VM模板以配置文件为准 11.CNI默认使用Flannel,最终以配置文件为准
12.集群节点ip按ipam 自由指定 ，`config/ipam.yml` 唯一事实源。脚本从中读取 `hostname/ip/role`，首个 `role=server` 作为集群 init 节点 13.服务器初始化时创建 `ops` 用户并配置 `sudoers.d/ops`：`ops ALL=(ALL) NOPASSWD:ALL`。后续可手动改为需密码 14. 改端口可选 + 密钥生效再禁用 root | `cluster.env` 增加 `SSH_PORT`（默认22，可改）。`ssh-setup.sh` 先下发密钥、验证用 `ops+密钥` 可连后再按 `DISABLE_ROOT_SSH_AFTER_INIT=true` 调整 `sshd_config`（建议先用 `prohibit-password` 策略再视需设 `no`）。  15.ufw 可选、不强制统一 ，增加 `USE_UFW=true/false`。若为 false 则跳过 ufw 相关任务。仍复用现有 firewalld 逻辑时也不冲突（按开关选择）。 16.nginx-ingress 走 `hostNetwork: true`，`controller.service.enabled=false`，直接监听宿主机 80/443。**不保留 NodePort** 17.`LOCALDISK_PATH` 默认值改为 `/opt/k8s-local-path`。目录根据配置文件创建并设置权限。配置文件优先生效 18. `IN_CLUSTER_NFS=true/false`。开启时预部署简易 NFS Server（可选）并配合 nfs-subdir-external-provisioner 使用；关闭时仅配置外部 NFS 19.生成到 production/kubeconfig 并设置 KUBECONFIG 提示 20.最小校验（首个 server 必须存在、至少 1 台 server、防误删） ， `bootstrap.sh` 校验 ipam 至少一条 `role: server`；`scale.sh remove` 增加保护（防止误删最后一台 server 等最简校验） 21.`terraform/` 仅放 `README.md` 和 `vm_template.yml.example`，暂不生成 `main.tf`。

---

## 2. 需求确认点与落实方式

> 这张表回答的是 §1 需求里的第 **12–21** 条，也就是需求开头「根据你的 10 个回答」所指的十问十答；此处保留 C 记录里的原始编号（1–10），便于和 §3 的设计稿逐条对照。
>
> 与 [design.md §2](design.md) 同源，但表内的 playbook 文件名（如 `01-os-init.yml`、`04-addons-prep.yml`）是当时的编号，现行编号见 §4。

| 回答 | 落实方式 |
|---|---|
| 1. C（按 ipam 自由指定） | `config/ipam.yml` 唯一事实源。脚本从中读取 `hostname/ip/role`，首个 `role=server` 作为集群 init 节点。 |
| 2. 先 NOPASSWD，后续收紧 | `01-os-init.yml` 创建 `ops` 用户并配置 `sudoers.d/ops`：`ops ALL=(ALL) NOPASSWD:ALL`。后续可手动改为需密码。 |
| 3. 改端口可选 + 密钥生效再禁用 root | `cluster.env` 增加 `SSH_PORT`（默认22，可改）。`ssh-setup.sh` 先下发密钥、验证用 `ops+密钥` 可连后再按 `DISABLE_ROOT_SSH_AFTER_INIT=true` 调整 `sshd_config`（建议先用 `prohibit-password` 策略再视需设 `no`）。 |
| 4. ufw 可选、不强制统一 | 增加 `USE_UFW=true/false`。若为 false 则跳过 ufw 相关任务。仍复用现有 firewalld 逻辑时也不冲突（按开关选择）。 |
| 5. 同意 hostNetwork | nginx-ingress 走 `hostNetwork: true`，`controller.service.enabled=false`，直接监听宿主机 80/443。**不保留 NodePort**。 |
| 6. 默认 `/opt/k8s-local-path` | `LOCALDISK_PATH` 默认值改为 `/opt/k8s-local-path`。目录由 `04-addons-prep.yml` 创建并设置权限。配置文件优先生效。 |
| 7. 集群内 NFS 开关 | `IN_CLUSTER_NFS=true/false`。开启时预部署简易 NFS Server（可选）并配合 nfs-subdir-external-provisioner 使用；关闭时仅配置外部 NFS。 |
| 8. kubeconfig 输出到 `production/kubeconfig` 并提示 | `bootstrap.sh` 从首台 server 抽取 kubeconfig 至 `production/kubeconfig`，并打印 `export KUBECONFIG=$(pwd)/kubeconfig` 提示。**不强制覆盖宿主机 `~/.kube/config`**。 |
| 9. 最小校验（首个 server 必须存在、至少 1 台 server、防误删） | `bootstrap.sh` 校验 ipam 至少一条 `role: server`；`scale.sh remove` 增加保护（防止误删最后一台 server 等最简校验）。 |
| 10. 仅目录+示例 `vm_template.yml` | `terraform/` 仅放 `README.md` 和 `vm_template.yml.example`，暂不生成 `main.tf`。 |

---

## 3. v0 早期设计稿（已被 v1 取代）

> 还原自当时的《prduction - 简化版一键部署 K8s 集群方案》。
> ⚠️ 目录名 `prduction` 是原文笔误；目录结构、配置文件名、脚本名都已随 v1 重构改变，差异见 §4。
> 保留它的价值在于：它写清了**为什么这样设计**——复用现有 roles、先初始化后部署、把安全收紧放在最后一步。
>
> 说明：原文小节编号为 1–8，此处加 `3.` 前缀以免与本文 §1/§2 混淆。原文的代码块围栏在磁盘上已丢失，下面的围栏与列表标记是**按原意补回**的；本机绝对路径已替换为 `<repo-root>`。除上述两类之外，文字内容未改。

本方案基于现有 k3s-ops 项目，面向公司级测试环境和生产环境，采用 Ansible（复用 k3s-ops 现有 roles） + 服务器初始化 的方式实现一键部署。预留 Terraform（KVM/Proxmox） 用于后期动态服务器分配。

### 3.1 设计原则

- **复用现有资产**：尽量复用 `k3s-ops/ansible/roles/` 下的 `k3s-common`、`k3s-server`、`k3s-agent`、`k3s-manage`，避免重复造轮子。
- **配置驱动**：所有参数均由 `vars/config.yml` 控制（主机名前缀、IPAM、SSH、NFS、Ingress、存储、k3s 版本等），最终以配置文件为准。
- **先初始化、后部署**：前期使用 root + 密码 登录最小化安装的服务器，完成初始化（账号、SSH、时区、网络、UFW 等）后，仅允许 ops 账号通过 SSH 密钥登录。
- **靠近真实场景、好实现、易扩展**：简化但不精简关键环节，预留 Terraform 动态分配和 Artifactory 离线部署能力。
- **安全收紧**：初始化完成后禁用 root 密码登录，统一使用运维账号 ops + SSH 密钥进行运维。

### 3.2 目录结构

```text
prduction/
├── README.md
├── ansible.cfg
├── inventory/
│   ├── .gitignore        # 忽略 hosts.yml
│   └── hosts.example.yml
├── vars/
│   ├── .gitignore        # 忽略 config.yml
│   └── config.example.yml
├── scripts/
│   ├── gen-inventory.py  # 根据 config.yml 生成 inventory/hosts.yml
│   └── one-key.sh       # 一键初始化+部署
├── playbooks/
│   ├── 00-os-init.yml     # 服务器初始化（root+密码）
│   ├── 01-k3s-prepare.yml # k3s 前置准备
│   ├── 02-k3s-install.yml # k3s 集群安装
│   ├── 03-addons.yml     # Ingress + 存储（localdisk + NFS）
│   └── site.yml
├── roles/
│   ├── os-init/           # 主机名、静态IP、chrony、swap、ufw、ops账号、sshd收紧
│   ├── k3s-prepare/       # registries.yaml、基础预检
│   ├── ingress-hostnet/   # nginx-ingress（hostNetwork 80/443，不保留 NodePort）
│   ├── storage-local/     # local-path-provisioner（localdisk）
│   └── storage-nfs/       # nfs-subdir-external-provisioner（外部NFS）
├── templates/
│   ├── registries.yaml.j2
│   ├── ingress-nginx-hostnetwork.values.yaml.j2
│   ├── localdisk-sc.yaml.j2
│   └── nfs-sc.yaml.j2
└── terraform/
    ├── kvm/              # KVM 动态分配预留（示例）
    └── proxmox/           # Proxmox 动态分配预留（示例）
```

### 3.3 使用前准备

- 准备 3 台已安装好的最小化安装的 Linux 服务器（Ubuntu 22.04 推荐）。
- 确认能使用 root + 密码 SSH 登录这 3 台服务器。
- 准备好用于 ops 账号的 SSH 公钥（推荐 ed25519）。
- 按实际环境准备外部 NFS Server 信息（本方案按 nfs-server.example.com:/nfs-share 假设，可在配置文件修改）。
- 确定集群网络、静态 IP 分配方案（IPAM 在配置文件中设置）。

### 3.4 配置文件

复制示例配置文件并按实际环境填写：

```bash
cd <repo-root>
cp prduction/vars/config.example.yml prduction/vars/config.yml
```

关键配置项说明：

| 配置项 | 说明 |
|---|---|
| cluster_prefix | 主机名前缀，最终主机名格式为 xxx-k8s-01、xxx-k8s-02、xxx-k8s-03 |
| ipam.nodes | 每台服务器的 hostname、role（server/agent）、ip。主机名需按 xxx-k8s-XX 格式，或按 hostname_rule 自动生成 |
| ops_user.ssh_pubkey | 运维账号 ops 的 SSH 公钥（必填，用于密钥登录） |
| sshd.port | SSH 端口（可修改，初始化后生效） |
| k3s.version | k3s 版本，默认 latest（自动获取最新稳定版），也可固定如 v1.31.3+k3s1 |
| k3s.cni | CNI，默认 flannel，最终以配置文件为准 |
| ingress | nginx-ingress 使用 hostNetwork 直接监听 80/443，不保留 NodePort |
| storage.localdisk.path | localdisk 存储路径，默认 /nfs-share/local-disk（按要求先假设在 /nfs-share 下，最终以配置文件为准） |
| storage.nfs.server/path | 外部 NFS Server 信息（vers=4、可读写）。支持在集群内部署 NFS Client |
| registries | 内网镜像仓库预留（Artifactory），支持离线部署，保留 registries.yaml |
| ufw | 防火墙使用 UFW，默认仅放行必要端口（SSH、80、443、6443、8472、10250） |
| ntp/timezone | 时区 Asia/Shanghai，统一使用 chrony |

### 3.5 一键部署

```bash
cd <repo-root>
bash prduction/scripts/one-key.sh
```

执行流程：

- **校验配置**：检查 vars/config.yml 是否存在
- **生成 Inventory**：根据 config.yml 自动生成 inventory/hosts.yml
- **00-os-init（root + 密码）**：主机名、静态 IP、时区/chrony、关闭 swap、UFW、防火墙规则、创建 ops 用户并配置 SSH 公钥、收紧 sshd（初始化完成后仅允许 ops 密钥登录）。首次运行会提示输入 root 密码（-k）
- **01-k3s-prepare（ops + 密钥）**：准备工作目录、下发 registries.yaml、基础预检
- **02-k3s-install（ops + 密钥）**：安装 k3s 集群。首台 server 执行 cluster-init，其余 server/agent 按角色 join
- **03-addons（ops + 密钥）**：部署 nginx-ingress（hostNetwork 80/443，不保留 NodePort）、local-path-provisioner（local-disk SC）、nfs-subdir-external-provisioner（nfs-client SC）

### 3.6 部署验证

#### 3.6.1 检查节点

```bash
export KUBECONFIG=<repo-root>/kubeconfig  # 或脚本自动获取
kubectl get nodes
kubectl get cs
```

#### 3.6.2 检查 Ingress（hostNetwork 80/443）

```bash
# 查看 Pod 是否使用 hostNetwork
kubectl -n ingress-nginx get pod -o jsonpath='{range .items[*]}{.metadata.name}{" hostNetwork="}{.spec.hostNetwork}{" dnsPolicy="}{.spec.dnsPolicy}{"\n"}{end}'

# 节点上是否监听 80/443
ssh -p <sshd.port> ops@<任一节点IP> "ss -tlnp | grep -E ':(80|443)\b'"
```

预期：hostNetwork=true、dnsPolicy=ClusterFirstWithHostNet，节点上有进程监听 0.0.0.0:80、0.0.0.0:443。

#### 3.6.3 检查 StorageClass

```bash
kubectl get sc
```

预期输出包含：

```text
local-disk   local-path     Retain/WaitForFirstConsumer
nfs-client   cluster.local/nfs-subdir-external-provisioner   Delete
```

#### 3.6.4 测试 PVC（可选）

```bash
cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-local
  namespace: default
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: local-disk
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-nfs
  namespace: default
spec:
  accessModes: ["ReadWriteMany"]
  storageClassName: nfs-client
  resources:
    requests:
      storage: 1Gi
YAML

kubectl get pvc
kubectl delete pvc test-local test-nfs
```

### 3.7 运维说明

- **初始化后登录方式**：仅允许 ops 账号通过 SSH 密钥登录，root 密码登录已禁用（按 sshd 配置收紧）。
- **后续执行 Playbook**：可直接使用 ops 用户 + 私钥运行 Ansible，无需再加 -u root -k。
- **动态分配预留**：terraform/kvm/ 和 terraform/proxmox/ 提供最简示例，字段与 vars/config.yml 对齐。后续使用 Terraform 动态申请虚拟机时，可结合 scripts/gen-inventory.py 思路自动生成 inventory/hosts.yml。
- **内网镜像仓库**：registries.yaml 已预留 Artifactory endpoints，后续按需补充认证配置即可支持离线部署。
- **CNI/NFS/IPAM/路径**：全部以 vars/config.yml 为准。文档中提及的默认值均为"先假设"，请按实际环境修改配置文件。

### 3.8 注意事项

- **静态 IP（netplan）**：os-init 会渲染 /etc/netplan/01-static-ip.yaml。不同最小化系统的网卡名称可能不同。如果应用后网络异常，可检查实际网卡名（ip link）并调整模板 roles/os-init/templates/01-static-ip.yaml.j2 后重新执行 00-os-init.yml。
- **SSH 收紧前提**：务必确认 ops_user.ssh_pubkey 填写正确且可用，再执行 00-os-init.yml。否则可能导致 SSH 密钥登录失败。
- **Ingress hostNetwork**：nginx-ingress 直接绑定节点 80/443，不保留 NodePort。当前未配置前置 LB，如需通过域名访问请直接使用节点 IP + Host 头，或后续在节点前加反向代理/LB。
- **多 Server ETCD 端口**：本方案默认按最简放行清单（含 6443、8472、10250）。如果后续扩展 server 节点数（etcd 通讯 2379/2380），需按需在 ufw.allow 中补充对应端口。
- **k3s 最新稳定版**：k3s.version: latest 会尝试从 GitHub 获取最新稳定版 Tag。生产环境建议固定版本以保证可控性。

---

## 4. v0 → 现行实现对照

| 维度 | v0 设计稿 | 现行实现（v1） |
|---|---|---|
| 目录名 | `prduction/`（笔误） | `production/` |
| 配置 | 单文件 `vars/config.yml`（+ `.example`） | 拆成两个：`config/cluster.env`（主配置） + `config/ipam.yml`（IPAM 唯一事实源） |
| 配置样例 | `vars/config.example.yml` | `config/cluster.env.local.example`、`config/ipam.yml`（含样例节点） |
| 一键入口 | `scripts/one-key.sh` | `bootstrap.sh`（production/ 根下） |
| Inventory | `scripts/gen-inventory.py` 生成 `inventory/hosts.yml` | `lib/inventory.sh` 生成 `ansible/inventories/production/` |
| Playbook | `00-os-init` / `01-k3s-prepare` / `02-k3s-install` / `03-addons` / `site.yml` | `05-preflight` / `10-os-init` / `20-k3s-cluster` / `30-addons` / `40-scale-add` / `50-scale-remove` / `60-upgrade` / `70-backup` |
| 角色 | 新建 `os-init`、`k3s-prepare`、`ingress-hostnet`、`storage-local`、`storage-nfs`，复用父仓库 `ansible/roles` | 自带 `ansible/roles/{k3s-common,k3s-server,k3s-agent,k3s-manage}` 副本；addons 走 `manifests/` + `charts/` |
| 仓库依赖 | 依赖父仓库的 `ansible/roles`、`lib/` | **自包含**，`production/` 可整体拷走独立运行（父仓库仅 1 处隐私白名单改动） |
| localdisk 默认路径 | `/nfs-share/local-disk` | `/opt/k8s-local-path`（`LOCALDISK_PATH`） |
| registries | `templates/registries.yaml.j2` | `config/registries.yaml.example` |
| Terraform | `terraform/kvm/`、`terraform/proxmox/` 示例目录 | `terraform/` 只放 `README.md` + `vm_template.yml.example` |
| kubeconfig | `<repo-root>/kubeconfig` | `production/kubeconfig`（由 `scripts/kubeconfig.sh` 生成） |
| 扩缩容 | `scripts/scale.sh`（v0 已规划） | `scale.sh` + `40-scale-add.yml` / `50-scale-remove.yml`，含"不能删最后一台 server"保护 |

---

## 5. 未收录的内容及原因

原始记录（C，共 902 行）里还有三段没有收进来，原因如下。

### 5.1 「生成文件」（810 行）——不收录

整节是 `mkdir -p` 加几十个 `cat > … << 'EOF'` 的全量文件内容。

- 这些文件如今已真实存在于 `production/` 仓库中；
- 且与现行实现有差异（playbook 编号、配置拆分、角色归属都变了）；
- 照抄进来会与现状冲突，且容易被误当成现行代码。

要看实现直接读仓库文件；要看设计意图读 [design.md](design.md)。

### 5.2 「目录结构」（62 行）——不收录

C 的目录树是 v0 与 v1 之间的**中间态**：`00-preflight.yml`、`config/cluster.env.example`、`config/registries.yaml.tpl`。

- v0 是 `playbooks/00-os-init.yml` + `vars/config.yml`（见 §3）；
- v1 是 `05-preflight.yml` + `config/cluster.env` + `config/registries.yaml.example`；
- 这棵树两边都不对，贴进来只会误导，差异已在 §4 按维度列全。

### 5.3 「说明」（7 行）——不收录

那 5 条是当时写码的临时备注，其中三条后来被实现推翻：

| C 里的说法 | 现行实现 |
|---|---|
| 复用父仓库 `../../../ansible/roles/...` | v1 改为 `production/` 自带 role 副本，**自包含**可整体拷走 |
| `ufw` 开关默认 false | 现行 `config/cluster.env` 是 `USE_UFW=true` |
| kubeconfig 由 `bootstrap.sh` 简单替换 server | 现由 `scripts/kubeconfig.sh` 用 ipam 首个 server 的真实 IP 替换 `127.0.0.1:6443` |

其余两条（hostNetwork 下 80/443 被 ingress 直接占用、后续接前置 LB 时再调 values）与现状一致，但没有新信息，不重复收录。

### 5.4 §3 里补回的围栏与列表

A 稿在磁盘上已丢失全部代码块围栏与列表标记（对还原文件统计三个反引号的出现次数，结果为 0），直接并进来命令会糊成一段。

§3 中的代码块围栏、`-` 列表符号和 `###` 小节标题是按原意补回的，**文字内容一字未改**。逐行比对结果：A 的 139 行正文全部命中，缺失 0 段；仅 8 个小节标题按 `3.x` 重新编号（原文为 1–8），文字未改。

另外，原文里的 4 处本机绝对路径（两处 `cd`、一处 `KUBECONFIG` 导出、一处 §4 对照表条目）已统一替换为 `<repo-root>`，避免把本地路径写进公开仓库。

---

## 6. 参考

- [design.md](design.md) —— 现行设计（权威）
- [README.md](README.md) —— 操作手册
- [../docs/k3s-production-scaling-plan.md](../docs/k3s-production-scaling-plan.md) —— 生产化落地路径与扩缩容选型建议
