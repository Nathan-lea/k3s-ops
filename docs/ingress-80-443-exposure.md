# nginx-ingress：节点 80/443 暴露（NodePort vs hostNetwork）全解析

> 本文基于本项目真实集群状态（nginx-ingress 已部署，类型为 NodePort 30080/30444）撰写，解释当前“为什么不能直接走节点 80/443 访问 Ingress”、改成 `hostNetwork: true + hostPort`（Controller 直接绑节点 80/443）的原理、操作步骤、风险、回滚以及持久化方式。

## 1. 前因：本集群 Ingress 现状

### 1.1 服务现状

```bash
kubectl --kubeconfig ./kubeconfig -n ingress-nginx get svc ingress-nginx-controller
```

输出：
```text
NAME                       TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)                      AGE
ingress-nginx-controller   NodePort   10.43.197.40    <none>        80:30080/TCP,443:30444/TCP   143d
```

- **类型**：`NodePort`
- **HTTP**：容器/Service 端口 `80` 映射到**节点 NodePort `30080`**
- **HTTPS**：容器/Service 端口 `443` 映射到**节点 NodePort `30444`**
- **EXTERNAL-IP**：`<none>`，对外通过**任意节点 IP + NodePort** 访问

### 1.2 Controller 是否占用节点 80/443

检查 Pod 是否用 `hostNetwork`：

```bash
kubectl --kubeconfig ./kubeconfig -n ingress-nginx get pods -o jsonpath='{range .items[*]}{.metadata.name}{" hostNetwork="}{.spec.hostNetwork}{" dnsPolicy="}{.spec.dnsPolicy}{"\n"}{end}'
```

输出示例：`ingress-nginx-controller-69b89bf9b4-fzh4b hostNetwork=`（空/false）

检查 Deployment 配置要点：

```bash
kubectl --kubeconfig ./kubeconfig -n ingress-nginx get deploy/ingress-nginx-controller -o jsonpath='{.spec.template.spec.hostNetwork}{"\n"}'
```

返回：`false`

也可查看 Controller 容器监听端口：容器内监听 `80`、`443`，但**不是通过 hostPort 绑到宿主机 80/443**。

所以结论：**当前 Ingress Controller 并未直接占用节点的 80/443。它只通过 kube-proxy 将 NodePort（30080/30444）暴露出来。**

### 1.3 为什么不能直接走节点 80/443

因为要让节点的 `80/TCP`、`443/TCP` 真正响应 HTTP/HTTPS 请求，必须有**某个进程**直接在宿主机网络栈上 `bind` 这两个端口。

目前的方式（NodePort）：
- 流量：`http://<节点IP>:30080`（或 `:30444`）→ kube-proxy → Service → Pod（ingress-nginx-controller）
- 节点自身的 `80/443` **空闲**（除非宿主机上已起了其它进程）

因此：
- **可用的入口是 30080/30444**，而不是 80/443。
- **设置域名后**，必须用 `http://<节点IP>:30080` 并带 `Host: your.domain`（HTTPS 对应 `:30444`）才能命中 Ingress 路由。
- **直接用 `http://<节点IP>`（省略 30080）走节点 80 是访问不到 Ingress 的。**

### 1.4 图解思路（文字版）

```
外部客户端
  └─ http://node:80        → 节点 80（空闲）→ 无响应（Controller 未监听）
  └─ http://node:30080     → kube-proxy 转发 → ingress-nginx-controller:80 → 按 Host 路由到后端 Service
```

要让第一条路也能走到 Ingress，就得让 Controller **直接绑定宿主机 80/443**。

## 2. 原理：hostNetwork: true + hostPort

### 2.1 什么是 hostNetwork

设置 `spec.template.spec.hostNetwork: true` 后，Pod 的网络命名空间会直接使用**节点的网络栈**。

效果：
- Pod 内的进程看到的 IP 就是**节点 IP**。
- Pod 可以直接 `bind` 节点上的端口（无需再走 NodePort/kube-proxy 的端口转发）。
- `containerPort: 80` 绑定的就是**节点的 80**。

nginx-ingress-controller 容器本身已监听 `80`、`443`。一旦启用 `hostNetwork: true`，它就会直接在节点上监听 `0.0.0.0:80` 和 `0.0.0.0:443`。

### 2.2 要不要配合 hostPort

对于 `hostNetwork: true` 的 Pod，**通常不需要额外加 `hostPort`**。因为端口已经是宿主机端口。加 `hostPort` 反而显得多余。

但如果未来改成**非 hostNetwork** 的 DaemonSet 想绑宿主机端口时才会用到 `hostPort`。这里目标是“直接绑节点 80/443”，最简方式就是 `hostNetwork: true`。

### 2.3 同时要改 dnsPolicy

当 Pod 用 `hostNetwork: true` 时，Kubernetes 推荐把 `dnsPolicy` 改成 `ClusterFirstWithHostNet`。

原因：这样 Pod 仍能解析集群内 Service 域名（如 `my-svc.default.svc.cluster.local`），同时也能走宿主机的 DNS 解析。否则有些集群内 DNS 解析路径可能受影响。

### 2.4 用 hostNetwork 后 Service 要怎么配

启用 `hostNetwork: true` 后，**外部流量已经是直接打到节点 IP:80/443**，不再需要经由 NodePort。

所以 Service 类型建议改成 **`ClusterIP`**（甚至可以考虑保留但没必要）。

理由：
- 去掉 `nodePort: 30080/30444`，更简洁、也避免误用。
- Ingress Controller 自身对外暴露的方式已经变成“直接宿主机端口”，Service 更多是给集群内组件（如 webhook、metrics 等）用。
- 保留 NodePort 也不会冲突（只是多了一个没必要的入口），但**清理掉更干净**。

### 2.5 副本数、调度与端口冲突（核心风险）

**最大风险：端口独占。**

- **端口冲突**：节点的 `80/443` 只能被**一个进程**监听。一旦某个 Pod 用了 `hostNetwork: true` 并绑定 80/443，同一节点就再也不能有第二个 Pod（或宿主机进程）去监听这两个端口。
- **副本数限制**：如果 Controller 还是 **Deployment** 且 `replicas > 1`，当 Pod 被调度到**同一个节点**时，第二个 Pod 会因端口被占用而**启动失败**（CrashLoopBackOff / `bind: address already in use`）。
- **多节点集群更明显**：要想每个节点都能直接用 80/443 暴露，最自然的方式是用 **DaemonSet** 而不是 Deployment。DaemonSet 保证**每个（符合条件的）节点恰好一个副本**，避免同节点冲突。
- **宿主机已有进程**：极少数宿主机上可能已经起了 `nginx/apache` 等监听 80/443。启用 hostNetwork 前务必检查：`ss -tlnp | grep -E ':(80|443)\s'`。

**本集群现状**：Controller 当前是 **Deployment**，`replicas: 1`。节点也只有 2 个（server-1、agent-1）。如果只想**临时验证**单副本改 hostNetwork 是可行的。但要走到“生产可用”，更推荐改成 DaemonSet。

### 2.6 hostNetwork 的利弊

| 对比维度 | NodePort（当前） | hostNetwork: true（直接绑 80/443） |
|---|---|---|
| **访问方式** | `http://<节点IP>:30080`、`https://<节点IP>:30444`（需带端口） | `http://<节点IP>`、`https://<节点IP>`（直接走 80/443） |
| **是否占用节点 80/443** | 否（由 kube-proxy 管理） | **是**（直接 bind 宿主机端口） |
| **端口冲突风险** | 极低（NodePort 段 30000–32767） | **较高**（80/443 全局唯一） |
| **适用场景** | 本地教学、临时演示、通用做法（最省事也最安全） | 想“省略端口”直接暴露到外网、前面无 LB/反代时常用 |
| **Service 类型** | NodePort | 建议改成 ClusterIP |
| **副本策略** | Deployment（可多副本）也没端口冲突 | 若多副本调度到同节点→端口冲突；首选 **DaemonSet** |
| **网络隔离** | Pod 网络隔离更“纯粹” | Pod 直接用宿主机网络栈（权限面略有变化） |
| **DNS 行为** | 默认 `ClusterFirst` 即可 | 建议用 `ClusterFirstWithHostNet` |

## 3. 操作前准备（必查）

先确认节点上 80/443 是否已被占用：

```bash
# SSH 到节点检查（推荐用 k3s-ops.sh ssh）
./k3s-ops.sh ssh server-1
# 登录后
sudo ss -tlnp | grep -E ':(80|443)\b'
```

也可直接在宿主机（或通过 kubectl debug）看。若返回空，说明当前空闲。

再确认当前 Controller 副本数：

```bash
kubectl --kubeconfig ./kubeconfig -n ingress-nginx get deploy/ingress-nginx-controller -o jsonpath='{.spec.replicas}{"\n"}'
```

当前一般是 `1`。如果是 `>1`，强烈建议改成 DaemonSet 再用 hostNetwork。

## 4. 方法 A：临时修改（kubectl patch/edit，立即生效）

> **适用场景**：临时验证“改成 hostNetwork 后能不能直接走节点 80/443 访问”。验证完后按 §6 回滚即可。
> **影响**：Deployment 会触发滚动更新，Pod 重建（短暂中断）。

### 步骤 1：加 hostNetwork 和 dnsPolicy

```bash
kubectl --kubeconfig ./kubeconfig -n ingress-nginx patch deploy/ingress-nginx-controller --type='merge' -p='{
  "spec": {
    "template": {
      "spec": {
        "hostNetwork": true,
        "dnsPolicy": "ClusterFirstWithHostNet"
      }
    }
  }
}'
```

### 步骤 2：把 Service 从 NodePort 改成 ClusterIP（推荐）

```bash
kubectl --kubeconfig ./kubeconfig -n ingress-nginx patch svc/ingress-nginx-controller --type='json' -p='[
  {"op":"replace","path":"/spec/type","value":"ClusterIP"},
  {"op":"remove","path":"/spec/ports/0/nodePort"},
  {"op":"remove","path":"/spec/ports/1/nodePort"}
]'
```

> 如果你想**保留 NodePort** 也没问题（多一个入口而已）。但改成 ClusterIP 更贴合“直接走宿主机 80/443”的思路。

### 步骤 3：等待 Pod 就绪

```bash
kubectl --kubeconfig ./kubeconfig -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=120s
```

### 步骤 4：验证 hostNetwork 生效

```bash
kubectl --kubeconfig ./kubeconfig -n ingress-nginx get pods -o jsonpath='{range .items[*]}{.metadata.name}{" hostNetwork="}{.spec.hostNetwork}{" dnsPolicy="}{.spec.dnsPolicy}{"\n"}{end}'
```

预期：`hostNetwork=true`、`dnsPolicy=ClusterFirstWithHostNet`

### 步骤 5：验证节点 80/443 已被监听

SSH 到节点：

```bash
./k3s-ops.sh ssh server-1
# 登录后
sudo ss -tlnp | grep -E ':(80|443)\b'
# 或
sudo netstat -tlnp 2>/dev/null | grep -E ':(80|443)\b'
```

预期能看到 `nginx-ingress-controller`（或进程名含 nginx）监听 `0.0.0.0:80`、`0.0.0.0:443`。

### 步骤 6：验证域名直接走 80/443 访问

回到宿主机（或任意能通节点 IP 的机器）：

```bash
# 假设你已有 Ingress 配置了 host: example.local
curl -I -H "Host: example.local" http://192.168.56.10/
curl -k -I -H "Host: example.local" https://192.168.56.10/
```

- 不再用 `:30080`、`:30444`。
- 直接走节点 IP 的 `80/443` 即可命中 Ingress 路由。

如果返回 `200 OK`（或 Ingress 配置的预期状态码），说明生效成功。

## 5. 方法 B：持久化（改 Helm values.yaml，推荐长期用）

本项目 nginx-ingress 是通过 Helm 部署（见 `addons/ingress/`）。用 `kubectl patch` 的改动在下次 **Helm upgrade** 时会被覆盖。

要持久化，得改 values。

### 步骤 1：确认 values 文件路径

本项目里常见是 `addons/ingress/values.yaml`。结构因版本略有不同。先大致看一下：

```bash
cat ~/k3s-ops/addons/ingress/values.yaml 2>&1 | head -40
```

### 步骤 2：在 values 里加 hostNetwork 配置

以 nginx-ingress 官方 chart（4.11.x）常用结构为例，在 `controller:` 下加：

```yaml
ingress-nginx:
  controller:
    hostNetwork: true
    dnsPolicy: ClusterFirstWithHostNet
    service:
      type: ClusterIP
    # 如果想改成 DaemonSet（更适合 hostNetwork 多节点场景）
    # kind: DaemonSet
    # updateStrategy:
    #   type: RollingUpdate
```

> **注意**：上面的 `ingress-nginx:` 顶层 key 要和你现有 `values.yaml` 的实际顶层结构保持一致。也可能直接是 `controller:` 顶级，视 chart 包装方式而定。按文件实际结构微调即可。

如果想走更“干净”的 hostNetwork 思路（多节点建议），可以把 `kind: DaemonSet` 打开。前提是副本数策略要配合节点亲和，不要出现同节点多副本。

### 步骤 3：重新应用（Helm upgrade）

进入仓库根目录，按项目现有的 Helm 应用方式操作。

常见做法（以本项目惯用命令推测）：

```bash
# 假设用 helm upgrade --install
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace \
  -f ~/k3s-ops/addons/ingress/values.yaml
```

> 具体命令以项目脚本（如 `k3s-ops.sh deploy-ingress`）为准更保险。若项目已有 `k3s-ops.sh deploy-ingress`，直接跑它也会应用最新 values。

应用后重复 §4 步骤 4–6 验证。

## 6. 回滚

### 6.1 临时改动（方法 A）回滚

改回 Deployment 配置：

```bash
kubectl --kubeconfig ./kubeconfig -n ingress-nginx patch deploy/ingress-nginx-controller --type='merge' -p='{
  "spec": {
    "template": {
      "spec": {
        "hostNetwork": false,
        "dnsPolicy": "ClusterFirst"
      }
    }
  }
}'
```

改回 Service NodePort：

```bash
kubectl --kubeconfig ./kubeconfig -n ingress-nginx patch svc/ingress-nginx-controller --type='json' -p='[
  {"op":"replace","path":"/spec/type","value":"NodePort"},
  {"op":"add","path":"/spec/ports/0/nodePort","value":30080},
  {"op":"add","path":"/spec/ports/1/nodePort","value":30444}
]'
```

等待就绪并验证：

```bash
kubectl --kubeconfig ./kubeconfig -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=120s
kubectl --kubeconfig ./kubeconfig -n ingress-nginx get pods -o jsonpath='{range .items[*]}{.metadata.name}{" hostNetwork="}{.spec.hostNetwork}{" dnsPolicy="}{.spec.dnsPolicy}{"\n"}{end}'
```

预期：`hostNetwork=`（false）、`dnsPolicy=ClusterFirst`

此时恢复成原来的访问方式：`http://<节点IP>:30080`、`https://<节点IP>:30444`。

### 6.2 持久化改动（方法 B）回滚

把 `addons/ingress/values.yaml` 恢复原状（去掉 `hostNetwork: true`、`dnsPolicy: ClusterFirstWithHostNet`、`service.type: ClusterIP`，改回 `NodePort` 或保留原配置），再重新 Helm upgrade 即可。

## 7. 风险评估与最佳实践

| 风险点 | 说明 | 建议 |
|---|---|---|
| **端口独占** | 节点 80/443 全局唯一。同节点只能有一个进程监听。 | 若副本数>1 或多节点都要跑，**改成 DaemonSet**（每节点恰好一副本）。当前单副本可先验。 |
| **调度约束** | hostNetwork Pod 的调度没额外限制时，理论上可调到任意节点。万一调到已被占用 80/443 的节点就失败。 | 用 DaemonSet + 合理的节点选择器（nodeSelector/tolerations/affinity）控制范围。 |
| **安全性** | `hostNetwork: true` 让 Pod 直接用宿主机网络栈，丢失了一层“Pod 网络隔离”。部分安全策略（NetworkPolicy）对 hostNetwork Pod 的约束也不同。 | 教学环境可接受。生产环境要结合安全基线评估是否合规。 |
| **与宿主机冲突** | 宿主机上若已装 nginx/keepalived/sshd 相关转发等也监听 80/443，会导致 Controller 无法启动。 | 启用前务必用 `ss -tlnp \| grep :(80\|443)` 检查。 |
| **升级/回滚** | 滚动更新时，新 Pod 起不来（端口被旧 Pod 占用）极少见但理论存在。 | 操作时留意 `kubectl describe pod`、`kubectl events`。 |
| **kube-proxy 依赖降低** | 启用后走 NodePort 的入口用得少了（改走宿主机直绑）。这不是坏事，但要意识到暴露方式变了。 | 同时清理 NodePort（改 ClusterIP）最省事。 |

## 8. 推荐结论

- **日常教学/演示（本项目当前场景）**：**维持现状 NodePort（30080/30444）最省心、最安全**。域名访问配合 `Host` 头完全可用，也没端口冲突风险。
- **想“省略端口直接走 80/443”**：可以用**方法 A**临时体验一下（单副本场景下没大问题）。
- **真要长期用宿主机 80/443 暴露**：建议**改成 DaemonSet + hostNetwork: true**，并配合 `dnsPolicy: ClusterFirstWithHostNet`、Service 改为 `ClusterIP`。且要先确认节点 80/443 空闲。

**个人建议**：如果只是“想知道能不能”，用**方法 A**验证即可。**如果不是强烈需求，个人更倾向保留 NodePort 方案。**
