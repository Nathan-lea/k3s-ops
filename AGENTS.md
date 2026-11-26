# k3s-ops 项目备忘录

## 项目概述

k3s 全生命周期管理项目，基于 Vagrant + Ansible + VirtualBox 实现本地 k3s 集群的自动化部署、运维。

## 技术栈

- **VM 编排**: Vagrant (bento/ubuntu-22.04 box)
- **配置管理**: Ansible >= 2.15
- **K8s 发行版**: k3s（嵌入式 etcd, 多 server HA）
- **Ingress**: nginx-ingress（替代默认 Traefik）
- **管理 UI**: Rancher（部署在 k3s 集群上, NodePort 30443）
- **Gateway API**: NGINX Gateway Fabric（教程第 37 章部署, NodePort 30025）
- **策略引擎**: Kyverno（教程第 43 章部署, 命名空间 `kyverno`, 4 控制器钉在 agent-1）
- **虚拟化**: VirtualBox >= 7.0

## 项目结构

```text
k3s-ops/
├── vagrant/                 # VM 编排（Vagrantfile, nodes.yml）
├── ansible/                 # 配置管理（ansible.cfg, playbooks/, roles/, group_vars/, files/）
├── addons/                  # Helm values（rancher/, nginx-ingress/, monitoring/）
├── scripts/                 # 辅助脚本（bootstrap, get-kubeconfig, privacy-check, gen-inventory 等）
├── lib/                     # 共享 shell 库（logging.sh, nodes.sh）
├── win/                     # Windows ops VM 路径（up/down/destroy.ps1, nodes.windows.yml, provision-ops.sh）
├── docs/                    # 架构/设计/教程/运维文档（architecture.md, k8s-tutorial/, macos/windows 设计等）
├── tests/                   # 测试脚本（run-all.sh, test-*.sh, stubs/）
├── examples/                # 示例（如 webapp-operator）
├── production/              # 独立生产环境目录（物理隔离，不受主流程改动影响）
├── .githooks/               # Git hooks（pre-commit, pre-push）
├── k3s-ops.sh               # 统一 CLI 入口
├── Vagrantfile              # 根 Vagrantfile（委派到 vagrant/）
└── README.md
```

> `logs/`、`kubeconfig`、`*.tgz`、`tmp/` 等为运行/本地产物，不作为稳定结构；新增/删除顶层目录或关键工作流目录时，同步更新本节与 `docs/architecture.md` 项目结构。

## 关键设计决策

- **首个 server** 带 `cluster-init: true`，后续 server 通过 etcd join
- **server 不设污点**（taint_server: false），小集群可运行业务负载
- **节点扩容**：修改 nodes.yml → `k3s-ops.sh up` → `k3s-ops.sh add-node <name>`
- **节点缩容**：`k3s-ops.sh remove-node -n <name>` → `vagrant destroy <name>`
- **升级策略**：逐节点替换二进制 + 重启 service（Ansible 方式）
- **vagrant/nodes.yml** 是唯一需要手动编辑的配置文件

## 平台兼容约定

- **标准路径（Linux / macOS）**：Vagrant + Ansible 在宿主机执行，拓扑来自 `vagrant/nodes.yml`。k3s 二进制下载 URL 由 `ansible/group_vars/all.yml` 按 VM `ansible_architecture` 生成（`amd64 -> k3s`，`arm64 -> k3s-arm64`）；Vagrantfile 不传硬编码 `k3s_download_url`/`containerd_mirrors` extra_vars。
- **macOS / Apple Silicon**：`box_architecture` 默认 `auto`；主流程脚本避免 GNU-only `sed -i`、bash4 `mapfile`；Apple Silicon 为 best-effort，容器镜像需 `linux/arm64`/multi-arch。细节见 `docs/macos-teaching-env-design-a.md`。
- **Windows ops VM 路径**：宿主机只跑 Vagrant 生命周期（`win/up.ps1`/`down.ps1`/`destroy.ps1`），Ansible/kubectl/helm/`k3s-ops.sh` 在 `k3s-demo-ops` VM 内运行；拓扑来自 `win/nodes.windows.yml`。改拓扑/端口/角色/流程时，同步检查 `vagrant/nodes.yml`、`win/nodes.windows.yml`、`win/up.ps1`、`win/README.md`、`docs/architecture.md`。细节见 `win/README.md`。
- **公共约定**：`ansible/playbooks/group_vars` 是指向 `../group_vars` 的 symlink，保证 Vagrant provisioner 加载 group_vars；不要删除。

## CLI 入口

```bash
k3s-ops.sh init|up|down|install|add-node|remove-node|upgrade|backup|restore|deploy-rancher|deploy-ingress|status|destroy|ssh|kubeconfig
```

`down` 用于关闭 VM 释放宿主机资源：默认优雅关机（`vagrant halt`），`-f` 强制关机，`-s` 挂起（`vagrant suspend`，恢复最快）。

**节点名规则**：所有接受节点名的命令（`up` / `down` / `ssh` / `add-node` / `remove-node` / `kubeconfig`）统一接受短名（`agent-1`）与完整主机名（`k3s-demo-agent-1`），节点不存在时报错退出。规则集中在 `lib/nodes.sh`（`resolve_host` 把结果写入全局 `RESOLVED_HOST`），新增接受节点名的命令必须复用它，不要另写前缀拼接。集群名从 `vagrant/nodes.yml` 的 `cluster_name` 读取，不得硬编码。

## 日志

- **宿主机日志**: `logs/k3s-ops.log`（所有 CLI 操作，超 10MB 自动轮转）、`logs/health-check.log`（`status` 在宿主机执行的健康检查输出）、`logs/vbox/`（VirtualBox 生成的 `*VBoxHeadless-*.log`）
- **VM 节点日志**: `/var/log/k3s-backup.log`, `/var/log/k3s-health.log`（`health-check.sh` 在 `/var/log` 不可写时自动降级到 `$TMPDIR/k3s-health.log`）
- **统一日志库**: `lib/logging.sh`（提供 log_info/warn/error/debug/cmd/mark）

## 路由提醒

- 文档路径：`docs/architecture.md`（设计文档，变更时同步更新）
- kubeconfig 路径：项目根目录下 `kubeconfig`（vagrant up + install 后自动拉取）

## 文档编写节奏（教程章节）

**默认走轻量节奏**，仅当下列"重流程条件"命中时才加重（第 42/43 章属于例外，因命中条件 1、2）。轻量节奏的含义：

- 不做 brainstorming / 设计文档 / writing-plans / 子代理独立评审那一套；直接写、小步提交（一章一个提交）。
- 采集一次到位：能一次 `apply` / 一条命令拿到的输出就一次拿到，采完即写，不反复重采。
- 提交信息用 conventional commits；**不主动 push**，推送须用户显式指示。

**命中以下任一条才升级为重流程**：

1. 需要**手写并跑通代码/构建产物**（如自研 Operator、镜像打包）；
2. 引入**有副作用、可能"拦死集群"的新准入/控制面组件**（如 Kyverno/webhook），需逃逸演练；
3. 涉及**破坏性 / 集群级 / 不可逆操作**；
4. 输出**强非确定且必须多处一致**（需专门设计采集脚本）；
5. 用户**显式要求**独立评审。

**通用省时做法**：证据落盘到仓库内可追溯路径（不用 `/tmp`，避免重启丢失）；非确定性输出统一写"一次真实样例 + 明确标注'会变'"。

## 隐私检查钩子（同步前必检）

项目在同步到 GitHub 等远程仓库前，**必须通过本地隐私检查**，防止 `kubeconfig`、私钥、绝对路径等敏感信息泄漏。

- **钩子入口**: `.githooks/pre-commit`（提交前）和 `.githooks/pre-push`（推送前），检查逻辑在 `scripts/privacy-check.sh`
- **启用方式**: `git config core.hooksPath .githooks`（需在仓库内执行一次，`core.hooksPath` 为本地配置，不入库）
- **触发时机**: `git commit` 前扫描当前跟踪文件；`git push` 前扫描当前跟踪文件 + 本次 push 范围的提交历史（防止“tip 干净、历史脏”）。发现隐私风险（绝对路径/私钥/密钥/token/明文密码/白名单外私有 IP 等）即阻止操作
- **手动运行**: `bash scripts/privacy-check.sh`（当前文件）；`printf '<local> <local_sha> <remote> <remote_sha>\n' | bash scripts/privacy-check.sh --push-range`（历史范围）
- **维护**: 项目设计内的值（如拓扑 IP、演示用 `admin` 密码）已加入 `ALLOW_*` 白名单，新增用例时同步维护该脚本

## 部署记录

### 端口分配

| 组件 | 协议 | NodePort | 说明 |
|------|------|----------|------|
| nginx-ingress | HTTP | 30080 | 外部流量入口 |
| nginx-ingress | HTTPS | 30444 | 外部流量入口（TLS） |
| NGINX Gateway Fabric | HTTP | 30025 | Gateway API 入口（教程第 37 章部署） |
| Rancher | HTTPS | 30443 | Rancher UI 管理端 |

### 当前集群拓扑

- 1 个 server 节点: k3s-demo-server-1 (192.168.56.10, 2c/4GB)
- 1 个 agent 节点: k3s-demo-agent-1 (192.168.56.20, 2c/4GB)
- 数据存储: 嵌入式 etcd（单节点模式）
- server-2 (192.168.56.11) 已被移除
- 已部署组件: k3s, nginx-ingress, cert-manager, Rancher, Gateway API CRD (v1.4.1), NGINX Gateway Fabric (2.4.2), Kyverno (chart 3.9.1 / app v1.19.1)

### Kyverno（策略引擎, 教程第 43 章）

- **安装**：`helm install kyverno kyverno/kyverno -n kyverno --create-namespace --set global.nodeSelector."kubernetes\.io/hostname"=k3s-demo-agent-1 --wait --timeout 10m`
- **组件**：4 个控制器（admission / background / cleanup / reports），各 1 副本，全部钉在 `k3s-demo-agent-1`；新增 22 个 CRD（`kyverno.io`/`policies.kyverno.io`/`reports.kyverno.io`/`wgpolicyk8s.io`）；webhook 7 validating + 3 mutating。
- ⚠️ **单点风险**：webhook `failurePolicy=Fail`，控制器又全在唯一 agent 上；agent-1 不可用时，相关命名空间的**写入会被拦**（不是放行）。
- **逃生（两步，顺序不可反）**：① `kubectl -n kyverno scale deploy --all --replicas=0`；② `kubectl delete validatingwebhookconfiguration,mutatingwebhookconfiguration -l webhook.kyverno.io/managed-by=kyverno`。恢复：`kubectl -n kyverno scale deploy --all --replicas=1`（控制器会自愈重建 webhook）。
- **演示资源**：命名空间 `policy-demo` / `policy-demo-gen`，5 条 `ClusterPolicy`（详见第 43 章附录）。

### Service 暴露与 ServiceLB（教程第 44 章）

- **决策**：k3s 内置 LB（ServiceLB / Klipper）保持**关闭**（`disable_servicelb: true`），对外统一走 **NodePort + nginx-ingress**，避免 `svclb` 与 `30080/30444` 抢端口。
- **选型**：公司测试（KVM，对齐生产）与生产（混合云）→ 关闭 ServiceLB，用 **MetalLB**（本地/KVM）或**云厂商 LB**（公有云）；三者**不可并存**。
- **坑 1**：`config.yaml.j2` 的 `disable:` 列表已支持条件渲染（**已修复**），改 `vagrant/nodes.yml` 的开关即可生效，无需手动改模板。
- **坑 2（已修复 CLI 边界）**：`ansible/inventory.yml` 仍是 tracked 占位清单，但 `k3s-ops.sh` / `scripts/update-nodes.sh` 现在会从 `vagrant/nodes.yml` 生成运行时 `ansible/inventory.generated.yml`（gitignored），并显式设置 `ANSIBLE_CONFIG`。Linux/macOS 宿主机默认用 `.vagrant/machines/<host>/virtualbox/private_key`；Windows ops VM/预分发 key 场景用 `~/.ssh/k3s-ops/<host>`。首次建机仍建议 `k3s-ops.sh up`（Vagrant provisioner）；CLI 的 `install/add-node/remove-node/...` 用于对已存在 VM/节点执行 Ansible 操作。

### 关键操作说明

1. **镜像拉取限制**: 部署环境无法直接访问 Docker Hub/GCR/GitHub raw。使用 docker.1panel.live 作为 Docker Hub 镜像（1panel 只代理 docker.io）；registry.k8s.io 用 k8s.m.daocloud.io、quay.io 用 quay.m.daocloud.io（2026-10-20 实测）。
2. **Rancher 部署**: 如果 Helm 部署时镜像拉取超时，需在宿主机 Docker 先 pull 镜像，然后 save → scp → k3s ctr images import 导入到 VM 的 containerd。
3. **路径**: Vagrant Ansible 依赖需通过 `ENV['ANSIBLE_ROLES_PATH']` 设置角色路径，使用 `--config` 而非 `--ansible-cli` 参数。helm 安装在 `~/.local/bin/helm`。
