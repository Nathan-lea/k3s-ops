# 35 NetworkPolicy 网络隔离实战

## 本章目标

- 理解 NetworkPolicy 的作用：默认全通（Flannel 默认）到“最小权限”（Least Privilege）
- 掌握 NetworkPolicy 核心概念：`podSelector`、`namespaceSelector`、`policyTypes`（Ingress/Egress）、`from/to`、`ports`
- 理解“控制 Ingress”和“控制 Egress”两个方向的含义
- 通过真实集群实测：先全拒绝（deny-all）→ 再仅放行 client→server（双向配合）
- 掌握常用排障思路（DNS 解析失败、连通性失败、CNI 对 NetworkPolicy 的支持）
- 体会“RBAC（身份权限）+ NetworkPolicy（网络权限）”双重边界

> 本章所有命令统一使用 `kubectl --kubeconfig ./kubeconfig`。文档中路径统一用 `~/k3s-ops` 表示。

---

## 1. NetworkPolicy 概述

在 Kubernetes 中，默认情况下**同集群内 Pod 间网络是全互通的**。对于多租户、敏感应用场景，仅靠 RBAC（谁能操作资源）往往不够，还需要**网络层面隔离**（谁能访问谁的网络）。

**NetworkPolicy（网络策略）** 通过定义“允许哪些流量通过”的白名单规则，实现 Pod 间及出站入站的精细隔离。只有当**CNI 插件支持 NetworkPolicy**时（如 Calico、Cilium、Kube-router）策略才会生效。

本集群使用 Flannel（k3s 默认），Flannel 本身**不原生强制执行 NetworkPolicy**，但 k3s 通常会配合 `kube-router` 或其他方式启用 NetworkPolicy 支持。实测表明本环境的 NetworkPolicy 能够生效（deny-all 后 client 无法访问 server，放行后恢复）。

### 1.1 核心概念

| 字段 | 说明 |
|---|---|
| `podSelector` | 筛选要应用策略的目标 Pod（空 `{}` 表示“所有 Pod”） |
| `namespaceSelector` | 筛选其他命名空间的 Pod（配合 `podSelector` 使用） |
| `policyTypes` | 指定策略方向：`["Ingress"]`、`["Egress"]` 或 `["Ingress","Egress"]` |
| `ingress.from` | 允许哪些**来源**访问本策略所选的 Pod（入站白名单） |
| `egress.to` | 允许本策略所选的 Pod 访问哪些**目的地**（出站白名单） |
| `ports` | 限定协议（TCP/UDP）和端口号 |

### 1.2 默认行为（重要）

- **未定义任何 NetworkPolicy**：Pod 间全互通（默认宽松）
- **定义了 NetworkPolicy 但只限制了部分方向**：未显式允许的流量在**策略生效的方向**上会被拒绝（具体取决于实现），但实践中**推荐显式列出两个方向**并按最小权限原则设计
- **deny-all（全拒绝）**：`podSelector: {}` + `policyTypes: ["Ingress","Egress"]` 会阻断该命名空间内几乎所有 Pod 间流量（也会影响 DNS 出站，需单独放行）

> Flannel 环境下 NetworkPolicy 行为与 Calico 略有差异，但“全拒绝→部分放行”的实测结论在本集群是成立的。

---

## 2. 真实集群实测：从全通到最小权限

本节在 `netpol-demo` 命名空间创建 `client`（busybox）和 `server`（httpd:2.4-alpine）两个 Pod，先验证默认全通，再逐步收紧。

### 2.1 准备环境

```bash
$ kubectl --kubeconfig ./kubeconfig create ns netpol-demo
namespace/netpol-demo created

$ kubectl --kubeconfig ./kubeconfig label ns netpol-demo name=netpol-demo
namespace/netpol-demo labeled
```

部署 client、server、Service：

```yaml
# ~/k3s-ops/tmp/netpol-demo.yaml（示例）
apiVersion: v1
kind: Pod
metadata:
  name: client
  namespace: netpol-demo
  labels: {app: client}
spec:
  containers:
    - name: busybox
      image: busybox:latest
      command: ["/bin/sh","-c","sleep 3600"]
---
apiVersion: v1
kind: Pod
metadata:
  name: server
  namespace: netpol-demo
  labels: {app: server}
spec:
  containers:
    - name: httpd
      image: docker.1panel.live/library/httpd:2.4-alpine
      ports: [{containerPort: 80}]
---
apiVersion: v1
kind: Service
metadata:
  name: server
  namespace: netpol-demo
spec:
  ports: [{port: 80, targetPort: 80}]
  selector: {app: server}
```

实际部署后 Pod IP：

```bash
$ kubectl --kubeconfig ./kubeconfig -n netpol-demo get pods -o wide
NAME     READY   STATUS    RESTARTS   AGE   IP            NODE               NOMINATED NODE   READINESS GATES
client   1/1     Running   0          16s   10.42.1.127   k3s-demo-agent-1   <none>           <none>
server   1/1     Running   0          16s   10.42.1.126   k3s-demo-agent-1   <none>           <none>
```

### 2.2 改前：默认全通（真实验证）

从 `client` 直接访问 `server` Pod IP（10.42.1.126:80）：

```bash
$ SERVER_IP=$(kubectl --kubeconfig ./kubeconfig -n netpol-demo get pod server -o jsonpath='{.status.podIP}')
$ kubectl --kubeconfig ./kubeconfig -n netpol-demo exec client -- wget -O- --timeout=2 http://$SERVER_IP
...
</body>
</html>
```

**结果：** 返回 httpd 默认页面（200 类响应体），说明默认全通。

### 2.3 改后①：deny-all（全拒绝 Ingress + Egress）

创建一条“全选中”的 NetworkPolicy，同时限制 Ingress 和 Egress：

```yaml
# ~/k3s-ops/tmp/netpol-deny.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all
  namespace: netpol-demo
spec:
  podSelector: {}        # 匹配该命名空间内所有 Pod
  policyTypes: ["Ingress","Egress"]  # 同时限制入站和出站
```

应用后再次测试：

```bash
$ kubectl --kubeconfig ./kubeconfig apply -f /tmp/netpol-deny.yaml
networkpolicy.networking.k8s.io/deny-all created

$ SERVER_IP=$(kubectl --kubeconfig ./kubeconfig -n netpol-demo get pod server -o jsonpath='{.status.podIP}')
$ kubectl --kubeconfig ./kubeconfig -n netpol-demo exec client -- wget -O- --timeout=2 http://$SERVER_IP
command terminated with exit code 1
```

**结果：** 连接超时/失败（exit code 1）。此外，尝试在 `client` 内解析 DNS（`nslookup server`）也会超时，说明**Egress 被拒绝后连 CoreDNS（kube-dns）都无法访问**。

> 这正是“最小权限”起作用的体现：一旦加上 `deny-all`，除非显式放行，否则所有流量都被阻断。

### 2.4 改后②：仅放行 client→server（Ingress + Egress 配合）

要让 `client` 能访问 `server`，通常需要**两条方向都放行**：

1. **server 的 Ingress**：允许带 `app=client` 标签的 Pod 从**入站**访问 server 的 80 端口
2. **client 的 Egress**：允许 `client` 向带 `app=server` 标签的 Pod 在 TCP 80 端口**出站**访问

先放行 server 入站：

```yaml
# ~/k3s-ops/tmp/netpol-allow-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-client-to-server
  namespace: netpol-demo
spec:
  podSelector:
    matchLabels: {app: server}  # 策略作用于 server Pod
  policyTypes: ["Ingress"]
  ingress:
    - from:
        - podSelector:
            matchLabels: {app: client}  # 只允许 client 访问
      ports:
        - protocol: TCP
          port: 80
```

应用后测试（此时 client 的 Egress 仍被 deny-all 拒绝）：

```bash
$ kubectl --kubeconfig ./kubeconfig apply -f /tmp/netpol-allow-ingress.yaml
networkpolicy.networking.k8s.io/allow-client-to-server created

$ SERVER_IP=$(kubectl --kubeconfig ./kubeconfig -n netpol-demo get pod server -o jsonpath='{.status.podIP}')
$ kubectl --kubeconfig ./kubeconfig -n netpol-demo exec client -- wget -O- --timeout=3 http://$SERVER_IP
wget: can't connect to remote host (10.42.1.126): Connection refused
command terminated with exit code 1
```

**结果：** 仍然失败。原因是**出站（client→外部）也被 deny-all 阻断**。client 发起连接的 SYN 包根本发不出去，更谈不上 server 入站放行生效。

再放行 client 出站（**同时放行 DNS**，否则即使用 IP 访问也可能受影响；且若用 Service 名称访问更必须放行 DNS）：

```yaml
# ~/k3s-ops/tmp/netpol-client-egress.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-client-egress
  namespace: netpol-demo
spec:
  podSelector:
    matchLabels: {app: client}  # 策略作用于 client Pod
  policyTypes: ["Egress"]
  egress:
    # 放行 DNS（kube-system/coredns）
    - to:
        - namespaceSelector:
            matchLabels: {name: kube-system}
          podSelector:
            matchLabels: {k8s-app: kube-dns}
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    # 放行到 server 的 TCP 80
    - to:
        - podSelector:
            matchLabels: {app: server}
      ports:
        - protocol: TCP
          port: 80
```

应用后测试：

```bash
$ kubectl --kubeconfig ./kubeconfig apply -f /tmp/netpol-client-egress.yaml
networkpolicy.networking.k8s.io/allow-client-egress created

$ SERVER_IP=$(kubectl --kubeconfig ./kubeconfig -n netpol-demo get pod server -o jsonpath='{.status.podIP}')
$ kubectl --kubeconfig ./kubeconfig -n netpol-demo exec client -- wget -O- --timeout=3 http://$SERVER_IP
...
</body>
</html>
```

**结果：** 恢复连通（返回 httpd 页面）。至此实现“最小权限”：**只有 client 能主动访问 server:80，其它跨 Pod 流量一律拒绝**。

### 2.5 改前/改后对照

| 对照点 | 改前（无 NetworkPolicy） | 改后（deny-all + 精准放行） |
|---|---|---|
| **跨 Pod 连通性** | 全互通（默认） | 全部拒绝，**仅 client→server:80** 放行 |
| **安全边界** | 仅依赖 RBAC（操作权限） | **RBAC + NetworkPolicy 双重边界**（身份 + 网络） |
| **最小权限** | 宽松（攻击面大） | 精准到“源 Pod 标签 + 目标 Pod 标签 + 端口” |
| **DNS 可用性** | 正常 | 一旦拒绝 Egress，必须**显式放行 kube-dns** 才能用 Service 名称解析 |
| **排障复杂度** | 较低（默认通） | 略有上升，但更贴近生产安全要求 |
| **适用场景** | 开发测试环境、PoC | 多租户、生产敏感服务（DB、内部 API 等） |

---

## 3. namespaceSelector 的用法（跨命名空间访问）

有时需要放行**其他命名空间**的 Pod 访问本命名空间的服务。此时需配合 `namespaceSelector`。

示例思路（不在本次实测中强行跨命名空间，仅展示写法）：

```yaml
ingress:
  - from:
      - namespaceSelector:
          matchLabels: {team: backend}
        podSelector:
          matchLabels: {role: api-client}
      ports:
        - protocol: TCP
          port: 80
```

说明：**同时指定 `namespaceSelector` 和 `podSelector`** 时，匹配的是“满足命名空间标签 且 满足 Pod 标签”的来源。

> 若只想匹配某个命名空间的**全部 Pod**，可省略 `podSelector`：`namespaceSelector: {matchLabels: {name: other-ns}}`。

---

## 4. 排障清单

| 故障现象 | 可能原因 | 排查命令 | 处理建议 |
|---|---|---|---|
| **加了 NetworkPolicy 后全都连不上** | `deny-all` 覆盖过广且未放行 DNS/Egress | `kubectl --kubeconfig ./kubeconfig get networkpolicy -A`、`kubectl --kubeconfig ./kubeconfig -n <ns> exec <pod> -- nslookup kubernetes.default 2>&1` | 检查是否漏放行 `kube-system/coredns` 的 UDP/TCP 53 |
| **用 IP 能通，用 Service 名称不通** | Egress 未放行 DNS | 同上，直接 `nslookup <svc>` 测试 | 补充到 kube-dns 的 Egress 规则（必须带端口 53 UDP/TCP） |
| **client→server 仍连不上（已加 Ingress）** | **只加了 Ingress，忘了加 Egress**（client 出站被阻断） | 对比策略：检查 `allow-client-to-server`（作用于 server）和 `allow-client-egress`（作用于 client）是否都存在 | 同时为“发起方”（client）配置 Egress 到“接收方”（server） |
| **策略不生效** | CNI 插件不支持 NetworkPolicy（Flannel 部分版本需额外组件） | `kubectl --kubeconfig ./kubeconfig get pods -n kube-system | grep -E "cni|router|calico"`、查看集群 CNI | 确认集群是否启用 NetworkPolicy 支持。本环境实测生效，如仍不生效需排查 CNI |
| **namespaceSelector 匹配不到预期** | 命名空间缺少对应标签 | `kubectl --kubeconfig ./kubeconfig get ns --show-labels` | 给目标命名空间打上正确标签（如 `name=other-ns`） |
| **Pod 标签选错导致连不上** | `podSelector.matchLabels` 与实际 Pod 标签不一致 | `kubectl --kubeconfig ./kubeconfig -n <ns> get pod <pod> --show-labels` | 对齐标签（大小写、键值完全一致） |
| **只想放行某个命名空间全量却配了 podSelector** | 多加了限制条件 | 检查 `from` 块：若只需命名空间全量，**省略 `podSelector`** 仅保留 `namespaceSelector` | 简化规则，按最小但够用的原则编写 |

> **排障技巧：** 先用“临时全通”思路排除网络本身，再逐步加上 NetworkPolicy。也可临时去掉 deny-all 验证基础连通，再加回验证策略。

---

## 5. Rancher 对照

在 Rancher UI 中也能查看和管理 NetworkPolicy：

| 路径 | 对应 kubectl |
|---|---|
| **集群 → More Resources → networking.k8s.io → NetworkPolicies（按命名空间筛选 netpol-demo）** | `kubectl --kubeconfig ./kubeconfig get networkpolicy -n netpol-demo` |
| **NetworkPolicy 详情页** | 展示 `podSelector`、`policyTypes`、`ingress`/`egress` 规则清单（可视化编辑） |
| **命名空间详情（Labels）** | 查看命名空间标签（用于 `namespaceSelector`） |

> UI 编辑器适合初学理解字段，但建议熟悉 YAML 后再按最小权限原则编写，避免误配导致连通性中断。

---

## 6. 练习

1. **全通验证**：按 §2.1-2.2 步骤复现“默认全通”，用 `wget` 直连 Pod IP 成功。
2. **deny-all 生效**：应用 `deny-all` 后验证 client 无法访问 server 且 DNS 解析受影响，说明 Ingress+Egress 双向都被限制。
3. **最小权限还原**：按 §2.4 步骤补充 server Ingress + client Egress（含 kube-dns 放行），恢复 client→server 连通并解释“双向配合”的必要性。
4. **跨命名空间设计**：假设 `app-ns` 需放行 `monitor-ns` 的 Prometheus 抓取 `server:80`，写出最小化的 NetworkPolicy YAML（用 `namespaceSelector`）。
5. **只允许 Service 访问？**：思考“直接用 Pod IP 放行”和“通过 Service 名称访问”时 NetworkPolicy 的差异（提示：Service 本身不改 IP，策略匹配的是**源/目标 Pod 标签**）。
6. **排障实战**：故意漏掉 client Egress 规则，仅保留 server Ingress，复现“连不上但规则貌似没错”的现象并用排障清单定位。
7. **安全思考**：结合第 32 章（Rancher 多租户/RBAC），说明为什么“RBAC（谁能操作） + NetworkPolicy（谁能通网络）”才构成更完整的多租户安全边界。

---

## 附录：本章真实采集片段

- 命名空间：`netpol-demo`（带标签 `name=netpol-demo`）
- Pod：`client`（10.42.1.127，标签 `app: client`）、`server`（10.42.1.126，标签 `app: server`，端口 80）
- Service：`server`（80→80）
- NetworkPolicy：
  - `deny-all`：`podSelector: {}`，`policyTypes: ["Ingress","Egress"]`
  - `allow-client-to-server`：作用于 `app: server`，Ingress 仅允许 `app: client` 访问 TCP 80
  - `allow-client-egress`：作用于 `app: client`，Egress 放行 kube-dns（UDP/TCP 53）+ server（TCP 80）
- 连通性实测：deny-all 后 `wget` 失败（exit 1）；双向放行后成功返回 httpd 页面

> 演示结束后可按需清理：`kubectl --kubeconfig ./kubeconfig delete ns netpol-demo`