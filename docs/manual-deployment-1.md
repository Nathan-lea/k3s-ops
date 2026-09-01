# k3s-ops 手动部署全流程文档

> 适用环境: EndeavourOS (Arch Linux) / VirtualBox / Vagrant / Ansible
> 网络限制: Docker Hub、GCR、GitHub raw 均无法直接访问，需配置镜像
> 最后更新: 2026-05-25

---

## 目录

1. [环境准备](#1-环境准备)
2. [项目初始化](#2-项目初始化)
3. [创建虚拟机](#3-创建虚拟机)
4. [安装 k3s 集群](#4-安装-k3s-集群)
5. [部署 nginx-ingress](#5-部署-nginx-ingress)
6. [部署 cert-manager](#6-部署-cert-manager)
7. [部署 Rancher](#7-部署-rancher)
8. [常见问题处理](#8-常见问题处理)
9. [附录](#9-附录)

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

### 1.2 配置 Docker Hub 镜像（受限网络环境）

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

# SSH 登录节点验证
vagrant ssh k3s-demo-server-1

# 在 VM 内检查网络和 OS
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
  image:
    registry: docker.1panel.live
    image: ingress-nginx/controller
    tag: v1.11.1
    digest: ""
  service:
    type: NodePort
    nodePorts:
      http: 30080
      https: 30444
  admissionWebhooks:
    enabled: false
  metrics:
    enabled: false
  config:
    use-forwarded-headers: "true"
  updateStrategy:
    type: RollingUpdate
  allowSnippetAnnotations: true
  nodeSelector:
    kubernetes.io/os: linux

defaultBackend:
  enabled: false
```

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

## 8. 常见问题处理

### 8.1 Vagrant Ansible provisioner 错误

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

### 8.2 k3s 镜像拉取超时

**问题**: 通过镜像加速器拉取大型镜像（如 rancher/rancher）时超时

**解决**: 采用离线导入方式（见 7.4 节）。核心命令链：

```bash
docker pull <image>                          # 宿主机拉取
docker save <image> -o /tmp/<name>.tar       # 导出
scp ... <name>.tar <vm>:/tmp/                # 传输到 VM
k3s ctr images import /tmp/<name>.tar        # 导入 containerd
```

### 8.3 NodePort 端口冲突

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

### 8.4 containerd 镜像配置

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

### 8.5 kubeconfig 连接问题

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

## 9. 附录

### 9.1 最终集群端口规划

| 组件 | 协议 | NodePort | 访问地址 |
|------|------|----------|----------|
| k3s API | HTTPS | 6443（直连） | `https://192.168.56.10:6443` |
| nginx-ingress | HTTP | 30080 | `http://192.168.56.10:30080` |
| nginx-ingress | HTTPS | 30444 | `https://192.168.56.10:30444` |
| Rancher UI | HTTPS | 30443 | `https://192.168.56.10:30443` |

### 9.2 关键文件路径

| 文件 | 用途 |
|------|------|
| `kubeconfig` | 项目根目录下，供 kubectl 使用 |
| `.vagrant/machines/*/virtualbox/private_key` | Vagrant SSH 私钥 |
| `/etc/rancher/k3s/registries.yaml` | k3s containerd 镜像配置（VM 内） |
| `ansible/group_vars/all.yml` | Ansible 全局变量 |
| `vagrant/nodes.yml` | 集群拓扑定义 |
| `lib/logging.sh` | 共享日志库 |

### 9.3 快速参考命令

```bash
# 查看集群状态
kubectl get nodes
kubectl get pods -A

# SSH 到节点
vagrant ssh k3s-demo-server-1

# 查看 k3s 日志
vagrant ssh k3s-demo-server-1 -- "sudo journalctl -u k3s --no-pager | tail -50"

# 查看 containerd 镜像
vagrant ssh k3s-demo-server-1 -- "sudo /usr/local/bin/k3s crictl images"

# 导入镜像到 containerd
vagrant ssh k3s-demo-server-1 -- "sudo /usr/local/bin/k3s ctr images import /path/to/image.tar"

# 获取 Rancher admin 密码
kubectl get secret -n cattle-system bootstrap-secret -o jsonpath='{.data.bootstrapPassword}' | base64 -d
```
