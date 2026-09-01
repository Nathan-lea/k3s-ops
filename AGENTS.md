# k3s-ops 项目备忘录

## 项目概述

k3s 全生命周期管理项目，基于 Vagrant + Ansible + VirtualBox 实现本地 k3s 集群的自动化部署、运维。

## 技术栈

- **VM 编排**: Vagrant (bento/ubuntu-22.04 box)
- **配置管理**: Ansible >= 2.15
- **K8s 发行版**: k3s（嵌入式 etcd, 多 server HA）
- **Ingress**: nginx-ingress（替代默认 Traefik）
- **管理 UI**: Rancher（部署在 k3s 集群上, NodePort 30443）
- **虚拟化**: VirtualBox >= 7.0

## 项目结构

```
k3s-ops/
├── vagrant/
│   ├── Vagrantfile          # 读取 nodes.yml 动态创建 VM
│   └── nodes.yml            # 集群拓扑配置（核心）
├── ansible/
│   ├── playbooks/           # 12 个 playbook
│   ├── roles/
│   │   ├── k3s-common/      # OS 基础配置（swap/sysctl/firewall/containerd）
│   │   ├── k3s-server/      # server 安装（init/join）
│   │   ├── k3s-agent/       # agent 安装
│   │   └── k3s-manage/      # remove/upgrade 操作
│   └── group_vars/          # all.yml / server.yml / agent.yml
├── addons/                  # Helm values
├── scripts/                 # 辅助脚本
├── lib/
│   └── logging.sh           # 共享日志库（所有脚本通过 source 引入）
├── logs/                    # 操作日志（自动生成，超 10MB 归档）
├── k3s-ops.sh               # 统一 CLI 入口
└── docs/architecture.md     # 详细架构设计文档
```

## 关键设计决策

- **首个 server** 带 `cluster-init: true`，后续 server 通过 etcd join
- **server 不设污点**（taint_server: false），小集群可运行业务负载
- **节点扩容**：修改 nodes.yml → `k3s-ops.sh up` → `k3s-ops.sh add-node <name>`
- **节点缩容**：`k3s-ops.sh remove-node -n <name>` → `vagrant destroy <name>`
- **升级策略**：逐节点替换二进制 + 重启 service（Ansible 方式）
- **vagrant/nodes.yml** 是唯一需要手动编辑的配置文件

## CLI 入口

```bash
k3s-ops.sh init|up|install|add-node|remove-node|upgrade|backup|restore|deploy-rancher|deploy-ingress|status|destroy|ssh|kubeconfig
```

## 日志

- **宿主机日志**: `logs/k3s-ops.log`（所有 CLI 操作，超 10MB 自动轮转）
- **VM 节点日志**: `/var/log/k3s-backup.log`, `/var/log/k3s-health.log`
- **统一日志库**: `lib/logging.sh`（提供 log_info/warn/error/debug/cmd/mark）

## 路由提醒

- 文档路径：`docs/architecture.md`（设计文档，变更时同步更新）
- kubeconfig 路径：项目根目录下 `kubeconfig`（vagrant up + install 后自动拉取）

## 部署记录

### 端口分配

| 组件 | 协议 | NodePort | 说明 |
|------|------|----------|------|
| nginx-ingress | HTTP | 30080 | 外部流量入口 |
| nginx-ingress | HTTPS | 30444 | 外部流量入口（TLS） |
| Rancher | HTTPS | 30443 | Rancher UI 管理端 |

### 当前集群拓扑

- 1 个 server 节点: k3s-demo-server-1 (192.168.56.10, 2c/4GB)
- 1 个 agent 节点: k3s-demo-agent-1 (192.168.56.20, 2c/4GB)
- 数据存储: 嵌入式 etcd（单节点模式）
- server-2 (192.168.56.11) 已被移除
- 已部署组件: k3s, nginx-ingress, cert-manager, Rancher

### 关键操作说明

1. **镜像拉取限制**: 部署环境无法直接访问 Docker Hub/GCR/GitHub raw。使用 docker.1panel.live 作为 Docker Hub 镜像。registry.k8s.io 和 quay.io 同样配置了镜像。
2. **Rancher 部署**: 如果 Helm 部署时镜像拉取超时，需在宿主机 Docker 先 pull 镜像，然后 save → scp → k3s ctr images import 导入到 VM 的 containerd。
3. **路径**: Vagrant Ansible 依赖需通过 `ENV['ANSIBLE_ROLES_PATH']` 设置角色路径，使用 `--config` 而非 `--ansible-cli` 参数。helm 安装在 `~/.local/bin/helm`。
