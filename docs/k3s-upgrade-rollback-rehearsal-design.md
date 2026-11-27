# k3s 升级回滚/隔离演练设计（步骤 3，不动当前集群）

> 状态：**设计稿，未执行破坏性演练**。  
> 日期：2026-11-27  
> 前置输入：`docs/k3s-upgrade-compatibility-matrix.md`、`docs/k3s-ops-upgrade-wrapper-comparison.md`、`docs/k8s-tutorial/57-集群升级实战.md`、`ansible/playbooks/k3s-restore.yml`。

## 1. 目标

为“跨 minor 逐级升级”前的回滚能力建立可复现证据，回答三件事：

1. **二进制回退**能覆盖哪些失败场景，边界在哪。
2. **etcd 快照 + cluster-reset restore** 在 k3s embedded etcd 单 server 场景如何实操，恢复后如何验收。
3. 本仓库 `k3s-ops.sh restore -f` / `ansible/playbooks/k3s-restore.yml` 的封装边界与风险。

## 2. 强约束

- **不在当前教学集群执行**。当前集群保留 57 章升级后状态与历史证据。
- **隔离环境**执行所有破坏性演练；优先独立 Vagrant 项目目录/独立 `VAGRANT_CWD` + 独立 `KUBECONFIG`，避免污染 `vagrant/.vagrant`、根 `Vagrantfile` 状态。
- **不触碰 `production/`**。
- 每次演练前后记录：拓扑、版本、快照名、命令、关键输出、验收结果、清理结果。
- 所有证据落盘到仓库 `docs/` 或 `logs/`（gitignored 按需），不依赖 `/tmp`。

## 3. 演练环境设计（建议）

### 方案 A：独立临时 Vagrant 目录（推荐）

在仓库外或仓库 `tmp/` 下创建独立演练目录（不提交 `.vagrant`），复制最小必要文件：`Vagrantfile`/`vagrant/nodes.yml` 模板、必要 scripts/ansible 子集，或直接使用独立 nodes YAML + 新 `cluster_name`（如 `k3s-rollback-lab`）。

要求：

- `cluster_name` 不同，避免 VM 名/hostname/DHCP 冲突。
- 私网网段与当前集群错开（当前 `192.168.56.0/24`，演练用如 `192.168.57.0/24`）。
- 至少 1 server + 1 agent（覆盖 server/agent 升级与恢复）；如资源紧张可先做 1 server 最小闭环，再扩 1 agent。
- k3s 初始版本固定为 `v1.30.14+k3s2`（当前基线），目标跳 `v1.31.14+k3s1` 作为跨 minor 第一跳候选。

### 方案 B：复用仓库但独立 nodes 文件

仅在确认 Vagrant/VirtualBox 命名不会冲突时使用；风险高于方案 A，不作为默认。

## 4. 演练场景

| 场景 | 目的 | 预期可回滚性 | 关键证据 |
|---|---|---|---|
| R1 二进制回退（同 minor） | 验证 `k3s.bak.*` + 重启服务能否快速回退 | 高 | 升级后回退版本、节点 Ready、系统 Pod |
| R2 二进制回退（跨 minor 失败后） | 验证升级到 1.31 失败/异常时回退 1.30.14 的边界 | 中，依赖未发生不可逆数据/schema 变化 | 回退后 API/etcd/Pod；若失败记录阻塞点 |
| R3 etcd 快照 restore（同 minor） | 验证 `cluster-reset --cluster-reset-restore-path` 全流程 | 高，但破坏性强 | 快照恢复后对象状态、节点重注册、数据面 |
| R4 封装 restore 对照 | 验证 `k3s-ops.sh restore -f` / `k3s-restore.yml` 行为与文档边界 | 待验证 | playbook 是否能在干净/脏 etcd dir 场景执行 |

## 5. R3/R4 重点检查：现有 restore playbook 风险

静态审查 `ansible/playbooks/k3s-restore.yml` 发现：

- 使用 `k3s server --cluster-reset --cluster-reset-restore-path=...`，并带 `args.creates: /var/lib/rancher/k3s/server/db/etcd`。**若 etcd 目录已存在，该 task 可能被跳过**，导致“看似执行、实际未 restore”。这是隔离演练必须验证的高风险点。
- 只在 `server[0]` 执行；停止所有 server、恢复后启动 first server，再启动剩余 server、重启 agents。对单 server 可接受；多 server/异常拓扑需验证。
- 未做 restore 前快照、未校验 snapshot checksum/来源、未校验集群版本兼容性、未做恢复后全量验收。
- `k3s-ops.sh restore -f` 有交互确认，但无前置门禁清单。

演练时必须记录该行为，不在未验证前把封装写成“可靠恢复路径”。

## 6. 标准恢复流程（演练脚本草案）

> 以下仅为隔离环境演练草案，执行前需再次确认 k3s 版本手册。

### 6.1 二进制回退

```bash
# 在目标节点
sudo cp /usr/local/bin/k3s.bak.v1.30.14+k3s2 /usr/local/bin/k3s
sudo chmod 0755 /usr/local/bin/k3s
sudo systemctl restart k3s        # server
sudo systemctl restart k3s-agent  # agent
kubectl get nodes -o wide
```

验收：版本回退、节点 Ready、关键 system pods Ready、无新增异常事件。

### 6.2 etcd 快照 restore（单 server embedded etcd）

```bash
# 所有 server 停止 k3s（单 server 即本机）
sudo systemctl stop k3s

# 执行 restore（注意：按官方文档确认 cluster-reset 行为）
sudo k3s server --cluster-reset --cluster-reset-restore-path=<snapshot>

# 启动 k3s
sudo systemctl start k3s

# 如有 agent，重启 agent 重新加入
sudo systemctl restart k3s-agent
```

验收：

- `kubectl get nodes` 恢复快照时点的集群成员视图；
- 快照后创建的对象应消失（验证回滚语义）；
- 快照前存在的关键对象/Helm release 恢复；
- agent 重新注册/Ready；
- PV 数据**不保证**随 etcd 回滚一致（需单独验证）。

## 7. 验收门禁

每个场景必须产出：

- 执行前基线：`kubectl get nodes -o wide`, `kubectl get pods -A`, `helm list -A`, snapshot list。
- 执行记录：命令、退出码、关键日志。
- 执行后验收：节点、system pods、目标 workload、事件、必要时 Helm release。
- 结论：`通过/失败/有条件通过` + 阻塞点 + 是否可进入下一场景。
- 清理：销毁隔离 VM，确认无残留 Vagrant/VirtualBox 资源。

## 8. 停止条件

出现以下任一情况立即停止并记录：

- restore 命令行为与文档不符（尤其 `creates` 跳过导致未恢复）。
- 数据目录损坏或节点无法重新加入。
- 演练环境影响到当前集群网络/存储/Vagrant 状态。
- 无法在 30 分钟内定位控制面不可恢复原因（先保留现场证据再清理）。

## 9. 交付物

- 本设计文档（已创建）。
- 后续实操记录：`docs/k8s-tutorial/` 新章或 `docs/` 证据文档（执行后再定）。
- backlog 更新：步骤 3 从“待补”推进到“设计完成/待隔离实操”。

## 10. 下一步

1. 评审本设计，确认隔离环境网段/命名/资源预算。
2. 实施 R1/R3 最小闭环（1 server）后再扩 R2/R4。
3. 根据演练结果修订 `k3s-restore.yml`/`k3s-ops.sh restore` 文档或实现（需单独变更）。
