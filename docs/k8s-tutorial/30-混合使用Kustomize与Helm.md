# 30 在同一部署库混用 Kustomize 与 Helm

## 本章目标

- 明确回答:**一个部署仓库 / 一个 GitRepo 里能否同时用 Kustomize 和 Helm?**（能，且是原生能力）
- 理解 Fleet 的**按 path 判定规则**：目录里出现什么文件，就决定用什么工具
- 通过**真实混合仓库实测**，看到两个工具在同一 GitRepo、同一命名空间里各自独立同步
- 踩并绕开一个真实坑：**同一个 path 同时放 `Chart.yaml` 和 `kustomization.yaml` 会怎样**
- 掌握在一个 bundle 内**显式指定**工具（`fleet.yaml`）、以及 Kustomize 内含 Helm 的写法
- 对比 **ArgoCD**，并给出仓库组织与选型建议

> 前置：本章建立在 **第 25 章（Kustomize vs Helm）**、**第 27 章（多服务/多环境仓库组织）**、**第 28 章（Fleet 用 Helm）**之上。
> 环境（2026-10-09 真实执行）：本集群 Fleet **v0.15.1**，用 gitea 建公开仓库 `mixed-tools-demo` 做混合实测，结束后清理。

---

## 1. 结论：可以，而且是原生的

Fleet 官方文档对仓库内容的原话：

> The git repository has **no explicitly required structure**. … This allows **mixing charts, kustomize, and raw YAML in the same repo**.

Fleet 的做法是**按 path（目录）逐个判定**用哪种工具。你在 GitRepo 里写多个 `paths`，每个 path 独立扫描、独立生成一个 Bundle、独立部署与监控。

**判定规则（官方原文整理）**：

| path 里的文件 | Fleet 判定 |
|----------------|-----------|
| `Chart.yaml` | 按 **Helm** 部署 |
| `kustomization.yaml` | 按 **Kustomize** 部署 |
| `fleet.yaml` | 新建一个 Bundle（可配置 helm/kustomize） |
| `*.yaml`（无上述两者） | 当作普通 K8s 资源直接部署 |
| `overlays/{name}` | 纯 YAML 场景下的定制目录 |

> 判定是**逐目录**的：`services/order` 可以是 Kustomize，`services/payment` 可以是 Helm，互不影响。

---

## 2. 为什么能：Bundle 是隔离单元

第 26~28 章反复出现的一个概念，在这里是答案的核心：

> **每个 path → 一个 Bundle；每个 Bundle 独立渲染、独立同步、独立汇报状态。**

所以"混用"在 Fleet 里根本不算特殊操作——它本来就是把每个目录当独立单元。真正需要小心的只有一件事：**别让一个目录同时命中两种判定**（见第 4 节）。

---

## 3. 实站：一个仓库混用两种工具（真实）

### 3.1 仓库结构

```text
mixed-tools-demo/
└── services/
    ├── order/                        # ← Kustomize
    │   ├── kustomization.yaml        #   namePrefix: order-
    │   └── configmap.yaml            #   ConfigMap shop-config
    └── payment/                      # ← Helm
        ├── Chart.yaml                #   name: payment, version 0.1.0
        ├── values.yaml               #   configValue: from-helm-values
        └── templates/
            └── configmap.yaml         #   ConfigMap payment-config
```

`order/kustomization.yaml`：
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - configmap.yaml
namePrefix: order-            # ← 用于验证 Kustomize 确实生效
```

`payment/templates/configmap.yaml`（节选）：
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: payment-config
  labels:
    helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
    app.kubernetes.io/managed-by: {{ .Release.Service }}
data:
  config: {{ .Values.configValue | quote }}
  rendered-by: helm
```

### 3.2 一个 GitRepo，两个 paths

```yaml
apiVersion: fleet.cattle.io/v1alpha1
kind: GitRepo
metadata: {name: mixed-demo, namespace: fleet-local}
spec:
  repo: http://10.0.2.2:3000/admin/mixed-tools-demo.git
  branch: main
  paths:
    - services/order      # Kustomize
    - services/payment    # Helm
  targetNamespace: demo-mixed
```

### 3.3 真实结果

```text
GitRepo: mixed-demo   2/2

Bundle:
mixed-demo-services-order     1/1     ← path 斜杠换 - 生成 bundle 名
mixed-demo-services-payment   1/1

demo-mixed 命名空间:
NAME                DATA
order-shop-config   2
payment-config      3
```

两种工具的产物逐项对照（真实采集）：

| 服务 | 工具 | 产物 | 关键证据 |
|------|------|------|----------|
| order | Kustomize | `order-shop-config` | 名字带 `order-` 前缀 → `namePrefix` 生效；`data.rendered-by=kustomize` |
| payment | Helm | `payment-config` | 标签 `helm.sh/chart=payment-0.1.0`；`data.rendered-by=helm`、`config=from-helm-values` |

两个服务在**同一个 GitRepo、同一个命名空间**里各自独立同步，互不干扰。

### 3.4 怎么判断某个 Bundle 用了哪种工具

看 Bundle 的 `spec` 最直接：

```bash
kubectl -n fleet-local get bundle mixed-demo-services-payment -o jsonpath='{.spec.helm}'
# → Helm：spec.helm 非空（或有 helm.sh/chart 标签的产物）
kubectl -n fleet-local get bundle mixed-demo-services-order -o jsonpath='{.spec.kustomize}'
```

> ⚠️ **不要用 `app.kubernetes.io/managed-by: Helm` 判断来源**。Fleet 会把**每个 Bundle（包括纯 Kustomize、纯 YAML）最终都包成一个 Helm chart 来部署**，所以所有 Fleet 纳管的资源都带这个标签加 `objectset.rio.cattle.io/hash`。判断工具要看 `helm.sh/chart` 标签、目录里的文件，或 `spec.helm`/`spec.kustomize`。

---

## 4. 真实坑：同一个 path 里混用会怎样

"混用"指的是**不同 path 之间**。如果你把两种工具塞进**同一个目录**，行为会很反直觉。真实复现：

### 4.1 复现

```text
services/ambiguous/
├── Chart.yaml                 # 命中 Helm
├── values.yaml
├── templates/configmap.yaml   # ConfigMap ambiguous-helm
├── kustomization.yaml         # 又命中 Kustomize
└── cm-kustomize.yaml          # ConfigMap ambiguous-kustomize
```

把它加进 GitRepo 的 `paths`，等待同步。

### 4.2 真实现象

```text
Bundle: mixed-demo-services-ambiguous   1/1

Bundle spec:
  helm: null
  kustomize: null
  resources: Chart.yaml / cm-kustomize.yaml / kustomization.yaml
             / templates/configmap.yaml / values.yaml     ← 存的是"原文件"，没被干净归类

demo-mixed 里：
  ambiguous-helm         data: {"who":"helm","rendered-by":"helm"}   ← 被 Helm 渲染了
  ambiguous-kustomize    data: {"rendered-by":"kustomize"}           ← Kustomize 产物也在
```

Fleet 既没把它当纯 Helm，也没当纯 Kustomize，**两条路都碰了**，产物同时出现、`spec.helm`/`spec.kustomize` 全为 `null`。**结果不可预期。**

### 4.3 正确做法

> **一个 path 只用一种工具。**

如果你想在一个目录内精确控制，就在该目录放一个 **`fleet.yaml`** 显式声明（见第 5 节），**不要靠同时放 `Chart.yaml` 和 `kustomization.yaml`**。

---

## 5. 一个 bundle 内的显式指定（fleet.yaml）

`fleet.yaml` 可以把某个 path 明确指定为 Helm 或 Kustomize，并附带选项。

**Kustomize**：
```yaml
# fleet.yaml
namespace: demo
kustomize:
  dir: "overlays/prod"     # 相对 base 目录（即该 path）
```

**Helm**：
```yaml
# fleet.yaml
helm:
  chart: "."               # 或用外部 chart
  values:
    replicas: 2
  valuesFiles:
    - values.prod.yaml
```

> **`helm:` 与 `kustomize:` 不要同时写**——那又回到第 4 节的歧义问题。
> 当 path 里有 `fleet.yaml` 时，Fleet 以它为准；没有时才对 `Chart.yaml` / `kustomization.yaml` 自动判定。

**多环境共享同一目录**用 GitRepo 的显式 `spec.bundles`（第 28 章讲过）也能混合不同工具：

```yaml
spec:
  bundles:
    - base: services/order       # Kustomize
    - base: services/payment     # Helm（目录含 Chart.yaml 或 fleet.yaml）
```

---

## 6. Kustomize 内含 Helm（以及反向）

有时你反而想**收敛到一种工具**：

- **Kustomize 渲染 Helm chart**：在 `kustomization.yaml` 里用 `helmCharts:`
  ```yaml
  helmCharts:
    - name: nginx
      repo: https://charts.example.com
      version: 1.2.3
      valuesFile: values-nginx.yaml
  ```
  渲染时需要开启 Helm（Fleet 内置支持；本地 `kubectl kustomize --enable-helm`）。这样"Helm 的部分"也被纳入 Kustomize 统一流水线。
- **反向不行**：Helm 没有"消费 Kustomize 产物"的原生机制。

结论：想统一，优先"Kustomize 收编 Helm"，而不是"Helm 套 Kustomize"。

---

## 7. 与 ArgoCD 对照

| 维度 | Fleet | ArgoCD |
|------|-------|--------|
| 判定单位 | GitRepo 的每个 `path` | 每个 Application 的 `spec.source.path` |
| 自动识别 | `Chart.yaml`→Helm；`kustomization.yaml`→Kustomize | 同左 |
| 显式指定 | `fleet.yaml` 的 `helm:` / `kustomize:` | `source.helm:` / `source.kustomize:` |
| 混合方式 | 一个 GitRepo 多个 paths | 多个 Application 各指一个 path |

两者一致：**按目录判定，一个目录一种工具；混用发生在目录之间**。

---

## 8. 选型与仓库组织建议

**什么时候适合混：**

- **迁移期**：老服务还在 Kustomize，新服务上 Helm
- **第三方 chart 只能用 Helm** + 自研服务用 Kustomize
- **不同团队**各自习惯不同的工具

**什么时候应该统一：**

- 同一团队、同一批服务 → 统一工具，降低认知负担
- **同一服务的多环境** → 必须统一，只换 overlay / values，绝不 dev 用一种、prod 用另一种

**三种仓库布局：**

```text
# A. 按工具分区
repo/
├── kustomize/<service>/...
└── helm/<service>/...

# B. 按服务分区（每个服务自带工具）
repo/
├── apps/order/        # kustomization.yaml
└── apps/payment/      # Chart.yaml

# C. 混合（也是合法的）
repo/
├── platform/          # 用 Helm 的第三方组件
└── apps/<service>/    # 用 Kustomize 的自研服务
```

无论哪种，铁律只有一条：**一个 path 里只出现一种工具的标志文件**。

---

## 9. 排障清单

| 现象 | 原因 | 处理 |
|------|------|------|
| 一个 path 冒出意料外的资源 | 目录里同时有 `Chart.yaml` 和 `kustomization.yaml` | 只保留一种；或用 `fleet.yaml` 明确指定 |
| 纯 Kustomize 资源也带 `managed-by: Helm` | Fleet 把所有 bundle 都包成 Helm chart 部署 | 正常现象；判断来源看 `helm.sh/chart` |
| 某 path 把 `Chart.yaml`/`values.yaml` 也当资源 | 目录未被归类（歧义） | 见第 4 节 |
| 改了 kustomize 却不生效 | GitRepo 指向的 path 不对（指到了仓库根而非 overlay） | paths 具体到含 `kustomization.yaml` 的目录 |
| 混用后回滚/排查困难 | 没约定工具边界 | 按第 8 节固定布局 |

---

## 10. 小结

1. **能混，且是原生的**：Fleet/ArgoCD 都**按 path 判定**工具，一个仓库、一个 GitRepo 可同时存在 Kustomize、Helm、纯 YAML。
2. **判定规则**：目录里 `Chart.yaml`→Helm、`kustomization.yaml`→Kustomize、`fleet.yaml`→新 bundle、其余 `*.yaml`→原始资源。
3. **真实实测**：`mixed-demo` GitRepo `2/2`，两个 bundle 分别用两种工具，同命名空间和平共处。
4. **真实坑**：**同一个 path 同时放 `Chart.yaml` 和 `kustomization.yaml` → 判定混乱、两种产物都出现**。铁律：**一个 path 一种工具**。
5. **显式控制**用 `fleet.yaml`（`helm:` / `kustomize:`，别同时写）或 GitRepo 的 `spec.bundles`。
6. **想收敛**：用 Kustomize 的 `helmCharts:` 收编 Helm；反向做不到。
7. **判断来源**看 `helm.sh/chart` / 目录文件 / `spec.helm`，**别信** `managed-by: Helm`。

---

## 动手练习

1. **最小混合**：建一个仓库，`services/a` 用 Kustomize（加 `namePrefix`）、`services/b` 用 Helm，一个 GitRepo 两个 paths，验证两个 bundle 各自 1/1。
2. **判定实验**：在 `services/a` 里额外放一个 `Chart.yaml`，观察它变成什么、产物有何异常，然后还原。
3. **fleet.yaml 显式指定**：给 Kustomize 目录加 `fleet.yaml` 的 `kustomize.dir` 指向 overlay，确认仍正常。
4. **来源判定**：用 `kubectl get bundle -o jsonpath='{.spec.helm}'` 与产物标签，区分两个 bundle 各用了什么工具。
5. **错误示范**：故意在同一目录放两种工具文件，记录 `spec.helm`/`spec.kustomize` 的值与产物，解释为什么不可预期。
6. **收敛实验**：把 Helm 服务改成 Kustomize 的 `helmCharts:` 方式渲染，比较产物差异。
7. **仓库组织**：为你手头的一个多服务仓库，画出第 8 节的 A/B/C 三种布局草案，选一种并说明理由。
