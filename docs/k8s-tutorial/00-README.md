# Windows 教程

## 1. 安装并打开 PowerShell 终端

1.1 打开 PowerShell（权限：默认→取消勾选「在 Win11 上使用 Ctrl+Shift+Enter 启动 PowerShell」）。

1.2 确保有管理员权限：右键『以管理员身份运行』PowerShell。如果已经以管理员身份运行，可以继续下一步。

## 2. 切换到本教程所在目录

2.1 打开文件资源管理器，找到包含本教程的文件夹（例如 `C:\Users\liming\Desktop\k3s-ops`）。

2.2 在 PowerShell 中切换到该目录：

```powershell
Set-Location "C:\Users\liming\Desktop\k3s-ops"
```

或者直接在文件资源管理器地址栏中输入 `cd` 后回车即可打开 PowerShell 终端在当前目录下。

## 3. 执行 `.\win\up.ps1 -Install`

3.1 执行以下命令（注意使用了 `-Install` 参数）：

```powershell
powershell -ExecutionPolicy Bypass -File .\win\up.ps1 -Install
```

3.2 耐心等待脚本完成。以下是正常输出示例（根据你的网络和硬件，时间可能有所不同）：

```
[INFO]  检查前置条件
[INFO]  vagrant: Vagrant 2.4.9
[INFO]  VBoxManage: Oracle VirtualBox Command Line Management Interface 7.0.44
[INFO]  找到 cluster_name: k3s-demo
[INFO]  物理内存 16GB
[INFO]  192.168.56.0/24 未被占用
[INFO]  拓扑文件: .\win\nodes.windows.yml
[INFO]  启动全部 VM（首次需要下载 box，约 1-3GB）
[INFO]  引导工作机（装 ansible/kubectl/helm，首次约 5-10 分钟）
[INFO]  安装 k3s（约 5-10 分钟）
[INFO]  改写 kubeconfig 的 server 地址
[INFO]  集群自检
完成。进入工作机：
    vagrant ssh k3s-demo-ops
    cd ~/k3s-ops && ./k3s-ops.sh status
[INFO]  完成。
```

## 4. 执行第 2 步：验证并开始学习

4.1 在 PowerShell 中输入以下命令，进入工作机（ops 工作机）：

```powershell
vagrant ssh k3s-demo-ops
```

4.2 在工作机里，切换到项目根目录并运行 `k3s-ops.sh status` 进行验证：

```bash
cd ~/k3s-ops
./k3s-ops.sh status
```

应该看到如下输出（请根据你的网络和硬件进行调整）：

```
[INFO]  Starting cluster health-check
[INFO]  [node] k3s-demo-server-1: etcd 正常运行
[INFO]  [node] k3s-demo-agent-1: kubelet 正常运行
[INFO]  集群健康检查通过
```

4.3 验证完成后，退出工作机（`exit` 命令）：

```bash
exit
```

## 5. 成功！恭喜你！

恭喜你！你已经拥有了一个完整的 k3s 集群！你可以直接按照 `docs/k8s-tutorial/` 目录下的所有章节学习 Kubernetes。

**注意**：在本教程的所有命令中，`kubectl` 前缀的命令统一使用 `kubectl --kubeconfig ./kubeconfig`，方便直接复制粘贴。如果你想简化，也可以先执行：

```powershell
$env:KUBECONFIG = "$(Get-Location)\kubeconfig"
```

之后命令可直接写作 `kubectl get nodes`。

---

## 常见问题

### `vagrant up` 权限不足或报错

运行 PowerShell 时可能会出现警告：\"要安装此应用程序，你需要管理员权限\"，选择 \"继续\"。这会让进程以管理员身份重启。如果仍然失败，请右键『以管理员身份运行』PowerShell 并再试一次。

### `host-only` 网卡冲突

如果 `vagrant up` 报错，大概率是 `192.168.56.0/24` 段已被占用（例如其它软件用过）。解决方案：

- 可临时修改 `win/nodes.windows.yml` 中 `subnet: 192.168.56.0/24` 和第一个节点的 `ip` / 后继节点的 `ip`。
- 也可以把 ops 节点改成 `192.168.57.5` 等其他未占用网段。

### `helm` 下载失败

正常网络可以从 `https://get.helm.sh` 下载，但实测中 `raw.githubusercontent.com` 不可达（Connection reset），kubeconfig 请求失败。教程已针对这点进行优化：helm 全部由工作机分发到 server-1 / agent-1（请参考 `provision-ops.sh` 中 `distribute_helm` 函数）。因此 `helm` 版本只需在工作机安装即可，不需要跑 `helm init`。

### `kubeconfig` 文件不正常

`install` 拉下来的 `kubeconfig` 里 server 地址是 `127.0.0.1`（在 VM 里），无法在宿主机访问。所以 `up.ps1 -Install` 自动运行 `provision-ops.sh` -> `./k3s-ops.sh install` -> `./k3s-ops.sh kubeconfig` -> 改写 server 地址为 `192.168.56.10`。有两种拉取 kubeconfig 的方法：

- `.\\win\\kubeconfig.ps1` 直接从工作机拉取，并把 `127.0.0.1` 改写成 `192.168.56.10`。
- 或者 `vagrant ssh k3s-demo-ops -c 'cat ~/k3s-ops/kubeconfig'` 从工作机拉取，之后手动改写。

请确保修改 `127.0.0.1:6443` 成 `192.168.56.10:6443` 后，再导出 `KUBECONFIG` 变量到宿主机，方便直接用 `kubectl`。

### `ansible` 命令丢失

`provision-ops.sh` 会为工作机建立一个独立的虚拟环境 `~/.venv/k3s-ops`，并在 `~/.bashrc` / `/etc/profile.d/k3s-ops.sh` 里注入 `PATH` 等环境变量。所以每个新的 PowerShell 会话都需要重新加载这些环境变量（否则 `ansible` / `kubectl` 等命令将丢失）。

解决方法如下图所示：

1. 通过 `/etc/profile.d/k3s-ops.sh` 自动加载环境变量（本脚本已经完成），
2. 或者手动 `source ~/.bashrc` / 打开新的 PowerShell 终端，
3. 或者使用 `exe`（类似于 `source` 的 PowerShell 原生命令）。

---

## 教程目录

本教程共 45 章，从基础概念到高级实战，详细信息请查看 `docs/k8s-tutorial/` 目录。

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
| [32 Rancher 多租户与 RBAC](32-Rancher多租户与RBAC.md) | Rancher 多租户模型、CR 识别、项目/集群授权实操、Namespace 归属、排障清单 |
| [33 Pod 生命周期、探针与优雅终止](33-Pod生命周期、探针与优雅终止.md) | Pod 生命周期、liveness/readiness/startupProbe、preStop、terminationGracePeriodSeconds、滚动更新卡住排障 |
| [34 资源治理、QoS 与 HPA 实战](34-资源治理、QoS与HPA实战.md) | requests/limits、QoS、LimitRange、ResourceQuota、HPA 基础与 OOMKilled 排障 |
| [35 NetworkPolicy 网络隔离实战](35-NetworkPolicy网络隔离实战.md) | 默认全通到最小权限、PodSelector/NamespaceSelector、Ingress/Egress、流量实测（RBAC+网络双重边界闭环） |
| [36 Kubernetes 故障排查实战 Runbook](36-Kubernetes故障排查实战Runbook.md) | CrashLoopBackOff/ImagePull/ErrImagePull/OOMKilled/Pending/NodeNotReady/ReadinessFailed、结构化排障链路 |
| [37 Gateway API 入门与实战](37-GatewayAPI入门与实战.md) | Gateway/HTTPRoute/ReferenceGrant、与 Ingress 对比、NGINX Gateway Fabric 简单实测 |
| [38 PodDisruptionBudget 与节点维护实战](38-PodDisruptionBudget与节点维护实战.md) | PDB、kubectl drain/cordon/uncordon、Eviction、可用性保障 |
| [39 Pod 安全与安全上下文](39-Pod安全与安全上下文.md) | securityContext 字段体系、PSA 三档与 enforce/warn/audit、seccomp/AppArmor、privileged 拦截与 restricted 合规改造 |
| [40 StatefulSet 与有状态应用](40-StatefulSet与有状态应用.md) | Headless Service/DNS、volumeClaimTemplates 独立 PVC、有序创建/缩容、重建复用同卷、partition 灰度与 PDB 联动 |
| [41 Gateway API 进阶实战](41-GatewayAPI进阶实战.md) | 权重金丝雀、header/query 匹配、URLRewrite 与头改写、超时与 backendRefs 语义、Ingress 迁移对照、GRPCRoute/TLSRoute 现状 |
| [42 CRD 与 Operator 实战](42-CRD与Operator实战.md) | CRD 拆解（schema/printer columns/status 子资源）、调谐循环与幂等、Go+controller-runtime 自写小控制器、镜像导入、删对象自愈 |
| [43 Kyverno 策略引擎](43-Kyverno策略引擎.md) | validate/mutate/generate 三类策略、Enforce 拦截与 Audit 报告、PolicyReport、Kyverno CLI 离线测试、PSA 分层、failurePolicy 逃生与卸载 |
| [44 Service 暴露与 LoadBalancer](44-Service暴露与LoadBalancer.md) | 三种暴露方式、k3s ServiceLB 机制与开关、开与不开对比、本环境/公司测试/生产选型、MetalLB 与真 VIP、本环境开启与回滚 |
| [45 集群安装前服务器参数设置](45-集群安装前服务器参数设置.md) | 硬性 vs 建议参数分组、swap/内核模块/sysctl/limits/NTP/防火墙端口逐项「四要素」（参数名·值·作用·设置位置）、k3s-common 角色对照、一键设置与体检脚本（幂等 / --check / 退出码巡检） |