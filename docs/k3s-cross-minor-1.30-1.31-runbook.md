# k3s 跨 minor 升级 Runbook：`v1.30.14+k3s2 -> v1.31.14+k3s1`

> 状态：**可执行草案（未执行实际生产/教学窗口）**。  
> 日期：2026-11-27  
> 适用范围：本仓库单 control-plane embedded etcd 教学集群基线；其他拓扑需先隔离演练并调整。  
> 主路径：**标准 k3s/Kubernetes/systemd/etcd snapshot 命令**。`k3s-ops.sh` 仅作为项目便利封装，边界见证据文档。

## 0. 证据与前置文档

| 文档 | 作用 |
|---|---|
| `docs/k3s-upgrade-compatibility-matrix.md` | 版本/组件兼容与 blocker |
| `docs/k3s-cross-minor-upgrade-plan.md` | 分阶段跨 minor 总方案 |
| `docs/k3s-ops-upgrade-wrapper-comparison.md` | `k3s-ops.sh upgrade -v` L1 能力边界 |
| `docs/k3s-upgrade-rollback-rehearsal-evidence.md` | R1/R3 隔离实操证据 |
| `docs/k3s-upgrade-r4-restore-wrapper-evidence.md` | R4 restore 封装危险成功修复 + 受控 restore PASS |
| `docs/k3s-upgrade-r2-rollback-boundary-evidence.md` | R2 边界：二进制回退!=状态回滚；peer URL mismatch 启动循环 |

## 1. NO-GO 门禁（任一命中即停止）

- [ ] **ingress-nginx 1.31 兼容/处置未完成**（用户已跳过专项，仍是 blocker）。
- [ ] 未在隔离环境完成本 runbook 彩排。
- [ ] 无升级前 etcd 快照，或快照未验证可列出/可复制。
- [ ] 任一节点 NotReady，或 `kube-system`/关键 addon Pod 异常且未评估。
- [ ] PV/业务数据回滚预案缺失（etcd restore **不回滚 PV 数据**）。
- [ ] 无维护窗口、无回滚责任人、无验收清单。
- [ ] `k3s restore` 将跨节点/IP/引导参数恢复，且未做 peer URL 预检/人工 runbook。

## 2. 角色与记录

执行前填写：

```text
窗口时间：
执行人：
观察人/回滚决策人：
集群：
当前版本：v1.30.14+k3s2
目标版本：v1.31.14+k3s1
快照名：
旧二进制备份路径：
业务 smoke：
回滚触发条件：
```

## 3. Preflight

在可执行 kubectl 的节点/运维机（设置 `KUBECONFIG`）：

```bash
export KUBECONFIG=/path/to/kubeconfig
kubectl get nodes -o wide
kubectl get pods -A
helm list -A
kubectl get --raw=/readyz && echo
```

在每个节点记录关键引导参数（restore peer URL 预检依据）：

```bash
sudo cat /etc/systemd/system/k3s.service | sed -n '1,220p'
sudo k3s --version | head -2
ip -4 addr show
```

重点记录：`--node-ip`、`--advertise-address`、`--flannel-iface`、节点 IP、快照来源节点。

## 4. 备份（必须）

在 first server（embedded etcd）：

```bash
sudo k3s etcd-snapshot save --name before-1.31-$(date +%Y%m%d-%H%M%S)
sudo k3s etcd-snapshot list
sudo ls -lh /var/lib/rancher/k3s/server/db/snapshots
```

将快照文件复制到离线/异机安全位置（仓库外），记录文件名、sha256、来源节点、时间、k3s 版本。

## 5. 升级执行（逐节点，先 server 后 agent）

> 一次只升级一个节点；每步验收通过再继续。不要并行升级 control-plane。

### 5.1 Server 节点

对每个 server（本基线通常单 server；多 server 按拓扑谨慎扩展）：

```bash
# 运维机：可选 drain（单 server 需评估业务中断）
kubectl drain <server-node> --ignore-daemonsets --delete-emptydir-data --timeout=300s || true

# 目标节点
sudo cp /usr/local/bin/k3s /usr/local/bin/k3s.bak.v1.30.14+k3s2
export INSTALL_K3S_VERSION=v1.31.14+k3s1
export INSTALL_K3S_MIRROR=cn  # 如需镜像加速
curl -sfL https://rancher-mirror.rancher.cn/k3s/k3s-install.sh | sudo -E sh -s - server
sudo systemctl daemon-reload
sudo systemctl restart k3s
```

验收：

```bash
sudo k3s --version | head -2
sudo kubectl get nodes -o wide
kubectl get --raw=/readyz && echo
kubectl get pods -A | egrep -v 'Running|Completed' || true
```

```bash
kubectl uncordon <server-node> || true
```

### 5.2 Agent 节点

```bash
kubectl drain <agent-node> --ignore-daemonsets --delete-emptydir-data --timeout=300s

# agent 节点
sudo cp /usr/local/bin/k3s /usr/local/bin/k3s.bak.v1.30.14+k3s2
export INSTALL_K3S_VERSION=v1.31.14+k3s1
export INSTALL_K3S_MIRROR=cn
curl -sfL https://rancher-mirror.rancher.cn/k3s/k3s-install.sh | sudo -E sh -s - agent
sudo systemctl daemon-reload
sudo systemctl restart k3s-agent
```

验收后 `kubectl uncordon <agent-node>`。重复直到所有节点升级。

## 6. 升级后验收

```bash
kubectl get nodes -o wide
kubectl get pods -A
helm list -A
kubectl get events -A --sort-by=.lastTimestamp | tail -60
```

业务 smoke（按实际填写）：Ingress/Service/关键 API/页面/Job。记录通过/失败与证据。

## 7. 回退决策树

> 先判断“要回退什么”：**版本/进程** 还是 **集群对象状态**。二进制回退不回滚 etcd 对象。

### A. 二进制回退（版本/进程异常，状态可接受）

适用：升级后组件版本/启动异常，但无不可接受的对象状态变化。证据：R1/R2 显示版本回退、节点可恢复，但 `after-upgrade` marker 仍在。

```bash
# 目标节点（server/agent 分别重启对应服务）
sudo cp /usr/local/bin/k3s.bak.v1.30.14+k3s2 /usr/local/bin/k3s
sudo chmod 0755 /usr/local/bin/k3s
sudo systemctl restart k3s        # server
# sudo systemctl restart k3s-agent  # agent
sudo k3s --version | head -2
kubectl get nodes -o wide
```

验收后仍需评估对象/schema 兼容性；不满足则进入 B。

### B. 受控 etcd snapshot restore（需要对象状态回滚）

适用：需要回到快照时点的集群对象状态。**破坏性**：停 server/agent、移动 `server/db`、cluster-reset；**不回滚 PV 数据**。

优先使用加固后的封装（已加 preflight/受控重装/marker 验收/peer URL guard）：

```bash
# k3s-ops.sh wrapper（便利封装）
./k3s-ops.sh restore -f <snapshot-name-or-path> \
  -v v1.30.14+k3s2 \
  -e v1.30.14+k3s2 \
  -c <pre-upgrade-marker-cm> \
  -a <post-upgrade-marker-cm> \
  -n <namespace> \
  -i <restore_node_ip>
```

或标准/Ansible 等价变量（主路径可直接审查 playbook）：

```bash
ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i <inventory> \
  ansible/playbooks/k3s-restore.yml \
  -e snapshot_file=<snapshot> \
  -e restore_k3s_version=v1.30.14+k3s2 \
  -e expected_k3s_version=v1.30.14+k3s2 \
  -e verify_configmap=<pre-marker> \
  -e verify_absent_configmap=<post-marker> \
  -e verify_namespace=<ns> \
  -e restore_node_ip=<node_ip>
```

验收：节点版本/Ready、`/readyz`、`baseline` marker 存在、`after-upgrade` marker 消失、系统 Pod、业务 smoke。记录 `db.bak.restore-*` 位置。

### C. 停止自动化（人工恢复）

出现任一情况立即停止封装 restore，保留现场证据：

- preflight 报 **snapshot peer URL mismatch**（R2：`10.0.2.15:2380` vs 期望 node-ip）且无已演练人工方案。
- cluster-reset 后 API/etcd 起不来，日志出现 member/bootstrap/token/peer URL 不一致。
- 恢复后对象状态不符合预期，或 PV/应用语义损坏。
- 多 server/agent 拓扑下成员关系异常。

处理：仅在隔离环境演练过的单节点人工 runbook 下操作；必要时重建节点并恢复应用层备份。

## 8. 禁止项

- 不在未快照/未验收/未演练情况下跨 minor。
- 不把二进制回退当作对象状态回滚。
- 不在 peer URL mismatch 时加 `-p` 直接硬跑，除非已在相同拓扑隔离演练并有人工回收方案。
- 不假设 etcd restore 会回滚 PV 数据。
- 不跳过 ingress-nginx blocker 直接进 1.31 实际窗口。

## 9. 执行记录模板

```text
- [ ] NO-GO 检查通过
- [ ] preflight 已记录
- [ ] 快照已保存/异地复制/sha256
- [ ] server 升级完成并验收
- [ ] agent 升级完成并验收
- [ ] 升级后验收通过
- [ ] 回滚未触发 / 已按 A|B|C 执行
- [ ] 证据归档（命令、输出、截图/日志、快照名、db.bak 路径）
```
