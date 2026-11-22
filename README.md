# k3s-ops

k3s 全生命周期管理工具，基于 **Vagrant + Ansible + VirtualBox** 实现本地 k3s 集群的自动化部署、扩容、升级、备份恢复和销毁。

## 快速开始

### Linux / macOS

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

### Windows（ops VM 路径）

```powershell
# 启动全部 VM + 引导工作机 + 安装集群（首次约 15-30 分钟）
powershell -ExecutionPolicy Bypass -File .\win\up.ps1 -Install

# 进入工作机验证/运维
vagrant ssh k3s-demo-ops
cd ~/k3s-ops && ./k3s-ops.sh status
```

> Windows 宿主机只执行 Vagrant 生命周期命令；`install/status/deploy-*` 等在 `k3s-demo-ops` 工作机内执行。详见 [`win/README.md`](win/README.md)。

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

| 平台 | 要求 | 说明 |
|------|------|------|
| Linux x86_64 | VirtualBox >= 7.0, Vagrant >= 2.4（建议）, Ansible >= 2.15, Python3, 宿主机内存 >= 16GB | 主流程完整支持 |
| macOS Intel | VirtualBox >= 7.0, Vagrant >= 2.4（建议）, Ansible >= 2.15, Python3 | 可用 Homebrew 安装：`brew install --cask virtualbox vagrant && brew install ansible` |
| macOS Apple Silicon | VirtualBox >= 7.1, Vagrant >= 2.4, Ansible >= 2.15, Python3 | 需在“系统设置 > 隐私与安全性”中允许 Oracle 扩展；教学流程为 best-effort，受 VirtualBox ARM 上游稳定性影响 |
| Windows（ops VM 路径） | Windows 宿主机安装 VirtualBox >= 7.0、Vagrant >= 2.4；Ansible/kubectl/helm 在 `k3s-demo-ops` VM 内运行 | 宿主机执行 `win/up.ps1` 等生命周期命令；详见 [`win/README.md`](win/README.md) |

> `./k3s-ops.sh init` 会输出宿主机 OS/架构并给出 Apple Silicon 提示。

### macOS / Apple Silicon 注意事项

- Vagrantfile 会按 `vagrant/nodes.yml` 的 `network.box_architecture`（默认 `auto`）选择 box 架构；Apple Silicon 宿主机会自动选择 `arm64`。
- k3s 二进制下载 URL 由 Ansible 根据 VM 的 `ansible_architecture` 自动生成（`amd64 -> k3s`，`arm64 -> k3s-arm64`），不是按宿主机架构猜。
- 若 VirtualBox ARM 遇到稳定性问题，可在 `vagrant/nodes.yml` 设置 `network.provider` 为 `vmware_desktop` 或 `parallels`（逃生口，教学主流程官方支持 virtualbox）。

### arm64 影响范围（教学章节注意事项）

| 类别 | 影响 | 说明 |
|---|---|---|
| k3s/kubectl/crictl/ctr | 自动适配 | 随 `k3s-arm64` 安装，架构匹配，无需改教学命令 |
| Helm 安装 | 基本自动适配 | Helm 安装脚本会自动检测架构 |
| 容器镜像 | **需要 multi-arch** | k3s 系统镜像、nginx-ingress、cert-manager、Rancher 等官方镜像一般支持 `linux/arm64`；需实测验证。学员自定义镜像若只构建了 amd64，在 arm64 VM 上会 `ImagePullBackOff`/`exec format error` |
| 教程里的 kubectl/YAML 操作 | 基本不受影响 | Deployment/Service/Ingress/ConfigMap 等 API 操作与架构无关 |
| 教程里的示例输出 | **会不同** | 节点标签会显示 `kubernetes.io/arch=arm64`（而不是 amd64）；命令流程不变，但输出不同 |
| 教程里显式下载 amd64 二进制的命令 | **需要改** | 如 `cilium-linux-amd64.tar.gz`、`GOARCH=amd64` 等，需要按架构换成 `arm64/aarch64` |
| 性能/资源表现 | 可能略有不同 | Apple Silicon + VirtualBox ARM 的 VM 性能、网络行为与 x86_64 VirtualBox 不完全一样，但不影响 K8s 教学概念和命令 |

## 隐私检查钩子

推送到远程仓库（GitHub 等）前会自动执行隐私检查，防止 `kubeconfig`、私钥、绝对路径等敏感信息泄漏。检出后需启用一次：

```bash
git config core.hooksPath .githooks
bash scripts/privacy-check.sh   # 可选：手动运行
```

## 文档

详细架构设计见 [docs/architecture.md](docs/architecture.md)
