# 18 Annotation 详解：概念、来源、查看与实战应用

## 本章目标

- 理解 Annotation（注解）的本质：**非标识性的 key/value 附加信息**，不参与选择，可承载任意字符串
- 掌握 Annotation 与 Label 的**根本区别**（含选型表：什么时候用哪个）
- 认识 Annotation 的**六大来源**：kubectl 工具、K8s 核心、系统组件、第三方工具、云厂商/平台、用户自定义
- 用**本集群真实数据**看清各类 Annotation 的长相与用途（Node 16 个 key / PVC / Deployment / Ingress / Pod）
- 学会**查看、添加、修改、删除** Annotation（`kubectl annotate` 全用法）
- 学会把 Annotation 用于**排障与自动化**（`k3s.io/node-args` 查启动参数、`last-applied-configuration` 备份恢复、`selected-node` 查存储落点）

> 前置：建议先完成 13（Label）、15（资源定义文件）、17（资源落位）。Annotation 与它们强相关。
> 本章所有输出均为本集群真实采集。

---

## 1. Annotation 是什么

Annotation 是**挂在对象 `metadata.annotations` 下的键值对（key/value）**，用来给对象附加**非标识性**的信息：

```yaml
metadata:
  annotations:
    description: 我的备注            # 随意字符串
    prometheus.io/scrape: "true"     # 监控采集配置
    kubectl.kubernetes.io/restartedAt: 2026-10-05T09:12:35+08:00
```

**一句话定义**：Label 是"给对象贴的标签"（**用来选**），Annotation 是"给对象写的便签"（**用来读**）。

### 1.1 与 Label 的关键区别（必须吃透）

| 维度 | Label（标签） | Annotation（注解） |
|------|--------------|-------------------|
| 本质 | **标识性**：用于选择/分组 | **描述性**：用于记录/配置 |
| 能否被 selector 匹配 | ✅（Service/Deployment/nodeSelector 等） | ❌（**永远不参与选择**） |
| 可查性 | `kubectl get -l` / `--show-labels` | 需 `-o yaml/json/jsonpath` 展开 |
| 内容限制 | key 严格规范；value ≤63 字符 | **任意字符串**（可放 JSON、长文本、tls 配置） |
| 长度上限 | 单对象整个 labels 总大小受限 | **单对象整个 annotations 总量 ≤ 256KB**（防止滥放） |
| 变更影响 | 影响调度/服务发现（慎改） | **不影响任何选择逻辑**（可随意改） |
| 前缀惯例 | `app.kubernetes.io/`、`kubernetes.io/` | 各工具/组件各自前缀（§2.2） |
| 谁在写 | 用户为主，控制器少量（pod-template-hash） | **系统/控制器/工具大量写**，用户也可写 |

> 记忆锚点：**Label 回答"这对象属于哪一组"，Annotation 回答"这对象有什么备注/元信息"**。labels 与 annotations 是两个并列的 map，同一个 key 不允许同时出现在两者里。

### 1.2 Annotation 的价值（为什么"非常重要"）

1. **记录**：对象是谁装的、什么时候改的、当初怎么配的（`k3s.io/node-args` 记 k3s 启动参数）
2. **配置驱动**：很多控制器/工具**用 Annotation 下发配置**，改 Annotation 即改行为（ingress-nginx 的 `nginx.ingress.kubernetes.io/*` 系列注解）
3. **状态回显**：控制面把内部状态写进 Annotation 供人读（`pv.kubernetes.io/bind-completed`、`field.cattle.io/publicEndpoints`）
4. **自动化**：Prometheus 通过 `prometheus.io/scrape` 等注解发现抓取目标（本集群实测）；外部系统靠约定注解接入
5. **无损附加**：不占 label 命名空间、不影响选择——放"想说但不想用来分类"的东西

---

## 2. Annotation 的格式与命名规则

### 2.1 语法

```yaml
annotations:
  前缀/名称: 值      # 前缀可选
  无前缀键: 值       # 允许（不推荐，易冲突）
```

- **key**：与 Label 的 key 规则相同——前缀须为 DNS 子域（`kubernetes.io`、`k3s.io`、`prometheus.io`…），名称部分 ≤ 63 字符，字母/数字/`-_.`，首尾须字母数字
- **value**：任意字符串；空串合法（等于"标记了这个键存在"）
- **大小**：单对象全部 annotations **总大小上限 256KB**（超出 API Server 拒绝写入）

### 2.2 本环境常见前缀一览（实测）

| 前缀 | 谁写的 | 用途 |
|------|--------|------|
| `kubectl.kubernetes.io/` | kubectl | 工具行为记录（§3.1） |
| `deployment.kubernetes.io/` | Deployment 控制器 | 版本号 revision |
| `pv.kubernetes.io/` | 存储控制器 | PV 绑定状态 |
| `volume.kubernetes.io/` `volume.beta.kubernetes.io/` | 存储/调度 | 选定节点、provisioner |
| `k3s.io/` | k3s | 节点身份/启动参数/环境 |
| `etcd.k3s.cattle.io/` | k3s 内嵌 etcd | 快照时间、节点地址 |
| `flannel.alpha.coreos.com/` | flannel CNI | 网络后端数据 |
| `management.cattle.io/` | Rancher | pod 资源限额 |
| `field.cattle.io/` | Rancher | 对外暴露端点记录 |
| `cattle.io/` `lifecycle.cattle.io/` | Rancher | 命名空间状态/生命周期 |
| `prometheus.io/` | Prometheus 监控 | 抓取配置 |
| `alpha.kubernetes.io/` `node.alpha.kubernetes.io/` | K8s 核心 | 节点 IP、TTL |

**判读方法**：见前缀即知"是谁写的、大概是干什么的"。这也是排障第一步——**看对象的 Annotation 就是看对象的"病历本"**。

---

## 3. Annotation 的六大来源（从大到小认识）

### 3.1 kubectl 工具写入

| Annotation | 何时出现 | 作用 | 本环境实测 |
|-----------|---------|------|-----------|
| `kubectl.kubernetes.io/last-applied-configuration` | **每次 `kubectl apply`** 自动存 | 记录"上次 apply 的完整 YAML"——apply 三方合并的基准（第 15 章 §5.1） | PVC/Deployment/Ingress 上都有 |
| `kubectl.kubernetes.io/restartedAt` | `kubectl rollout restart` 时 | 记录重启时间——**注解变化使 Pod 模板哈希改变，从而触发滚动更新** | `nginx-demo` Pod 实测 `2026-10-05T09:12:35+08:00` |
| `kubectl.kubernetes.io/default-container` | 多容器的 Pod | 指定 `kubectl logs/exec` 默认操作哪个容器 | ingress-nginx 实测存在 |

实测（Deployment 的 revision annotation 会随每次滚动 +1）：

```bash
kubectl -n lab get deploy nginx-demo -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}'
# 当前输出: 3   （rollout restart 后从 2 变成 3，见第 16 章）
```

### 3.2 K8s 核心控制器写入（存储/调度）

实测 `lab/nginx-data` PVC 的完整 annotations（**全是系统写的**）：

```bash
kubectl -n lab get pvc nginx-data -o json | jq -r '.metadata.annotations|to_entries[]|"\(.key) = \(.value)"'
```

真实输出：

```text
kubectl.kubernetes.io/last-applied-configuration = {"apiVersion":"v1","kind":"PersistentVolumeClaim",...}
pv.kubernetes.io/bind-completed = yes                              ← 绑定完成
pv.kubernetes.io/bound-by-controller = yes                         ← 由控制器绑定
volume.beta.kubernetes.io/storage-provisioner = rancher.io/local-path
volume.kubernetes.io/selected-node = k3s-demo-server-1             ← ★ 数据落在哪台节点（第 17 章用过）
volume.kubernetes.io/storage-provisioner = rancher.io/local-path
```

> `volume.kubernetes.io/selected-node` 是**排障金矿**：直接告诉你这块本地盘数据在哪台节点（第 17 章"数据单节点"的实证）。

### 3.3 节点侧：k3s / flannel / etcd（综合大杂烩）

**Node 是本集群 Annotation 最丰富的对象（16 个 key）**，实测：

```bash
kubectl get node k3s-demo-server-1 -o json | jq -r '.metadata.annotations|keys[]'
```

真实输出：

```text
alpha.kubernetes.io/provided-node-ip
etcd.k3s.cattle.io/local-snapshots-timestamp       ← 最近 etcd 快照时间
etcd.k3s.cattle.io/node-address
etcd.k3s.cattle.io/node-name
flannel.alpha.coreos.com/backend-data              ← flannel vxlan 后端信息
flannel.alpha.coreos.com/backend-type
flannel.alpha.coreos.com/kube-subnet-manager
flannel.alpha.coreos.com/public-ip
k3s.io/hostname
k3s.io/internal-ip
k3s.io/node-args                                   ← ★★★ k3s 启动参数（排障神器）
k3s.io/node-config-hash                            ← 配置哈希
k3s.io/node-env                                    ← 数据目录等环境
management.cattle.io/pod-limits                    ← Rancher 计算出的 Pod 限额
management.cattle.io/pod-requests
node.alpha.kubernetes.io/ttl                       ← 节点对象 TTL
volumes.kubernetes.io/controller-managed-attach-detach
```

**`k3s.io/node-args` 实战用法**（忘了当初 k3s 怎么启动的？）：

```bash
kubectl get node k3s-demo-server-1 -o jsonpath='{.metadata.annotations.k3s\.io/node-args}'
# 输出: ["server","--node-name","k3s-demo-server-1","--node-ip","192.168.56.10",
#        "--cluster-cidr","10.42.0.0/16","--service-cidr","10.43.0.0/16",
#        "--disable","traefik","--disable","servicelb","--flannel-backend","vxlan",...]
```

> 所有调参（`--disable traefik`、`--flannel-backend vxlan`…）都留在 Annotation 里，**不用猜、不用翻 systemd 文件**。这是"Annotation = 病历本"的最好例子。

### 3.4 第三方控制器：Rancher 的 field.cattle.io / Prometheus 的 prometheus.io

**Rancher 往用户对象上写"对外暴露端点"**（Ingress 实测全文）：

```bash
kubectl -n lab get ing nginx-ing -o jsonpath='{.metadata.annotations.field\.cattle\.io/publicEndpoints}'
```

真实输出：

```json
[{"addresses":["10.43.197.40"],"port":80,"protocol":"HTTP","serviceName":"lab:nginx-svc",
  "ingressName":"lab:nginx-ing","hostname":"lab.k3s.local","path":"/","allNodes":false}]
```

**Prometheus 用 Annotation 发现抓取目标**（本集群 Pod annotation 全量 key 统计实测）：

```bash
kubectl get pods -A -o json | python3 -c "
import json,sys,collections
data=json.load(sys.stdin)
c=collections.Counter()
for item in data['items']:
    for k in (item.get('metadata',{}).get('annotations') or {}): c[k]+=1
for k,v in c.most_common(): print(f'{v:4d} {k}')"
```

真实输出：

```text
   5 kubectl.kubernetes.io/restartedAt                  ← 工具记录（rollout restart 痕迹）
   3 prometheus.io/path                                 ← 监控抓取路径
   3 prometheus.io/port                                 ← 监控抓取端口
   3 prometheus.io/scrape                               ← 是否抓取（ingress-nginx 相关 Pod）
   1 kubectl.kubernetes.io/default-container
   1 kubectl.kubernetes.io/last-applied-configuration
```

> 对照出一个**极重要的观察**：本集群 Pod 侧的 Annotation 极少且全部是工具/监控写入；**而 Node 侧有 16 个**——因为**身份与状态类信息（k3s/flannel/etcd）都堆在节点上**。Annotation 的分布本身就是"资源落位"（第 17 章）的微观体现。

**命名空间也有 Rancher 的 Annotation**（实测 `lab`）：

```bash
kubectl get ns lab -o json | jq -r '.metadata.annotations|keys[]'
# 输出:
# cattle.io/status
# lifecycle.cattle.io/create.namespace-auth
```

### 3.5 用户自定义（随你写）

只要 key 符合规则（建议带自己团队的前缀，如 `myteam.io/`）：

```bash
kubectl -n lab annotate cm app-config description="我的备注"
configmap/app-config annotated

# 验证（dry-run 演示）:
kubectl -n lab annotate cm app-config --dry-run=client description="我的备注" -o jsonpath='{.metadata.annotations}'
# 输出: {"description":"我的备注"}
```

---

## 4. Annotation 在 ingress-nginx 的经典用法（课外重点）

很多工具把"功能开关"全做成 Annotation。**ingress-nginx 是最大用户**（本集群已装）：

| Annotation | 作用 |
|-----------|------|
| `nginx.ingress.kubernetes.io/rewrite-target` | 路径重写（去掉前缀再转发） |
| `nginx.ingress.kubernetes.io/ssl-redirect` | 强制 HTTPS |
| `nginx.ingress.kubernetes.io/proxy-body-size` | 允许的上传体积 |
| `nginx.ingress.kubernetes.io/canary` | 金丝雀发布权重 |
| `nginx.ingress.kubernetes.io/affinity` | 会话保持 |

> 这就是"**改 Annotation = 改行为**"的典型：对同一个 Ingress 对象加一条注解，ingress-nginx 控制器 watch 到后重写 nginx 配置。第 04 章的 Ingress 就是靠这类注解做高级路由（可自行 `kubectl -n lab get ing -o yaml` 验证）。

---

## 5. Annotation 的查看与操作（全命令）

### 5.1 查看

```bash
kubectl get <res> <name> -o yaml                # 完整 YAML（含 annotations）
kubectl describe <res> <name>                   # 摘要视图（Annotations: 段）
kubectl get <res> <name> -o jsonpath='{.metadata.annotations}'          # 全部（JSON）
kubectl get <res> <name> -o jsonpath='{.metadata.annotations.前缀\.key}' # 单条（点需转义）
kubectl get <res> -A -o json | jq '.items[].metadata.annotations'       # 批量
```

本环境实测（单条查询带点 key 的转义写法）：

```bash
kubectl -n lab get pvc nginx-data -o jsonpath='{.metadata.annotations.volume\.kubernetes\.io/selected-node}'
# 输出: k3s-demo-server-1
```

### 5.2 添加 / 修改 / 删除

```bash
kubectl annotate <res> <name> key=value                  # 添加；key 已存在会报错
kubectl annotate <res> <name> key=新值 --overwrite       # 覆盖（修改）
kubectl annotate <res> <name> key-                      # 删除（key 后跟 -）
kubectl annotate <res> <name> key=value --dry-run=client # 预演
kubectl annotate --all deploy -n lab xxx=1              # 批量（慎用）
```

实测（在临时 CM 上演练后可清理）：

```text
kubectl -n lab annotate cm app-config description="我的备注"
configmap/app-config annotated
kubectl -n lab annotate cm app-config description="新备注" --overwrite
configmap/app-config annotated
kubectl -n lab annotate cm app-config description-
configmap/app-config annotated
```

> **--overwrite 必备**：不给它，给已存在的 key 赋新值会直接报错（和 label 一样）。`kubectl label` / `kubectl annotate` 行为完全对称（第 16 章 §3.6）。

---

## 6. Annotation 实战深挖：三个场景串起来

### 场景 A：查机子当初怎么配的（排障）

```bash
kubectl get node k3s-demo-server-1 -o jsonpath='{.metadata.annotations.k3s\.io/node-args}'
```

### 场景 B：备份/恢复与审计（apply 的记忆）

`last-applied-configuration` 让"我这文件上次到底 apply 了什么"可追溯：

```bash
kubectl -n lab get deploy nginx-demo \
  -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}' \
  | python3 -m json.tool > /tmp/last-applied.json     # 还原上次 apply 的完整内容
```

> 注意：它是"上次 apply 的**本地文件**内容"（不含系统回写字段），与 `-o yaml`（完整现状）不同——只想还原自己当初的声明时用前者更干净。

### 场景 C：查数据落点（与第 17 章联动）

```bash
kubectl -n lab get pvc nginx-data -o jsonpath='{.metadata.annotations.volume\.kubernetes\.io/selected-node}'
# k3s-demo-server-1 → 数据在这台节点，drain/备份前先看它
```

**三者串起来 = 一份"对象病历"**：启动参数（`k3s.io/node-args`）+ 变更记录（`revision`/`restartedAt`）+ 数据落点（`selected-node`），全是 Annotation。

---

## 7. Rancher 界面对照

- **任何资源 → View/Edit YAML**：Annotations 就在 `metadata` 下，与 kubectl 同源
- **编辑 Annotation**：Edit YAML 里改 `metadata.annotations` 保存，等效 `kubectl annotate --overwrite`
- **Rancher 自己大量写 Annotation**：`field.cattle.io/publicEndpoints`（UI 上的"端点暴露到哪"）、`management.cattle.io/pod-limits`（资源配额视图）、`cattle.io/status`（命名空间初始化状态）——**Rancher UI 的许多状态展示其实就是在读 Annotation**
- **Launch kubectl**：可直接跑本章全部命令

---

## 8. 小结

- Annotation = **非标识性 key/value 便签**：用来"读"和"配置驱动"，**不参与选择**（与 Label 最大区别）
- 任意字符串、总量 ≤256KB、key 前缀即"署名"（认出谁写的）
- 六大来源：kubectl 工具、K8s 核心、k3s/flannel/etcd、Rancher、Prometheus 等第三方、用户
- 本集群反差：**Pod 侧极少（监控+工具），Node 侧 16 个 key（身份/网络/存储）**——Annotation 分布即"资源落位"的微观体现
- 操作：`kubectl annotate`（加/改/删/预演）+ 查询（yaml/describe/jsonpath 转义写法）
- 实战：`k3s.io/node-args`（启动参数）、`volume.kubernetes.io/selected-node`（数据落点）、`last-applied-configuration`（备份审计）、ingress-nginx 注解（改注解=改行为）
- 选型一句话：**要"选"用 Label，要"记/配"用 Annotation**

---

## 动手练习

1. `kubectl get nodes -o json` 用 jq 列出 agent-1 的全部 annotation key，找出与 server-1 不同的项（提示：etcd 相关）并解释为什么。
2. 给 `lab/app-config` 加三个 annotation（带 `--overwrite` 改一次、删除一个、`--dry-run` 预演一个），最后 `kubectl describe cm app-config` 观察 Annotations 段。完成后清理。
3. 用 `kubectl annotate` 给 `nginx-ing` 加一条 `nginx.ingress.kubernetes.io/rewrite-target: /`（⚠️ 会改变入口转发行为，练完删除），然后 `kubectl -n lab get ing -o yaml | grep rewrite` 验证"改注解=改行为"。
4. 查看 `lab/nginx-demo` 的 `deployment.kubernetes.io/revision` 与 `kubectl.kubernetes.io/restartedAt`，再 `kubectl rollout restart` 一次，比较两个值的变化，解释哪个是控制器写的。
5. 深度题：为什么 `kubectl apply` 之后 `last-applied-configuration` 是**必须的**？（提示：第 15 章 apply 三方合并；没有它，apply 无法知道"上次我声明过什么"）

<details>
<summary>参考答案</summary>

1. agent-1 没有 `etcd.k3s.cattle.io/*` 三个 annotation——因为 etcd 只跑在 server 节点（嵌入式 etcd），agent 不承载。这正好印证第 17 章"k3s server 进程只在 server 节点"。
2. `annotate` 加/改/删/预演全流程走一遍即可；describe 的 `Annotations:` 段会以 `key: value` 形式列出。清理用 `key-` 去掉即可。
3. 加 `rewrite-target: /` 后 Ingress 控制器会重写 nginx 配置（前缀被剥掉再转发）；`kubectl get ing -o yaml | grep rewrite` 能看到该注解已写入对象。删除后恢复原配置。
4. `revision` 由 Deployment 控制器写（每次模板变更 +1，2→3）；`restartedAt` 由 kubectl 写（rollout restart 时打时间戳，**正是它的注入导致模板哈希变化从而触发滚动**，revision 才变成 3）。
5. `last-applied-configuration` 是 apply 三方合并（上次 apply 的 / 服务器现状 / 本次）的"上次"基准。没有它，apply 无法区分"服务器上的字段是我曾经声明的（应随我删）"还是"别人/系统后来加的（应保留）"——会错误覆盖。这也是 `kubectl create`（无此 annotation）与 `apply` 行为差异的根源之一。
</details>