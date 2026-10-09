# k3s-ops 架构设计文档

> 版本: v1.0
> 最后更新: 2026-10-09

---

## 1. 项目概述

k3s-ops 是一个面向 **k3s 全生命周期管理** 的运维项目，基于 **Vagrant + Ansible** 实现本地 VirtualBox 虚拟机的 k3s 集群的自动化部署、扩容、升级、备份恢复和销毁。

### 1.1 核心目标

- **基础设施即代码**：一份 `nodes.yml` 定义整个集群拓扑
- **全生命周期覆盖**：安装、配置、扩容、缩容、升级、备份、恢复、销毁
- **动态扩容**：从单节点起步，随时按需增加 server 或 agent
- **最小化依赖**：仅依赖 Vagrant、VirtualBox、Ansible
- **生产友好**：嵌入式 etcd HA、nginx-ingress、Rancher UI

### 1.2 技术选型

| 层级 | 技术 | 说明 |
|------|------|------|
| 虚拟化 | VirtualBox | 本地 VM 运行环境 |
| VM 编排 | Vagrant | 管理 VM 生命周期（创建/销毁/网络/快照） |
| 配置管理 | Ansible | k3s 安装、配置、运维自动化 |
| Kubernetes | k3s | 轻量级 K8s 发行版 |
| 数据存储 | 嵌入式 etcd | 多 server 高可用 |
| Ingress | nginx-ingress | 替代默认 Traefik |
| UI 管理 | Rancher | 集群可视化管理 |
| Base OS | Ubuntu 22.04 (bento/ubuntu-22.04) | 统一基础镜像 |

---

## 2. 系统架构

### 2.1 整体架构图

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Host Machine                                │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │                     VirtualBox Internal Network               │   │
│  │                      192.168.56.0/24                         │   │
│  │                                                              │   │
│  │  ┌─────────────────┐  ┌─────────────────┐  ┌──────────────┐  │   │
│  │  │   k3s-server-1   │  │   k3s-server-2   │  │ k3s-agent-1  │  │   │
│  │  │   (control)      │  │   (control)      │  │  (worker)    │  │   │
│  │  │                  │  │                  │  │              │  │   │
│  │  │  ┌─────────────┐ │  │  ┌─────────────┐ │  │ ┌──────────┐ │  │   │
│  │  │  │ k3s server  │ │  │  │ k3s server  │ │  │ │k3s agent │ │  │   │
│  │  │  │ (etcd)      │ │  │  │ (etcd)      │ │  │ │          │ │  │   │
│  │  │  ├─────────────┤ │  │  ├─────────────┤ │  │ │workloads │ │  │   │
│  │  │  │ Rancher UI  │ │  │  │ workloads   │ │  │ └──────────┘ │  │   │
│  │  │  ├─────────────┤ │  │  └─────────────┘ │  └──────────────┘  │   │
│  │  │  │nginx-ingress│ │  └─────────────────┘                    │   │
│  │  │  │ workloads   │ │                                         │   │
│  │  │  └─────────────┘ │                                         │   │
│  │  └─────────────────┘                                         │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  管理工具: Vagrant CLI │ Ansible │ k3s-ops.sh                      │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.2 节点角色

| 角色 | 运行组件 | 说明 |
|------|----------|------|
| **server** | k3s server, embedded etcd, kubelet, kube-proxy | 控制面节点，组成 HA etcd 集群 |
| **agent** | k3s agent, kubelet, kube-proxy | 纯工作节点，不运行控制面组件 |

- 首个 server 节点负责初始化集群并生成 join token
- 后续 server 节点自动加入 embedded etcd 集群（HA）
- agent 节点通过 server 的 API 注册到集群
- server 节点默认不设污点，可运行业务负载（小集群友好）

### 2.3 网络规划

| 网络 | CIDR/地址 | 说明 |
|------|-----------|------|
| VirtualBox Internal | 192.168.56.0/24 | 节点间通信 |
| Cluster CIDR (Pod) | 10.42.0.0/16 | Flannel VXLAN |
| Service CIDR | 10.43.0.0/16 | 集群服务网络 |
| NodePort 范围 | 30000-32767 | 服务对外暴露 |

### 2.4 端口规划

| 端口 | 用途 | 协议 | 开放范围 |
|------|------|------|----------|
| 6443 | Kubernetes API Server | TCP | 所有节点 |
| 2379 | etcd 客户端 | TCP | Server 节点间 |
| 2380 | etcd 对等通信 | TCP | Server 节点间 |
| 10250 | kubelet API | TCP | 所有节点 |
| 10256 | kube-proxy 健康检查 | TCP | 所有节点 |
| 8472 | Flannel VXLAN | UDP | 所有节点 |
| 30000-32767 | NodePort 服务 | TCP/UDP | 按需 |

### 2.5 宿主机与 VM 的网络路径（VirtualBox NAT / Host-only）

Vagrant 为每台 VM 接入两块网卡：第一块 **NAT**（`nic1`），第二块 **Host-only**（`nic2`，由 Vagrantfile 的 `private_network` 创建）。两者独立，分工如下（以 server-1 实测为准）：

| 网卡 | VirtualBox 类型 | VM 内接口 / 地址 | 网段 | 用途 |
|------|-----------------|------------------|------|------|
| nic1 | NAT | `eth0` = 10.0.2.15/24 | 10.0.2.0/24 | 出公网；访问宿主机 loopback 上的服务 |
| nic2 | Host-only | `eth1` = 192.168.56.10/24 | 192.168.56.0/24 | 宿主机 ↔ VM、VM ↔ VM（k3s 节点互连） |

**`10.0.2.2` 从哪来？** 它不是本项目配置出来的，而是 **VirtualBox NAT 模式的固定约定**。NAT 引擎在访客与宿主机之间虚拟一个 `10.0.2.0/24` 内网（若有多块 NAT 则依次 `10.0.3.0`…），默认地址见下表（源自 VirtualBox 官方文档）：

| 地址 | 角色 |
|------|------|
| **10.0.2.2** | NAT 网关/路由器 + DHCP 服务器，**并映射到宿主机 loopback `127.0.0.1`** |
| 10.0.2.3 | NAT 内置 DNS 代理（仅 `--natdnsproxy1 on` 时使用） |
| 10.0.2.4 | VirtualBox 内置 TFTP（PXE 引导） |
| **10.0.2.15** | 访客自身（DHCP 分配的第一个地址） |

关键点：NAT 引擎把发往 `10.0.2.2` 的流量**转交给宿主机的 `127.0.0.1`**。因此宿主机上**只监听 loopback 的服务**（例如本机 gitea `127.0.0.1:3000`）无需改绑定、也无需知道宿主机在局域网中的真实 IP，VM 内即可通过 `http://10.0.2.2:3000` 访问。

**实测验证**（server-1，2026-10-09）：

```text
# DHCP 租约 (/run/systemd/netif/leases/2)
ADDRESS=10.0.2.15
ROUTER=10.0.2.2
SERVER_ADDRESS=10.0.2.2

# 路由
default via 10.0.2.2 dev eth0 proto dhcp src 10.0.2.15
10.0.2.2 dev eth0 proto dhcp scope link src 10.0.2.15

# VM 内访问宿主机 loopback 上的 gitea
$ curl http://10.0.2.2:3000/        → HTTP 200
$ curl http://192.168.56.1:3000/    → 不可达（gitea 只绑 loopback，host-only 网关到不了）
```

> 注：DHCP 下发的 DNS 默认是**宿主机配置的 DNS**（本集群为 192.168.2.1）；只有开启 `--natdnsproxy1 on` 后才会显示为 `10.0.2.3`。

**宿主机 → VM 的入口**走 NAT 端口转发（Vagrant `forwarded_port`，来自 `nodes.yml` 的 `port_forwards`）：

| 宿主监听 | → VM | 用途 |
|----------|------|------|
| 127.0.0.1:2222 | :22 | Vagrant SSH |
| :8080 | :30080 | nginx-ingress HTTP |
| :8443 | :30443 | Rancher UI |

**修改 NAT 网段**（一般无需改动）：

```bash
VBoxManage modifyvm <vm> --natnet1 "192.168.99.0/24"
# 网关随之变为 192.168.99.2，访客第一个地址为 192.168.99.15
```

---

## 3. 项目结构

```
k3s-ops/
│
├── docs/                               # 文档
│   └── architecture.md                 # 本架构文档
│
├── vagrant/                            # VM 生命周期管理
│   ├── Vagrantfile                     # 动态 Vagrantfile，读取 nodes.yml
│   └── nodes.yml                       # 集群拓扑定义（核心配置文件）
│
├── ansible/                            # k3s 全生命周期管理
│   ├── ansible.cfg                     # Ansible 配置
│   ├── inventory.yml                   # 动态 Inventory（由 Vagrant 生成）
│   │
│   ├── playbooks/                      # 剧本
│   │   ├── k3s-cluster.yml             # 入口：完整安装 k3s 集群
│   │   ├── k3s-install.yml             # 安装/初始化 k3s
│   │   ├── k3s-add-server.yml          # 添加 server 节点
│   │   ├── k3s-add-agent.yml           # 添加 agent 节点
│   │   ├── k3s-remove-node.yml         # 排空并移除节点
│   │   ├── k3s-upgrade.yml             # 滚动升级 k3s 版本
│   │   ├── k3s-backup.yml              # etcd 快照备份
│   │   ├── k3s-restore.yml             # 从快照恢复集群
│   │   ├── rancher-deploy.yml          # 部署 Rancher UI
│   │   ├── rancher-reset-admin.yml     # 重置 Rancher admin 密码
│   │   └── nginx-ingress-deploy.yml    # 部署 nginx-ingress
│   │
│   ├── roles/                          # 角色
│   │   ├── k3s-common/                 # 基础 OS 配置
│   │   │   ├── tasks/
│   │   │   │   ├── main.yml            # swap, sysctl, hostname
│   │   │   │   ├── containerd.yml      # containerd 镜像加速
│   │   │   │   └── firewall.yml        # 开放端口
│   │   │   └── vars/
│   │   │       └── main.yml
│   │   │
│   │   ├── k3s-server/                 # Server 节点
│   │   │   ├── tasks/
│   │   │   │   ├── main.yml
│   │   │   │   ├── install.yml         # 下载安装 k3s
│   │   │   │   ├── config.yml          # 生成 config.yaml
│   │   │   │   ├── init.yml            # 初始化第一个 server
│   │   │   │   └── join.yml            # 加入已有 etcd 集群
│   │   │   ├── templates/
│   │   │   │   └── config.yaml.j2      # k3s server 配置模板
│   │   │   └── vars/
│   │   │       └── main.yml
│   │   │
│   │   ├── k3s-agent/                  # Agent 节点
│   │   │   ├── tasks/
│   │   │   │   ├── main.yml
│   │   │   │   ├── install.yml         # 下载安装 k3s
│   │   │   │   └── config.yml          # 配置 agent
│   │   │   ├── templates/
│   │   │   │   └── config.yaml.j2
│   │   │   └── vars/
│   │   │       └── main.yml
│   │   │
│   │   └── k3s-manage/                 # 集群管理操作
│   │       ├── tasks/
│   │       │   ├── main.yml
│   │       │   ├── remove-node.yml     # cordon + drain + delete
│   │       │   └── upgrade.yml         # 升级逻辑
│   │       └── templates/
│   │           └── upgrade-plan.yml.j2
│   │
│   ├── group_vars/                     # 分组变量
│   │   ├── all.yml
│   │   ├── server.yml
│   │   └── agent.yml
│   │
│   └── files/                          # 静态文件
│       ├── etcd-snapshot-cron.sh
│       └── health-check.sh
│
├── addons/                             # Helm values
│   ├── rancher/
│   │   └── values.yaml
│   ├── nginx-ingress/
│   │   └── values.yaml
│   └── monitoring/
│       └── values.yaml
│
├── scripts/                            # 辅助脚本
│   ├── bootstrap.sh                    # 环境依赖检查/安装
│   ├── get-kubeconfig.sh               # 获取 kubeconfig
│   ├── update-nodes.sh                 # 更新拓扑后重新 provision
│   └── cleanup.sh                      # 清理本地缓存
│
├── lib/                                # 共享库
│   └── logging.sh                      # 日志库（所有脚本共用）
│
├── logs/                               # 操作日志（自动生成）
│   └── k3s-ops.log                     # 日志文件，超 10MB 自动轮转
│
├── k3s-ops.sh                          # 统一 CLI 入口
├── Vagrantfile                         # 项目根 Vagrantfile（委派到 vagrant/）
└── README.md
```

---

## 4. 集群拓扑定义

### 4.1 nodes.yml 格式

```yaml
# 集群名称，用于主机名前缀和 k3s cluster domain
cluster_name: k3s-demo

# k3s 版本
k3s_version: v1.30.2+k3s2

# 虚拟机网络配置
network:
  subnet: 192.168.56.0/24
  box: bento/ubuntu-22.04

# 节点列表 — 动态扩容在此追加条目
nodes:
  - name: server-1
    role: server
    ip: 192.168.56.10
    cpus: 2
    memory: 4096
    port_forwards:
      - guest: 30443        # Rancher NodePort
        host: 8443
      - guest: 30080        # Ingress HTTP NodePort
        host: 8080

  - name: server-2
    role: server
    ip: 192.168.56.11
    cpus: 2
    memory: 2048

  - name: agent-1
    role: agent
    ip: 192.168.56.20
    cpus: 4
    memory: 8192

# k3s 安装选项
k3s_config:
  disable_traefik: true
  disable_servicelb: true
  taint_server: false
  cluster_cidr: 10.42.0.0/16
  service_cidr: 10.43.0.0/16

# 附加组件
addons:
  rancher:
    enabled: true
    version: 2.9.x
    hostname: rancher.k3s.local
    bootstrap_password: admin
  ingress:
    type: nginx
    enabled: true
    version: 4.11.x
```

### 4.2 动态扩容流程

1. 编辑 `vagrant/nodes.yml`，追加新节点定义
2. 运行 `k3s-ops.sh up <节点名>` — Vagrant 启动新 VM
3. 运行 `k3s-ops.sh add-node <节点名>` — Ansible 将节点加入集群
   - server 角色 → 执行 `k3s-add-server.yml`，加入 etcd 集群
   - agent 角色 → 执行 `k3s-add-agent.yml`，注册到 server

### 4.3 缩容流程

1. 运行 `k3s-ops.sh remove-node -n <节点名>` — Ansible cordon → drain → 删除 node 资源
2. 运行 `vagrant destroy <完整主机名>` — 销毁 VM（remove-node 结束时会提示完整命令）
3. 从 `nodes.yml` 中移除该节点定义

---

## 5. 安装与运维流程

### 5.1 首次部署（从零到集群）

```
Step 1: k3s-common → 所有节点
        主机名配置、关闭 swap、sysctl 优化、防火墙规则

Step 2: k3s-server → server-1（首个控制面节点）
        安装 k3s → 初始化 embedded etcd → 生成 node-token

Step 3: k3s-server → server-2（可选，HA）
        读取 token → 安装 k3s → 加入 etcd 集群

Step 4: k3s-agent → agent-1+（可选，计算节点）
        读取 token → 安装 k3s agent → 注册到集群

Step 5: nginx-ingress-deploy → 任意 server
        通过 Helm 部署 nginx-ingress（NodePort）

Step 6: rancher-deploy → 任意 server
        通过 Helm 部署 Rancher（NodePort 30443）
```

### 5.2 升级流程

k3s 版本升级采用 **逐节点滚动升级** 策略（适用于小集群）：

```
Server 节点:
  Step 1: 升级最后一个非首个 server（先备后主）
  Step 2: 升级第一个 server（最后升级 init 节点）
  每个节点: 替换二进制 → 重启 k3s service → 验证 ready

Agent 节点:
  并行升级所有 agent 节点
  每个节点: 替换二进制 → 重启 k3s service → 验证 ready
```

也可选择部署 **System Upgrade Controller** 实现自动滚动升级。

### 5.3 备份与恢复

**备份**（etcd 快照）：
```bash
k3s etcd-snapshot save \
  --snapshot-dir=/var/lib/rancher/k3s/server/db/snapshots/
```

- Ansible playbook `k3s-backup.yml` 自动执行快照
- 支持定期 cron 任务（`etcd-snapshot-cron.sh`）
- 快照可同步到远程存储

**恢复**：
```bash
k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=<snapshot-file>
```
- Ansible playbook `k3s-restore.yml` 自动执行恢复流程
- 需停止所有节点，仅在 init 节点执行恢复

---

## 6. CLI 使用指南

### 6.1 命令一览

```bash
k3s-ops.sh init                    # 检查 Vagrant/Ansible 依赖
k3s-ops.sh up [node]              # vagrant up（可选指定节点）
k3s-ops.sh down [node] [-f|-s]   # 关闭 VM 释放资源（-f 强制关机 / -s 挂起）
k3s-ops.sh install                # 首次完整安装 k3s 集群
k3s-ops.sh add-node <node>        # 将新节点加入集群
k3s-ops.sh remove-node -n <name>  # 移除指定节点
k3s-ops.sh upgrade -v <version>   # 升级 k3s 版本
k3s-ops.sh backup                 # etcd 快照备份
k3s-ops.sh restore -f <snapshot>  # 从快照恢复
k3s-ops.sh deploy-rancher         # 部署 Rancher UI
k3s-ops.sh reset-rancher-admin    # 重置 Rancher admin 密码
k3s-ops.sh deploy-ingress         # 部署 nginx-ingress
k3s-ops.sh status                 # 集群健康检查
k3s-ops.sh destroy                # 销毁所有 VM
k3s-ops.sh ssh <node>             # SSH 到指定节点
k3s-ops.sh kubeconfig             # 获取 kubeconfig
```

### 6.2 典型使用场景

**场景一：从零开始部署单节点测试环境**
```bash
# nodes.yml 中只配 server-1
./k3s-ops.sh init
./k3s-ops.sh up
./k3s-ops.sh install
./k3s-ops.sh deploy-ingress
./k3s-ops.sh deploy-rancher
```

**场景二：扩容为 3 节点 HA 集群**
```bash
# nodes.yml 追加 server-2, agent-1
./k3s-ops.sh up
./k3s-ops.sh add-node server-2
./k3s-ops.sh add-node agent-1
```

**场景三：日常升级**
```bash
./k3s-ops.sh upgrade -v v1.31.0+k3s1
```

**场景四：节点故障替换**
```bash
./k3s-ops.sh remove-node -n agent-1
vagrant destroy k3s-demo-agent-1   # 如果 VM 还活着（vagrant 命令需完整主机名）
# 修复或重建后重新添加
./k3s-ops.sh up k3s-demo-agent-1
./k3s-ops.sh add-node agent-1
```

---

## 7. Rancher 部署方案

| 项目 | 说明 |
|------|------|
| 部署方式 | Helm chart 部署到 k3s 集群 |
| 暴露方式 | NodePort 30443（独立于 ingress） |
| 访问地址 | `https://<server-1-ip>:30443` |
| 登录凭据 | 预设 bootstrap password |
| 管理模式 | Self-managed（Rancher 管理自身集群） |
| TLS | 自签名证书（后续可替换为 cert-manager） |

---

## 8. 安全考虑

- k3s token 存储在 Ansible Vault 加密变量中
- etcd 快照文件建议加密后存储
- 默认关闭 k3s 中的 Traefik 和 ServiceLB 以减少攻击面
- 使用 containerd 而非 Docker，减少守护进程暴露
- Rancher 部署后建议配置认证和 RBAC
- 宿主机与 VM 之间通过 VirtualBox Internal Network 隔离

---

## 9. 日志系统

### 9.1 架构

```
宿主机 (Host)                                    VM 节点
┌──────────────────────────────┐          ┌──────────────────────────┐
│  k3s-ops.sh                  │          │  health-check.sh         │
│  scripts/*.sh                │          │  etcd-snapshot-*.sh      │
│        │                     │          │        │                 │
│        ▼                     │          │        ▼                 │
│  lib/logging.sh              │          │  /var/log/               │
│  ──── 写入 ────────────────►  │          │  ├─ k3s-backup.log       │
│  logs/k3s-ops.log            │          │  └─ k3s-health.log       │
│  logs/health-check.log       │          └──────────────────────────┘
└──────────────────────────────┘
```

| 层级 | 日志位置 | 说明 |
|------|----------|------|
| **Host CLI** | `logs/k3s-ops.log` | 所有 `k3s-ops.sh` 和 `scripts/*.sh` 的操作日志 |
| **Host 健康检查** | `logs/health-check.log` | `status` 在宿主机执行时的健康检查输出（非 root 无法写 `/var/log`） |
| **Host VirtualBox** | `logs/vbox/` | VirtualBox 生成的 `*VBoxHeadless-*.log`，由 `up` / `down` / `destroy` 自动归档，保留最近 20 个（`VBOX_LOG_KEEP` 可调） |
| **VM 备份** | `/var/log/k3s-backup.log` | etcd 快照备份日志（VM 本地） |
| **VM 健康检查** | `/var/log/k3s-health.log` | 健康检查输出（VM 本地） |

`health-check.sh` 通过 `LOG_FILE` 环境变量决定日志位置：未设置时默认 `/var/log/k3s-health.log`（VM 上以 root 运行），不可写时自动降级到 `$TMPDIR/k3s-health.log`，因此同一份脚本在宿主机和 VM 上都能直接执行。

VirtualBox 会把每个 VM 进程的 `*VBoxHeadless-*.log` 写进启动进程的当前工作目录（即项目根），而 VirtualBox 7.x 已移除 `VBoxManage set logfile`，无法修改写入位置。因此 `k3s-ops.sh` 在 `up` / `down` / `destroy` 结束后调用 `_archive_vbox_logs()`，把根目录的这类文件移入 `logs/vbox/`，并按修改时间仅保留最近 20 个。

### 9.2 日志库 (`lib/logging.sh`)

所有宿主机侧脚本共用同一个日志库，通过 `source lib/logging.sh` 引入：

| 函数 | 用途 |
|------|------|
| `log_init` | 初始化日志目录，日志文件超 10MB 自动轮转（最多保留 5 个归档） |
| `log_info` | INFO 级别（终端绿色 + 文件） |
| `log_warn` | WARN 级别（终端黄色 + 文件） |
| `log_error` | ERROR 级别（终端红色 + 文件，输出到 stderr） |
| `log_debug` | DEBUG 级别（终端和文件） |
| `log_cmd` | 包裹命令执行，自动记录开始/结束/耗时/退出码 |
| `log_mark` | 标记性消息（如阶段开始/结束） |

### 9.3 日志格式

```
[2026-05-25 10:30:01] [INIT] === k3s-ops session started ===
[2026-05-25 10:30:01] [INFO]  Starting all VMs
[2026-05-25 10:30:01] [CMD]  === Starting all VMs (PID=12345) ===
[2026-05-25 10:35:22] [CMD]  --- Starting all VMs completed (4m21s) ---
[2026-05-25 10:35:22] [INFO]  Cluster installation complete!
[2026-05-25 10:35:30] [WARN]  This will destroy all VMs. Are you sure?
[2026-05-25 10:35:35] [ERROR] Node not found in nodes.yml
```

### 9.4 日志轮转

- 单文件上限 10MB
- 超限后自动归档：`k3s-ops.log.1` → `k3s-ops.log.2` → ... → `k3s-ops.log.5`
- 最旧归档自动丢弃
- 日志目录 `logs/` 已在 `.gitignore` 中忽略（不应纳入版本控制）

---

## 10. 分阶段实施计划

| 阶段 | 内容 | 依赖 | 里程碑 |
|------|------|------|--------|
| **Phase 1** | 项目骨架、Vagrantfile、nodes.yml、k3s 安装 playbook | 无 | 1 server 启动成功，kubectl get nodes Ready |
| **Phase 2** | 多 server HA join + agent 安装 + 节点增删 | Phase 1 | 3 节点集群动态扩缩 |
| **Phase 3** | nginx-ingress 部署 + Rancher 部署 | Phase 2 | 通过 Rancher 管理集群 |
| **Phase 4** | 升级 + 备份恢复 + 健康检查脚本 | Phase 2 | 完整运维链路 |
| **Phase 5** | 可选：监控（kube-prometheus-stack） | Phase 3 | 可观测性 |

---

## 11. 环境要求

| 工具 | 版本要求 | 用途 |
|------|----------|------|
| VirtualBox | >= 7.0 | VM 运行环境 |
| Vagrant | >= 2.3 | VM 编排 |
| Ansible | >= 2.15 | 配置管理 |
| helm | >= 3.14 | 部署 addons |
| kubectl | 匹配 k3s 版本 | 集群管理 |

宿主机内存建议 >= 16GB（3 节点集群约需 8-12GB）。

---

## 12. 设计决策记录

| 决策 | 选项 | 选择 | 理由 |
|------|------|------|------|
| VM 编排 | Terraform vs Vagrant | Vagrant | VirtualBox 生态最成熟的管理工具 |
| K8s 发行版 | k3s vs MicroK8s vs Kubeadm | k3s | 轻量、嵌入式 etcd、单二进制部署 |
| 数据存储 | SQLite vs 嵌入式 etcd | 嵌入式 etcd | 支持多 server HA，适合动态扩容 |
| Ingress | Traefik vs nginx-ingress | nginx-ingress | 用户指定，社区广泛使用 |
| 管理 UI | Rancher vs 开源 Dashboard | Rancher | 用户指定，提供完整集群管理能力 |
| Server 污点 | 设污点 vs 不设 | 不设（taint_server: false） | 小集群充分利用资源 |
| 升级策略 | System Upgrade Controller vs Ansible | Ansible | 小集群更直观可控 |
