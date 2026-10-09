# 26 GitOps：让 Git 仓库当"唯一事实来源"（ArgoCD / Fleet）

## 本章目标

- 理解 **GitOps 四原则**：声明式 / Git 唯一事实来源 / 自动同步（pull-based）/ 可观测可回滚
- 看懂 **Fleet（Rancher 内置 GitOps）的完整架构**：GitRepo → fleet-controller → gitjob → Bundle → agent → 集群
- 看懂 **ArgoCD 的对应架构**：Application → repo-server → controller，以及 Sync/Health/Drift 三个核心机制
- 在本集群**真实跑通一个完整 GitOps 闭环**：gitea 建仓库 → GitRepo 接入 → 资源自动落地 → 改 Git 自动同步 → 人为漂移被检测/修复 → 清理
- 学会横向对比：**Fleet vs ArgoCD**（架构 / 漂移修复 / 回滚 / 多集群 / 选型）

> 前置：建议先完成 15（资源定义文件）、24（Helm 与 Chart）、25（Kustomize 与 Helm 对比）。本章的 GitOps 演示会**同时用到 Helm（渲染）+ Kustomize（渲染）**——上一章结尾的"预习题"答案就在这里。
> 环境（2026-10-09 真实执行）：本集群由 Rancher 自带 **Fleet**（fleet-controller 已运行 136 天），**未部署 ArgoCD**——因此 Fleet 走全真实闭环，ArgoCD 做原理级讲解 + 与 Fleet 逐项对照（不动集群，避免引入未经管理的组件）。所有 Fleet 输出均为本集群真实采集。

---

## 1. GitOps：一句话 + 四原则

**GitOps 是什么（一句话）**：把"**集群应该长什么样**"这个事实，**放进 Git 仓库**；有个程序盯着仓库，**仓库一变，它就把集群改成那样**；谁动过集群想改回去，**切回旧 commit 就行**。

对比"传统运维"（push 模式）与 GitOps（pull 模式）：

```text
传统 push 模式:   人 → kubectl/helm 命令 → 集群        （状态在人的脑子里/终端历史里）
GitOps pull 模式:  Git 仓库（唯一事实） → 同步器盯梢 → 集群  （状态在 Git 里，可 diff、可审计、可回滚）
```

### 四原则（每条都对应一个真实设计）

| 原则 | 含义 | 谁来实现 |
|------|------|----------|
| ① 声明式 | 仓库里写"期望状态"（desired state），不写"操作步骤" | 仓库内容是 YAML 清单，不是脚本 |
| ② Git 是唯一事实来源 | 集群一切以 Git 为准，手工改 = 漂移（drift） | 同步器持续比对 |
| ③ 自动同步（pull） | 同步器从仓库**拉取**并应用，不是人往里推 | controller + agent，集群侧主动拉 |
| ④ 可观测、可持续收敛 | 漂移可检测、可自动修复；回滚 = 仓库回退 | 状态报告 / force 修复 / revision |

**它给人带来的三个核心价值**：

1. **审计**：集群每一次变更都有 Git commit 记录——"谁、什么时候、改了什么"。
2. **回滚**：出问题 = `git revert` 或切回旧 commit，同步器自动把集群改回去（不用人逐条 kubectl）。
3. **多环境一致性**：dev/staging/prod 各是一个分支或目录，结构相同、差异可控。

> 第 25 章末尾的预习题答案：在 GitOps 流程里，**Kustomize 负责"渲染 + 环境差异"，Helm 负责"参数化 + 第三方应用"**——同步器把仓库对应目录拉回来后，用这两者渲染成最终 YAML 再 apply。Fleet 和 ArgoCD 都原生支持这两种渲染器（下面会看到实证）。

---

## 2. 原理：GitOps 的通用"管道"与两种实现

### 2.1 不管哪个工具，都是同一条管道

```text
Git 仓库（YAML/Kustomize/Helm chart）
   │  （1）拉取：有权限地从 Git 拿最新代码
   ▼
渲染（render）：Kustomize build / helm template → 得到最终 YAML
   │  （2）成包：把渲染结果打包成"一批要应用的资源"
   ▼
分发/应用（apply）：把资源应用到目标集群
   │  （3）持续比对：期望 vs 实际 → 漂移检测
   ▼
状态上报：同步成功？失败？漂移了？→ 写回 GitRepo/Application 状态
```

Fleet 和 ArgoCD 的差异，主要在"这条管道分段在哪、谁来做"。

### 2.2 Fleet（Rancher 内置）的架构

```text
Git 仓库（gitea/github/…）
   │
GitRepo CR（用户创建，声明"盯住哪个仓库哪个目录"）
   │  fleet-controller 监听
   ▼
gitjob（pod）：在集群里 git clone / pull，把仓库内容取下来
   │  渲染器：kustomize build / helm template（取决于 path 目录类型）
   ▼
Bundle（fleet-controller 生成）—— 一批要部署的资源 + 目标集群/namespace
   │  BundleDeployment —— bundle 落到某个集群的"部署单"
   ▼
fleet-agent（跑在目标集群里）—— 应用资源 + 持续比对漂移
   ▼
集群实际资源（带 fleet 管理印记）
```

**Fleet 的关键设计**：

- **用 CRD 表达一切**：`GitRepo`（盯仓库）、`Bundle`（渲染好的资源包）、`BundleDeployment`（部署任务）、`Cluster`/`ClusterGroup`（目标集群/集群分组）——全是我方 CR，kubectl 就能查。
- **面向多集群**：一个 GitRepo 可同时同步到一群集群（ClusterGroup），Rancher 管理端/下游集群都吃这套。单集群时用 `fleet-local`（本集群就是）。
- **gitjob 独立成 Pod**：拉代码这件事有独立工作负载（可看日志、可伸缩），不会堵死 controller。

### 2.3 ArgoCD 的架构

```text
Git 仓库
   │
Application CR（用户创建，声明 app 名/repo/path/目标集群）
   │  Application controller 监听
   ▼
repo-server（拉取 + 渲染：git clone、helm template、kustomize build、jsonnet…）
   │
Application controller（对比 desired vs live → Sync 动作）
   ▼
集群资源（带 app.kubernetes.io/instance=名字 或 argocd.argoproj.io/tracking-id 印记）
```

**ArgoCD 的三个核心机制（对照 Fleet 记）**：

| ArgoCD 机制 | 做什么 | Fleet 对应 |
|-------------|--------|------------|
| **Sync**（同步） | 对比 Git 期望与实际 → 执行 apply；可自动（auto-sync）或手动 | 自动应用 Bundle |
| **Health**（健康） | 应用部署后持续健康检查（Progressing/Degraded/Healthy） | BundleDeployment 状态 |
| **Drift**（漂移） | 期望 vs 实际不一致时——默认**只报告**，`selfHeal` 开启才自动修 | 默认只报告，`correctDrift` 开启才自动修（**本章 4.5 会真实复现这个对比**） |

> ArgoCD 有 UI 和 CLI（`argocd app sync`），Fleet 主要靠 Rancher UI + kubectl 查 CR —— 但**底层的"拉取→渲染→应用→漂移"管道两者完全同构**。学一个，另一个就是换皮。

---

## 3. 勘察现场：本集群 Fleet 组件的真实模样

写 GitOps 前，先看本集群（Rancher 自带）Fleet 今天在跑什么。**2026-10-09 真实采集**：

```bash
kubectl get pods -n cattle-fleet-system
```

```text
NAME                                        READY   STATUS    RESTARTS         AGE
fleet-cleanup-gitrepo-jobs-29854080-f8bk8   0/1     Error     0                3d6h
fleet-cleanup-gitrepo-jobs-29854080-hrz7z   0/1     Error     0                3d6h
fleet-controller-5cb54648d5-z4nh7           3/3     Running   62 (6m19s ago)   136d
gitjob-59d6685d46-7q6cx                     1/1     Running   21 (6m19s ago)   136d
helmops-5477b69f6d-slkqz                    1/1     Running   21 (6m19s ago)   136d
```

**读这张表**：

- **fleet-controller 3/3、136 天**：总控在跑，三个容器（controller/代理相关/……）全健康。
- **gitjob 1/1**：拉取 Git 的"搬运工"（2.2 架构里的 git 拉取环节）——它活着，我们的演示才能走通。
- **helmops 1/1**：Helm 操作的执行器（渲染/打包）。
- **两个 fleet-cleanup-gitrepo-jobs 显示 Error**：这是**清理历史任务的 CronJob** 的旧 Job 实例（3d6h 前的），任务本身已过期，报错无碍业务——真实环境里这种"历史遗留 Error Job"很常见，别一看到 Error 就慌。

**Fleet 的 CRD 全家（前 8 个）**：

```text
bundledeployments.fleet.cattle.io     # 部署单
bundlenamespacemappings.fleet.cattle.io
bundles.fleet.cattle.io               # 渲染后的资源包
clustergroups.fleet.cattle.io         # 集群分组
clusterregistrations.fleet.cattle.io / clusterregistrationtokens / clusters.fleet.cattle.io
contents.fleet.cattle.io              # bundle 内容（最终 YAML 清单）
gitrepos.fleet.cattle.io              # ★ 我们的入口
```

**接入前现状**：

```bash
kubectl get gitrepo -A        # → No resources found（一个 Git 仓库都还没接入）
kubectl get bundle -A         # → fleet-local/fleet-agent-local 1/1（fleet 自身管理自己的 bundle）
```

> `fleet-agent-local` 是 Fleet 管理**它自己**（本地集群）的一个 bundle——说明"fleet 管 fleet"也走同一套管道，狗粮自己吃。

---

## 4. 实站：完整跑通一个 GitOps 闭环（真实执行）

目标：造一个"应用仓库"（gitea），用 Fleet 盯着它，看资源**自动**落地、改仓库**自动**同步、人为破坏**被检测**（然后被修复）。全程本集群真实执行（2026-10-09）。

### 4.1 准备"应用仓库"（gitea + Kustomize 结构）

在宿主机 gitea（localhost:3000）建公开仓库 `admin/fleet-demo`，内容是一个 **Kustomize 结构**（复习第 25 章）：

```text
fleet-demo/
└── kustomize/
    ├── base/
    │   ├── deployment.yaml      # nginx-demo（nginx:latest, 3 副本）
    │   ├── service.yaml         # NodePort 30999
    │   └── kustomization.yaml
    └── overlays/
        └── prod/
            └── kustomization.yaml   # namePrefix: prod- / replicas: 2 / env: prod
```

> 为什么用 Kustomize 结构？——**Fleet 原生就把 Kustomize 当渲染器**，path 指向 overlay 目录即可。天然印证上一章。用户代码里也常见这种结构（base 共享、overlay 分环境）。

推上去后确认**从 VM 内（Fleet Pod 所在网络）能匿名拉取**——Fleet 的 gitjob 跑在集群里，它看到的"本地仓库"地址不是 localhost，而是**宿主机在 VM 网络里的地址**（本环境 VirtualBox NAT：`10.0.2.2`）：

```bash
# 在 VM（k3s-demo-server-1）里验证
git ls-remote http://10.0.2.2:3000/admin/fleet-demo.git
# 输出: <sha>  HEAD /  <sha>  refs/heads/main   （通了！）
```

```text
eb12b2f7f17fdfcb5d201779dbcd7508550409f6  HEAD
eb12b2f7f17fdfcb5d201779dbcd7508550409f6  refs/heads/main
```

### 4.2 创建 GitRepo CR（GitOps 的"入伙协议"）

```yaml
apiVersion: fleet.cattle.io/v1alpha1
kind: GitRepo
metadata:
  name: fleet-demo
  namespace: fleet-local        # fleet-local = 管"本集群自己"（单集群场景）
spec:
  repo: http://10.0.2.2:3000/admin/fleet-demo.git   # ★ Fleet 要从这个地址拉
  branch: main
  paths:
  - kustomize/overlays/prod     # ★ 只盯仓库里的这个目录（Kustomize 渲染入口）
  targetNamespace: fleet-demo   # ★ 资源落到这个 namespace
```

```bash
kubectl apply -f gitrepo.yaml
# 输出: gitrepo.fleet.cattle.io/fleet-demo created
```

### 4.3 第一次同步：撞上真实坑——Fleet 的 path 必须"自包含"

等 25 秒后查 GitRepo 状态，得到一条 `ErrApplied`（应用失败）：

```text
NAME         REPO                                        COMMIT                BUNDLEDEPLOYMENTS-READY   STATUS
fleet-demo   http://10.0.2.2:3000/admin/fleet-demo.git   7d86f3395...          0/1                       ErrApplied(1) [Cluster fleet-local/local: error while running post render on files: accumulating resources from '../../base': '../../base' doesn't exist']
```

#### 为什么失败：Fleet 把"每个 path"当成一个独立的渲染根

关键在 4.2 那行 `spec.paths: [kustomize/overlays/prod]`。Fleet 渲染时**只把 path 指向的那个目录当作 kustomize 的根**，而 overlay 里写的是 `../../base`——想往上跳两级去拿资源，就跳出了这个根范围，Fleet 的工作区里自然找不到。

这不是 Kustomize 的问题（第 25 章你在**完整仓库**里跑 `kubectl kustomize overlays/prod` 是成功的），而是 **Fleet 的渲染方式**决定的。本地复现，一测便知：

```bash
# A) 完整仓库都在 → 成功
kubectl kustomize overlays/prod
# 得到 prod-nginx-svc / prod-nginx-demo / replicas: 2

# B) 模拟 Fleet：只把 path 目录拷到一个独立根，再渲染 → 报错（与上面同源）
cp -r overlays/prod /tmp/render-root && cd /tmp/render-root && kubectl kustomize .
# error: accumulating resources: accumulation err='accumulating resources from
#   '../../base': ... no such file or directory': must build at directory: not a valid directory
```

一句话：**Fleet 眼里"一个 path = 一个独立 kustomize 根"，path 里不能引用 `..`。**

#### 改前 vs 改后（对照）

**① 改前**（commit `7d86f33`）——仓库靠 base 跨目录共享，overlay 里只有一个文件：

```text
fleet-demo/
└── kustomize/
    ├── base/                          # 底稿（被 overlay 跨目录引用）
    │   ├── deployment.yaml
    │   ├── service.yaml
    │   └── kustomization.yaml
    └── overlays/
        └── prod/
            └── kustomization.yaml     # ★ 只有 1 个文件
```

`kustomize/overlays/prod/kustomization.yaml`（改前）：

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base          # ★ 元凶：跳两级去拿 base，落到 Fleet 根的外面 → 找不到
namePrefix: prod-
replicas:
  - name: nginx-demo
    count: 2
commonLabels:
  env: prod
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

**② 改后**（commit `78e807c`）——把资源"复制进" path 目录，让每个 path 自包含：

```text
fleet-demo/
└── kustomize/
    ├── base/                          # 保留（Fleet 不指向它，不参与本次渲染）
    │   ├── deployment.yaml
    │   ├── service.yaml
    │   └── kustomization.yaml
    └── overlays/
        └── prod/                      # ★ GitRepo.path 指向这里，必须自包含
            ├── deployment.yaml        # ← 从 base 复制进来（内容不变）
            ├── service.yaml           # ← 从 base 复制进来（内容不变）
            └── kustomization.yaml     # resources 改成"同目录"文件
```

`kustomize/overlays/prod/kustomization.yaml`（改后，只动了 `resources` 两行）：

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml     # ★ 改成同目录文件，不再 ../../base
  - service.yaml
namePrefix: prod-
replicas:
  - name: nginx-demo
    count: 2
commonLabels:
  env: prod
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

`kustomize/overlays/prod/deployment.yaml`（从 base 复制，内容不变，供对照）：

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

`kustomize/overlays/prod/service.yaml`（从 base 复制，内容不变）：

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

> **GitRepo CR 一个字都不用改**——`spec.paths` 仍然是 `kustomize/overlays/prod`（见 4.2）。变的只是仓库里那个目录的内容：从"依赖外部 base"变成"自包含"。

改后 push，Fleet 自动检测到新 commit 并重试：

```text
78e807c  fix: kustomize overlay self-contained (fleet path constraint)
```

> **通用规律**：Fleet 的每个 path 都是一个独立渲染单元。多环境复用时，要么把公共部分"复制/生成"进每个 path，要么直接用 **Helm chart**（chart 天生自包含：模板都在 chart 目录内，`helm template` 不依赖外部相对路径）。

### 4.4 自动交付：GitRepo → Bundle → 资源落地

修复后的同步链路（真实输出）：

```bash
kubectl -n fleet-local get gitrepo fleet-demo
# fleet-demo   ...   78e807c6...   0/1   NotReady(1) ... deployment.apps fleet-demo/prod-nginx-demo [progressing] Available: 1/2
```

**关键观察——中间产物自动生成**：

```bash
kubectl -n fleet-local get bundle | grep fleet-demo
# fleet-demo-kustomize-overlays-prod   0/1   NotReady(1) ...   ← Bundle（渲染后的资源包）
kubectl -n fleet-local get bundledeployment | grep fleet-demo
# (同名 BundleDeployment 出现 —— 部署单下发到集群)
```

**目标资源已在 `fleet-demo` namespace 落地**：

```text
deployment.apps/prod-nginx-demo   1/2   2   1   24s       ← 副本数正在收敛（2 副本）
service/prod-nginx-svc   NodePort 10.43.41.130  <none>  80:30999/TCP
```

**资源上的"管理印记"（判断谁在管它，最硬的证据）**：

```bash
kubectl -n fleet-demo get deploy prod-nginx-demo -o json | jq '.metadata.labels'
```

```json
{
  "app.kubernetes.io/managed-by": "Helm",          // ★ Fleet 底层用 HelmSDK 的 objectset 机制 apply！
  "env": "prod",                                    // ★ Kustomize overlay 的 commonLabels 生效
  "objectset.rio.cattle.io/hash": "eff37aa9b2..."   // ★ Fleet 的漂移对账指纹
}
```

> 三行标签三个知识点：`managed-by: Helm` 是**Fleet 用 Helm 的 ObjectSet 库来 apply 资源**的痕迹（不是装了 Helm release，是"借用了 Helm 的 apply 机制"）；`env: prod` 是 Kustomize 渲染进来的（第 25 章魔法）；`objectset.rio.cattle.io/hash` 是 Fleet 记录"期望状态指纹"，**漂移检测就是拿它和当前资源对账**。

访问验证：

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://192.168.56.10:30999/    # → HTTP 200
```

### 4.5 Git 驱动变更：改仓库 = 改集群（自动同步）

GitOps 的核心体验：**不改集群，只改 Git**。

```bash
# 本地改 overlay：replicas 2 → 1（也是给 2×500m 的 CPU 压力让路，见第 25 章坑 2）
sed -i 's/count: 2/count: 1/' kustomize/overlays/prod/kustomization.yaml
git commit -m "chore: scale to 1 replica"
git push origin main
```

**等 30 秒，什么都不用做**，Fleet 自动完成：

```text
NAME         REPO                                        COMMIT                                     BUNDLEDEPLOYMENTS-READY   STATUS
fleet-demo   http://10.0.2.2:3000/admin/fleet-demo.git   00509427e1...                              1/1

kubectl -n fleet-demo get pods
# prod-nginx-demo-6bd667b7df-7vbcc   1/1   Running
kubectl -n fleet-demo get deploy prod-nginx-demo -o jsonpath='{.spec.replicas}'
# 1
```

**三行证据**：GitRepo 的 `COMMIT` 列自动前进到 `0050942`、`BUNDLEDEPLOYMENTS-READY` 变 `1/1`、Deployment 副本真的变成了 1——**全程没有一条 kubectl apply**。这就是"Git 是唯一事实来源"的现场。

### 4.6 漂移：人为破坏集群，看 Fleet 怎么对待（本章最值钱的一幕）

GitOps 的分水岭：**有人绕过 Git 直接改了集群**，同步器怎么办？——分两档，Fleet 的默认行为和 ArgoCD 默认行为**惊人地一致**，我们一档一档演。

**第一档：默认（只检测、只报告，不自动修）**——在集群里手动改 label：

```bash
kubectl -n fleet-demo label deploy prod-nginx-demo env=drifter --overwrite
# deployment.apps/prod-nginx-demo labeled
```

等 45 秒，查 GitRepo 状态：

```text
fleet-demo   ...   0050942...   0/1   Modified(1) [Cluster fleet-local/local]; deployment.apps fleet-demo/prod-nginx-demo modified {"metadata":{"labels":{"env":"prod"}}}
```

**解读这份状态**（金句）：Fleet **检测到了漂移**（`Modified(1)`），甚至明确指出"期望 env=prod、当前被改成了 drifter"——**但它没有动手修**。集群里的 label 仍然是 `drifter`。

> 这正是主流 GitOps 工具的**默认安全策略**：漂移默认"报警不轰炸"——万一手动改是有意的（比如临时调试、线上救火），自动回滚反而捅娄子。Fleet 要 `correctDrift`、ArgoCD 要 `selfHeal` 才进入"自动修复"档。**默认只报不改，两边一模一样。**

**第二档：开启自动修复（correctDrift: true）**：

```bash
kubectl -n fleet-local patch gitrepo fleet-demo --type=merge \
  -p '{"spec":{"correctDrift":{"enabled":true,"force":true}}}'
# gitrepo.fleet.cattle.io/fleet-demo patched
```

等 45 秒：

```text
label 回到: env: prod          （被打回 Git 声明状态！）
GitRepo 状态: 1/1  （Ready，不再 Modified）
```

**完整闭环达成**：破坏 → 检测（默认只报）→ 开启修复 → 自动还原。这条链路就是 GitOps 自愈能力的全部真相——**不是"永远不被改"，而是"改了能发现、想要能自动改回来"**。

### 4.7 收尾：删 GitRepo = 一键卸载（反向自动同步）

```bash
kubectl -n fleet-local delete gitrepo fleet-demo
```

等 20 秒看**清理也是自动的**：

```text
bundle: 已清理（数量回到 0）
fleet-demo namespace 资源: No resources found   （Deployment/Service/Ingress 全被 Fleet 回收）
gitea 仓库: curl -X DELETE … → HTTP 204（宿主机侧一并清理）
```

> 反向也成立：**删除 GitRepo，Fleet 会回收它创建的所有资源**。这正是"我把集群状态托管给了 Git，撤销托管也干干净净"。

---

## 5. Fleet vs ArgoCD：逐项正面对比

两个都是"Git 是唯一事实来源"的实现，主战场不同。本集群用 Fleet（Rancher 自带），ArgoCD 未部署（上述已说明）——以下对比按原理 + 公开行为，本集群已验证的标注 ✓：

| 维度 | Fleet（Rancher 内置） | ArgoCD（独立 CNCF 项目） |
|------|----------------------|--------------------------|
| 安装 | **Rancher 自带**，零成本（本集群 136 天 ✓） | 需自己装（kubectl/helm/operator），自带 UI |
| 入口对象 | `GitRepo` CR（✓ 4.2） | `Application` CR |
| 渲染器 | kustomize / helm ✓ | helm / kustomize / jsonnet / 自定义插件 |
| 拉取 | gitjob Pod（✓ 3 节，独立工作负载） | repo-server（独立组件） |
| 资源包 | Bundle + Contents（✓ 4.4 可见） | 直接由 controller 同步 |
| 漂移检测 | 默认报、`correctDrift` 修（✓ 4.6 全实测） | 默认报、`selfHeal` 修 |
| 回滚 | **改 Git commit**（✓ 4.5：推进即生效） | `argocd app rollback` 支持切历史 revision |
| 多集群 | 天生主打：Cluster/ClusterGroup 分组、级联 | 支持多集群但以"每 Application 指一个集群"组织 |
| UI | Rancher 的 Continuous Delivery 页面 | 独立 Web UI（泳道图/同步状态墙） |
| 适用 | 已在用 Rancher 管理集群 | 想要独立于 Rancher、或深度自定制的 GitOps |
| 本集群 | 生产在用 ✓ | 未部署（章节内原理对照） |

**选型一句话**：**Rancher 用户 → Fleet 顺理成章（零安装、UI 集成、多集群天生）**；**不用 Rancher / 要更细的同步控制（hook、sync 阶段、插件）→ ArgoCD**。

---

## 6. Rancher 界面对照（Continuous Delivery）

Rancher 里 Fleet 的界面就是 **Continuous Delivery**（持续交付）页：左侧 Cluster 导航 → 底部 **Continuous Delivery**。

在这个页面你能看到（对应我们 4 节做的每件事）：

- **Git Repos 列表**：每行一个 GitRepo（能看到我们 `fleet-demo` 的 URL、branch、最后一个 commit、状态）。
- **Cluster Groups / Clusters**：部署目标；`local` 就是我们 k3s 集群自己（`fleet-local` 的映射）。
- **Bundle 状态**：点进 GitRepo 看它产生的 Bundle（`fleet-demo-kustomize-overlays-prod`）与其 `NotReady/Modified/Ready` 状态流转。
- **漂移一眼可见**：把 Deployment 改花后回到 UI，Bundle 状态显示 Modified——**和 4.6 在命令行看到的是一个东西，Rancher 帮你画出来了**。

> 界面上还有个动作值得留意：**Force Update**（强制同步）——点它等于触发一次立即拉取应用，对应 CLI 里 `kubectl -n fleet-local annotate gitrepo fleet-demo fleet.cattle.io/force-sync=true`。

---

## 7. 排障：GitOps 常见问题速查

| 现象 | 原因 | 排查 |
|------|------|------|
| Bundle 一直 `ErrApplied` | 渲染失败（如 kustomize 路径不存在） | 看 STATUS 里的具体报错（✓ 4.3 的 `'../../base' doesn't exist` 就是活例） |
| GitRepo 拉不到仓库 | 地址只在宿主机通、Pod 里不通 | 从 VM 里 `git ls-remote` 验证；用 `10.0.2.2` 这类**集群侧可达**的地址 |
| 改了 Git 不生效 | branch/paths 写错，或触发未过 | 核对 `kubectl get gitrepo -o yaml` 的 spec；等一个轮询周期（默认 15s 级） |
| 漂移了不修复 | 默认只报不改（安全策略） | 开 `correctDrift.enabled: true`（Fleet）/ `selfHeal`（ArgoCD） |
| 修了恢复不过来 | force 不够 | `force: true` 允许覆盖冲突字段（✓ 4.6 就是这样修的） |
| 想立即同步 | 不想等轮询 | Rancher UI Force Update / annotation 强推 |
| 有历史 Error Job | 清理任务的旧实例 | cronjob 历史遗留，业务无碍（✓ 3 节真实所见） |

---

## 8. 小结

1. **GitOps 四原则**：声明式 / Git 唯一事实来源 / pull 自动同步 / 可观测可回滚。
2. **管道**：Git 仓库 → 拉取（gitjob/repo-server）→ 渲染（kustomize/helm）→ Bundle/Application → agent 应用 → 持续对账。
3. **真实闭环**（本集群 2026-10-09）：gitea 建库 → GitRepo 接入 → 自动落地（`managed-by: Helm` + `objectset hash` 印记）→ 改 Git 自动同步（commit 推进即生效）→ 人为漂移：**默认只报不改，开 correctDrift 后自动修复** → 删 GitRepo 资源自动回收。
4. **Fleet vs ArgoCD**：同构管道、同漂移策略（默认报/开关修）；Fleet 是 Rancher 内置、多集群天生，ArgoCD 独立可定制。
5. 别忘了那两个衍生知识点：**Fleet 的 path 要自包含**；**Fleet 借用 HelmSDK 的 ObjectSet apply**（所以资源带 `managed-by: Helm`）。

---

## 动手练习

1. **画管道**：不看正文，画出"改一个 YAML 提交到 Git → 集群变样"经过的 5 个环节（拉取/渲染/成包/应用/对账），给每个环节标出 Fleet 的对应组件。
2. **复现闭环**：按 4 节步骤，在 gitea 建你自己的仓库（内容换成一个 `deployment + service` 的 Kustomize 结构），跑通 GitRepo → 资源落地 → 访问 200 → 清理。
3. **漂移实验**：练习 2 完成后，手动 `kubectl scale deploy xxx --replicas=3`，观察 GitRepo 状态变成 Modified；再开启 correctDrift，看它拉回 1。
4. **对比题**：ArgoCD 的 `selfHeal` 与 Fleet 的 `correctDrift` 行为是一样的（默认只报不改）。想想为什么两个项目都不约而同把"自动修复"设为**默认关闭**？哪些场景应该开、哪些场景必须关？（提示：在线故障处理、临时调试、数据库类有状态服务）
5. **选型判断题**：公司已有 Rancher 管着 40 个集群，要上一套 GitOps——选 Fleet 还是 ArgoCD？如果公司禁用 Rancher、纯开源栈呢？（答案在第 5 节）