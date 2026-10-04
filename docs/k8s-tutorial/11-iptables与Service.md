# 11 Service 与 iptables 深入：kube-proxy 的转发实现

## 本章目标

- 理解 kube-proxy 用 **iptables** 实现 Service 的核心机制（DNAT + 概率负载均衡）
- 认识与 Service 有关的 iptables 链结构：KUBE-SERVICES / KUBE-SVC-* / KUBE-SEP-* / KUBE-NODEPORTS / KUBE-POSTROUTING
- 学会在节点上抓取、阅读、追踪这些规则，把「Service 概念」落到「节点真实规则」
- 理解 NodePort 与 ClusterIP 在 iptables 层面的区别

> 前置：建议先完成第 04 章（网络与通讯），理解 Service/NodePort/Ingress 的上层概念。本章是它下面的「实现层」。
> 适用：本集群 2 节点均适用；以下命令在任一节点执行（规则由各节点 kube-proxy 独立维护）。

---

## 1. 为什么 Service 是「虚拟」的

Service 的本质：**一段写入 etcd 的期望状态 + 各节点 kube-proxy 据此生成的转发规则**。虚拟 IP（ClusterIP 10.43.x.x）不挂在任何网卡上，真正让流量到达 Pod 的是节点上的 iptables 规则。

```text
客户端请求 Service IP:Port
        │
        ▼
节点网卡 → PREROUTING 链 → KUBE-SERVICES（匹配"这是哪个 Service"）
        │
        ▼
    KUBE-SVC-XXXXX（本 Service 的"流量分配器"，按概率挑一个端点）
        │
        ▼
    KUBE-SEP-XXXXX（某个 Pod 端点，执行 DNAT 把目标 IP 换成 Pod IP）
        │
        ▼
    Pod (10.42.x.x)
```

每一个 Service、每一个 Endpoint，kube-proxy 都会维护几条链。**链的名字由 Service 的哈希生成**（规则里注释 `/* lab/nginx-svc */` 能帮你认出是谁）。

## 2. 相关 iptables 概念速览

| 概念 | 含义 |
|------|------|
| **表（table）** | 按功能分：`nat`（地址转换）、`filter`（过滤）、`mangle`（标记）等 |
| **链（chain）** | 表内的规则序列；内置链 PREROUTING/INPUT/FORWARD/OUTPUT/POSTROUTING + 自定义链 |
| **DNAT** | 修改目标地址：把 `ClusterIP:80` 改成 `PodIP:80`（进 Pod 前） |
| **MASQUERADE/SNAT** | 修改源地址：Pod 回包时把源换成节点 IP（出节点时） |
| **MARK** | 给包打标记（如 0x4000），供后续链判断 |

内核包经过路径（本集群用到的）：

```text
入向包:  PREROUTING → (路由) → FORWARD → POSTROUTING
本机发起: OUTPUT → (路由) → POSTROUTING
```

NAT 表里，PREROUTING 和 OUTPUT 链最顶部都挂着 `KUBE-SERVICES` —— 这是所有 Service 流量的总入口。

## 3. 本集群实站对照

> 本集群 kube-proxy 没有独立进程：它作为 k3s 内嵌组件运行。验证：
>
> ```bash
> vagrant ssh k3s-demo-server-1 -- "sudo ps -eo comm | grep -i kube-proxy"   # 无输出 = 无独立进程
> vagrant ssh k3s-demo-server-1 -- "sudo ss -ltnp | grep 10249"              # 未监听 metrics 端口
> ```
>
> k3s 的 kube-proxy 逻辑在 `k3s-server`/`k3s-agent` 进程内（`kubernetes.io/kube-proxy` 组件打包进主进程）。

### 3.1 环境与操作对象

沿用第 03/04 章的实验资源：`lab/nginx-demo`（5 副本）+ `lab/nginx-svc`（NodePort `80:32062`，ClusterIP `10.43.23.169`）。

```bash
export KUBECONFIG=./kubeconfig
kubectl -n lab get svc nginx-svc
kubectl -n lab get endpoints nginx-svc
```

```text
NAME        TYPE       CLUSTER-IP     EXTERNAL-IP   PORT(S)        AGE
nginx-svc   NodePort   10.43.23.169   <none>        80:32062/TCP   24h

NAME        ENDPOINTS
nginx-svc   10.42.0.10:80,10.42.0.13:80,10.42.0.4:80,10.42.0.5:80,10.42.0.6:80
```

### 3.2 总入口：KUBE-SERVICES 链

```bash
vagrant ssh k3s-demo-server-1 -- "sudo iptables -t nat -L KUBE-SERVICES -n | grep -i nginx"
```

预期输出（真实，每行是一个 Service 的 ClusterIP 匹配）：

```text
KUBE-SVC-CG5I4G2RS3ZVWGLK  tcp  --  0.0.0.0/0  10.43.197.40   /* ingress-nginx/ingress-nginx-controller:http cluster IP */  tcp dpt:80
KUBE-SVC-EDNDUDH2C75GIR6O  tcp  --  0.0.0.0/0  10.43.197.40   /* ingress-nginx/ingress-nginx-controller:https cluster IP */ tcp dpt:443
KUBE-SVC-GPUC54NPJOBC5I6P  tcp  --  0.0.0.0/0  10.43.23.169   /* lab/nginx-svc cluster IP */ tcp dpt:80
```

解读：

- `dst=10.43.23.169 tcp dpt:80`：匹配「目标 ClusterIP 是 nginx-svc」的包
- 命中后跳转 `KUBE-SVC-GPUC54NPJOBC5I6P`（该 Service 的分配链）
- 注释 `/* lab/nginx-svc cluster IP */` 是 kube-proxy 写规则的标注，**排障时靠它认链**

查看整条链确认它是入口（挂在 PREROUTING 与 OUTPUT 顶部）：

```bash
vagrant ssh k3s-demo-server-1 -- "sudo iptables -t nat -L -n | sed -n '/Chain PREROUTING/,/^$/p' | head -4"
```

```text
Chain PREROUTING (policy ACCEPT)
target         prot opt source          destination
KUBE-SERVICES  all  --  0.0.0.0/0       0.0.0.0/0   /* kubernetes service portals */
```

### 3.3 负载均衡链：KUBE-SVC-XXXXX（概率分配）

```bash
vagrant ssh k3s-demo-server-1 -- "sudo iptables -t nat -L KUBE-SVC-GPUC54NPJOBC5I6P -n --line-numbers"
```

预期输出（真实 —— 注意每一行的概率）：

```text
Chain KUBE-SVC-GPUC54NPJOBC5I6P (2 references)
num  target                    prot opt source         destination
1    KUBE-MARK-MASQ            tcp  --  !10.42.0.0/16  10.43.23.169   /* lab/nginx-svc cluster IP */ tcp dpt:80
2    KUBE-SEP-EC447TFDGNPKABVG all  --  0.0.0.0/0      0.0.0.0/0      /* lab/nginx-svc -> 10.42.0.10:80 */ statistic mode random probability 0.20000000019
3    KUBE-SEP-C6WHH4ORMXZW45OX all  --  0.0.0.0/0      0.0.0.0/0      /* lab/nginx-svc -> 10.42.0.13:80 */ statistic mode random probability 0.25000000000
4    KUBE-SEP-MBLO2FAFZIOQQXEG all  --  0.0.0.0/0      0.0.0.0/0      /* lab/nginx-svc -> 10.42.0.4:80 */ statistic mode random probability 0.33333333349
5    KUBE-SEP-MG7ZHCFDI445PSGA all  --  0.0.0.0/0      0.0.0.0/0      /* lab/nginx-svc -> 10.42.0.5:80 */ statistic mode random probability 0.50000000000
6    KUBE-SEP-KSGHIK33AHWLCMEU all  --  0.0.0.0/0      0.0.0.0/0      /* lab/nginx-svc -> 10.42.0.6:80 */
```

**这是 kube-proxy 负载均衡的精髓**：

- 5 个副本 → 5 条 `KUBE-SEP-*` 跳转，从上到下用 **`statistic mode random probability`** 分配
- 概率依次是 `1/5 → 1/4 → 1/3 → 1/2 → 1`（最后一条不再随机）：第一个命中 20%，剩下的 25%... 直到最后一个 100%
- 这正是「统计平均 ≈ 轮询」的实现 —— 每条规则只有 1/剩余数 的概率被选中，总命中率对每个端点都是 20%

第 1 行 `KUBE-MARK-MASQ`：当**来源不是 Pod 网段**（`!10.42.0.0/16`，如外部客户端）访问 ClusterIP 时打标记 0x4000，让回包也走 MASQUERADE（见 3.6）。

**动手验证分配**：在 server 节点上循环请求 ClusterIP，关注到达的 Pod IP：

```bash
vagrant ssh k3s-demo-server-1 -- "for i in \$(seq 1 10); do curl -s http://10.43.23.169/ >/dev/null; done; sudo iptables -t nat -L KUBE-SVC-GPUC54NPJOBC5I6P -n -v | tail -6"
```

`-v` 列（pkts/bytes）会显示每个端点的命中次数，多次访问后各 SEP 行的 pkts 会大致均衡分布。

### 3.4 端点链：KUBE-SEP-XXXXX（DNAT 到 Pod）

每个 Endpoint 一条链，做真正的地址转换：

```bash
vagrant ssh k3s-demo-server-1 -- "sudo iptables -t nat -L KUBE-SEP-EC447TFDGNPKABVG -n"
```

预期输出：

```text
Chain KUBE-SEP-EC447TFDGNPKABVG (1 references)
target          prot opt source   destination
KUBE-MARK-MASQ  all  --  10.42.0.10  0.0.0.0/0   /* lab/nginx-svc */
DNAT            tcp  --  0.0.0.0/0   0.0.0.0/0   /* lab/nginx-svc */ tcp to:10.42.0.10:80
```

- 第 1 行：**从该 Pod 发出的**包打 MASQ 标记（Pod 回包时要用）
- 第 2 行：`tcp to:10.42.0.10:80` —— **DNAT**：把目标从 `10.43.23.169:80` 改写为 `10.42.0.10:80`。到这里流量才真正指向 Pod

### 3.5 NodePort：KUBE-NODEPORTS 与 KUBE-EXT-XXXXX

NodePort 是「每个节点都监听一个端口」的入口，链上独立于 ClusterIP：

```bash
vagrant ssh k3s-demo-server-1 -- "sudo iptables -t nat -L KUBE-NODEPORTS -n | grep -iE 'nginx'"
```

预期输出（注意 30080/30444 是 ingress-nginx，32062 是 lab/nginx-svc）：

```text
KUBE-EXT-CG5I4G2RS3ZVWGLK  tcp  --  0.0.0.0/0  0.0.0.0/0  /* ingress-nginx/ingress-nginx-controller:http */ tcp dpt:30080
KUBE-EXT-EDNDUDH2C75GIR6O  tcp  --  0.0.0.0/0  0.0.0.0/0  /* ingress-nginx/ingress-nginx-controller:https */ tcp dpt:30444
KUBE-EXT-GPUC54NPJOBC5I6P  tcp  --  0.0.0.0/0  0.0.0.0/0  /* lab/nginx-svc */ tcp dpt:32062
```

`KUBE-EXT-*` 链是 NodePort 的「外部入口包装」：

```bash
vagrant ssh k3s-demo-server-1 -- "sudo iptables -t nat -L KUBE-EXT-GPUC54NPJOBC5I6P -n"
```

预期输出：

```text
Chain KUBE-EXT-GPUC54NPJOBC5I6P (1 references)
target                      prot opt source   destination
KUBE-MARK-MASQ              all  --  0.0.0.0/0  0.0.0.0/0  /* masquerade traffic for lab/nginx-svc external destinations */
KUBE-SVC-GPUC54NPJOBC5I6P   all  --  0.0.0.0/0  0.0.0.0/0
```

解读：外部流量进 NodePort → 先打 MASQ 标记 → 转入同一个 `KUBE-SVC-*` 分配链（与 ClusterIP 共用分配逻辑）。

NodePort 实测（宿主机）：

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://192.168.56.10:32062/   # 200
```

### 3.6 回包与 SNAT：KUBE-POSTROUTING + 0x4000 标记

Pod 回包目标地址是「请求者的地址」（可能是外部客户端），需要在出节点时做源地址转换（SNAT/MASQUERADE），否则 Pod 不会把回包路由回客户端：

```bash
vagrant ssh k3s-demo-server-1 -- "sudo iptables -t nat -L KUBE-POSTROUTING -n"
```

预期输出：

```text
Chain KUBE-POSTROUTING (1 references)
target      prot opt source   destination
RETURN      all  --  0.0.0.0/0  0.0.0.0/0   mark match ! 0x4000/0x4000
MARK        all  --  0.0.0.0/0  0.0.0.0/0   MARK xor 0x4000
MASQUERADE  all  --  0.0.0.0/0  0.0.0.0/0   /* kubernetes service traffic requiring SNAT */ random-fully
```

机制：

1. 第 1 行：**没打 0x4000 标记**的包直接 RETURN（不动）—— 例如 Pod↔Pod 的内部流量
2. 第 2 行：打了标记的包再 XOR 一次，清除标记（避免二次处理）
3. 第 3 行：对需要 SNAT 的包做 **MASQUERADE**（把源地址换成节点 IP），保证回包能原路返回

`KUBE-MARK-MASQ` 链就是「打 0x4000 标记」的地方：

```bash
vagrant ssh k3s-demo-server-1 -- "sudo iptables -t nat -L KUBE-MARK-MASQ -n"
```

```text
Chain KUBE-MARK-MASQ (53 references)
target  prot opt source   destination
MARK    all  --  0.0.0.0/0  0.0.0.0/0   MARK or 0x4000
```

（53 references = 集群里 53 处 Service 规则引用它。）

### 3.7 一个包的完整旅程（背下来）

```text
外部客户端 curl 192.168.56.10:32062/
 1. 节点网卡接收 → PREROUTING → KUBE-NODEPORTS 匹配 dpt:32062
 2. → KUBE-EXT-GPUC54NPJOBC5I6P: 打 0x4000 标记
 3. → KUBE-SVC-GPUC54NPJOBC5I6P: 概率选一个端点 → KUBE-SEP-XXX
 4. → KUBE-SEP-XXX: DNAT 目标改为 10.42.0.x:80
 5. 路由到 Pod 网段 → flannel 隧道转发到目标节点
 6. Pod 回包 → POSTROUTING → 因 0x4000 标记 MASQUERADE → 源改为节点 IP
 7. 响应原路返回客户端

集群内 Pod 访问 ClusterIP 10.43.23.169:80 的路径更短:
 OUTPUT → KUBE-SERVICES 匹配 ClusterIP → SVC → SEP(DNAT) → Pod
```

### 3.8 规则随资源变化（观察实验）

```bash
# 扩缩容后观察 SVC 链的 SEP 条目与概率变化
kubectl -n lab scale deploy nginx-demo --replicas=3
sleep 5
vagrant ssh k3s-demo-server-1 -- "sudo iptables -t nat -L KUBE-SVC-GPUC54NPJOBC5I6P -n | tail -4"
# 应看到只剩 3 条 SEP 跳转, 概率变为 1/3 → 1/2 → 1

# 删除 Service 后该链整条消失
kubectl -n lab delete svc nginx-svc
vagrant ssh k3s-demo-server-1 -- "sudo iptables -t nat -L KUBE-NODEPORTS -n | grep 32062"   # 无输出
# 恢复
kubectl -n lab expose deployment nginx-demo --type=NodePort --port=80 --target-port=80 --name=nginx-svc
```

> ⚠️ 别忘了把副本数改回 5（下一章及以后练习要用）。

## 4. Rancher 界面对照

iptables 规则在节点内核里，Rancher UI 没有直接页面。对照方式：

- **Service Discovery → Services**：看到 Service/NodePort —— 每条记录背后就是本章的一组链
- **节点 Shell**：Rancher 的 Node → 某节点 → **⋮ → Launch Kubectl / Execute Shell**，可以进节点跑 `iptables` 命令（需要 root）
- 流量不通时排查顺序：UI 看 Service/Endpoints → 节点上 `kubectl get endpoints` → `iptables -t nat -L KUBE-SERVICES -n`（规则是否存在）→ `-L KUBE-SVC-*`（分配链是否存在）

## 5. 小结

- Service 是「期望状态 + iptables 规则」：ClusterIP 不挂网卡，转发全靠节点上的规则
- 三层链：`KUBE-SERVICES`（总入口匹配）→ `KUBE-SVC-*`（概率分配）→ `KUBE-SEP-*`（DNAT 到 Pod）
- 负载均衡 = iptables `statistic mode random` 概率链（1/5→1/4→1/3→1/2→1）
- NodePort 通过 `KUBE-NODEPORTS → KUBE-EXT-*` 进入同一个分配链
- 回包靠 0x4000 标记 + `KUBE-POSTROUTING` 的 MASQUERADE
- 所有链名后注释 `/* namespace/服务名 */`，是排障认链的第一线索

## 动手练习

1. 在 server-1 上执行 `sudo iptables -t nat -L KUBE-SERVICES -n | grep kube-dns`，找出集群 DNS Service 的链名与 ClusterIP。
2. 在 agent-1 上重复 3.3 的命令，观察该节点的 `KUBE-SVC-GPUC54NPJOBC5I6P` 链是否与 server-1 一致（kube-proxy 每节点独立维护）。
3. 用 `curl` 多次请求 NodePort，再用 `-L ... -n -v` 观察各 SEP 的 pkts 计数是否大致均衡。
4. 新创建一个 Service（如 `kubectl -n lab expose deploy probe-demo --port=80 --name=probe-svc`），观察 KUBE-SERVICES 链新增的行与注释。
5. 思考题：为什么概率链设计成 1/5 → 1/4 → 1/3 → 1/2 → 1 而不是每条都写 20%？

<details>
<summary>参考答案</summary>

1. `*/*:kube-dns cluster IP tcp dpt:53` 之类，链名形如 `KUBE-SVC-XXX`，ClusterIP 为 10.43.0.10。
2. 应一致（同一 Service 由两台节点各自的 kube-proxy 生成相同规则）。
3. 多次请求后各 SEP 行 pkts 数值接近（统计平均）。
4. 新增 `/* lab/probe-svc cluster IP */` 一行，指向新的 `KUBE-SVC-*` 链。
5. 每条规则若固定 20%，前 5 条各自命中 20%，但**第 5 条之后的包会被丢弃**（无后续规则）；概率递减保证「前几条随机、最后一条兜底全收」，且对每个端点命中率正好 1/N。删除/新增端点时 kube-proxy 会重建整条链。
</details>