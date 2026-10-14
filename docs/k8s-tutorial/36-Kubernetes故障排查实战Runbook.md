# 36 Kubernetes 故障排查实战 Runbook

## 本章目标

- 掌握 Kubernetes 故障排查的结构化思路（观察 → 定位 → 验证 → 恢复 → 复盘）
- 熟悉核心排障链路：`kubectl describe`、`kubectl get events --sort-by`、`kubectl logs`（`--previous`）、`kubectl top`、节点/Pod Conditions
- 覆盖常见故障类型：CrashLoopBackOff、ImagePullBackOff/ErrImagePull、OOMKilled、Pending、NodeNotReady、ReadinessFailed、Terminating 卡住、Init:CrashLoopBackOff
- 基于本集群真实 Events/状态采集，建立可直接落地的排障清单与 Runbook 模板
- 强调“证据优先（describe/events/logs）→ 假设验证 → 最小变更恢复”原则

> 本章所有命令统一使用 `kubectl --kubeconfig ./kubeconfig`。文档中路径统一用 `~/k3s-ops` 表示。

---

## 1. 排障哲学与黄金链路

Kubernetes 故障排查的核心是**先看事件（Events），再看状态（describe），最后看日志（logs）**。避免直接跳到猜测。

### 1.1 结构化排障流程（Runbook SOP）

| 步骤 | 动作 | 目的 |
|---|---|---|
| 1. 观察（Observe） | 收集异常现象（Pod 重启次数、READY、STATUS、部署是否卡住） | 明确“什么异常、什么时候发生” |
| 2. 定位（Triage） | 按资源范围缩小：Namespace → Workload（Deployment/DS/Job）→ Pod → 容器 → 节点 | 快速缩小故障域 |
| 3. 证据（Evidence） | 优先查看 Events（时间序列）、`kubectl describe pod`、`kubectl logs --previous`、节点状态 | 获取客观证据，而非臆测 |
| 4. 验证（Hypothesize） | 根据证据提出最可能假设，一次只验证一个假设 | 避免盲目改动 |
| 5. 恢复（Remediate） | 最小变更修复（回滚、修正配置、扩容等） | 降低二次故障风险 |
| 6. 验证（Verify） | `kubectl get pods/events`、`kubectl rollout status` 确认恢复 | 闭环验证 |
| 7. 复盘（Postmortem） | 记录根因、修复步骤、预防措施（本章模板） | 防止复发 |

### 1.2 黄金排障命令链路

| 优先级 | 命令 | 说明 |
|---|---|---|
| P0（时间序列） | `kubectl --kubeconfig ./kubeconfig get events -n <ns> --sort-by=.metadata.creationTimestamp` | 最关键：按时间排序的事件流，通常先暴露根因（调度失败、拉取失败、探针失败等） |
| P1（整体状态） | `kubectl --kubeconfig ./kubeconfig describe pod <pod> -n <ns>` | 汇聚 Conditions、容器状态（Waiting/Running/Terminated）、Liveness/Readiness、Events、QoS、资源等 |
| P2（崩溃日志） | `kubectl --kubeconfig ./kubeconfig logs <pod> -n <ns> -c <container> --previous` | 查看上一次崩溃前的日志（解决 CrashLoopBackOff 首选） |
| P3（当前日志） | `kubectl --kubeconfig ./kubeconfig logs <pod> -n <ns> -c <container> --tail=100 -f` | 实时观察当前容器日志 |
| P4（工作负载） | `kubectl --kubeconfig ./kubeconfig describe deploy/<name> -n <ns>`、`kubectl --kubeconfig ./kubeconfig rollout status deploy/<name> -n <ns>` | 定位是否是滚动更新卡住 |
| P5（节点层面） | `kubectl --kubeconfig ./kubeconfig describe node <node>`、`kubectl --kubeconfig ./kubeconfig top nodes`、`kubectl --kubeconfig ./kubeconfig top pods -A` | 资源压力（CPU/Memory）、污点、Conditions（Ready/MemoryPressure/DiskPressure/PIDPressure） |
| P6（集群事件） | `kubectl --kubeconfig ./kubeconfig get events -A --sort-by=.metadata.creationTimestamp \| tail -50` | 全局近期异常事件 |

> **铁律：** 遇到 Pod 异常，先做 `events --sort-by`，再 `describe pod`，再决定是否看 `logs --previous`。

---

## 2. 常见故障速查表

| STATUS/现象 | 常见 Reason | ExitCode | 核心原因 | 首要排查命令 | 修复建议 |
|---|---|---|---|---|---|
| CrashLoopBackOff | Error/ContainerCannotRun | 1、2、126、127、137 等 | 启动即崩溃（配置错误、依赖未就绪、缺失文件、权限） | `kubectl --kubeconfig ./kubeconfig logs <pod> -n <ns> -c <container> --previous`、`kubectl --kubeconfig ./kubeconfig describe pod <pod> -n <ns>`（Last State/Events） | 修正启动命令/环境变量/配置，必要时加 `startupProbe` 保护慢启动 |
| ImagePullBackOff | ErrImagePull | N/A | 镜像名错误、私有仓库无凭据、网络不可达、镜像 tag 不存在 | `kubectl --kubeconfig ./kubeconfig describe pod <pod> -n <ns>`（Events） | 修正镜像/tag、配置 `imagePullSecrets`、检查网络/仓库可达性 |
| ErrImagePull | ErrImagePull | N/A | 拉取中断/超时（常见跨网/仓库限流） | `kubectl --kubeconfig ./kubeconfig describe pod <pod> -n <ns>`（Events 原始报错） | 重试、换可达镜像源（本环境使用 `docker.1panel.live` 等镜像加速） |
| OOMKilled | OOMKilled | 137（128+9 SIGKILL） | 内存超过 `limits`，内核 OOM Killer 强制终止 | `kubectl --kubeconfig ./kubeconfig describe pod <pod> -n <ns>` → Last State: Terminated（Reason OOMKilled） | 增加 `limits.memory` 或优化内存，结合 HPA（第 34 章）做水平扩容分摊压力 |
| Pending | FailedScheduling | N/A | 资源不足（CPU/Memory requests）、污点/容忍、亲和性/反亲和、PVC/PV 未绑定、`nodeSelector` 不匹配 | `kubectl --kubeconfig ./kubeconfig describe pod <pod> -n <ns>`（Events：FailedScheduling: ...）、`kubectl --kubeconfig ./kubeconfig describe node <node>`、`kubectl --kubeconfig ./kubeconfig top nodes`、`kubectl --kubeconfig ./kubeconfig get pvc -n <ns>` | 降低 requests、扩容节点、调整调度约束、检查存储 |
| ContainerCreating（长时间） | FailedCreateContainer/VolumeMount 等 | N/A | CSI/Volume 挂载失败、ConfigMap/Secret 不存在、权限问题 | `kubectl --kubeconfig ./kubeconfig describe pod <pod> -n <ns>`（Events） | 创建缺失的 ConfigMap/Secret/PVC、排查存储驱动 |
| NodeNotReady（节点层） | NodeNotReady | N/A | kubelet 未上报心跳、网络中断、磁盘/内存压力、runtime 异常 | `kubectl --kubeconfig ./kubeconfig describe node <node>`（Conditions: Ready=False, Memory/Disk/PID Pressure） | 排查节点网络/磁盘/内存、重启 kubelet（按需）、驱逐或修复节点 |
| ReadinessFailed/READY 0/1 | Unhealthy（探针失败） | N/A | `readinessProbe` 连续失败（路径/端口错误、应用初始化慢） | `kubectl --kubeconfig ./kubeconfig describe pod <pod> -n <ns>`（Liveness/Readiness + Events） | 修正探针路径/端口、放宽超时/间隔或加 `startupProbe` |
| LivenessProbeFailed（频繁重启） | Unhealthy | N/A | `livenessProbe` 误判（应用响应慢、临时抖动） | `kubectl --kubeconfig ./kubeconfig describe pod <pod> -n <ns>`（探针配置与失败事件）、`kubectl --kubeconfig ./kubeconfig logs <pod> -n <ns> -c <container> --previous` | 调整 `periodSeconds`/`failureThreshold`/`timeoutSeconds`，使用 `startupProbe` 区分启动阶段 |
| Terminating 长时间卡住 | DeletionTimestamp 存在 | N/A | `preStop` 执行过久、应用未响应 SIGTERM、Finalizer 阻塞 | `kubectl --kubeconfig ./kubeconfig describe pod <pod> -n <ns>`、`kubectl --kubeconfig ./kubeconfig get pod <pod> -n <ns> -o yaml \| grep -B2 -A5 finalizers` | 优化优雅关闭、按需调整 `terminationGracePeriodSeconds`，谨慎处理 Finalizer（仅在明确原因下清理） |
| Init:CrashLoopBackOff | Init 容器崩溃 | 视 Init 而定 | InitContainer 启动失败（依赖检查超时、脚本异常） | `kubectl --kubeconfig ./kubeconfig describe pod <pod> -n <ns>`（Init Containers 段）、`kubectl --kubeconfig ./kubeconfig logs <pod> -n <ns> -c <init-container> --previous` | 修正 Init 脚本、增加重试/超时或检查外部依赖可达性 |

> **ExitCode 快速对照：** 137=OOMKilled/SIGKILL，143=SIGTERM（正常终止，143=128+15），1/2 一般为应用异常退出。

---

## 3. 基于真实集群的排障证据采集

本节基于当前集群已有对象（Events、状态）提取真实证据，体现“真实采集”原则。

### 3.1 查看全局近期事件（时间序列）

```bash
$ kubectl --kubeconfig ./kubeconfig get events -A --sort-by=.metadata.creationTimestamp | tail -40
...
probe-demo      28m   Normal    Pulled    pod/web-57d87ff99c-q8vkp       Successfully pulled image "nginx:latest" in 1.541s ...
probe-demo      28m   Normal    Created   pod/web-57d87ff99c-q8vkp       Created container web
probe-demo      28m   Normal    Started   pod/web-57d87ff99c-q8vkp       Started container web
...
hpa-demo        28m   Warning   FailedComputeMetricsReplicas   horizontalpodautoscaler/php-apache   invalid metrics (1 invalid out of 1), first error is: failed to get cpu resource metric value: ... no metrics returned from resource metrics API
cert-manager    27m   Warning   Unhealthy   pod/cert-manager-webhook-7f8cc9d46b-94w2h   Readiness probe failed: Get "http://10.42.0.30:6080/healthz": context deadline exceeded (Client.Timeout exceeded while awaiting headers)
```

按创建时间倒序查看最近事件，便于发现异常链路。上例中既有 `Normal`（拉取/创建/启动成功），也有 `Warning`（HPA 指标缺失、探针 Unhealthy）——**Warning 事件通常就是根因线索**。

### 3.2 从 probe-demo 查看探针相关事件（真实案例）

在第 33 章创建的 `probe-demo` 命名空间中，查看 Pod 的 Events 段，可直观看到调度、拉取镜像、创建启动及探针相关事件：

```bash
$ kubectl --kubeconfig ./kubeconfig -n probe-demo describe pod -l app=web 2>&1 | grep -B1 -A15 "Events"
Events:
  Type     Reason          Age   From             Message
  ----     ------          ----  ----             -------
  Warning  NodeNotReady    170m  node-controller  Node is not ready
  Normal   SandboxChanged  28m   kubelet          Pod sandbox changed, it will be killed and re-created.
  Normal   Pulling         28m   kubelet          spec.containers{web}: Pulling image "nginx:latest"
  Normal   Pulled          28m   kubelet          spec.containers{web}: Successfully pulled image "nginx:latest" in 1.541s ...
  Normal   Created         28m   kubelet          spec.containers{web}: Created container web
  Normal   Started         28m   kubelet          spec.containers{web}: Started container web
```

当探针失败时（readiness/liveness 连续失败），kubelet 会以 `Warning` 类型的 `Unhealthy` 事件记录到 Events 中，这是定位“READY 0/1”或“频繁重启”的关键线索。上例中的 `Warning NodeNotReady`（节点短暂失联）同样会出现在这里，可用于关联“Pod 异常是否由节点导致”。

### 3.3 节点层面健康检查（Conditions）

节点是否 Ready、是否有压力，是判断“Pod Pending 是否因节点问题”的关键：

```bash
$ kubectl --kubeconfig ./kubeconfig describe node k3s-demo-server-1 2>&1 | grep -A12 "^Conditions"
Conditions:
  Type             Status  LastHeartbeatTime                 LastTransitionTime                Reason                       Message
  ----             ------  -----------------                 ------------------                ------                       -------
  EtcdIsVoter      True    Tue, 13 Oct 2026 13:08:52 +0800   Sat, 10 Oct 2026 09:52:15 +0800   MemberNotLearner             Node is a voting member of the etcd cluster
  MemoryPressure   False   Tue, 13 Oct 2026 13:07:50 +0800   Mon, 25 May 2026 17:12:52 +0800   KubeletHasSufficientMemory   kubelet has sufficient memory available
  DiskPressure     False   Tue, 13 Oct 2026 13:07:50 +0800   Mon, 25 May 2026 17:12:52 +0800   KubeletHasNoDiskPressure     kubelet has no disk pressure
  PIDPressure      False   Tue, 13 Oct 2026 13:07:50 +0800   Mon, 25 May 2026 17:12:52 +0800   KubeletHasSufficientPID      kubelet has sufficient PID available
  Ready            True    Tue, 13 Oct 2026 13:07:50 +0800   Tue, 13 Oct 2026 12:42:16 +0800   KubeletReady                 kubelet is posting ready status
```

结论（真实值）：`Ready=True` 且三类 Pressure 均为 `False`，说明节点健康、无资源压力。

节点资源使用概览（便于判断资源不足导致 Pending）：

```bash
$ kubectl --kubeconfig ./kubeconfig top nodes
NAME                CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
k3s-demo-agent-1    26m          1%       396Mi           10%
k3s-demo-server-1   726m         36%      2401Mi          61%
```

> 结合 `kubectl describe node` 的 `Allocatable` 与 `top nodes` 的实际用量，即可判断 `FailedScheduling: Insufficient cpu/memory` 是否成立。

---

## 4. CrashLoopBackOff 排障实操思路

最有效的切入点是上次崩溃日志：

```bash
kubectl --kubeconfig ./kubeconfig logs <pod> -n <ns> -c <container> --previous
```

排查顺序建议：

1. `logs --previous` → 找到崩溃堆栈/报错（例如配置文件未找到、端口被占用、依赖连接超时）
2. `kubectl --kubeconfig ./kubeconfig describe pod <pod> -n <ns>` → 查看 `Last State.Terminated`（Reason、Exit Code、FinishedAt）
3. `kubectl --kubeconfig ./kubeconfig describe deploy/<name> -n <ns>` + `kubectl --kubeconfig ./kubeconfig rollout history deploy/<name> -n <ns>` → 判断是否是最近一次发布导致
4. 修复配置（ConfigMap/Secret/环境变量/启动脚本）后 `kubectl --kubeconfig ./kubeconfig rollout restart deploy/<name> -n <ns>` 重建验证

> **原则：** 不要直接删除 Pod 猜测，优先看 `--previous` 日志。

---

## 5. OOMKilled 排障要点

OOMKilled 对应 ExitCode 137。关键证据在 `kubectl describe pod` 的 Terminated 段：

```text
Last State:  Terminated
  Reason:    OOMKilled
  Exit Code: 137
  Finished:  ...
```

排查建议：

1. 对比 `requests.memory` 与实际峰值（`kubectl --kubeconfig ./kubeconfig top pods -n <ns>` 在压力时采集最有效）
2. 判断是否是内存泄漏（持续爬升）还是突发峰值（短时暴涨）
3. 优化：增加 `limits.memory`、减小堆内存配置（JVM `-Xmx`）、限制并发、改用 Burstable/Guaranteed 合理配比
4. 结合 HPA（第 34 章）做水平扩容分摊压力

---

## 6. Pending（调度失败）排障要点

`FailedScheduling` 是最常见 Reason。典型 Events 消息：

```text
0/2 nodes are available: 2 Insufficient cpu, 2 Insufficient memory.
0/2 nodes are available: 1 node(s) had untolerated taint {node-role.kubernetes.io/control-plane: ...}, 1 node(s) didn't match Pod's node affinity/selector.
```

对应排查：

1. **资源不足**：`kubectl --kubeconfig ./kubeconfig top nodes` + 节点 `Allocatable` vs Requests 总和
2. **污点（Taints）**：节点有污点但 Pod 无对应 `tolerations`
3. **亲和性（Affinity）**：`nodeAffinity`/`podAffinity`/`podAntiAffinity` 条件不满足
4. **PVC**：Pending PVC 导致 Pod 无法调度/挂载（`kubectl --kubeconfig ./kubeconfig get pvc -n <ns>`、`kubectl --kubeconfig ./kubeconfig describe pvc <pvc> -n <ns>`）

> 本集群 `k3s-demo-server-1` 为**无污点**的 server（未加 `NoSchedule` 污点），因此“控制面污点”类 Pending 一般不会出现；若出现 taint 相关 Pending，多为自定义污点或系统组件（如 `cattle`/Rancher）引入。

---

## 7. Terminating 卡住排障要点

Pod 长时间处于 Terminating 状态，通常有两个原因：

1. **应用未响应 SIGTERM**：`preStop` 执行过久或主进程忽略 SIGTERM，消耗完 `terminationGracePeriodSeconds` 后才被 SIGKILL（第 33 章优雅终止时序）
2. **Finalizer 阻塞**：`metadata.finalizers` 不为空，控制器未清理导致删除被阻塞

排查方式：

```bash
kubectl --kubeconfig ./kubeconfig get pod <pod> -n <ns> -o yaml | grep -B2 -A5 finalizers
```

> **处理原则：** 绝对不要随意强制删除（`--force --grace-period=0`）而不查明原因。只有在确认外部控制器异常或不再存在且业务影响可控时，才谨慎考虑移除 Finalizer（高风险操作，需有明确依据）。

---

## 8. Runbook 模板（推荐直接复用）

每次故障处理建议记录以下模板，形成可复用的知识库：

```markdown
## 故障记录：<简短标题>
- 报告时间：YYYY-MM-DD HH:MM:SS
- 命名空间/资源：ns/<ns>，workload/<name>，pod/<pod>
- 影响范围：影响服务、用户影响、SLA 影响

### 现象（Symptoms）
- READY/STATUS/RESTARTS、是否可访问、报错信息

### 初步判断（Triage）
- 最可能原因：...

### 排查证据（Evidence）
- kubectl --kubeconfig ./kubeconfig get events -n <ns> --sort-by=.metadata.creationTimestamp：关键事件摘录
- kubectl --kubeconfig ./kubeconfig describe pod <pod> -n <ns>：关键段落
- kubectl --kubeconfig ./kubeconfig logs <pod> -n <ns> -c <c> --previous：关键日志
- kubectl --kubeconfig ./kubeconfig describe node/<n>（如涉及节点）：关键 Conditions

### 根因（Root Cause）
- 具体根因（可验证）

### 修复措施（Remediation）
- 具体操作步骤（可回放）

### 验证（Verification）
- kubectl --kubeconfig ./kubeconfig get pods -n <ns>
- kubectl --kubeconfig ./kubeconfig rollout status deploy/<name> -n <ns>
- 连通性测试

### 预防措施（Prevention）
- 监控告警（Probe/Restarts/OOM/NodeNotReady）
- 资源预案（requests/limits/LimitRange/ResourceQuota）
- 探针调优（startupProbe/readinessProbe/livenessProbe）
- 日常演练与文档固化
```

---

## 9. Rancher 界面对照

Rancher UI 在故障排障时也非常有用，可与命令行双向验证。

| 路径 | 对应 kubectl | 用途 |
|---|---|---|
| **集群 → Workload → Pods（按命名空间筛选）** | `kubectl --kubeconfig ./kubeconfig get pods -n <ns>` | 一目了然查看 READY/STATUS/RESTARTS，快速发现异常 Pod |
| **Pod 详情 → Events** | `kubectl --kubeconfig ./kubeconfig describe pod <pod> -n <ns>` 的 Events 段 | 按时间顺序的事件，便于快速定位异常 |
| **Pod 详情 → Logs** | `kubectl --kubeconfig ./kubeconfig logs <pod> -n <ns> -c <container>` | 可直接查看当前/上一容器日志 |
| **Pod 详情 → Conditions/Containers** | `kubectl --kubeconfig ./kubeconfig describe pod <pod> -n <ns>` | 查看探针失败、就绪状态、重启计数 |
| **集群 → Nodes → Node 详情 → Conditions** | `kubectl --kubeconfig ./kubeconfig describe node <node>` | 查看 NodeReady/Pressure 状态 |
| **集群 → Events（全局）** | `kubectl --kubeconfig ./kubeconfig get events -A --sort-by=.metadata.creationTimestamp` | 集群级近期事件流 |

> 推荐“UI 先发现异常 → 命令行深挖证据（events+describe+logs）”，既高效又能保证证据完整。

---

## 动手练习

1. **黄金链路演练**：任选 `probe-demo` 命名空间的 web Pod，按 §1.2 顺序依次执行 events（命名空间内）、`describe pod`、`logs`，用自己的话总结当前健康状态的证据链。
2. **事件排序练习**：执行 `kubectl --kubeconfig ./kubeconfig get events -A --sort-by=.metadata.creationTimestamp | tail -30`，找出最近 3 条 Warning/Normal 并推测其含义。
3. **CrashLoopBackOff 思路**：假设某 Pod 出现 CrashLoopBackOff，列出你会按什么顺序排查（至少 4 步），并说明为什么先查 `--previous` 日志。
4. **OOMKilled 判断**：列出判断 OOMKilled 的三个关键证据点（来自 `describe`/`logs`/`top` 中的线索）。
5. **Pending 分类**：写出 3 种导致 Pending 的不同原因及对应的排查命令和验证方式。
6. **Terminating 卡住分析**：区分“preStop/SIGTERM 超时”和“Finalizer 阻塞”这两种情况的判断方法及处理原则（强调风险控制）。
7. **Runbook 实战**：基于 §8 模板，从 `kubectl --kubeconfig ./kubeconfig get events -A --sort-by=.metadata.creationTimestamp | tail -20` 中任选一条事件填写一份最简 Runbook（现象→证据→可能根因→验证思路）。
8. **节点压力排障**：执行 `kubectl --kubeconfig ./kubeconfig top nodes` 和 `kubectl --kubeconfig ./kubeconfig describe node k3s-demo-server-1 | grep -A5 Conditions`，判断当前节点是否存在压力，给出结论和依据。

<details>
<summary>参考答案</summary>

1. 黄金链路：`kubectl -n probe-demo get events` → `kubectl -n probe-demo describe pod web-<hash>` → `kubectl -n probe-demo logs web-<hash>`，从事件到现状再到日志形成证据链。
2. `kubectl get events -A --sort-by=.metadata.creationTimestamp | tail -30`，任取最近 3 条 Warning（如 `FailedScheduling`/`BackOff`）结合资源与命名空间推测含义。
3. CrashLoopBackOff 排查顺序：① `describe pod` 看 `Last State`/`ExitCode`/Events → ② `logs --previous` 看**上一次**崩溃输出（最关键）→ ③ 检查 command/args/配置挂载 → ④ 检查依赖（下游服务、ConfigMap/Secret、镜像）。先查 `--previous` 是因为当前容器可能还没产生日志或已重启。
4. OOMKilled 三个证据：`describe` 的 `Last State: Terminated, Reason: OOMKilled, ExitCode 137`；`logs` 在中途被截断；`top`/监控显示内存逼近 `limits`。
5. Pending 三种原因：① 资源不足（`describe` Events `Insufficient cpu/memory`）；② 节点选择/污点不匹配（`FailedScheduling: node(s) didn't match nodeSelector/taints`）；③ 未绑定存储（`pod has unbound immediate PersistentVolumeClaims`）。
6. preStop/SIGTERM 超时：`describe` 长时间 `Terminating`、`terminationGracePeriodSeconds` 到期后强杀；Finalizer 阻塞：`kubectl get pod -o yaml` 的 `metadata.finalizers` 非空。处理原则：优先排查根因（节点/CSI），谨慎手动移除 finalizer，避免数据损坏。
7. 按 §8 模板填写：现象（事件原文）→ 证据（describe/logs）→ 可能根因 → 验证思路。
8. `top nodes` 看 CPU/内存使用率；`describe node | grep -A5 Conditions` 看 `MemoryPressure/DiskPressure/PIDPressure` 是否 `False`——若均为 `False` 且 `Ready True`，则节点健康、无压力。

</details>

---

## 附录：本章排障速记

- **第一现场**：`kubectl --kubeconfig ./kubeconfig get events -A --sort-by=.metadata.creationTimestamp | tail -40`
- **Pod 全貌**：`kubectl --kubeconfig ./kubeconfig describe pod <pod> -n <ns>`（Events + Conditions + 容器状态最全）
- **崩溃溯源**：`kubectl --kubeconfig ./kubeconfig logs <pod> -n <ns> -c <container> --previous`（CrashLoopBackOff 必查）
- **资源压力**：`kubectl --kubeconfig ./kubeconfig top nodes`、`kubectl --kubeconfig ./kubeconfig top pods -A`
- **节点健康**：`kubectl --kubeconfig ./kubeconfig describe node <n>`（Ready/Pressure）
- **工作负载卡住**：`kubectl --kubeconfig ./kubeconfig rollout status deploy/<name> -n <ns>` + `kubectl --kubeconfig ./kubeconfig describe deploy/<name> -n <ns>`

> 本章为只读排障演练，不创建额外资源；如需动手演练，可复用第 33 章的 `probe-demo` 命名空间，演示结束后按需清理：`kubectl --kubeconfig ./kubeconfig delete ns probe-demo`。
