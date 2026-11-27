# k3s 跨 minor 逐级升级方案（步骤 4，设计稿）

> 状态：**设计稿，未执行**。任何执行前必须在隔离环境完成步骤 3 回滚演练，并重新核对官方兼容矩阵。  
> 日期：2026-11-27  
> 当前基线：k3s `v1.30.14+k3s2`，单 server + 单 agent，embedded etcd；Rancher 2.14.1、cert-manager v1.20.2、ingress-nginx controller 1.11.0、NGF 2.4.2、Kyverno 1.19.1。  
> 输入：`docs/k3s-upgrade-compatibility-matrix.md`、`docs/k3s-ops-upgrade-wrapper-comparison.md`、`docs/k3s-upgrade-rollback-rehearsal-design.md`、`docs/k8s-tutorial/57-集群升级实战.md`。

## 1. 结论先行

- **不能直接跨 minor**。从 `v1.30.14+k3s2` 到更高版本必须 `1.30 -> 1.31 -> 1.32 -> ...` 每跳升级、验收、留证。
- **不能只升 k3s**。当前已安装组件的官方支持范围与目标 k3s minor 存在错位：ingress-nginx 1.11.0 最高支持 K8s 1.30；cert-manager 1.20.x 支持 1.32-1.35；Rancher 2.14.1/Kyverno 1.19.x 支持 1.33-1.35。 
- **建议阶段目标：先规划到 1.33，分三跳完成；1.34/1.35 作为后续阶段**。1.33 是第一个同时进入 Rancher 2.14.1 与 Kyverno 1.19.x 声明支持范围的候选点，但前提是 ingress-nginx/cert-manager 已先完成兼容升级。
- **执行前置门禁**：完成隔离回滚演练（R1/R3 最低）；确认 Rancher/组件升级路径；备份与业务窗口就绪；明确“失败即止损”负责人。

## 2. 目标版本阶梯（候选）

| 跳次 | k3s 目标 | 通道快照（2026-11-27） | 进入该跳前必须处理 | 阶段结论 |
|---:|---|---|---|---|
| 0 | `v1.30.14+k3s2` | v1.30 latest | 当前基线 | 已完成 |
| 1 | `v1.31.14+k3s1` | v1.31 latest | ingress-nginx 1.11.0 超出支持；Rancher/cert-manager/Kyverno 仍不在声明范围 | **有条件，需组件先行** |
| 2 | `v1.32.13+k3s1` | v1.32 latest | cert-manager 1.20.x 进入支持范围；Rancher/Kyverno 仍不在声明范围 | **有条件** |
| 3 | `v1.33.13+k3s2` | v1.33 latest | Rancher 2.14.1/Kyverno 1.19.x 进入声明范围；仍需确认其实际可用 | **阶段目标候选** |
| 4 | `v1.34.13+k3s1` | v1.34 latest | Rancher 2.14.1 仍覆盖上限内？需复核；组件联动升级 | 后续阶段 |
| 5 | `v1.35.10+k3s1` | v1.35 latest | Rancher 2.14.1 支持上限 1.35；再往上需 Rancher 升级 | 后续阶段上限候选 |

> 通道版本为采集快照，执行时必须重新抓取 `https://update.k3s.io/v1-release/channels`。

## 3. 组件处理策略

| 组件 | 当前 | 策略 | 说明 |
|---|---|---|---|
| ingress-nginx | controller 1.11.0/chart 4.11.0 | **1.31 前必须升级或替换** | 官方支持表最高 1.30。项目已归档，长期应评估迁移（如 Gateway API/NGF 或其他 ingress）；短期可评估可用的后续 patch/chart，但必须核对 K8s 支持。 |
| cert-manager | v1.20.2 | **1.32 前升级到支持 1.31/1.32 路径的版本，或接受非支持窗口并验证** | 1.20.x 官方声明 1.32-1.35；跨 1.31 时有支持缺口。可考虑升级到同时覆盖目标窗口的较新 cert-manager，并核对 CRD/API 变更。 |
| Rancher | 2.14.1 | **单独决策** | 2.14.1 支持 1.33-1.35。若坚持 Rancher 管理面在支持矩阵内，1.30-1.32 期间 Rancher 对该 k3s 版本不在支持范围；可选：先升 Rancher 到支持更低/更宽范围版本（若存在）或接受管理面风险并限制操作。 |
| Fleet/webhook/turtles/SUC | Rancher 2.14.1 附带 | **随 Rancher 联动** | 不单独漂移。 |
| Kyverno | 1.19.1 | **1.33 前升级/验证** | 1.19 支持 1.33-1.35；1.31/1.32 有支持缺口。升级时注意 webhook Fail、agent 单点、策略兼容性。 |
| NGF | 2.4.2 | **每跳验收，可暂不先升** | 支持 1.25+，相对宽松。 |
| k3s bundled (CoreDNS/metrics-server/local-path/traefik disabled) | 随 k3s | **随 k3s 升级验收** | 关注 CoreDNS/metrics-server 行为与资源。 |

## 4. 推荐执行顺序（单跳模板）

每一跳都按固定模板执行，不合并步骤：

1. **Freeze**：确认无其他变更；记录基线（nodes/pods/helm/events/snapshots/disk）。
2. **Compatibility gate**：复核该跳目标 k3s + 所有关键组件支持矩阵；有阻塞项则先处理组件。
3. **Backup**：etcd snapshot + 旧 k3s 二进制备份 + 关键配置/Helm values/CRD 资源导出。
4. **Component pre-action**：必要时升级 ingress-nginx/cert-manager/Kyverno/Rancher；或按预案临时摘除 Kyverno webhook（维护窗口，记录恢复步骤）。
5. **Upgrade k3s server**：下载目标版本、安装、重启、等待 Ready/API。
6. **Validate control plane**：API、etcd、系统 Pod、节点、事件、证书/ServiceAccount 基本功能。
7. **Upgrade k3s agents（逐台）**：必要时 cordon/drain（本集群单 agent 需评估业务影响）；升级、重启、uncordon。
8. **Post-upgrade validation**：全量节点/Pod/Helm/Ingress/Gateway/Rancher/Kyverno/存储 smoke。
9. **Record**：版本、快照、命令、异常、回滚点、结论；回写 nodes.yml/group_vars/教程/架构文档。
10. **Soak**：观察窗口后再进入下一跳。

## 5. 分跳建议

### 跳 1：1.30.14+k3s2 -> 1.31.14+k3s1（高风险准备跳）

**进入条件**：

- ingress-nginx 已有明确处理方案：升级到支持 1.31 的版本，或迁移到 NGF/其他 ingress，并完成数据面验证。
- cert-manager/Kyverno/Rancher 的“非支持窗口”风险被接受或有缓解方案。
- 已完成隔离环境 R1/R3。

**额外风险**：

- ingress-nginx 1.11.0 是明确阻塞。
- Rancher 管理面可能进入非支持组合；禁止在该窗口做 Rancher 重大变更。
- Kyverno 在 agent 重启时可能拦写。

**验收**：

- 两节点 Ready，版本 1.31.x。
- ingress 数据面 smoke（HTTP/HTTPS/现有 Ingress 规则）。
- cert-manager Certificate/Issuer 基本 reconcile。
- Kyverno webhook/策略 smoke（创建合规/不合规 Pod）。
- Rancher UI/API 基本可访问（若保留）。

### 跳 2：1.31.x -> 1.32.13+k3s1（组件收敛跳）

**进入条件**：

- 跳 1 稳定观察完成。
- cert-manager 已在支持范围或已升级到覆盖 1.32 的版本。
- Rancher/Kyverno 非支持窗口风险仍可控。

**重点**：

- 复核 k3s 1.32 release notes 中的弃用/行为变化。
- 复核 cert-manager CRD 升级要求。
- 继续保持 ingress 已处理后的回归验证。

### 跳 3：1.32.x -> 1.33.13+k3s2（阶段目标）

**进入条件**：

- 跳 2 稳定。
- Rancher 2.14.1/Kyverno 1.19.x 支持矩阵在执行日再次复核为覆盖 1.33。

**重点**：

- 这是管理面/策略组件回到声明支持范围的关键跳。
- 完成后可作为阶段里程碑：更新基线文档，决定是否继续 1.34/1.35。

## 6. 验收清单（每跳）

```bash
export KUBECONFIG=./kubeconfig
kubectl get nodes -o wide
kubectl get pods -A
kubectl get events -A --sort-by=.lastTimestamp | tail -n 50
helm list -A
kubectl get certificates,issuers,clusterissuers -A
kubectl get ingress -A
kubectl get gateway,httproute -A  # 若已部署 Gateway API
kubectl get validatingwebhookconfiguration,mutatingwebhookconfiguration | grep kyverno || true
```

业务 smoke 最低要求：

- 现有 Ingress 域名/NodePort 可访问。
- Rancher UI 可登录（非支持窗口仅做只读 smoke）。
- Kyverno 审计/拦截行为符合预期。
- 一个测试 PVC Pod 可创建、写入、读取。

## 7. 止损与回滚

- **二进制回退**：仅适用于未发生不可逆数据/CRD/schema 变化的失败；先在隔离环境验证。
- **etcd restore**：破坏性整集群回滚；使用升级前快照；必须理解其会回滚集群对象状态，不自动修复 PV 数据一致性。
- **禁止**在未隔离演练的情况下把 restore 当“保险按钮”。
- **失败即止损条件**：控制面不可恢复、etcd 不健康、关键组件 CRD 升级失败且无回退路径、数据面大面积异常。

## 8. 本仓库封装的使用边界

- `k3s-ops.sh upgrade -v`：仅作为薄封装执行器；不提供快照、兼容门禁、全量验收、回滚。详见 `docs/k3s-ops-upgrade-wrapper-comparison.md`。
- `k3s-ops.sh restore -f` / `k3s-restore.yml`：有潜在行为风险（如 etcd 目录已存在时的 `creates` 跳过语义），必须先在隔离环境验证。详见 `docs/k3s-upgrade-rollback-rehearsal-design.md`。

## 9. 建议的下一步（执行前）

1. 评审并确认阶段目标：`1.33` 还是更保守的 `1.31`。
2. 做 ingress-nginx 处置专项：升级、替换或接受风险。
3. 在隔离 Vagrant 环境完成 R1/R3，补充 R4 restore 封装验证。
4. 产出可执行 runbook（含命令、门禁、验收、回滚、负责人/窗口）。
5. 只有在以上完成后，才预约真实集群升级窗口。
