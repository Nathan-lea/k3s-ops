# 27 GitOps 多服务与多环境：仓库该怎么组织

## 本章目标

- 分清**两类仓库**：业务源码仓库 vs 部署配置仓库（GitOps 管的是后者）
- 用**三个决策问题**（几个仓库 / 环境怎么分 / 同步单元多大）推导出合理结构
- 掌握三种主流结构：**单仓服务优先（A）/ app-platform-clusters 三层（B）/ 多仓团队自治（C）**
- 理解为什么 GitOps 用**目录**而不是**分支**划分环境
- 真实跑通**多服务组织**两条路线：一个 GitRepo 管多服务（多 paths） vs 每服务一个 GitRepo（真实 Fleet 输出）
- 掌握多服务下的**配置复用**（避开第 26 章的 path 自包含约束）、命名/标签/Namespace 约定、反模式清单

> 前置：本章是**第 26 章（GitOps：Fleet / ArgoCD）的直接延伸**——26 章演示的是"一个服务"的仓库结构，本章解决"几十个服务"的组织问题。建议先完成 15（资源定义）、24（Helm）、25（Kustomize）、26（GitOps）。
> 环境（2026-10-09 真实执行）：本集群 Fleet 实测，搭一个含 `order-service` / `payment-service` 的多服务仓库 `gitops-demo`，分别用「单 GitRepo 多 paths」与「每服务独立 GitRepo」两种方式接入，采集真实输出后清理。

---

## 1. 先分清两类仓库（别混为一谈）

| 仓库 | 放什么 | 谁维护 | 变更频率 |
|------|--------|--------|----------|
| **业务源码仓库** | 代码 + Dockerfile，CI 构建镜像 | 开发 | 高（每天几十次） |
| **部署配置仓库**（GitOps 仓库） | K8s 清单 / Kustomize / Helm values | 运维/SRE | 低（每次发布） |

**关键**：Fleet/ArgoCD 盯的是**部署配置仓库**。源码仓库只在 CI 里产出镜像 tag（如 `registry/order-service:1.2.3`），配置仓库再把这个 tag 写进清单——**"构建"和"部署"解耦**，这正是 GitOps 能把"改集群"变成"改 Git"的前提。

第 26 章的 gitea `fleet-demo` 仓库是"部署配置仓库"的单服务雏形；本章讨论它装了**很多服务**时怎么摆。

---

## 2. 三个决策问题（先想清楚，再动手摆目录）

看到"多服务怎么组织"，很多人的第一反应是"目录怎么分"。但目录只是表象，先回答这三个问题：

| # | 决策 | 选项 | 推荐 |
|---|------|------|------|
| ① | **几个仓库？** | 单仓（monorepo）/ 多仓（polyrepo）/ 混合 | 中小团队**单仓**；多团队**每团队一仓** |
| ② | **环境怎么分？** | 目录 / 分支 / 独立仓库 | **目录**（GitOps 首选，见第 5 节） |
| ③ | **同步单元多大？** | 一个 GitRepo 管全部 / 每服务一个 / 每环境一个 | **每服务一个 GitRepo**（独立生命周期） |

这三个维度**正交**——可以"单仓 + 目录分环境 + 每服务一个 GitRepo"，也可以"多仓 + 目录分环境 + 每环境一个 GitRepo"。第 6 节用真实集群演示③的两种粒度。

---

## 3. 推荐结构 A：单仓库 + 服务优先

把第 26 章那个服务目录，扩展成 `apps/` 下**一群结构完全一致的同级目录**：

```text
gitops-repo/
├── apps/                                  # 业务应用（一服务一目录）
│   ├── order-service/
│   │   ├── base/                          # 通用清单（底稿）
│   │   │   ├── deployment.yaml
│   │   │   ├── service.yaml
│   │   │   └── kustomization.yaml
│   │   └── overlays/
│   │       ├── dev/
│   │       │   ├── deployment.yaml        # 自包含（见第 7 节）
│   │       │   ├── service.yaml
│   │       │   └── kustomization.yaml
│   │       └── prod/
│   │           ├── deployment.yaml
│   │           ├── service.yaml
│   │           └── kustomization.yaml
│   ├── payment-service/
│   │   └── overlays/{dev,prod}/           # 与 order-service 同构
│   └── user-service/
│       └── overlays/{dev,prod}/
│
└── platform/                              # 集群级共享组件
    ├── ingress-nginx/
    ├── cert-manager/
    └── monitoring/
```

**为什么是"服务优先"（先按服务、服务内部再分环境）而不是"环境优先"（先按环境、环境内部再分服务）？**

| 组织方式 | 结构 | 适合 | 代价 |
|----------|------|------|------|
| **服务优先**（推荐） | `apps/<svc>/overlays/<env>/` | 每服务独立演进 | 环境全景要横向跨目录看 |
| 环境优先 | `<env>/<svc>/` | 一整个环境一起发布 | 服务跨环境复用难 |

**服务优先的好处**：一个服务的所有环境集中在同一目录下，**改一个服务只碰一个目录**（PR 清晰、git blame 清晰、可独立 OWNERS 授权）。这也是 Fleet/ArgoCD 最常见的组织方式。

---

## 4. 进阶结构 B / C：按规模升级

### 4.1 结构 B：app / platform / clusters 三层（规模大时）

服务一多，"业务"和"平台"混在一起会很乱，再拆一层：

```text
gitops-repo/
├── apps/                     # 业务服务（可按团队/域再分子目录）
│   ├── team-order/
│   │   ├── order-service/
│   │   └── payment-service/
│   └── team-user/
│       └── user-service/
├── platform/                 # 所有集群都要装的组件
│   ├── ingress-nginx/
│   ├── cert-manager/
│   └── monitoring/
└── clusters/                 # 多集群时：各集群的差异配置
    ├── prod-east/
    │   └── cluster-values.yaml
    └── prod-west/
        └── cluster-values.yaml
```

三层各自的**变更频率与审批人完全不同**：

| 层 | 内容 | 变更频率 | 审批 |
|----|------|----------|------|
| `apps/` | 业务清单 | 每次发布 | 服务负责人 |
| `platform/` | ingress/cert-manager/监控 | 偶尔 | SRE |
| `clusters/` | 集群拓扑/差异 | 很少 | 平台团队 |

### 4.2 结构 C：多仓库（团队自治）

团队边界清晰时，**每团队一个部署仓库**，各自接入一个 GitRepo：

```text
team-order-deploy/   → GitRepo: team-order      （order / payment）
team-user-deploy/    → GitRepo: team-user       （user / gateway）
platform-deploy/     → GitRepo: platform        （ingress / cert-manager / monitoring）
```

| 维度 | 单仓库（A/B） | 多仓库（C） |
|------|--------------|-------------|
| 权限 | 粗（同一仓库） | **细（每团队独立）** |
| 跨服务变更 | **一次 PR 原子完成** | 需开 N 个 PR |
| 共享配置复用 | 容易（同仓引用） | 难（需 chart / remote base） |
| 变更爆炸半径 | 大 | 小 |
| 适合 | 中小团队、强一致 | 大组织、团队自治 |

---

## 5. 环境划分：目录 vs 分支 vs 独立仓库

| 方式 | 例子 | 评价 |
|------|------|------|
| **目录**（推荐） | `overlays/{dev,staging,prod}/` | ✅ GitOps 首选：环境差异可 diff、一次 PR 全见 |
| 分支 | `main`=dev，`release/prod`=prod | ⚠️ cherry-pick / merge 会产生**漂移**，环境无法干净对比 |
| 独立仓库 | `app-dev` / `app-prod` | 隔离最强，但维护成本高 |

**GitOps 的共识：用目录，不用分支。** 因为 GitOps 的核心价值是"**可 diff、可审计**"——分支模型下 dev 和 prod 是两棵不同的历史树，差异只能靠脑补；目录模型下同一份 base，overlay 的差异一眼可见。**环境晋级 = 改一个 overlay 目录 + 提 PR**，而不是 merge 分支（merge 会把 dev 的历史混进 prod，产生隐性漂移）。

---

## 6. 实站：多服务组织两条路线（Fleet 真实执行）

理论讲完，用本集群 Fleet 实测。先搭一个含两个服务的部署仓库（结构 A 的简化版，只留 prod）：

### 6.1 多服务仓库结构（真实创建）

```text
gitops-demo/
└── apps/
    ├── order-service/
    │   └── overlays/prod/
    │       ├── deployment.yaml
    │       ├── service.yaml
    │       └── kustomization.yaml
    └── payment-service/
        └── overlays/prod/
            ├── deployment.yaml
            ├── service.yaml
            └── kustomization.yaml
```

每个 `overlays/prod/` 都是**自包含**的（复习第 26 章的 path 约束）。以 order-service 为例：

**`apps/order-service/overlays/prod/deployment.yaml`**：

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-service
spec:
  replicas: 1
  selector:
    matchLabels:
      app: order-service
  template:
    metadata:
      labels:
        app: order-service
    spec:
      containers:
      - name: app
        image: nginx:latest
        imagePullPolicy: IfNotPresent       # 复用缓存，避开 latest 的 Always 拉取（第 25 章）
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 128Mi
```

**`apps/order-service/overlays/prod/service.yaml`**：

```yaml
apiVersion: v1
kind: Service
metadata:
  name: order-service
spec:
  selector:
    app: order-service
  ports:
  - port: 80
    targetPort: 80
```

**`apps/order-service/overlays/prod/kustomization.yaml`**：

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
commonLabels:
  app.kubernetes.io/part-of: shop
```

`payment-service/overlays/prod/` 三个文件与上面同构（只把名字换成 payment-service）。

### 6.2 路线 A：一个 GitRepo 管一个环境的多个服务

```yaml
apiVersion: fleet.cattle.io/v1alpha1
kind: GitRepo
metadata:
  name: shop-prod
  namespace: fleet-local
spec:
  repo: http://10.0.2.2:3000/admin/gitops-demo.git
  branch: main
  paths:                                  # ★ 一个 GitRepo 列出多个服务的 path
  - apps/order-service/overlays/prod
  - apps/payment-service/overlays/prod
  targetNamespace: demo-shop              # ★ 所有服务落同一个命名空间
```

应用后等 30 秒，**真实输出**：

```text
NAME        REPO                                         COMMIT                BUNDLEDEPLOYMENTS-READY   STATUS
shop-prod   http://10.0.2.2:3000/admin/gitops-demo.git    d18d654dedd98...      2/2
```

**关键观察：一个 GitRepo 的多个 paths → 生成多个 Bundle（每 path 一个）**：

```text
shop-prod-apps-order-service-overlays-prod       1/1
shop-prod-apps-payment-service-overlays-prod     1/1
```

**命名规则揭示**：`<GitRepo 名>-<path 路径，斜杠换连字符>`。资源全部落地 `demo-shop`：

```text
deployment.apps/order-service     1/1   1   1   26s
deployment.apps/payment-service   1/1   1   1   26s
service/order-service     ClusterIP   10.43.53.173
service/payment-service   ClusterIP   10.43.162.11
```

集群内访问验证 + 管理印记（真实）：

```bash
kubectl -n demo-shop exec deploy/order-service -- curl -s -o /dev/null -w "%{http_code}" http://order-service/
# → 200
kubectl -n demo-shop get deploy order-service -o json | jq '.metadata.labels'
```

```json
{
  "app.kubernetes.io/managed-by": "Helm",
  "app.kubernetes.io/part-of": "shop",
  "objectset.rio.cattle.io/hash": "94d270cdc9b8ab91f68b1823bd558919ea126774"
}
```

### 6.3 路线 B：每个服务一个 GitRepo（独立生命周期）

把上面的 `shop-prod` 删掉，改成**每服务一个 GitRepo、各自独立命名空间**：

```yaml
apiVersion: fleet.cattle.io/v1alpha1
kind: GitRepo
metadata:
  name: order-service
  namespace: fleet-local
spec:
  repo: http://10.0.2.2:3000/admin/gitops-demo.git
  branch: main
  paths:
  - apps/order-service/overlays/prod
  targetNamespace: order          # ★ 独立命名空间
---
apiVersion: fleet.cattle.io/v1alpha1
kind: GitRepo
metadata:
  name: payment-service
  namespace: fleet-local
spec:
  repo: http://10.0.2.2:3000/admin/gitops-demo.git
  branch: main
  paths:
  - apps/payment-service/overlays/prod
  targetNamespace: payment
```

真实输出：

```text
NAME              REPO                                         COMMIT            BUNDLEDEPLOYMENTS-READY   STATUS
order-service     http://10.0.2.2:3000/admin/gitops-demo.git    d18d654dedd98...  1/1
payment-service   http://10.0.2.2:3000/admin/gitops-demo.git    d18d654dedd98...  1/1
```

对应的 Bundle（命名规则同前）：

```text
order-service-apps-order-service-overlays-prod       1/1
payment-service-apps-payment-service-overlays-prod   1/1
```

资源各自落在**独立的命名空间** `order` / `payment`：

```text
# kubectl -n order get deploy,svc          # kubectl -n payment get deploy,svc
deployment.apps/order-service   1/1        deployment.apps/payment-service   1/1
service/order-service   ClusterIP ...      service/payment-service   ClusterIP ...
```

### 6.4 两条路线怎么选

| 维度 | 路线 A：单 GitRepo 多 paths | 路线 B：每服务一个 GitRepo |
|------|----------------------------|----------------------------|
| CR 数量 | 少（1 个） | 多（N 个） |
| 生命周期 | 一起同步（改 Git 全部生效） | **各自独立**（一服务更新不影响他者） |
| 爆炸半径 | 大（一个 path 渲染失败拖累整批） | **小**（只影响该服务） |
| 权限/所有权 | 混在一起 | **可按 GitRepo 分**（配 Rancher 角色） |
| 适合 | 服务一起发布、强一致的小系统 | 多团队、独立发布的成熟系统 |

> **真实经验**：起步可用 A（简单），服务一多（>10 个）或团队一多，就该切 B。第 6.3 的骚操作——**每服务独立命名空间 + 独立 GitRepo**，正是"服务自治"的标准姿势。

### 6.5 清理

删除 GitRepo 即回收全部资源（第 26 章已验证的反向同步）：

```bash
kubectl -n fleet-local delete gitrepo shop-prod order-service payment-service
kubectl delete ns demo-shop order payment
# gitea 仓库一并删除（curl DELETE → 204）
```

---

## 7. 多服务下的配置复用（避开 26 章的 path 约束）

第 26 章踩过的坑（**Fleet 的每个 path 必须自包含**）在多服务下会更突出：几十个服务的 base 如果都靠 `../../base` 跨目录共享，**每个都会报错**。三种解法：

| 解法 | 做法 | 优点 | 缺点 |
|------|------|------|------|
| **复制** | base 文件复制进每个 overlay | 零依赖、最简单（第 26 章用法） | 改 base 要同步多处 |
| **Helm chart** ✅ | 每服务一个 chart，base=模板，overlay=values | **chart 天生自包含**，Fleet/ArgoCD 原生支持 | 需要写 chart |
| **remote base** | `resources: [github.com/org/base//svc?ref=v1]` | 真正复用 | 依赖网络，渲染多一跳 |

**结论**：服务一多，**优先把 Helm chart 作为打包单元**（第 24 章）——chart 的模板都在 chart 目录内，`helm template` 不依赖外部相对路径，天然满足 Fleet 的自包含要求；Kustomize 更适合"少量服务 + 环境差异"的场景。

---

## 8. Namespace 与命名/标签约定

### 8.1 Namespace 策略

| 策略 | 说明 | 适合 |
|------|------|------|
| 每服务一个 ns | 隔离好、RBAC 细、配额独立 | 服务多、多团队（本节 6.3 路线 B） |
| 每团队一个 ns | 资源共享方便、配额按团队 | 团队内服务相互调用频繁 |
| 每环境一个集群 | 物理隔离 | 合规要求高的生产 |

### 8.2 命名约定

- **`目录名 = 应用名 = K8s 资源名`**：`apps/order-service/` ↔ Deployment `order-service`。运维一眼对得上，别用中文/空格/大小写混用。
- Bundle 名是 Fleet 自动拼的（`<GitRepo名>-<path>`），不用手动起。

### 8.3 统一标签（第 13 / 25 章）

每个服务都打上一组标准标签，实现**跨服务批量巡检**：

```yaml
labels:
  app.kubernetes.io/name: order-service          # 应用名
  app.kubernetes.io/instance: order-service-prod # 实例（多环境区分）
  app.kubernetes.io/part-of: shop                # 所属系统（本章演示用）
  app.kubernetes.io/managed-by: Helm             # 或 fleet
```

于是可以一条命令跨服务查：

```bash
kubectl get all -A -l app.kubernetes.io/part-of=shop
```

---

## 9. Rancher 界面对照（Continuous Delivery）

在 Rancher 的 **Continuous Delivery** 页里，本章两条路线的差异**一眼可见**：

- **路线 A（单 GitRepo 多 paths）**：Git Repos 列表里**一行**（`shop-prod`）；点进去能看到它产生的 **2 个 Bundle**（order / payment 各一）。
- **路线 B（每服务一 GitRepo）**：列表里**两行**（`order-service`、`payment-service`），每行可**单独** Force Update / 查看状态 / 授权——这就是"独立生命周期"的界面体现。
- 用 **Cluster Groups** 把 GitRepo 绑定到一组集群，即可实现"一套多服务配置，分发到多个集群"。

---

## 10. 反模式清单（真实踩过的坑）

- ❌ **所有服务塞进 `default` 命名空间**，靠名字区分——RBAC/配额/清理全乱
- ❌ **分支即环境**（第 5 节）——cherry-pick/merge 产生隐性漂移
- ❌ **base 跨目录引用 `../../base`**（第 7 节）——Fleet path 约束下必炸
- ❌ **巨型 GitRepo 全量同步**——一个渲染失败拖累全部服务（用路线 B 拆开）
- ❌ **Secret 明文进 Git**——用 Sealed Secrets / SOPS / External Secrets
- ❌ **目录名与资源名不一致**——运维排查对不上号
- ❌ **dev/prod 混在同一个 kustomization**——差异不可控，改一处影响两环境

---

## 11. 小结

1. **先分清两类仓库**：源码仓库（CI 出镜像）与部署配置仓库（GitOps 管的对象），二者解耦。
2. **三个决策问题**：几个仓库（单/多）/ 环境怎么分（目录！）/ 同步单元多大（每服务一个 GitRepo）。
3. **三种结构**：A 单仓服务优先（入门）、B app-platform-clusters 三层（大规模）、C 多仓团队自治（大组织）。
4. **环境用目录不用分支**——为了可 diff、可审计、晋级靠 PR。
5. **两条路线真实实测**（本集群）：A 一个 GitRepo 多 paths（→ 多 Bundle，一起同步）；B 每服务一个 GitRepo（→ 独立命名空间、独立生命周期）。**Bundle 命名规则** `<GitRepo名>-<path>`。
6. **多服务复用**：优先 Helm chart 做打包单元（自包含），避开 Kustomize 跨目录引用在 Fleet 下的限制。
7. **反模式**要背下来：default 大杂烩、分支即环境、跨目录 base、巨型 GitRepo、明文 Secret。

---

## 动手练习

1. **画结构**：为"3 个服务 × 2 个环境（dev/prod）× 2 个团队"设计一份仓库结构（选结构 A 或 C，说明理由）。
2. **复现路线 A**：建一个含两个服务的仓库，用**一个 GitRepo + 多 paths** 接入 Fleet，验证生成 2 个 Bundle、资源落地同一命名空间。
3. **复现路线 B**：把练习 2 改成**每服务一个 GitRepo + 独立命名空间**，对比 CR 数量与资源落点。
4. **Bundle 命名推演**：若 GitRepo 名叫 `team-a`，path 为 `apps/user/overlays/prod`，Bundle 名应该是什么？（提示：本节 6.2 的命名规则）
5. **决策题**：公司有 30 个服务、5 个团队、3 套环境。你选结构 A/B/C？环境用目录还是分支？同步单元多细？（综合第 2/4/5/6 节作答）
6. **复用题**：30 个服务的 base 都相同，你如何在"满足 Fleet path 自包含"的前提下避免复制 30 份？（提示：第 7 节的 Helm chart 方案）