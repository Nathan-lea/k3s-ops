# 13 Label 与选择器：从概念到系统自带标签的实战

## 本章目标

- 理解 Label（标签）设计思想：**key/value 附加信息**，K8s 里几乎所有"关联"都靠它
- 掌握两种选择器语法：等值选择（`=`/`!=`）与集合选择（`in`/`notin`/`exists`）
- 认识 Label 在日常运维的关键作用：`-l` 过滤、Service/Controller 联动、调度
- **重点**：系统自带 Label 有哪些、默认值是什么、日常怎么用（节点/命名空间/工作负载）
- 学会增删改查标签（`kubectl label` / `--show-labels` / `kubectl get -l`）

> 前置：建议先完成第 03（工作负载）、04（Service）、06（调度）章。Label 是贯穿它们的"胶水"。
> 本章所有输出来自本集群真实执行。

---

## 1. Label 是什么

Label 是**附加在对象上的键值对（key/value）**，用于标识和选择对象：

```yaml
metadata:
  labels:
    app: nginx-demo        # key=value
    tier: frontend
    env: production
```

**关键设计思想**：Label 不是唯一的（不像名字），一个对象可以有多个 Label，一个 Label 可以属于多个对象。这种"多对多"松散关联正是 K8s 组织海量资源的方式。

| 对比 | 名字（name） | Label |
|------|------------|-------|
| 唯一性 | 同一命名空间内唯一 | 不唯一，可有多个 |
| 用途 | 定位具体对象 | 分组、筛选、关联 |
| 是否可改 | Deployment 不可改 | 随时可增删改 |
| 示例 | `nginx-demo-559f959666-59frr` | `app=nginx-demo` |

**命名规则**（重要，排错常见）：

- key 分两部分：`前缀/名称`，前缀可选（须为 DNS 子域，如 `kubernetes.io/`、`app.kubernetes.io/`）
- 名称部分 ≤ 63 字符，以字母/数字开头
- value 可以为空、≤ 63 字符

> 约定俗成：**不带前缀**的 key（如 `app=nginx-demo`）属于用户自定义空间；**带系统前缀**（`kubernetes.io/` 等）的是系统或公认标准，见第 4 节。

## 2. 选择器语法（Selector）

### 2.1 等值选择（equality-based）

| 操作符 | 含义 | 示例 |
|--------|------|------|
| `=` | 相等 | `app=nginx-demo` |
| `==` | 相等（同 `=`） | `app==nginx-demo` |
| `!=` | 不相等 | `tier!=backend` |

### 2.2 集合选择（set-based）

| 操作符 | 含义 | 示例 |
|--------|------|------|
| `in` | 属于集合 | `env in (prod,staging)` |
| `notin` | 不属于集合 | `env notin (dev)` |
| `exists` | key 存在 | `tier`（只要该 key 存在） |
| `!key` | key 不存在 | `!tier` |

多个条件用逗号分隔（AND 关系）：`-l 'app=nginx-demo,env in (prod)'`

### 2.3 三处用 Selector 的地方

| 位置 | 作用 |
|------|------|
| **`kubectl get -l`** | 命令行过滤要查看的资源 |
| **资源 spec 里（如 Service/Deployment）** | 声明"我要关联哪些对象" |
| **API 查询参数** | 程序化精准取数 |

## 3. Label 在各组件的实际作用

```
        Deployment (spec.selector.matchLabels)
              │  app=nginx-demo
              ▼
        ReplicaSet (自动继承 + pod-template-hash)
              │
              ▼
        Pod (创建时带上 Labels)
              │              ▲
              │              │ app=nginx-demo
              ▼              │
        Service (spec.selector) 匹配 Pod → 自动生成 Endpoints
```

**四大作用**：

1. **Controller → Pod 归属**：Deployment 通过 selector 声称"这些 Pod 归我管"，缩放、滚动更新才找得到
2. **Service → Endpoints 关联**：Service 用 selector 匹配 Pod，自动维护后端列表（本章 3.x 实测）
3. **调度**：`nodeSelector`/`nodeAffinity` 用节点标签选目标节点（第 06 章细讲）
4. **运维组织**：按环境/应用/团队分组，一条命令精准操作一批资源

## 4. 系统自带 Label 与默认值（本节重点）

集群创建时，K8s/k3s 会给节点、命名空间打上**系统标签**。它们都有默认值，日常排障、调度、监控常靠它们。

### 4.1 节点自带标签（本集群真实数据）

```bash
kubectl get nodes --show-labels
```

真实输出：

```text
NAME                STATUS   ROLES                      LABELS
k3s-demo-agent-1    Ready    <none>                     beta.kubernetes.io/arch=amd64,beta.kubernetes.io/instance-type=k3s,beta.kubernetes.io/os=linux,disktype=hdd,kubernetes.io/arch=amd64,kubernetes.io/hostname=k3s-demo-agent-1,kubernetes.io/os=linux,node.kubernetes.io/instance-type=k3s
k3s-demo-server-1   Ready    control-plane,etcd,master  beta.kubernetes.io/arch=amd64,beta.kubernetes.io/instance-type=k3s,beta.kubernetes.io/os=linux,disktype=ssd,kubernetes.io/arch=amd64,kubernetes.io/hostname=k3s-demo-server-1,kubernetes.io/os=linux,node-role.kubernetes.io/control-plane=true,node-role.kubernetes.io/etcd=true,node-role.kubernetes.io/master=true,node.kubernetes.io/instance-type=k3s
```

逐个解读（**这些就是默认值**）：

| 标签 | 默认值（本集群） | 含义与日常用处 |
|------|----------------|----------------|
| `kubernetes.io/hostname` | 节点主机名 | **调度到指定节点**（`nodeSelector` 用最多） |
| `kubernetes.io/os` | `linux` | 平台筛选（`-l kubernetes.io/os=linux`） |
| `kubernetes.io/arch` | `amd64` | CPU 架构筛选 |
| `node-role.kubernetes.io/control-plane` | `true` | 控制面节点（对应 `ROLES` 列 control-plane） |
| `node-role.kubernetes.io/etcd` | `true` | 承载 etcd 的节点（k3s 嵌入式） |
| `node-role.kubernetes.io/master` | `true` | 兼容旧版 master 标识 |
| `node.kubernetes.io/instance-type` | `k3s` | k3s 自动打上"实例类型" |
| `beta.kubernetes.io/os`/`arch` | `linux`/`amd64` | 旧版（beta）副本，**为兼容旧脚本保留** |
| `disktype` | **本集群手动加的** | ssd/hdd（见第 06 章：测试 nodeSelector 时手动添加） |

> **教学点**：`disktype` 不是系统标签——它是教程第 06 章做 nodeSelector 实验时手动 `kubectl label node ... disktype=ssd` 加的。系统标签 vs 自定义标签的界线，看前缀：**`kubernetes.io/`、`node-role.kubernetes.io/`、`node.kubernetes.io/` 都是系统保留前缀**。

**注意**：云环境（EKS/GKE/AKS）会有 `topology.kubernetes.io/region`、`topology.kubernetes.io/zone` 等拓扑标签；本集群是本地 k3s，**没有这些标签**（前面验证过）——排障时若脚本依赖它们会失败，这是正常现象。

### 4.2 命名空间自动标签

每个命名空间创建时自动带 `kubernetes.io/metadata.name`：

```bash
kubectl get ns -o custom-columns=NAME:.metadata.name,LABELS:.metadata.labels | head -4
```

真实输出：

```text
NAME                                     LABELS
cattle-capi-system                       map[cattle.io/creator:norman kubernetes.io/metadata.name:cattle-capi-system]
cattle-fleet-clusters-system             map[field.cattle.io/projectId:p-fr6vf kubernetes.io/metadata.name:cattle-fleet-clusters-system ...]
```

- `kubernetes.io/metadata.name=<你的 NS 名>`：自动生成，**值 = 命名空间名**，可按 NS 精确过滤
- `cattle.io/creator:norman`、`field.cattle.io/projectId:`：Rancher 打的标签（`p-fr6vf` 是 Rancher 项目 ID）

> 用法示例：`kubectl get pods -A -l kubernetes.io/metadata.name=kube-system` 只看 kube-system 的 Pod。

### 4.3 工作负载自动标签

```bash
kubectl -n lab get rs --show-labels | head -4
```

真实输出：

```text
NAME                    DESIRED   CURRENT   READY   AGE   LABELS
nginx-demo-559f959666   5         5         5       25h   app=nginx-demo,pod-template-hash=559f959666
nginx-demo-689745b8fd   0         0         0       25h   app=nginx-demo,pod-template-hash=689745b8fd
```

- **`pod-template-hash`**：Deployment 为每个 ReplicaSet 自动生成的唯一哈希标签，**用于区分新旧版本 ReplicaSet**（滚动更新时旧 RS 保留、新 RS 接管）
- Deployment 的 selector 用 `app=nginx-demo`，ReplicaSet 在 Pod 上额外加 `pod-template-hash`

```bash
kubectl -n kube-system get pods --show-labels | head -4
```

真实输出：

```text
NAME                                      READY   STATUS    RESTARTS   AGE    LABELS
coredns-576bfc4dc7-c5j4q                  1/1     Running   12         131d   k8s-app=kube-dns,pod-template-hash=576bfc4dc7
local-path-provisioner-86f46b7bf7-mdnxz   1/1     Running   14         131d   app=local-path-provisioner,pod-template-hash=86f46b7bf7
metrics-server-557ff575fb-khjrx           1/1     Running   13         131d   k8s-app=metrics-server,pod-template-hash=557ff575fb
```

- **`k8s-app=kube-dns` / `k8s-app=metrics-server`**：核心组件惯例标签，Service 用它们关联
- 验证：`kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.selector}'` → `map[k8s-app:kube-dns]`

### 4.4 推荐标签（应用方标准）

K8s 官方推荐一组**通用标签**（前缀 `app.kubernetes.io/`），多用于 Helm/Operator 管理的应用，本集群 Rancher 相关组件可见：

| 标签 | 含义 | 例 |
|------|------|----|
| `app.kubernetes.io/name` | 应用名 | `nginx-demo` |
| `app.kubernetes.io/instance` | 实例标识 | `nginx-demo-prod` |
| `app.kubernetes.io/version` | 版本 | `v1.0.0` |
| `app.kubernetes.io/managed-by` | 管理工具 | `Helm`、`k3s` |

```bash
kubectl get ns cattle-capi-system -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}'
# 输出：Helm   （Rancher 用 Helm 部署的组件）
```

## 5. 本集群实站对照

### 5.1 查标签：--show-labels 与 -l

```bash
kubectl -n lab get pods -l app=nginx-demo -o name
```

真实输出：

```text
pod/nginx-demo-559f959666-59frr
pod/nginx-demo-559f959666-kv4nv
pod/nginx-demo-559f959666-pw68t
pod/nginx-demo-559f959666-thbhv
pod/nginx-demo-559f959666-vkpmx
```

带标签列查看：

```bash
kubectl -n lab get pods -l app=nginx-demo --show-labels
```

真实输出（每行尾部是 Labels 列）：

```text
NAME                          READY   STATUS    RESTARTS      AGE   LABELS
nginx-demo-559f959666-59frr   1/1     Running   1 (83m ago)   25h   app=nginx-demo,pod-template-hash=559f959666
nginx-demo-559f959666-kv4nv   1/1     Running   1 (83m ago)   25h   app=nginx-demo,pod-template-hash=559f959666
```

### 5.2 加/删标签

```bash
# 加标签
kubectl -n lab label pod nginx-demo-559f959666-59frr tier=frontend
# 真实输出: pod/nginx-demo-559f959666-59frr labeled

# 查新标签
kubectl -n lab get pods -l tier=frontend -o name
# 真实输出: pod/nginx-demo-559f959666-59frr

# 删标签（key 后跟 -）
kubectl -n lab label pod nginx-demo-559f959666-59frr tier-
# 真实输出: pod/nginx-demo-559f959666-59frr unlabeled
```

> 修改已存在的标签：`kubectl label pod <名> app=new-value --overwrite`（不写 `--overwrite` 会报"already exists"）。

### 5.3 Label 驱动 Service 联动（重点观察）

**机制**：Service 的 `spec.selector` 匹配 Pod 标签 → 控制面自动生成 Endpoints。

```bash
kubectl -n lab get svc nginx-svc -o jsonpath='{.spec.selector}'
# 输出: map[app:nginx-demo]
```

扩容自动加端点（真实执行）：

```bash
kubectl -n lab scale deploy nginx-demo --replicas=6
sleep 8
kubectl -n lab get endpoints nginx-svc -o custom-columns=NAME:.metadata.name,IPS:.subsets[*].addresses[*].ip
```

真实输出：

```text
扩容前: 10.42.0.10,10.42.0.13,10.42.0.4,10.42.0.5,10.42.0.6
扩容后: 10.42.0.10,10.42.0.13,10.42.0.26,10.42.0.4,10.42.0.5,10.42.0.6
```

（新 Pod `10.42.0.26` 自动进端点；缩回 5 副本后它自动消失——不需要动 Service。）

### 5.4 用节点标签做调度的日常用法

```bash
# 按主机名调度（最常见的 nodeSelector）
kubectl get nodes -l kubernetes.io/hostname=k3s-demo-server-1
# 输出该节点

# 按角色筛选控制面
kubectl get nodes -l node-role.kubernetes.io/control-plane
# 输出: k3s-demo-server-1
```

> nodeSelector 的完整 YAML 与实验见第 06 章。标签是它工作的前提——**先给节点打标签，才能按语义选择**。

## 6. Rancher 界面对照

- **Cluster → Nodes**：节点列表展示 Labels（点开节点详情有完整标签）；`⋮ → Edit Config` 可手动加节点标签
- **Cluster → Projects/Namespaces**：Rancher 的项目（projectId 标签）正是用 Label 实现的
- **Workload → 某工作负载**：查看 Pod 的 Labels，或 Edit 时在 Labels & Annotations 直接改
- **Service Discovery → Services**：View/Edit YAML 看 `.spec.selector`

## 7. 小结

- Label = key/value 附加信息，**不唯一、可多对多**；Selector 用它做精确关联
- 三种选择器场景：`kubectl get -l`（查）、资源 spec（关联）、API 查询（取数）
- 系统标签：节点（`kubernetes.io/hostname/os/arch`、`node-role.kubernetes.io/*`）、命名空间（`kubernetes.io/metadata.name`）、工作负载（`pod-template-hash`）、组件惯例（`k8s-app=`）
- 系统前缀 `kubernetes.io/`、`node-role.kubernetes.io/`、`node.kubernetes.io/` 保留；云环境另有 `topology.kubernetes.io/region/zone`
- 标签驱动联动：Service ↔ Endpoints、Deployment ↔ ReplicaSet ↔ Pod、调度器 ↔ 节点
- 用 `kubectl label` 增删改；`--overwrite` 覆盖；`key-` 删除

## 动手练习

1. 列出所有带 `kubernetes.io/hostname` 标签的节点，并观察该标签的值是否等于 `kubectl get nodes` 的 NAME。
2. 用集合选择 `-l 'node-role.kubernetes.io/control-plane'` 和 `-l '!node-role.kubernetes.io/control-plane'` 分别查节点，对比结果。
3. 给 `lab` 的一个 Deployment 打标签 `env=test`，再用 `-l env=test` 查它管理的 Pod（观察：打给 Deployment 的标签会不会自动出现在 Pod 上？为什么？）。
4. 把 nginx-svc 的 selector 临时改成 `app=不存在`，观察 `kubectl get endpoints` 变成空——再改回来恢复（⚠️ 会短暂断流，练习完记得恢复）。
5. 思考题：为什么 Deployment 的 selector 一旦创建后**不允许修改**（`spec.selector` 是 immutable）？

<details>
<summary>参考答案</summary>

1. `kubectl get nodes -l kubernetes.io/hostname`——该标签值确实等于节点名，这是调度到指定节点的依据。
2. 前者只出 server-1（有该标签=true），后者只出 agent-1（标签不存在）。
3. **不会自动同步**。Deployment 的标签只属于 Deployment 自身；Pod 标签来自 Pod template（`.spec.template.metadata.labels`），需在模板里声明才会出现在 Pod 上。`kubectl label deploy ...` 只改 Deployment 对象本身，不影响已创建的 Pod。
4. selector 匹配不到任何 Pod 时 Endpoints 为空，Service 表现为 503/连接拒绝——这正说明"Service 与 Pod 的关联全靠 Label"。
5. Deployment 的 `spec.selector` 一旦创建不可改：它是"所有权"声明，若允许随意改，正在被旧 selector 管理的 Pod 可能同时被多个控制器认领（产生孤儿/双管理器冲突）。要改，只能删旧 Deployment 重建或改 Pod template 滚动迁移。
</details>