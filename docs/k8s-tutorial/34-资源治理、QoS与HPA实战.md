# 34 资源治理、QoS 与 HPA 实战

## 本章目标

- 理解 Kubernetes 资源治理的核心：`requests`（请求）与 `limits`（限制）的区别及调度/驱逐逻辑
- 掌握 Pod QoS（Quality of Service）三类：Guaranteed、Burstable、BestEffort 及其判定规则
- 理解 LimitRange 与 ResourceQuota 的作用边界（命名空间级资源约束）
- 掌握 HorizontalPodAutoscaler（HPA）工作原理、指标类型（Resource/Utilization）及扩缩容行为
- 结合本集群真实采集，演示 requests/limits、QoS 判定、LimitRange/ResourceQuota、HPA 基础配置与现象
- 掌握 OOMKilled、资源不足导致 Pending 等常见排障思路

> 本章所有命令统一使用 `kubectl --kubeconfig ./kubeconfig`。文档中路径统一用 `~/k3s-ops` 表示。

---

## 1. requests 与 limits 概念

Kubernetes 为每个容器的 CPU 和内存设置两个维度的资源约束：

| 字段 | 含义 | 影响范围 |
|---|---|---|
| `requests` | 容器对资源的**最小需求量**（保底）。 | **调度器依据**：Node 必须有足够的可用资源（未分配 requests 总和）才能调度 Pod。也影响节点资源预留视角。 |
| `limits` | 容器可使用的**最大资源量**（上限）。 | **运行时限制**：若超过 limits，容器会被 CPU 节流（CPU 是可压缩资源），内存超过 limits 则会被 **OOMKilled**（内存是不可压缩资源）。 |

**CPU 单位**：`m`（millicore），1000m = 1 核。**内存单位**：Mi、Gi、M、G 等。

> 核心原则：`requests` 影响**调度（能不能跑）**，`limits` 影响**运行时约束（跑到多少会被限制/杀死）**。

---

## 2. QoS（Quality of Service）

Kubernetes 根据容器的 `requests`/`limits` 是否**全等**、是否**都设置**，将 Pod 划分为三种 QoS 等级。该等级会影响节点资源不足时的**驱逐优先级**（优先级从低到高：BestEffort < Burstable < Guaranteed，BestEffort 最先被驱逐）。

### 2.1 QoS 判定规则

| QoS 类别 | 判定条件 | 驱逐优先级 |
|---|---|---|
| **Guaranteed（保证）** | Pod 内**所有容器**的 CPU 和内存的 `requests == limits`（且两者都必须显式设置）。 | **最高**（最不容易被驱逐） |
| **Burstable（可突发）** | Pod **不满足 Guaranteed**，但**至少有一个容器**设置了 `requests`（CPU 或内存任意一个）。 | 中等 |
| **BestEffort（尽力而为）** | Pod 内**所有容器**的 CPU 和内存都**未设置** `requests` 和 `limits`。 | **最低**（资源紧张时最先被驱逐） |

> 注意：CPU 和内存是分别判定的。要达成 Guaranteed，**每个容器的每种资源**都必须 `requests==limits`。

### 2.2 真实实测：Burstable

本章创建演示 Deployment `php-apache`，显式设置 `requests` 和 `limits`（不全等）：

```yaml
# ~/k3s-ops/tmp/hpa-demo.yaml（片段）
resources:
  requests: {cpu: 200m, memory: 128Mi}
  limits: {cpu: 500m, memory: 256Mi}
```

实际部署后，Pod 的 QoS 为 Burstable：

```bash
$ kubectl --kubeconfig ./kubeconfig -n hpa-demo describe pod php-apache-6c96b9c959-82jmg | grep "QoS Class"
QoS Class:                   Burstable
```

**解析（真实值）：**
- 设置了 `requests` 和 `limits`，但 `200m != 500m`、`128Mi != 256Mi` → 不满足 Guaranteed
- 至少有 requests → 满足 Burstable

如果将其改为 `requests==limits`（例如 `cpu: 500m/memory: 256Mi`），则 QoS 将变为 **Guaranteed**。

### 2.3 QoS 对驱逐的影响（原理）

节点内存/CPU 压力达到驱逐阈值时，kubelet 按 QoS 优先级驱逐 Pod：**BestEffort → Burstable → Guaranteed**。Burstable/Guaranteed 内部也会按实际资源使用超出 requests 的程度排序。这个顺序在生产资源规划时非常关键。

---

## 3. LimitRange 与 ResourceQuota

这两个是**命名空间级**的资源约束，用于防止单个 Pod/容器过度消耗资源或某个命名空间过度占用集群资源。

| 对象 | 作用范围 | 典型用途 |
|---|---|---|
| **LimitRange** | 命名空间内的**每个容器/Pod** | 为未显式设置 `requests/limits` 的容器设置**默认值/最大最小限制**，强制规范资源申请 |
| **ResourceQuota** | 命名空间**整体** | 限制命名空间内所有资源的**总量**（requests.cpu 总和、limits.memory 总和、Pod 数量等），防止某个团队/项目吃满集群 |

> 区别：LimitRange 管“单个”，ResourceQuota 管“总量”。

### 3.1 LimitRange 实测

在 `hpa-demo` 命名空间创建 LimitRange，为未显式指定的容器自动注入默认 requests/limits：

```yaml
# ~/k3s-ops/tmp/lr-quota.yaml（LimitRange 部分）
apiVersion: v1
kind: LimitRange
metadata:
  name: lr
  namespace: hpa-demo
spec:
  limits:
    - default: {cpu: 300m, memory: 192Mi}        # 未显式指定 limits 时的默认值
      defaultRequest: {cpu: 150m, memory: 96Mi} # 未显式指定 requests 时的默认值
      type: Container
```

应用后，LimitRange 生效：

```bash
$ kubectl --kubeconfig ./kubeconfig apply -f /tmp/lr-quota.yaml
limitrange/lr created
```

> 注意：LimitRange 只对**后续创建**且**未显式设置**资源的容器生效，不会回溯修改已存在的 Pod。

### 3.2 ResourceQuota 实测

限制 `hpa-demo` 命名空间的总资源配额：

```yaml
# ~/k3s-ops/tmp/rq.yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: rq
  namespace: hpa-demo
spec:
  hard:
    requests.cpu: "1"        # CPU requests 总和上限 1 核
    requests.memory: 512Mi   # 内存 requests 总和上限 512Mi
    limits.cpu: "2"          # CPU limits 总和上限 2 核
    limits.memory: 1Gi       # 内存 limits 总和上限 1Gi
    pods: "5"                # 最大 Pod 数量 5
```

应用后：

```bash
$ kubectl --kubeconfig ./kubeconfig apply -f /tmp/rq.yaml
resourcequota/rq created
```

ResourceQuota 生效后，若尝试创建超出配额的资源（如第 6 个 Pod 或 requests 总和超标），API Server 将直接拒绝（`403 Forbidden: exceeded quota`）。

> **配合使用建议**：通常先用 LimitRange 统一默认值，再用 ResourceQuota 限定命名空间总配额，实现“统一规范 + 总量管控”。

---

## 4. HorizontalPodAutoscaler（HPA）基础

HPA 用于**根据资源利用率或其他指标自动调整 Deployment/ReplicaSet 的副本数**，实现弹性伸缩（Scale Out/In）。

### 4.1 HPA 工作原理

HPA Controller 每隔约 15s（默认同步周期）从 Metrics API 获取目标指标（如 CPU 利用率 %），计算期望副本数：

```text
期望副本数 = ceil( 当前副本数 × ( 当前指标值 / 目标指标值 ) )
```

例如：当前 1 副本，CPU 平均利用率 80%，目标 50% → ceil(1×(80/50)) = 2 副本（扩容）。

扩缩容存在冷却窗口（`scaleDown`/`scaleUp` stabilization）以避免抖动。生产环境常配合自定义指标（v2 API）实现更精细的伸缩策略。

### 4.2 HPA 指标类型（v2 API）

本章使用 `autoscaling/v2`（推荐）：

| 指标类型 | 示例 | 说明 |
|---|---|---|
| `Resource` | `name: cpu`，`target.type: Utilization`，`averageUtilization: 50` | 基于容器资源利用率（当前利用率 vs requests 的百分比） |
| `Pods` | 按 Pod 自定义指标平均值 | 适用于每 Pod 业务指标（如 QPS/连接数） |
| `Object` | 外部对象指标（如 Ingress 请求速率） | 跨资源指标 |
| `External` | Prometheus/外部监控指标 | 第三方指标源 |

> `averageUtilization` 是相对于 `requests` 而不是 `limits` 计算的（CPU 利用率 % = (实际使用 CPU)/requests × 100%）。

### 4.3 真实实测：创建 HPA

为 `php-apache` Deployment 创建 HPA：目标 CPU 利用率 50%，最小 1 副本，最大 3 副本。

```yaml
# ~/k3s-ops/tmp/hpa-scale.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: php-apache
  namespace: hpa-demo
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: php-apache
  minReplicas: 1
  maxReplicas: 3
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
```

应用并观察初始状态：

```bash
$ kubectl --kubeconfig ./kubeconfig apply -f /tmp/hpa-scale.yaml
horizontalpodautoscaler.autoscaling/php-apache created

$ kubectl --kubeconfig ./kubeconfig -n hpa-demo get hpa
NAME         REFERENCE               TARGETS              MINPODS   MAXPODS   REPLICAS   AGE
php-apache   Deployment/php-apache   cpu: <unknown>/50%   1         3         0          0s

$ kubectl --kubeconfig ./kubeconfig -n hpa-demo get hpa
NAME         REFERENCE               TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
php-apache   Deployment/php-apache   cpu: 0%/50%   1         3         1          36s
```

**解释（真实采集）：**
- 刚创建时 Metrics API 尚未采集到 Pod 的 CPU 指标，显示 `<unknown>`
- 30s 左右同步后，目标变为 `cpu: 0%/50%`，当前副本数 `REPLICAS=1`（空载）

HPA 只有在指标可用（Metrics Server 正常运行）时才能计算扩缩容决策。本集群已部署 Metrics Server（生产可用），因此能正常获取 CPU/Memory 指标。

### 4.4 扩容触发原理（示意）

当负载增加（例如用 `ab`、`hey`、`k6` 对 Service `php-apache` 压测）时，Pod CPU 平均利用率会超过 50%。假设达到 80%：
- ceil(1×(80/50))=2 → HPA 将 Deployment 副本扩到 2
- 压力继续上升到 120%（相对 requests）：ceil(2×(120/50))=5，但 `maxReplicas=3`，因此扩到 3
- 压力下降后，利用率回落，HPA 会逐步缩容至 `minReplicas=1`

> 本章未做大流量压测（避免环境波动），重点是**配置方式、字段含义与现象观察**。生产压测时建议配合 `--horizontal-pod-autoscaler-downscale-stabilization` 等参数控制抖动。

---

## 5. OOMKilled 与资源不足排障

资源相关的常见故障及排查思路：

| 故障现象 | 常见原因 | 排查命令 | 处理建议 |
|---|---|---|---|
| **`OOMKilled`（容器被杀死）** | 内存超过 `limits`，内核 OOM Killer 终止容器 | `kubectl --kubeconfig ./kubeconfig describe pod <pod>`（查看 `Last State: Terminated`、`Reason: OOMKilled`、`Exit Code: 137`） | 提升 `limits.memory` 或优化应用内存使用；优先分析内存泄漏/峰值 |
| **Pod 一直 `Pending`** | 节点 CPU/Memory 可分配不足（requests 无法满足）、污点/亲和性、PVC 未绑定 | `kubectl --kubeconfig ./kubeconfig describe pod <pod>` → `Events`；`kubectl --kubeconfig ./kubeconfig top nodes`、`kubectl --kubeconfig ./kubeconfig describe node <n>` | 降低 requests、扩容节点、调整调度约束 |
| **`ImagePullBackOff`/`ErrImagePull`** | 镜像拉取失败（网络/权限/镜像名错误） | `describe pod` Events、`kubectl --kubeconfig ./kubeconfig get events --sort-by=.metadata.creationTimestamp -n <ns>` | 检查镜像仓库可达性、Secret（imagePullSecrets）、镜像地址 |
| **HPA 显示 `<unknown>`** | Metrics Server 未就绪/网络异常/指标采集延迟 | `kubectl --kubeconfig ./kubeconfig get pods -n kube-system -l k8s-app=metrics-server`、`kubectl --kubeconfig ./kubeconfig top pods -n <ns>` | 等待 Metrics Server 就绪（通常 1-2 分钟），检查其日志 |
| **HPA 不扩容/不缩容** | 指标未达阈值、`minReplicas==maxReplicas`、stabilization window、readinessProbe 不就绪导致有效 Pod 数不足 | `kubectl --kubeconfig ./kubeconfig describe hpa <name> -n <ns>`（Conditions/Events）、`kubectl --kubeconfig ./kubeconfig top pods -n <ns>` | 检查当前利用率是否真的超标、有效副本（Ready）数量是否满足计算条件 |

> **OOMKilled 判定要点：** ExitCode `137` = 128+9（SIGKILL）。在 `describe pod` 的 `Last State.Terminated` 可清晰看到 `Reason: OOMKilled`。

---

## 6. 改前/改后对照

| 对照维度 | 改前（无资源约束） | 改后（有资源治理） |
|---|---|---|
| **调度可预期性** | Pod 随意抢占资源，调度器仅看节点剩余裸容量，容易导致资源争抢 | `requests` 明确最小需求，调度更可预期，避免过度调度 |
| **运行时稳定性** | 单个容器内存暴涨可能导致整节点 OOM，影响其他 Pod | `limits` 做硬限制，超限容器先被 OOMKilled（隔离爆炸半径） |
| **驱逐优先级** | 无法区分关键/非关键负载 | QoS（Guaranteed/Burstable/BestEffort）指导 kubelet 驱逐顺序 |
| **命名空间管控** | 团队/项目可无限消耗集群资源 | ResourceQuota 限定总量，LimitRange 统一规范，杜绝资源申请随意 |
| **弹性能力** | 副本数固定，无法应对流量波动 | HPA 按实际负载（CPU 利用率）自动扩缩容，在成本与可用性之间取得平衡 |
| **故障定位** | OOM、资源争抢排障困难 | `describe pod/node/hpa` + QoS/requests/limits 提供清晰线索 |

---

## 7. Rancher 界面对照

在 Rancher UI 中可直观查看资源配置与 HPA：

| 路径 | 对应 kubectl |
|---|---|
| **集群 → Workload → Deployments（命名空间 hpa-demo）→ Pod 详情 → Resources** | `kubectl --kubeconfig ./kubeconfig -n hpa-demo describe pod <pod>`（Requests/Limits） |
| **集群 → More Resources → core → LimitRanges（按命名空间筛选）** | `kubectl --kubeconfig ./kubeconfig get limitrange -n hpa-demo` |
| **集群 → More Resources → core → ResourceQuotas** | `kubectl --kubeconfig ./kubeconfig get resourcequota -n hpa-demo` |
| **集群 → More Resources → autoscaling → HorizontalPodAutoscalers** | `kubectl --kubeconfig ./kubeconfig get hpa -n hpa-demo` |
| **Workload → Deployments → 弹性伸缩（HPA）页签** | 查看当前副本数、目标利用率、指标等 |

> Rancher UI 可直接创建/编辑 HPA、查看指标趋势，适合日常巡检。

---

## 动手练习

1. **QoS 判定**：按 §2.2 复现 Burstable，修改为 `requests==limits`（Guaranteed），用 `describe pod` 验证 QoS 类别变化并解释判定规则。
2. **requests vs limits 差异**：创建两个容器（一个只设 requests、一个只设 limits、不设的情况），观察 QoS 分类并说明调度/运行时差异。
3. **LimitRange 生效验证**：创建一个不带 resources 的 Pod，观察其是否被 LimitRange 自动注入默认 requests/limits（注意仅对新建生效）。
4. **ResourceQuota 超额验证**：尝试在 `hpa-demo` 创建第 6 个 Pod（当前 pods 硬配额 5），观察 API 返回的报错信息并分析原因。
5. **OOMKilled 模拟**：创建内存 limits 较小（如 32Mi）的 busybox，运行 `dd if=/dev/zero of=/tmp/big bs=1M count=100`，观察 Pod 是否变为 `OOMKilled`、ExitCode 137。
6. **HPA 行为推理**：假设当前 2 副本，CPU 平均利用率 120%，目标 50%，maxReplicas 5，计算期望副本数并解释是否会触发扩容。
7. **Metrics 可用性排障**：执行 `kubectl --kubeconfig ./kubeconfig top nodes` 和 `kubectl --kubeconfig ./kubeconfig top pods -n hpa-demo`，确认指标可采集；若 `top` 超时，思考可能原因并给出排查思路。

<details>
<summary>参考答案</summary>

1. 令单容器 `requests==limits`（cpu/memory 都设）→ QoS 变为 `Guaranteed`；`kubectl -n hpa-demo describe pod ... | grep 'QoS Class'` 验证。
2. 只设 `requests` → `Burstable`；只设 `limits`（未设 requests 时 requests 默认等于 limits，所有资源都如此则为 `Guaranteed`）；两者都不设 → `BestEffort`。调度按 **requests**，运行时上限按 **limits**。
3. 不带 `resources` 的新建 Pod 会被 LimitRange 注入默认 `requests`/`limits`（仅对**新建** Pod 生效，已存在的不会改）。
4. 创建第 6 个 Pod 被拒，报错类似：`exceeded quota: rq, requested: pods=1, used: pods=5, limited: pods=5`。
5. busybox（`limits.memory: 32Mi`）跑 `dd if=/dev/zero of=/tmp/big bs=1M count=100` → 触发 `OOMKilled`，`ExitCode 137`。
6. 期望副本 = `ceil(当前副本 × 当前利用率 / 目标利用率)` = `ceil(2 × 120% / 50%)` = `ceil(4.8)` = **5**（≤ maxReplicas 5），会扩容到 5。
7. `top nodes` / `top pods` 能正常返回即指标可用；若超时：查 `kube-system` 的 `metrics-server` 是否 Ready、`kubectl get apiservice v1beta1.metrics.k8s.io`、看 metrics-server 日志与网络连通性。

</details>

---

## 附录：本章真实采集片段

- 命名空间：`hpa-demo`
- Deployment/Service：`php-apache`
- Pod：`php-apache-6c96b9c959-82jmg`，QoS Class `Burstable`，Requests `cpu:200m,memory:128Mi`，Limits `cpu:500m,memory:256Mi`
- LimitRange：`lr`（default/defaultRequest）
- ResourceQuota：`rq`（requests.cpu 1、requests.memory 512Mi、limits.cpu 2、limits.memory 1Gi、pods 5）
- HPA：`php-apache`（autoscaling/v2），`cpu: 0%/50%`，minReplicas 1，maxReplicas 3，REPLICAS 1

> 演示结束后可按需清理：`kubectl --kubeconfig ./kubeconfig delete ns hpa-demo`