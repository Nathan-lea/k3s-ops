# k3s-ops 手动部署全流程文档

> 适用环境: EndeavourOS (Arch Linux) / VirtualBox / Vagrant / Ansible
> 网络限制: Docker Hub、GCR、GitHub raw 均无法直接访问，需配置镜像
> 最后更新: 2026-06-01

---

## 目录

1. [环境准备](#1-环境准备)
2. [项目初始化](#2-项目初始化)
3. [创建虚拟机](#3-创建虚拟机)
4. [安装 k3s 集群](#4-安装-k3s-集群)
5. [部署 nginx-ingress](#5-部署-nginx-ingress)
6. [部署 cert-manager](#6-部署-cert-manager)
7. [部署 Rancher](#7-部署-rancher)
8. [添加 server 节点](#8-添加-server-节点扩容控制面)
9. [移除 server 节点](#9-移除-server-节点缩容控制面)
10. [添加 agent 节点](#10-添加-agent-节点扩容工作节点)
11. [常见问题处理](#11-常见问题处理)
12. [附录](#12-附录)

---

## 1. 环境准备

### 1.1 安装依赖软件

```bash
# 安装 VirtualBox
sudo pacman -S virtualbox virtualbox-host-modules-arch
sudo modprobe vboxdrv
sudo systemctl restart vboxservices

# 确认 VirtualBox 版本 >= 7.0
vboxmanage --version
```

```bash
# 安装 Vagrant（Arch 上通过 gem 安装，避免二进制包与 readline 冲突）
gem install vagrant

# 确认 Vagrant 版本 >= 2.3
vagrant --version
```

```bash
# 安装 Ansible >= 2.15
sudo pacman -S ansible

# 确认版本
ansible --version
```

```bash
# 安装 kubectl
sudo pacman -S kubectl

# 安装 helm（下载二进制到 ~/.local/bin）
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
# 或手动下载
wget https://get.helm.sh/helm-v3.21.0-linux-amd64.tar.gz
tar zxf helm-v3.21.0-linux-amd64.tar.gz
mv linux-amd64/helm ~/.local/bin/helm
helm version
```

```bash
# 安装 Docker（宿主机用于镜像搬运）
sudo pacman -S docker
sudo systemctl start docker
sudo systemctl enable docker
sudo usermod -aG docker $USER
# 重新登录使组生效
```

### 1.2 配置 PATH（gem 安装的 vagrant）

```bash
echo 'export PATH="$HOME/.local/share/gem/ruby/3.4.0/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
vagrant --version
```

> **注意**: `vagrant ssh` 在 Vagrant 2.4.9 + Ruby 3.4 上会报错 `undefined method 'join'`。这是已知的上游兼容问题，替代方法见 3.2 节。

### 1.3 配置 Docker Hub 镜像（受限网络环境）

如果环境无法直接访问 Docker Hub，需配置镜像加速器：

```bash
sudo mkdir -p /etc/docker
cat <<'EOF' | sudo tee /etc/docker/daemon.json
{
  "registry-mirrors": ["https://docker.1panel.live"]
}
EOF
sudo systemctl restart docker

# 验证镜像可用
docker pull nginx:alpine
```

---

## 2. 项目初始化

### 2.1 创建项目目录

```bash
mkdir -p ~/k3s-ops
cd ~/k3s-ops
```

### 2.2 创建项目目录结构

```bash
mkdir -p vagrant ansible/{playbooks,roles,group_vars,files} \
         addons/{rancher,nginx-ingress,monitoring} \
         scripts lib logs docs
```

### 2.3 配置 nodes.yml

这是 **集群拓扑定义文件**，是唯一需要手动编辑的核心配置。

```yaml
# vagrant/nodes.yml
cluster_name: k3s-demo
k3s_version: v1.30.2+k3s2

network:
  subnet: 192.168.56.0/24
  box: bento/ubuntu-22.04

nodes:
  - name: server-1
    role: server
    ip: 192.168.56.10
    cpus: 2
    memory: 4096

k3s_config:
  disable_traefik: true
  disable_servicelb: true
  taint_server: false
  cluster_cidr: 10.42.0.0/16
  service_cidr: 10.43.0.0/16
```

### 2.4 创建 Vagrantfile

`vagrant/Vagrantfile` 负责读取 `nodes.yml`，动态创建 VM。关键要点：

- 必须设置 `ENV['ANSIBLE_ROLES_PATH']`，让 Vagrant Ansible provisioner 能找到角色路径
- 使用 `ansible.config_file` 而非 `ansible.ansible_cli` 参数（新版 Vagrant 语法）
- 每个节点执行 Ansible 时需设置 `extra_vars` 传递节点 IP、角色等信息

### 2.5 配置 Ansible

#### group_vars/all.yml — 全局变量

```yaml
# ansible/group_vars/all.yml
k3s_version: "v1.30.2+k3s2"
containerd_mirrors:
  docker.io:
    endpoint:
      - "https://docker.1panel.live"
  registry.k8s.io:
    endpoint:
      - "https://docker.1panel.live"
  quay.io:
    endpoint:
      - "https://docker.1panel.live"
```

该配置会通过 `k3s-common` 角色的 `registries.yaml.j2` 模板写入到 `/etc/rancher/k3s/registries.yaml`，k3s 启动时会将其转化为 containerd 的 hosts.toml 配置。

#### ansible.cfg

```ini
[defaults]
host_key_checking = False
gathering = explicit
retry_files_enabled = False
```

### 2.6 初始化 CLI 入口

```bash
# 从零创建 k3s-ops.sh 统一入口脚本
# 支持子命令：init, up, install, add-node, remove-node, upgrade, backup, restore, deploy-rancher, deploy-ingress, status, destroy, ssh, kubeconfig
chmod +x k3s-ops.sh
```

---

## 3. 创建虚拟机

### 3.1 启动 VM

```bash
cd ~/k3s-ops
vagrant up
```

**说明**: 该命令读取 `vagrant/nodes.yml`，为每个节点创建 VirtualBox VM。
- 使用 bento/ubuntu-22.04 作为基础镜像
- 分配 192.168.56.0/24 内网 IP
- 执行 Ansible provisioner 完成初始化配置

首次启动会下载 box 镜像（约 500MB），之后复用缓存。

### 3.2 验证 VM 就绪

```bash
# 查看所有 VM 状态
vagrant status
```

SSH 到节点验证：

**方法 A — vagrant ssh（推荐，如果可用）**:
```bash
vagrant ssh k3s-demo-server-1
```

**方法 B — 直接 SSH（当 vagrant ssh 报 Ruby 兼容错误时）**:
```bash
# 查看 SSH 连接参数
vagrant ssh-config k3s-demo-server-1

# 使用查到的 IdentityFile 和 Port 连接
# server-1 默认端口 2222，server-2 默认端口 2200
ssh -p 2222 \
  -i .vagrant/machines/k3s-demo-server-1/virtualbox/private_key \
  -o StrictHostKeyChecking=no \
  vagrant@127.0.0.1
```

在 VM 内检查:
```bash
hostname
ip addr show
cat /etc/os-release
```

**预期输出**: VM 正常运行，IP 为 192.168.56.10，OS 为 Ubuntu 22.04。

---

## 4. 安装 k3s 集群

### 4.1 配置 containerd 镜像加速（关键步骤）

在受限网络环境中，k3s 使用的 containerd 需要配置镜像加速。这是通过 `/etc/rancher/k3s/registries.yaml` 实现的：

```yaml
# /etc/rancher/k3s/registries.yaml
mirrors:
  docker.io:
    endpoint:
      - "https://docker.1panel.live"
  registry.k8s.io:
    endpoint:
      - "https://docker.1panel.live"
  quay.io:
    endpoint:
      - "https://docker.1panel.live"
```

**说明**: k3s 启动时会读取此文件，自动为 containerd 生成 `/var/lib/rancher/k3s/agent/etc/containerd/certs.d/<registry>/hosts.toml`。本地文件优先于远程仓库。

### 4.2 安装 k3s server（首个控制面节点）

在 VM k3s-demo-server-1 上安装 k3s server：

```bash
# SSH 到 VM
vagrant ssh k3s-demo-server-1

# 下载 k3s 二进制（使用镜像加速）
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.30.2+k3s2 sh -s - server \
  --cluster-init \
  --disable traefik \
  --disable servicelb \
  --node-name k3s-demo-server-1 \
  --node-ip 192.168.56.10 \
  --advertise-address 192.168.56.10 \
  --cluster-cidr 10.42.0.0/16 \
  --service-cidr 10.43.0.0/16 \
  --disable-cloud-controller \
  --kube-controller-manager-arg bind-address=0.0.0.0 \
  --kube-proxy-arg proxy-mode=iptables \
  --tls-san 192.168.56.10
```

**参数说明**:
- `--cluster-init`: 初始化 embedded etcd 集群（首个 server 必需）
- `--disable traefik`: 禁用默认 Traefik ingress，后续部署 nginx-ingress
- `--disable servicelb`: 禁用 ServiceLB，使用 NodePort 或 nginx-ingress
- `--node-ip`: 指定节点在集群内部通信的 IP
- `--advertise-address`: 指定 API Server 对外公布的地址
- `--tls-san`: 在 TLS 证书中附加 SAN（后续通过此 IP 访问 API）

### 4.3 验证 k3s 集群就绪

```bash
# 在 VM 内使用内置 kubectl 检查
sudo k3s kubectl get nodes
sudo k3s kubectl get pods -A

# 或在宿主机使用配置好的 kubeconfig
sudo k3s kubectl config view --raw > /etc/rancher/k3s/k3s.yaml
```

**预期输出**:
```
NAME                STATUS   ROLES                       AGE   VERSION
k3s-demo-server-1   Ready    control-plane,etcd,master   1m    v1.30.2+k3s2
```

所有系统 pod（coredns, local-path-provisioner, metrics-server）均为 Running。

### 4.4 从宿主机获取 kubeconfig

```bash
# 方法一：直接复制 VM 内的 kubeconfig
vagrant ssh k3s-demo-server-1 -- "sudo cat /etc/rancher/k3s/k3s.yaml" > kubeconfig

# 方法二：通过 scp 复制
scp -P 2222 -i .vagrant/machines/k3s-demo-server-1/virtualbox/private_key \
  vagrant@127.0.0.1:/etc/rancher/k3s/k3s.yaml ./kubeconfig
```

### 4.5 修复 kubeconfig（关键步骤）

复制出来的 kubeconfig 中 `server` 地址是 `127.0.0.1`，需要改为 VM 的真实 IP：

```bash
sed -i 's/127.0.0.1/192.168.56.10/g' kubeconfig

# 验证连接
export KUBECONFIG=~/k3s-ops/kubeconfig
kubectl get nodes
```

---

## 5. 部署 nginx-ingress

### 5.1 下载 Helm chart

由于网络限制，可能无法通过 `helm repo add` 添加仓库。改用直接下载 chart 压缩包：

```bash
# 从 GitHub release 下载（如果 GitHub raw 也受限，需手动在其他环境下载后拷贝）
wget https://github.com/kubernetes/ingress-nginx/releases/download/helm-chart-4.11.0/ingress-nginx-4.11.0.tgz

# 或者从可访问的镜像站点下载
```

### 5.2 创建自定义 values

```yaml
# addons/nginx-ingress/values.yaml
controller:
  service:
    type: NodePort
    nodePorts:
      http: 30080
      https: 30444
  replicaCount: 1
  hostNetwork: false
  kind: Deployment
```

> **注意**: 如果环境无法直接拉取 `registry.k8s.io/ingress-nginx/controller` 镜像，在 values 中追加 `controller.image` 配置使用镜像加速，或采用离线导入方式（见 5.5 节）。

**端口规划说明**:
- 30080: HTTP 外部流量入口
- 30444: HTTPS 外部流量入口（注意：不使用 30443，该端口留给 Rancher）

### 5.3 部署 nginx-ingress

```bash
helm upgrade --install ingress-nginx ./ingress-nginx-4.11.0.tgz \
  --namespace ingress-nginx \
  --create-namespace \
  --values addons/nginx-ingress/values.yaml \
  --wait \
  --timeout 10m
```

**说明**: 使用 `--wait` 等待所有 pod 就绪。首次部署需要拉取 `ingress-nginx/controller` 和 `kube-webhook-certgen` 镜像，如果网络慢可能超时。

### 5.4 验证 nginx-ingress

```bash
kubectl get pods -n ingress-nginx
kubectl get svc -n ingress-nginx ingress-nginx-controller
```

**预期输出**:
```
NAME                                        READY   STATUS    RESTARTS   AGE
ingress-nginx-controller-5bfc858768-zqtms   1/1     Running   0          5m

NAME                       TYPE       CLUSTER-IP     EXTERNAL-IP   PORT(S)                      AGE
ingress-nginx-controller   NodePort   10.43.197.40   <none>        80:30080/TCP,443:30444/TCP   5m
```

### 5.5 镜像拉取失败的处理

如果 `registry.k8s.io/ingress-nginx/kube-webhook-certgen` 镜像拉取超时（可能出现 Error: `ErrImagePull: rpc error: code = DeadlineExceeded`），说明镜像加速未覆盖到 registry.k8s.io 的 sub-path：

**解决方案**: 禁用 admission webhooks（已在上述 values 中设置 `controller.admissionWebhooks.enabled: false`），或者在 k3s registries.yaml 中增加更具体的镜像配置：

```yaml
mirrors:
  "registry.k8s.io/ingress-nginx":
    endpoint:
      - "https://docker.1panel.live"
```
但注意：镜像地址映射通常只对顶层 registry 有效，sub-path 的映射可能不生效。最可靠的方式是使用已下载好的镜像 `docker save` + 导入。

### 5.6 启用 TCP/UDP 服务透传

nginx-ingress 默认只代理 HTTP/HTTPS（七层）。若要透传 MySQL、PostgreSQL、MQTT 等 TCP/UDP 四层协议，需启用 `--tcp-services-configmap` 和 `--udp-services-configmap` 参数并创建空的 ConfigMap。

#### 5.6.1 创建 ConfigMap

```bash
# 创建空的 tcp 和 udp services ConfigMap
kubectl create configmap -n ingress-nginx ingress-nginx-tcp
kubectl create configmap -n ingress-nginx ingress-nginx-udp
```

> **注意**: Helm chart 的 `tcp: {}` / `udp: {}` 在 YAML values 文件中无法正确生成 ConfigMap（Go 模板将空 map 视为 nil）。必须使用 `kubectl create configmap` 手工创建，或通过 `--set-json 'tcp={}'` CLI 参数传递。

#### 5.6.2 添加启动参数到 Deployment

```bash
kubectl patch deployment -n ingress-nginx ingress-nginx-controller --type='json' -p='[
  {"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--tcp-services-configmap=$(POD_NAMESPACE)/ingress-nginx-tcp"},
  {"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--udp-services-configmap=$(POD_NAMESPACE)/ingress-nginx-udp"}
]'
```

这会滚动更新 controller pod（添加参数后旧 pod 终止，新 pod 启动）。

#### 5.6.3 添加具体 TCP/UDP 服务

后续只需在 ConfigMap 中填入条目即可：

```bash
# 示例：透传 default 命名空间的 mysql 服务的 3306 端口
kubectl patch configmap -n ingress-nginx ingress-nginx-tcp --type='json' -p='[
  {"op": "add", "path": "/data/3306", "value": "default/mysql-service:3306"}
]'
```

同时需在 nginx-ingress Service 和 Deployment 中添加对应的端口映射（每个 TCP/UDP 端口需显式声明）。

---



## 6. 部署 cert-manager

### 6.1 添加 Helm 仓库

如果 `helm repo` 操作因网络不可用，改用直接下载 chart：

```bash
# 方法一：helm repo（如果可用）
helm repo add jetstack https://charts.jetstack.io
helm repo update

# 方法二：下载 chart
wget https://github.com/cert-manager/cert-manager/releases/download/v1.20.2/cert-manager-v1.20.2.tgz
```

### 6.2 安装 cert-manager

cert-manager 是 Rancher 的依赖组件（用于自动签发 TLS 证书）：

```bash
helm upgrade --install cert-manager ./cert-manager-v1.20.2.tgz \
  --namespace cert-manager \
  --create-namespace \
  --set installCRDs=true \
  --set image.repository=docker.1panel.live/cert-manager \
  --wait \
  --timeout 10m
```

**参数说明**:
- `--set installCRDs=true`: 安装 CRD 资源（Issuer, Certificate, 等）
- `--set image.repository`: 使用镜像加速地址

### 6.3 验证 cert-manager

```bash
kubectl get pods -n cert-manager
```

**预期输出**:
```
NAME                                       READY   STATUS    RESTARTS   AGE
cert-manager-5fc8564cb8-jk9xv              1/1     Running   0          2m
cert-manager-cainjector-69c5ccb4c7-qzbdz   1/1     Running   0          2m
cert-manager-webhook-7f8cc9d46b-94w2h      1/1     Running   0          2m
```

---

## 7. 部署 Rancher

### 7.1 添加 Helm 仓库

```bash
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable
helm repo update
```

### 7.2 创建 cattle-system 命名空间

```bash
kubectl create namespace cattle-system
```

### 7.3 部署 Rancher

```bash
helm upgrade --install rancher rancher-stable/rancher \
  --namespace cattle-system \
  --set hostname=rancher.k3s.local \
  --set bootstrapPassword=admin \
  --set replicas=1 \
  --set service.type=NodePort \
  --set service.nodePort=30443 \
  --set ingress.enabled=false \
  --wait \
  --timeout 10m
```

**参数说明**:
- `hostname`: Rancher 服务的域名（本环境不需要实际 DNS 解析）
- `bootstrapPassword`: 首次登录的 admin 密码
- `service.type=NodePort`: 不使用 Ingress，直接通过 NodePort 暴露
- `service.nodePort=30443`: 指定 HTTPS NodePort
- `ingress.enabled=false`: 禁用内置 Ingress（避免与 nginx-ingress 冲突）
- `replicas=1`: 单节点部署

### 7.4 镜像拉取超时的处理方法

Rancher 镜像（`rancher/rancher:v2.14.1`）约 1.8GB，通过镜像加速器可能导致超时。此时需要采用 **宿主机拉取 + 导入** 的离线方式：

```bash
# Step 1: 在宿主机（有 Docker）拉取镜像
docker pull rancher/rancher:v2.14.1

# Step 2: 保存为 tar 文件
docker save rancher/rancher:v2.14.1 -o /tmp/rancher.tar

# Step 3: 将 tar 文件传输到 VM
vagrant ssh k3s-demo-server-1 -- "mkdir -p /tmp/images"
scp -P 2222 \
  -i ~/k3s-ops/.vagrant/machines/k3s-demo-server-1/virtualbox/private_key \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  /tmp/rancher.tar vagrant@127.0.0.1:/tmp/images/rancher.tar

# Step 4: 导入到 k3s 的 containerd
vagrant ssh k3s-demo-server-1 -- \
  sudo /usr/local/bin/k3s ctr images import /tmp/images/rancher.tar

# Step 5: 验证导入
vagrant ssh k3s-demo-server-1 -- \
  sudo /usr/local/bin/k3s crictl images | grep rancher

# Step 6: 删除卡住的 pod 使其重新创建（将使用已导入的镜像）
kubectl delete pod -n cattle-system -l app=rancher

# Step 7: 清理临时文件
rm -f /tmp/rancher.tar
vagrant ssh k3s-demo-server-1 -- "rm -rf /tmp/images"
```

**说明**: `k3s ctr images import` 是 k3s 内置的 containerd 客户端，用于直接导入 Docker 镜像。

### 7.5 验证 Rancher

```bash
# 检查 pod 状态
kubectl get pods -n cattle-system

# 查看 service
kubectl get svc -n cattle-system rancher

# 验证 API 响应
curl -sk https://192.168.56.10:30443/ping
```

**预期输出**:
```
pong   # API 响应正常
```

### 7.6 访问 Rancher UI

| 项目 | 值 |
|------|-----|
| 访问地址 | `https://192.168.56.10:30443` |
| 用户名 | admin |
| 密码 | admin（由 `bootstrapPassword` 指定） |

首次访问会显示 HTTPS 证书警告（自签名证书），点击继续即可。

---

## 8. 添加 server 节点（扩容控制面）

### 8.1 编辑 nodes.yml

在 `vagrant/nodes.yml` 中追加新 server 节点：

```yaml
nodes:
  - name: server-1
    role: server
    ip: 192.168.56.10
    cpus: 2
    memory: 4096

  - name: server-2          # 新增节点
    role: server
    ip: 192.168.56.11
    cpus: 2
    memory: 2048
```

### 8.2 启动新 VM

```bash
cd ~/k3s-ops

# 仅启动 server-2（不会重建已存在的 VM）
vagrant up k3s-demo-server-2
```

VM 创建后会自动执行 Ansible provisioner（安装基础组件、下载 k3s 二进制等）。如果 provisioner 因网络问题失败，单独重试：

```bash
vagrant provision k3s-demo-server-2
```

### 8.3 加入集群（add-node）

```bash
k3s-ops.sh add-node server-2
```

### 8.4 已知问题：config.yaml 中 token 为空

执行 `kubectl get nodes` 看不到新节点时，说明加入失败。根因：playbook 在获取 token 之前就已生成 `config.yaml`，导致 `token` 字段为空。新版 playbook 已修复（join.yml 中在启动 k3s 前重新生成 config），但现有安装需要使用以下手动修复流程：

```bash
# Step 1: 从 server-1 获取 token
TOKEN=$(ssh -p 2222 \
  -i .vagrant/machines/k3s-demo-server-1/virtualbox/private_key \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  vagrant@127.0.0.1 \
  "sudo cat /var/lib/rancher/k3s/server/node-token" 2>&1 | tail -1)

echo "Token: $TOKEN"

# Step 2: 写入正确的 token（用 | 分隔符避免 token 中的 / 冲突）
ssh -p 2200 \
  -i .vagrant/machines/k3s-demo-server-2/virtualbox/private_key \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  vagrant@127.0.0.1 \
  "sudo sed -i 's|token: $|token: ${TOKEN}|' /etc/rancher/k3s/config.yaml"

# Step 3: 清理第一次失败残留的 etcd 数据
ssh -p 2200 \
  -i .vagrant/machines/k3s-demo-server-2/virtualbox/private_key \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  vagrant@127.0.0.1 \
  "sudo systemctl stop k3s && sudo rm -rf /var/lib/rancher/k3s/server/db && sudo rm -rf /var/lib/rancher/k3s/server/tls"

# Step 4: 重启 k3s
ssh -p 2200 \
  -i .vagrant/machines/k3s-demo-server-2/virtualbox/private_key \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  vagrant@127.0.0.1 \
  "sudo systemctl start k3s"

# Step 5: 等待注册并验证
sleep 30
export KUBECONFIG=~/k3s-ops/kubeconfig
kubectl get nodes -o wide
```

**预期输出**:
```
NAME                STATUS   ROLES                       AGE     VERSION
k3s-demo-server-1   Ready    control-plane,etcd,master   2d17h   v1.30.2+k3s2
k3s-demo-server-2   Ready    control-plane,etcd,master   40s     v1.30.2+k3s2
```

### 8.5 验证多节点

```bash
# 检查 etcd 成员
kubectl get pods -n kube-system | grep etcd-

# 验证 pod 分布在不同节点
kubectl get pods -n cattle-system -o wide

# 验证 k3s API 高可用
curl -sk https://192.168.56.11:6443/version
```

---

## 9. 移除 server 节点（缩容控制面）

### 9.1 适用场景

- 集群从多节点 HA 回退到单节点，节省资源
- 某个 server 节点硬件故障，需移除后重建
- 节点健康问题持续影响集群稳定性

> **重要**: 2 节点 etcd 集群的最小 quorum 为 2。移除一个 server 节点后，etcd 会降级为单节点模式。移除前确保已为剩余节点配置了 `cluster-init: true`（首个 server 已有此参数），否则移除后集群无法恢复。

### 9.2 前置检查

```bash
# 确认要移除的节点存在
kubectl get nodes -o wide

# 确认所有关键 pod 不在目标节点上（或可以容忍驱逐）
kubectl get pods -A -o wide | grep <target-node>

# 检查 etcd 成员列表（k3s 自动管理，仅做了解）
ssh -p 2222 \
  -i .vagrant/machines/k3s-demo-server-1/virtualbox/private_key \
  -o StrictHostKeyChecking=no \
  vagrant@127.0.0.1 \
  "sudo journalctl -u k3s --no-pager | grep 'etcd.*member' | tail -5"
```

### 9.3 移除步骤

#### Step 1: Cordon 节点（标记不可调度）

```bash
# 节点标记为 SchedulingDisabled，新 pod 不会调度到此节点
kubectl cordon k3s-demo-server-2

# 确认状态
kubectl get nodes
# 输出: k3s-demo-server-2   Ready,SchedulingDisabled
```

#### Step 2: Drain 节点（驱逐已有 Pod）

```bash
kubectl drain k3s-demo-server-2 \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --force

# 如果 drain 超时或有 pod 卡在 Terminating 状态：
# 先查看卡住的 pod
kubectl get pods -A -o wide | grep k3s-demo-server-2

# 强制删除卡住的 pod
kubectl delete pod -n <namespace> <pod-name> --force --grace-period=0
# 然后重新执行 drain
```

**说明**:
- `--ignore-daemonsets`: DaemonSet pod 会由控制器在新节点重新创建，无需驱逐
- `--delete-emptydir-data`: 允许驱逐使用 emptyDir 的 pod（数据为容器生命周期绑定，不持久）
- `--force`: 即使某 pod 不是由 ReplicationController/ReplicaSet/Job/StatefulSet 管理，也强制执行
- 驱逐后所有 pod 会被 k8s 调度器分配到其他可用节点（本例中为 server-1）

#### Step 3: 删除节点

```bash
kubectl delete node k3s-demo-server-2
```

**关键行为**: k3s 自动处理以下逻辑：
- 从 etcd 集群中移除对应的 member
- 释放节点相关的资源记录
- 剩余 server-1 的 etcd 自动降级为单节点模式运行

验证 etcd member 移除：
```bash
ssh -p 2222 \
  -i .vagrant/machines/k3s-demo-server-1/virtualbox/private_key \
  -o StrictHostKeyChecking=no \
  vagrant@127.0.0.1 \
  "sudo journalctl -u k3s --no-pager | grep 'removed member' | tail -3"
```

**预期输出**（示例）:
```
msg="removed member" removed-remote-peer-urls=["https://192.168.56.11:2380"]
```

#### Step 4: 验证集群状态

```bash
# 确认只剩一个节点
kubectl get nodes

# 确认所有系统组件正常运行
kubectl get pods -A -o wide

# 确认所有 pod 已重新调度到剩余节点
# 重点检查：rancher, rancher-webhook, ingress-nginx-controller 等关键服务
kubectl get pods -n cattle-system -o wide
kubectl get pods -n ingress-nginx -o wide

# 验证 Rancher API 正常响应
curl -sk https://192.168.56.10:30443/ping
# 预期输出: pong
```

#### Step 5: 销毁 VM

```bash
cd ~/k3s-ops
vagrant destroy k3s-demo-server-2 -f
```

`-f` 参数跳过确认提示。该命令会：
1. 强制关闭 VM
2. 删除 VM 及相关磁盘文件
3. 释放宿主机资源（内存、CPU）

#### Step 6: 更新 nodes.yml（持久化配置）

编辑 `vagrant/nodes.yml`，注释或删除已移除的节点：

```yaml
nodes:
  - name: server-1
    role: server
    ip: 192.168.56.10
    cpus: 2
    memory: 4096

  # - name: server-2          # 已移除
  #   role: server
  #   ip: 192.168.56.11
  #   cpus: 2
  #   memory: 2048
```

> 推荐注释掉而非删除，保留配置历史以便需要时参考（如 IP 地址分配、硬件规格等）。

### 9.4 常见问题

#### Drain 卡住 — pod 处于 Terminating 状态

**原因**: Pod 的 preStop hook 执行超时、PDB（PodDisruptionBudget）阻止驱逐、或挂载了特定卷。

**解决**: 强制删除卡住的 pod：
```bash
kubectl delete pod -n <namespace> <pod-name> --force --grace-period=0
```

#### 删除节点后 etcd 集群异常

**原因**: 2 节点 etcd 集群中移除一个 member 后，剩余节点需要以单节点模式运行。

**解决**: 确认 server-1 的 config.yaml 包含 `cluster-init: true`：
```bash
ssh -p 2222 \
  -i .vagrant/machines/k3s-demo-server-1/virtualbox/private_key \
  -o StrictHostKeyChecking=no \
  vagrant@127.0.0.1 \
  "sudo cat /etc/rancher/k3s/config.yaml"
```

**预期输出**：
```yaml
cluster-init: true   # 确认存在此行
```

#### 重新添加已移除的节点

如果后续需要重新加入同一节点，必须先清理 etcd 数据：
```bash
# 在重新加入的节点上执行
sudo systemctl stop k3s
sudo rm -rf /var/lib/rancher/k3s/server/db
sudo rm -rf /var/lib/rancher/k3s/server/tls
sudo systemctl start k3s
```

## 10. 添加 agent 节点（扩容工作节点）

### 10.1 适用场景

- 集群工作负载增加，需要更多计算资源
- 希望将控制面与工作负载分离，server 节点只运行系统组件
- 测试多节点 pod 调度和跨节点网络

> **说明**: agent 节点只运行工作负载（kubelet、kube-proxy、containerd、flannel），不参与 etcd 和 API Server 控制面。与 server 节点不同，agent 节点加入集群不需要 etcd 集群变更，只需提供正确的 token 和 server 地址。

### 10.2 编辑 nodes.yml

在 `vagrant/nodes.yml` 中追加 agent 节点定义：

```yaml
nodes:
  - name: server-1
    role: server
    ip: 192.168.56.10
    cpus: 2
    memory: 4096

  - name: agent-1              # 新增 agent 节点
    role: agent
    ip: 192.168.56.20
    cpus: 2
    memory: 4096
```

资源规格建议：
- **CPU**: agent 节点主要运行业务 pod，建议 2c 起步
- **内存**: 取决于预期工作负载，建议 4GB 起步
- **IP**: 需在集群 `subnet` 范围内（192.168.56.0/24）

### 10.3 创建 VM

```bash
cd ~/k3s-ops

# 启动 agent 节点 VM
vagrant up k3s-demo-agent-1
```

**预期行为**:
1. Vagrant 读取 `nodes.yml`，为 agent-1 创建 VirtualBox VM
2. 自动配置 host-only 网络（IP: 192.168.56.20）
3. 运行 Ansible provisioner，完成基础 OS 配置（禁用 swap、加载内核模块、配置 sysctl、配置 containerd 镜像加速、配置防火墙）
4. 销毁 VM 前，provisioner 会尝试下载 k3s 二进制

> **注意**: Ansible provisioner 中的 k3s 二进制下载步骤可能在受限网络下超时（`get_url` 从 GitHub releases 下载约 64MB 文件）。这是已知问题，不影响 VM 创建的基础配置步骤。

验证 VM 就绪：
```bash
vagrant status k3s-demo-agent-1
# 输出: k3s-demo-agent-1   running (virtualbox)

# SSH 验证
ssh -p 2200 \
  -i .vagrant/machines/k3s-demo-agent-1/virtualbox/private_key \
  -o StrictHostKeyChecking=no \
  vagrant@127.0.0.1 \
  "hostname && ip addr show eth1 | grep inet"
# 预期输出:
# k3s-demo-agent-1
# inet 192.168.56.20/24
```

**SSH 端口说明**: 新创建 VM 的 SSH 端口从 2200 开始依次递增。server-1 固定为 2222，agent-1 为 2200。可通过 `vagrant ssh-config` 查看所有端口映射。

### 10.4 安装 k3s agent

k3s agent 的安装包括以下步骤：获取 k3s 二进制、配置 config.yaml、注册 k3s-agent 服务、启动并加入集群。

#### Step 1: 准备 k3s 二进制

受限网络环境下，provisioner 的 `get_url` 超时导致 `/usr/local/bin/k3s` 不存在。需要手动下载并传输：

```bash
# 方式 A：在宿主机下载（推荐，宿主机可访问 GitHub）
# 确认版本与 server 一致
curl -sfL -o /tmp/k3s \
  https://github.com/k3s-io/k3s/releases/download/v1.30.2+k3s2/k3s
chmod +x /tmp/k3s

# 传输到 agent-1
scp -P 2200 \
  -i .vagrant/machines/k3s-demo-agent-1/virtualbox/private_key \
  -o StrictHostKeyChecking=no \
  /tmp/k3s vagrant@127.0.0.1:/tmp/k3s

# 在 agent-1 上安装到系统路径
ssh -p 2200 \
  -i .vagrant/machines/k3s-demo-agent-1/virtualbox/private_key \
  -o StrictHostKeyChecking=no \
  vagrant@127.0.0.1 \
  "sudo cp /tmp/k3s /usr/local/bin/k3s && sudo chmod +x /usr/local/bin/k3s && ls -lh /usr/local/bin/k3s"
# 预期输出: -rwxr-xr-x 1 root root 64M ... /usr/local/bin/k3s
```

**方式 B：从已有 server 节点复制**（如宿主机也无法访问 GitHub）：
```bash
# Step 1: 在 server-1 确认 k3s 版本
ssh -p 2222 \
  -i .vagrant/machines/k3s-demo-server-1/virtualbox/private_key \
  -o StrictHostKeyChecking=no \
  vagrant@127.0.0.1 \
  "k3s --version"

# Step 2: 从 server-1 复制到宿主机
scp -P 2222 \
  -i .vagrant/machines/k3s-demo-server-1/virtualbox/private_key \
  -o StrictHostKeyChecking=no \
  vagrant@127.0.0.1:/usr/local/bin/k3s /tmp/k3s

# Step 3: 再传输到 agent-1
scp -P 2200 \
  -i .vagrant/machines/k3s-demo-agent-1/virtualbox/private_key \
  -o StrictHostKeyChecking=no \
  /tmp/k3s vagrant@127.0.0.1:/tmp/k3s

# Step 4: 安装到 agent-1
ssh -p 2200 \
  -i .vagrant/machines/k3s-demo-agent-1/virtualbox/private_key \
  -o StrictHostKeyChecking=no \
  vagrant@127.0.0.1 \
  "sudo cp /tmp/k3s /usr/local/bin/k3s && sudo chmod +x /usr/local/bin/k3s"
```

#### Step 2: 获取 server token

agent 节点加入集群需要 token 认证。从已存在的 server 节点获取：

```bash
TOKEN=$(ssh -p 2222 \
  -i .vagrant/machines/k3s-demo-server-1/virtualbox/private_key \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  vagrant@127.0.0.1 \
  "sudo cat /var/lib/rancher/k3s/server/node-token" 2>&1 | tail -1)

echo "Token: $TOKEN"
# 输出示例: K1049271e46...::server:e09546b2...
```

> **注意**: token 中可能包含 `::` 分隔符，后续写入配置文件时需保持完整。

#### Step 3: 创建 k3s agent 配置

在 agent-1 上创建 k3s 配置目录并写入配置文件：

```bash
# 创建配置目录
ssh -p 2200 \
  -i .vagrant/machines/k3s-demo-agent-1/virtualbox/private_key \
  -o StrictHostKeyChecking=no \
  vagrant@127.0.0.1 \
  "sudo mkdir -p /etc/rancher/k3s"

# 写入 config.yaml（用 HERE 文档避免 token 特殊字符问题）
ssh -p 2200 \
  -i .vagrant/machines/k3s-demo-agent-1/virtualbox/private_key \
  -o StrictHostKeyChecking=no \
  vagrant@127.0.0.1 \
  "cat <<'EOF' | sudo tee /etc/rancher/k3s/config.yaml
server: https://192.168.56.10:6443
token: ${TOKEN}
node-name: k3s-demo-agent-1
node-ip: 192.168.56.20
flannel-iface: eth1
EOF"
```

**配置参数说明**:
| 参数 | 值 | 说明 |
|------|-----|------|
| `server` | `https://192.168.56.10:6443` | server-1 的 API Server 地址 |
| `token` | 从 server-1 获取的值 | 集群认证令牌 |
| `node-name` | `k3s-demo-agent-1` | 节点在集群中显示的名称 |
| `node-ip` | `192.168.56.20` | 节点在集群内部通信的 IP（host-only 接口） |
| `flannel-iface` | `eth1` | flannel VXLAN 使用的网络接口（必须使用 host-only 网卡） |

#### Step 4: 配置 containerd 镜像加速

创建 `/etc/rancher/k3s/registries.yaml`，确保 agent 节点能通过镜像加速器拉取容器镜像：

```bash
ssh -p 2200 \
  -i .vagrant/machines/k3s-demo-agent-1/virtualbox/private_key \
  -o StrictHostKeyChecking=no \
  vagrant@127.0.0.1 \
  "cat <<'EOF' | sudo tee /etc/rancher/k3s/registries.yaml
mirrors:
  docker.io:
    endpoint:
      - \"https://docker.1panel.live\"
      - \"https://docker-0.unsee.tech\"
  quay.io:
    endpoint:
      - \"https://quay.mirrors.ustc.edu.cn\"
EOF"
```

#### Step 5: 创建 k3s-agent systemd 服务

k3s agent 需要作为 systemd 服务运行，确保开机自启和崩溃自动恢复。手动创建服务单元文件：

```bash
ssh -p 2200 \
  -i .vagrant/machines/k3s-demo-agent-1/virtualbox/private_key \
  -o StrictHostKeyChecking=no \
  vagrant@127.0.0.1 \
  "cat <<'EOF' | sudo tee /etc/systemd/system/k3s-agent.service
[Unit]
Description=k3s Agent
Documentation=https://docs.k3s.io
Wants=network-online.target
After=network-online.target

[Service]
Type=notify
ExecStartPre=-/sbin/modprobe br_netfilter
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/k3s agent --config /etc/rancher/k3s/config.yaml
KillMode=process
Delegate=yes
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
TimeoutStartSec=0
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF"
```

**服务配置说明**:
- `Type=notify`: k3s agent 启动后会通过 systemd 通知机制报告就绪状态
- `Delegate=yes`: 允许 k3s agent 管理 cgroup 子层级（容器资源隔离必需）
- `LimitNOFILE=infinity`: 取消文件描述符限制（kubernetes 组件需要大量文件句柄）
- `Restart=always`: 崩溃后自动重启，重启间隔 5 秒

#### Step 6: 启动 k3s-agent 服务

```bash
ssh -p 2200 \
  -i .vagrant/machines/k3s-demo-agent-1/virtualbox/private_key \
  -o StrictHostKeyChecking=no \
  vagrant@127.0.0.1 \
  "sudo systemctl daemon-reload && sudo systemctl enable k3s-agent && sudo systemctl start k3s-agent"
```

**预期行为**:
1. k3s 二进制启动 agent 模式，读取 `/etc/rancher/k3s/config.yaml`
2. 连接到 server-1 的 API Server（`https://192.168.56.10:6443`）
3. containerd 初始化，读取 `registries.yaml` 中的镜像加速配置
4. kubelet 启动并以指定 node-name 向集群注册
5. flannel 启动，使用 eth1（host-only）建立 VXLAN 隧道
6. kube-proxy 启动，配置 iptables 规则

启动过程可通过 journald 观察：
```bash
ssh -p 2200 \
  -i .vagrant/machines/k3s-demo-agent-1/virtualbox/private_key \
  -o StrictHostKeyChecking=no \
  vagrant@127.0.0.1 \
  "sudo journalctl -u k3s-agent --no-pager --follow"
```

**关键日志行**（表示成功加入集群）:
```
Successfully registered node node="k3s-demo-agent-1"
Starting flannel with backend vxlan
The interface eth1 with ipv4 address 192.168.56.20 will be used by flannel
Running kubelet ... --hostname-override=k3s-demo-agent-1 ...
Running kube-proxy ...
```

### 10.5 验证 agent 节点

确认 agent 节点已成功加入集群：

```bash
# 从宿主机查看节点状态
export KUBECONFIG=~/k3s-ops/kubeconfig
kubectl get nodes -o wide
```

**预期输出**:
```
NAME                STATUS   ROLES                       AGE     VERSION        INTERNAL-IP     OS-IMAGE
k3s-demo-server-1   Ready    control-plane,etcd,master   6d23h   v1.30.2+k3s2   192.168.56.10   Ubuntu 22.04
k3s-demo-agent-1    Ready    <none>                      1m      v1.30.2+k3s2   192.168.56.20   Ubuntu 22.04
```

**验证要点**:
| 检查项 | 命令 | 预期结果 |
|--------|------|----------|
| 节点状态 | `kubectl get nodes` | agent-1 为 `Ready`，ROLES 列为 `<none>`（无控制面角色） |
| 系统组件 | `kubectl get pods -A -o wide` | 所有 pod 正常运行，可分布在不同节点 |
| VXLAN FDB | `bridge fdb show dev flannel.1` | 每条 FDB 指向另一节点的 host-only IP |
| 跨节点网络 | 调度一个 pod 到 agent-1，验证其可访问 server-1 的 pod | 正常通信 |

验证 VXLAN 跨节点网络：
```bash
# 在 server-1 查看 flannel FDB
ssh -p 2222 \
  -i .vagrant/machines/k3s-demo-server-1/virtualbox/private_key \
  -o StrictHostKeyChecking=no \
  vagrant@127.0.0.1 \
  "bridge fdb show dev flannel.1"
# 预期输出: <agent-mac> dst 192.168.56.20 self permanent

# 在 agent-1 查看 flannel FDB
ssh -p 2200 \
  -i .vagrant/machines/k3s-demo-agent-1/virtualbox/private_key \
  -o StrictHostKeyChecking=no \
  vagrant@127.0.0.1 \
  "bridge fdb show dev flannel.1"
# 预期输出: <server-mac> dst 192.168.56.10 self permanent
```

### 10.6 常见问题

#### 加入集群后节点未显示在 kubectl get nodes 中

**原因**: token 错误、网络不通、或 k3s agent 服务未正常启动。

**排查步骤**:
```bash
# 1. 检查 agent 服务状态
ssh -p 2200 \
  -i .vagrant/machines/k3s-demo-agent-1/virtualbox/private_key \
  -o StrictHostKeyChecking=no \
  vagrant@127.0.0.1 \
  "sudo systemctl status k3s-agent --no-pager"

# 2. 查看 k3s-agent 日志
ssh -p 2200 \
  -i .vagrant/machines/k3s-demo-agent-1/virtualbox/private_key \
  -o StrictHostKeyChecking=no \
  vagrant@127.0.0.1 \
  "sudo journalctl -u k3s-agent --no-pager | grep -i error | tail -20"

# 3. 检查能否连通 server API
ssh -p 2200 \
  -i .vagrant/machines/k3s-demo-agent-1/virtualbox/private_key \
  -o StrictHostKeyChecking=no \
  vagrant@127.0.0.1 \
  "curl -sk https://192.168.56.10:6443/version"

# 4. 确认 token 正确
ssh -p 2200 \
  -i .vagrant/machines/k3s-demo-agent-1/virtualbox/private_key \
  -o StrictHostKeyChecking=no \
  vagrant@127.0.0.1 \
  "sudo cat /etc/rancher/k3s/config.yaml"
```

#### node-token 不匹配

**原因**: server 节点重启后 token 可能变化（如果数据目录被清理）。

**解决**: 重新从 server-1 获取 token 并更新 agent 配置：
```bash
TOKEN=$(ssh -p 2222 \
  -i .vagrant/machines/k3s-demo-server-1/virtualbox/private_key \
  -o StrictHostKeyChecking=no \
  vagrant@127.0.0.1 \
  "sudo cat /var/lib/rancher/k3s/server/node-token" 2>&1 | tail -1)

ssh -p 2200 \
  -i .vagrant/machines/k3s-demo-agent-1/virtualbox/private_key \
  -o StrictHostKeyChecking=no \
  vagrant@127.0.0.1 \
  "sudo sed -i 's|token:.*|token: ${TOKEN}|' /etc/rancher/k3s/config.yaml && sudo systemctl restart k3s-agent"
```

#### flannel VXLAN 接口使用 eth0（NAT）而非 eth1（host-only）

**问题**: flannel 可能使用 NAT 网卡 eth0（IP: 10.0.2.15），导致不同节点 VM 的 VXLAN 都认为自己在同一 IP 上，FDB 指向自己而非对端，跨节点 pod 通信失效。

**原因**: k3s 默认选择第一个非 loopback 接口（eth0）作为 flannel 后端。

**解决**: 在 config.yaml 中强制指定 `flannel-iface: eth1`：
```bash
ssh -p 2200 \
  -i .vagrant/machines/k3s-demo-agent-1/virtualbox/private_key \
  -o StrictHostKeyChecking=no \
  vagrant@127.0.0.1 \
  "echo 'flannel-iface: eth1' | sudo tee -a /etc/rancher/k3s/config.yaml && sudo systemctl restart k3s-agent"
```

验证修复：
```bash
ssh -p 2200 \
  -i .vagrant/machines/k3s-demo-agent-1/virtualbox/private_key \
  -o StrictHostKeyChecking=no \
  vagrant@127.0.0.1 \
  "ip addr show flannel.1 && echo '---FDB---' && bridge fdb show dev flannel.1"
```

**预期输出**:
```
flannel.1: ... inet 10.42.1.0/32 scope global flannel.1
---FDB---
<server-mac> dst 192.168.56.10 self permanent
```

#### Agent vs Server 端口需求差异

agent 节点需要开放的端口比 server 节点少（不需要 etcd 的 2379/2380、不需要 k3s API 6443）：

| 端口 | 协议 | 用途 | agent | server |
|------|------|------|-------|--------|
| 6443 | TCP | Kubernetes API Server | × | ✓ |
| 10250 | TCP | Kubelet metrics/API | ✓ | ✓ |
| 8472 | UDP | flannel VXLAN | ✓ | ✓ |
| 2379 | TCP | etcd 客户端 | × | ✓ |
| 2380 | TCP | etcd 对等通信 | × | ✓ |

## 11. 常见问题处理

### 11.1 Vagrant Ansible provisioner 错误

**问题**: `ansible-playbook` 找不到角色路径

**解决**: 在 Vagrantfile 中设置环境变量：

```ruby
ENV['ANSIBLE_ROLES_PATH'] = File.join(File.dirname(__FILE__), 'ansible/roles')
```

同时使用 `ansible.config_file` 参数（旧版 Vagrant 的 `--ansible-cli` 已废弃）：

```ruby
config.vm.provision "ansible" do |ansible|
  ansible.config_file = "ansible/ansible.cfg"
  ansible.playbook = "ansible/playbooks/k3s-cluster.yml"
end
```

### 11.2 k3s 镜像拉取超时

**问题**: 通过镜像加速器拉取大型镜像（如 rancher/rancher）时超时

**解决**: 采用离线导入方式（见 7.4 节）。核心命令链：

```bash
docker pull <image>                          # 宿主机拉取
docker save <image> -o /tmp/<name>.tar       # 导出
scp ... <name>.tar <vm>:/tmp/                # 传输到 VM
k3s ctr images import /tmp/<name>.tar        # 导入 containerd
```

### 11.3 NodePort 端口冲突

**问题**: 多个服务分配到同一 NodePort

**解决**: Kubernetes 会在 30000-32767 范围内自动分配，也可手动指定。部署时规划好端口：

| 组件 | 端口 | 说明 |
|------|------|------|
| nginx-ingress HTTP | 30080 | 外部 HTTP 流量 |
| nginx-ingress HTTPS | 30444 | 外部 HTTPS 流量 |
| Rancher HTTPS | 30443 | Rancher 管理界面 |

如果已部署的服务占用了目标端口，需先修改已部署服务的 NodePort：

```bash
# 修改已有服务的 NodePort
kubectl patch svc <service> -n <namespace> --type='json' -p='[
  {"op": "replace", "path": "/spec/ports/1/nodePort", "value": <new-port>}
]'
```

### 11.4 containerd 镜像配置

k3s 中镜像加速的配置层级：

```
用户配置: /etc/rancher/k3s/registries.yaml
    ↓ (k3s 启动时自动处理)
containerd 配置: /var/lib/rancher/k3s/agent/etc/containerd/certs.d/<registry>/hosts.toml
```

验证镜像配置是否生效：

```bash
# 在 VM 中查看最终生成的 hosts.toml
vagrant ssh k3s-demo-server-1 -- \
  "sudo ls -la /var/lib/rancher/k3s/agent/etc/containerd/certs.d/"
  
vagrant ssh k3s-demo-server-1 -- \
  "sudo cat /var/lib/rancher/k3s/agent/etc/containerd/certs.d/docker.io/hosts.toml"
```

### 11.5 节点间镜像传输

**问题**: 滚动更新后新 pod 调度到不含缓存镜像的节点，`ImagePullBackOff`

**原因**: containerd 镜像缓存在节点本地，不会自动同步。新节点需要重新拉取或手动导入。

**解决**: 从已有节点导出镜像并导入到目标节点：

```bash
# Step 1: 在源节点导出镜像（通过 SSH）
ssh -p 2222 \
  -i .vagrant/machines/k3s-demo-server-1/virtualbox/private_key \
  -o StrictHostKeyChecking=no \
  vagrant@127.0.0.1 \
  "sudo /usr/local/bin/k3s ctr images export /tmp/image.tar <registry>/<image>:<tag>"

# Step 2: 复制到宿主机，再传到目标节点
scp -P 2222 -i ... vagrant@127.0.0.1:/tmp/image.tar /tmp/image.tar
scp -P 2200 -i ... /tmp/image.tar vagrant@127.0.0.1:/tmp/image.tar

# Step 3: 在目标节点导入
ssh -p 2200 \
  -i .vagrant/machines/k3s-demo-server-2/virtualbox/private_key \
  -o StrictHostKeyChecking=no \
  vagrant@127.0.0.1 \
  "sudo /usr/local/bin/k3s ctr images import /tmp/image.tar"

# Step 4: 删除 ImagePullBackOff 的 pod，触发重建使用本地镜像
kubectl delete pod -n <namespace> <pod-name>
```

> **提示**: 如果镜像不含 tag（仅 digest），export 时使用 `@sha256:...` 而非 `:tag`。可用 `k3s crictl images` 查看完整引用。

### 11.6 kubeconfig 连接问题

**问题**: `kubectl get nodes` 返回连接拒绝

**解决步骤**:
1. 检查 kubeconfig 中的 server 地址是否为 VM IP（非 127.0.0.1）
2. 确认 VM 的 k3s API server 正在监听 6443
3. 确认宿主机能 ping 通 VM 的 IP（192.168.56.10）

```bash
# 修复 kubeconfig
sed -i 's/127.0.0.1/192.168.56.10/g' kubeconfig

# 测试连接
curl -sk https://192.168.56.10:6443/version
```

---

## 12. 附录

### 12.1 最终集群端口规划

| 组件 | 协议 | NodePort | 访问地址 |
|------|------|----------|----------|
| k3s API | HTTPS | 6443（直连） | `https://192.168.56.10:6443` |
| nginx-ingress | HTTP | 30080 | `http://192.168.56.10:30080` |
| nginx-ingress | HTTPS | 30444 | `https://192.168.56.10:30444` |
| Rancher UI | HTTPS | 30443 | `https://192.168.56.10:30443` |

### 12.2 关键文件路径

| 文件 | 用途 |
|------|------|
| `kubeconfig` | 项目根目录下，供 kubectl 使用 |
| `.vagrant/machines/k3s-demo-server-1/virtualbox/private_key` | server-1 SSH 密钥（端口 2222） |
| `.vagrant/machines/k3s-demo-server-2/virtualbox/private_key` | server-2 SSH 密钥（端口 2200，依次递增） |
| `/etc/rancher/k3s/registries.yaml` | k3s containerd 镜像配置（VM 内） |
| `ansible/group_vars/all.yml` | Ansible 全局变量 |
| `vagrant/nodes.yml` | 集群拓扑定义 |
| `lib/logging.sh` | 共享日志库 |

### 12.3 快速参考命令

```bash
# 查看集群状态
kubectl get nodes
kubectl get pods -A

# SSH 到节点（vagrant 方式）
vagrant ssh k3s-demo-server-1

# SSH 到节点（直接方式，当 vagrant ssh 不可用时）
ssh -p 2222 \
  -i .vagrant/machines/k3s-demo-server-1/virtualbox/private_key \
  -o StrictHostKeyChecking=no \
  vagrant@127.0.0.1

# 查看所有 VM 的 SSH 端口映射
vagrant ssh-config

# 查看 k3s 日志
vagrant ssh k3s-demo-server-1 -- "sudo journalctl -u k3s --no-pager | tail -50"

# 查看 containerd 镜像
vagrant ssh k3s-demo-server-1 -- "sudo /usr/local/bin/k3s crictl images"

# 导入镜像到 containerd
vagrant ssh k3s-demo-server-1 -- "sudo /usr/local/bin/k3s ctr images import /path/to/image.tar"

# 从节点导出镜像到 tar
vagrant ssh k3s-demo-server-1 -- "sudo /usr/local/bin/k3s ctr images export /tmp/out.tar <image-ref>"

# 获取 Rancher admin 密码
kubectl get secret -n cattle-system bootstrap-secret -o jsonpath='{.data.bootstrapPassword}' | base64 -d

# 关机与重启
vagrant halt      # 优雅关机（保留全部数据）
vagrant up        # 开机（k3s 自动启动）
vagrant suspend   # 挂起
vagrant resume    # 恢复
```

### 12.4 版本兼容性

| 组件 | 验证过的版本 | 备注 |
|------|-------------|------|
| VirtualBox | 7.0+ | -- |
| Vagrant | 2.4.9 | gem install；2.4.9 + Ruby 3.4+ 有 ssh 兼容问题 |
| Ansible | 2.21+ | -- |
| k3s | v1.30.2+k3s2 | 嵌入式 etcd |
| nginx-ingress | 4.11.0 (controller v1.11.1) | Helm chart |
| cert-manager | v1.20.2 | -- |
| Rancher | v2.14.1 | 稳定版 chart |
| Docker | 29.5.1 | 宿主机用于离线导入 |
| Helm | v3.21.0 | 下载二进制到 ~/.local/bin |
| base OS | Ubuntu 22.04 (bento/ubuntu-22.04) | Vagrant box |
```
