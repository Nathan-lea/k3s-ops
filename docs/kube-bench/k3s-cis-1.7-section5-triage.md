# kube-bench k3s-cis-1.7 Section 5 WARN 分拣

> 日期：2026-11-27  
> 来源：`docs/kube-bench/k3s-cis-1.7-server-2026-11-27.json`（kube-bench v0.10.6, `k3s-cis-1.7`, server 节点）  
> 目的：把 Section 5（Kubernetes Policies）35 条 WARN 分为“教学/现状可接受”“应落地模板”“需人工评估/产品能力”三类，避免把扫描器输出直接当整改清单。

## 判定规则

| 判定 | 含义 | 默认动作 |
|---|---|---|
| **Accept/现状可接受** | 系统组件或教学环境已知约束；强制落地成本高于收益 | 记录原因，不盲改 |
| **Template/应落地模板** | 业务命名空间可通过 PSA/NetworkPolicy/RBAC/SA 模板低成本改进 | 写入 namespace 基线模板，逐步推广 |
| **Assess/需评估** | 依赖组织流程、外部系统或更高权限模型 | 形成评估项，不在当前集群硬做 |

## 5.1 RBAC and Service Accounts

| Check | 判定 | 依据/风险 | 建议动作 | 对应章节 |
|---|---|---|---|---|
| 5.1.1 cluster-admin 仅必要使用 | Assess | 系统组件/Rancher/运维 kubeconfig 可能绑定 cluster-admin；人工审计 | 定期审计 ClusterRoleBinding；人类账号最小权限；记录豁免 | 53,07,32 |
| 5.1.2 最小化 secrets 访问 | Template | secrets get/list/watch 可读取明文 | 业务 Role 避免 `secrets *`；只给所需 name/resourceNames；审计敏感读取 | 50,55,53 |
| 5.1.3 最小化 RBAC 通配符 | Template | `*` 易造成权限膨胀 | 新 Role/ClusterRole 禁止通配符；存量逐步收敛 | 07,53 |
| 5.1.4 最小化 create pods | Assess | CI/CD、operator、kubectl debug 场景需要 | 限制到特定 namespace/SA；禁止普通用户在生产 ns create pods | 07,53 |
| 5.1.5 default SA 不活跃使用 | Template | default SA 易被误用 | 业务 Pod 显式设置 `serviceAccountName`；default SA `automountServiceAccountToken: false` | 50,53 |
| 5.1.6 SA token 仅必要挂载 | Template | 减少 token 暴露面 | 不访问 API 的 Pod 设 `automountServiceAccountToken: false` | 50,53 |
| 5.1.7 避免 system:masters | Assess | 破坏性/紧急运维可能依赖；需严格控制 | 确认无人类常驻成员；仅 break-glass 流程使用 | 53 |
| 5.1.8 限制 Bind/Impersonate/Escalate | Assess | 权限升级高风险，但部分控制器需要 | 审计 RBAC；禁止普通角色拥有这些 verb | 07,53 |
| 5.1.9 最小化创建 PV | Assess | 动态供应通常由 StorageClass/provisioner 处理 | 普通用户不授予 PV create；保留 provisioner | 05,53 |
| 5.1.10 最小化 nodes/proxy | Assess | 可用于节点级访问 | 审计并移除非必要授权 | 53 |
| 5.1.11 最小化 CSR approval | Assess | 证书审批敏感 | 仅平台组件/审批人 | 53 |
| 5.1.12 最小化 webhook 配置访问 | Assess | 可影响准入控制 | 仅平台管理员；变更审计 | 43,53 |
| 5.1.13 最小化 SA token creation | Assess | 可签发 token | 仅必要控制器 | 50,53 |

## 5.2 Pod Security Standards

| Check | 判定 | 依据/风险 | 建议动作 | 对应章节 |
|---|---|---|---|---|
| 5.2.1 至少一个策略控制机制 | Template | 集群有 Kyverno；业务 namespace 未统一 PSA 标签 | 业务 ns 采用 PSA `baseline/restricted` + Kyverno 审计；系统 ns 豁免记录 | 39,43,53 |
| 5.2.2-5.2.13 特权/hostPID/hostIPC/hostNetwork/提权root/能力/hostPath/hostPort 等 | Template | 业务工作负载应默认受限；系统组件按需豁免 | 新业务 ns 先 `warn/audit`，稳定后 `enforce`；用 Kyverno 补充 PSA 未覆盖项 | 39,43,33,53 |

> 注：5.2.3-5.2.5 在本次 kube-bench 报告中为 `No tests defined`，仍按 CIS 意图纳入模板治理。

## 5.3 Network Policies and CNI

| Check | 判定 | 依据/风险 | 建议动作 | 对应章节 |
|---|---|---|---|---|
| 5.3.1 CNI 支持 NetworkPolicy | Accept | 当前 k3s 环境已实测 NetworkPolicy（35 章） | 保持；CNI 变更时复核 | 35,53 |
| 5.3.2 所有 namespace 定义 NetworkPolicy | Template | 大多数 ns 无默认隔离 | 业务 ns 先 default-deny + DNS + 必要 egress/ingress；系统 ns 评估后逐步纳入 | 35,53 |

## 5.4 Secrets Management

| Check | 判定 | 依据/风险 | 建议动作 | 对应章节 |
|---|---|---|---|---|
| 5.4.1 Secret 优先文件挂载而非 env | Assess | 取决于应用实现；env 变量有泄露面但改造成本不一 | 新应用优先 volume；存量应用评估日志/崩溃转储/调试接口风险 | 50,53 |
| 5.4.2 考虑外部 secret 存储 | Assess | 已有 50 章方案对比；生产接入依赖外部系统 | 生产/敏感场景评估 ESO+Vault/KMS；教学环境 SOPS+age 已覆盖基础 | 50 |

## 5.5 Extensible Admission Control

| Check | 判定 | 依据/风险 | 建议动作 | 对应章节 |
|---|---|---|---|---|
| 5.5.1 Image Provenance/ImagePolicyWebhook | Assess | 需要 registry 签名、验签策略、例外流程 | 下一步可评估 cosign + Kyverno verifyImages；当前不引入 Harbor 全家桶 | 52,43,53 |

## 5.7 General Policies

| Check | 判定 | 依据/风险 | 建议动作 | 对应章节 |
|---|---|---|---|---|
| 5.7.1 使用 namespace 边界 | Template | default namespace 仍易被滥用 | 业务工作负载进专用 namespace；配合 RBAC/Quota/NetworkPolicy | 07,53 |
| 5.7.2 seccomp RuntimeDefault | Template | 降低内核攻击面 | 业务 Pod 默认 `seccompProfile: RuntimeDefault`；不兼容应用单独豁免 | 39,53 |
| 5.7.3 应用 SecurityContext | Template | 已有 33/39 基础 | 纳入 Pod 模板/CI 检查；优先 non-root、drop caps、no privilege escalation | 33,39,53 |
| 5.7.4 不使用 default namespace | Template | 与 5.7.1 一致 | 教学 demo 可临时使用但必须清理；业务禁止 | 53 |

## 推荐落地顺序（低风险）

1. **Namespace 基线模板**：PSA labels + default-deny NetworkPolicy + ResourceQuota/LimitRange（可选）+ SA 默认不挂载 token。
2. **Pod securityContext 模板**：`runAsNonRoot`、`allowPrivilegeEscalation=false`、`drop ALL`、`seccompProfile: RuntimeDefault`。
3. **RBAC 审计**：cluster-admin 绑定、secrets 通配符、bind/escalate/impersonate。
4. **准入增强**：Kyverno Audit 模式先观察，再对新 namespace enforce。
5. **供应链**：Trivy 扫描 + cosign 验签评估，先不做 Harbor。

## 建议的业务 Namespace 基线（示例）

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: example-app
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: latest
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: latest
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
  namespace: example-app
automountServiceAccountToken: false
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: example-app
spec:
  podSelector: {}
  policyTypes: ["Ingress", "Egress"]
```

> 说明：该模板是起点，不是万能策略。应用 DNS、Ingress、数据库、metrics 抓取等流量需显式放行；系统 namespace 不应直接套用。