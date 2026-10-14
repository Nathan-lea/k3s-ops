# 42 CRD 与 Operator 实战

## 本章目标

- 理解 **CRD（CustomResourceDefinition）** 解决了什么问题：内置资源不够用时，如何**给 API Server 注册一个新类型**
- 会**拆解一个 CRD**：group/version/kind、plural、scope、`served`/`storage`、OpenAPI schema、printer columns、`subresources.status`
- 会用**集群里现成的 CRD**（Fleet、cert-manager、Gateway API、Rancher）反推设计思路
- 会**手写一个 CRD**：`webapps.demo.example.com/v1`，带字段校验、默认值和 `-o wide` 自定义列
- 理解**声明式与调谐循环（reconcile）**：期望状态、观测状态、幂等性、`ownerReference`
- 会用 **Go + controller-runtime 从零写一个小控制器**，并把它**打包成镜像导入集群**运行
- 能**实测自愈**：删掉被管对象自动重建、改 CR 后下游跟随、status 回写
- 掌握排障要点：RBAC 作用域与 informer 作用域不匹配、status 子资源、退避重试、finalizer

> 本章所有命令统一使用 `kubectl --kubeconfig ./kubeconfig`。文档中路径统一用 `~/k3s-ops` 表示。
> 示例工程位于 `~/k3s-ops/examples/webapp-operator/`，章节里出现的代码块与该目录下的文件**逐字一致**。

---

## 1. 为什么需要 CRD

**内置资源是"通用积木"。** Pod、Deployment、Service、ConfigMap 这些类型解决的是普适问题：
跑容器、做副本管理、暴露网络、存配置。它们不关心你的业务语义。

但真实场景常常是**领域对象**，比如"一个 WebApp 就代表一个应用"：

- 镜像是什么
- 要几个副本
- 暴露哪个端口
- 现在**就绪了几个副本**（这是状态，不是配置）

用内置资源硬凑的话，只能拿 Deployment 顶上，把额外信息塞进注解或命名约定：

```text
缺陷：
  ✗ 没有字段级校验（replicas 想限制 0–10？只能靠约定）
  ✗ 没有"观测状态"的正式位置（就绪副本数只能去读 Deployment）
  ✗ kubectl 体验差（不能 kubectl get webapps，只能 kubectl get deploy -l ...）
  ✗ 没有 RBAC 粒度（无法单独授权"谁能建 WebApp"）
  ✗ 无法被 watch 成领域事件（只能 watch Deployment，语义丢失）
```

**CRD 就是来解决这个问题的**：它把一个新类型注册进 API Server。注册之后，这个类型和内置资源**平起平坐**：

| 能力 | 内置资源（如 Deployment） | 自建 CRD（如 WebApp） |
|---|---|---|
| `kubectl get/apply/describe` | ✅ | ✅ |
| 字段级 schema 校验与默认值 | ✅ | ✅（写在 CRD 里） |
| `-o wide` 自定义列 | ✅ | ✅（printer columns） |
| `status` 子资源 | ✅ | ✅（`subresources.status`） |
| watch / informer / RBAC | ✅ | ✅ |

**关键区分：CRD 只是"数据"，Controller 才是"行为"。**

```text
CRD          = 类型定义（schema）           → 让 API Server 认识新对象
Controller   = 调谐循环（把实际推向期望）   → 让新对象"活"起来
CRD + Controller = Operator
```

本章你会**先写 CRD，再写 Controller**，最后把它跑在集群里验证自愈。

本集群现在就有 **132 个 CRD**——几乎全是各种 Operator 装进来的：

```bash
kubectl --kubeconfig ./kubeconfig get crd --no-headers | wc -l
```

```text
132
```

---

## 2. 拆开一个 CRD 看结构

CRD 本身也是一个资源，`apiVersion` 是 `apiextensions.k8s.io/v1`。顶层骨架：

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: webapps.demo.example.com     # <plural>.<group>
spec:
  group: demo.example.com            # ① API 组
  names:
    kind: WebApp                     # ② Kind
    listKind: WebAppList
    plural: webapps
    singular: webapp
    shortNames: [wa]
  scope: Namespaced                  # ③ 作用域
  versions:                          # ④ 版本
    - name: v1
      served: true
      storage: true
      subresources:
        status: {}                   # ⑤ status 子资源
      additionalPrinterColumns: [...] # ⑥ -o wide 的列
      schema:
        openAPIV3Schema: {...}       # ⑦ 校验 schema
```

逐个说：

**① group / version / kind（合称 GVK）**
`group=demo.example.com` + `version=v1` 拼成 **apiVersion**：`demo.example.com/v1`。
`metadata.name` 必须是 `<plural>.<group>`，即 `webapps.demo.example.com`——API Server 用这个名字保证唯一。

**② names**
`kind` 是对外类型名（`WebApp`），`plural` 决定 URL 路径（`/apis/demo.example.com/v1/namespaces/<ns>/webapps`），
`shortNames` 是缩写（`kubectl get wa`）。这些**全部由你定义**，但要遵守命名规范。

**③ scope**
`Namespaced`（默认）还是 `Cluster`。本集群两种都有：

```bash
kubectl --kubeconfig ./kubeconfig get crd clusters.management.cattle.io -o jsonpath='{.spec.group}{" / "}{.spec.names.kind}{" / scope="}{.spec.scope}'
```

```text
management.cattle.io / Cluster / scope=Cluster
```

**④ 版本与 served / storage**
一个 CRD 可以有多个版本。`served=true` 表示对外提供，`storage=true` 表示**持久化用哪个版本**（有且仅有一个为 true）。
Gateway API 就是多版本共存：

```bash
kubectl --kubeconfig ./kubeconfig get crd gateways.gateway.networking.k8s.io -o jsonpath='{range .spec.versions[*]}{.name}{" served="}{.served}{" storage="}{.storage}{"\n"}{end}'
```

```text
v1 served=true storage=true
v1beta1 served=true storage=false
```

**⑤ subresources.status**
加上它之后，`spec` 和 `status` 可以**分开写入**：控制器只改 `status` 不会碰到 `spec`，
权限也能拆成 `webapps` 与 `webapps/status` 两组。这是 Operator 的标配。

**⑥ additionalPrinterColumns**
决定 `kubectl get <kind> -o wide` 多显示哪些列，值用 **JSONPath** 从对象里取。
看两个真实例子——cert-manager 的 `Certificate`：

```bash
kubectl --kubeconfig ./kubeconfig get crd certificates.cert-manager.io -o jsonpath='{range .spec.versions[0].additionalPrinterColumns[*]}{.name}{"  <-  "}{.jsonPath}{"\n"}{end}'
```

```text
Ready  <-  .status.conditions[?(@.type == "Ready")].status
Secret  <-  .spec.secretName
Issuer  <-  .spec.issuerRef.name
Status  <-  .status.conditions[?(@.type == "Ready")].message
Age  <-  .metadata.creationTimestamp
```

注意 `Ready` 这一列：它用 **JSONPath 过滤表达式** `[?(@.type == "Ready")]` 从 conditions 数组里挑出 Ready 那条，
再取它的 `status`。这就是为什么 `kubectl get certificate` 能一眼看到 `True/False`。

Fleet 的 `GitRepo` 同理：

```bash
kubectl --kubeconfig ./kubeconfig get crd gitrepos.fleet.cattle.io -o jsonpath='{range .spec.versions[0].additionalPrinterColumns[*]}{.name}{"  <-  "}{.jsonPath}{"\n"}{end}'
```

```text
Repo  <-  .spec.repo
Commit  <-  .status.commit
BundleDeployments-Ready  <-  .status.display.readyBundleDeployments
Status  <-  .status.conditions[?(@.type=="Ready")].message
```

**⑦ schema（结构性 schema）**
写在 `openAPIV3Schema` 里，决定两件事：

1. **校验**：类型、`required`、`minimum`/`maximum`、`enum`、`pattern` 等，写错直接拒绝；
2. **裁剪（pruning）**：**不在 schema 里的字段会被 API Server 丢弃**。

第 2 条极其重要：如果你给 `status` 只写了 `type: object` 而没有展开 `properties`，
那么控制器写进去的 `readyReplicas`、`conditions` **会被静默裁掉**。正确做法是二选一：

- 老老实实把 `status` 的 `properties` 展开（controller-gen 的做法）；
- 或者显式声明 `x-kubernetes-preserve-unknown-fields: true`（本章手写版对 `status` 采用，便于阅读）。

另外两个常用命令：

```bash
kubectl --kubeconfig ./kubeconfig api-resources --api-group=demo.example.com   # 还没建，先看 cert-manager 的
kubectl --kubeconfig ./kubeconfig api-resources --api-group=cert-manager.io
```

```text
NAME                  SHORTNAMES   APIVERSION           NAMESPACED   KIND
certificaterequests   cr,crs       cert-manager.io/v1   true         CertificateRequest
certificates          cert,certs   cert-manager.io/v1   true         Certificate
clusterissuers        ciss         cert-manager.io/v1   false        ClusterIssuer
issuers               iss          cert-manager.io/v1   true         Issuer
```

`kubectl explain` 也能读懂 CRD 的 schema：

```bash
kubectl --kubeconfig ./kubeconfig explain gitrepo.spec
```

```text
GROUP:      fleet.cattle.io
KIND:       GitRepo
VERSION:    v1alpha1

FIELD: spec <Object>

DESCRIPTION:
    <empty>
FIELDS:
  branch	<string>
    Branch The git branch to follow.

  bundles	<[]Object>
    Bundles defines the paths of bundles to be read.
...
  clientSecretName	<string>
    ClientSecretName is the name of the client secret to be used to connect to
    the repo
...
```

---

## 3. 看现成 Operator 的 CRD

**CRD 数量**：本集群 132 个。它们几乎都是"某某 Operator"带进来的。

**例子一：cert-manager**（第 31 章用过它签发证书）。
先看它的 CRD 结构：

```bash
kubectl --kubeconfig ./kubeconfig get crd certificates.cert-manager.io -o jsonpath='{.spec.names.kind}{"\n"}{.spec.scope}{"\n"}{.spec.versions[*].name}{"\n"}{.spec.versions[0].subresources}{"\n"}'
```

```text
Certificate
Namespaced
v1
{"status":{}}
```

再看一个**真实实例**。Rancher 用 cert-manager 给自己的入口签证书，`cattle-system` 里有个 `Issuer`：

```bash
kubectl --kubeconfig ./kubeconfig -n cattle-system get issuers
```

```text
NAMESPACE       NAME      READY   AGE
cattle-system   rancher   True    141d
```

注意这一行输出的 `READY=True`——它是**从 printer column 的 JSONPath 算出来的**（见上一节）。
`Issuer` 对象本身长这样（省略了所有时间戳与 `managedFields`）：

```bash
kubectl --kubeconfig ./kubeconfig -n cattle-system get issuer rancher -o yaml
```

```yaml
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  annotations:
    meta.helm.sh/release-name: rancher
    meta.helm.sh/release-namespace: cattle-system
  labels:
    app: rancher
    app.kubernetes.io/managed-by: Helm
    chart: rancher-2.14.1
    heritage: Helm
    release: rancher
  name: rancher
  namespace: cattle-system
spec:
  ca:
    secretName: tls-rancher
status:
  conditions:
  - lastTransitionTime: "2026-05-25T10:16:28Z"
    message: Signing CA verified
    observedGeneration: ...
    reason: KeyPairVerified
    status: "True"
    type: Ready
```

**这就是 Operator 的本质**：你只写了 `spec`（"我要一个 CA 签发者，密钥放在 `tls-rancher`"），
cert-manager 的控制器去做了实际工作，然后把结果写进 `status.conditions`（`Ready=True`，`reason=KeyPairVerified`）。
你**没有**告诉它怎么做，它自己把期望变成了现实。

**例子二：Fleet**（第 26–30 章用过）。它的 `GitRepo` 也是同一个模式：

```bash
kubectl --kubeconfig ./kubeconfig get crd gitrepos.fleet.cattle.io -o jsonpath='{.spec.names.kind}{" / "}{.spec.scope}{"\n"}{.spec.versions[0].subresources}{"\n"}'
```

```text
GitRepo / Namespaced
{"status":{}}
```

`GitRepo` 的 `spec.repo` 指向 git 仓库，`status.commit` 是**它实际同步到哪个 commit**——
这就是"期望 vs 观测"在 printer column 上的直接体现。

**例子三：Rancher 自己**。Rancher 的管理 API 几乎全是 CRD：

```bash
kubectl --kubeconfig ./kubeconfig get clusters.management.cattle.io
```

```text
NAME    AGE
local   141d
```

`Cluster` 是**集群级** CRD（`scope=Cluster`）——因为"集群"这个概念本身不属于任何命名空间。
同一套机制，作用域按语义选。

**例子四：Gateway API**（第 37/41 章）。它的 CRD 是多版本的（`v1` 与 `v1beta1` 都 `served`，
只有 `v1` 是 `storage`），这也是 CRD 版本演进的通用做法。

> **前瞻（第 43 章）**：Kyverno 本身也是**一组 Operator**——它自带 admission/background/cleanup/reports
> 四个控制器和**一整套自家 CRD**（ClusterPolicy、Policy、PolicyReport……）。
> 学完本章，你就能理解"为什么装一个策略引擎会往集群里塞进上百个 CRD"。

---

## 4. 手写一个 CRD：`webapps.demo.example.com/v1`

现在自己写。目标：

```text
group   : demo.example.com
version : v1
kind    : WebApp  (plural: webapps, shortName: wa)
scope   : Namespaced
spec    : image(必填) / replicas(默认1, 0-10) / port(可选)
status  : readyReplicas / observedGeneration / conditions
列      : Image / Replicas / Ready / Age
```

文件在 `~/k3s-ops/examples/webapp-operator/config/crd/webapp.yaml`：

`examples/webapp-operator/config/crd/webapp.yaml`：

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: webapps.demo.example.com
spec:
  # 1) 归属哪个 API 组、哪个版本
  group: demo.example.com
  names:
    kind: WebApp
    listKind: WebAppList
    plural: webapps
    singular: webapp
    shortNames:
      - wa
  scope: Namespaced
  versions:
    - name: v1
      served: true
      storage: true
      # 2) 启用 status 子资源：spec 与 status 分开写入，控制器更新 status 不会碰到 spec
      subresources:
        status: {}
      # 3) kubectl get webapps 时显示的额外列
      additionalPrinterColumns:
        - name: Image
          type: string
          jsonPath: .spec.image
        - name: Replicas
          type: integer
          jsonPath: .spec.replicas
        - name: Ready
          type: integer
          jsonPath: .status.readyReplicas
        - name: Age
          type: date
          jsonPath: .metadata.creationTimestamp
      # 4) 结构性 schema：API Server 用它做校验与裁剪
      schema:
        openAPIV3Schema:
          type: object
          description: WebApp 描述一个由控制器托管的无状态应用。
          properties:
            spec:
              type: object
              description: 期望状态，由用户书写。
              required: [image]
              properties:
                image:
                  type: string
                  minLength: 1
                  description: 容器镜像。
                replicas:
                  type: integer
                  format: int32
                  default: 1
                  minimum: 0
                  maximum: 10
                  description: 期望副本数，默认 1。
                port:
                  type: integer
                  format: int32
                  description: 容器端口（可选）。
            status:
              type: object
              description: 观测状态，由控制器书写。
              # 为便于手写阅读，这里不展开 conditions 的完整 schema；
              # 若要像内置资源一样做严格校验，交由 controller-gen 从 Go 类型生成。
              x-kubernetes-preserve-unknown-fields: true
```

### 应用并验证

```bash
kubectl --kubeconfig ./kubeconfig apply -f examples/webapp-operator/config/crd/webapp.yaml
kubectl --kubeconfig ./kubeconfig wait --for=condition=Established crd/webapps.demo.example.com --timeout=60s
```

```text
customresourcedefinition.apiextensions.k8s.io/webapps.demo.example.com created
customresourcedefinition.apiextensions.k8s.io/webapps.demo.example.com condition met
```

注册成功后，`kubectl` 立刻就能"看见"这个新类型：

```bash
kubectl --kubeconfig ./kubeconfig get crd webapps.demo.example.com -o custom-columns=NAME:.metadata.name,GROUP:.spec.group,KIND:.spec.names.kind,SCOPE:.spec.scope
kubectl --kubeconfig ./kubeconfig api-resources --api-group=demo.example.com
```

```text
NAME                       GROUP              KIND     SCOPE
webapps.demo.example.com   demo.example.com   WebApp   Namespaced

NAME      SHORTNAMES   APIVERSION            NAMESPACED   KIND
webapps   wa           demo.example.com/v1   true         WebApp
```

`kubectl explain` 也认识它了——注意 `image` 标了 `-required-`：

```bash
kubectl --kubeconfig ./kubeconfig explain webapp.spec
```

```text
GROUP:      demo.example.com
KIND:       WebApp
VERSION:    v1

FIELD: spec <Object>

DESCRIPTION:
    期望状态，由用户书写。
    
FIELDS:
  image	<string> -required-
    容器镜像。

  port	<integer>
    容器端口（可选）。

  replicas	<integer>
    期望副本数，默认 1。
```

### 实测校验与默认值

**默认值**：不写 `replicas`，用 `--dry-run=server` 看 API Server 补了什么：

```bash
kubectl --kubeconfig ./kubeconfig apply --dry-run=server -n default -f - <<'YAML'
apiVersion: demo.example.com/v1
kind: WebApp
metadata:
  name: dryrun-default-test
spec:
  image: nginx:1.27-alpine
YAML
```

```yaml
apiVersion: demo.example.com/v1
kind: WebApp
metadata:
  name: dryrun-default-test
  namespace: default
spec:
  image: nginx:1.27-alpine
  replicas: 1          # ← 我们没写，API Server 按 schema 的 default 补上了
```

**校验**：`replicas` 越界直接拒绝——

```bash
kubectl --kubeconfig ./kubeconfig apply --dry-run=server -n default -f - <<'YAML'
apiVersion: demo.example.com/v1
kind: WebApp
metadata:
  name: dryrun-invalid-test
spec:
  image: nginx:1.27-alpine
  replicas: 99
YAML
```

```text
The WebApp "dryrun-invalid-test" is invalid: spec.replicas: Invalid value: 99: spec.replicas in body should be less than or equal to 10
```

缺 `image` 同样拒绝：

```text
The WebApp "dryrun-noimage-test" is invalid: spec.image: Required value
```

**这就是 CRD 相对"注解 + 约定"最大的价值**：非法对象**根本进不了 etcd**，不用等控制器去发现。

### 对比：controller-gen 生成的版本

手写 CRD 是学习手段；真实项目一般用 `controller-gen` **从 Go 类型生成**。
生成版在 `examples/webapp-operator/config/crd/generated/webapp.generated.yaml`，与手写版的差异：

| 维度 | 手写版 | controller-gen 生成版 |
|---|---|---|
| 来源 | 手写 | 从 `api/v1/*.go` 的注释标记生成 |
| `spec.required` | `[image]` | `[image, replicas]`（因为 Go 里 `Replicas int32` 无 `omitempty`） |
| `status` | `x-kubernetes-preserve-unknown-fields: true` | 把 `conditions` 的完整 schema（`lastTransitionTime`/`message`/`reason`…）都展开 |
| 描述 | 手写文案 | 从 Go 注释自动搬运 |
| printer columns | 手写 | 从 `+kubebuilder:printcolumn` 标记生成 |

生成版的 `required` 片段（真实内容）：

```yaml
            required:
            - image
            - replicas
            type: object
```

> 注意：生成版要求 `replicas` 必填，看起来和"默认 1"冲突——其实不冲突：**默认值在校验之前应用**，
> 用户不写 `replicas` 时会被补成 1，`required` 自然满足。手写版因为 `required` 只列了 `image`，
> 行为一致但少一层解释成本。**生产建议用生成版**，让 Go 类型与 CRD 永远同源。

---

## 5. 声明式与调谐循环

CRD 解决"类型"，控制器解决"行为"。控制器的核心是一个**调谐循环**：

```text
        ┌─────────────────────────────────────────────┐
        │            Reconcile(key)                   │
        │                                             │
  watch │   1. 读 CR        → 期望状态 (spec)         │
 ──────►│   2. 读下游对象   → 实际状态 (status)       │  ← 只拿到 namespace/name
        │   3. 若不一致     → 写：把实际推向期望      │
        │   4. 回写 CR.status ← 观测结果              │
        └─────────────────────────────────────────────┘
```

四个必须内化的概念：

**① 期望 vs 观测**
`spec` 是期望（用户写），`status` 是观测（控制器写）。**控制器永远不写 `spec`**。
本章的 WebApp：`spec` 里用户写 `image`/`replicas`；控制器读被管 Deployment 的 `status.readyReplicas` 写回 `status`。

**② 输入只是一个 key**
`Reconcile` 的参数只有 `namespace/name`（不是对象内容）。所以**必须先重新 `Get` 最新状态**——
这带来一个天然好处：**错过事件也没关系**，下一轮从最新状态重新算，结果一致。这叫 **level-triggered**。

**③ 幂等**
同一个 key 被调谐 N 次，结果必须一样。做法：**只在漂移时才写**。
本章的控制器用 `drifted()` 比较 `replicas` 与 `image`，只有不一致才 `Update`。
实测无谓写入的证据（间隔 20 秒观察 Deployment 的 `resourceVersion`）：

```bash
kubectl --kubeconfig ./kubeconfig -n operator-demo get deploy demo-webapp -o jsonpath='{.metadata.resourceVersion}'
```

```text
sleep 20 前: 908093
sleep 20 后: 908093      # ← 没变化：控制器没有反复写入
```

**④ 事件来源**
除了 watch CR 自己，还要 watch **它创建的下游对象**。
这样"有人手动删了 Deployment"也会触发调谐——这正是自愈的来源。
本章用 `Owns(&appsv1.Deployment{})` 注册这个 watch。

---

## 6. 用 Go + controller-runtime 写一个小控制器

选型：**Go + `sigs.k8s.io/controller-runtime`**。它是 kubebuilder/Operator SDK 的共同底座，
k8s 生态里写控制器的"事实标准"。

### 6.1 初始化模块

```bash
cd ~/k3s-ops/examples/webapp-operator
go mod init example.com/webapp-operator
go get sigs.k8s.io/controller-runtime@v0.18.4
go mod tidy
```

本集群是 k8s `v1.30.2`，`controller-runtime v0.18.x` 正好配套 `k8s.io/* v0.30.x`：
Go 依赖的大版本**要贴着集群版本选**，否则容易出现 API 不兼容。

### 6.2 定义类型（api/v1）

**`groupversion_info.go`** 负责注册 GVK：

`examples/webapp-operator/api/v1/groupversion_info.go`：

```go
// Package v1 contains API Schema definitions for the demo.example.com v1 API group.
// +kubebuilder:object:generate=true
// +groupName=demo.example.com
package v1

import (
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/scheme"
)

var (
	// GroupVersion is group version used to register these objects.
	GroupVersion = schema.GroupVersion{Group: "demo.example.com", Version: "v1"}

	// SchemeBuilder is used to add go types to the GroupVersionKind scheme.
	SchemeBuilder = &scheme.Builder{GroupVersion: GroupVersion}

	// AddToScheme adds the types in this group-version to the given scheme.
	AddToScheme = SchemeBuilder.AddToScheme
)
```

**`webapp_types.go`** 定义 spec/status。上面那些 `+kubebuilder:*` 注释是给 controller-gen 看的，
它会把注释翻译成 CRD 里的校验、默认值、printer columns：

`examples/webapp-operator/api/v1/webapp_types.go`：

```go
package v1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// WebAppSpec 定义 WebApp 的期望状态。
type WebAppSpec struct {
	// Image 是控制器创建的 Deployment 所使用的容器镜像。
	// +kubebuilder:validation:MinLength=1
	Image string `json:"image"`

	// Replicas 是期望的副本数。
	// +kubebuilder:default=1
	// +kubebuilder:validation:Minimum=0
	// +kubebuilder:validation:Maximum=10
	Replicas int32 `json:"replicas"`

	// Port 是容器暴露的端口，可选。
	// +optional
	Port *int32 `json:"port,omitempty"`
}

// WebAppStatus 定义 WebApp 的观测状态。
type WebAppStatus struct {
	// ReadyReplicas 来自被管 Deployment 的 status。
	// +optional
	ReadyReplicas int32 `json:"readyReplicas,omitempty"`

	// ObservedGeneration 是最近一次调谐到的 .metadata.generation。
	// +optional
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`

	// Conditions 描述 WebApp 的当前状况。
	// +optional
	// +listType=map
	// +listMapKey=type
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:shortName=wa
// +kubebuilder:printcolumn:name="Image",type=string,JSONPath=`.spec.image`
// +kubebuilder:printcolumn:name="Replicas",type=integer,JSONPath=`.spec.replicas`
// +kubebuilder:printcolumn:name="Ready",type=integer,JSONPath=`.status.readyReplicas`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`

// WebApp 是 webapps API 的 Schema。
type WebApp struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   WebAppSpec   `json:"spec,omitempty"`
	Status WebAppStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// WebAppList 包含 WebApp 的列表。
type WebAppList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []WebApp `json:"items"`
}

func init() {
	SchemeBuilder.Register(&WebApp{}, &WebAppList{})
}
```

生成 deepcopy 和 CRD：

```bash
go install sigs.k8s.io/controller-tools/cmd/controller-gen@v0.17.0
export PATH="$(go env GOPATH)/bin:$PATH"   # controller-gen 装在 GOPATH/bin

controller-gen object paths="./api/..."
controller-gen crd paths="./api/..." output:crd:dir=config/crd/generated
```

`zz_generated.deepcopy.go` 是 `object` 生成的（`runtime.Object` 需要 `DeepCopyObject`），
`config/crd/generated/` 下是 CRD。**这两个产物不要手改**，改 Go 类型后重新生成。

### 6.3 写调谐逻辑

`examples/webapp-operator/internal/controller/webapp_controller.go`：

```go
package controller

import (
	"context"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"

	demoV1 "example.com/webapp-operator/api/v1"
)

// ConditionAvailable 表示被管 Deployment 的可用副本数已达到期望值。
const ConditionAvailable = "Available"

// 固定标签契约：被管 Deployment 及 Pod 都带上 instance 标签，值为 WebApp 名。
const labelInstance = "app.kubernetes.io/instance"

// WebAppReconciler 调谐 WebApp：确保同名 Deployment 存在且与 spec 一致，并回写 status。
type WebAppReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

// +kubebuilder:rbac:groups=demo.example.com,resources=webapps,verbs=get;list;watch;update;patch
// +kubebuilder:rbac:groups=demo.example.com,resources=webapps/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=apps,resources=deployments,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups="",resources=events,verbs=create

// Reconcile 把实际状态推向期望状态。调谐必须幂等：重复执行结果一致。
func (r *WebAppReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	// 1. 取 CR；不存在说明已被删除，忽略即可（ownerreference 会级联回收下游）。
	var webapp demoV1.WebApp
	if err := r.Get(ctx, req.NamespacedName, &webapp); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	// 2. 组装期望的 Deployment。
	desired := r.desiredDeployment(&webapp)

	// 3. 读现有 Deployment：不存在则创建，存在则只在漂移时更新。
	var current appsv1.Deployment
	err := r.Get(ctx, types.NamespacedName{Name: desired.Name, Namespace: desired.Namespace}, &current)
	switch {
	case apierrors.IsNotFound(err):
		logger.Info("creating deployment", "deployment", desired.Name)
		if err := r.Create(ctx, desired); err != nil {
			return ctrl.Result{}, err
		}
		// 创建后下一轮再回写 status（此时 Deployment 尚无 status）。
		return ctrl.Result{}, nil
	case err != nil:
		return ctrl.Result{}, err
	}

	if drifted(&current, desired) {
		logger.Info("updating deployment", "deployment", desired.Name)
		current.Spec.Replicas = desired.Spec.Replicas
		current.Spec.Template.Spec.Containers[0].Image = desired.Spec.Template.Spec.Containers[0].Image
		if err := r.Update(ctx, &current); err != nil {
			return ctrl.Result{}, err
		}
	}

	// 4. 回写 status（用观测到的 Deployment 状态，而不是期望值）。
	if err := r.updateStatus(ctx, &webapp, &current); err != nil {
		return ctrl.Result{}, err
	}

	return ctrl.Result{}, nil
}

// desiredDeployment 依据 WebApp 组装被管 Deployment。
func (r *WebAppReconciler) desiredDeployment(webapp *demoV1.WebApp) *appsv1.Deployment {
	replicas := webapp.Spec.Replicas
	port := int32(80)
	if webapp.Spec.Port != nil {
		port = *webapp.Spec.Port
	}

	labels := map[string]string{labelInstance: webapp.Name}

	deploy := &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{
			Name:      webapp.Name,
			Namespace: webapp.Namespace,
			Labels:    labels,
		},
		Spec: appsv1.DeploymentSpec{
			Replicas: &replicas,
			Selector: &metav1.LabelSelector{MatchLabels: labels},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{Labels: labels},
				Spec: corev1.PodSpec{
					Containers: []corev1.Container{
						{
							Name:  "webapp",
							Image: webapp.Spec.Image,
							Ports: []corev1.ContainerPort{{ContainerPort: port}},
						},
					},
				},
			},
		},
	}

	// 关键：ownerReference 指向 CR，删除 CR 时下游被级联回收。
	_ = controllerutil.SetControllerReference(webapp, deploy, r.Scheme)
	return deploy
}

// drifted 判断现有 Deployment 是否偏离期望（只比较本章关心的两个字段）。
func drifted(current, desired *appsv1.Deployment) bool {
	if current.Spec.Replicas == nil || desired.Spec.Replicas == nil {
		return true
	}
	if *current.Spec.Replicas != *desired.Spec.Replicas {
		return true
	}
	return current.Spec.Template.Spec.Containers[0].Image != desired.Spec.Template.Spec.Containers[0].Image
}

// updateStatus 依据被管 Deployment 的真实状态更新 CR 的 status 子资源。
func (r *WebAppReconciler) updateStatus(ctx context.Context, webapp *demoV1.WebApp, deploy *appsv1.Deployment) error {
	webapp.Status.ReadyReplicas = deploy.Status.ReadyReplicas
	webapp.Status.ObservedGeneration = webapp.Generation

	available := deploy.Status.ReadyReplicas >= webapp.Spec.Replicas
	status := metav1.ConditionFalse
	reason := "Unavailable"
	if available {
		status = metav1.ConditionTrue
		reason = "MinimumReplicasAvailable"
	}
	meta.SetStatusCondition(&webapp.Status.Conditions, metav1.Condition{
		Type:               ConditionAvailable,
		Status:             status,
		Reason:             reason,
		ObservedGeneration: webapp.Generation,
		Message:            "被管 Deployment 的可用副本数已对齐期望值",
	})

	return r.Status().Update(ctx, webapp)
}

// SetupWithManager 注册控制器；Owns 让被管 Deployment 的变化也触发调谐。
func (r *WebAppReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&demoV1.WebApp{}).
		Owns(&appsv1.Deployment{}).
		Complete(r)
}
```

五个要点：

1. **`NotFound` 不是错误**：CR 已被删除时直接返回（`client.IgnoreNotFound`），下游由 `ownerReference` 回收。
2. **`ownerReference`**：`controllerutil.SetControllerReference(webapp, deploy, scheme)` 让 Deployment 归 CR 所有，
   删 CR 时 k8s GC 会级联删除 Deployment（实测见第 9 节）。
3. **只改漂移字段**：`drifted()` 不成立就不 `Update`，保证幂等、避免 `resourceVersion` 抖动。
4. **status 用观测值**：`readyReplicas` 取自 **Deployment 的 status**，不是 `spec.replicas`。
5. **`Owns()`**：注册对 Deployment 的 watch，手动删 Deployment 也能触发自愈。

### 6.4 装配 manager（main.go）

`examples/webapp-operator/main.go`：

```go
package main

import (
	"flag"
	"os"

	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/cache"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"

	demoV1 "example.com/webapp-operator/api/v1"
	"example.com/webapp-operator/internal/controller"
)

var scheme = runtime.NewScheme()

// 控制器只管理这一个命名空间。默认情况下 controller-runtime 的 informer 会在
// 集群级别 list/watch，那就必须给集群级权限；把缓存限定到命名空间后，命名空间级
// 的 Role 就够用了（这就是"命名空间级 Operator"的最小权限做法）。
const watchNamespace = "operator-demo"

func init() {
	// 内置类型（Deployment 等）+ 我们自己的 WebApp。
	_ = clientgoscheme.AddToScheme(scheme)
	_ = demoV1.AddToScheme(scheme)
}

func main() {
	var metricsAddr string
	flag.StringVar(&metricsAddr, "metrics-bind-address", ":8080", "metrics 监听地址")

	zapOpts := zap.Options{Development: true}
	zapOpts.BindFlags(flag.CommandLine)
	flag.Parse()

	ctrl.SetLogger(zap.New(zap.UseFlagOptions(&zapOpts)))

	// 单副本运行，不需要 leader election。
	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme:                 scheme,
		Metrics:                metricsserver.Options{BindAddress: metricsAddr},
		LeaderElection:         false,
		HealthProbeBindAddress: ":8081",
		Cache: cache.Options{
			DefaultNamespaces: map[string]cache.Config{watchNamespace: {}},
		},
	})
	if err != nil {
		ctrl.Log.Error(err, "unable to start manager")
		os.Exit(1)
	}

	if err := (&controller.WebAppReconciler{
		Client: mgr.GetClient(),
		Scheme: mgr.GetScheme(),
	}).SetupWithManager(mgr); err != nil {
		ctrl.Log.Error(err, "unable to create controller", "controller", "WebApp")
		os.Exit(1)
	}

	ctrl.Log.Info("starting webapp-operator")
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		ctrl.Log.Error(err, "problem running manager")
		os.Exit(1)
	}
}
```

> **`Cache: cache.Options{DefaultNamespaces: ...}` 这一行是本章最值钱的一课**，见第 9 节的真实踩坑：
> 不限定命名空间，控制器就需要**集群级**权限；限定了，**命名空间级 Role** 就够。

编译验证：

```bash
go build ./... && go vet ./...
```

---

## 7. 打包与在集群内运行

控制器要跑在集群里，就需要镜像 + RBAC + Deployment 三样。

### 7.1 静态编译 + scratch 镜像

`examples/webapp-operator/Dockerfile`：

```dockerfile
# 第一段：借 alpine 提供 CA 证书（控制器要访问 apiserver，需要校验证书链）。
# alpine:3.20 体积小，且这里只为了取一个文件，不会进入最终镜像。
FROM alpine:3.20 AS certs

# 第二段：最终镜像。scratch 是空镜像，只放静态二进制 + CA 证书，
# 没有 shell、没有包管理器，攻击面最小。
FROM scratch

COPY --from=certs /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY bin/webapp-operator /webapp-operator

# 以非 root 用户运行，对应 config/manager/deployment.yaml 里的 runAsNonRoot: true。
# scratch 里没有 /etc/passwd，用数字 UID/GID 即可（65532 是 k8s 生态常用的 nonroot）。
USER 65532:65532

ENTRYPOINT ["/webapp-operator"]
```

两个容易踩的地方：

- **必须带 CA 证书**。`scratch` 空镜像没有 `/etc/ssl/certs`，控制器连 apiserver 会报 x509 错误。
  这里从 `alpine` 阶段拷一份证书进去。
- **必须声明非 root 用户**。`scratch` 默认 UID 0，而 Deployment 里写了 `runAsNonRoot: true`，
  不写 `USER` 会被 kubelet 直接拒绝启动。

构建与分发（宿主机有 Docker，但集群没有内网 registry）：

```bash
cd ~/k3s-ops/examples/webapp-operator
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o bin/webapp-operator .
docker build -t webapp-operator:v0.1.0 .
docker save -o /tmp/webapp-operator-v0.1.0.tar webapp-operator:v0.1.0
```

然后回到**仓库根目录**再分发（`vagrant` 命令要在有 `Vagrantfile` 的 `~/k3s-ops` 下执行）：

```bash
cd ~/k3s-ops
vagrant upload /tmp/webapp-operator-v0.1.0.tar /tmp/webapp-operator-v0.1.0.tar k3s-demo-agent-1
vagrant ssh k3s-demo-agent-1 -c "sudo k3s ctr images import /tmp/webapp-operator-v0.1.0.tar"
vagrant ssh k3s-demo-agent-1 -c "sudo k3s ctr images ls -q | grep webapp-operator"
```

```text
-rw------- 1 liming liming 39825920 10月14日 12:50 /tmp/webapp-operator-v0.1.0.tar

Upload has completed successfully!

unpacking docker.io/library/webapp-operator:v0.1.0 (sha256:40a1b78d8da3594e1354127b89030d9f340a935f60f4beac5205e99a09f8529e)...done

docker.io/library/webapp-operator:v0.1.0
```

> `CGO_ENABLED=0` 产生静态二进制（scratch 里没有 glibc）；`-ldflags="-s -w"` 去掉调试符号，
> 二进制从约 58MB 降到约 40MB。

### 7.2 最小权限 RBAC

**关键点**：控制器只需要 `operator-demo` 这一个命名空间，所以用**命名空间级 `Role`**（不是 ClusterRole）：

`examples/webapp-operator/config/rbac/role.yaml`：

```yaml
# 最小权限：只授予控制器真正需要的动词，且只作用于 operator-demo 命名空间。
# 用命名空间级 Role 而非 ClusterRole，避免控制器拥有全集群的 Deployment 权限。
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: webapp-operator
  namespace: operator-demo
rules:
  - apiGroups: ["demo.example.com"]
    resources: ["webapps"]
    verbs: ["get", "list", "watch", "update", "patch"]
  - apiGroups: ["demo.example.com"]
    resources: ["webapps/status"]
    verbs: ["get", "update", "patch"]
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create"]
```

`examples/webapp-operator/config/rbac/serviceaccount.yaml`：

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: webapp-operator
  namespace: operator-demo
```

`examples/webapp-operator/config/rbac/rolebinding.yaml`：

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: webapp-operator
  namespace: operator-demo
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: webapp-operator
subjects:
  - kind: ServiceAccount
    name: webapp-operator
    namespace: operator-demo
```

注意 `webapps/status` 是单独一条规则——这正是 `subresources.status` 带来的**权限拆分**能力。

### 7.3 控制器的 Deployment

`examples/webapp-operator/config/manager/deployment.yaml`：

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp-operator
  namespace: operator-demo
  labels:
    app.kubernetes.io/name: webapp-operator
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: webapp-operator
  template:
    metadata:
      labels:
        app.kubernetes.io/name: webapp-operator
    spec:
      serviceAccountName: webapp-operator
      # 镜像只导入了 agent-1 的 containerd，因此把 Pod 钉到这台节点。
      nodeSelector:
        kubernetes.io/hostname: k3s-demo-agent-1
      containers:
        - name: manager
          image: webapp-operator:v0.1.0
          imagePullPolicy: IfNotPresent
          args:
            - --metrics-bind-address=:8080
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
          securityContext:
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
```

`imagePullPolicy: IfNotPresent` 配合"手动导入镜像"：节点本地已有该 tag，就不去远端拉。
`nodeSelector` 把 Pod 钉在 `k3s-demo-agent-1`（镜像只导入了这台），
`securityContext` 沿用第 39 章的非 root、不可提权、只读根文件系统。

### 7.4 部署并按顺序应用

```bash
cd ~/k3s-ops
kubectl --kubeconfig ./kubeconfig create namespace operator-demo
kubectl --kubeconfig ./kubeconfig apply -f examples/webapp-operator/config/rbac
kubectl --kubeconfig ./kubeconfig apply -f examples/webapp-operator/config/manager/deployment.yaml
kubectl --kubeconfig ./kubeconfig -n operator-demo rollout status deploy/webapp-operator --timeout=120s
kubectl --kubeconfig ./kubeconfig -n operator-demo get pods -o wide
```

```text
namespace/operator-demo created
role.rbac.authorization.k8s.io/webapp-operator created
rolebinding.rbac.authorization.k8s.io/webapp-operator created
serviceaccount/webapp-operator created
deployment.apps/webapp-operator created
deployment "webapp-operator" successfully rolled out

NAME                               READY   STATUS    RESTARTS   AGE   IP            NODE               NOMINATED NODE   READINESS GATES
webapp-operator-669d76646f-kcc7n   1/1     Running   0          10s   10.42.1.185   k3s-demo-agent-1   <none>           <none>
```

看启动日志：manager 起来了，watch 建立，worker 开始工作——**没有任何 forbidden / x509 错误**：

```bash
kubectl --kubeconfig ./kubeconfig -n operator-demo logs deploy/webapp-operator --tail=10
```

```text
2026-10-14T04:57:03Z	INFO	starting webapp-operator
2026-10-14T04:57:03Z	INFO	controller-runtime.metrics	Starting metrics server
2026-10-14T04:57:03Z	INFO	starting server	{"name": "health probe", "addr": "[::]:8081"}
2026-10-14T04:57:03Z	INFO	Starting EventSource	{"controller": "webapp", "controllerGroup": "demo.example.com", "controllerKind": "WebApp", "source": "kind source: *v1.WebApp"}
2026-10-14T04:57:03Z	INFO	Starting EventSource	{"controller": "webapp", "controllerGroup": "demo.example.com", "controllerKind": "WebApp", "source": "kind source: *v1.Deployment"}
2026-10-14T04:57:03Z	INFO	Starting Controller	{"controller": "webapp", "controllerGroup": "demo.example.com", "controllerKind": "WebApp"}
2026-10-14T04:57:04Z	INFO	Starting workers	{"controller": "webapp", "controllerGroup": "demo.example.com", "controllerKind": "WebApp", "worker count": 1}
```

---

## 8. 动手验证自愈

创建演示 CR（`image: nginx:1.27-alpine`、`replicas: 2`）：

`examples/webapp-operator/config/samples/demo-webapp.yaml`：

```yaml
apiVersion: demo.example.com/v1
kind: WebApp
metadata:
  name: demo-webapp
  namespace: operator-demo
spec:
  # 控制器会用这个镜像创建一个名为 demo-webapp 的 Deployment
  image: nginx:1.27-alpine
  replicas: 2
```

```bash
kubectl --kubeconfig ./kubeconfig apply -f examples/webapp-operator/config/samples/demo-webapp.yaml
```

### 8.1 下游生成 + printer columns 生效

```bash
kubectl --kubeconfig ./kubeconfig -n operator-demo get webapps -o wide
kubectl --kubeconfig ./kubeconfig -n operator-demo get deploy,po
```

```text
NAME          IMAGE               REPLICAS   READY   AGE
demo-webapp   nginx:1.27-alpine   2          2       14s

NAME                              READY   UP-TO-DATE   AVAILABLE   AGE    CONTAINERS   IMAGES                   SELECTOR
deployment.apps/demo-webapp       2/2     2            2           15s    webapp       nginx:1.27-alpine        app.kubernetes.io/instance=demo-webapp
deployment.apps/webapp-operator   1/1     1            1           2m24s  manager      webapp-operator:v0.1.0   app.kubernetes.io/name=webapp-operator

NAME                                   READY   STATUS    RESTARTS   AGE   IP            NODE                NOMINATED NODE   READINESS GATES
pod/demo-webapp-78dfd877b7-gvhq7       1/1     Running   0          15s   10.42.0.125   k3s-demo-server-1   <none>           <none>
pod/demo-webapp-78dfd877b7-vrpqs       1/1     Running   0          15s   10.42.1.186   k3s-demo-agent-1    <none>           <none>
```

`get webapps -o wide` 里的 `IMAGE / REPLICAS / READY` 三列，就是第 4 节写的 printer columns。
`get deploy,po` 里的 `deployment.apps/demo-webapp` 是**控制器创建**的（注意标签 `app.kubernetes.io/instance=demo-webapp`）。

### 8.2 status 回写

```bash
kubectl --kubeconfig ./kubeconfig -n operator-demo get webapp demo-webapp -o yaml
```

```yaml
apiVersion: demo.example.com/v1
kind: WebApp
metadata:
  name: demo-webapp
  namespace: operator-demo
  generation: 1
  ...
spec:
  image: nginx:1.27-alpine
  replicas: 2
status:
  conditions:
  - lastTransitionTime: "2026-10-14T04:58:39Z"
    message: 被管 Deployment 的可用副本数已对齐期望值
    observedGeneration: 1
    reason: MinimumReplicasAvailable
    status: "True"
    type: Available
  observedGeneration: 1
  readyReplicas: 2
```

`status.readyReplicas=2`、`observedGeneration=1`（等于 `metadata.generation`）、`conditions` 里 `Available=True`。
**这些都是控制器写进去的，用户从未写过 `status`。**

### 8.3 自愈：删掉被管对象自动重建

```bash
kubectl --kubeconfig ./kubeconfig -n operator-demo delete deploy demo-webapp
sleep 10
kubectl --kubeconfig ./kubeconfig -n operator-demo get deploy demo-webapp -o wide
kubectl --kubeconfig ./kubeconfig -n operator-demo logs deploy/webapp-operator --tail=1
```

```text
deployment.apps "demo-webapp" deleted from operator-demo namespace

NAME          READY   UP-TO-DATE   AVAILABLE   AGE   CONTAINERS   IMAGES              SELECTOR
demo-webapp   2/2     2            2           11s   webapp       nginx:1.27-alpine   app.kubernetes.io/instance=demo-webapp

2026-10-14T04:58:47Z	INFO	creating deployment	{"controller": "webapp", ... "deployment": "demo-webapp"}
```

Deployment 被删后**约 10 秒内重建**，日志里出现新的 `creating deployment`。
触发者是 `Owns(&appsv1.Deployment{})` 注册的 watch：**下游变化也会触发调谐**。

### 8.4 跟随：改 CR，下游跟随

```bash
kubectl --kubeconfig ./kubeconfig -n operator-demo patch webapp demo-webapp --type=merge -p '{"spec":{"replicas":3}}'
sleep 14
kubectl --kubeconfig ./kubeconfig -n operator-demo get deploy demo-webapp -o jsonpath='{.spec.replicas}{"\n"}'
kubectl --kubeconfig ./kubeconfig -n operator-demo get webapp demo-webapp -o jsonpath='{.status.readyReplicas}{"\n"}'
kubectl --kubeconfig ./kubeconfig -n operator-demo get webapp demo-webapp -o jsonpath='{.metadata.generation}{" / "}{.status.observedGeneration}{"\n"}'
kubectl --kubeconfig ./kubeconfig -n operator-demo get webapps -o wide
```

```text
webapp.demo.example.com/demo-webapp patched

3          # Deployment 的 spec.replicas 跟随
3          # CR 的 status.readyReplicas 回写
2 / 2      # generation 与 observedGeneration 同步前进
```

```text
NAME          IMAGE               REPLICAS   READY   AGE
demo-webapp   nginx:1.27-alpine   3          3       38s
```

到这里，"声明式 + 调谐"闭环就跑通了：**你只改 CR，其余全是控制器干的。**

---

## 9. 排障与最佳实践

### 9.1 真实踩坑：命名空间级 Role 与集群级 informer 不匹配

这是本章**最值得记住的坑**。第一版控制器配的是命名空间级 `Role`，Pod 起来后 `STATUS=Running`，
看起来一切正常，但**调谐完全不动**。日志在刷：

```text
failed to list *v1.Deployment: deployments.apps is forbidden:
  User "system:serviceaccount:operator-demo:webapp-operator" cannot list
  resource "deployments" in API group "apps" at the cluster scope
```

**原因**：`controller-runtime` 的 informer **默认在集群级别** `list`/`watch`，
哪怕你只想管一个命名空间。命名空间级 `Role` 覆盖不到集群级 list。

**两种解法**：

| 解法 | 效果 | 代价 |
|---|---|---|
| `ClusterRole` + `ClusterRoleBinding` | 立即可用 | 权限放大到整个集群 |
| **把 manager 缓存限定到命名空间**（本章采用） | 命名空间级 Role 即够用 | 控制器只能管理该命名空间 |

```go
Cache: cache.Options{
    DefaultNamespaces: map[string]cache.Config{watchNamespace: {}},
},
```

> **排查提示**：控制器 Pod `Running` 但"什么都不干"，**第一件事就是看日志有没有 `forbidden`**。
> `Running` 只说明容器活着，不代表有权限。

### 9.2 幂等与无谓写入

`Reconcile` 可能被**任意多次**触发（CR 变更、下游变更、重连后重新 list……），
所以必须"**只在漂移时写**"。本章用 `drifted()` 比较关键字段。
如果不做这个判断，每次调谐都 `Update`，会造成 `resourceVersion` 抖动、触发更多事件，甚至热循环。

另一个高频热循环是**"读 `status` 又写 `status`"**：正确做法是写之前比较，或只写真正变化的部分。

### 9.3 status 用子资源

`spec` 与 `status` 分开写入的好处：

- 控制器写 `status` **不会碰 `spec`**：即使用户正好在改 `spec`，也不会互相覆盖；
- RBAC 可以拆开（`webapps` 与 `webapps/status`）；
- CRD 里必须声明 `subresources.status`，并且 CR 的 `status` 字段要在 schema 里可写（否则被裁剪）。

### 9.4 失败就返回 error，让框架退避重试

`Reconcile` 返回 `error` 时，controller-runtime 会**指数退避**重排该 key（不是忙等）。
临时错误（apiserver 抖动、冲突）就该 `return ..., err`；**永久错误**（spec 非法）则应写进 `status.conditions`
并把 `reason` 讲清楚，而不是无限重试。

### 9.5 ownerReference 与级联删除

`SetControllerReference` 建立"归属"关系。删 CR 时 GC 会级联删掉 Deployment 及其 Pod。实测：

```bash
kubectl --kubeconfig ./kubeconfig -n operator-demo delete webapp demo-webapp
kubectl --kubeconfig ./kubeconfig -n operator-demo get deploy demo-webapp
kubectl --kubeconfig ./kubeconfig -n operator-demo get po -l app.kubernetes.io/instance=demo-webapp
```

```text
webapp.demo.example.com "demo-webapp" deleted from operator-demo namespace
Error from server (NotFound): deployments.apps "demo-webapp" not found
No resources found in operator-demo namespace.
```

**注意方向**：`ownerReference` 只做"删父带子"。
**反向不做**：删掉 Deployment **不会**删 CR（那正是自愈能生效的原因）。

### 9.6 finalizer 什么时候才需要

`finalizer` 用来在对象**被删除前**执行清理（"优雅删除"钩子）。
只有当 CR 关联了 **k8s 之外的资源**时才需要，例如：

- 云上创建了负载均衡/数据库/对象存储，删除时要回收；
- 集群外注册了 DNS 记录、监控目标。

本章的 CR 只派生 k8s 内部对象，`ownerReference` 的级联删除就够，**不需要 finalizer**。
误用 finalizer 的典型后果是"对象卡在 `Terminating`"，所以**能不用就不用**。

### 9.7 常用排查命令

```bash
kubectl --kubeconfig ./kubeconfig get crd <plural>.<group>            # CRD 在不在、Established
kubectl --kubeconfig ./kubeconfig explain <kind>.spec                 # schema 对不对
kubectl --kubeconfig ./kubeconfig -n <ns> get <plural> -o yaml        # spec/status 实际内容
kubectl --kubeconfig ./kubeconfig -n <ns> logs deploy/<controller>    # 控制器日志（先看 forbidden）
kubectl --kubeconfig ./kubeconfig -n <ns> get events --sort-by=.lastTimestamp
```

| 现象 | 常见原因 |
|---|---|
| Pod Running 但不动 | RBAC 不足（`forbidden`）、informer 作用域不匹配、controller 未注册 |
| `status` 不更新 | CRD 没开 `subresources.status`、schema 把 status 裁剪了、控制器没写 |
| CR 被拒 | schema 校验失败（看报错里的字段）、`required` 缺字段 |
| CR 一直 `Terminating` | finalizer 没被移除 |
| CRD 应用失败 | `metadata.name` 不是 `<plural>.<group>`、schema 非结构性 |
| 下游反复重建（热循环） | 期望对象与生成对象不一致（如默认值没对齐），每次都判定为"漂移" |

---

## 10. Rancher 界面对照

| 路径 | 对应 kubectl | 用途 |
|---|---|---|
| **集群 → More Resources → demo.example.com → WebApps** | `kubectl --kubeconfig ./kubeconfig -n operator-demo get webapps` | 看自建 CR 列表与 `-o wide` 列 |
| **WebApp 详情 → YAML** | `kubectl --kubeconfig ./kubeconfig -n operator-demo get webapp <n> -o yaml` | 查看接口 `spec` 与控制器回写的 `status` |
| **集群 → CRDs** | `kubectl --kubeconfig ./kubeconfig get crd` | 查看集群里所有 CRD（本集群 **132 个**），含刚注册的 `webapps.demo.example.com` |
| **…→ CustomResourceDefinitions → 某 CRD → YAML** | `kubectl --kubeconfig ./kubeconfig get crd <name> -o yaml` | 查看 group/version/scope/schema/printer columns |
| **…→ 任意 Operator 的 CR**（如 `cert-manager.io → Issuers`） | `kubectl --kubeconfig ./kubeconfig -n cattle-system get issuer` | 对照"现成 Operator"的 spec/status |
| **集群 → Events** | `kubectl --kubeconfig ./kubeconfig -n operator-demo get events` | 看 CR 与下游对象的事件 |

> 提示：自建 CRD 会被 Rancher 归到 **More Resources** 下（按 API 组分目录），
> 和 Gateway API、cert-manager 一样；Rancher 没有"CRD 专用"顶层菜单，
> 但 **集群 → CRDs** 能看到全部类型定义。控制器本身的 Pod 就在 `operator-demo` 命名空间的 Workloads 里。

---

## 动手练习

1. **默认值验证**：不写 `spec.replicas` 创建一个 WebApp，说明最终 `spec.replicas` 是多少、为什么。
2. **校验边界**：把 `replicas` 改成 `0` 和 `11`，分别会发生什么？为什么是这两个数。
3. **printer column**：给 `WebApp` 再加一列显示 `spec.port`，写出 CRD 里对应的片段。
4. **RBAC 实验**：把 `Role` 里 `deployments` 的一条 `list` 去掉，重启控制器后预测并观察会发生什么。
5. **级联方向**：删掉被管的 `Deployment`，`WebApp` 会消失吗？删掉 `WebApp` 呢？分别说明机制。
6. **幂等**：解释为什么控制器"每次调谐都无条件 `Update`"是坏实践，并给出改进方法。
7. **finalizer**：举一个**必须**用 finalizer 的场景，并说明不加会有什么后果。

<details>
<summary>参考答案</summary>

1. 是 `1`。CRD schema 里 `replicas` 声明了 `default: 1`；默认值在**校验之前**应用，所以不写也会被补成 1。
2. `0` 合法（`minimum: 0`），控制器会把 Deployment 缩到 0 副本（无 Pod）；`11` 非法，
   API Server 直接拒绝：`spec.replicas in body should be less than or equal to 10`。范围由 `minimum/maximum` 决定。
3. 在 `additionalPrinterColumns` 里加：

   ```yaml
   - name: Port
     type: integer
     jsonPath: .spec.port
   ```
   然后 `kubectl apply` 更新 CRD（printer columns 属于 CRD 定义，改动无需重建 CR）。
4. 控制器启动后日志会出现类似 `cannot list resource "deployments" ... at the cluster scope`
   （`list` 是 informer 建 cache 必需的），**调谐停止/报错**。这印证第 9.1 节：informer 需要 `list`/`watch`，
   少任何一项都会失败。
5. 删 `Deployment` **不会**删 `WebApp`（没有反向 owner 关系），反而会触发自愈把 Deployment 重建；
   删 `WebApp` 会**级联**删掉 Deployment（`ownerReference` + GC），但不会删 Pod 之外的东西（Pod 由 Deployment 自己管）。
6. 无条件 `Update` 会推高 `resourceVersion`、触发更多 watch 事件，可能形成"写→事件→再写"的**热循环**，
   还可能在并发下频繁产生冲突。改进：**读取后比较**，只在关键字段（如 `replicas`/`image`）不一致时才 `Update`（本章的 `drifted()`）。
7. 例如控制器在云厂商创建了负载均衡器（集群外资源），删除 CR 时需要调用云 API 回收。
   不加 finalizer 的话，CR 一删对象就没了，**外部资源会泄漏**（云上留下孤儿负载均衡）。
   加了 finalizer 但在 `Reconcile` 里忘了在清理完后移除它，则对象会卡在 `Terminating`。

</details>

---

## 附录：本章真实采集片段与清理

**采集环境**：k3s `v1.30.2+k3s2`，节点 `k3s-demo-server-1`（192.168.56.10）与
`k3s-demo-agent-1`（192.168.56.20）；集群已有 132 个 CRD（Rancher/cert-manager/Fleet/Gateway API 等）。
`controller-runtime v0.18.4`，Go 静态二进制，镜像 `webapp-operator:v0.1.0`（约 40MB）导入到 agent-1 的 containerd。

**1. CRD 注册**：`webapps.demo.example.com`（group `demo.example.com`，Namespaced，shortName `wa`），
`Established` 通过；`kubectl explain webapp.spec` 能展开字段。

**2. 校验**：不写 `replicas` → 默认 `1`；`replicas: 99` → 拒绝；缺 `image` → `Required value`。

**3. 控制器**：Pod 运行于 `k3s-demo-agent-1`（`nodeSelector`），启动日志无 `forbidden`/`x509`；
worker 正常启动。

**4. 自愈实测**：

```text
创建 CR(replicas=2) → Deployment 2/2，status.readyReplicas=2，Available=True
删除 Deployment      → 约 10s 内自动重建（日志 creating deployment）
patch replicas=3     → Deployment spec.replicas=3，status.readyReplicas=3，generation 2/2
删除 WebApp CR       → Deployment 与 Pod 级联删除（NotFound / No resources found）
间隔 20s 观察        → resourceVersion 不变（幂等，无无谓写入）
```

**本章创建的资源：**

- CRD：`webapps.demo.example.com`
- 命名空间 `operator-demo`：Deployment `webapp-operator`（控制器）、ServiceAccount/Role/RoleBinding `webapp-operator`
- 命名空间 `operator-demo`：WebApp `demo-webapp` 及其被管 Deployment `demo-webapp`

**清理（如不需要保留）：**

```bash
# 先删 CR（会级联删掉被管 Deployment 与 Pod）
kubectl --kubeconfig ./kubeconfig -n operator-demo delete webapp demo-webapp

# 再删控制器与命名空间
kubectl --kubeconfig ./kubeconfig delete namespace operator-demo

# 最后删 CRD（注意：删 CRD 会连同其下所有 CR 一起删除）
kubectl --kubeconfig ./kubeconfig delete crd webapps.demo.example.com

# 可选：清理节点上导入的镜像（vagrant 命令在仓库根目录 ~/k3s-ops 执行）
vagrant ssh k3s-demo-agent-1 -c "sudo k3s ctr images rm docker.io/library/webapp-operator:v0.1.0"
```

**本章涉及文件清单（`~/k3s-ops/examples/webapp-operator/`）：**

```text
api/v1/groupversion_info.go           # GVK 注册
api/v1/webapp_types.go                # spec/status 类型 + kubebuilder 标记
api/v1/zz_generated.deepcopy.go       # controller-gen 生成
internal/controller/webapp_controller.go  # 调谐逻辑
main.go                               # manager 装配（含命名空间级缓存）
Dockerfile                            # scratch + CA 证书 + nonroot
config/crd/webapp.yaml                # 手写 CRD（教学主角）
config/crd/generated/webapp.generated.yaml  # controller-gen 产物（对比）
config/rbac/{serviceaccount,role,rolebinding}.yaml
config/manager/deployment.yaml        # 控制器自身 Deployment
config/samples/demo-webapp.yaml       # 演示 CR
README.md                             # 复现步骤
```
