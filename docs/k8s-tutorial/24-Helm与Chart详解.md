# 24 Helm 与 Chart：把一个服务参数化，用版本管理生命周期

## 本章目标

- 理解 **Chart / values / 生命周期** 三个核心概念（安装包 / 参数开关 / 版本管理）
- 学会**把一个现有服务转成 Chart**：解剖资源 → `helm create` 骨架 → 参数化迁移
- 掌握 **values 设计原则与覆盖优先级**（`--set` > 多 `-f` > 默认值）
- 完整跑通 **生命周期闭环**：install → upgrade → history → rollback → uninstall（--keep-history）
- 理解 helm 原理：**release 的完整 manifest 存在 Secret 里，rollback 就是重放某版 manifest**
- 会用本集群真实数据判断"谁在管这个资源"（`managed-by: Helm` 标签）与 release 状态（deployed/superseded/failed/uninstalled）

> 前置：建议先完成 03（工作负载）、15（资源定义文件）、22/23（网络与数据面）。本章演示（2026-10-09 真实执行）把一个 `nginx-demo` 服务转成 chart 安装到独立命名空间 `demo-helm`，全程使用本集群 ingress-nginx（REVISION=8，被升级过 8 次的活案例）与 rancher（一条 failed 的历史）。
> 环境：Helm **v3.21.0**（v3 架构，v2 的 Tiller 组件早已废弃）。

---

## 1. 三个核心概念

| 概念 | 是什么 | 类比 |
|------|--------|------|
| **Chart** | 一个应用的"安装包"：`Chart.yaml`（元信息）+ `templates/`（模板）+ `values.yaml`（默认参数） | 服务的安装盘 |
| **values.yaml** | 模板变量的默认值：副本数/镜像/端口/域名全部抽成参数，**改 values 不改模板** | 安装盘的"选项页" |
| **生命周期（Release）** | 一次安装 = 一个 **Release**（发行版），可升级/回滚/卸载，版本号叫 **revision** | 应用的"版本档案" |

**核心思想（一句话）**：把"手写一堆 YAML 然后 `kubectl apply`"变成"**一份模板 + 一份参数**"，此后每个变更 = 改 values + 一条命令，且每个版本都可回滚、可对比。

```text
手写 YAML 时代:  改副本数 → 编辑 YAML → kubectl apply → （没有版本回滚）
Helm 时代:       改 values → helm upgrade → 自动滚动更新 → 出问题 helm rollback 秒级恢复
```

---

## 2. 把一个现有服务转成 Chart（三步走）

本集群 `lab/nginx-demo` 就是"手写 YAML 时代"的产物（第 03 章创建），用它做迁移案例。

### 2.1 第一步：解剖目标服务（它由哪些资源组成）

```bash
kubectl -n lab get deploy nginx-demo -o jsonpath='{.spec.template.spec.containers[0].image} {.spec.replicas}{"\n"}'
# 输出: nginx:latest 5
kubectl -n lab get deploy nginx-demo -o jsonpath='{.spec.selector.matchLabels}{"\n"}'
# 输出: {"app":"nginx-demo"}
kubectl -n lab get svc nginx-svc -o yaml | grep -E "type|port|targetPort|nodePort"
# 输出: NodePort / port 80 / targetPort 80 / nodePort 32062
kubectl -n lab get ing nginx-ing -o jsonpath='{.spec}{"\n"}'
# 输出: ingressClassName nginx / host lab.k3s.local / path / Prefix / backend nginx-svc:80
```

于是它的"物料清单"是：

```text
Deployment nginx-demo  → 镜像 nginx:latest、5 副本、端口 80
Service    nginx-svc   → NodePort 80:32062、selector app=nginx-demo
Ingress    nginx-ing   → class=nginx、host lab.k3s.local、path / → nginx-svc:80
```

> **转 chart 前先问自己**：这个服务有哪些**会变的参数**？——副本数、镜像 tag、端口、域名。这些就是将来 values.yaml 里要抽出来的键。

### 2.2 第二步：`helm create` 生成骨架

```bash
helm create nginx-demo
# 输出: Creating nginx-demo
```

生成的骨架（Helm v3.21 实测）：

```text
nginx-demo/
├── Chart.yaml                    # name/version/appVersion 等元信息
├── values.yaml                   # 所有可调参数的默认值
├── .helmignore                   # 打包时忽略的文件
└── templates/
    ├── deployment.yaml           # Deployment 模板
    ├── service.yaml              # Service 模板
    ├── ingress.yaml              # Ingress 模板（可用 values 开关）
    ├── hpa.yaml / httproute.yaml / serviceaccount.yaml   # 按需删除
    ├── _helpers.tpl              # 命名/标签辅助函数
    └── NOTES.txt                 # install 成功后的提示文案（模板可引用变量）
```

> 骨架是"全家桶"，**按需精简**：本演示删掉了 hpa/httproute/serviceaccount/tests/helpers，只留三件套（Deployment/Service/Ingress）——与 2.1 的物料清单一一对应。

### 2.3 第三步：迁移 + 参数化（核心）

**Deployment**：干活的写死值换成 `{{ .Values.xxx }}`，名字改用内置对象（`.Release.Name` 天然防命名冲突）：

```yaml
# templates/deployment.yaml（要点：变量 + 管理标签）
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}                                  # ★ release 名 = 资源名
  labels:
    app.kubernetes.io/name: {{ .Chart.Name }}
    app.kubernetes.io/managed-by: {{ .Release.Service }}     # ★ Helm 管理标记（见 5.3）
spec:
  replicas: {{ .Values.replicaCount }}                       # ★ 副本数参数化
  selector:
    matchLabels: { app.kubernetes.io/name: {{ .Chart.Name }}, app.kubernetes.io/instance: {{ .Release.Name }} }
  template:
    spec:
      containers:
      - name: {{ .Chart.Name }}
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"   # ★ 镜像参数化
        ports: [{ name: http, containerPort: {{ .Values.service.targetPort }} }]
```

**Service**：NodePort 留空自动分配（生产值 !——避免端口冲突，见 4.3 的 30814）：

```yaml
# templates/service.yaml（条件渲染：nodePort 有值才写）
spec:
  type: {{ .Values.service.type }}
  ports:
  - name: http
    port: {{ .Values.service.port }}
    targetPort: {{ .Values.service.targetPort }}
    {{- if .Values.service.nodePort }}
    nodePort: {{ .Values.service.nodePort }}
    {{- end }}
```

**Ingress**：用 `{{- if .Values.ingress.enabled }}` 整体开关（不需要时 `--set ingress.enabled=false` 就完全不生成）：

```yaml
# templates/ingress.yaml
{{- if .Values.ingress.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ .Release.Name }}
spec:
  ingressClassName: {{ .Values.ingress.className }}
  rules:
  - host: {{ .Values.ingress.host }}
    http:
      paths:
      - path: {{ .Values.ingress.path }}
        pathType: {{ .Values.ingress.pathType }}
        backend: { service: { name: {{ .Release.Name }}, port: { name: http } } }
{{- end }}
```

**values.yaml**（默认 = 生产可用最小配置）：

```yaml
replicaCount: 3
image:
  repository: nginx
  tag: "latest"
  pullPolicy: IfNotPresent
service:
  type: NodePort
  port: 80
  targetPort: 80
  nodePort: ""            # 留空自动分配 30000-32767
ingress:
  enabled: true
  className: nginx
  host: demo.lab.k3s.local   # 与 lab 的 lab.k3s.local 错开
  path: /
  pathType: Prefix
resources: {}
```

### 2.4 干跑验证（不动集群，先看渲染结果）

```bash
helm lint nginx-demo/
# [INFO] Chart.yaml: icon is recommended   ← 只是建议
# 1 chart(s) linted, 0 chart(s) failed     ← 0 失败即通过

helm template nginx-demo ./nginx-demo --set replicaCount=5   # 把最终 YAML 渲染到屏幕
# 输出三个文档: Service / Deployment(replicas: 5) / Ingress —— 先看对不对再安装
```

> **工作流原则**：`lint`（语法）→ `template`（渲染检查）→ 确认无误 → `install`。不用"装上再试错"。

---

## 3. values 覆盖优先级（改参数的三层方式）

| 方式 | 命令 | 用途 |
|------|------|------|
| 默认值 | values.yaml 内 | chart 自带基线 |
| 覆盖文件 | `helm upgrade ... -f prod.yaml` | **环境差异**（dev/prod 各一份 values） |
| 命令行 | `helm upgrade ... --set replicaCount=5` | 临时/精确覆盖 |

**优先级**（从高到低）：`--set` > 后写的 `-f` > 先写的 `-f` > values.yaml 默认值

```bash
helm upgrade nginx-demo ./nginx-demo -n demo-helm \
  -f base.yaml -f prod.yaml --set replicaCount=5
#   最优先 ────────────────────────────────▲
```

> 生产常用模式：**一套 chart + 多份 values**（dev.yaml/staging.yaml/prod.yaml），环境差异全在 values 层，模板零改动。

---

## 4. 生命周期管理（真实执行全闭环）

以下为本集群 2026-10-09 的完整真实输出。前置：chart 位于 `nginx-demo/`，目标命名空间 `demo-helm`。

### 4.1 install（第一次安装）

```bash
helm install nginx-demo ./nginx-demo -n demo-helm --create-namespace
```

```text
NAME: nginx-demo
NAMESPACE: demo-helm
STATUS: deployed          ← release 状态
REVISION: 1               ← 第 1 版
NOTES:                    ← NOTES.txt 渲染结果（访问方式）
  1. 集群内   curl http://nginx-demo.demo-helm.svc.cluster.local:80
  2. 节点端口 curl http://<节点IP>:<nodePort>
  3. Ingress  curl -H "Host: demo.lab.k3s.local" http://192.168.56.10:30080/
```

安装后资源（实测）：

```text
NAME                 TYPE       CLUSTER-IP     PORT(S)        SELECTOR
service/nginx-demo   NodePort   10.43.171.42   80:30814/TCP   app.kubernetes.io/instance=nginx-demo,...
NAME                                  HOSTS                PORTS
ingress.networking.k8s.io/nginx-demo  demo.lab.k3s.local   80
```

**三路访问全部 HTTP 200（实测）**：

```bash
curl -s -o /dev/null -w "%{http_code}" http://192.168.56.10:30814/          # ① NodePort（4 层直达）→ 200
curl -s -o /dev/null -w "%{http_code}" -H "Host: demo.lab.k3s.local" http://192.168.56.10:30080/   # ② Ingress（7 层）→ 200
kubectl -n demo-helm exec deploy/nginx-demo -- curl -s -o /dev/null -w "%{http_code}" \
  http://nginx-demo.demo-helm.svc.cluster.local/    # ③ 集群内 DNS → 200
```

### 4.2 upgrade + history（升级与查看版本）

```bash
helm upgrade nginx-demo ./nginx-demo -n demo-helm --set replicaCount=4
# NAME: nginx-demo / STATUS: deployed / REVISION: 2        ← 升级 = 新 revision

helm history nginx-demo -n demo-helm
# REVISION  STATUS      DESCRIPTION
# 1         superseded  Install complete      ← 已被替代（可回滚目标）
# 2         deployed    Upgrade complete
```

### 4.3 rollback（出问题秒级回退）

```bash
helm rollback nginx-demo 1 -n demo-helm
# Rollback was a success! Happy Helming!
# 副本数回到 3（history 又加一条）:
# REVISION  STATUS      DESCRIPTION
# 1         superseded  Install complete
# 2         superseded  Upgrade complete
# 3         deployed    Rollback to 1
```

**原理**：Helm 每次 install/upgrade 都把**完整 manifest** 存进 Secret（`sh.helm.release.v1.<name>.v<N>`）。**rollback 不是"撤销补丁"，是把那一版的完整 manifest 重新 apply**——所以任何一次升级（哪怕把资源删了）都能回滚。

### 4.4 uninstall --keep-history（卸载但留档案）

```bash
helm uninstall nginx-demo -n demo-helm --keep-history
# release "nginx-demo" uninstalled

helm history nginx-demo -n demo-helm     # 历史仍在！（可继续 rollback 复活）
# REVISION  STATUS      DESCRIPTION
# 1         superseded  Install complete
# 2         superseded  Upgrade complete
# 3         uninstalled Uninstallation complete
```

> 不带 `--keep-history` 则连 release 档案一起删（history/list 都查不到）。生产长留档案便于审计与复活。

### 4.5 常用辅助命令

```bash
helm list -A                  # 全部 release（Namespace/REVISION/STATUS/CHART）
helm status nginx-demo -n demo-helm    # 状态 + 最近事件
helm get values nginx-demo -n demo-helm    # 当前生效 values（排查"改没改上"）
helm get manifest nginx-demo -n demo-helm  # 该 release 实际落地的全部 YAML
```

---

## 5. 本集群真实 Release 盘点（判断"谁在管"）

### 5.1 `helm list -A` 实测（2026-10-09）

```text
NAME                      NAMESPACE                REVISION  STATUS    CHART
cert-manager              cert-manager             1         deployed  cert-manager-v1.20.2
ingress-nginx             ingress-nginx            8         deployed  ingress-nginx-4.11.0   ← 升级过 8 次
rancher                   cattle-system            1         failed    rancher-2.14.1          ← failed 但资源在跑
rancher-webhook           cattle-system            2         deployed  rancher-webhook-109.0.1+up0.10.4
fleet / fleet-crd / fleet-agent-local / rancher-turtles / system-upgrade-controller   ← Rancher 生态自带
```

**两个真实教学点**：

1. **ingress-nginx REVISION=8**：这个 release 被升级/修改过 8 次——每次都会有 `superseded` 历史可回滚。**它是你练习 `helm history` / `helm rollback` 的现成对象**（只读查看，别真动生产）。
2. **rancher STATUS=failed 但 Rancher UI 一直正常**：release 状态 ≠ 资源状态。`failed` 可能指某次升级/校验中的一次失败被记录，但已生效的资源继续运行。**排障时先 `helm status rancher -n cattle-system` 看最近事件，别只看 STATUS 列**。

### 5.2 一个资源的"管理印记"（怎么知道它是 Helm 管的）

```bash
kubectl get deploy -n ingress-nginx ingress-nginx-controller -o jsonpath='{.metadata.labels}{"\n"}'
# {"app.kubernetes.io/managed-by":"Helm","helm.sh/chart":"ingress-nginx-4.11.0",...}
```

出现的 `app.kubernetes.io/managed-by: Helm`（写入 2.3 Deployment 模板里那个 `.Release.Service`）就是标识。**看到它 = 这个资源归属 Helm，手改 YAML 会被下次 `helm upgrade` 覆盖**——要么走 helm 流程改 values，要么 `helm uninstall` 后手动接管。

### 5.3 release 状态速查

| 状态 | 含义 |
|------|------|
| deployed | 当前生效版本 |
| superseded | 被更新的 revision 替代（**回滚的候选目标**） |
| failed | upgrade/install 中途失败（资源可能已部分生效 → 5.1 的 rancher） |
| uninstalled | 已卸载（--keep-history 时保留） |

---

## 6. 排障：Helm 常见坑

| 现象 | 原因 | 处理 |
|------|------|------|
| `upgrade failed` 但资源是新的 | 升级中途失败，revision 记 failed | `helm history` 看失败描述；`helm rollback <name> <上一正常rev>` 恢复 |
| `Error: rendered manifests contain a resource that already exists` | chart 资源名与已有资源冲突（比如与手写 YAML 同名） | 改名/换 release 名；或先删旧资源（前章就是"接管"流程） |
| 手改的资源被升级覆盖 | `managed-by: Helm` 资源受 helm 管理 | 改 values 后 `helm upgrade`；不要 `kubectl edit` |
| `--set` 改了没生效 | 覆盖优先级理解反了 / 忘了 `helm upgrade` 重新渲染 | `helm get values` 确认当前值 |
| installation hung（Pod 一直 ContainerCreating） | 镜像拉取（第 04 章镜像源问题）/ 资源不足 | `kubectl get pod -o wide` + `kubectl describe pod`；不是 helm 问题 |
| `wait: condition ... failed` | `--wait` 超时（探针/镜像问题） | 结合 `kubectl get pods` 看具体卡点；可 `--atomic` 让失败自动回滚 |

**三条心法**：

1. **先 `helm history`，再决定升级还是回滚**——永远有 revision 兜底
2. **`helm get manifest` / `helm get values` 是对账工具**：怀疑"该生效的没生效"就拉出来看
3. **分层排障**：helm 报错 ≠ 集群问题。资源起不来先看 `kubectl get pods/describe`；helm 层面的错（冲突/校验/回滚）才在 `helm history`/`helm status` 里找

---

## 7. Rancher 界面对照（Apps & Marketplace）

Rancher 内置 Helm 的图形化封装（本集群的 ingress-nginx/rancher 就是用它在界面装的）：

| 界面位置 | 对应 Helm 操作 |
|---------|---------------|
| **Apps → Repositories** | 添加 Chart 仓库（相当于 `helm repo add`） |
| **Apps → Charts** | 搜索/选择 Chart → 填 **Answer 参数**（= values.yaml）→ 安装 |
| **Apps → Installed Apps** | 列表 = `helm list -A`；每项有 **Upgrade / Rollback** 按钮（回滚选 revision） |
| 已装应用详情 → **View in YAML** | 看渲染后的完整 manifest（= `helm get manifest`） |

> Rancher 的"旁路"：它用 fleet 管理多集群（前面 helm list 里的 fleet 组件天生在），但在单集群内对 release 的升级/回滚操作与命令行等价。**界面适合点选，命令行适合脚本化/排障**——两个都会，生产切换自如。

---

## 8. 小结

- **Chart = 安装包**（模板+参数+元信息）；**values = 参数开关**；**Release = 一次安装的版本档案（revision）**
- **转 Chart 三步**：解剖资源清单 → `helm create` 骨架 → 参数化迁移（变量替换 + 条件渲染 + 管理标签）
- **values 覆盖**：`--set` > 多 `-f` > 默认值；一套 chart + 多份 values 是环境差异的标准做法
- **生命周期**：install → upgrade（新 revision）→ history（superseded/deployed）→ rollback（重放旧 manifest）→ uninstall（--keep-history 留档案）
- **原理核心**：每次 install/upgrade 全量 manifest 存 Secret；`rollback = 重放那一版`，所以能"整版还原"
- **本集群实证**：ingress-nginx REVISION=8（活了 8 次的回滚素材）、rancher failed 但资源在跑（状态≠资源）、`managed-by: Helm` 标签识别归属
- **排障三心法**：先 history / 用 get manifest+get values 对账 / 分层：helm 错≠集群错

---

## 动手练习

1. 在 `demo-helm` 命名空间完整重做本章闭环（install → `--set replicaCount=4` upgrade → history → rollback 1 → uninstall --keep-history），记录每次 REVISION 与 STATUS 变化，对照 4.1–4.4。
2. 用 `helm get values nginx-demo -n demo-helm`（练习 1 中）查看当前生效参数；再用 `-f prod.yaml` 覆盖 `replicaCount: 6` 并 upgrade，观察 `helm get values` 的变化与优先级（提示：覆盖文件优先级高于默认值、低于 --set）。
3. 对 ingress-nginx（生产 release，只读）：`helm history ingress-nginx -n ingress-nginx` 看 8 个 revision 的描述；`helm get values ingress-nginx -n ingress-nginx | head -30` 看它的实际参数。不要 rollback/upgrade。
4. 排障演练：把练习 1 装的 chart 再 `install` 一次（同名 release）会发生什么？报错文案是什么？说出它对应 6.1 哪一行。
5. 深度题：为什么 `--keep-history` 卸载后还能 `rollback` 复活？`helm rollback` 的底层操作是什么（提示：4.3 原理 + release Secret 存的是什么）？

<details>
<summary>参考答案</summary>

1. 与 4.1–4.4 一致：install→rev1 deployed；upgrade→rev2 deployed（replicaCount=4）；rollback 1→rev3 deployed（回 3 副本，DESCRIPTION 为 "Rollback to 1"）；uninstall --keep-history→rev3 uninstalled 且历史 1/2 superseded 保留。
2. `helm get values` 展示合并后的最终值：`-f prod.yaml` 的 replicaCount=6 会盖过 values.yaml 的 3；若再 `--set replicaCount=5` 则 5 胜出（命令行最高）。
3. 应看到 8 行 revision（1..8），最近一条 deployed、其余 superseded；`get values` 展示 ingress-nginx 的 controller 镜像/参数——只读是安全的。
4. 报错类似 `Error: cannot re-use a name, the release "nginx-demo" already exists`（或 helm 提示用 `helm upgrade` 复用）——对应 6.1 表"manifest 冲突"一行的同类问题（同名 release 不可重复 install；同名资源则报 already exists）。
5. `--keep-history` 把 release 的 Secret（含每次 revision 的完整 manifest）保留在集群里；`helm rollback <rev>` 就是读取那个 Secret 里的 manifest 重新 apply 并登记新 revision——所以只要档案在（Secret 在），卸载过也能整版还原。这也解释了为什么删除命名空间会连 history 一起没掉（Secret 在命名空间内）。
</details>