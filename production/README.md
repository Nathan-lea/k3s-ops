# production/ —— 一条命令把 N 台裸机变成可用的 k3s 集群

> 设计文档：[design.md](design.md)
> 本文是操作手册，只讲"怎么用、改哪里"。

---

## 这是什么

给公司测试环境和生产环境用的**轻量 K8s 部署工具**，基于 k3s。和根目录下的 `k3s-ops.sh`（Vagrant + Ansible 演示环境）**并存、互不干扰**：

| 场景 | 用哪个 |
|---|---|
| 本机虚拟机演示 | `k3s-ops.sh`（Vagrant + VirtualBox） |
| 公司测试 / 生产环境（已有裸机） | `production/bootstrap.sh` |

生产/测试环境的特点：**没有 VIP、没有负载均衡、Nginx-Ingress 用 `hostNetwork` 直接占 80/443**，所以任何节点 IP 都能直接访问服务。

**自包含**：`production/` 可整体拷贝独立运行——roles（`ansible/roles/`）、日志库（`lib/logging.sh`）、addons 模板（`addons/`）都在本目录内，不依赖 k3s-ops 仓库的其他部分。

---

## 快速开始

### 前置条件

在**控制机**（你的笔记本/跳板机）上：

```bash
# Ubuntu/Debian
sudo apt install -y ansible python3 python3-yaml ssh sshpass rsync curl

# 或 macOS
brew install ansible
```

Ansible 需要 **>= 2.15**，Python >= 3.8。

在**目标节点**上：

- 已装好 Ubuntu 22.04 / Debian 11+（其他发行版未测试）
- 已配好静态 IP，能从控制机 SSH 上去
- 默认用 `root` + 密码登录（也可以改 `INIT_SSH_USER`）
- 资源建议：server 2C/4G，agent 2C/4G 起步

### 三步上手

```bash
# 1. 编辑拓扑（IP / 主机名 / 角色）
vim production/config/ipam.yml

# 2. 编辑集群参数（版本、存储、Ingress、Rancher 等）
vim production/config/cluster.env
cp production/config/cluster.env.local.example production/config/cluster.env.local
vim production/config/cluster.env.local   # 真正的密码放这里，不入库

# 3. 一键部署
./production/bootstrap.sh
```

跑完后：

```bash
export KUBECONFIG=$(pwd)/production/kubeconfig
kubectl get nodes
```

### 常用变体

```bash
# 只跑某个阶段（比如只跑预检，不改任何东西）
./production/bootstrap.sh --steps 05

# 只到 k3s 集群可用，不装 ingress / Rancher
./production/bootstrap.sh --skip-addons

# 只打印将要执行的命令，不真正跑
./production/bootstrap.sh --dry-run

# 环境变量覆盖配置文件里的值
SSH_PORT=2222 INIT_SSH_USER=root INIT_SSH_PASSWORD=xxx ./production/bootstrap.sh
```

---

## 流水线（阶段与文件对应关系）

`bootstrap.sh` 按顺序执行下面这些阶段，**每个阶段都幂等**，可以反复跑：

| 阶段 | 文件 | 做什么 |
|---|---|---|
| 05 | `ansible/playbooks/05-preflight.yml` | **只读预检**：OS / 内存 / 磁盘 / 80/443 是否空闲 / 离线 chart 是否齐全 |
| ssh | `scripts/ssh-setup.sh` | **root → ops**：建 ops 账号、分发密钥、验证 ops + 密钥能连、收紧 root 登录 |
| 10 | `ansible/playbooks/10-os-init.yml` | **系统初始化**：复用 `k3s-common` 角色，补时区/chrony/limits/本地盘目录/ufw 生产规则 |
| 20 | `ansible/playbooks/20-k3s-cluster.yml` | **装 k3s**：第一个 `role: server` 走 etcd init，其余 server 走 etcd join，agent 走 token 加入 |
| 30 | `ansible/playbooks/30-addons.yml` | **附加组件**：localdisk / ingress-nginx / cert-manager / NFS provisioner / Rancher / 节点标签 |
| kubeconfig | `scripts/kubeconfig.sh` | 从首个 server 拉 kubeconfig，`server:` 字段改成真实 IP，写到 `production/kubeconfig` |
| verify | `scripts/verify.sh` | **自检**：节点 Ready？组件就绪？StorageClass 有？80/443 在听？打印访问入口 |

另外有一个不依赖机器、随时可跑的**逻辑自测**：

```bash
./production/scripts/selftest.sh          # 全跑（ipam + config 正反例，共 45 条）
./production/scripts/selftest.sh ipam     # 只跑 IPAM 校验
./production/scripts/selftest.sh config   # 只跑 cluster.env 校验
```

改了 `lib/ipam.sh` 或 `lib/config.sh` 之后跑一遍，就知道有没有把某条校验改坏。它只在临时目录里改配置副本，不碰真实配置、不碰任何节点。

扩缩容（`scale.sh`）额外用到：

| 命令 | 文件 | 做什么 |
|---|---|---|
| `apply` | `ssh-setup.sh` + `05` + `10` + `20` + `30` | 扩容：新节点走一遍同一条流水线（已存在节点上都是幂等的），最后全量重跑 addons 以套用新增的节点 label |
| `remove` | `ansible/playbooks/50-scale-remove.yml` | 缩容：drain → delete node → 停服务 → 清数据 → 清 etcd member |
| `upgrade` | `ansible/playbooks/60-upgrade.yml` | 升级 k3s 二进制，逐节点重启 |
| `backup` | `ansible/playbooks/70-backup.yml` | 在第一个 server 上做 etcd snapshot |

---

## 两个核心配置文件

### `production/config/ipam.yml` —— 节点拓扑

```yaml
subnet: 192.168.100.0/24
gateway: 192.168.100.1
domain: k8s.example.com

nodes:
  - hostname: xxx-k8s-01      # 第一条 role: server = 集群 init 节点
    ip: 192.168.100.11
    role: server
  - hostname: xxx-k8s-02
    ip: 192.168.100.12
    role: server
  - hostname: xxx-k8s-03
    ip: 192.168.100.13
    role: agent
```

**三条硬规则**：

1. **第一条 `role: server`** 就是集群 init 节点（etcd 第一个成员），不要随意调换顺序
2. 至少 1 条 `role: server`
3. `hostname` 与 `ip` 全局唯一

### `production/config/cluster.env` —— 集群参数

分 8 个区，注释写了每项的含义和取值范围：

1. 集群标识（`CLUSTER_NAME` / `CLUSTER_DOMAIN`）
2. k3s（`K3S_VERSION` / `K3S_INSTALL_MODE` / `CNI` / `POD_CIDR` / `SVC_CIDR` / Traefik / ServiceLB / 污点）
3. SSH / 运维账号（`SSH_PORT` / `INIT_SSH_USER` / `INIT_SSH_PORT` / `OPS_USER` / `DISABLE_ROOT_SSH_AFTER_INIT` / `ROOT_SSH_POLICY`）

   > `INIT_SSH_PORT` 是**初始化时**用 root 首次连入的端口（默认 22）；`SSH_PORT` 是之后 ops 账号用的端口。两者不同也行，hardening 会在改端口后回连确认新端口可用再收紧 root。
4. OS 初始化（`TIMEZONE` / `CHRONY_SERVERS` / `USE_UFW` / `UFW_ALLOW_CIDR`）
5. 存储（本地盘 `LOCALDISK_*` + NFS `NFS_*` + `IN_CLUSTER_NFS`）
6. Ingress（`INGRESS_KIND` / 端口 / nodeSelector）
7. 附加组件（cert-manager / Rancher）
8. 制品与镜像仓库（`CHARTS_MODE` / `ARTIFACTS_DIR` / `REGISTRY_*` / `HELM_*`）

真实密码和凭据放 `cluster.env.local`（已 gitignore）：

```bash
cp production/config/cluster.env.local.example production/config/cluster.env.local
vim production/config/cluster.env.local
chmod 600 production/config/cluster.env.local
```

---

## 访问集群

### kubectl

```bash
export KUBECONFIG=$(pwd)/production/kubeconfig
kubectl get nodes
kubectl get pods -A
```

### Nginx-Ingress

**hostNetwork**，任何节点 IP 的 80/443 都是入口：

```bash
# 例如部署一个测试应用
kubectl create deployment nginx --image=nginx
kubectl expose deployment nginx --port=80 --type=NodePort
kubectl create ingress nginx --class=nginx --rule="test.example.com/=nginx:80"

# 客户机 hosts 加一条
# 192.168.100.11 test.example.com
curl http://test.example.com/
```

### Rancher

`https://<任意节点IP>/`，Host 头需为 `RANCHER_HOSTNAME`（默认 `rancher.<CLUSTER_DOMAIN>`）：

```bash
curl -k -H "Host: rancher.k8s.example.com" https://192.168.100.11/
```

或客户机 hosts 加：

```
192.168.100.11 rancher.k8s.example.com
```

---

## 存储

### localdisk StorageClass（本地盘）

- **默认**（`LOCALDISK_DEFAULT_SC=true`）
- Provisioner：`rancher/local-path-provisioner`
- 落盘位置：`LOCALDISK_PATH`（默认 `/opt/k8s-local-path`）
- 回收策略：`Retain`（PV 不删，节点上数据文件还在）
- 命名空间：`local-path-storage`

k3s 内置的 `local-storage` 已被 `disable: [local-storage]` 关掉，避免和自管 provisioner 冲突。

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
  # 不写 storageClassName，用默认（localdisk）
```

### nfs-client StorageClass（NFS）

- **默认关闭**（`STORAGE_NFS_ENABLED=false`，一键部署开箱即跑）。要用就填真实 `NFS_SERVER` 再改回 `true`
- **不是默认 SC**（`NFS_DEFAULT_SC=false`，与 `LOCALDISK_DEFAULT_SC` 互斥）
- Provisioner：`registry.k8s.io/sig-storage/nfs-subdir-external-provisioner`
- 需要外部 NFS server（`NFS_SERVER`）或开启集群内 NFS（`IN_CLUSTER_NFS=true`，要先把镜像弄进内网）
- 命名空间：`nfs-provisioner`（集群内 NFS server 在 `nfs-system`）
- `NFS_ARCHIVE_ON_DELETE`：PVC 删除后是把目录改名归档（`archived-*`）还是真删，默认不归档

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nfs-pvc
spec:
  storageClassName: nfs-client   # 指定用 NFS
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
```

---

## 离线部署

**场景**：目标环境访问不到 Docker Hub / GitHub / Helm 仓库。

### 步骤

```bash
# 1. 在能联网的机器上准备制品
./production/scripts/fetch-artifacts.sh

# 2. 准备镜像（fetch-artifacts 不管镜像，需手动）
docker pull rancher/local-path-provisioner:v0.0.30
docker pull rancher/mirrored-library-busybox:1.36.1
docker pull registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2
# 按需 pull 其他镜像，然后
docker save -o production/artifacts/images/images.tar \
  rancher/local-path-provisioner:v0.0.30 \
  rancher/mirrored-library-busybox:1.36.1 \
  registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2

# 3. 拷贝到离线控制机
scp -r production/ user@offline-machine:~/k3s-ops/production/

# 4. 改配置
vim production/config/cluster.env
# K3S_INSTALL_MODE=offline
# CHARTS_MODE=local        # 默认就是 local，不用改

# 5. 分发制品到节点
./production/scripts/offline-load.sh

# 6. 部署
./production/bootstrap.sh
```

---

## 镜像加速 / 内网仓库

默认用一份已验证过的镜像加速列表（见 `production/config/registries.yaml.example`）。要换成内网 Artifactory：

```bash
# cluster.env 或 cluster.env.local
REGISTRY_ENDPOINT=artifactory.corp.com
REGISTRY_PATH_PREFIX=docker-remote
REGISTRY_USERNAME=user
REGISTRY_PASSWORD=token
```

---

## 常见问题

### bootstrap.sh 中途失败

**每个阶段都幂等**，直接重跑：

```bash
./production/bootstrap.sh
```

会从上次失败的阶段继续（已完成的阶段会快速跳过）。

### 想只补做某个阶段

```bash
./production/bootstrap.sh --steps 30    # 只重跑附加组件
./production/bootstrap.sh --steps 20    # 只重跑 k3s 安装
```

### 80/443 被占用

`05-preflight` 会拦住：

```
节点 xxx-k8s-01 的 80/443 已被占用：:80 :443
请先 `ss -tlnp | grep -E ':(80|443)'` 找出占用进程并停掉（nginx/apache/httpd 等）。
```

### NFS_SERVER 还是占位值

```
配置错误: NFS_SERVER 还是占位值（'nfs-server.example.com'）。请填真实 NFS 服务器，或把 STORAGE_NFS_ENABLED 改成 false
```

### root 登录被关了，想恢复

SSH 到节点（用 ops 账号 + 密钥）：

```bash
sudo rm /etc/ssh/sshd_config.d/99-k3s-ops-hardening.conf
sudo systemctl reload sshd
```

### 扩缩容

```bash
# 扩容：往 ipam.yml 加条目，然后
vim production/config/ipam.yml   # 加一个节点条目
./production/scale.sh apply

# 缩容
./production/scale.sh remove xxx-k8s-03

# 升级
./production/scale.sh upgrade --version v1.31.4+k3s1 --serial 1

# 备份 etcd
./production/scale.sh backup

# 查看状态
./production/scale.sh status
```

---

## 首次真机运行检查清单

本轮**没有真机验证**（用户确认 A1），下面这些只有你第一次在真机跑过才算数。跑完逐项打勾：

| # | 检查项 | 怎么确认 |
|---|---|---|
| 1 | bootstrap 端到端跑通 | `./production/bootstrap.sh` 全绿，中途无手工干预 |
| 2 | ops 账号生效、root 已收紧 | 换个终端 `ssh -i production/.state/ops_id_ed25519 ops@<节点IP>` 能进；`ssh root@<节点IP>` 按 `ROOT_SSH_POLICY` 被拒 |
| 3 | 端口已切到 `SSH_PORT` | `ssh -p <SSH_PORT> ops@<节点IP>` 能进（若改过端口） |
| 4 | 节点 Ready | `kubectl get nodes` 全部 `Ready`，版本是 `K3S_RESOLVED_VERSION` 解析出的那个 |
| 5 | hostNetwork ingress 真的占了 80/443 | `ss -tlnp \| grep -E ':(80\|443)'` 在**每个**节点上都有 ingress-nginx；`curl http://<任意节点IP>/` 返回 404（说明是 ingress 在应答） |
| 6 | localdisk 出 PVC | 按"存储"一节建 `test-pvc` → `Bound`；节点 `LOCALDISK_PATH` 下出现对应目录 |
| 7 | nfs-client 出 PVC（若启用了 NFS） | 建 `nfs-pvc` → `Bound`；NFS server 上出现子目录 |
| 8 | in-cluster NFS（若开启） | `nfs-system` 与 `nfs-provisioner` 两个 ns 的 pod 都 Ready |
| 9 | cert-manager 就绪 | `kubectl get pods -n cert-manager` 全 Ready，无 `CrashLoopBackOff` |
| 10 | Rancher 能登录 | `https://<任意节点IP>/`（Host 头为 `RANCHER_HOSTNAME`）出登录页，用 `RANCHER_BOOTSTRAP_PASSWORD` 能登进去 |
| 11 | 时区与时间同步 | `timedatectl` 显示 `Asia/Shanghai`；`chronyc tracking` 的偏移在毫秒级 |
| 12 | 缩容演练（可选但强烈建议） | `./production/scale.sh remove <某台>` 后 `etcdctl member list` 少一个 member，`kubectl get nodes` 少一个节点 |

任何一项不符，先看 `production/logs/production.log`，再回来对照设计文档 §18。

---

## 安全说明

- 初始化后**只有 ops 用户**可用密钥登录，root 登录已按 `ROOT_SSH_POLICY` 收紧（默认 `prohibit-password`）
- 私钥在 `production/.state/ops_id_ed25519`（gitignore），别泄露
- `config/cluster.env.local` 存真实密码，**不入库**
- `production/kubeconfig` 含集群凭据，**不入库**

---

## 文档

- 设计文档：[design.md](design.md)
- Ingress 端口设计：[../docs/ingress-80-443-exposure.md](../docs/ingress-80-443-exposure.md)
- 生产扩容方案：[../docs/k3s-production-scaling-plan.md](../docs/k3s-production-scaling-plan.md)
- 已知限制（本轮未真机验证）：设计文档 §15 验证清单里标注 `⚠️ 未真机验证` 的项目（bootstrap 端到端、hostNetwork 80/443、StorageClass、in-cluster NFS、Rancher 登录）
