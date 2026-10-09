# 23 CNI 插件体系详解：flannel / Calico / Cilium 与集群网络底座

## 本章目标

- 理解 **CNI 是什么**：一套"容器怎么获得网络"的标准化接口（规范 + 插件 + 配置）
- 走通一条 **Pod 网络的诞生流程**：kubelet → CRI → CNI ADD → IPAM → veth/网桥/隧道
- 对比 **三大主流 CNI 插件**：flannel（overlay 简单派）/ Calico（BGP 路由派）/ Cilium（eBPF 全能派）
- 用本集群 **flannel 实站解剖**（双网卡/vxlan/路由表/annotation/CNI 配置全部实测）建立"看得见"的直觉
- 掌握 **CNI 切换与排障**：切 CNI 是重建网络的大手术，排障先分清"CNI 层 vs 数据面层"

> 前置：建议先完成 04（网络与通讯）、11（iptables 与 Service）、22（eBPF 与 Cilium 数据面）。
> 本章与 22 章互补：**CNI 管"网怎么建"（接口/IP/路由），数据面管"流量怎么转"（Service 转发）**——Cilium 同时是两者，Calico 可选 eBPF 数据面。
> 本章除「其他插件」与「切换」两节的通用知识外，**实站数据全部为本集群真实采集（2026-10-06）**。

---

## 1. CNI 是什么

### 1.1 定义

> **CNI**（Container Network Interface，容器网络接口）是 CNCF 维护的一套规范：**定义容器运行时（containerd/CRI-O）如何把网络"做"给一个容器**——创建接口、分配 IP、配置路由；删除容器时清理。

它解决一个工程问题：**网络方案很多（flannel/calico/cilium/weave…），运行时不该为每种方案写死代码**——于是定一个统一接口，运行时只负责"喊"，具体怎么建网由**插件**干。

```text
容器运行时（containerd）          CNI 规范              网络插件（实现）
       │                          │                      │
  要给 Pod 建网络 ── 调用 ──▶ 传配置 + 环境变量 ──▶ flannel / calico / cilium…
       ◀────────────── 返回 接口名 + IP ───────────┘
```

### 1.2 一次调用长什么样（协议）

运行时执行插件二进制（如 `flannel`），通过 **stdin 传 JSON 配置** + **环境变量传上下文**：

```bash
# 概念示意（实际由 containerd 自动做，无需手工执行）
CNI_COMMAND=ADD CNI_CONTAINERID=<沙箱ID> CNI_NETNS=/var/run/netns/<沙箱> \
CNI_IFNAME=eth0 CNI_ARGS=K8S_POD_NAMESPACE=lab,K8S_POD_NAME=nginx-xxx \
/opt/cni/bin/flannel < /etc/cni/net.d/10-flannel.conflist
```

| 命令 | 含义 | 触发时机 |
|------|------|---------|
| `ADD` | 给容器建网络 | Pod sandbox 创建时 |
| `DEL` | 清理网络 | Pod 删除/沙箱销毁时 |
| `CHECK` | 校验网络仍在 | 可选，健康检查 |
| `GC` / `STATUS` | 垃圾回收 / 状态 | 新版本扩展 |

### 1.3 三个组成：二进制 + 配置 + IPAM

```text
插件二进制   /opt/cni/bin/ ……（flannel、portmap、bandwidth、host-local、bridge…）
配置(conf)   /etc/cni/net.d/*.conflist  —— 描述"用哪些插件、怎么用"（本集群实测在下文 4.6）
IPAM 插件   host-local / dhcp  —— 负责分配 IP（"IP Address Management"）
```

**关键**：插件是**链式**的（conflist 多插件按顺序执行）——本集群就是 `flannel`（主）+ `portmap` + `bandwidth` 三个插件串起来（4.6 有全量配置）。

---

## 2. K8s 中一条 Pod 网络的诞生（全流程）

### 2.1 流程图（以本集群 k3s + containerd + flannel 为例）

```text
① Pod 调度到节点        scheduler 决定：node = k3s-demo-server-1
② kubelet 拉起            kubelet 通知 containerd 创建 sandbox（pause 容器）
③ CRI 调 CNI             containerd 按 /etc/cni/net.d/ 配置执行 CNI ADD（flannel）
④ 建网                   flannel 创建 veth 对 → 挂到 cni0 网桥 → 配 IP（host-local）
⑤ 回报                   kubelet 拿到 PodIP（如 10.42.0.66），更新 Pod 状态
⑥ 应用容器接入           nginx 容器 join 同一个 network namespace（共享 eth0/IP）
```

### 2.2 IPAM：Pod IP 从哪来

- 每个节点被分配一个 **Pod 子网**（server-1：`10.42.0.0/24`；agent-1：`10.42.1.0/24`）
- 子网内 IP 由 **host-local** 插件在节点本地分配（从 cni0 网桥角度看，就是 `10.42.0.1` 网关 + 池内地址）
- **Pod 重建 = 重新分配**：IP 不固定。第 19 章实测过 `coredns` 重启后 IP 从 `10.42.0.29` 变成 `10.42.0.62`——这就是 IPAM 每次新建分配的体现（也因此 ClusterIP/Service 才重要）

### 2.3 Pod 网络的"三个要素"自查

| 要素 | 本集群实例 | 查看命令 |
|------|-----------|---------|
| 接口 | 容器内 `eth0`（veth 对的一端） | `kubectl exec <pod> -- ip addr` |
| IP | `10.42.0.66`（节点子网内） | `kubectl get pod -o wide` |
| 路由/网关 | 默认网关 = cni0（10.42.0.1） | 节点 `ip route`（4.4 实测） |

> **直觉**：Pod 的 eth0 像"网线插在节点的一张虚拟交换机 cni0 上"，节点间再靠 vxlan 隧道像"一根光纤"连起来。这就是 flannel 的全貌。

---

## 3. 三大主流 CNI 插件对比

### 3.1 flannel（本集群在用）：简单派 Overlay

- **思路**：每个节点一张虚拟子网，节点间用 **vxlan 隧道**（或 host-gw 路由）互联，Pod 无需修改内核/路由协议
- **优点**：极简单、零外部依赖、跨网段/跨云都行（overlay 不挑底层）；k3s **默认内嵌**
- **缺点**：overlay 封包有开销；**不带网络策略**（要策略得另装 Calico 策略引擎）

### 3.2 Calico：路由派（BGP）

- **思路**：每个节点用 **BGP 协议**把子网路由广播出去，数据包**直接按路由表转发**（无 overlay 封装，性能接近物理网络）
- **优点**：性能好、网络策略（NetworkPolicy）原生成熟、可纯路由（不需要隧道）
- **缺点**：BGP 需在节点/路由设备上部署（大的数据中心场景要配合网络设备）；配置比 flannel 复杂

### 3.3 Cilium：eBPF 全能派（第 22 章细节）

- **思路**：eBPF 数据面（socket/TC/XDP 直通）+ 身份安全 + L3-L7 策略 + Hubble 观测
- **优点**：性能与功能天花板——源 IP 保留、HTTP 级策略、服务网格友好、可观测
- **缺点**：上手门槛最高、依赖内核版本、全家桶组件多

### 3.4 对比表（核心）

| 维度 | **flannel**（本集群） | **Calico** | **Cilium** |
|------|----------------------|-----------|-----------|
| 组网方式 | **vxlan overlay**（隧道） | BGP 路由 / vxlan | eBPF 直通（可选隧道） |
| 转发开销 | 有（vxlan 封包，MTU 1450） | 低（纯路由） | 最低（eBPF 直通） |
| 网络策略 | ❌ 不带 | ✅ 成熟（L3/L4） | ✅ 最强（L3–L7） |
| 可观测 | ❌ 无 | 有限 | ✅ Hubble 流量图 |
| 服务网格友好 | 一般 | 一般 | ✅ 很好（无 sidecar 也行） |
| 部署复杂度 | **最低**（k3s 开箱即用） | 中（BGP/CNI 都要配） | 高（全家桶） |
| 规模上限 | 中小集群够用 | 大（适合跨机架 BGP） | 大 + 功能密集场景 |
| 典型角色 | 学习/轻量生产 | 生产默认选项之一 | 云原生前沿/安全/观测 |

### 3.5 其他插件一句话

| 插件 | 一句话 |
|------|--------|
| **canal** | = Calico 的策略 + flannel 的网络（组合拳，历史方案） |
| **weave** | 早期 mesh overlay，简单但性能一般，已边缘化 |
| **antrea** | 基于 Open vSwitch（OVS）的 K8s CNI，VMware 系 |
| **multus** | 不是组网方案，是"多网卡调度器"（一个 Pod 挂多张网） |

---

## 4. 本集群 flannel 实站解剖（全实测）

### 4.1 组件形态：k3s 内嵌（不是 DaemonSet）

```bash
kubectl get ds -A
# 输出: No resources found
```

集群里**没有 flannel DaemonSet**——k3s 把 flannel 编译进了 agent 进程（`--flannel-backend=vxlan` 默认），每个节点由 k3s 进程直接维护。这是 k3s 与 kubeadm（装独立 flannel DS）的差异点。

### 4.2 接口家族（server-1 实测）

```text
eth0        10.0.2.15/24       VirtualBox NAT 网卡 —— 出公网/宿主	机访问
eth1        192.168.56.10/24   host-only 网卡 —— 集群管理网（flannel 隧道出口用这条！）
flannel.1   10.42.0.0/32       vxlan 隧道接口（本节点子网首地址）
cni0        10.42.0.1/24       本地虚拟交换机（Pod 网桥，网关）
veth×××××  （14 个）           每个 Pod 一对 veth：一端挂 cni0，一端进 Pod
```

> **注意 eth1 这个细节**：flannel 的 vxlan 配置 `local 192.168.56.10 dev eth1`——它**挑 host-only 网卡做隧道**（eth1 是集群互通网；NAT 网卡 eth0 只负责出公网）。Pod 跨节点流量走 `eth1`，出公网流量走 `eth0`，互不干扰。

### 4.3 隧道与 annotation 五要素互证

```bash
# 节点上 vxlan 详情（实测）
# ip -d link show flannel.1
# vxlan id 1 local 192.168.56.10 dev eth1 srcport 0 0 dstport 8472
# link/ether 52:83:90:f3:12:17   mtu 1450

# 第 18 章讲过的 Node annotation（实测现值）
# flannel.alpha.coreos.com/backend-type: vxlan
# flannel.alpha.coreos.com/backend-data: {"VNI":1,"VtepMAC":"52:83:90:f3:12:17"}
# flannel.alpha.coreos.com/public-ip: 192.168.56.10
```

| 要素 | 值 | 对应 |
|------|-----|------|
| backend-type | `vxlan` | 隧道模式（vs host-gw 等） |
| VNI | `1` | 虚拟网络 ID（vxlan id 1） |
| **VtepMAC** | `52:83:90:f3:12:17` | **flannel.1 的 MAC**（二层里互认对方隧道的凭据） |
| public-ip | `192.168.56.10` | 隧道源地址（eth1） |
| kube-subnet-manager | 存在 | 子网分配交给 K8s 管理（controller 分 PodCIDR） |

> **一张表看懂**：annotation 是 flannel 的"对讲机频率表"——每个节点广播"我用 vxlan、我的 VNI 是 1、我的 VtepMAC 是这个、我的隧道源 IP 是这个"，其它节点靠这些信息把包封装给你。

### 4.4 路由表（两节点完全对称，实测）

```text
server-1 (子网 10.42.0.0/24):
  10.42.0.0/24 dev cni0                          # 我自己的 Pod，走本地网桥
  10.42.1.0/24 via 10.42.1.0 dev flannel.1 onlink # agent-1 的 Pod，走 vxlan 隧道

agent-1 (子网 10.42.1.0/24):
  10.42.1.0/24 dev cni0 src 10.42.1.1             # 我自己的 Pod
  10.42.0.0/24 via 10.42.0.0 dev flannel.1 onlink # server-1 的 Pod，走隧道
```

> 完美对称：**每个节点只认识"自己的子网（cni0 本地）+ 别家子网（走 flannel.1）"**——这就是 overlay 的思想：把"另一台机器的 Pod 子网"当成"通过隧道可达的远端"。

### 4.5 CNI 配置全量（本集群实测）

`/var/lib/rancher/k3s/agent/etc/cni/net.d/10-flannel.conflist`：

```json
{
  "name": "cbr0",
  "cniVersion": "1.0.0",
  "plugins": [
    { "type": "flannel",
      "delegate": {
        "hairpinMode": true,
        "forceAddress": true,
        "isDefaultGateway": true } },
    { "type": "portmap",
      "capabilities": { "portMappings": true } },
    { "type": "bandwidth",
      "capabilities": { "bandwidth": true } }
  ]
}
```

| 插件 | 干什么 |
|------|--------|
| **flannel**（主） | 建 veth + 挂 cni0 + 配 IP（delegate 指明网桥细节：hairpinMode 允许 Pod 通过 svc 访问自己，isDefaultGateway 让 cni0 当默认网关——即 10.42.0.1） |
| **portmap** | 给 `hostPort` 功能转发端口（CNI 层的端口映射） |
| **bandwidth** | 支持 Pod 注解的带宽限制（`kubernetes.io/ingress-bandwidth` 等） |

### 4.6 一个包跨节点的完整旅程（client 在 server-1 → server 在 agent-1）

```text
client Pod 10.42.0.66
  → veth（进 cni0）
  → 查路由：10.42.1.0/24 走 flannel.1（onlink 不查 ARP 直接封装）
  → vxlan 封装（VNI=1，外层 src=192.168.56.10:8472 → dst=192.168.56.20:8472）
  → eth1 → 物理网线 → agent-1 eth1
  → 拆 vxlan（VtepMAC 核对 52:83:90:f3:12:17 ↔ 对方公钥）
  → flannel.1 → cni0（10.42.1.1）
  → veth → server Pod 10.42.1.xx
```

> **与 21 章的对照**：21 章"L7 入口也是 4 层给的"——这里"6 层的 Pod 互连也是 L3 overlay 给的"：Pod 感知不到隧道，**节点间 vxlan 封装对 Pod 完全透明**（就像 21 章 NodePort 对 Ingress 透明）。

---

## 5. 切换 CNI（生产考量，知道怎么评估即可）

### 5.1 三种切换路径

| 场景 | 操作 |
|------|------|
| k3s 换 flannel → Calico | k3s 以 `--flannel-backend=none` 重建/重配，再 `helm install calico`（tigera-operator） |
| k3s 换 flannel → Cilium | 同上 + `cilium install`（22 章 §5.3） |
| kubeadm 换 CNI | 删旧 DS → 清 `/etc/cni/net.d` → `kubectl apply` 新插件（各插件文档有迁移说明） |

### 5.2 切换前 Checklist（容易踩的坑）

- [ ] **Pod 网段要规划好**且两种插件 PID Range 不冲突（本集群 10.42.0.0/16 是 k3s 默认）
- [ ] **所有存量 Pod 会重建**：IP 全变、有状态服务（StatefulSet）注意数据/连接问题
- [ ] **网络策略 CRD 依赖**：Calico/Cilium 的策略是各自 CRD（K8s 原生 NetworkPolicy 才通用）
- [ ] **数据面协同**：Calico 带 BGP（不依赖 kube-proxy），Cilium 可 `kubeProxyReplacement=strict`（接管 Service 转发）——切换不仅是"CNI"，还可能动"数据面"（22 章）
- [ ] 小集群/学习环境**不要反复横跳**：每次切换都是全集群网络重建

### 5.3 选型决策（组网模式 × 场景）

| 你的情况 | 推荐 | 理由 |
|---------|------|------|
| 学习 / 2-3 节点 / 轻量 | **flannel**（本集群） | 开箱即用、链路直观 |
| 生产中小集群 / 要网络策略 | **Calico** | 策略成熟 + 性能好 |
| 大规模 / 服务网格 / 安全合规 / 可观测 | **Cilium** | 功能天花板（22 章） |
| 跨机房 / 网络设备不可控 | flannel 或 Calico（vxlan 模式） | overlay 不挑底层 |

> 一句话：**追求简单用 flannel，要策略用 Calico，要前沿能力用 Cilium**——没有"最好"，只有"匹配场景"。

---

## 6. 排障：CNI 层网络不通

### 6.1 现象 → 定位表

| 现象 | 最可能原因 | 第一命令 |
|------|-----------|---------|
| Pod 起不来 / `CreateContainerError` | CNI 二进制缺失 / 配置错误 / IPAM 失败 | `kubectl describe pod`（Events）；节点 `journalctl -u k3s` |
| Pod 有 IP 但**同节点互 ping 不通** | cni0 网桥 / veth 挂载异常 | 节点 `ip link`；`kubectl exec <pod> -- ip addr` |
| 同节点通、**跨节点不通** | vxlan 隧道 / 路由不对称 / VNI 或 VtepMAC 不一致 | `ip route`（4.4 对称性）；`ip -d link show flannel.1` |
| 全部 Pod 不通外网 | NAT（eth0 出网）或内核 IPv4 转发关闭 | `sysctl net.ipv4.ip_forward`；节点 SNAT 规则 |
| 换了 CNI 后老的还残留 | 旧 CNI 配置/桥接/路由残留 | 清 `/etc/cni/net.d`、删旧网桥（一般重建节点最干净） |

### 6.2 三层定位心法（和 22 章同理）

```bash
# ① 是"网没建好"还是"流量转不动"？
kubectl get pod -o wide          # 有没有 IP？没有 → CNI 层（本章）
# ② 有 IP，跨节点通不通？
kubectl exec <podA> -- ping <podB-IP>   # 不通 → flannel 隧道/路由（6.1 表第 3 行）
# ③ Service 层通不通（那是 11/22 章数据面的活）
curl <svc-lb>  /  kubectl get ep      # 端点空/规则问题 → 数据面
```

> **分层原则**：**Pod 没 IP / 跨节点不通 = CNI 问题（本章）**；**IP 有、Service 不通 = 数据面问题（11/22 章）**。先分清楚，不冤枉任何一层。

### 6.3 本集群真实案例引用

- **第 19 章 coredns IP 变化**（`10.42.0.29` → `10.42.0.62`）：Pod 重建 → IPAM（host-local）重新分配——**这是 CNI 正常行为**，不是故障。集群内访问请用 Service（`kube-dns` ClusterIP 10.43.0.10 稳定），别依赖 Pod IP。
- **第 11 章 KUBE-SVC 链重建**：Service 增删时 kube-proxy 重建规则——那是数据面；而 Pod 的 IP/接口一直是 flannel 在管，两者互不干扰但叠加成完整网络。

---

## 7. 小结

- **CNI = 规范 + 插件 + 配置 + IPAM**：运行时（containerd）按 conflist 调插件，插件建 veth/网桥/隧道并分配 IP
- **Pod 网络诞生流程**：kubelet → 沙箱 → CNI ADD → PodIP 回报；**Pod 重建 IP 会变**（IPAM）
- **三大插件定位**：flannel 简单 overlay（本集群）/ Calico BGP 路由 + 策略 / Cilium eBPF 全能（22 章）
- **本集群 flannel 实测**：vxlan 隧道走 eth1（host-only）、VNI=1、VtepMAC=52:83:90:f3:12:17、cni0 网关 10.42.0.1、两节点路由完美对称、CNI 链 = flannel+portmap+bandwidth
- **CNI 切换是大手术**：Pod 全重建、策略 CRD 依赖、可能连带换数据面——选型看场景
- **排障分层**：没 IP / 跨节点不通 → CNI；有 IP 但 Service 不通 → 数据面；分清再动手

---

## 动手练习

1. 在 server-1 上依次执行 `ip -br link`、`ip route | grep 10.42`、`ip -d link show flannel.1`，对照 4.2/4.3/4.4，找到本节点的 veth 数量与两个 Pod 子网路由。
2. 在 agent-1 上重复练习 1，对比两条 `10.42.x.0/24` 路由的对称性（4.4 表），解释"为什么每节点只要两条子网路由"。
3. `kubectl get node k3s-demo-server-1 -o yaml | grep flannel` 读出 backend-type / VtepMAC / public-ip，与 `ip -d link show flannel.1` 输出互证（4.3）。
4. 排障演练：某 Pod `kubectl get pod -o wide` 显示 `<none>`（没 IP）。按 6.2 判断这是哪一层的问题，说出排查第一步命令。
5. 深度题：换 CNI 前 checklist 里"Pod 网段冲突"是什么意思？如果新插件用 `10.244.0.0/16` 而本集群 k3s 默认 `10.42.0.0/16`，会发生什么？（提示：kubelet 里已有 Pod CIDR 记录 / 节点子网 annotation）

<details>
<summary>参考答案</summary>

1. 输出应与 4.2/4.3/4.4 一致：flannel.1 10.42.0.0/32、cni0 10.42.0.1/24、若干 veth；路由含 `10.42.0.0/24 dev cni0` 与 `10.42.1.0/24 via … dev flannel.1 onlink`。
2. agent-1 是 `10.42.1.0/24 dev cni0` + `10.42.0.0/24 via … flannel.1`——与 server-1 完全对称。每节点两条就够了：一条本地（cni0 直连），一条对端全部子网（经隧道出口），overlay 把"远端所有 Pod"收敛成"一条隧道路由"。
3. annotation（backend-type=vxlan、VtepMAC=52:83:90:f3:12:17、public-ip=192.168.56.10）与 `ip -d link show flannel.1`（vxlan id 1 local 192.168.56.10 dev eth1、MAC 52:83:90:f3:12:17）逐项对应——annotation 就是节点间封包所需的互认信息。
4. `<none>` 说明 **CNI 层没把网建起来**（IPAM 没给 IP）——不是数据面（Service 转发）问题。第一步：`kubectl describe pod <name>` 看 Events 里 CNI 报错（再配合节点 `journalctl -u k3s` 看 flannel 日志）。
5. Pod CIDR 由各 CNI 自己声明并广播，选两套不同的默认网段（10.42 vs 10.244）会在节点/路由层面出现"两个子网互相不认识"：旧插件建的 Pod 路由与路由表继承冲突、kubelet 的 node annotation（`flannel.alpha.coreos.com/…` 或 controller 分配的 CIDR）残留旧值，导致新增 Pod 拿错网段/IP 冲突——换 CNI 要么沿用同一 CIDR，要么彻底清理（重建节点最干净）。
</details>