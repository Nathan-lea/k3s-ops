# k3s 跨 minor 升级 - 版本兼容矩阵（只读调研）

> 状态：**只读调研，不改集群**。  
> 采集日期：2026-11-27  
> 当前集群基线：k3s `v1.30.14+k3s2`（2 节点：server-1 192.168.56.10，agent-1 192.168.56.20，embedded etcd，单 server）  
> 目的：为 backlog 34 后续工作（跨 minor 逐级升级方案、回滚实操/隔离演练、`k3s-ops.sh upgrade -v` 封装对照）提供版本兼容事实输入。

## 1. 范围与结论

### 1.1 调研范围

- **k3s 目标通道**：`v1.30`~`v1.37`（来自 `https://update.k3s.io/v1-release/channels`）。
- **关键组件**：Rancher、Fleet、rancher-webhook/turtles（随 Rancher 生态）、system-upgrade-controller、cert-manager、ingress-nginx、NGINX Gateway Fabric (NGF)、Kyverno。
- **不在本矩阵展开**：coredns/metrics-server/local-path-provisioner（随 k3s bundled）、教程实验命名空间中的临时 workload。

### 1.2 先行结论（重要）

1. **当前已安装的多个组件，其官方支持的 Kubernetes 版本范围高于当前集群 `v1.30`**。它们当前“能跑”不等于“在支持矩阵内”。跨 minor 升级前必须按组件矩阵逐级评估，不能只看 k3s 能否升级。
2. **Rancher 2.14.1** 官方支持矩阵为 k3s/RKE2 `v1.33-v1.35`（SUSE/Rancher support matrix / release notes 摘要）。若目标是跨 minor 升级 k3s，Rancher 很可能需要**先升级或同步升级**，否则管理面兼容性无保证。
3. **ingress-nginx controller v1.11.0** 官方支持表仅到 Kubernetes `1.30`；升级到 k3s `v1.31` 前应先评估 ingress-nginx 升级。另需注意 ingress-nginx 项目已归档（2026-03-24），后续维护策略要单独决策。
4. **cert-manager v1.20.2** 官方支持 `Kubernetes 1.32 → 1.35`；**Kyverno 1.19.1** 官方支持 `Kubernetes 1.33 - 1.35`。它们对“先升 k8s 到 1.31/1.32 再逐级补组件”的路径不友好，需要组件先行/并行升级规划。
5. **NGF 2.4.2** 官方支持 `Kubernetes 1.25+`，对 1.31~1.35 的 k8s minor 升级相对宽松，但仍需关注 Gateway API/NGINX Agent/数据面兼容。
6. **建议**：在做任何跨 minor 集群升级前，先产出“组件升级顺序 + 每级验收门禁”设计；不要直接在当前教学集群连续跨 minor。

## 2. 当前集群组件快照（2026-11-27 只读采集）

| 组件 | 当前版本 | 命名空间 | 来源/证据 | 备注 |
|---|---|---|---|---|
| k3s/Kubernetes | `v1.30.14+k3s2` | - | `kubectl get nodes -o wide` | 2 节点 Ready，containerd `1.7.27-k3s1` |
| Rancher | `rancher-2.14.1` / `v2.14.1` | `cattle-system` | `helm list -A` | Helm 状态 `failed`，但 Pod 当前 Running（历史状态，验收以功能为准） |
| Fleet | `fleet-109.0.1+up0.15.1` / `0.15.1` | `cattle-fleet-system` | `helm list -A` | 随 Rancher 生态部署 |
| Fleet Agent Local | `fleet-agent-local-v0.0.0+s-...` | `cattle-fleet-local-system` | `helm list -A` | 本地 agent chart |
| system-upgrade-controller | `109.0.1` / `v0.19.1` | `cattle-system` | `helm list -A` | Rancher 管理的 chart |
| rancher-webhook | `109.0.1+up0.10.1` / `0.10.1` | `cattle-system` | `helm list -A` | Rancher 组件 |
| rancher-turtles | `109.0.1+up0.26.1` / `0.26.1` | `cattle-turtles-system` | `helm list -A` | CAPI/Turtles 组件 |
| cert-manager | `v1.20.2` | `cert-manager` | `helm list -A` | chart/app 均 `v1.20.2` |
| ingress-nginx | chart `4.11.0` / controller `1.11.0` | `ingress-nginx` | `helm list -A` | 当前对外 HTTP/HTTPS 入口 |
| NGINX Gateway Fabric | chart `2.4.2` / app `2.4.2` | `nginx-gateway` | `helm list -A` | 教程 37 章部署 |
| Kyverno | chart `3.9.1` / app `v1.19.1` | `kyverno` | `helm list -A`, `kubectl get pods -n kyverno` | 4 控制器，全部在 `agent-1`，webhook `failurePolicy=Fail` |

## 3. k3s 目标版本通道（采集快照）

来源：`https://update.k3s.io/v1-release/channels`（2026-11-27 采集）

| 通道 | 最新版本 | 备注 |
|---|---:|---|
| stable | `v1.37.2+k3s1` | 当前 stable |
| latest | `v1.37.2+k3s1` | 当前 latest |
| v1.30 | `v1.30.14+k3s2` | 当前集群所在 minor，已是该通道最新 |
| v1.31 | `v1.31.14+k3s1` | 下一跳候选 |
| v1.32 | `v1.32.13+k3s1` | 逐级候选 |
| v1.33 | `v1.33.13+k3s2` | 逐级候选 |
| v1.34 | `v1.34.13+k3s1` | 逐级候选 |
| v1.35 | `v1.35.10+k3s1` | 逐级候选 |
| v1.36 | `v1.36.6+k3s1` | 逐级候选 |
| v1.37 | `v1.37.2+k3s1` | 逐级候选 |

> 升级规则：Kubernetes/k3s 不支持跳 minor；每跳都要备份、升级、验收、记录。

## 4. 组件兼容矩阵（面向跨 minor 规划）

> 说明：以下“支持范围”是官方文档/发布说明在采集日的陈述；“对本集群影响”是基于当前已安装版本的规划判断，不是厂商声明。实际升级前必须复核当时最新官方矩阵。

| 组件 | 当前版本 | 官方支持的 K8s/k3s 范围（采集日） | 对本集群跨 minor 的影响 | 结论 | 建议动作 | 来源 |
|---|---|---|---|---|---|---|
| k3s | `v1.30.14+k3s2` | 逐 minor 升级；不能跳 minor | 从 1.30 到更高版本需 1.31→1.32→... 逐级 | **可升（逐级）** | 先定目标 minor，再做每级门禁 | [K3s Upgrades](https://docs.k3s.io/upgrades) |
| Rancher | `2.14.1` | Rancher 2.14.1 支持矩阵：k3s/RKE2 `v1.33-v1.35`（搜索摘要/SUSE 页面摘要）；release notes 列出 RKE2/K3s `v1.35.3` 默认、`v1.34.6`、`v1.33.10` | 当前 Rancher 2.14.1 **不覆盖** k3s 1.30/1.31/1.32 的支持范围；直接升 k3s 会先进入管理面不支持区间 | **需先升组件/策略决策** | 先决定 Rancher 升级策略：要么维持 k3s 在 Rancher 支持范围内，要么接受管理面“非支持组合”风险并隔离验证 | [Rancher support matrix](https://rancher.com/support-maintenance-terms), [Rancher 2.14.1 release notes](https://documentation.suse.com/cloudnative/rancher-manager/v2.14/en/release-notes/v2.14.1.html) |
| Fleet / rancher-webhook / turtles / system-upgrade-controller | Rancher 2.14.1 附带 chart | 随 Rancher 版本联动 | 不应单独跨大版本漂移；Rancher 升级时一并评估 | **需随 Rancher 一起升级** | 作为 Rancher 升级包一起验收 | Rancher release/support docs |
| cert-manager | `v1.20.2` | `1.20` 支持 Kubernetes `1.32 → 1.35` | 当前在 k3s 1.30 上已超出声明支持下限；升到 1.31 仍不在声明支持范围，升到 1.32 才进入范围 | **需先升组件** | 若要严格按支持矩阵，需规划 cert-manager 与 k3s 的并行/先后升级；至少在 1.32 前完成兼容验证 | [cert-manager Supported Releases](https://cert-manager.io/docs/releases/) |
| ingress-nginx | controller `1.11.0` / chart `4.11.0` | controller v1.11.0 README 支持表：Kubernetes `1.30, 1.29, 1.28, 1.27, 1.26` | **升级到 k3s 1.31 即超出该版本声明支持范围**；这是跨 minor 第一跳的明确风险点 | **阻塞（1.31 前必须处理）** | 在 1.30→1.31 前制定 ingress-nginx 升级/替代方案；同时评估项目归档后的维护策略 | [ingress-nginx v1.11.0 README](https://github.com/kubernetes/ingress-nginx/blob/controller-v1.11.0/README.md) |
| NGINX Gateway Fabric | `2.4.2` | 技术规格表：Gateway API `1.4.1`，Kubernetes `1.25+`，NGINX OSS `1.29.5`，NGINX Plus `R36`，Agent `v3.7.1` | 对 1.31+ k8s minor 相对友好；但 NGF 自身也有更新版本，长期应评估升级 | **可升（需每跳验收）** | 可暂不作为 1.31 第一跳阻塞，但每跳后验证 Gateway/HTTPRoute/数据面 | [NGF Technical specifications](https://docs.nginx.com/nginx-gateway-fabric/overview/technical-specifications/) |
| Kyverno | `1.19.1` / chart `3.9.1` | Kyverno releases 页：1.19 支持 Kubernetes `1.33 - 1.35`（采集日页面摘要） | 当前在 k3s 1.30 上已超出声明支持下限；1.31/1.32 仍不在声明范围 | **需先升组件** | 若保留 Kyverno，需规划其升级窗口；注意 webhook `Fail` 在节点重启/控制器不可用时的拦写风险 | [Kyverno Releases](https://kyverno.io/docs/installation/releases/), [Kyverno 1.19 blog](https://kyverno.io/blog/2026/08/20/announcing-kyverno-release-1.19/) |

## 5. 跨 minor 逐级路径的初步风险评估

> 以下不是执行计划，只是基于矩阵的“能不能直接升”的判断。

| 目标跳 | k3s 目标 | 初步判断 | 主要阻塞/风险 |
|---|---|---|---|
| 1 | `v1.31.14+k3s1` | **有条件** | ingress-nginx 1.11.0 官方支持最高到 1.30；Rancher/cert-manager/Kyverno 当前版本声明支持范围均不覆盖 1.31。需先做组件升级策略和隔离验证。 |
| 2 | `v1.32.13+k3s1` | **有条件** | cert-manager 1.20.x 支持范围从 1.32 开始，但 Rancher 2.14.1/Kyverno 1.19.x 仍不覆盖；Rancher 可能需升级。 |
| 3 | `v1.33.13+k3s2` | **有条件** | 开始进入 Rancher 2.14.1、Kyverno 1.19.x 声明支持范围；但需要确认组件版本是否仍合适、以及中间跳是否已处理。 |
| 4+ | `v1.34+` | **暂不建议直接规划实操** | 需先完成 1.31-1.33 路径验证、组件升级联动、回滚隔离演练；Rancher 2.14.1 上限到 1.35。 |

## 6. 建议的后续动作（对应约定顺序）

1. **已完成（本项）**：版本兼容矩阵（只读）。
2. **下一步 L1 封装对照**：不动集群，梳理 `k3s-ops.sh upgrade -v` 调用链、playbook/role 行为、现有测试覆盖；补充“封装能保证什么/不能保证什么”的实测证据。
3. **隔离回滚演练设计**：先出设计文档，明确快照/二进制回退/cluster-reset restore 的边界；确认后再建临时 Vagrant 隔离环境实操。
4. **跨 minor 逐级升级方案**：基于本矩阵选定目标（建议先评估“到 1.31/1.32/1.33 哪一级作为阶段目标”），给出每级前置检查、组件升级顺序、验收、止损点；确认后才动集群。

## 7. 证据与来源

> 外部来源以采集日可见内容为准；SUSE Rancher support matrix 详情页在本环境返回 403，已用 Rancher docs/release notes 与搜索摘要交叉确认，升级前应人工复核原始 support matrix。

- k3s channels: https://update.k3s.io/v1-release/channels
- k3s upgrades: https://docs.k3s.io/upgrades
- k3s manual upgrade: https://docs.k3s.io/upgrades/manual
- Rancher support matrix: https://rancher.com/support-maintenance-terms
- Rancher 2.14.1 release notes: https://documentation.suse.com/cloudnative/rancher-manager/v2.14/en/release-notes/v2.14.1.html
- cert-manager supported releases: https://cert-manager.io/docs/releases/
- ingress-nginx v1.11.0 README: https://github.com/kubernetes/ingress-nginx/blob/controller-v1.11.0/README.md
- NGINX Gateway Fabric technical specifications: https://docs.nginx.com/nginx-gateway-fabric/overview/technical-specifications/
- Kyverno releases: https://kyverno.io/docs/installation/releases/
- Kyverno 1.19 announcement: https://kyverno.io/blog/2026/08/20/announcing-kyverno-release-1.19/

## 8. 本次采集命令（只读）

```bash
export KUBECONFIG=./kubeconfig
kubectl get nodes -o wide
helm list -A
kubectl get pods -n kyverno -o wide
curl -sS https://update.k3s.io/v1-release/channels
```
