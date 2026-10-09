# 28 GitOps 使用 Helm Chart 完整实战

## 本章目标

- 讲清 **Fleet 如何在 GitOps 流程里使用 Helm**：配置入口（`fleet.yaml` / options）、三种打包方式（chart / kustomize / 原始 YAML）
- 掌握 **Helm 值的四种来源与合并顺序**，知道 `values.yaml` / `helm.values` / `valuesFiles` / `valuesFrom` 各在哪一层
- **真实跑通一个完整例子**：一个共享 chart + dev/prod 两个环境（显式 `bundles` + options），Git 一改自动同步
- 通过**对照实验**吃透两个真实大坑：
  1. Fleet 的每个 path **必须自包含**，chart 不能跨目录引用
  2. v0.15.1 下 `valuesFiles` **必须显式写 `helm.chart`** 才生效（否则静默忽略）
- 能与第 24/25 章的 **Kustomize 路线**对照选型
- 掌握进阶：外部 chart 仓库（Helm repo / OCI）、`valuesFrom`、`targetCustomizations`、HelmOps

> 前置：本章是 **第 24 章（Helm 与 Chart）** 和 **第 26 章（GitOps：Fleet / ArgoCD）** 的结合，并复用 **第 27 章（多服务/多环境仓库组织）** 的结构思路。建议先完成 24、25、26、27。
> 环境（2026-10-09 真实执行）：本集群 Fleet **v0.15.1**（Rancher 自带），搭建 `gitops-helm-demo` 仓库（共享 `web-app` chart + dev/prod 两环境），采集真实输出与两个失败实验后清理。

---

## 1. 为什么要在 GitOps 里用 Helm

第 26/27 章我们用 Kustomize 做 GitOps，那时写的是「原始清单 + overlay」。当应用变复杂（多参数、多环境、要发布成可复用组件），Helm 的优势就出来了：

| 场景 | 原始清单/Kustomize | Helm chart |
|------|-------------------|-----------|
| 多参数可配置 | 改 overlay 的散装 patch | **集中 `values`** |
| 打包复用/版本化 | 目录复制 | **chart 版本 + 依赖** |
| 环境差异 | overlay 覆盖 | **values 覆盖** |
| 参数带默认值 | 无 | **`values.yaml` 默认** |
| 条件逻辑/循环 | 不支持 | **Go template** |

Fleet 本身**就是基于 Helm 的**——它把每个 bundle「转成单个 Helm chart 部署」（官方原文：*Each bundle is converted to a single Helm chart for deployment*）。所以"用 Helm chart"其实是回到 Fleet 的原生路径上。

---

## 2. Fleet 如何用 Helm：两个配置入口

先破一个常见误解：**GitRepo CR 里没有 `spec.helm` 字段**。查一下本集群 CRD 的真实一级字段：

```text
spec.branch            spec.bundles           spec.caBundle
spec.clientSecretName  spec.correctDrift      spec.deleteNamespace
spec.disablePolling    spec.forceSyncGeneration  spec.helmRepoURLRegex
spec.helmSecretName    spec.helmSecretNameForPaths  spec.imageScanCommit
spec.imageScanInterval spec.insecureSkipTLSVerify  spec.keepResources
spec.ociRegistrySecret spec.paths             spec.paused
spec.pollingInterval   spec.repo              spec.revision
spec.serviceAccount    spec.targetNamespace   spec.targets
spec.webhookSecret
```

**没有 `spec.helm`**。Helm 参数是通过**仓库里的文件**配置的，正好符合"一切在 Git 里"：

| 入口 | 位置 | 说明 |
|------|------|------|
| `fleet.yaml` | path 目录根 | 最常用；任何含 `fleet.yaml` 的目录都会变成一个 bundle |
| **options 文件** | 显式 `bundles` 模式 | 让**同一个 chart 目录**配多套参数，生成多个 bundle（本章主角） |

> 官方定义：`fleet.yaml` 的内容对应 `FleetYAML` 结构，即 `BundleSpec`。

### 2.1 Fleet 如何识别要部署什么（扫描规则）

Fleet 扫描每个 path，按这些文件判断打包方式：

| 文件 | 含义 |
|------|------|
| `Chart.yaml` | 该目录按 **Helm chart** 打包 |
| `kustomization.yaml` | 按 **Kustomize** 打包 |
| `fleet.yaml` | 该目录变成一个 **bundle** 并应用其中的配置 |
| `*.yaml` | 没有 chart/kustomization 时，按**原始 K8s 清单**部署 |

**关键**：每个 path **独立扫描、独立成 bundle**。这决定了后面两个坑。

---

## 3. 值从哪来：四种来源与合并顺序

这是本章的核心。Fleet 安装 chart 时，Helm 值的来源与优先级（官方文档原文）：

> 合并顺序：`helm.values` → `helm.valuesFiles` → `helm.valuesFrom`

```text
        chart/values.yaml          ← 默认值（永远生效）
              │  被覆盖
              ▼
   fleet.yaml 的 helm.values       ← 内联值（支持 ${} 模板）
              │  被覆盖
              ▼
   helm.valuesFiles                ← 值文件（路径相对 bundle 根）
              │  被覆盖
              ▼
   helm.valuesFrom                 ← 从下游 Secret/ConfigMap 读（加密友好）
```

| 来源 | 写在 | 适合 | 注意 |
|------|------|------|------|
| **chart `values.yaml`** | chart 目录内 | 默认值 | **总是自动加载**，无需在 `valuesFiles` 再引用 |
| **`helm.values`** | `fleet.yaml` | 少量覆盖、按集群模板 | 支持 `${ }` 模板 |
| **`helm.valuesFiles`** | 值文件 | 大块环境值 | ⚠️ **必须显式 `helm.chart`**（见第 5 节坑 2） |
| **`helm.valuesFrom`** | 下游 Secret/ConfigMap | 凭据/敏感值 | 落盘加密更安全，**推荐放密码** |

> 官方建议：**永远不要把凭据写进 `values`/`valuesFiles`/chart `values.yaml`**，敏感值用 `valuesFrom`。

---

## 4. 实站：完整例子（共享 chart + dev/prod）

### 4.1 仓库结构

用第 27 章"服务优先"的结构，但为了**一个 chart 服务两个环境**，采用 Fleet 的**显式 `bundles` 模式**：

```text
gitops-helm-demo/
└── app/                          # 共享 chart（base）
    ├── Chart.yaml
    ├── values.yaml               # 默认值
    ├── values-dev.yaml           # dev 覆盖
    ├── values-prod.yaml          # prod 覆盖
    ├── dev.yaml                  # dev 的 options（等价 fleet.yaml）
    ├── prod.yaml                 # prod 的 options
    └── templates/
        ├── _helpers.tpl
        ├── deployment.yaml
        └── service.yaml
```

> 为什么 options 文件放在 `app/` 里、而不是两个独立的 chart 目录？因为**同一个 base 目录 + 不同 options = 两个 bundle，共享同一份 chart**，避免复制。

### 4.2 chart 文件全文

**`app/Chart.yaml`**：

```yaml
apiVersion: v2
name: web-app
description: GitOps Helm demo web app
type: application
version: 0.1.0
appVersion: "1.0.0"
```

**`app/values.yaml`（默认值）**：

```yaml
replicaCount: 1
image:
  repository: nginx
  tag: latest
  pullPolicy: IfNotPresent
service:
  type: ClusterIP
  port: 80
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 128Mi
```

**`app/templates/_helpers.tpl`**：

```gotemplate
{{- define "web-app.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{- define "web-app.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "web-app.labels" -}}
app.kubernetes.io/name: {{ include "web-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "web-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "web-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
```

**`app/templates/deployment.yaml`**：

```gotemplate
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "web-app.fullname" . }}
  labels:
    {{- include "web-app.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      {{- include "web-app.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "web-app.selectorLabels" . | nindent 8 }}
    spec:
      containers:
      - name: {{ .Chart.Name }}
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
        imagePullPolicy: {{ .Values.image.pullPolicy }}
        ports:
        - containerPort: 80
        resources:
          {{- toYaml .Values.resources | nindent 10 }}
```

**`app/templates/service.yaml`**：

```gotemplate
apiVersion: v1
kind: Service
metadata:
  name: {{ include "web-app.fullname" . }}
  labels:
    {{- include "web-app.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.type }}
  selector:
    {{- include "web-app.selectorLabels" . | nindent 4 }}
  ports:
  - port: {{ .Values.service.port }}
    targetPort: 80
```

### 4.3 环境 values 与 options

**`app/values-dev.yaml`**：

```yaml
replicaCount: 1
```

**`app/values-prod.yaml`**：

```yaml
replicaCount: 2
```

**`app/dev.yaml`（options，等价于 fleet.yaml）**：

```yaml
namespace: web-dev
helm:
  chart: .                      # ★ 必须显式写，否则 valuesFiles 被忽略（见第 5 节）
  releaseName: web-dev
  valuesFiles:
  - values-dev.yaml
```

**`app/prod.yaml`**：

```yaml
namespace: web-prod
helm:
  chart: .                      # ★ 同理
  releaseName: web-prod
  valuesFiles:
  - values-prod.yaml
```

### 4.4 GitRepo 定义（显式 bundles 共享 chart）

```yaml
apiVersion: fleet.cattle.io/v1alpha1
kind: GitRepo
metadata:
  name: web-app
  namespace: fleet-local
spec:
  repo: http://10.0.2.2:3000/admin/gitops-helm-demo.git
  branch: main
  bundles:                     # ★ 显式定义 bundle：同一个 base，两套 options
  - base: app
    options: dev.yaml
  - base: app
    options: prod.yaml
```

> 这就是"**一个 chart 部署到多个环境**"的干净解法：`base` 指共享 chart，`options` 指向不同参数。

### 4.5 真实输出

应用后等约 35 秒：

```text
NAME      REPO                                              COMMIT        BUNDLEDEPLOYMENTS-READY
web-app   http://10.0.2.2:3000/admin/gitops-helm-demo.git   5fcfab37...   2/2

NAME                 BUNDLEDEPLOYMENTS-READY
web-app-app-dev      1/1
web-app-app-prod     1/1
```

**Bundle 命名规则**（显式模式）：`<GitRepo名>-<base>-<options 文件名去扩展名>`。

两个命名空间各自落地，环境值正确生效：

```text
web-dev   web-dev-web-app   replicas=1
web-prod  web-prod-web-app  replicas=2
```

**Helm 渲染印记**（证明是 Helm 渲染的，不是原始 YAML）：

```json
{
  "app.kubernetes.io/instance": "web-prod",
  "app.kubernetes.io/managed-by": "Helm",
  "app.kubernetes.io/name": "web-app",
  "helm.sh/chart": "web-app-0.1.0",
  "objectset.rio.cattle.io/hash": "0b9a383365d4e8602a20efddb451f3fe96ed3704"
}
```

集群内访问验证：

```bash
kubectl -n web-dev  exec deploy/web-dev-web-app  -- curl -s -o /dev/null -w "%{http_code}" http://web-dev-web-app/
# → 200
kubectl -n web-prod exec deploy/web-prod-web-app -- curl -s -o /dev/null -w "%{http_code}" http://web-prod-web-app/
# → 200
```

### 4.6 git 改动自动同步

把 prod 的 `values-prod.yaml` 从 `replicaCount: 2` 改成 `3`，提交推送：

```bash
sed -i 's/replicaCount: 2/replicaCount: 3/' app/values-prod.yaml
git commit -am "chore(prod): scale web-app to 3 replicas" && git push
```

约 40 秒后（真实结果）：

```text
web-dev  replicas=1      # 不受影响
web-prod replicas=3      # 自动扩到 3
GitRepo commit: f4d41f418f0a1b552ecd6c5f16c63217a9abd02e
```

**这就是 GitOps 的闭环**：改 Git → Fleet 拉取 → Helm 重新渲染 → 只更新变化的环境。dev 完全不受影响，因为它是独立的 bundle。

### 4.7 清理

```bash
kubectl -n fleet-local delete gitrepo web-app      # 反向同步自动回收资源
kubectl delete ns web-dev web-prod
# 删除 gitea 仓库
```

真实结果：删除 GitRepo 后两个命名空间资源即消失，无残留。

---

## 5. 真实踩坑与对照实验（本章重点）

上面顺风顺水的例子里藏着两个**真实踩过的坑**。把对照实验摆出来，比只给结论有用得多。

### 5.1 坑 1：path 必须自包含，chart 不能跨目录引用

**错误尝试**：把 chart 放在 `charts/web-app/`，让 `envs/dev/fleet.yaml` 用相对路径引用：

```yaml
# envs/dev/fleet.yaml  ——  ❌ 错误
helm:
  chart: ../../charts/web-app
```

Fleet 报错（真实输出）：

```text
Stalled True failed to process bundle: failed reading resources for "t-rel":
  loading directory .chart/2839b2..., t-rel:
  retrieving file from "../../charts/web-app":
    source path error: stat /workspace/charts/web-app: no such file or directory
```

**机制**：Fleet 把**每个 path 单独 stage 到 `/workspace/`**，`../../charts/web-app` 解析到了不存在的 `/workspace/charts/web-app`。结论——**chart 必须就在 path 目录内部**。这和第 26 章 Kustomize 的 path 自包含是同一个道理，但对 Helm 更严格。

另有一种相关错误：**path 里只有 `fleet.yaml` + `values.yaml`、没有 chart/清单**：

```text
Stalled True no resource found at the following paths to deploy: [envs/dev envs/prod]
```

Fleet 会认为"无可部署内容"。**所以 path 根上必须有 `Chart.yaml` / `kustomization.yaml` / 原始清单之一**。

### 5.2 坑 2：`valuesFiles` 必须显式写 `helm.chart`（v0.15.1）

即使 `fleet.yaml` 与 `Chart.yaml` **同目录**，只要没写 `helm.chart`，`valuesFiles` 就会被**静默忽略**。三组对照：

| 变体 | `fleet.yaml` 写法 | 结果 |
|------|------------------|------|
| A | 只有 `helm.releaseName`（靠 chart 默认） | ✅ replicas=1（默认值正常加载） |
| B | `helm.values: {replicaCount: 7}` | ✅ replicas=7 |
| C | `helm.valuesFiles: [values.prod.yaml]` | ❌ replicas=1（**值文件没生效，无报错**） |
| D | `helm.chart: .` + `valuesFiles: [values.prod.yaml]` | ✅ replicas=6 |

C 的 Bundle 里确实记录了 `valuesFiles: ["values.prod.yaml"]`，但渲染时没应用；D 加上 `helm.chart: .` 后立刻生效。

> 更隐蔽的是：当值文件恰好叫 `values.yaml` 时，某些版本会报 `.Values.service: nil pointer evaluating interface {}.type`（chart 默认值像是被"清空"了），更难排查。

**正确写法**（本集群实测）：

```yaml
helm:
  chart: .              # ← 哪怕 fleet.yaml 就在 chart 目录里，也要写
  valuesFiles:
  - values-prod.yaml
```

### 5.3 三种值来源实测对照

| 写法 | 是否生效 | 适用 |
|------|---------|------|
| chart `values.yaml` 默认 | ✅ 自动 | 默认值 |
| `helm.values` 内联 | ✅ | 少量覆盖、带模板 |
| `helm.valuesFiles` | ✅（**须配 `helm.chart`**） | 大块环境值 |
| `helm.valuesFrom` | ✅（从 Secret/ConfigMap） | 凭据/敏感值 |

### 5.4 多环境共享 chart 的两种做法

| 做法 | 结构 | 优点 | 缺点 |
|------|------|------|------|
| **显式 `bundles` + options**（本章） | 一个 base + 多个 options | ✅ 共享一份 chart | options 文件放在 base 内 |
| 每环境复制 chart | `web-dev/`、`web-prod/` 各一份 | 简单直接 | chart 重复，改模板要同步多处 |

> 若 chart 已发布到 **Helm 仓库 / OCI**，还能用 `helm.repo` + `helm.chart` + `helm.version` 引用同一版本（见第 7 节），此时各环境目录里连 chart 都不用放。

---

## 6. Helm vs Kustomize 在 GitOps 下的选择

| 维度 | Kustomize（第 25/26/27 章） | Helm（本章） |
|------|---------------------------|-------------|
| 参数模型 | patch/overlay 覆盖 | `values` 集中覆盖 |
| 默认值 | 无 | `values.yaml` |
| 条件/循环 | 无 | Go template |
| 版本化/复用 | 目录复制 | **chart 版本 + 依赖** |
| 上手成本 | 低 | 中（要会模板） |
| Fleet 原生 | 支持 | **本身就是 Helm** |
| 适合 | 少量服务、环境差异 | 复杂应用、多参数、对外发布 |

**选型建议**：参数少、结构简单 → Kustomize；参数多、要复用/版本化 → Helm。二者可在同一 Fleet 仓库里混用（`Chart.yaml` 走 Helm，`kustomization.yaml` 走 Kustomize）。

---

## 7. 进阶：外部 chart、valuesFrom、按集群定制

### 7.1 引用外部 Helm 仓库（不用把 chart 放 Git）

```yaml
# fleet.yaml
namespace: monitoring
helm:
  repo: https://charts.example.com        # 标准 Helm 仓库
  chart: kube-prometheus-stack
  version: "65.0.0"
  values:
    grafana:
      enabled: true
```

OCI 仓库用 `repo: oci://…` + `version`。私有仓库需配 `spec.helmSecretName` / `spec.helmRepoURLRegex`。

### 7.2 `valuesFrom`：从下游 Secret/ConfigMap 取值

```yaml
helm:
  chart: .
  valuesFrom:
  - secretKeyRef:
      name: web-app-values
      namespace: web-prod
      key: values.yaml
  - configMapKeyRef:
      name: web-app-values
      namespace: web-prod
      key: values.yaml
```

**密码/密钥走这里**，别写进 Git 里的 values。

### 7.3 `targetCustomizations`：同一 bundle 按目标集群改值

```yaml
targetCustomizations:
- name: prod
  clusterName: prod-cluster
  helm:
    values:
      replicaCount: 5
```

适合"一个 bundle 分发到多集群、每集群微调"；注意 **chart 源本身不能按集群切换**（chart 创建阶段就已下载）。

### 7.4 HelmOps

Fleet 还有独立的 `HelmOp` 资源，用于**只引用外部 chart、不在 Git 里放清单**的场景，配合 `downstreamResources` 可把 ConfigMap/Secret 自动下发到下游集群。

---

## 8. Rancher 界面对照（Continuous Delivery）

在 Rancher 的 **Continuous Delivery → Git Repos** 里：

- 列表能看到 `web-app` 这个 GitRepo，右侧 **Bundles** 显示 **2 个**（`web-app-app-dev` / `web-app-app-prod`），状态 `1/1`。
- 点进某个 Bundle → 可查看它渲染出的资源、**Force Update**、查看 commit。
- 因为用了显式 `bundles`，界面里能清楚看到"**一个 GitRepo、共享 chart、两个环境 bundle**"的对应关系——这正是多环境 GitOps 想要的可视化。

---

## 9. 反模式与最佳实践

**反模式**：

- ❌ 用 `helm.chart: ../../xxx` 跨目录引用 chart（坑 1，必失败）
- ❌ 只放 `fleet.yaml`/`values.yaml` 而没有 chart/kustomization/清单（"no resource found"）
- ❌ 写了 `valuesFiles` 却忘了 `helm.chart`（坑 2，静默忽略）
- ❌ 把密码写进 Git 里的 `values.yaml`/`valuesFiles`（用 `valuesFrom`）
- ❌ 每个环境复制一份 chart，改模板时漏改（用显式 `bundles`+options 或外部 chart 仓库）
- ❌ 忽视 Fleet 是"基于 Helm"的——它给资源加的 `app.kubernetes.io/managed-by: Helm` 和 `objectset.rio.cattle.io/hash` 是正常印记，不是异常

**最佳实践**：

- ✅ chart 自包含在 path 内；多环境用 `base`+`options` 共享
- ✅ 默认值放 chart `values.yaml`，环境差异放 `valuesFiles` 并**记得 `helm.chart`**
- ✅ 敏感值走 `valuesFrom`
- ✅ 版本化用外部 chart 仓库（`repo`/`chart`/`version`）或 git tag
- ✅ 改 Git → 自动同步，用独立 bundle 隔离环境影响

---

## 10. 小结

1. **Fleet 本身就是 Helm**：每个 bundle 被转成单个 Helm chart 部署；GitRepo **没有** `spec.helm`，Helm 参数写在 `fleet.yaml` / options 里。
2. **值合并顺序**：chart `values.yaml`（默认）→ `helm.values` → `helm.valuesFiles` → `helm.valuesFrom`。敏感值用 `valuesFrom`。
3. **完整例子**：一个共享 `web-app` chart + `spec.bundles`（`base: app` + `options: dev/prod`）→ 2 个 bundle、dev/prod 各自命名空间与副本数，Git 一改 prod 自动同步。
4. **两个真实大坑**：
   - path 必须自包含，**chart 不能跨目录引用**（`../../` 会 stat 失败）
   - `valuesFiles` **必须显式 `helm.chart`**，否则静默忽略（本集群 v0.15.1 实测）
5. **多环境共享 chart**：优先显式 `bundles`+options，或外部 chart 仓库；避免复制 chart。
6. **选型**：Kustomize 适合简单差异，Helm 适合复杂参数/复用/版本化；二者可在一个 Fleet 仓库混用。

---

## 动手练习

1. **最小复现**：写一个含 `Chart.yaml` + `fleet.yaml` 的目录，用 GitRepo（`paths`）部署到 `demo` 命名空间，验证资源带 `helm.sh/chart` 标签。
2. **体验坑 2**：把练习 1 的 `fleet.yaml` 改成 `valuesFiles: [values-prod.yaml]`（**不写 `helm.chart`**），观察 replicas 不变；再加上 `helm.chart: .`，观察生效。
3. **共享 chart 多环境**：用 `spec.bundles`（`base: app` + `options: dev.yaml`/`prod.yaml`）部署 dev/prod，验证 2 个 bundle、两个命名空间。
4. **GitOps 闭环**：改 `values-prod.yaml` 的副本数并 push，确认只有 prod 变化、dev 不变。
5. **跨目录踩坑**：把 chart 移到 `charts/`，在 `envs/dev/fleet.yaml` 写 `chart: ../../charts/web-app`，观察真实报错并解释原因。
6. **Kustomize 对照**：把本章例子改写成 Kustomize（`base` + `overlays/prod`），对比两种写法的文件数量与可读性。
7. **凭据安全**：把某个值改成从 Secret 读取（`valuesFrom.secretKeyRef`），验证不把密码写进 Git 也能生效。
