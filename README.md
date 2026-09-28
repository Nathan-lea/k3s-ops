# k3s-ops

k3s 全生命周期管理工具，基于 **Vagrant + Ansible + VirtualBox** 实现本地 k3s 集群的自动化部署、扩容、升级、备份恢复和销毁。

## 快速开始

```bash
# 1. 检查环境
./k3s-ops.sh init

# 2. 启动虚拟机
./k3s-ops.sh up

# 3. 安装 k3s 集群
./k3s-ops.sh install

# 4. 部署 nginx-ingress（可选）
./k3s-ops.sh deploy-ingress

# 5. 部署 Rancher UI（可选）
./k3s-ops.sh deploy-rancher

# 6. 获取 kubeconfig
./k3s-ops.sh kubeconfig
```

## 集群拓扑

编辑 `vagrant/nodes.yml` 定义节点、角色和规格，默认配置为单 server 节点。

## 命令参考

| 命令 | 说明 |
|------|------|
| `init` | 检查环境依赖 |
| `up [node]` | 启动 VM |
| `down [node] [-f] [-s]` | 关闭 VM 释放资源（`-f` 强制关机 / `-s` 挂起） |
| `install` | 首次安装 k3s |
| `add-node <name>` | 添加节点 |
| `remove-node -n <name>` | 移除节点 |
| `upgrade -v <version>` | 升级 k3s |
| `backup` | etcd 快照备份 |
| `restore -f <snapshot>` | 从快照恢复 |
| `deploy-rancher` | 部署 Rancher |
| `reset-rancher-admin` | 重置 Rancher admin 密码 |
| `deploy-ingress` | 部署 nginx-ingress |
| `status` | 集群健康检查 |
| `destroy` | 销毁所有 VM |
| `ssh <name>` | SSH 到指定节点 |
| `kubeconfig [name]` | 获取 kubeconfig |

节点参数写法：所有接受节点名的命令（`up` / `down` / `ssh` / `add-node` / `remove-node` / `kubeconfig`）都接受短名（`agent-1`）和完整主机名（`k3s-demo-agent-1`），节点不存在时报错退出。直接执行 `vagrant` 命令时仍需完整主机名。

## 环境要求

- VirtualBox >= 7.0
- Vagrant >= 2.3
- Ansible >= 2.15
- 宿主机内存 >= 16GB

## 隐私检查钩子

推送到远程仓库（GitHub 等）前会自动执行隐私检查，防止 `kubeconfig`、私钥、绝对路径等敏感信息泄漏。检出后需启用一次：

```bash
git config core.hooksPath .githooks
bash scripts/privacy-check.sh   # 可选：手动运行
```

## 文档

详细架构设计见 [docs/architecture.md](docs/architecture.md)
