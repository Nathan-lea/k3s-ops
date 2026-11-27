# R4 封装 restore 端到端验证（隔离环境）

> 状态：**已实操（失败样本）**。  
> 日期：2026-11-27  
> 环境：隔离 `tmp/rollback-lab-r4`（gitignored），`cluster_name=k3s-r4-lab`，`192.168.58.0/24`，1 server 2c/2G，bento/ubuntu-22.04，k3s `v1.30.14+k3s2` embedded etcd。教学集群演练前后已关停/恢复。

## 目标

验证仓库封装 `ansible/playbooks/k3s-restore.yml`（`k3s-ops.sh restore -f` 底层 playbook）在“跨 minor 升级后回滚”场景的端到端行为。

## 场景

1. 基线：安装 v1.30.14+k3s2（`--cluster-init`），创建 `ns/rollback-demo`、`cm/baseline`，保存 etcd snapshot `r4-baseline-k3s-r4-lab-server-1-1795751263`。
2. 升级：手动升级到 `v1.31.14+k3s1`，节点 Ready；创建 `cm/after-upgrade`。
3. 封装 restore：运行

```bash
ANSIBLE_CONFIG=ansible/ansible.cfg ANSIBLE_STDOUT_CALLBACK=default ANSIBLE_CALLBACK_RESULT_FORMAT=yaml \
ansible-playbook -i tmp/rollback-lab-r4/inventory.yml ansible/playbooks/k3s-restore.yml \
  -e snapshot_file=/var/lib/rancher/k3s/server/db/snapshots/r4-baseline-k3s-r4-lab-server-1-1795751263
```

## 观察结果

Playbook **返回成功**（`ok=5 changed=3 failed=0`），但**restore 语义未达成**：

- `Restore from snapshot` task：`changed`。
- 恢复后检查：节点仍为 `v1.31.14+k3s1` Ready；`rollback-demo` 中 `after-upgrade` ConfigMap **仍存在**；`baseline` 也存在。
- 快照文件仍在，etcd 目录仍存在。

## 结论：R4 = FAIL（危险成功）

封装在该场景下产生“绿色成功”假象，但未回滚集群状态。

## 根因（代码事实）

`ansible/playbooks/k3s-restore.yml`：

```yaml
- name: Restore from snapshot
  command: >
    k3s server
    --cluster-reset
    --cluster-reset-restore-path={{ snapshot_file }}
  args:
    creates: /var/lib/rancher/k3s/server/db/etcd
```

- `creates: /var/lib/rancher/k3s/server/db/etcd` 在 dirty 升级后 data-dir 存在时会**跳过 cluster-reset**（本次 task 仍 reported changed 需要结合完整输出复核，但实际集群状态未回滚；无论如何 restore 未生效）。
- playbook 未做：版本/token 兼容校验、停服后 data-dir 清理策略、snapshot 路径/名称规范化、恢复后二进制版本处理、全量语义验收（对象/版本/业务 smoke）。
- playbook 先 `systemctl stop k3s`，但后续 `k3s server --cluster-reset ...` 的前提和 data-dir 状态未被管理；跨 minor 场景还需要二进制/引导数据兼容处理。

## 对 `k3s-ops.sh restore -f` 的影响

`k3s-ops.sh restore -f` 仅做交互确认并调用该 playbook；因此当前封装**不应被视为可靠 restore 路径**，尤其跨 minor/dirty data-dir 场景。

## 建议修复方向（后续单独变更）

1. 明确 restore 合约：仅支持“同版本/同 token/干净 data-dir”或实现完整安全流程。
2. 去掉危险的 `creates` 短路，改为显式 preflight + 受控 data-dir 备份/清理。
3. 增加 preflight：snapshot 存在性、快照路径解析、k3s 版本兼容、token/CA 备份、磁盘空间、确认目标。
4. 增加 post-restore 验收：节点/API Ready、目标快照前对象存在、快照后 marker 不存在（可选 smoke）、版本提示。
5. 文档强标“破坏性、需隔离演练”，CLI 默认拒绝除非强确认。

## 证据

- `tmp/rollback-lab-r4/evidence/restore-playbook-run2.log`
- `tmp/rollback-lab-r4/evidence/post-restore-check.log`
