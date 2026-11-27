# kube-bench CIS 扫描摘要（k3s）

- 日期：2026-11-27
- 集群：k3s-demo，1 server + 1 agent，`v1.30.14+k3s2`，embedded etcd
- 工具：`aquasec/kube-bench:v0.10.6`，`--benchmark k3s-cis-1.7 --targets master,node,etcd,controlplane,policies --json`
- 范围：server 节点单次扫描；Job 在 `security-bench-demo` 运行后已清理
- 原始报告：`docs/kube-bench/k3s-cis-1.7-server-2026-11-27.json`

## 总计

PASS=41 FAIL=22 WARN=53 INFO=15

## 分区

| Section | PASS | FAIL | WARN | INFO |
|---|---:|---:|---:|---:|
| 1 Control Plane Security Configuration | 19 | 21 | 11 | 10 |
| 2 Etcd Node Configuration | 7 | 0 | 0 | 0 |
| 3 Control Plane Configuration | 0 | 0 | 5 | 0 |
| 4 Worker Node Security Configuration | 15 | 1 | 2 | 5 |
| 5 Kubernetes Policies | 0 | 0 | 35 | 0 |

## 关键发现

- **Section 1 多数 FAIL 为 kube-bench 检测误报/环境不兼容**：22 个 FAIL 中 18 个 `reason` 为 `journalctl ... libsystemd-shared-249.so: No such file or directory`，4 个为 audit 命中但 expected 未解析。k3s 的 apiserver/scheduler/controller-manager 嵌入 `k3s server` 进程，kube-bench 的 `journalctl | grep Running ...` 规则在该镜像/宿主机组合下不可靠；需人工按 k3s 文档与实际参数复核，不应直接当作配置缺陷。
- **4.2.9 FAIL 同类误报**：k3s kubelet TLS 证书由 k3s 自动管理，kube-bench 通过 journalctl 抽取失败。
- **WARN 主要是策略/运营类**：PodSecurity/NetworkPolicy/ServiceAccount 默认行为等（Section 5 共 35 WARN）；其中部分已被仓库现有教程（39/35/43/55）覆盖或需按业务命名空间落地。
- **未发现 etcd 分区 FAIL**；Section 2 PASS=7。

## 建议处理

| 项目 | 判定 | 动作 |
|---|---|---|
| Section 1 中 journalctl/libsystemd-shared FAIL | 工具误报/检测不兼容 | 不改集群；在 53/55 标注“kube-bench k3s-cis-1.7 在本环境 journalctl 规则不可靠，需人工复核”。可评估使用 kube-bench 支持的 k3s config 或宿主机运行。 |
| 4.2.9 | k3s 默认行为/检测限制 | 保持默认；记录 k3s kubelet 证书自动轮换机制。 |
| 5.x Policy WARN | 部分合理，部分待落地 | 按命名空间逐步落地 PSA/NetworkPolicy/ServiceAccount/RBAC 最小化；已有 35/39/43/55，不作为本次破坏性加固。 |
