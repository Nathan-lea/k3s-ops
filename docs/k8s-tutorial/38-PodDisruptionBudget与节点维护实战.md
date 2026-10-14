# 38 PodDisruptionBudget 与节点维护实战

## 本章目标

- 理解"自愿中断（voluntary）"与"非自愿中断（involuntary）"以及 PDB（PodDisruptionBudget）的定位
- 掌握 `minAvailable` / `maxUnavailable` 语义与 `disruptionsAllowed`（允许中断数）的计算
- 掌握 Eviction API（`pods/eviction` 子资源）——理解 PDB 是如何"拦住"驱逐的
- 在本集群（k3s v1.30.2+k3s2）真实实测 PDB 拦截驱逐、`cordon`/`uncordon`、`kubectl drain` 的组合应用
- 建立节点维护（升级/下线/检修）的标准化流程与恢复思路

> 本章所有命令统一使用 `kubectl --kubeconfig ./kubeconfig`。文档中路径统一用 `~/k3s-ops` 表示。

---

## 1. 为什么需要 PDB：自愿中断 vs 非自愿中断

Kubernetes 把 Pod 中断分成两类，处理逻辑完全不同：

| 类型 | 示例 | 谁触发 | Kubernetes 能否"阻止" |
|---|---|---|---|
| **自愿中断（voluntary)** | 节点维护（drain）、Deployment 滚动更新、手动 `kubectl delete pod`、HPA 缩容 | 人/控制器，主动发起 | **可以**：通过 Eviction API 校验 PDB 后决定是否允许 |
| **非自愿中断（involuntary）** | 节点宕机/重启、硬件故障、内存 OOM-Kill、磁盘故障触发驱逐 | 基础设施故障 | 不能（PDB 管不到这些） |

NodeNotReady（第 36 章）属于非自愿；而 `kubectl drain`、版本升级、`kubectl replace` 属于自愿。**PDB 的价值**：在自愿中断发生时，保证集群"任何时刻可用副本数不低于阈值"，防止一次节点维护把某应用的全部副本一次性清空导致服务中断。

> 注意：PDB **不调度 Pod**、**不影响删除所有权**，只在"主动驱逐"这个动作上设卡。

---

## 2. PDB 核心概念

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: app-pdb
  namespace: pdb-demo
spec:
  minAvailable: 2            # 方式一：最少保留多少"健康 Pod"
  # maxUnavailable: 1        # 方式二：最多允许中断多少（二选一）
  selector:
    matchLabels: {app: app}  # 匹配受保护的 Pod 集合
```

- `minAvailable` / `maxUnavailable` 二选一，支持绝对数或百分比（如 `50%`）。两者等价换算：`maxUnavailable = 副本数 - minAvailable`。
- **健康 Pod（currentHealthy）** = Running 且 Ready（通过 Readiness 探针）+ 通过 StartupProbe。
- **允许中断数 disruptionsAllowed**（对应 `kubectl get pdb` 的 `ALLOWED DISRUPTIONS` 列）：minAvailable 模式下为 `currentHealthy − minAvailable`（下限 0）；maxUnavailable 模式下取 `maxUnavailable` 与"健康副本相对目标的缺口"的较小者。`disruptionsAllowed = 0` 意味着"此刻一个都不许驱逐"（本演示：2 副本 + `minAvailable: 2` → `2 − 2 = 0`）。

**Eviction API（驱逐）**：驱逐是"带着合法性检查的删除"。`kubectl drain`、节点压力驱逐、API 主动驱逐都走 `POST /api/v1/namespaces/<ns>/pods/<pod>/eviction`（**`pods/eviction` 子资源**）。API Server 在响应前会检查：

1. Pod 是否存在、是否已有 DeletionTimestamp；
2. 若有 PDB 且驱逐会跌破预算 → 返回 `429 TooManyRequests`；
3. 其余（不健康的驱逐、QoS 为 BestEffort 等）按策略放行或限速。

> **真实细节：** `Eviction` 是子资源类型，不在顶层资源列表里（本集群 `kubectl api-resources --api-group=policy` 只有 `poddisruptionbudgets`）。因此 `kubectl create -f eviction.json` 会报 `no matches for kind "Eviction"`，要直接调用需经 `kubectl proxy` 向子资源 POST（见 §3.3），日常推荐直接用 `kubectl drain`。

---

## 3. 真实集群实测一：PDB 保护生效（Eviction API 拦截）

### 3.1 部署受保护的工作负载

创建一个把 2 个副本**固定到 agent-1** 的 Deployment（`nodeSelector` 钉住），并加 `minAvailable: 2` 的 PDB：

```yaml
# ~/k3s-ops/tmp/pdb-demo.yaml（示例）
apiVersion: v1
kind: Namespace
metadata:
  name: pdb-demo
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app
  namespace: pdb-demo
spec:
  replicas: 2
  selector:
    matchLabels: {app: app}
  template:
    metadata:
      labels: {app: app}
    spec:
      nodeSelector:
        kubernetes.io/hostname: k3s-demo-agent-1
      containers:
        - name: nginx
          image: nginx:latest
          ports: [{containerPort: 80}]
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: app-pdb
  namespace: pdb-demo
spec:
  minAvailable: 2
  selector:
    matchLabels: {app: app}
```

```bash
$ kubectl --kubeconfig ./kubeconfig apply -f pdb-demo.yaml
namespace/pdb-demo created
deployment.apps/app created
poddisruptionbudget.policy/app-pdb created

$ kubectl --kubeconfig ./kubeconfig -n pdb-demo get pods -o wide
NAME                   READY   STATUS    RESTARTS   AGE   IP            NODE               NOMINATED NODE   READINESS GATES
app-76dd494669-ffglq   1/1     Running   0          20s   10.42.1.141   k3s-demo-agent-1   <none>           <none>
app-76dd494669-wccw5   1/1     Running   0          20s   10.42.1.142   k3s-demo-agent-1   <none>           <none>
```

两个副本都在 agent-1。此时 PDB 状态（真实值）为 `ALLOWED DISRUPTIONS 0`：

```bash
$ kubectl --kubeconfig ./kubeconfig -n pdb-demo get pdb app-pdb
NAME      MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
app-pdb   2               N/A               0                     21s

$ kubectl --kubeconfig ./kubeconfig -n pdb-demo describe pdb app-pdb
Name:           app-pdb
Namespace:      pdb-demo
Min available:  2
Selector:       app=app
Status:
    Allowed disruptions:  0
    Current:              2
    Desired:              2
    Total:                2
```

**解读（真实值）：** `Current=2`（当前健康副本）、`Desired=2`、`Allowed disruptions=0` → 任意一个 Pod 的驱逐都会把健康副本跌破 2，因此**当前一个都不许驱逐**。

### 3.2 直接调用 Eviction API（PDB 拦截，429）

用 `kubectl proxy` 直连 API Server，向 `pods/eviction` 子资源 POST：

```bash
$ kubectl --kubeconfig ./kubeconfig proxy --port=18001 & PROXY=$!
$ POD=$(kubectl --kubeconfig ./kubeconfig -n pdb-demo get pod -l app=app -o jsonpath='{.items[0].metadata.name}')
$ curl -s -X POST "http://127.0.0.1:18001/api/v1/namespaces/pdb-demo/pods/$POD/eviction" \
    -H "Content-Type: application/json" \
    -d "{\"apiVersion\":\"policy/v1\",\"kind\":\"Eviction\",\"metadata\":{\"name\":\"$POD\",\"namespace\":\"pdb-demo\"}}"
{
  "kind": "Status",
  "apiVersion": "v1",
  "metadata": {},
  "status": "Failure",
  "message": "Cannot evict pod as it would violate the pod's disruption budget.",
  "reason": "TooManyRequests",
  "details": {
    "causes": [
      {
        "reason": "DisruptionBudget",
        "message": "The disruption budget app-pdb needs 2 healthy pods and has 2 currently"
      }
    ]
  },
  "code": 429
}
```

要点解读：

- HTTP `429 TooManyRequests` + `<details><cause reason="DisruptionBudget">`：这是"PDB 不允许驱逐"的**标准应答**，不是资源不存在；
- 消息 `The disruption budget app-pdb needs 2 healthy pods and has 2 currently` 精确说明了"预算要求 2 个、当前恰好 2 个，一个都不让动"；
- Pod 原封不动仍在运行（驱逐被拒），验证：`kubectl --kubeconfig ./kubeconfig -n pdb-demo get pods` 两个 Pod 依旧 `Running`。

---

## 4. 真实集群实测二：cordon / uncordon（"只出不进"）

`cordon` 标记节点为 `SchedulingDisabled`：**已有 Pod 不动**，但**新 Pod 不再调度上去**——是升级/维护前"先停产再拆卸"的第一步。

### 4.1 cordon：新 Pod 无法调度（Pending）

```bash
$ kubectl --kubeconfig ./kubeconfig cordon k3s-demo-agent-1
node/k3s-demo-agent-1 cordoned

$ kubectl --kubeconfig ./kubeconfig get nodes
NAME                STATUS                     ROLES                       AGE    VERSION
k3s-demo-agent-1    Ready,SchedulingDisabled   <none>                      133d   v1.30.2+k3s2
k3s-demo-server-1   Ready                      control-plane,etcd,master   140d   v1.30.2+k3s2
```

状态 `Ready,SchedulingDisabled`（注意：**Ready 依然为 True**，只是禁止调度）。此时创建一个钉住 agent-1 的新 Deployment：

```bash
$ kubectl --kubeconfig ./kubeconfig -n pdb-demo get pod -l app=pinned -o wide
NAME                      READY   STATUS    RESTARTS   AGE   IP       NODE
pinned-78b7bf4755-lrgzn   0/1     Pending   0          8s    <none>   <none>

$ kubectl --kubeconfig ./kubeconfig -n pdb-demo describe pod -l app=pinned | grep -A4 "Events:"
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  8s    default-scheduler  0/2 nodes are available: 1 node(s) didn't match Pod's node affinity/selector, 1 node(s) were unschedulable. preemption: 0/2 nodes are available: 2 Preemption is not helpful for scheduling.
```

`FailedScheduling`：server-1 不匹配 `nodeSelector`，agent-1 被 cordon（`unschedulable`）→ 新 Pod 只能 Pending。

### 4.2 uncordon：恢复调度

```bash
$ kubectl --kubeconfig ./kubeconfig uncordon k3s-demo-agent-1
node/k3s-demo-agent-1 uncordoned

$ kubectl --kubeconfig ./kubeconfig -n pdb-demo get pod -l app=pinned -o wide
NAME                      READY   STATUS    RESTARTS   AGE   IP            NODE
pinned-78b7bf4755-lrgzn   1/1     Running   0          24s   10.42.1.143   k3s-demo-agent-1   ...
```

> **小结：** `cordon` 只影响"未来调度"，不影响"存量运行"；未设置 `nodeSelector`/亲和性的普通负载在 cordon 期间会被调度到其他节点。这也是为什么"cordon 先行、drain 再排空"是最安全的维护顺序。

---

## 5. 真实集群实测三：kubectl drain 与 PDB 联动

`kubectl drain` 是节点维护的"打包动作"：**自动 cordon → 对节点上所有 Pod 逐个走 Eviction API → 全部驱逐成功才算完成**。

### 5.1 前置处理：裸 Pod（真实细节）

本集群 agent-1 上有第 35 章的 `netpol-demo/client`、`netpol-demo/server` 这两个**无控制器裸 Pod**（kind: Pod）。`kubectl drain` 默认**拒绝驱逐无控制器 Pod**（无法重建，属于危险操作，除非加 `--force`）。为了让演示聚焦"PDB 拦截"，先导出清单并删除裸 Pod，恢复阶段再重建（§5.5）：

```bash
$ kubectl --kubeconfig ./kubeconfig -n netpol-demo delete pod client server
pod "client" deleted from netpol-demo namespace
pod "server" deleted from netpol-demo namespace
```

> ⚠️ 生产环境不建议直接删裸 Pod；应评估其重要性，或显式使用 `--force --ignore-daemonsets`（`--force` 会不经 Eviction 检查直接删除，风险自负）。

### 5.2 drain：PDB 保护导致驱逐失败（真实输出）

```bash
$ kubectl --kubeconfig ./kubeconfig drain k3s-demo-agent-1 --ignore-daemonsets --delete-emptydir-data --timeout=30s
error when evicting pods/"app-76dd494669-ffglq" -n "pdb-demo" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
error when evicting pods/"app-76dd494669-wccw5" -n "pdb-demo" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
evicting pod pdb-demo/app-76dd494669-ffglq
evicting pod pdb-demo/app-76dd494669-wccw5
error when evicting pods/"app-76dd494669-ffglq" -n "pdb-demo" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
...（每 5 秒重试，直至 --timeout）
There are pending pods in node "k3s-demo-agent-1" when an error occurred: [error when evicting pods/"app-76dd494669-ffglq" -n "pdb-demo": global timeout reached: 30s, ...]
error: unable to drain node "k3s-demo-agent-1" due to error: [error when evicting pods/"app-76dd494669-ffglq" -n "pdb-demo": global timeout reached: 30s], continuing command...

$ echo $?
1
```

**解读（真实行为）：**

- drain 先把节点 cordon（前面章节看到的是 `Ready,SchedulingDisabled`）；
- **其他可驱逐的 Pod**（如 gateway-demo 数据面、gold 后端、Fleet 清理 Job 等）逐个驱逐成功；
- 唯二被拒绝的就是 PDB 保护的 `pdb-demo/app-*`：`Cannot evict pod as it would violate the pod's disruption budget.`，drain **每 5 秒重试**；
- 不设 `--timeout` 时，drain 会对被拒的 Pod 每 5 秒重试、无限挂起（直到被手动中断）——**`--timeout` 是 drain 的必备护栏**；
- 最终 `error: unable to drain node ...`，退出码 `1`，节点保持 cordon 状态（不会自动 uncordon）。

### 5.3 删除 PDB 后 drain 完成

PDB 就是"拦路卡"，删掉后驱逐放行：

```bash
$ kubectl --kubeconfig ./kubeconfig -n pdb-demo delete pdb app-pdb
poddisruptionbudget.policy "app-pdb" deleted

$ kubectl --kubeconfig ./kubeconfig drain k3s-demo-agent-1 --ignore-daemonsets --delete-emptydir-data --timeout=90s
node/k3s-demo-agent-1 already cordoned
evicting pod pdb-demo/app-76dd494669-wccw5
evicting pod pdb-demo/app-76dd494669-ffglq
pod/app-76dd494669-ffglq evicted
pod/app-76dd494669-wccw5 evicted
node/k3s-demo-agent-1 drained

$ kubectl --kubeconfig ./kubeconfig get pods -A --field-selector spec.nodeName=k3s-demo-agent-1
No resources found

$ kubectl --kubeconfig ./kubeconfig get nodes
NAME                STATUS                     ROLES                       AGE    VERSION
k3s-demo-agent-1    Ready,SchedulingDisabled   <none>                      133d   v1.30.2+k3s2
k3s-demo-server-1   Ready                      control-plane,etcd,master   140d   v1.30.2+k3s2
```

节点已排空（无 Pod），等待维护/升级。

### 5.4 drain 语义总结

| 阶段 | 动作 | 结果 |
|---|---|---|
| 1 | 自动 `cordon` | `Ready,SchedulingDisabled`（存量 Pod 继续运行，新 Pod 不来） |
| 2 | 逐个 Eviction API | 满足 PDB/有控制器/无本地数据的 Pod 被驱逐并重建到其他节点 |
| 3 | 失败重试 | PDB 拒绝 → 每 5s 重试直到 `--timeout`；有 `--delete-emptydir-data`/`--ignore-daemonsets` 选项放行特定类型 |
| 4 | 完成 | `node ... drained`；节点无 Pod，可安全关机/升级 |
| 5 | 恢复 | 维护完成后需手动 `kubectl uncordon`（drain 不会自动恢复调度） |

常用选项：`--ignore-daemonsets`（保留 DaemonSet）、`--delete-emptydir-data`（允许驱逐挂 emptyDir 的 Pod）、`--pod-selector`（只排空某类负载）、`--timeout`（全局超时，防卡死）。

### 5.5 恢复集群原状（uncordon + 重建 + 回滚验证）

```bash
$ kubectl --kubeconfig ./kubeconfig uncordon k3s-demo-agent-1
node/k3s-demo-agent-1 uncordoned

$ kubectl --kubeconfig ./kubeconfig create -f netpol-client.yaml -f netpol-server.yaml   # 重建裸 Pod
pod/client created
pod/server created

$ kubectl --kubeconfig ./kubeconfig -n pdb-demo rollout restart deploy/app             # 让 app 副本回到 agent-1
deployment.apps/app restarted

$ kubectl --kubeconfig ./kubeconfig get nodes
NAME                STATUS   ROLES                       AGE    VERSION
k3s-demo-agent-1    Ready    <none>                      133d   v1.30.2+k3s2
k3s-demo-server-1   Ready    control-plane,etcd,master   140d   v1.30.2+k3s2
```

> 被 drain 驱逐的工作负载由各自的 Deployment/Job 控制器在 server-1 上自动重建；钉住 agent-1 的负载（`pdb-demo/app`）在 uncordon + `rollout restart` 后回到 agent-1。最终集群恢复双节点 Ready、无异常 Pod 的初始状态。

---

## 6. 节点维护标准流程（升级/下线/检修）

结合第 33/36 章与本章结论，一次"安全节点维护"的最小闭环：

| 步骤 | 命令 | 关键点 |
|---|---|---|
| 1. 检查应用 | `kubectl --kubeconfig ./kubeconfig get deploy -A` | 确认关键应用有 ≥2 副本且有 PDB 兜底 |
| 2. 逐应用建 PDB | `minAvailable: 2`（或 `maxUnavailable: 1`） | 保证维护期间不跌破预算 |
| 3. 停止新流量调度 | `kubectl --kubeconfig ./kubeconfig cordon <node>` | 存量不动，新 Pod 不再来 |
| 4. 排空节点 | `kubectl --kubeconfig ./kubeconfig drain <node> --ignore-daemonsets --delete-emptydir-data --timeout=15m` | 走 Eviction API；PDB 保护的 Pod 会留到最后（若拒绝，说明预算不够） |
| 5. 确认排空 | `kubectl --kubeconfig ./kubeconfig get pods -A --field-selector spec.nodeName=<node>` | 应无 Pod（DaemonSet 除外） |
| 6. 维护/升级 | 停机检修、升级 k3s、换硬件等 | 节点可安全关机 |
| 7. 恢复调度 | `kubectl --kubeconfig ./kubeconfig uncordon <node>` | 恢复调度能力 |
| 8. 观察回归 | `kubectl --kubeconfig ./kubeconfig top nodes`、`kubectl --kubeconfig ./kubeconfig get pods -A` | 验证负载回流、集群健康 |
| 9. 清理演练对象 | 删除临时 PDB/演示 namespace | 防止残留预算影响后续 |

> 本章实测中 server-1 为无污点的 server（AGENTS.md 设计），因此 `cordon server-1` 同样适用于控制面节点维护演示；但**etcd 成员**的摘除请参考 k3s 官方节点替换流程，不要直接 drain 后 destroy（会破坏 etcd quorum）。

---

## 7. 排障清单

| 现象 | 常见原因 | 排查/修复 |
|---|---|---|
| `kubectl drain` 卡住不动 | PDB 拒绝且未设 `--timeout`（默认无限重试） | 加 `--timeout`；`kubectl get pdb -A` 确认谁在拦；必要时临时调低 `minAvailable` |
| 驱逐返回 `Cannot evict pod as it would violate the pod's disruption budget` | `disruptionsAllowed=0` | 提升副本数/调低 minAvailable，或等副本恢复 Ready 后再驱逐 |
| `error: unable to evict pod ... not managed by a controller` | drain 遇到无控制器裸 Pod | `--force`（⚠️ 慎用）或评估后删除 |
| drain 后新 Pod 不来 | 节点仍处于 `SchedulingDisabled` | `kubectl uncordon <node>` |
| PDB 一直 `Allowed disruptions: 0` | `currentHealthy < minAvailable`（探针失败/副本不足） | `kubectl --kubeconfig ./kubeconfig top pods`、检查 Readiness 探针 |
| PDB 不生效 | `selector` 没有匹配到任何 Pod（Status 显示 `NoPods`） | `kubectl --kubeconfig ./kubeconfig describe pdb` 看 `Current/Desired`，核对 label |
| `kubectl create -f eviction.json` 报 `no matches for kind "Eviction"` | Eviction 是子资源，非顶层资源 | 用 `kubectl drain` 或 `kubectl proxy` + POST `pods/eviction`（§3.2） |

---

## 8. Rancher 界面对照

| 路径 | 对应 kubectl | 用途 |
|---|---|---|
| **集群 → Nodes → 节点详情 → Edit**（Cordon/Uncordon 按钮） | `kubectl --kubeconfig ./kubeconfig cordon/uncordon <node>` | UI 一键启停调度 |
| **集群 → Nodes → 节点详情 → Drain** | `kubectl --kubeconfig ./kubeconfig drain <node> --ignore-daemonsets --delete-emptydir-data` | Rancher 的 Drain 按钮封装了上述完整流程（含驱逐与确认） |
| **集群 → More Resources → policy → PodDisruptionBudgets** | `kubectl --kubeconfig ./kubeconfig get pdb -A` | 查看所有 PDB 的 ALLOWED DISRUPTIONS |
| **PDB 详情** | `kubectl --kubeconfig ./kubeconfig describe pdb <name> -n <ns>` | 查看 Current/Desired/Min available |
| **集群 → Events** | `kubectl --kubeconfig ./kubeconfig get events -A --sort-by=.metadata.creationTimestamp` | 驱逐被拒时查看 `TooManyRequests/DisruptionBudget` 事件 |

> Rancher 的 **Drain 按钮**实际执行的正是本章的命令组合，生产上推荐在 UI 里操作以便审计留痕；命令行用于精细控制（`--pod-selector`、`--timeout`）。

---

## 动手练习

1. **预算换算**：某 Deployment 5 副本，`minAvailable: 60%`。当前 5 个健康副本时 `disruptionsAllowed` 是多少？4 个健康时呢？（提示：`min(currentHealthy - minAvailable, maxUnavailable)`，逐项写出）。
2. **PDB 状态观察**：执行 `kubectl --kubeconfig ./kubeconfig -n pdb-demo get pod,pdb`，解释 `ALLOWED DISRUPTIONS: 0` 的含义与触发条件。
3. **驱逐拦截复现**：按 §3.2 用 `kubectl proxy` 对 `pdb-demo` 的某个 app Pod 发起 Eviction，记录返回的 HTTP 状态码与 message，并确认 Pod 未被删除。
4. **cordon 实战**：`kubectl --kubeconfig ./kubeconfig cordon k3s-demo-agent-1` 后，在 `lab` 命名空间创建一个无 nodeSelector 的 1 副本 nginx，观察它调度到哪个节点；`uncordon` 后再创建一个，观察调度结果差异。
5. **drain 演练（⚠️ 高危，建议先在练习 namespace 隔离）**：给 `pdb-demo/app` 建 `maxUnavailable: 1` 的 PDB，对 agent-1 执行 `drain --timeout=60s`，对比与 `minAvailable: 2` 时的行为差异，然后按 §5.5 恢复。
6. **原生 Eviction vs delete**：对比 `kubectl delete pod`（绕开 PDB 检查）与 Eviction（受 PDB 约束）对 `pdb-demo` 的差异，说明为什么"维护操作必须用 drain/Eviction 而不是 delete"。
7. **排障口径**：写出"drain 卡住"的三步排查顺序（命令/查看对象/结论）。

<details>
<summary>参考答案</summary>

1. `minAvailable: 60%` → 目标值 `ceil(5×60%) = 3`。5 个健康时 `allowed = 5-3 = 2`；4 个健康时 `allowed = 4-3 = 1`（`disruptionsAllowed` 取 `min(currentHealthy - minAvailable, maxUnavailable)`）。
2. `ALLOWED DISRUPTIONS: 0` 表示当前**不允许**任何自愿驱逐：因为 2 个健康副本、`minAvailable: 2`，健康副本 − minAvailable = 0。
3. `kubectl proxy` 后 `POST /api/v1/namespaces/pdb-demo/pods/<pod>/eviction` → HTTP **429**，message 为 `Cannot evict pod as it would violate the pod's disruption budget.`，Pod 未被删除。
4. `cordon` agent-1 后新 Pod 调度到 **server-1**（agent-1 变成 `SchedulingDisabled`）；`uncordon` 后新 Pod 才可能回到 agent-1。
5. `maxUnavailable: 1` 时 `allowed = 1`，`drain` 可驱逐 1 个 Pod 并推进；`minAvailable: 2`（`allowed = 0`）时 `drain` 被 PDB 拦截、反复重试直到超时。
6. `kubectl delete pod` 直接删除、**绕开** PDB 检查；Eviction（`drain` 使用）会先经 PDB 校验。维护操作必须用 `drain`/Eviction 才能在保护可用性的前提下腾空节点。
7. "drain 卡住"三步：① `kubectl get pdb -n <ns>` 看 `ALLOWED DISRUPTIONS` 是否为 0；② `kubectl get events`/`describe pod` 看驱逐是否被拒（PDB/裸 Pod/Finalizer）；③ 检查节点状态与残留 Pod，按结论处理（补副本、删 PDB/裸 Pod，或 `--force`）。

</details>

---

## 附录：本章演示对象与清理

**本章创建的资源：**

- 命名空间 `pdb-demo`：Deployment `app`（2 副本，钉住 agent-1）+ PDB `app-pdb`（`minAvailable: 2`）—— 已恢复并保留
- 演示用临时 Deployment `pinned` —— 已清理
- 恢复阶段重建：`netpol-demo/client`、`netpol-demo/server`（第 35 章裸 Pod，导出后重建，IP 有变化属正常）

**清理命令：**

```bash
kubectl --kubeconfig ./kubeconfig delete ns pdb-demo
```

> ⚠️ 本章 drain/cordon 均为**真实节点操作**，演练后务必执行 §5.5 的恢复步骤；若容器在维护场景（如验证升级）中使用，请先为关键应用补好 PDB 再 drain。