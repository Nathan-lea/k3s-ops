# 公司级测试环境及生产环境：k3s 动态扩缩容部署方案建议

> 本文基于现有项目（Vagrant + Ansible + VirtualBox）经验，面向从“本地教学环境”迁移到“公司级测试环境”和“生产环境”时的选型、架构、扩缩容、HA、安全、存储等全量建议。

## 1. 总体思路

现有项目（k3s-ops）采用 **Vagrant + Ansible** 来管理虚拟机并一键部署 k3s，逻辑清晰（`nodes.yml` + `k3s-ops.sh` + Ansible playbook）。但要真正满足“**可动态扩缩容**”、“**多环境一致**”、“**生产可用**”，Vagrant（偏向开发本地）已不适合作为生产 IaC。

核心原则：

| 原则 | 说明 |
|---|---|
| **基础设施即代码（IaC）** | 环境定义应版本化（Git），能幂等、可回溯地创建/销毁。 |
| **声明式扩缩容** | 节点增删应该是“声明节点池规模”，而非手动逐台跑脚本。 |
| **HA 先行** | 控制面（server）至少 3 台，采用嵌入式 etcd（k3s 默认）或外部 etcd，前端入口用 VIP（kube-vip）或外部 LB。 |
| **南北向一致** | 测试环境尽量与生产环境采用同一套暴露方案（MetalLB + Ingress/Gateway），减少“本地能跑、线上不通”的差异。 |
| **可观测、可恢复** | 配备备份（etcd/snapshot + 应用数据）、日志/监控、告警及演练。 |

## 2. 环境差异对比

| 维度 | 本地教学（当前） | 公司级测试环境（KVM/Proxmox/VMware） | 生产环境（混合云/自建/云上） |
|---|---|---|---|
| **底层** | VirtualBox（单机） | 虚拟化集群（KVM/Proxmox/vSphere）或少量裸金属 | 云（EKS-like 自建或公有云）或多机房裸金属/混合 |
| **节点增删** | 手动改 `nodes.yml` → `k3s-ops.sh up/add-node/remove-node` | 需要**自动化节点纳管**（IPAM、网络、OS 基线） | 更强调**节点池**、自动扩缩容（CA/Karpenter） |
| **控制面 HA** | 目前单 server（可扩展到多 server） | **推荐 3 台 server**（嵌入式 etcd） | **强制 3 台及以上**，考虑跨可用区/机架 |
| **LoadBalancer** | ServiceLB 已关闭（教程第 44 章决策），用 NodePort+Ingress | **关闭 ServiceLB，推荐 MetalLB（L2/BGP）**，也可用 kube-vip | **关闭 ServiceLB**。云上用云厂商 LB；自建用 MetalLB/kube-vip + Nginx/Gateway |
| **存储** | 宿主机路径（local-path-provisioner，k3s 默认） | 建议用分布式/共享存储（Longhorn/OpenEBS/LocalPV+LVM/Rook-Ceph） | 用企业级存储（云盘、Ceph、vSAN 等），关注 RPO/RTO |
| **网络** | VirtualBox Host-only（192.168.56.0/24） | VLAN/Bridge/VxLAN、BGP（若用 MetalLB BGP）、Calico/Flannel 可选 | 需考虑多租户、出口、内网隔离、安全组等 |
| **动态扩缩容** | 半自动（脚本化） | **推荐 Cluster Autoscaler（CA）**（配合节点模板） | **优先 CA 或 Karpenter**（视云/裸金属而定） |
| **密钥/机密** | 本地文件（kubeconfig、token） | 用 Vault/External Secrets/SSO 等集中管理 | 强化机密管理、最小权限、审计 |
| **镜像仓库** | 本地可直连或用镜像加速 | 建议自建 Harbor/Artifactory 或用内网镜像源（已在项目加速逻辑基础上扩展） | 离线/内网镜像仓库 + 漏洞扫描 |

## 3. 推荐技术栈

| 类别 | 推荐 | 说明 |
|---|---|---|
| **底层（测试）** | **Proxmox VE** 或 **KVM + libvirt** | 成本低、API 丰富（便于做自动化扩缩容）、社区活跃。vSphere 也可但授权成本高。 |
| **底层（生产）** | **裸金属** 或 **公有云（阿里云/腾讯云/AWS/Azure/GCP）** | 按业务选型。混合云需统一网络与身份。 |
| **IaC（基础设施）** | **Terraform** | 用 HCL 声明 VM/网络/IP，配合 `proxmox/terraform-provider-proxmox`、`libvirt`、云厂商 provider。比纯 Vagrant 更适合团队协作与 CI。 |
| **配置管理（OS+k3s）** | **Ansible**（沿用现有思路）或 **cloud-init** | 沿用项目现有 roles（k3s-common/server/agent）最省迁移成本。可用 Packer 制作 OS 镜像+cloud-init 做基线。 |
| **k3s 集群编排（声明式）** | **Cluster API（CAPI） + CAPK3S** | 声明式管理“集群对象”（Cluster/MachineDeployment），支持多基础设施（Proxmox/KVM/云），天然支持**水平扩缩容（MachineDeployment）**和集群生命周期。 |
| **K8s 发行版** | **k3s**（与本项目一致） | 轻量、易用、嵌入式 etcd、资源占用低，适合大多数中小集群。若强烈要求更“原生”可考虑 **RKE2**，但迁移成本略高。 |
| **控制面入口（VIP）** | **kube-vip** | 在自建环境（KVM/Proxmox/裸金属）用 ARP/L2 宣告一个 VIP，供 `kubeconfig` 和外部 LB 前置连 API Server。比单节点 IP 更适合 HA。 |
| **集群内 LB** | **MetalLB**（L2 或 BGP） | 实现 `type=LoadBalancer`。**L2** 简单（同一二层广播域），**BGP** 更适合跨子网/规模更大的生产。**切记：关闭 ServiceLB（已按第44章决策）**。 |
| **Ingress/Gateway** | **NGINX Ingress Controller** 或 **NGINX Gateway Fabric**（沿用项目已有组件） | 项目已用 nginx-ingress、也实践过 Gateway API（教程37/41章）。建议统一成一种，按团队偏好选。 |
| **证书** | **cert-manager**（已有经验） | 自动签发/续期 Let's Encrypt（HTTP-01/DNS-01）或企业内网 CA。 |
| **存储** | **Longhorn**（易上手）或 **OpenEBS（LocalPV）** 或 **Rook-Ceph** | 测试环境推荐 Longhorn（UI 全、快照/备份简单）。生产按性能/可用性选型。 |
| **动态节点扩缩容** | **Cluster Autoscaler（CA）** 或 **Karpenter** | **CA**：通用，支持多云、文档丰富。**Karpenter**：更快、按需求直接起新节点（更适合云/云原生环境）。裸金属需额外适配（如 CAPC/Proxmox provider 配合 CA）。 |
| **GitOps（可选但推荐）** | **FluxCD** 或 **ArgoCD** | 声明式交付应用，配合环境目录（dev/stage/prod）实现“可审计、可回滚”。 |
| **备份** | **Velero** | 应用资源 + 持久卷备份/恢复，支持对象存储（MinIO/S3）和多集群。配合 etcd snapshot（k3s 自带 `k3s etcd-snapshot`）双保险。 |
| **可观测** | **kube-prometheus-stack**（Prom/Grafana/Alertmanager）+ **Loki** + **Promtail** | 覆盖指标、日志、告警。生产需配置告警路由（飞书/钉钉/邮件）。 |
| **安全基线** | **Kyverno**（项目已实战）+ **KubeArmor/OPA Gatekeeper（二选一）** + **Trivy**（镜像/文件扫描） | 沿用 Kyverno 策略（第43章），再叠加镜像签名（cosign）、SBOM、CIS 合规检查。 |

## 4. 动态扩缩容方案对比

要实现“**动态扩缩容**”，核心是两层：

1. **控制面扩缩容**：server 节点（etcd 成员）增删。etcd 成员变动要谨慎（建议固定 3 台 server，极少扩到 5 台）。
2. **工作节点扩缩容**：agent 节点按负载（CPU/内存/Pending Pod）自动增删。

| 方案 | 适用范围 | 难度 | 可控性 | 说明 |
|---|---|---|---|---|
| **A. 半自动（沿用现有思路）** | 测试环境过渡期 | ★★☆（低） | 高（人工审核） | 继续用 `nodes.yml` + `k3s-ops.sh up/add-node`。优点：迁移成本最低、可复用 Ansible roles。缺点：不是“按负载”自动触发，需人工判断时机。 |
| **B. Cluster Autoscaler（CA）** | **测试+生产最常用**（KVM/Proxmox/云厂商均有 provider） | ★★★☆（中） | 高 | 依赖“节点组（Node Group）”概念。配合 Terraform 预定义节点模板（VM 镜像、规格、标签、taint），CA 根据 `scale-up/down` 条件增删节点。成熟、稳定、社区广泛。 |
| **C. Karpenter** | 云原生生产（AWS/Azure/GCP）首选；裸金属需额外适配 | ★★★★☆（较高） | 中高 | 无需预定义节点组，按 Pod 需求**即时**创建最合适规格的节点，回收更激进。更省成本、更智能。但在自建 KVM/Proxmox 场景适配工作量较大。 |
| **D. Cluster API（CAPK3S）内建扩缩容** | **最符合“声明式”长期演进** | ★★★★☆（中高） | 高 | 用 `MachineDeployment` 声明 `replicas`，CAPI Controller 自动创建/删除对应 VM 并让 k3s 加入。配合 **Cluster Autoscaler** 也能做“按负载”自动扩缩容（HPA-like for nodes）。 |

> 建议：**公司级测试环境 → B（CA）** 或 **D（CAPI）**；**生产环境 → B 或 D**。若团队已熟悉 Ansible，可先用 **A→B** 过渡；长期推荐走 **D（CAPI）** 统一集群全生命周期。

## 5. 推荐落地路径

针对“公司级测试环境”和“生产环境”两种场景，建议分阶段落地。

### 5.1 公司级测试环境（KVM/Proxmox）

目标：**环境可复制、能动态扩缩容、尽量与生产对齐**。

| 步骤 | 建议做法 | 备注 |
|---|---|---|
| **Step 1：底层标准化** | 用 **Proxmox**（API 简洁）搭建虚拟化平台，统一模板（Ubuntu 22.04 + cloud-init）。 | 用 Packer 构建“干净模板”（预装必要包、containerd、sysctl），省后续配置时间。 |
| **Step 2：IaC 托管基础设施** | 改用 **Terraform** 管理 VM（CPU/MEM/DISK/网卡/IP）。将 `nodes.yml` 思路迁移到 `terraform.tfvars`。 | 保留 Ansible 思路：Terraform 创建 VM → Ansible 配置 OS + k3s。两者配合最省迁移成本。 |
| **Step 3：HA 控制面** | 固定 **3 台 server**（嵌入式 etcd）。前置用 **kube-vip** 配置 VIP（192.168.x.x）供 kubeconfig 连 API。 | 测试环境也要走 HA，避免“测试单点、生产三节点”的认知偏差。 |
| **Step 4：负载均衡** | **关闭 ServiceLB**，部署 **MetalLB L2**（给 `LoadBalancer` 分配内网 IP 池）。Ingress 用 **nginx-ingress**（沿用现有）。 | 与第 44 章结论一致。L2 足够（同一二层）。 |
| **Step 5：半自动扩缩容（起步）** | 先用 **Ansible add-node/remove-node** 流程（可复用项目 roles）。配合脚本校验节点 ready。 | 过渡期最平滑。等规模上来再上 CA。 |
| **Step 6：存储** | 用 **Longhorn**（单体环境也能跑，UI 直观，便于排障）。 | 测试环境数据可定期清理，不用一上来就上 Ceph。 |
| **Step 7：GitOps+备份** | 建议先上 **Velero**（定期备份命名空间/卷到 MinIO）+ **k3s etcd snapshot** 定时任务。 | 能演练“删 namespace → 恢复”的真实场景，极有价值。 |

### 5.2 生产环境（混合云/自建）

目标：**高可用、可扩缩容、安全合规、可观测、可恢复**。

| 步骤 | 建议做法 | 备注 |
|---|---|---|
| **Step 1：多可用区/多机架** | 控制面跨机架/可用区部署（最少 3 台，间隔物理故障域）。工作节点按业务池划分（通用池/计算密集池等）。 | 嵌入式 etcd 对网络延迟敏感（建议 RTT < 10ms）。跨机房需谨慎，优先外部 etcd 或专线。 |
| **Step 2：基础设施 IaC** | **Terraform** 管理裸金属（PXE/IPMI）或云资源。配合 **Packer** 固定 OS 镜像。 | 禁止手动点点点。所有变更走 PR 审核。 |
| **Step 3：声明式集群（推荐）** | 用 **Cluster API + CAPK3S** 定义 `Cluster`、`KThreesControlPlane`、`MachineDeployment`。 | “集群本身”也变成声明式对象，配合 ArgoCD/Flux 将 Cluster 定义纳入 GitOps。 |
| **Step 4：API Server 入口** | 用 **kube-vip**（L2/ARP）或**外部 LB**（云厂商 NLB/ALB、或 F5/HAProxy Keepalived）。优先 kube-vip 简化自建场景。 | `kubeconfig` 固定指向 VIP，server 节点故障时自动切换。 |
| **Step 5：集群内 LB** | **MetalLB BGP**（若网络有 BGP 能力）更适合生产；否则用 **L2**。**禁用 ServiceLB**。 | BGP 可实现真正的跨节点流量分发且故障更平滑。 |
| **Step 6：动态扩缩容** | 用 **Cluster Autoscaler** 配合 CAPI（有成熟实践）。若全云且追求极致弹性，可评估 **Karpenter**。 | 重点配置 `scale-down-delay-after-add`、`scale-down-unneeded-time`、`pod-eviction-timeout` 等参数，避免抖动。 |
| **Step 7：存储** | 根据数据特性选型：**Longhorn**（块存储，快照易用）、**Rook-Ceph**（高可用强一致，较重）、**云盘**（云上最省运维）。 | 生产需做**存储灾备**（卷快照、异地备份）、IOPS 压测。 |
| **Step 8：GitOps 全量交付** | 用 **FluxCD** 或 **ArgoCD** 管理所有应用（包括 Kyverno 策略、cert-manager、Ingress 等基础组件）。环境按 `overlays/` 或 `clusters/<env>/` 隔离。 | “一键回滚”是生产最关键的安全网。 |
| **Step 9：备份与演练** | **Velero** 日常备份（对象存储隔离），**k3s etcd-snapshot** 每日本地+异地。每季度至少做一次**全量恢复演练**。 | 很多团队有备份却从未演练，真正出事时才发现不可用。 |
| **Step 10：安全与合规** | 启用 **Kyverno**（已实战）强制标签/资源配额/镜像仓库限制等；配合 **Trivy** 扫描；启用 **NetworkPolicy** 默认拒绝+最小放行；配置 **PodSecurityAdmission/Restricted**；集成 **OIDC**（统一登录）；启用 **audit-log**。 | 参考 CIS Kubernetes Benchmark，按风险优先级落地。 |
| **Step 11：可观测与告警** | 上 **kube-prometheus-stack** + **Loki** + **Tempo/Jaeger**（链路追踪按需）。关键指标（APIServer 延迟、etcd leader、Pod CrashLoop、节点 NotReady）必须有告警。 | 告警要“可行动”（附排查清单），避免“告警风暴”。 |

## 6. 从现有 k3s-ops 向目标方案迁移建议

现有项目的最大资产是：**Ansible roles（k3s-common/server/agent/manage）**、**节点名解析（lib/nodes.sh）**、**统一 CLI（k3s-ops.sh）**、**教程体系（42/43/44章）**。没必要推翻全盘。

推荐渐进式迁移：

| 阶段 | 做法 | 说明 |
|---|---|---|
| **Phase 0：固化现状** | 保持现有本地环境可用（已验证的流程）。将本文档沉淀到 `docs/`。 | 不破坏现有教学价值。 |
| **Phase 1：基础设施抽象** | 新增 `terraform/` 目录（Proxmox/libvirt）。用 Terraform 定义 VM，保留 Ansible `inventory` 动态生成方式（参考 Vagrant 逻辑）。 | 用最小改动复用 Ansible playbooks。 |
| **Phase 2：HA + LB 对齐生产** | 在测试环境强制 **3 server + kube-vip + MetalLB L2**。验证 `LoadBalancer` 行为与第44章结论一致。 | 强化“测试=生产”的思路。 |
| **Phase 3：引入 CAPI（中长期）** | 试点 **CAPK3S**：用 `clusterctl` 管理集群，改用 `MachineDeployment` 做工作节点扩缩容。逐步替代“手动 add-node”思路。 | 一旦跑通，后续新增环境（stage/prod）都能用同一套 manifests。 |
| **Phase 4：自动化扩缩容** | 配合 **Cluster Autoscaler** 监听 `MachineDeployment`，按资源压力自动扩缩容。配合 **Prometheus Adapter** 做自定义指标（按需）。 | 真正实现“按负载动态扩缩容”。 |

## 7. 关于“动态扩缩容”的落地建议（最务实版）

对于多数公司团队，**最务实且风险可控**的路径是：

1. **测试环境**：沿用 **Terraform + Ansible**（复用现有 roles）→ 先用 **半自动 add-node** 跑通流程 → 再接入 **Cluster Autoscaler**（配合节点池模板）。
2. **生产环境**：直接上 **Cluster API + CAPK3S + Cluster Autoscaler**。控制面固定 3 台，工作节点走 `MachineDeployment` + HPA 触发节点扩缩容。

**避免一上来全套最复杂**。建议先在**公司级测试环境**验证全链路（扩容→Pod 调度→缩容→资源回收）后再复制到生产。

## 8. 快速 check-list（落地前自查）

| 检查项 | 建议 | 是否达标（自评） |
|---|---|---|
| **控制面 HA** | server >= 3，etcd 健康、API Server 可用性验证 | ☐ |
| **VIP/外部 LB** | kube-vip 或外部 LB 配置正确，`kubectl` 走 VIP 连通 | ☐ |
| **集群内 LB** | MetalLB 正常分配 EXTERNAL-IP，ServiceLB 已禁用 | ☐ |
| **Ingress 可用** | 80/443 正常（按环境选用 NodePort/hostNetwork/直通 LB） | ☐ |
| **动态扩缩容验证** | 制造 Pending Pod → 节点自动扩容 → 压力降下 → 节点自动缩容（排空） | ☐ |
| **存储可用** | PVC 创建/挂载/删除正常，快照可用 | ☐ |
| **备份恢复** | etcd snapshot + Velero 恢复演练成功 | ☐ |
| **安全基线** | NetworkPolicy、PodSecurity、Kyverno 策略生效 | ☐ |
| **可观测** | 核心告警（节点宕机/etcd慢/CrashLoop）已配置并可触发 | ☐ |
| **证书自动续期** | cert-manager 正常签发/续期 | ☐ |

## 9. 结论

- **短期（公司测试环境）**：**Terraform + Ansible（复用 k3s-ops 现有 roles） + kube-vip + MetalLB + nginx-ingress + Cluster Autoscaler** 是“**迁移成本最低、又能跑通动态扩缩容**”的平衡点。
- **中长期（生产环境）**：**Cluster API（CAPK3S） + Cluster Autoscaler** 更符合基础设施即代码的“声明式”演进方向。它把“集群”本身也纳入 Git 管理，新增环境只需改几行 YAML。
- **关于自动扩缩容时机**：别一上来追求“零人工”，先用**半自动**打通全流程、积累运维经验，再逐步收紧到“全自动”更安全。
- **延续现有决策**：沿用“**ServiceLB 关闭**、用 **MetalLB**”的结论（第44章），这套选型在自建 KVM/Proxmox 场景最省踩坑。

> **核心建议一句话**：**先复用（Ansible roles + 节点解析逻辑），再抽象（Terraform 定义基础设施），再声明式（CAPI 管理集群生命周期），最后才做“全自动按负载扩缩容”。** 这是从“教学脚本”平滑过渡到“生产平台”的最现实路径。
