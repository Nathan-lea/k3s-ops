# 44 Service 暴露与 LoadBalancer（k3s ServiceLB 详解）

> 本章从"Service 到底怎么被集群外部访问"切入，重点讲清 **k3s 自带的 LoadBalancer 实现（ServiceLB）**：
> 它是什么、做了什么、**开与不开有什么区别**，以及在本环境 / 公司级测试（KVM）/ 生产（混合云）里分别该怎么选。

## 本章目标

读完本章你能：

- 说清 `ClusterIP` / `NodePort` / `LoadBalancer` 三种 Service 的对外能力差别，以及 Ingress/Gateway 在其中的位置；
- 理解 **k3s ServiceLB** 的机制（每个 LB Service 派生一个 DaemonSet、用 hostPort 绑端口、拿**节点 IP** 当 `EXTERNAL-IP`），为什么它"看起来像 LB、其实不是真 LB"；
- 解释本集群里 `LoadBalancer` 的 `EXTERNAL-IP` **永远 `<pending>`**，以及"**pending 却还能从 3 万端口访问**"的原因；
- 会做**开与不开 ServiceLB 的对比**判断；
- 能给 **本环境 / 公司级测试（KVM）/ 生产（混合云）**分别选出合适的暴露方案（NodePort / ServiceLB / MetalLB / 云厂商 LB）；
- 知道**本环境若要打开 ServiceLB 的具体操作与回滚**。

---

## 1. 先分清：Service 的三种"对外"形态

Kubernetes 里一个 Service 有 `spec.type` 三种取值，决定了"谁能访问到它"：

| type | 谁能访问 | 分配的东西 | 典型用途 |
|------|---------|-----------|---------|
| `ClusterIP`（默认） | **仅集群内部** | 一个虚拟 IP（`10.43.x.x`） | 集群内的服务发现 |
| `NodePort` | 集群外部，**经任意节点的 IP + 高位端口** | ClusterIP + 每个节点上的 `30000–32767` 端口 | 本地/自建环境对外暴露（本项目就用它） |
| `LoadBalancer` | 集群外部，**经一个"外部 IP"** | ClusterIP（+ 通常还带一个 NodePort） + **`EXTERNAL-IP`** | 云上给服务一个独享入口 IP |

关键点：**`LoadBalancer` 只是"声明需求"，实现它的是外部组件**。云上有云厂商的 LB 控制器；裸金属/本地没有云，就**必须有人来当这个控制器**，否则 `EXTERNAL-IP` 会一直 `<pending>`。

k3s 的解法，就是内置了一个叫 **ServiceLB** 的负载均衡控制器。

> **Ingress / Gateway 放哪？** 它们是**七层（HTTP）**入口，通常只占**一个** `NodePort`/`LoadBalancer`，再按域名/路径分流到多个 `ClusterIP` 服务。所以"要不要 LB"和"要不要 Ingress"是两个正交问题（见第 21、31、37 章）。

---

## 2. 什么是 ServiceLB

**ServiceLB**（旧称 **Klipper LoadBalancer**）是 **k3s 内置**的一个极简 LoadBalancer 控制器：

- **作用**：让 `type: LoadBalancer` 的 Service 在**没有云厂商**的情况下也能拿到 `EXTERNAL-IP`（用**节点 IP**）。
- **定位**：给边缘 / 单机 / 本地环境"开箱即用"的便利件，**不是**生产级负载均衡器。
- **默认状态**：k3s **默认开启**（`k3s server` 启动即带）。
- **关闭方式**：所有 server 都加 `--disable servicelb`（k3s 配置文件里写 `disable: [servicelb]`）。

> 官方文档对它的价值说得很直白：上游 Kubernetes 里 `LoadBalancer` 类型的 Service 会一直 `pending`，直到有人装上负载均衡实现；而 k3s 的 ServiceLB 让"**无需云厂商、无需额外配置**"就能用上 `LoadBalancer` Service。—— 它的全部价值就是"让它别 pending"。

---

## 3. ServiceLB 的机制（官方行为拆解）

按 [k3s 官方文档](https://docs.k3s.io/networking/networking-services)，ServiceLB 的行为是这样的：

1. **监听**所有 `spec.type: LoadBalancer` 的 Service。
2. 对**每个**这样的 Service，在 **`kube-system` 命名空间**里生成一个 **DaemonSet**（名字形如 `svclb-<service>`）。
3. 该 DaemonSet 在**每个合格节点**上跑一个 `klipper-lb` 容器（Pod 带 `svc-` 前缀），用 **`hostPort` = Service 的端口**去监听。
4. **只有该端口空闲的节点才会被部署**；如果**所有节点**的该端口都被占用，这个 LB 就**保持 Pending**。
5. 节点有 external IP 时，把**节点 external IP** 写进 `Service.status.loadBalancer.ingress`（并带 `ipMode: VIP`）；否则用节点 internal IP。
6. 流量到达后：`klipper-lb` 容器用 iptables 把进入该端口的流量转发到 Service 的 ClusterIP（也就是"用节点当入口、再落到 Service"）；节点上对 `nodePort`/ClusterIP 的常规转发仍由 `kube-proxy` 负责。

由此可推出它的**本质**：

> **ServiceLB = "在每台节点上用 hostPort 监听该端口，并把节点 IP 填进 EXTERNAL-IP"**。
> 它**没有 VIP**、**不做健康检查**、**不做跨节点故障漂移**。所谓"负载均衡"，其实是"每台节点都监听，客户端自己挑一台"。

---

## 4. 本集群现状：ServiceLB 是**关闭**的，对外走 NodePort

本项目的 `vagrant/nodes.yml` 里：

```yaml
k3s_config:
  disable_traefik: true
  disable_servicelb: true
```

对应 `ansible/roles/k3s-server/templates/config.yaml.j2` 渲染出的 k3s 配置：

```yaml
disable:
  - traefik
  - servicelb
```

也就是说：**本集群既没有 ServiceLB，也没有 k3s 默认的 Traefik**；对外统一走**自建的 nginx-ingress + NodePort**。

实测（见文末附录 A、B）：`kube-system` 里**没有任何 `svclb-*` DaemonSet**；集群当前所有对外服务都是 `NodePort`：

| 命名空间 | 服务 | 类型 | 端口 |
|---------|------|------|------|
| ingress-nginx | ingress-nginx-controller | NodePort | `80:30080`, `443:30444` |
| cattle-system | rancher | NodePort | `80:31380`, `443:30443` |
| gateway-demo | gateway-nginx | NodePort | `80:30025` |

---

## 5. 开与不开的对比

### 5.1 关闭时（本环境实测）

在关闭状态下建一个 `type: LoadBalancer` 的 Service，会发生两件"看似矛盾"的事（附录 D–G 为真实输出）：

- **`EXTERNAL-IP` 永远是 `<pending>`**，`status.loadBalancer` 是**空对象** `{}` —— 没人来填它。
- 但它**仍被分配了一个 NodePort**（k8s 默认会给 `LoadBalancer` 类型也分配 nodePort，可用 `allocateLoadBalancerNodePorts: false` 关掉），**并且该 NodePort 照样能从节点 IP 访问（HTTP 200）** —— 因为这是 kube-proxy 的活，跟 LB 控制器无关。

一句话：**关掉 ServiceLB 后，`LoadBalancer` 实际上退化成一个"`EXTERNAL-IP` 为空的 NodePort"**。这就是很多人"LB 一直 pending，可服务在 3 万端口却能访问"的真相。

### 5.2 打开后的**预期**行为

> ⚠️ 以下为**按 k3s 官方文档描述的行为**，**本章未在本环境做切换实测**（切换需改节点配置并重启 k3s，见 §8）。请勿把它当作本集群的实测输出。

- `kube-system` 里会为每个 LB Service 出现一个 `svclb-<service>` DaemonSet，每个合格节点一个 `klipper-lb` Pod。
- 该 Service 的 `EXTERNAL-IP` 从 `<pending>` 变为**节点 IP 列表**，本环境即 `192.168.56.10` 与/或 `192.168.56.20`。
- 从宿主机可直接访问 `http://192.168.56.10:<port>`（端口就是 Service 端口，可以是 80/443，不再限于 3 万段）。
- 删除该 Service 时，对应的 `svclb-*` DaemonSet 会被**自动回收**。

### 5.3 对比表

| 维度 | 关闭（本环境现状） | 打开 ServiceLB |
|------|-------------------|----------------|
| `LoadBalancer` 的 `EXTERNAL-IP` | **永远 `<pending>`** | **节点 IP**（多节点=多个 IP） |
| 是否分配 NodePort | 会（可用，但语义别扭） | 会 |
| 额外资源 | 无 | 每个 LB Service 一个 DaemonSet（**每节点 1 个 pod**） |
| 端口自由度 | 仍受 `30000–32767` 限制 | 可直接用 80/443 等 |
| 真 VIP / 健康检查 / 漂移 | 无 | **也无**（仍是节点 IP 摊开） |
| 默认源 IP | 会被 SNAT（除非 `externalTrafficPolicy: Local`） | 同左 |
| 与 hostPort/NodePort 冲突 | 少 | **有**：`hostPort` 抢端口，撞到就 Pending |
| 云上 `type: LoadBalancer` 的 YAML 可移植性 | 差（本地跑不通） | 好（本地能跑，行为仍与云不同） |

---

## 6. 特点与优劣

**优点**

- **零依赖、开箱即用**：不用装任何东西，`LoadBalancer` 就不再 pending；
- **免端口号**：可以直接用 80/443，比 NodePort 的高位端口"体面"；
- **对默认用 `LoadBalancer` 的 Chart 友好**：很多 Chart 默认 `type: LoadBalancer`，开了就能直接跑；
- 对**单节点/边缘/一次性**环境足够。

**缺点 / 限制**

- **没有真正的 VIP**：`EXTERNAL-IP` 只是节点 IP，客户端要自己选节点，**节点挂了就断**，没有漂移；
- **没有健康检查**：后端挂了它不会摘；
- **资源随规模膨胀**：`服务数 × 节点数` 个 `svclb` Pod；
- **抢 host 端口**：用 `hostPort` 绑端口，**和别的 hostPort/hostNetwork 直接冲突**；官方明确说默认会占 80/443，导致别的 HostPort/NodePort pod 用不了；
- **源 IP 默认丢失**（需 `externalTrafficPolicy: Local`，但那又牺牲均衡）；
- **不是生产级方案**：设计定位就是便利件。

---

## 7. 选型建议：本环境 / 公司测试（KVM）/ 生产（混合云）

| 环境 | 建议 | `LoadBalancer` 由谁实现 | 理由 |
|------|------|------------------------|------|
| **本环境（本地教学）** | **保持关闭**，用 NodePort + Ingress | —— | 现有暴露链路已自洽；避免 `svclb` 与 30080/30444 抢端口 |
| **公司测试（KVM，要对齐生产）** | **关闭**，装 **MetalLB** | MetalLB（L2/BGP） | 测试与生产的 `LoadBalancer` 行为一致，不踩"测试能跑、生产 pending"的坑 |
| **公司测试（KVM，临时/集成）** | **关闭**，用 NodePort + Ingress | —— | 最省事、无额外组件 |
| **生产（公有云部分）** | **关闭** | **云厂商 LB**（cloud-controller-manager） | 云上就该用云 LB（真 VIP、健康检查、跨 AZ） |
| **生产（本地/KVM 部分）** | **关闭** | **MetalLB** 或硬件 LB（F5/HAProxy+keepalived） | 需要真 VIP |
| 单节点/边缘/玩具 | 可开 | ServiceLB（默认） | 只图方便 |

三条硬规则：

1. **生产一律关闭 ServiceLB**；
2. **不要同时开两个 LB 实现**：ServiceLB 与 MetalLB / 云 LB 会互相抢 `LoadBalancer` Service，必须只留一个（用 MetalLB/云 LB 时先 `--disable servicelb`）；
3. **南北向优先收敛到 Ingress/Gateway + 一个入口**，而不是给每个服务都发 `type: LoadBalancer`（省 IP、省 `svclb`、便于统一 TLS/路由）。

---

## 8. 本环境若要打开 ServiceLB：操作与回滚

> ⚠️ 以下会**修改节点配置并重启 k3s**，属于集群级变更。仅在明确需要时执行，并先确认可以接受控制面短暂中断。

### 8.1 先纠正两个"坑"

**坑 1：`nodes.yml` 的开关没接进模板。** `config.yaml.j2` 里 `disable:` 是**写死的**（`traefik`、`servicelb`），`k3s_config.disable_servicelb` 这个变量**根本没被模板引用**：

```yaml
# ansible/roles/k3s-server/templates/config.yaml.j2（现状片段）
disable:
  - traefik
  - servicelb
```

所以只把 `nodes.yml` 改成 `disable_servicelb: false`，**不会改变渲染结果**。

**坑 2：`k3s-ops.sh install` 是空跑。** 它走的是 `ansible/inventory.yml`，而该文件是**占位空清单**：

```text
$ ansible-playbook -i inventory.yml playbooks/k3s-cluster.yml --list-hosts
[WARNING]: provided hosts list is empty, only localhost is available...
  play #1 (all): Install and configure k3s cluster
    hosts (0):
```

真正把 `vagrant/nodes.yml` 喂给 Ansible 的，是 **Vagrant 的 ansible provisioner**（`Vagrantfile` 里 `ansible.extra_vars = { k3s_config: nodes_config['k3s_config'], ... }`），由 `vagrant up` / `vagrant provision` 触发。**改 `nodes.yml` 只有重新 provision 才生效。**

### 8.2 方法 A（最直接，立即生效）：改节点配置

```bash
./k3s-ops.sh ssh server-1
#   （登录后）先备份：
#   sudo cp /etc/rancher/k3s/config.yaml /etc/rancher/k3s/config.yaml.bak
#   （登录后）编辑：
#   sudo vi /etc/rancher/k3s/config.yaml      # 从 disable 列表里删掉 "- servicelb" 这一行
#   （登录后）重启：
#   sudo systemctl restart k3s
```

> `k3s-ops.sh ssh` 只负责登录（内部是 `vagrant ssh <host>`），**不接受 `-c` 之类的附加参数**；要一条命令直达，用 `(cd vagrant && vagrant ssh k3s-demo-server-1 -- "命令")`。
> 多 server 时，**每台 server** 都要改配置并重启。

### 8.3 方法 B（可重复，纳入配置管理）

1. 让模板尊重变量（改成条件渲染）：

   ```yaml
   # ansible/roles/k3s-server/templates/config.yaml.j2（改后片段）
   disable:
   {% if k3s_config.disable_traefik %}
     - traefik
   {% endif %}
   {% if k3s_config.disable_servicelb %}
     - servicelb
   {% endif %}
   ```

2. `vagrant/nodes.yml` 里把开关置否：`disable_servicelb: false`。

3. 重新 provision（provisioner 挂在**最后一个节点**上，会对**所有节点**生效；前提是 Vagrant 状态正常，`vagrant status` 显示 running）：

   ```bash
   (cd vagrant && vagrant provision)
   ```

4. 集群已初始化时，provision 只会**重写** `/etc/rancher/k3s/config.yaml`、**不会重启 k3s**——仍需按 8.2 手动重启。

> ⚠️ 重新 provision 会跑完整 `k3s-cluster.yml`（common/server/agent 三个角色）。在已初始化集群上通常是幂等的，但仍建议先在测试环境验证。

### 8.4 验证

```bash
# 建一个 LoadBalancer Service
kubectl --kubeconfig ./kubeconfig create ns lb-demo
kubectl --kubeconfig ./kubeconfig -n lb-demo create deployment web \
  --image=nginxinc/nginx-unprivileged:1.27 --replicas=2
kubectl --kubeconfig ./kubeconfig -n lb-demo expose deploy/web \
  --name=web-lb --type=LoadBalancer --port=80 --target-port=8080

# 1) 应看到 kube-system 出现 svclb-* DaemonSet
kubectl --kubeconfig ./kubeconfig -n kube-system get ds

# 2) EXTERNAL-IP 应从 <pending> 变成节点 IP（本环境为 192.168.56.10 / .20）
kubectl --kubeconfig ./kubeconfig -n lb-demo get svc web-lb

# 3) 宿主机直连（端口即 Service 端口 80）
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.56.10:80/
```

### 8.5 回滚

```bash
# 1) 删掉测试资源
kubectl --kubeconfig ./kubeconfig delete ns lb-demo

# 2) 若用方法 A（直接改节点）：还原配置并重启
./k3s-ops.sh ssh server-1
#   （登录后）sudo mv /etc/rancher/k3s/config.yaml.bak /etc/rancher/k3s/config.yaml
#   （登录后）sudo systemctl restart k3s
```

> 若用方法 B（模板 + `nodes.yml`）：把 `disable_servicelb` 设回 `true`（或还原模板），重新 `vagrant provision`，再按 8.2 重启 k3s。

### 8.6 注意

- **端口冲突**：ServiceLB 用 `hostPort`，若 LB Service 用 80/443，会与占用这些端口的 hostPort/NodePort 冲突；本集群已有 `30080/30444` 等 NodePort，注意别撞。
- **别与 MetalLB/云 LB 并存**（见 §7）。
- 想给"某些节点专用"：给节点打 `svccontroller.k3s.cattle.io/enablelb=true`（进入 allow-list 模式），或用 `svccontroller.k3s.cattle.io/lbpool=<pool>` 做节点池。

---

## 9. 延伸：MetalLB —— 真正的 VIP

如果目标是"**真负载均衡**"（单一 VIP、健康检查、跨节点漂移），ServiceLB 不够，答案是 [**MetalLB**](https://metallb.universe.tf/)：

- **地址分配**：你用 CRD `IPAddressPool` 给它一段可用 IP（本地可用 RFC1918 私网段）；
- **对外宣告**：
  - **L2 模式**（ARP/NDP）：由一台节点"认领"该 IP 并在 LAN 上宣告——**简单**，但同一时刻只有一台在承载；
  - **BGP 模式**：多节点与路由器建 BGP 会话，**真·多节点负载 + 策略控制**——需要网络侧配合；
- **与 k3s 的关系**：**必须先关掉 klipper（ServiceLB）**，即 `--disable servicelb`（MetalLB 官方《Issues with K3s》明确要求）。

本环境不直接上 MetalLB 的原因：L2 模式需要一段**未被占用、且在 LAN 内可 ARP** 的 IP 池——教学环境里通常没有规划，属于"进阶/可选"话题。

---

## 10. Rancher 界面对照

登录 `https://192.168.56.10:30443`（admin/admin）后：

- **看 Service 类型与端口**：`Cluster` → **Service Discovery** → **Services** → 选命名空间（如 `ingress-nginx`）→ 看 `Type` 列（`NodePort`）与 `Ports`。
- **看 LoadBalancer 状态**：同上，若某服务是 `LoadBalancer`，`External IP` 列会显示 `<pending>`（本环境）。
- **看 ServiceLB 的 DaemonSet（仅开启时才有）**：`Workloads` → **DaemonSets** → 选命名空间 `kube-system` → 会出现 `svclb-<service>`。
- **看它产生的 Pod（仅开启时）**：`Workloads` → **Pods** → `kube-system` → `svclb-*`。

---

## 动手练习

1. **观察 pending**：建一个 `type: LoadBalancer` 的 Service，观察 `EXTERNAL-IP` 是否 `<pending>`，并解释为什么。
2. **它还能通吗**：给上面这个 LB Service 找它被分配的 `nodePort`，从节点 IP `curl` 一下，验证"pending 但仍可达"。
3. **纯 pending**：把该 Service 加上 `spec.allocateLoadBalancerNodePorts: false`，重建，观察 `PORT(S)` 里是否**不再有 nodePort**。
4. **对比 NodePort**：同样后端再建一个 `type: NodePort` 的 Service，对比两者 `EXTERNAL-IP` 与端口。
5. **端口占用推演**：假设开启 ServiceLB 后，某 LB Service 用 80 端口，而某 Pod 用了 `hostPort: 80`，会出现什么？（提示：DaemonSet 调度）
6. **数一数**：如果开启 ServiceLB 且有 5 个 LB Service、2 个节点，`kube-system` 里会多出多少个 Pod？（提示：§3 机制）
7. **选型判断**：给出三种场景（单机边缘、公司 KVM 测试要跑生产同款 YAML、公有云生产），分别选哪种 LB 实现，并说明理由。

<details>
<summary>参考答案</summary>

1. 会一直 `<pending>`。因为本集群 `--disable servicelb`，没有任何 LB 控制器去填 `status.loadBalancer`；上游 k8s 本身不实现 `LoadBalancer`。

2. 能通。`LoadBalancer` 类型默认**也会分配一个 nodePort**（本环境实测如 `32163`），这个转发是 kube-proxy 的职责，与 LB 控制器无关：
   ```bash
   NPLB=$(kubectl --kubeconfig ./kubeconfig -n lb-demo get svc web-lb -o jsonpath='{.spec.ports[0].nodePort}')
   curl -s -o /dev/null -w '%{http_code}\n' "http://192.168.56.10:$NPLB/"   # 200
   ```

3. `PORT(S)` 会变成只有 `80/TCP`（**不再有 `80:3xxxx/TCP`**），`EXTERNAL-IP` 仍 `<pending>`。这就是"最纯粹的 pending"——既不填 IP、也不占节点端口。

4. `NodePort` 的 `EXTERNAL-IP` 是 `<none>`（注意与 LB 的 `<pending>` 不同），端口是 `80:3xxxx/TCP`；两者都能从节点 IP 访问，区别只在"有没有人为它填 `EXTERNAL-IP`"。

5. 若开启 ServiceLB：该 LB 的 DaemonSet 会尝试在节点上用 `hostPort: 80` 起 `klipper-lb`。若节点 80 已被占用，则**该节点不部署**；若**所有**节点都占用，则该 LB **保持 Pending**。这正是官方说的"only be deployed on nodes that have that port available"。

6. `5 × 2 = 10` 个 `svclb` Pod（每个 LB Service 一个 DaemonSet、每节点一个 Pod）。

7. —— **单机边缘**：用 ServiceLB（默认开）即可，`节点 IP` 就是入口；
   —— **公司 KVM 测试（跑生产同款 YAML）**：关 ServiceLB + 装 **MetalLB**，保证 `LoadBalancer` 行为与生产一致；
   —— **公有云生产**：关 ServiceLB，用**云厂商 LB**（经 cloud-controller-manager），要真 VIP/健康检查/跨 AZ。

</details>

---

## 附录：本章真实采集片段

> 采集环境：k3s `v1.30.2+k3s2`，节点 `k3s-demo-server-1`（192.168.56.10）与 `k3s-demo-agent-1`（192.168.56.20）。
> 采集时间：2026-10-16。采集时 ServiceLB 处于**关闭**状态。临时资源采集后已清理。

**A. 关闭态下，`kube-system` 无任何 `svclb` DaemonSet**

```text
$ kubectl --kubeconfig ./kubeconfig -n kube-system get ds
No resources found in kube-system namespace.
```

**B. 集群对外服务均为 NodePort（节选）**

```text
$ kubectl --kubeconfig ./kubeconfig get svc -A | grep -E 'NodePort|NAME'
NAMESPACE             NAME                       TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)                      AGE
cattle-system         rancher                    NodePort   10.43.111.14    <none>        80:31380/TCP,443:30443/TCP   143d
gateway-demo          gateway-nginx              NodePort   10.43.132.95    <none>        80:30025/TCP                 2d19h
ingress-nginx         ingress-nginx-controller   NodePort   10.43.197.40    <none>        80:30080/TCP,443:30444/TCP   143d
lab                   nginx-svc                  NodePort   10.43.23.169    <none>        80:32062/TCP                 12d
```

**C. 建对照：一个 `LoadBalancer` 与一个 `NodePort`**

```text
$ kubectl --kubeconfig ./kubeconfig create ns lb-demo
namespace/lb-demo created
$ kubectl --kubeconfig ./kubeconfig -n lb-demo create deployment web --image=nginxinc/nginx-unprivileged:1.27 --replicas=2
deployment.apps/web created
$ kubectl --kubeconfig ./kubeconfig -n lb-demo rollout status deploy/web --timeout=90s
deployment "web" successfully rolled out
$ kubectl --kubeconfig ./kubeconfig -n lb-demo expose deploy/web --name=web-lb --type=LoadBalancer --port=80 --target-port=8080
service/web-lb exposed
$ kubectl --kubeconfig ./kubeconfig -n lb-demo expose deploy/web --name=web-np --type=NodePort --port=80 --target-port=8080
service/web-np exposed
```

**D. 两者对比：`LoadBalancer` 的 `EXTERNAL-IP` 为 `<pending>`**

```text
$ kubectl --kubeconfig ./kubeconfig -n lb-demo get svc
NAME     TYPE           CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
web-lb   LoadBalancer   10.43.51.191    <pending>     80:32163/TCP   9s
web-np   NodePort       10.43.188.185   <none>        80:32345/TCP   8s
```

**E. `LoadBalancer` 的 `status` 为空对象（永远 pending）**

```text
$ kubectl --kubeconfig ./kubeconfig -n lb-demo get svc web-lb -o jsonpath='{.status.loadBalancer}{"\n"}'
{}
```

**F. 但它的 nodePort 仍可访问（kube-proxy 在转发，与 LB 无关）**

```text
$ # web-lb nodePort=32163  web-np nodePort=32345
$ curl -s -o /dev/null -w '%{http_code}\n' http://192.168.56.10:32163/
200
$ curl -s -o /dev/null -w '%{http_code}\n' http://192.168.56.10:32345/
200
```

**G. 依然没有任何 `svclb`（不会为 LB 建 DaemonSet）**

```text
$ kubectl --kubeconfig ./kubeconfig -n kube-system get ds
No resources found in kube-system namespace.
```

**H. 清理**

```text
$ kubectl --kubeconfig ./kubeconfig delete ns lb-demo
namespace "lb-demo" deleted
```

**I. 佐证：`k3s-ops.sh install` 走的是占位空清单（匹配不到主机）**

```text
$ cd ansible && ansible-inventory -i inventory.yml --list
{
    "_meta": {
        "hostvars": {},
        "profile": "inventory_legacy"
    },
    "all": {
        "children": [ "ungrouped", "server", "agent" ]
    }
}

$ ansible-playbook -i inventory.yml playbooks/k3s-cluster.yml --list-hosts
[WARNING]: provided hosts list is empty, only localhost is available. Note that the implicit localhost does not match 'all'

playbook: playbooks/k3s-cluster.yml

  play #1 (all): Install and configure k3s cluster	TAGS: []
    pattern: ['all']
    hosts (0):
```

