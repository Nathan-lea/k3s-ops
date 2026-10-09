# 22 eBPF 与 Cilium 数据面详解：下一代集群网络

## 本章目标

- 理解 **eBPF 是什么**：内核里的"可编程沙箱"，为什么它能安全地改写网络行为
- 看清 **kube-proxy 的痛点**（iptables / ipvs 的固有局限），理解"为什么要有新方案"
- 掌握 **Cilium 数据面** 如何用 eBPF 替代 kube-proxy：socket 层负载均衡、直达后端、源 IP 保留
- 会对比 **iptables / ipvs / eBPF 三代数据面**（性能、功能、可观测、安全）
- 建立判断能力：`iptables -L` / `ipvsadm -Ln` / `cilium status` 三种命令对应三种数据面
- 与本集群（flannel + kube-proxy iptables）对照，明白"小集群为什么不用、什么时候该用"

> 前置：先完成 11（iptables 与 Service）、11 章 §3.9（ipvs）。本章与 23（CNI 插件体系）是姊妹篇：本章讲**数据面引擎（怎么转发）**，23 章讲**CNI 插件（怎么组网）**——Cilium 同时是两者。
> ⚠️ 诚实声明：**本集群未部署 eBPF / Cilium**（现状：flannel 组网 + kube-proxy iptables 转发，均为上两章实测）。本章原理部分来自内核与 Cilium 官方机制总结，对照部分全部为本集群实测基线——学习重点是"理解机制 + 会判断自己集群跑的是哪种"。

---

## 1. eBPF 是什么

### 1.1 一句话定义

> **eBPF**（extended Berkeley Packet Filter）是一套"把用户编写的程序安全加载进 Linux 内核、在事件发生时执行"的机制。程序跑在内核态，但受严格限制与验证——**像给内核装了一个可控的插件系统**。

```text
传统方式:
  改内核行为 → 改内核源码/加内核模块 → 重编译/重载 → 风险大、易崩机

eBPF 方式:
  写 C/Go 小程序 → 编译成 BPF 字节码 → 内核验证器检查 → 挂到钩子上
  → 事件触发即执行（无需重启、不用改内核）
```

### 1.2 关键特性（为什么安全）

| 特性 | 说明 |
|------|------|
| **验证器（verifier）** | 加载前逐条检查字节码：不会死循环、不越界访问、退出路径有限 |
| **受限指令集** | 不是任意代码，不能随便调内核函数（只能调受支持的 helper） |
| **事件驱动** | 平时零开销，只有挂钩的事件发生时才有逻辑执行 |
| **热插拔** | 加载/卸载不影响系统，出错可秒级回滚（比内核模块安全得多） |

### 1.3 程序生命周期

```text
编写(C/Go) → 编译(clang → BPF 字节码) → 加载(bpftool / cilium 内部)
→ 验证器校验 → 挂载到钩子 → 有事件就执行 → 卸载
```

### 1.4 常见挂载点（网络相关的几个）

| 挂载点 | 位置 | 看到什么 | 典型用途 |
|--------|------|---------|---------|
| **XDP** | 网卡驱动入口（最早） | 原始数据帧 | DDoS 防护、最早丢包 |
| **TC**（traffic control） | 协议栈入口/出口 | 数据包 | 转发、封包、整形 |
| **socket** | 进程 socket 层 | 连接/消息 | **Cilium 的 Socket LB 就挂这里** |
| kprobe / tracepoint | 任意内核函数 | 函数调用 | 观测、追踪 |

> **记忆**：越靠进"网卡"越快（XDP > TC），越靠进"应用"越懂业务（socket 层能看懂连接目标——Cilium 的杀手锏）。

### 1.5 为什么现在火

eBPF 不是新技术（Linux 内核 4.x 就在演进），但三个因素让它近年爆发：

1. **观测性**：不插桩、不重启，就能看到内核里发生了什么（Falco/Tetragon/Hubble）
2. **安全**：内核级策略执行，比应用层更早拦截
3. **云原生**：K8s 规模变大后，iptables 规则爆炸，eBPF 提供 O(1) 数据面——**正好踩中 kube-proxy 的痛点**

---

## 2. kube-proxy 的痛点（为什么要替代它）

### 2.1 一切问题的根源：ClusterIP 是"假地址"

第 11 章讲过：**ClusterIP 不挂任何网卡**。它只是一个 iptables 规则里的"目标 IP"。所有流量到达它都必须经过 **NAT 改写**：

```text
iptables 模式转发一个包:
  client → ClusterIP 10.43.23.169:80
         → KUBE-SVC 链（随机挑一个端点）
         → KUBE-SEP 链 DNAT 成 Pod IP 10.42.0.57:80
         → 回程再做 SNAT/MASQUERADE（否则 Pod 看到的源是 ClusterIP，回不了包）
```

**问题不是"能不能通"，而是"这套 NAT 有代价"**。

### 2.2 iptables 模式的具体痛点

| 痛点 | 说明 |
|------|------|
| **规则越多越慢** | 链式线性匹配 O(n)，集群 500+ Service、几千规则，每条新连接都要遍历 |
| **转发是"随机概率"** | statistic 模块按概率挑端点，不是真正的调度算法（11 章 3.2/3.3） |
| **无连接概念** | 每条规则对每个连接都重新匹配；新连接建立时负载可能极不均匀 |
| **conntrack 负担** | NodePort/ClusterIP 双向都要 conntrack 跟踪，高并发下 conntrack 表爆表是常见故障 |
| **长连接问题** | 新建连接由概率决定，长连接一旦建成绑定不再迁移——重启/扩容后旧连接仍打旧 Pod |

### 2.3 ipvs 改进了什么、还差什么（11 章 §3.9 呼应）

ipvs 用哈希表 O(1) + 调度算法解决了一部分：

- ✅ 查找 O(1)、支持 rr/wrr/lc 等调度算法、内核连接级管理
- ❌ **本质仍是 NAT**：ClusterIP → DNAT → Pod；回程 SNAT
- ❌ 需要加载 `ip_vs` 模块；大集群配置项与排障工具又是一套（`ipvsadm`）
- ❌ 中间层 NAT 导致：**Pod 看到的是被改写过的源地址**、服务网格 sidecar 要"绕行"（每包穿两遍 iptables 或 proxy）

### 2.4 一个很有名的坑（说明"虚拟 IP"的代价）

**NodePort 长连接每连接仅 1/3 流量的问题**：Linux node 上对同一目标端口的多条 socket 连接（SO_REUSEPORT）会哈希到固定 worker；NodePort 再接一个 iptables DNAT 后，从 `conntrack` 看可能绕回同一 worker——表现为"某个 Pod 只收到 1/3 流量"。这类问题排查极痛苦，因为它依赖内核细节。

> **一句话总结痛点**：**只要 ClusterIP 还是"规则里的假地址"，就永远有 NAT、有 conntrack、有规则匹配成本**。根治办法是——**别让它成为假地址，直接在数据路径上把"服务名/目标"解析成真实 Pod**。这就是 eBPF 的思路。

---

## 3. Cilium 数据面：用 eBPF 重新发明转发

### 3.1 架构速览（两个核心组件）

```text
┌──────────────────────────────────────────────────────┐
│ 每个节点:  cilium-agent (DaemonSet)                    │
│   ├─ 管理本节点 BPF 程序 (XDP/TC/socket 钩子)          │
│   ├─ 从 apiserver 同步 Service/Endpoint 到 BPF map     │
│   └─ 与 Hubble (可观测) 同进程集成                     │
├──────────────────────────────────────────────────────┤
│ 集群级:   cilium-operator (Deployment)                │
│   ├─ 分配 PodCIDR / 身份 (Identity)                   │
│   └─ 集群级策略与多集群联动                            │
└──────────────────────────────────────────────────────┘
```

关键点：**没有 kube-proxy**。Cilium 有"无 kube-proxy 模式"（`kube-proxy-replacement=strict`），Service 转发逻辑全部由 BPF 程序承担。

### 3.2 转发方式一：Socket 层负载均衡（集群内流量的杀手锏）

BPF 挂在 **socket 钩子**上，Pod 内进程"发起连接"的那一瞬间，eBPF 程序就能看到目标——直接回答"这个服务名该连哪个真实 Pod IP"：

```text
传统 iptables:  app → ClusterIP 10.43.23.169 → DNAT → 真实 Pod 10.42.0.57
                 （始终有一跳 NAT 在中间）

Cilium socket LB:  app 发起 connect(10.43.23.169:80)
                   → socket 层 BPF 直接改写成 connect(10.42.0.57:80)
                   → 没有任何中间 NAT，Pod 看到的是发起方真实地址
```

**意义**：

- **没有二次封装/重封**，路径最短
- **源 IP 真实保留**（不用 proxy-protocol 那套）
- 负载均衡算法更精细（确定性哈希 maglev，新建连接分布均匀）
- 集群内流量绕开"HAProxy/envoy 又要走一遍 iptables"的怪圈——**服务网格场景收益巨大**

### 3.3 转发方式二：XDP/TC 钩子（南北向流量）

外部流量进 NodePort/LoadBalancer 时，在 **TC/XDP 钩子**直接查询 BPF map（`LB backend map`）得到真实后端，一把跳到 Pod IP——没有逐条规则遍历：

```text
外部 → nodeIP:30080 → TC 钩子查"30080 → 哪些后端" → 直连 Pod IP
（对比 11 章: KUBE-NODEPORTS → KUBE-SVC → KUBE-SEP 三跳链）
```

### 3.4 数据面之外：身份与策略

Cilium 不止转发，它给每个端点（Pod 集合）算一个 **Identity**（身份），安全策略基于身份而非 IP：

```text
CiliumNetworkPolicy（示例，L3-L7 一体）:
  apiVersion: cilium.io/v2
  kind: CiliumNetworkPolicy
  metadata: { name: block-web-to-db }
  spec:
    endpointSelector: { matchLabels: { app: web } }
    egress:
    - toEndpoints: [ { matchLabels: { app: db } } ]   # 只能访问 db
      toPorts:
      - ports: [ { port: 3306, protocol: TCP } ]
        rules:
          http: []                                     # 甚至能编排 HTTP 层规则
```

对比 K8s 原生 NetworkPolicy（L3/L4 为主）——**Cilium 能看懂 L7（HTTP 方法/路径）**，这是 iptables/ipvs 数据面永远做不到的。

### 3.5 Hubble：把转发变成"看得见"

- `hubble observe`：实时看每条流量的路径（谁→谁，经过什么策略）
- 依赖关系图：自动画出服务间调用拓扑
- 这是 iptables/ipvs 时代的"黑盒排障"体验升级

```bash
# 排障示例（若集群装有 cilium-hubble）
hubble observe --from-pod default/nginx-xxx     # 看该 Pod 所有流出流量
```

---

## 4. 三代数据面对比（核心表）

| 维度 | **iptables**（11 章实测） | **ipvs**（§3.9） | **eBPF / Cilium**（本章） |
|------|--------------------------|------------------|---------------------------|
| 转发机制 | 链式规则 + NAT | 内核哈希表 + NAT | **socket/TC/XDP 钩子直通** |
| 查找效率 | O(规则数) | O(1) | O(1)（BPF map） |
| 负载均衡 | 随机概率 | rr / wrr / lc… | **maglev 确定性哈希** |
| 源 IP 保留 | ❌ 需 proxy-protocol | ❌ 需配置 | ✅ 集群内天然保留 |
| 连接状态 | conntrack 跟踪 | 内核连接级 | BPF map 内 |
| 可观测性 | `iptables -L` 静态规则 | `ipvsadm -Ln` 表格 | **Hubble 实时流量图** |
| 安全策略 | 需额外装（如 Calico） | 同左 | **原生 L3-L7 策略**（身份） |
| 内核依赖 | netfilter（都有） | `ip_vs` 模块 | 内核 4.8+（生产建议 5.x） |
| 部署门槛 | 零（默认） | 加载模块 | 较高（Cilium 全家桶） |
| 典型场景 | 中小集群 | 大集群 | **大规模 + 安全 + 可观测 + 服务网格** |

> **记忆口诀**：iptables 是"对着规则一条条对"，ipvs 是"查表+会算账"，eBPF 是"在最快的地方直接回答'去哪个 Pod'"。

---

## 5. 本集群对照（实测基线）

### 5.1 本集群现状（前面章节已实测）

```text
组网:  flannel vxlan（第 23 章详述）——负责 Pod 互联
数据面: kube-proxy iptables（第 11 章: KUBE-SERVICES/SVC/SEP 链齐全）
ipvs:  未启用（/proc/net/ip_vs 不存在，11 章 §3.9）
eBPF:  未部署（kubectl get pods -A 无 cilium-*）
```

### 5.2 为什么本集群不用 eBPF（合理权衡）

| 考虑 | 本集群情况 | 结论 |
|------|-----------|------|
| 规模 | 2 节点、Service 个位数 | iptables 规则几十条，O(n) 无压力 |
| 场景 | 学习 + 演示 | 简单=可教，iptables 规则能"看得见"（第 11 章价值） |
| 功能需求 | 无 X-Large 规模、无服务网格实验 | eBPF 的杀手锏用不上 |
| 运维成本 | 换数据面 = 动网络底座 | 小集群不值得冒这个险 |

> **学习判断**：数据面选型是**规模 × 功能 × 运维成本**的平衡，不是"越新越好"。但理解 eBPF 是**主流趋势**：云厂商托管集群（EKS/GKE/AKS）都在推 Cilium 作为可选 kube-proxy 替代。**看懂 iptables 是看懂 eBPF 的必经之路**——两者解决同一个问题（Service 转发），只是实现不同。

### 5.3 想体验的话（不推荐在本集群反复横跳，知道即可）

```bash
# 方案（了解即可，勿在本学习集群直接执行）:
# 1. 用 cilium CLI 安装（会替换 flannel / 接管 kube-proxy 职责）
curl -L --remote-name-all https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-amd64.tar.gz
cilium install --set kubeProxyReplacement=strict

# 2. 验证
cilium status          # 数据面健康
cilium connectivity test
```

> 风险提示：CNI 切换会让**所有已有 Pod 重建**、IP 全变；本集群 flannel 是 k3s 内嵌的，切换需要 `--flannel-backend=none` 重建集群——**学习环境不动，理解优先**。

---

## 6. eBPF 在 K8s 生态的更大图景

### 6.1 三大方向（不只是网络）

| 方向 | 代表项目 | 干什么 |
|------|---------|--------|
| **网络** | Cilium | 数据面 + 负载均衡 + 策略 |
| **安全** | Falco / Tetragon | 内核级行为监测、可疑 syscall 告警 |
| **可观测** | Hubble / Pixie | 不插桩看流量、内核指标、请求链路 |

### 6.2 eBPF 与 CNI 的关系（为 23 章铺垫）

- **CNI** 管"Pod 怎么获得网络"（接口/IP/路由的创建）——下一章的主角
- **eBPF** 是"数据面引擎"——数据包怎么最快、最智能地转发
- **Cilium 两者都是**：它注册为 CNI 插件（负责建网络），又用 eBPF 做转发（替代 kube-proxy）
- 同理可理解：**Calico 是 CNI 插件（BGP 路由）但不含 eBPF**（传统模式）；flannel 只是 CNI（不做 Service 转发）

### 6.3 趋势一句话

> **eBPF 正在吃掉 iptables 的生态位**：新集群用 iptables 是"默认"，但新流量"K8s 网络改造/服务网格/零信任"基本都是 eBPF 方向。会 iptables 排障（第 11 章），遇到 eBPF 集群能快速迁移思路。

---

## 7. 排障视角：先判断自己在哪一代

### 7.1 三步识别集群数据面（出门就问的三个问题）

```bash
# ① 有没有 KUBE-* 链？
sudo iptables -t nat -L KUBE-SERVICES -n 2>/dev/null | head -3
#   有 → iptables 模式（11 章整套排障）

# ② 有没有 ip_vs？
ls /proc/net/ip_vs 2>/dev/null && sudo ipvsadm -Ln | head
#   有 → ipvs 模式（§3.9）

# ③ 有没有 cilium？
kubectl get pods -n kube-system | grep cilium
#   有 → eBPF 模式（本章；排障用 cilium status / hubble observe）
```

### 7.2 当代数据面排障命令对照

| 数据面 | "看 Service 规则" | "看流量" |
|--------|------------------|---------|
| iptables | `iptables -t nat -L KUBE-SERVICES -n` | 抓包 / 计数器 `-v` |
| ipvs | `ipvsadm -Ln` | `ipvsadm -Lnc`（连接表） |
| eBPF/Cilium | `cilium bpf lb list` | `hubble observe`（流量流） |

### 7.3 关键排障原则（三模式通用）

- **Service 通不通 ≠ 数据面问题**：先看 Endpoints 有没有 IP（`kubectl get ep`）——端点为空，任何数据面都转不起来
- **规则/程序在，但连不上**：查 conntrack / 防火墙（云安全组/宿主机 VirtualBox 端口转发）——这是"数据面之外"的层
- **切了数据面后旧坑消失、新坑出现**：iptables 的坑是"规则多、性能、NAT"；eBPF 的坑是"内核版本、BPF 程序加载失败"——`journalctl -u k3s`（本集群）/ `cilium status` 看内核兼容性

---

## 8. 小结

- **eBPF** = 内核里的可编程沙箱：验证器保证安全、事件驱动零闲置开销、热插拔
- **kube-proxy 的痛点** = ClusterIP 是"规则里的假地址"：iptables 规则 O(n) + 随机概率 + conntrack 负担；ipvs 改进查找但不是根治（仍是 NAT）
- **Cilium 的关键** = **socket 层 BPF 直接解析目标到真实 Pod**：无中间 NAT、源 IP 保留、maglev 确定性负载均衡
- **Cilium 不止转发**：身份 (Identity) + L3-L7 策略、Hubble 实时可观测——iptables/ipvs 做不到
- **三代对比**：iptables（链式 NAT）→ ipvs（哈希+NAT）→ eBPF（钩子直通）；按规模/功能/成本选型
- **本集群**：flannel + iptables（第 11 章实测），未部署 eBPF——小集群合理；理解趋势不盲目跟风
- **排障第一步永远是"识别数据面"**：KUBE-* 链 / ip_vs / cilium，三种模式三套命令

---

## 动手练习

1. 在本集群跑 `sudo iptables -t nat -L KUBE-SERVICES -n | head -5`（server-1 上），再跑 `ls /proc/net/ip_vs`——用 7.1 的三步法判断本集群是第几代数据面，并说出依据。
2. 面试题模拟：解释"为什么 eBPF 能保留源 IP 而 iptables 不行"（提示：§3.2 socket 层与 §2 NAT 的本质差异）。
3. 思考题：如果本集群 Service 增长到 2000 个，iptables 模式最可能先出现什么问题？（提示：§2.2 表格逐条过）
4. 画出三张转发路径图：Client→ClusterIP→Pod 的 iptables 版（第 11 章）与 Cilium socket LB 版（§3.2），标注两者"多的那一步"是什么。
5. 深度题：为什么 Cilium 的安全策略能写 HTTP 规则而 K8s 原生 NetworkPolicy 一般只到 L3/L4？这依赖 eBPF 的什么能力？（提示：§3.4 身份 + §3.5 可观测的底子）

<details>
<summary>参考答案</summary>

1. `KUBE-SERVICES` 链存在 → iptables 模式；`/proc/net/ip_vs` 不存在 → ipvs/eBPF 未启用。本集群 = 第一代数据面（iptables，第 11 章全套分析适用）。
2. iptables 模式 ClusterIP 必须 DNAT，回程要 SNAT（否则 Pod 收到源=ClusterIP，回不了包）——NAT 必然改写地址；eBPF socket 层在"连接发起瞬间"把目标解析成真实 Pod IP，之后直接建连，路径上没有任何改写点，Pod 天然看到发起方真实 IP。
3. 候选：① 规则条数爆炸，每条新连接遍历越来越慢（O(n)）；② conntrack 表在高并发下爆表；③ 随机概率导致长连接负载不均（§2.2/§2.4）。这正是 ipvs（O(1) 查找）和 eBPF（map 直查）被发明的原因。
4. iptables 版：Client → ClusterIP → KUBE-SVC（概率挑端点）→ KUBE-SEP（DNAT）→ Pod，回程 SNAT——中间多一跳 NAT；Cilium 版：connect(ClusterIP:80) 在 socket 层直接改写成 connect(PodIP:80)——没有 DNAT/SNAT 那一跳，路径最短。
5. Cilium 基于 eBPF 的 socket/TC 钩子能"看懂"连接与流量内容（BPF Helper 支持按 HTTP 字段过滤），配合 Identity 机制把策略绑定到逻辑身份而非 IP；iptables 数据面只有包级字段（IP/端口/协议），"看到"不了 HTTP 层，自然写不了 HTTP 规则。
</details>