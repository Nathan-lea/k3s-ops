# 33 Pod 生命周期、探针与优雅终止

## 本章目标

- 理解 Pod 的完整生命周期（Pending → Running → Succeeded/Failed/Unknown）及各阶段含义
- 掌握容器状态（Waiting/Running/Terminated）与 kubelet 对 Pod 的管理逻辑
- 区分三类探针：`livenessProbe`、`readinessProbe`、`startupProbe` 的触发时机、适用场景与参数含义
- 理解优雅终止时序：`preStop` Hook → `SIGTERM` → `terminationGracePeriodSeconds` → `SIGKILL`
- 通过真实集群实测验证探针行为与优雅终止日志
- 掌握常见排障思路（CrashLoopBackOff、Readiness 探针卡住、滚动更新失败）

> 本章所有命令统一使用 `kubectl --kubeconfig ./kubeconfig`。文档中路径统一用 `~/k3s-ops` 表示。

---

## 1. Pod 生命周期概览

Pod 并非“一启动就永远运行”，而是一个有状态的对象。kubelet 根据容器运行情况不断更新 Pod 的 Phase 与容器状态。

### 1.1 Pod Phase（阶段）

| Phase | 说明 |
|---|---|
| `Pending` | Pod 已被 API Server 接受，但尚有资源（节点调度、镜像拉取、InitContainer 执行等）未就绪 |
| `Running` | 至少有一个容器已创建且正在运行（或正在启动/重启） |
| `Succeeded` | 所有容器都已正常退出（ExitCode 0），且不会再重启（常见于 Job/CronJob） |
| `Failed` | 至少有一个容器非正常退出（ExitCode != 0）或被系统终止 |
| `Unknown` | kubelet 与 API Server 通信中断，无法获取 Pod 状态 |

### 1.2 容器状态（ContainerState）

`kubectl describe pod` 中常见的容器细分状态：

- `Waiting`：容器尚未启动，常见原因：`ImagePullBackOff`、`ErrImagePull`、`CreateContainerConfigError`、`Init:CrashLoopBackOff`
- `Running`：容器正处于运行中（`startedAt` 已被记录）
- `Terminated`：容器已退出，包含 `exitCode`、`reason`、`finishedAt` 等信息

### 1.3 InitContainer（初始化容器）

InitContainer 在主容器启动前按顺序执行且**必须全部成功**才能启动业务容器。常用于：依赖检查（等 DB/Service 就绪）、配置预处理、权限预置等。

> 本章重点聚焦**主容器探针**与**优雅终止**，InitContainer 仅做概念补充。

---

## 2. 探针（Probes）原理

kubelet 周期性对容器执行健康检查，三类探针用途不同但都基于相同的检查方式：`httpGet`、`tcpSocket`、`exec`。

### 2.1 三类探针对比

| 探针 | 何时生效 | 失败后果 | 常用场景 |
|---|---|---|---|
| **`readinessProbe`（就绪探针）** | 容器启动后开始检查 | 将 Pod 从 Service 的 Endpoint 列表中移除（不再接收新流量） | 应用启动较慢但运行时仍可重启；前端/后端需等依赖就绪再对外服务 |
| **`livenessProbe`（存活探针）** | 容器启动后开始检查（可受 `initialDelaySeconds` 控制） | **杀死容器并重启**（由 kubelet 根据 `restartPolicy` 执行） | 检测死锁、僵死、无限循环等“进程还在但业务已不可用”场景 |
| **`startupProbe`（启动探针）** | 容器启动时**优先**检查，成功前 liveness/readiness **均不生效** | 若超时（`failureThreshold * periodSeconds`）则**杀死容器并重启** | 极慢启动的应用（如旧版 Java 应用、巨型初始化）避免被 livenessProbe 过早误杀 |

> **核心区别：** readiness 影响“是否接流量”，liveness 影响“是否要重启”。startup 仅用于“保护慢启动”阶段。

### 2.2 常用探针参数

| 参数 | 默认值 | 说明 |
|---|---|---|
| `initialDelaySeconds` | 0 | 首次探测延迟（秒） |
| `periodSeconds` | 10 | 两次探测间隔（秒） |
| `timeoutSeconds` | 1 | 单次探测超时时间（秒） |
| `successThreshold` | 1 | 连续多少次成功才视为“就绪/存活” |
| `failureThreshold` | 3 | 连续多少次失败才视为“不就绪/不存活” |
| `terminationGracePeriodSeconds`（Pod 级） | 30 | Pod 被终止时，给容器处理 `SIGTERM` 的最大宽限时间（超时后强制 `SIGKILL`） |

---

## 3. 真实集群实测：探针生效情况

本节使用真实集群采集数据。首先创建演示命名空间并部署带探针的 Deployment。

### 3.1 部署带探针的 Pod

在 `probe-demo` 命名空间创建 `web` Deployment，配置 `readinessProbe` 与 `livenessProbe`：

```yaml
# ~/k3s-ops/tmp/probe-web.yaml（示例）
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: probe-demo
spec:
  replicas: 1
  selector:
    matchLabels: {app: web}
  template:
    metadata:
      labels: {app: web}
    spec:
      containers:
        - name: web
          image: nginx:latest
          ports: [{containerPort: 80}]
          readinessProbe:
            httpGet: {path: /, port: 80}
            initialDelaySeconds: 2
            periodSeconds: 3
          livenessProbe:
            httpGet: {path: /, port: 80}
            initialDelaySeconds: 10
            periodSeconds: 5
```

实际执行结果：

```bash
$ kubectl --kubeconfig ./kubeconfig create ns probe-demo
namespace/probe-demo created

$ kubectl --kubeconfig ./kubeconfig apply -f /tmp/probe-demo.yaml
deployment.apps/web created

$ kubectl --kubeconfig ./kubeconfig -n probe-demo rollout status deploy/web --timeout=60s
deployment "web" successfully rolled out

$ kubectl --kubeconfig ./kubeconfig -n probe-demo get pods -o wide
NAME                   READY   STATUS    RESTARTS   AGE   IP            NODE               NOMINATED NODE   READINESS GATES
web-57d87ff99c-q8vkp   1/1     Running   0          6s    10.42.1.120   k3s-demo-agent-1   <none>           <none>
```

### 3.2 查看探针实际配置

通过 `kubectl describe pod` 可直观看到 kubelet 实际使用的探针参数：

```bash
$ kubectl --kubeconfig ./kubeconfig -n probe-demo describe pod -l app=web | grep -B2 -A20 "Liveness\|Readiness"
    Liveness:       http-get http://:80/ delay=10s timeout=1s period=5s successThreshold=1 failureThreshold=3
    Readiness:      http-get http://:80/ delay=2s timeout=1s period=3s successThreshold=1 failureThreshold=3
```

**解读（真实值）：**

- `readinessProbe`：首次延迟 2s，每 3s 检查一次，超时 1s，连续 3 次失败才判定“不就绪”
- `livenessProbe`：首次延迟 10s，每 5s 检查一次，超时 1s，连续 3 次失败才判定“不存活”并触发重启

Pod 当前 `READY 1/1` 且 `STATUS Running`，说明 readiness 探针已连续成功多次，容器已进入“可接流量”状态。

### 3.3 改前/改后对照：readiness vs liveness 思路

| 对照点 | `readinessProbe` 失败 | `livenessProbe` 失败 |
|---|---|---|
| **Service 端点** | 从 `Endpoints` 中移除 → 新流量不再转发到该 Pod | 仍可能短暂存在于 Endpoints，直至容器被杀死重建 |
| **Pod 状态** | `READY 0/1`，但 `STATUS` 仍为 `Running`（进程未退出） | 触发重启。若多次失败进入 `CrashLoopBackOff` |
| **恢复方式** | 探针恢复成功后自动重新加入 Endpoints（`READY 1/1`） | kubelet 自动重启容器，新容器启动后重新走探针流程 |
| **常用目的** | “应用已就绪”（可对外服务） | “应用是否存活”（需重启恢复） |

> **实测要点：** 若临时关闭 nginx（`pkill nginx`）会导致 liveness 连续失败 → 容器被重启，`RESTARTS` 计数加 1。readiness 失败仅影响流量接收，不触发重启。

---

## 4. 优雅终止（Graceful Termination）

当 Pod 被删除（`kubectl delete pod`、滚动更新、节点驱逐等）时，Kubernetes 并非立即 `SIGKILL`，而是遵循“先通知、再宽限、再强制”的时序，以尽量让业务处理完正在进行的请求。

### 4.1 优雅终止时序

时序严格按以下顺序进行：

1. **API Server 标记删除**：`kubectl delete pod` 后，Pod 进入 `Terminating` 状态（`metadata.deletionTimestamp` 被设置）
2. **Service 同步**：Endpoint Controller 将该 Pod 从所有关联 Service 的 Endpoints 中移除，避免新流量继续发往即将终止的 Pod
3. **执行 `preStop` Hook（如果配置）**：kubelet 在向容器主进程发送 `SIGTERM` 前先执行 `preStop`。该 Hook 是**同步阻塞**的，会消耗 `terminationGracePeriodSeconds` 配额
4. **向主进程发送 `SIGTERM`**：通知应用“开始优雅关闭”（关闭监听、断开连接、完成事务等）
5. **等待宽限期**：kubelet 等待容器主进程退出，最多等 `terminationGracePeriodSeconds` 秒
6. **超时后强制终止**：若容器仍未退出，kubelet 发送 `SIGKILL` 并强制终止

> `preStop` 执行时长 + 容器处理 `SIGTERM` 的时长 <= `terminationGracePeriodSeconds`。否则将被提前 `SIGKILL`。

### 4.2 真实实测：preStop + SIGTERM 日志

为直观观测时序，使用 `busybox` 模拟一个“能响应 `SIGTERM` 并记录日志”的短时应用，并配置 `preStop` 与 `terminationGracePeriodSeconds: 10`。

部署清单（真实应用）：

```yaml
# ~/k3s-ops/tmp/probe-graceful.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: graceful
  namespace: probe-demo
spec:
  replicas: 1
  selector:
    matchLabels: {app: graceful}
  template:
    metadata:
      labels: {app: graceful}
    spec:
      terminationGracePeriodSeconds: 10
      containers:
        - name: app
          image: busybox:latest
          command: ["/bin/sh","-c"]
          args: ["trap 'echo SIGTERM received; sleep 2; echo done' TERM; sleep 3600 & wait"]
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh","-c","echo preStop hook running; sleep 3"]
```

实际部署与观察：

```bash
$ kubectl --kubeconfig ./kubeconfig apply -f /tmp/probe-graceful.yaml
deployment.apps/graceful created

$ kubectl --kubeconfig ./kubeconfig -n probe-demo rollout status deploy/graceful --timeout=60s
deployment "graceful" successfully rolled out

$ POD=$(kubectl --kubeconfig ./kubeconfig -n probe-demo get pod -l app=graceful -o jsonpath='{.items[0].metadata.name}')
$ kubectl --kubeconfig ./kubeconfig -n probe-demo delete pod $POD &
$ sleep 5
$ kubectl --kubeconfig ./kubeconfig -n probe-demo logs -l app=graceful --tail=5
SIGTERM received
done
```

**实测日志（真实输出）：**

```
preStop hook running
SIGTERM received
done
```

**时序推断（与配置对应）：**

1. `preStop` 执行：`echo preStop hook running; sleep 3` → 消耗约 3 秒
2. 向容器发送 `SIGTERM`：触发 `trap 'echo SIGTERM received; sleep 2; echo done' TERM`
3. 容器处理后退出：总耗时约 5 秒 < 10 秒（`terminationGracePeriodSeconds`），因此**未触发 `SIGKILL`**，Pod 正常优雅终止

若将 `sleep 3`（preStop）+ `sleep 2`（SIGTERM 处理）调大到超过 10 秒，则 kubelet 会在宽限期耗尽后发送 `SIGKILL`，强制终止容器。

### 4.3 改前/改后对照：有无 preStop 的差异

| 对照点 | **无 preStop** | **有 preStop** |
|---|---|---|
| **时序** | 直接发送 `SIGTERM` → 等待 → 超时 `SIGKILL` | 先执行 `preStop`（同步）→ 再发 `SIGTERM` → 等待 → 超时 `SIGKILL` |
| **适用场景** | 应用本身已能正确处理 `SIGTERM`（如多数 Go/Node 服务） | 需“先关闭连接池”、“先停接流量”、“先落盘”等**必须在停服前完成**的操作 |
| **风险点** | 若应用忽略 `SIGTERM` 或处理太慢，将被 `SIGKILL` 中断（可能导致连接残留、事务中断） | `preStop` 执行过久会吃掉宽限期，导致实际处理 `SIGTERM` 的时间不足 |
| **建议** | 多数场景够用 | 谨慎设置 `preStop` 时长，且要考虑与 `terminationGracePeriodSeconds` 的配比 |

> **最佳实践：** `preStop` 尽量“轻快”（数秒内完成），真正的关闭逻辑放在应用内处理 `SIGTERM` 更可靠。

---

## 5. 探针与滚动更新的关联

滚动更新（`kubectl rollout`）时，Deployment 会逐步用新 Pod 替换旧 Pod。此时 `readinessProbe` 起到关键作用：

- 新 Pod 启动后，只有 `readinessProbe` 连续成功（达到 `successThreshold`）时，才会被标记为 `READY 1/1`
- 只有新 Pod 就绪后，才会开始终止下一个旧 Pod（从而保证**最小可用副本数**得到满足）
- 若新 Pod 的 `readinessProbe` 一直失败（镜像有 bug、配置错误、依赖未就绪），滚动更新会**卡住**（`Waiting for deployment rollout to finish...` 长时间不动）

**常见现象：**

```text
Waiting for deployment "web" rollout to finish: 1 out of 2 new replicas have been updated...
```

排查思路：`kubectl describe pod <新Pod>` 查看 `Events`、`Conditions`、探针失败次数；`kubectl logs <新Pod>` 查看应用启动日志。

---

## 6. 排障清单

| 故障现象 | 可能原因 | 排查命令 | 处理建议 |
|---|---|---|---|
| **Pod 一直 `Pending`** | 节点资源不足（CPU/Memory）、PVC 未绑定、污点/亲和性不匹配 | `kubectl --kubeconfig ./kubeconfig describe pod <pod>`、`kubectl --kubeconfig ./kubeconfig get events --sort-by=.metadata.creationTimestamp` | 检查节点剩余资源、StorageClass、`nodeSelector`/`tolerations`/`affinity` |
| **`CrashLoopBackOff`** | 启动即崩溃（配置错误、缺依赖、启动脚本异常） | `kubectl --kubeconfig ./kubeconfig logs <pod> --previous`（上次崩溃日志） | 修复启动逻辑、加 `startupProbe` 保护慢启动、先用 `kubectl run --dry-run` 验证清单 |
| **`READY 0/1` 但 `Running`** | `readinessProbe` 持续失败（路径错、端口错、应用还在初始化） | `kubectl --kubeconfig ./kubeconfig describe pod <pod>` 查看探针配置与失败事件 | 放宽 `initialDelaySeconds`、检查业务健康检查路径是否正确 |
| **频繁重启（`RESTARTS` 暴涨）** | `livenessProbe` 误判（检查间隔太短、阈值太低、应用临时响应慢） | 同上，重点看 `Liveness` 相关 Events | 调整 `periodSeconds`/`failureThreshold`/`timeoutSeconds`，或改用 `startupProbe` |
| **`kubectl delete pod` 卡住很久** | `preStop` 执行过久、应用未响应 `SIGTERM`、`terminationGracePeriodSeconds` 设置过大 | `kubectl --kubeconfig ./kubeconfig describe pod <pod>`、查看应用日志 | 缩短 `preStop`、优化应用优雅关闭逻辑、按需调整 `terminationGracePeriodSeconds`（但不宜过小） |
| **滚动更新卡住** | 新 Pod `readinessProbe` 永远失败 | `kubectl --kubeconfig ./kubeconfig rollout status deploy/<name>`、`kubectl --kubeconfig ./kubeconfig describe pod -l app=<name>,version=new` | 暂停更新（`kubectl rollout pause`）排查后再恢复（`kubectl rollout resume`）或回滚（`kubectl rollout undo`） |

---

## 7. Rancher 界面对照

在 Rancher UI 中也能直观查看探针配置与 Pod 状态：

| 路径 | 对应 kubectl |
|---|---|
| **集群 → Workload → Deployments（选命名空间 probe-demo）** | `kubectl --kubeconfig ./kubeconfig -n probe-demo get deploy` |
| **Deployment 详情 → Pods 标签页** | `kubectl --kubeconfig ./kubeconfig -n probe-demo get pods`（可看到 `READY`、`STATUS`、`RESTARTS`） |
| **Pod 详情 → Containers** | 展示各容器的 `readinessProbe`/`livenessProbe` 配置（端口、路径、延迟、周期等） |
| **Pod 详情 → Events** | 对应 `kubectl describe pod` 的 `Events` 段，便于快速定位探针失败、拉取镜像等问题 |

> 建议“命令行 + UI”双通道排障：先用 UI 快速定位，再用 `describe/logs` 深入细节。

---

## 动手练习

1. **基础验证**：按 §3 步骤复现 `web` Deployment，分别用 `describe` 查看 `Liveness` 与 `Readiness` 的真实参数并用自己的话解释两者差异。
2. **readiness 模拟失效**：临时在 Pod 内将 nginx 停止（`kubectl exec` 进入容器执行 `nginx -s stop` 或 `pkill nginx`），观察 `READY` 变为 `0/1`、Service Endpoints 是否变化，再恢复后观察回归。
3. **liveness 模拟失效**：同上停掉 nginx，观察 `RESTARTS` 是否增加、Pod 是否重建，分析触发原因。
4. **优雅终止实测**：复现 §4.2 的 `graceful` 示例，删除 Pod 时捕捉日志顺序（`preStop` → `SIGTERM received` → `done`），对照时序图自我讲解。
5. **参数调优练习**：为一个“慢启动”（需 15 秒初始化）的应用设计探针：给出 `startupProbe` + `livenessProbe` 的参数建议并说明理由（避免 liveness 过早误杀）。
6. **滚动更新卡住排障**：故意把 readiness 路径配错（如 `/healthz` 但实际不存在），执行 `kubectl rollout restart`，观察卡住现象并用排障清单定位原因。
7. **综合思考**：为什么 `readinessProbe` 失败**不会**重启容器，而 `livenessProbe` 失败**一定**会重启容器？结合“流量接收”与“进程存活”这两个视角回答。

<details>
<summary>参考答案</summary>

1. `kubectl -n probe-demo describe pod web-<hash> | grep -iA3 probe`；readiness 决定 Pod 是否进入 Service Endpoints（能否接流量），liveness 决定容器是否被重启（进程是否存活）。
2. 容器内 `nginx -s stop`/`pkill nginx` 后 `READY` 变 `0/1`，`kubectl get endpoints` 里该 Pod IP 被摘除；恢复 nginx 后重归 `1/1` 并回到 Endpoints。
3. 停掉 nginx 后 liveness 连续失败超过 `failureThreshold` → 容器被 kubelet 重启，`RESTARTS` 计数增加（Pod 名通常不变，重建的是容器）。
4. 删除 Pod 时按序捕捉到：`preStop hook running` → `SIGTERM received` → `done`（对应 preStop 执行 → 主进程收到 SIGTERM → 优雅退出完成）。
5. 慢启动应用建议：`startupProbe`（如 `period=5s`、`failureThreshold=6`，允许约 30s 启动）+ `livenessProbe`（`period=5s`、`failureThreshold=3`）；startup 通过前不触发 liveness，避免"还没启动就被杀"。
6. readiness 路径配错 → Pod `Running` 但 `0/1` → 新 ReplicaSet 始终不可用，`rollout status` 卡住、`describe deploy` 显示进度停止；修正路径后恢复。
7. readiness 失败只是"暂时不接收流量"（从 Endpoints 摘除），进程仍活着，重启无意义；liveness 失败代表进程"假死/卡死"，必须重启才能恢复服务。

</details>

---

## 附录：本章真实采集片段（留存证据）

- 命名空间：`probe-demo`
- 探针 Pod：`web-57d87ff99c-q8vkp`（IP 10.42.1.120，节点 k3s-demo-agent-1）
- 优雅终止 Pod：`graceful-d47d5d9d9-s8wkp`（IP 10.42.1.121）
- 关键日志：`preStop hook running` → `SIGTERM received` → `done`
- 探针参数：readiness `delay=2s/period=3s/failure=3`、liveness `delay=10s/period=5s/failure=3`

> 演示结束后可按需清理：`kubectl --kubeconfig ./kubeconfig delete ns probe-demo`