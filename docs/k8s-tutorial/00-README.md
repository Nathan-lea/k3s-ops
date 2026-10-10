# K8s 学习教程（基于 k3s-ops 实战环境）

> 目的：利用本项目真实的 k3s 集群、Rancher 界面与 kubectl 命令行，由浅入深、由简到繁地学习和掌握 Kubernetes。
> 所有章节的"实站对照"均来自本集群真实执行输出，可直接复现。

---

## 环境速览

| 项目 | 值 |
|------|-----|
| 集群 | k3s-demo（k3s v1.30.2+k3s2，嵌入式 etcd） |
| 节点 | k3s-demo-server-1（192.168.56.10，控制面）<br>k3s-demo-agent-1（192.168.56.20，工作节点） |
| Ingress | nginx-ingress（HTTP :30080 / HTTPS :30444） |
| 管理 UI | Rancher（https://192.168.56.10:30443） |
| kubectl 用法 | `kubectl --kubeconfig ./kubeconfig <cmd>`（项目根目录） |

**注意**：教程中命令统一使用 `kubectl --kubeconfig ./kubeconfig`，为简洁可先执行：

```bash
export KUBECONFIG=./kubeconfig
```

之后命令可直接写作 `kubectl get nodes`。

---

## 学习路径（推荐顺序）

```
入门阶段                      深入阶段                      进阶阶段
┌──────────────┐   ┌──────────────────────┐   ┌──────────────────────┐
│ 01 基础概念   │ → │ 05 存储与配置         │ → │ 09 实战演练(10+实验)  │
│ 02 架构全景   │ → │ 06 调度与扩缩容       │ → │ 10 进阶之路(生产化)   │
│ 03 工作负载   │ → │ 07 安全与RBAC         │   │ 11 iptables 与Service│
│ 04 网络与通讯 │ → │ 08 监控与备份         │   │ 12 etcd 深入使用      │
└──────────────┘   └──────────────────────┘   │ 13 Label 与选择器      │
                                              │ 14 kubectl 输出定制     │
                                              │ 15 资源定义文件详解      │
                                              │ 16 kubectl 命令集合      │
                                              │ 17 资源落位详解          │
                                              │ 18 Annotation 详解       │
                                              │ 19 服务发现详解          │
                                              │ 20 存储卷挂载详解        │
                                              │ 21 四层与七层转发详解    │
                                              │ 22 eBPF 与 Cilium 详解   │
                                              │ 23 CNI 插件体系          │
                                              │ 24 Helm 与 Chart 详解    │
                                              │ 25 Kustomize 与 Helm 对比│
                                              │ 26 GitOps 与 Fleet/ArgoCD│
                                              │ 27 GitOps 仓库组织       │
                                              │ 28 GitOps 与 Helm 实战   │
                                              │ 29 私有仓库认证与安全    │
                                              │ 30 混用 Kustomize/Helm   │
                                              │ 31 Ingress 与证书管理   │
                                              └──────────────────────┘
```

### 章节依赖关系

| 章节 | 前置依赖 | 核心收获 |
|------|---------|---------|
| 00 README | 无 | 环境准备、全局视角 |
| 01 基础概念 | 00 | 容器/K8s 是什么、名词解释 |
| 02 架构全景 | 01 | 控制面/工作节点、每组件的角色与通讯总图 |
| 03 工作负载 | 02 | 如何部署和管理应用（Pod/Deployment/...） |
| 04 网络与通讯 | 03 | Service/Ingress/DNS、集群内外流量路径 |
| 05 存储与配置 | 03 | ConfigMap/Secret/PV/PVC |
| 06 调度与扩缩容 | 03 | 调度器、污点/亲和、HPA |
| 07 安全与RBAC | 02 | 认证鉴权、ServiceAccount、权限控制 |
| 08 监控与备份 | 03 | 健康检查、etcd 备份、事件与日志 |
| 09 实战演练 | 01-08 | 综合实验巩固所有知识 |
| 10 进阶之路 | 09 | 生产化方向、CKA 备考、官方文档索引 |
| 11 iptables 与Service | 04 | kube-proxy 用 iptables 实现 Service 的原理与规则追踪 |
| 12 etcd 深入使用 | 08 | etcdctl 连接/读取/维护、快照与恢复完整流程 |
| 13 Label 与选择器 | 03/04/06 | Label 概念、系统自带标签与默认值、选择器实战 |
| 14 kubectl 输出定制 | 03 | -o 各格式、custom-columns 自定义列、资源字段结构 |
| 15 资源定义文件详解 | 03/13/14 | 五大顶层字段、全量资源纵览、关联性、修改方式 |
| 16 kubectl 命令集合 | 13/14/15 | 六大类命令、语法/选项/子命令、排障链路 |
| 17 资源落位详解 | 15、04/06/08 | 跨节点三层、归属vs引用、资源存亡规律、排障四问 |
| 18 Annotation 详解 | 13/15/17 | 概念与选型、六大来源、前缀识别、annotate 操作、实战场景 |
| 19 服务发现详解 | 04/11/13 | 四大件原理、DNS 命名体系、Endpoints-Slices、DNS vs 环境变量、四层排障 |
| 20 存储卷挂载详解 | 05/17/18 | 六类卷全览、生命周期三层级、PV/PVC/SC 原理、挂载细节、排障四层 |
| 21 四层与七层转发详解 | 04/11/19 | L4/L7 概念对比、Service 三形态、Ingress 路由、配合模式、分层排障 |
| 22 eBPF 与 Cilium 数据面 | 11/21 | eBPF 原理、kube-proxy 痛点、Cilium socket LB/策略/Hubble、三代数据面对比 |
| 23 CNI 插件体系 | 04/22 | CNI 规范/流程、flannel/Calico/Cilium 对比、本集群 flannel 全解剖、切换与排障 |
| 24 Helm 与 Chart | 03/15 | Chart/values/生命周期、服务转 Chart 三步、install→upgrade→rollback→uninstall 闭环 |
| 25 Kustomize 与 Helm 对比 | 03/15/24 | base+overlay 覆盖模型、四大魔法、kubectl -k 渲染/落地、Helm vs Kustomize 选型 |
| 26 GitOps：Fleet 与 ArgoCD | 15/24/25 | GitOps 四原则、Fleet/ArgoCD 架构、真实闭环（同步/漂移修复/回滚）、选型对比 |
| 27 GitOps 多服务与多环境仓库组织 | 24/25/26 | 两类仓库、三个决策问题、结构 A/B/C、目录 vs 分支、多服务两条路线实测、复用与反模式 |
| 28 GitOps 使用 Helm Chart 完整实战 | 24/25/26/27 | fleet.yaml/options、值合并顺序、共享 chart 多环境（显式 bundles）、chart 自包含与 valuesFiles 两个真实坑、对比选型 |
| 29 GitOps 私有仓库认证与安全 | 26/27/28 | Fleet 三种 Git 认证（HTTP/SSH/GitHub App）、clientSecretName、CA/TLS、私有 Helm 仓库认证、Policy 与安全最佳实践 |
| 30 混用 Kustomize 与 Helm | 25/27/28 | Fleet 按 path 判定工具、一个 GitRepo 混用 Kustomize/Helm/纯 YAML 三种模式实测、同一 path 混用的真实坑、fleet.yaml 显式指定、与 ArgoCD 对照及选型 |
| 31 Ingress 深入与证书管理 | 04/21 | IngressClass/Controller 职责、pathType 与转发行为、rewrite/CORS/限流/会话保持/金丝雀注解全实测（含 4 个真实坑）、cert-manager 私有 CA 证书全流程、HTTPS/308/续期、排障清单 |

---

## 阅读约定

1. **命令**：`kubectl` 前缀的命令可直接复制执行；输出中 `...` 表示省略无关字段。
2. **输出**：所有"预期输出"均为本集群真实采集，环境不同会有差异（IP/时间/名称）。
3. **Rancher 对照**：每章给出在 Rancher UI 中查看同一对象的路径。
4. **练习**：章节末尾练习先独立完成，参考答案在文末。
5. **写作模板**（每章六段）：
   - 本章目标 → 概念讲解 → 组件作用与通讯 → 本集群实站对照 → Rancher 界面 → 动手练习

---

## 如何配合使用

- **跟着命令敲一遍**：教程命令都是幂等的，可放心执行；`kubectl describe`/`get` 只读安全。
- **对照 Rancher**：浏览器打开 `https://192.168.56.10:30443`（admin/admin），在左侧菜单找对应资源。
- **破坏性操作有标注**：标 ⚠️ 的命令会删除/修改资源，练习类已隔离到独立 namespace。
- **建议独立 namespace**：练习建议新建 `kubectl create ns lab`，用 `-n lab` 隔离，避免污染现有资源。

---

## 章节导航

| 文件 | 标题 |
|------|------|
| [01 基础概念](01-基础概念.md) | 容器→K8s→k3s，集群是什么 |
| [02 架构全景](02-架构全景.md) | 全部组件、角色与通讯总图 |
| [03 工作负载](03-工作负载.md) | Pod/Deployment/StatefulSet/... 部署管理 |
| [04 网络与通讯](04-网络与通讯.md) | Service/Ingress/DNS、流量路径 |
| [05 存储与配置](05-存储与配置.md) | ConfigMap/Secret/PV/PVC |
| [06 调度与扩缩容](06-调度与扩缩容.md) | 调度器/污点/亲和/HPA |
| [07 安全与RBAC](07-安全与RBAC.md) | 认证/授权/ServiceAccount |
| [08 监控与备份](08-监控与备份.md) | 健康检查/etcd备份/事件日志 |
| [09 实战演练](09-实战演练.md) | 综合实验 |
| [10 进阶之路](10-进阶之路.md) | 生产化/CKA/资源索引 |
| [11 iptables 与Service](11-iptables与Service.md) | kube-proxy 的 iptables 转发实现 |
| [12 etcd 深入使用](12-etcd深入使用.md) | etcdctl 读取/维护/备份恢复 |
| [13 Label 与选择器](13-Label与选择器.md) | 标签概念/系统自带标签/选择器实战 |
| [14 kubectl 输出定制](14-kubectl输出定制.md) | -o 格式/custom-columns 自定义列 |
| [15 资源定义文件详解](15-资源定义文件详解.md) | 声明式 API、五段骨架、全量资源、关联性 |
| [16 kubectl 命令集合](16-kubectl命令集合.md) | 六大类命令、语法选项、排障链路 |
| [17 资源落位详解](17-资源落位详解.md) | 三世界模型、跨节点层次、依附关系、排障四问 |
| [18 Annotation 详解](18-Annotation详解.md) | label 对比、六大来源、前缀识别、annotate 全命令 |
| [19 服务发现详解](19-服务发现详解.md) | 四大件原理、DNS 命名体系、Endpoints 生命周期、四层排障 |
| [20 存储卷挂载详解](20-存储卷挂载详解.md) | 六类卷全览、生命周期、PV/PVC/SC 原理、挂载排障 |
| [21 四层与七层转发详解](21-四层与七层转发详解.md) | L4/L7 对比、Service/Ingress 实现、配合模式、排障 |
| [22 eBPF 与 Cilium 数据面详解](22-eBPF与Cilium数据面详解.md) | eBPF 原理、Cilium 数据面、三代对比、识别数据面 |
| [23 CNI 插件体系详解](23-CNI插件体系详解.md) | CNI 规范、三大插件对比、flannel 实站、切换排障 |
| [24 Helm 与 Chart 详解](24-Helm与Chart详解.md) | Chart 概念、服务转 Chart、生命周期闭环、release 状态 |
| [25 Kustomize 与 Helm 对比详解](25-Kustomize与Helm对比详解.md) | base+overlay、四大魔法、kubectl -k、选型与排障 |
| [26 GitOps：Fleet 与 ArgoCD 详解](26-GitOps-ArgoCD与Fleet详解.md) | GitOps 四原则、Fleet 实测闭环、漂移修复、对比选型 |
| [27 GitOps 多服务与多环境仓库组织](27-GitOps多服务与多环境仓库组织.md) | 两类仓库、三个决策、结构 A/B/C、多服务两路线实测、复用与反模式 |
| [28 GitOps 使用 Helm Chart 完整实战](28-GitOps与Helm完整实战.md) | fleet.yaml/options、值合并顺序、共享 chart 多环境、两个真实坑、对比选型 |
| [29 GitOps 私有仓库认证与安全](29-GitOps私有仓库认证与安全.md) | 三种 Git 认证、clientSecretName 实测、CA/TLS、私有 Helm 仓库、Policy 与安全 |
| [30 混用 Kustomize 与 Helm](30-混合使用Kustomize与Helm.md) | Fleet 按 path 判定、Kustomize/Helm/纯 YAML 三模式混合实测、同一 path 混用的坑、fleet.yaml 显式指定 |
| [31 Ingress 深入与证书管理](31-Ingress深入实战与证书管理.md) | IngressClass/Controller、注解家族全实测与真实坑、cert-manager 私有 CA 证书链路、HTTPS/续期、排障清单 |