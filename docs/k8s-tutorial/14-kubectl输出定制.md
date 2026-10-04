# 14 kubectl 输出定制：-o/--output 与 custom-columns

## 本章目标

- 掌握 `kubectl` 的 `-o/--output` 各格式：`wide`/`name`/`json`/`yaml`/`jsonpath`/`custom-columns`
- **重点**：用 `custom-columns` 自定义输出列，把不需要的字段裁掉、只留关心的
- 看懂资源**定义文件的格式与内容**（`apiVersion`/`kind`/`metadata`/`spec`/`status`），知道字段路径从哪来
- 学会用 `kubectl explain` 反查字段、用 `--sort-by` 排序、组合 `-l` 过滤
- 用 `-o yaml/json` 对接自动化脚本与备份

> 前置：任意章节均可；若配合第 13 章（Label）与 `-l` 组合使用效果更好。
> 本章所有输出来自本集群真实执行。

---

## 1. 为什么需要定制输出

`kubectl get` 默认表格只显示固定列：

```text
NAME                          READY   STATUS    RESTARTS      AGE
nginx-demo-559f959666-59frr   1/1     Running   1 (84m ago)   25h
```

但生产排障经常要：Pod 的 **IP**、所在**节点**、容器**镜像**、**标签**、节点**内网 IP/系统版本**……这些"多出来的列"默认表格不显示。要拿到它们，就得用 `-o` 定制。

## 2. 资源定义文件的格式与内容（字段路径的来源）

**定制输出 = 按字段路径取数**。字段路径长什么样，取决于资源对象的 JSON/YAML 结构。所有 K8s 资源都是同一套骨架：

```yaml
apiVersion: apps/v1          # API 组/版本 → 决定"这个资源属于哪套定义"
kind: Deployment             # 资源类型
metadata:                    # 元数据：name/namespace/labels/annotations/uid...
  name: nginx-demo
  namespace: lab
  labels:
    app: nginx-demo
spec:                        # 期望状态（用户声明）
  replicas: 5
  selector:
    matchLabels:
      app: nginx-demo
  template:                  # Pod 模板
    metadata:
      labels:
        app: nginx-demo
    spec:
      containers:
      - name: nginx
        image: nginx:latest
status:                      # 实际状态（系统回写）
  readyReplicas: 5
  conditions: []
```

对照真实 Pod 的 JSON（本集群）：

```json
{
    "apiVersion": "v1",
    "kind": "Pod",
    "metadata": {
        "labels": { "app": "nginx-demo", "pod-template-hash": "559f959666" },
        "name": "nginx-demo-559f959666-59frr",
        "namespace": "lab",
        "ownerReferences": [ { "kind": "ReplicaSet", ... } ]
    },
    "spec": { "containers": [ { "image": "nginx:latest", "name": "nginx" } ] },
    "status": { "podIP": "10.42.0.5", "nodeName": "k3s-demo-server-1" }
}
```

**定制列的路径就是在 JSON 里"点"出来的**：

| 想取什么 | 路径 |
|---------|------|
| Pod 名字 | `.metadata.name` |
| Pod IP | `.status.podIP` |
| 所在节点 | `.spec.nodeName` |
| 镜像 | `.spec.containers[*].image` |
| 标签 | `.metadata.labels.app` |

> 路径里的 `.` 表示层级，`[*]` 表示"所有元素"。这就是 `custom-columns`/`jsonpath` 的数据基础。

## 3. 各输出格式速览

| 格式 | 用途 | 真实示例（本集群） |
|------|------|------------------|
| （默认） | 快速查看 | READY/STATUS/RESTARTS/AGE |
| `-o wide` | 默认 + IP/节点/镜像 | 见 4.1 |
| `-o name` | 只输出 `类型/名字`，**脚本最爱** | `pod/nginx-demo-...` |
| `-o json` | 完整 JSON（机器可读） | 见 4.2 |
| `-o yaml` | 完整 YAML（人读/备份/apply） | 见 4.2 |
| `-o jsonpath='...'` | 精确取一条字段或拼接 | 见 4.4 |
| `-o custom-columns=...` | **自定义表格列**（本章重点） | 见 4.3 |

## 4. 本集群实站对照

### 4.1 -o wide：多出 IP/节点/就绪门控

```bash
kubectl -n lab get pods -o wide
```

真实输出：

```text
NAME                          READY   STATUS    RESTARTS      AGE   IP            NODE                NOMINATED NODE   READINESS GATES
nginx-demo-559f959666-59frr   1/1     Running   1 (84m ago)   25h   10.42.0.5     k3s-demo-server-1   <none>           <none>
nginx-demo-559f959666-kv4nv   1/1     Running   1 (84m ago)   25h   10.42.0.6     k3s-demo-server-1   <none>           <none>
nginx-demo-559f959666-pw68t   1/1     Running   1 (84m ago)   25h   10.42.0.13    k3s-demo-server-1   <none>           <none>
```

### 4.2 -o name / json / yaml

```bash
kubectl -n lab get pods -o name
```

真实输出（脚本场景：`-o name` 即可，无需 awk 切割）：

```text
pod/nginx-demo-559f959666-59frr
pod/nginx-demo-559f959666-kv4nv
pod/nginx-demo-559f959666-pw68t
```

```bash
kubectl -n lab get deploy nginx-demo -o yaml   # 完整 YAML
kubectl -n lab get pod <名> -o json             # 完整 JSON
```

真实 `-o yaml` 头部（注意 `metadata` 里的系统字段——`uid`/`resourceVersion`/`generation` 是 etcd 回写的，**不要手改**）：

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  annotations:
    deployment.kubernetes.io/revision: "2"
    kubectl.kubernetes.io/last-applied-configuration: |
      {"apiVersion":"apps/v1","kind":"Deployment",...
  creationTimestamp: "2026-10-03T01:00:15Z"
  generation: 7
  name: nginx-demo
  namespace: lab
  resourceVersion: "343548"
  uid: e0c04b42-a1b1-4df0-bade-219a8ca0f58e
spec:
  replicas: 5
  selector:
    matchLabels:
      app: nginx-demo
  template: ...
```

> 应用场景：`kubectl get deploy -o yaml > deploy.yaml` 备份/修改/再 `kubectl apply -f`——但备份前通常删掉 `status` 与 `metadata.uid/resourceVersion` 等系统字段（apply 会忽略 status，uid 等带上也无害）。

**多资源一次取**：

```bash
kubectl -n lab get deploy,svc -o name
```

真实输出：

```text
deployment.apps/nginx-demo
deployment.apps/probe-demo
deployment.apps/sched-demo
service/nginx-svc
```

### 4.3 custom-columns：自定义列（重点）

语法：`-o custom-columns=表头1:路径1,表头2:路径2,...`

```bash
kubectl -n lab get pods -o custom-columns=NAME:.metadata.name,IP:.status.podIP,NODE:.spec.nodeName,IMG:.spec.containers[*].image
```

真实输出：

```text
NAME                          IP            NODE                IMG
nginx-demo-559f959666-59frr   10.42.0.5     k3s-demo-server-1   nginx:latest
nginx-demo-559f959666-kv4nv   10.42.0.6     k3s-demo-server-1   nginx:latest
nginx-demo-559f959666-pw68t   10.42.0.13    k3s-demo-server-1   nginx:latest
nginx-demo-559f959666-thbhv   10.42.0.4     k3s-demo-server-1   nginx:latest
nginx-demo-559f959666-vkpmx   10.42.0.10    k3s-demo-server-1   nginx:latest
probe-demo-586b969fd-4t76l    10.42.0.254   k3s-demo-server-1   nginx:latest
```

**标签列**（带点 key 需转义 `\.`）：

```bash
kubectl get nodes -o custom-columns='NAME:.metadata.name,ROLE:.metadata.labels.node-role\.kubernetes\.io/control-plane'
```

真实输出：

```text
NAME                ROLE
k3s-demo-agent-1    <none>
k3s-demo-server-1   true
```

> agent 没有 control-plane 标签所以是 `<none>`——这正好告诉你"输出里 `<none>` = 字段不存在"。转义规则：key 里的 `.` 用 `\.`，斜杠无需转义。

**搭配第 13 章 Label**：

```bash
kubectl -n lab get pods -l app=nginx-demo -o custom-columns=NAME:.metadata.name,IP:.status.podIP,NODE:.spec.nodeName
```

**节点资源清单**（OS 镜像/内核/容器运行时一列搞定）：

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,IP:.status.addresses[?\(@.type==\"InternalIP\"\)].address,OS:.status.nodeInfo.osImage,KERNEL:.status.nodeInfo.kernelVersion,RT:.status.nodeInfo.containerRuntimeVersion
```

真实输出：

```text
NAME                IP              OS                 KERNEL-VERSION       CONTAINER-RUNTIME
k3s-demo-server-1   192.168.56.10   Ubuntu 22.04.5 LTS   5.15.0-160-generic   containerd://1.7.17-k3s1
k3s-demo-agent-1    192.168.56.20   Ubuntu 22.04.5 LTS   5.15.0-160-generic   containerd://1.7.17-k3s1
```

> `?(@.type=="InternalIP")` 是 jsonpath 的**过滤表达式**（取 type 为 InternalIP 的地址）——字段路径不够时用它精确定位。

### 4.4 jsonpath：精确取数/拼接

```bash
kubectl -n lab get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.podIP}{"\n"}{end}'
```

真实输出（名字 + Tab + IP）：

```text
nginx-demo-559f959666-59frr	10.42.0.5
nginx-demo-559f959666-kv4nv	10.42.0.6
nginx-demo-559f959666-pw68t	10.42.0.13
```

> 引号内 `"\t"`/`"\n"` 是 jsonpath 的转义输出；`range ... end` 循环所有元素。适合拼成脚本可读的纯文本。

```bash
kubectl get nodes -o jsonpath='{.items[*].metadata.labels.node-role\.kubernetes\.io/control-plane}'
# 真实输出: true      （server-1 有；agent 无则不出现）
```

### 4.5 --sort-by 与 --no-headers

```bash
kubectl get nodes --sort-by=.metadata.creationTimestamp -o wide
```

真实输出（按创建时间排序，server 先建）：

```text
NAME                STATUS   ROLES                       AGE    VERSION        INTERNAL-IP     EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION       CONTAINER-RUNTIME
k3s-demo-server-1   Ready    control-plane,etcd,master   131d   v1.30.2+k3s2   192.168.56.10   <none>        Ubuntu 22.04.5 LTS   5.15.0-160-generic   containerd://1.7.17-k3s1
k3s-demo-agent-1    Ready    <none>                      124d   v1.30.2+k3s2   192.168.56.20   <none>        Ubuntu 22.04.5 LTS   5.15.0-160-generic   containerd://1.7.17-k3s1
```

```bash
kubectl get pods -n lab --no-headers | wc -l   # 去掉表头行数才准
```

## 5. kubectl explain：反查字段路径

写 custom-columns 前不知道字段在哪？用 `kubectl explain` 反查：

```bash
kubectl explain pod.spec.containers
```

真实输出（节选）：

```text
KIND:       Pod
VERSION:    v1

FIELD: containers <[]Container>

DESCRIPTION:
    List of containers belonging to the pod. ...
    A single application container that you want to run within a pod.

FIELDS:
  image	<string>
    Container image name.
  name	<string>
    Name of the container specified as a DNS_LABEL.
  ports	<[]ContainerPort>
    List of ports to expose from the container.
```

用法口诀：**`explain 资源.层级` 逐级下钻**——`kubectl explain pod.status`、`kubectl explain node.status.nodeInfo`。看到字段类型（`<string>`/`<[]Container>`）就知道路径怎么写。

## 6. 常用组合模板（背下来）

| 需求 | 命令 |
|------|------|
| 看 Pod 列表+IP+节点 | `kubectl get pods -A -o wide` |
| 脚本取全部 Pod 名 | `kubectl get pods -A -o name` |
| 按标签筛并抽列 | `kubectl get pods -l app=x -o custom-columns=NAME:.metadata.name,IP:.status.podIP` |
| 看完整定义 | `kubectl get deploy x -o yaml` |
| 按自定义条件排 | `kubectl get nodes --sort-by=.metadata.creationTimestamp` |
| 字段在哪查 | `kubectl explain pod.spec.containers.image` |
| 备份+恢复 | `kubectl get deploy -o yaml > d.yaml; kubectl apply -f d.yaml` |

## 7. Rancher 界面对照

- Rancher 工作负载详情页 **View/Edit YAML**：展示的正是 `-o yaml` 同源数据（HARBOR/集群 API 的存储格式）
- UI 表格列与 `-o wide` 类似；但 **custom-columns 的任意列组合 UI 不支持**，这是 CLI 的优势
- Rancher 的 **Launch kubectl**（集群 → 右上角）可在浏览器里直接跑本章命令

## 8. 小结

- `-o` 是输出格式开关：`wide`（多点列）/`name`（类型+名）/`json`（完整机器格式）/`yaml`（完整人读格式）/`jsonpath`（精确取数）/`custom-columns`（自定义表格）
- **字段路径**来自资源定义文件的结构：`metadata`（元数据）→ `spec`（期望）→ `status`（实际），层层"点"即可
- `custom-columns=表头:.路径,...` 任意组合列；带点 key 用 `\.`；过滤表达式 `?(@.type=="...")`
- `kubectl explain` 是字段字典；`--sort-by`、`--no-headers`、`-l` 与 `-o` 自由组合
- 资源定义文件里的 `status`/`uid`/`resourceVersion`/`generation` 是系统回写，备份时注意

## 动手练习

1. 用 custom-columns 输出 `lab` 所有 Pod 的 IP 和 NODE 列，再用 `-l app=nginx-demo` 只留 nginx-demo（提示：两命令输出对比）。
2. `kubectl explain service.spec.ports` 找出 `port` 与 `targetPort` 的字段类型，再写一个 custom-columns 输出所有 Service 的 ClusterIP 与外部端口（提示：`nodePort` 路径 `.spec.ports[*].nodePort`）。
3. 用 jsonpath 只输出所有节点的 `kubernetes.io/hostname` 值（一行一个）。
4. 把 `nginx-demo` Deployment 导出为 `deploy-backup.yaml`，修改 `replicas` 后 `kubectl apply -f`，再导出对比 `generation` 变化。
5. 思考题：`kubectl get pods -o jsonpath='{.items[*].metadata.name}'` 与 `-o custom-columns=NAME:.metadata.name` 输出有何不同？各适合什么场景？

<details>
<summary>参考答案</summary>

1. 两条命令分别执行后对比：custom-columns 输出全部 Pod，加 `-l app=nginx-demo` 只剩 5 个 nginx-demo（组合使用是日常标准姿势）。
2. `service.spec.ports` 的 `port`/`targetPort`/`nodePort` 均为 `<integer>`；输出示例 `kubectl get svc -A -o custom-columns=NAME:.metadata.name,CLUSTER_IP:.spec.clusterIP,NODE_PORT:.spec.ports[*].nodePort`——没有 NodePort 的显示 `<none>`。
3. `kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.labels.kubernetes\.io/hostname}{"\n"}{end}'`（同本章 4.4 思路）。
4. apply 后 `deployment.kubernetes.io/revision` 与 `metadata.generation` 会 +1（generation 从 7 → 8 之类），说明成功触发了一次 rollout。
5. jsonpath 输出**无表头、纯字符串列表**（适合管道给脚本）；custom-columns 输出**带表头的表格**（适合人读/报表）。要脚本用 jsonpath 或 `-o name`，要报表用 custom-columns。
</details>