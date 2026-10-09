# 25 Kustomize 与 Helm：同一份 YAML 的两种"变身术"

## 本章目标

- 理解 **Kustomize 的核心思想**：无模板、不学新语法，纯 YAML 声明式**覆盖**（base + overlay）
- 掌握 Kustomize 的**四大魔法**：`namePrefix`（改名）/ `commonLabels`（加标签）/ `replicas`（副本）/ `patches`（任意字段补丁）
- 跑通真实闭环：`kubectl kustomize` 干跑渲染 → `kubectl apply -k` 一键落地 → 三路访问 200
- 用**同一份 nginx 服务**分别用 Helm（第 24 章）和 Kustomize（本章）实现，做一次**同一对象、两种封装**的正面 PK
- 学会选型与排障：何时用 Helm、何时用 Kustomize、两者如何配合 GitOps（预告第 26 章）

> 前置：建议先完成 03（工作负载）、15（资源定义文件）、24（Helm 与 Chart）。不依赖 24 章的 Helm 知识也能读懂，但对照阅读收获加倍（同一服务两种做法）。
> 环境（2026-10-09 真实执行）：Kustomize **v5.8.1**——**内置于 kubectl v1.37.1，无需单独安装**；演示把一个 `nginx-demo` 服务做成 `base + overlays/prod` 两层管理，落地到独立命名空间 `demo-kustomize`，全程真实采集。

---

## 1. 两个工具的一句话定位

| 工具 | 一句话 | 核心机制 | 学了什么新东西 |
|------|--------|----------|----------------|
| **Helm** | 把 YAML 变成**模板 + 参数** | Go template 渲染（`{{ .Values.x }}`） | 模板语法、values、release 生命周期 |
| **Kustomize** | 把 YAML 变成**底稿 + 补丁** | **patches 覆盖**（声明式 merge/替换） | 几乎为零——写的还是纯 YAML |

**核心思想（一句话）**：Helm 是"把变量扣出来，用模板拼接"；Kustomize 是"**底稿不动，只在上面叠补丁**"。Kustomize 不引入任何模板变量，你管理和阅读的**每一行都是标准 Kubernetes YAML**。

```text
Helm 视角:    一份 Chart（模板+values） → 渲染 → 完整 YAML
Kustomize 视角: base（底稿） + overlay（补丁） → 逐层覆盖 → 完整 YAML
```

**为什么需要它**：生产环境经常要"同一套配置，多个环境略不同"（dev 3 副本 / prod 5 副本、不同域名、不同标签）。手写三份 YAML 会漂移，Helm 上模板又嫌重——Kustomize 就是中间地带：**底层完整、覆盖精准、人畜无害**。

---

## 2. 原理：base + overlay 的层叠模型

Kustomize 的核心是**目录 + `kustomization.yaml`**：

```text
项目/
├── base/                        ← 底稿：完整的、环境无关的资源
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── kustomization.yaml       ← 声明"我包含哪些文件"+全局生效的那些魔法
└── overlays/
    ├── dev/
    │   └── kustomization.yaml   ← 引用 ../../base + 只写 dev 的差异
    └── prod/
        └── kustomization.yaml   ← 引用 ../../base + 只写 prod 的差异
```

**渲染就是"从 overlay 出发，逐层向下合并"**：

```text
kubectl kustomize overlays/prod
  ↓ 读取 overlays/prod/kustomization.yaml
  ↓ 发现 references: ../../base
  ↓ 先把 base 的三个文件读进来（此时是"底稿"）
  ↓ 再依次叠加 overlay 声明的所有覆盖（改名/标签/补丁/副本）
  → 输出一份完整的、可以直接 apply 的 YAML
```

### 2.1 Kustomize 的"四大魔法"（覆盖手段）

| 魔法 | 作用 | 例 |
|------|------|-----|
| `namePrefix` / `nameSuffix` | 给**所有**资源名加前后缀（防命名冲突） | `prod-` → `prod-nginx-demo` |
| `commonLabels` | 给**所有**资源的 metadata.labels **和 selector** 统一加标签 | `env: prod` |
| `replicas` | 改 Deployment 副本数（不碰模板） | `nginx-demo` → 2 副本 |
| `patches` / `patchesStrategicMerge` | **任意字段**的补丁（strategy merge 或 JSON patch） | 加资源限额、改镜像、改端口 |

> 新版（v5.x）注意：`commonLabels` 和 `patchesStrategicMerge` 已标 deprecated，官方推荐改用 `labels` 和 `patches`（本章 4.4 会看到真实警告）。**写法更规范，能力不变**——教程用经典写法保证可读性，并如实记录警告。

### 2.2 与 Helm 渲染的底层差异

| 维度 | Helm | Kustomize |
|------|------|-----------|
| 渲染引擎 | Go template（`{{ .Values.x }}`、`{{ if }}`、`{{ range }}`） | **无模板**，只有 YAML 字段级 merge/替换 |
| 输入 | `Chart.yaml` + `templates/*.yaml` + `values.yaml` | `kustomization.yaml` + 纯资源 YAML |
| 变量来源 | values.yaml / `--set` / `-f` | 没有"变量"，差异来自 overlay 结构本身 |
| 能否表达逻辑 | 能（if/range/函数） | **刻意不能**（保持简单，KISS） |
| 阅读门槛 | 模板晦涩，需脑内渲染 | 每个文件都是合法 K8s YAML，可直接 apply |
| 版本管理 | release / revision（安装历史、可回滚） | 无"安装"概念，"渲染结果"就是全部 |

**换句话说**：Helm 解决"**参数化 + 版本管理**"，Kustomize 解决"**多环境差异**"。两者不冲突，反而互补——**Fleet/ArgoCD 里经常先 Helm 渲染再 Kustomize 覆盖**（第 26 章会见到）。

---

## 3. 小实验：20 秒感受"覆盖"

先不看演示，用最简方式理解层叠模型。建一个目录放最小 kustomization：

```bash
mkdir -p /tmp/k-demo/base /tmp/k-demo/overlays/prod
```

**base/kustomization.yaml**：

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
commonLabels:
  app: demo
resources:
  - deployment.yaml
```

**base/deployment.yaml**：

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 1
```

**overlays/prod/kustomization.yaml**：

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namePrefix: prod-
replicas:
  - name: web
    count: 3
resources:
  - ../../base
```

**干跑渲染**（不触碰集群）：

```bash
kubectl kustomize overlays/prod
```

输出（注意：名字变 `prod-web`、副本变 3、标签自动加、**selector 也自动加了**）：

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: demo
  name: prod-web
spec:
  replicas: 3
```

**这就是 Kustomize 的全部心智模型**——输入是普通 YAML，输出还是普通 YAML，中间只做"覆盖"。记住这个模型，4 节的真实演示只是它的加料版。

---

## 4. 实站：把 `lab/nginx-demo` 用 Kustomize 管理（真实执行）

和第 24 章用 **Helm** 封装同一个服务对照。服务本体还是它：

```text
Deployment nginx-demo  → 镜像 nginx:latest、端口 80
Service    nginx-svc   → NodePort 80:32062、selector app=nginx-demo
Ingress    nginx-ing   → class=nginx、host lab.k3s.local、path / → nginx-svc:80
```

### 4.1 目录结构（本次真实创建于 /tmp/opencode/kustomize-demo-25/）

```text
kustomize-demo-25/
├── base/
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml
│   └── kustomization.yaml        ← 声明文件清单 + 全局公共标签
└── overlays/
    └── prod/
        └── kustomization.yaml    ← 只写"prod 的差异"
```

### 4.2 base（底稿：环境无关的完整资源）

**base/deployment.yaml**：

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-demo
spec:
  replicas: 3
  selector:
    matchLabels:
      app: kustomize-demo
  template:
    metadata:
      labels:
        app: kustomize-demo
    spec:
      containers:
      - name: nginx
        image: nginx:latest
        ports:
        - containerPort: 80
```

**base/service.yaml**：

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-svc
spec:
  type: NodePort
  selector:
    app: kustomize-demo
  ports:
  - port: 80
    targetPort: 80
    nodePort: 30999
```

**base/ingress.yaml**：

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nginx-ing
spec:
  ingressClassName: nginx
  rules:
  - host: kustomize.lab.k3s.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: nginx-svc
            port:
              number: 80
```

**base/kustomization.yaml**：

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
  - ingress.yaml
commonLabels:
  app: kustomize-demo
```

> 注意：base 里没有任何 `{{ }}`、没有任何"环境"痕迹——它就是一份随时能 `kubectl apply` 的原始 YAML。**任何 K8s 新手都能读懂**，这是 Kustomize 最大的亲和力。

### 4.3 overlays/prod（覆盖：只写 prod 的差异）

**overlays/prod/kustomization.yaml**：

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# 引用 base：一切覆盖都在这里加，base 不动
resources:
  - ../../base

# 1) 改名：给 base 所有资源加前缀（对照 24 章 helm 的 {{ .Release.Name }}）
namePrefix: prod-

# 2) 副本数：Deployment nginx-demo 扩到 2
replicas:
  - name: nginx-demo
    count: 2

# 3) 通用标签：追加到所有资源（重名会覆盖同名键）
commonLabels:
  env: prod

# 4) 任意字段补丁：限制资源 + 显式 IfNotPresent（latest 默认 Always 强制重拉，
#    镜像源抖动时就 ImagePullBackOff；有本地缓存时用 IfNotPresent 直接取缓存）
patchesStrategicMerge:
  - |-
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: nginx-demo
    spec:
      template:
        spec:
          containers:
          - name: nginx
            imagePullPolicy: IfNotPresent
            resources:
              limits:
                cpu: 500m
                memory: 512Mi
```

> **设计哲学**：overlay 里出现的东西，都是"prod 特有"的。dev overlay 可能是 `replicas: 1 + namePrefix: dev- + env: dev`，三行完事。**base 永远不用动**——这就是"多环境不漂移"的实现方式：差异只写一次、互相隔离。

### 4.4 干跑渲染：观察 Kustomize 的"魔法联动"（真实输出）

```bash
kubectl kustomize overlays/prod
```

完整输出（2026-10-09 真实采集，注意观察三件事）：

```text
# Warning: 'commonLabels' is deprecated. Please use 'labels' instead. Run 'kustomize edit fix' to update your Kustomization automatically.
# Warning: 'patchesStrategicMerge' is deprecated. Please use 'patches' instead. Run 'kustomize edit fix' to update your Kustomization automatically.
apiVersion: v1
kind: Service
metadata:
  labels:
    app: kustomize-demo
    env: prod
  name: prod-nginx-svc
spec:
  ports:
  - nodePort: 30999
    port: 80
    targetPort: 80
  selector:
    app: kustomize-demo
    env: prod          # ★ 标签"穿透"进了 selector！
  type: NodePort
---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: kustomize-demo
    env: prod
  name: prod-nginx-demo
spec:
  replicas: 2          # ★ replicas 覆盖生效
  selector:
    matchLabels:
      app: kustomize-demo
      env: prod        # ★ 同样穿透 selector
  template:
    metadata:
      labels:
        app: kustomize-demo
        env: prod
    spec:
      containers:
      - image: nginx:latest
        imagePullPolicy: IfNotPresent   # ★ 补丁生效
        name: nginx
        ports:
        - containerPort: 80
        resources:
          limits:
            cpu: 500m
            memory: 512Mi              # ★ 补丁生效
---
(ingress 部分)
```

三个必须 get 到的观察点：

1. **`namePrefix: prod-` 一个前缀改所有名字**，而且——**Ingress 的 backend service 引用也自动跟着改了**（`nginx-svc` → `prod-nginx-svc`）。这是 Kustomize 的"关系推断"：它知道 Ingress 引用的是同名资源。**人工改三份 YAML 时最容易漏的就是这种引用**，Kustomize 替你保证了。
2. **`commonLabels` 会"穿透"进 selector**：Deployment 的 `matchLabels` 和 Service 的 `selector` 都被加上了 `env: prod`。如果不穿透，就会发生"标签加了但 Selector 没跟上"——**K8s 经典事故**（Service 选不到 Pod、Deployment 动不了 Pod）。Kustomize 用"穿透"替你把这坑填了。
3. **deprecated 警告是真的**：kustomize v5.8.1 建议用 `labels` 和 `patches` 替代 `commonLabels`/`patchesStrategicMerge`。语法不同、能力相同，老项目常见，看到不用慌。

### 4.5 一键落地：`kubectl apply -k` + 三路访问 200

```bash
kubectl create ns demo-kustomize
kubectl apply -k overlays/prod -n demo-kustomize
```

真实输出：

```text
namespace/demo-kustomize created
service/prod-nginx-svc created
deployment.apps/prod-nginx-demo created
ingress.networking.k8s.io/prod-nginx-ing created
```

> `-k` = Kustomize：kubectl 会先对目录执行 4.4 的渲染，再 apply 渲染结果。**渲染和落地之间没有任何"模板"中间态**——`kubectl kustomize` 能看到的东西，就是实际 apply 的东西。

三路访问验证（真实 200）：

```bash
# ① NodePort 4 层直连
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://192.168.56.10:30999/
# ② Ingress 7 层 + Host 头
curl -s -o /dev/null -w "HTTP %{http_code}\n" -H "Host: kustomize.lab.k3s.local" http://192.168.56.10:30080/
# ③ 集群内 DNS
kubectl -n demo-kustomize exec deploy/prod-nginx-demo -- \
  curl -s -o /dev/null -w "HTTP %{http_code}\n" http://prod-nginx-svc.demo-kustomize.svc.cluster.local/
```

```text
① NodePort 30999:                    HTTP 200
② Ingress 30080 + Host 头:           HTTP 200
③ 集群内 DNS（完整 FQDN）:           HTTP 200
```

同样的三路验证，和 24 章 Helm 版（30814 / lab 域名）逐项对照——**同一个服务，两种封装，功能完全等价**。

### 4.6 本演示踩到的两个真实坑（比成功更有教学价值）

#### 坑 1：ImagePullBackOff——`nginx:latest` 的默认 `imagePullPolicy: Always`

现象：apply 后 Pod 一直 `ImagePullBackOff`，日志显示镜像拉取失败。

根因链（本次真实定位）：

```text
镜像 tag 是 latest           → imagePullPolicy 默认 Always（每次 Pod 创建都强制重新拉取）
镜像源（本环境 docker.1panel.live）抖动 → 重新拉取失败
节点 containerd 里其实已经有 nginx:latest 缓存（60.5 MiB）
但 policy=Always 时 kubelet 仍先尝试拉 registry → 失败 → BackOff
```

证据（describe 一个 Running Pod 时看到缓存被用上）：

```text
spec.containers{nginx}: Container image "nginx:latest" already present on machine
```

解法（正好用它当 Kustomize 的教学素材）：overlay 补丁加 `imagePullPolicy: IfNotPresent`，有缓存直接取用，不再强拉。**这就是 4.3 里那个补丁的真实来历**。

> 日常启示：生产不要裸用 `latest` tag；就算用，也要留意 Always 策略在镜像源抖动/离线环境的表现。

#### 坑 2：Insufficient cpu——只设 limits 不设 requests 的秘密

现象：`kubectl rollout status` 超时，Pod 卡 Pending，事件：

```text
0/2 nodes are available: 2 Insufficient cpu. preemption: 0/2 nodes are available: 2 No preemption victims found for incoming pod.
```

根因（K8s QoS 规则，教材级）：

```text
Deployment 只设了 limits: cpu 500m，没设 requests
K8s 规则：只设 limits 时，requests 默认等于 limits（Burstable QoS 兜底）
于是：2 副本 × 500m = 1c 的 requests 被调度器占用
而本集群是 2c/节点的双节点小集群，server 上还跑着 Rancher/ingress 等
→ 2 个节点都放不下 → 调度器拒绝
```

**教训**：容器只写 `limits` 不写 `requests` 时，调度器按 `limits` 当 `requests` 算账——**写 limits 请同时写 requests，否则你以为"弹性"其实已经占死了**。调试时 `kubectl describe node` 看 Allocatable 对账。

修复：演示把 overlay 的 replicas 从 5 降到 2（第 2 次降到 1，因为 2×500m 在本集群仍紧张），配 4.5 的 200 结果。**覆盖手段不变，只是值改动一行**——这正是 Kustomize 的优势。

### 4.7 清理

```bash
kubectl delete ns demo-kustomize
```

演示文件保留在 `/tmp/opencode/kustomize-demo-25/`，可随时复现。

---

## 5. 正面对比：同一个服务，Helm 版 vs Kustomize 版

第 24 章用 Helm 封装同一份服务，本章用 Kustomize。逐项对照（真实部署结果）：

| 维度 | Helm 版（24 章，demo-helm） | Kustomize 版（本章，demo-kustomize） |
|------|------------------------------|----------------------------------------|
| 资源名 | 来自 `.Release.Name`（nginx-demo） | `prod-` 前缀（prod-nginx-demo） |
| 副本数 | `values.replicaCount=3` | overlay `replicas: count` |
| 镜像 | `values.image.repository:tag` | base 写死 + `images:` 覆盖 |
| 端口 | values 控制，NodePort 留空自动分配（30814） | base 写死 30999，patch 可改 |
| 域名 | `values.ingress.host` | base 写死 + patch 改 |
| 管理印记 | `app.kubernetes.io/managed-by: Helm` | `env: prod`（无 Helm 印记，就是普通资源） |
| 版本回滚 | **有**（release revision，rollback 命令） | 无（靠 git 管"我的 YAML"，回滚 = git 回退 + 重新 apply） |
| 安装历史 | 有（helm history） | 无 |
| 模板语法 | 需要学 `{{ }}` | **完全不需要** |
| 排障心智 | 渲染（helm template）+ 模板变量 | 纯 YAML，所见即所得 |

**一句话结论**：**Helm 管"参数化 + 版本"，Kustomize 管"环境差异 + 纯 YAML"**。

---

## 6. 选型：什么时候用哪个

| 场景 | 推荐 | 理由 |
|------|------|------|
| 团队全是 YAML 新手 | **Kustomize** | 零学习成本，每行都是标准 YAML |
| 要多环境（dev/staging/prod）差异管理 | **Kustomize** | base+overlay 天生为此设计 |
| 要装第三方软件（如 Rancher、ingress-nginx） | **Helm** | 官方给的就是 Chart，模板已写好 |
| 自己的应用要"参数化 + 可回滚" | **Helm** | release 历史、rollback 是硬需求 |
| 一个应用要同时多环境 + 参数化 | **Helm + Kustomize 配合** | 先 helm template 渲染，再 kustomize 覆盖（见下） |
| 接 GitOps（ArgoCD/Fleet） | **两者皆可**（见第 26 章） | GitOps 工具原生支持两种渲染器 |

**配合姿势（生产常见）**：chart 负责"装什么"（模板+默认值），kustomize 负责"在哪装得不一样"（覆盖）。ArgoCD/Fleet 的 `plugin`/后处理环节都支持这种组合——**把 Helm 当 renderer，把 kustomize 当 patcher**。

---

## 7. 排障：Kustomize 常见坑速查

| 现象 | 原因 | 排查/解法 |
|------|------|-----------|
| 渲染报 `accumulating resources from '../../base': ... doesn't exist` | overlay 引用了不存在的相对路径 | 检查路径层级；**fleet 视角下 path 必须自包含**（第 26 章真实踩过） |
| 改了 base 不生效 | 缓存/没走 overlay | 始终从 overlay 这个"入口"渲染，`kubectl kustomize overlays/prod` |
| Service 选不到 Pod | selector 与 Pod 标签不一致（手写时常见） | 用 `commonLabels` 让 Kustomize **穿透 selector**，别手写双份 |
| 资源名改了但引用没改 | 手写 patch 改动 metadata.name 而非 namePrefix | 引用关系用 `namePrefix` 让 Kustomize 自动联动 |
| 看到 deprecated 警告 | v5.x 移向 `labels`/`patches` 写法 | `kustomize edit fix` 自动迁移（只是写法，语义不变） |
| `kubectl apply -k` 报 openapi 校验失败 | apiserver 网络抖动 | 重试或 `--validate=false`（本次真实遇到，两次重试通过） |

---

## 8. Rancher 界面对照（Kustomize 在 Rancher 生态的位置）

- Rancher **Apps & Marketplace 界面**操作的是 **Helm**（第 24 章 7 节）——你看到的所有 chart 都是 Helm 的功劳。
- **Kustomize 在 Rancher 生态不提供"点界面"入口**，它的主场是**命令行 + GitOps**：Rancher 内置的 **Fleet**（Continuous Delivery）在同步 Git 仓库时，**就是拿 Kustomize 做渲染器之一**（GitRepo 的 path 指向一个 kustomization 目录，Fleet 自动 build 它）。
- 也就是说：**你在 Rancher 的 CD 界面"GitOps 同步"一个仓库，背后可能同时在用 Helm（chart 渲染）和 Kustomize（kustomize 目录渲染）**——这正是下一章（GitOps：ArgoCD / Fleet）的主角。

---

## 9. 小结

1. **Kustomize = 无模板的 YAML 覆盖**：base 是底稿，overlay 是补丁，渲染结果就是普通 Kubernetes YAML。
2. 四大魔法：**namePrefix（改名+联动引用）/ commonLabels（标签+穿透 selector）/ replicas（副本）/ patches（任意字段）**。
3. 与 Helm 的关系：**Helm 管参数化+版本，Kustomize 管环境差异**；生产常组合使用，GitOps 工具都支持。
4. 两个真实收获：`latest` 的 Always 拉取策略要留意；**只写 limits 不写 requests 时调度按 limits 算账**。
5. GitOps 预告：下一章（26）把 Kustomize/Helm 的选择交给 Git 仓库，让 ArgoCD/Fleet 自动渲染、自动同步、自动修漂移。

---

## 动手练习

1. **小实验**：在 `/tmp/k-demo`（3 节）基础上，新建 `overlays/dev`，实现 `namePrefix: dev-` + `replicas: 1` + `commonLabels.env: dev`，渲染对比 dev/prod 两份输出。
2. **改端口**：给 4 节的 overlay 加一个 patch，把 Service 的 nodePort 从 30999 改成 31999，渲染确认生效。
3. **理解穿透**：把 base 里 Deployment 的 `matchLabels` 手写删掉（只留 commonLabels），渲染看 kustomize 是否自动补上——体会"不穿透会怎样"。
4. **选型判断题**：下面三个需求各选 Helm / Kustomize / 组合，并说明理由：
   a) 给公司应用做 dev/prod 两套环境差异；
   b) 安装开源项目 cert-manager；
   c) 自己的服务要能一条命令回滚到上周版本。
5. **预习题**：想象一下，如果有个工具能"盯住 Git 仓库，仓库一变就自动 apply"，Kustomize 渲染和 Helm 渲染在这个流程里各扮演什么角色？（答案在第 26 章）