# R4 封装 restore 端到端验证（隔离环境）

> 状态：**已实操，发现危险成功 + 跨 minor restore 边界**。  
> 日期：2026-11-27  
> 环境：隔离 `tmp/rollback-lab-r4`（gitignored），`k3s-r4-lab`，`192.168.58.0/24`，1 server 2c/2G，bento/ubuntu-22.04，embedded etcd。教学集群演练期间已关停，演练后恢复。

## 目标

验证 `ansible/playbooks/k3s-restore.yml`（`k3s-ops.sh restore -f` 底层）在跨 minor 升级后回滚场景的端到端行为。

## 场景

1. 基线：`v1.30.14+k3s2`，`--cluster-init`，创建 `ns/rollback-demo` + `cm/baseline`，保存 snapshot `r4b-baseline-k3s-r4-lab-server-1-1795752432`。
2. 升级：手动二进制升级到 `v1.31.14+k3s1`，节点 Ready，创建 `cm/after-upgrade`。
3. 执行封装 restore：`ansible-playbook -i tmp/rollback-lab-r4/inventory.yml ansible/playbooks/k3s-restore.yml -e snapshot_file=<snapshot>`。

## 发现 1：旧 playbook 危险成功（FAIL）

旧实现 `args.creates: /var/lib/rancher/k3s/server/db/etcd`，在 dirty db 存在时跳过实际 restore；playbook 返回 `ok/changed/failed=0`，但节点仍 `v1.31.14+k3s1`，`cm/after-upgrade` 仍存在。**这是危险成功假象**。

## 修复（本次已落地）

`ansible/playbooks/k3s-restore.yml` 已修复/加固：
- `become: yes`、`any_errors_fatal: true`
- snapshot 路径规范化（绝对路径或 `k3s_etcd_snapshot_dir` 下文件名）
- 停止所有 server + agent
- restore 前 stage 快照，再将现有 `{{ k3s_data_dir }}/server/db` 移到 `db.bak.restore-*`（避免危险短路）
- 执行 `k3s server --cluster-reset --cluster-reset-restore-path=...`
- 启动 first server、等待 6443、启动其余 server/agent
- `kubectl get --raw=/readyz` 校验 + restore 摘要

## 发现 2：修复后跨 minor restore 仍失败（FAIL，需后续策略）

重跑修复版 playbook 时，`cluster-reset` 执行完成，但启动 k3s 失败：

```
Failed to test etcd connection: this server is a not a member of the etcd cluster.
Found [k3s-r4-lab-server-1-ad1e6f1d=https://10.0.2.15:2380], expect: k3s-r4-lab-server-1-ad1e6f1d=https://192.168.58.10:2380
```

同时节点二进制仍是 `v1.31.14+k3s1`，而快照来自 `v1.30.14+k3s2`。说明跨 minor/dirty 状态 restore 不是“清 db + cluster-reset”就够，还需明确处理：
- **版本兼容**：restore 执行与恢复后启动的 k3s 二进制应与快照/目标版本策略一致；跨 minor 回退通常需先回退二进制或按受控流程处理。
- **etcd member peer URL/引导参数**：快照内成员地址与当前节点 `--node-ip/--advertise-address` 可能不一致，需要专门恢复流程（单节点可考虑 reset/重建参数，但要谨慎）。
- **preflight**：应检查 snapshot 存在、db 备份空间、当前/目标版本、token、是否 embedded etcd、是否单节点/HA，并明确危险提示。
- **post-verify**：应验证 API ready、节点版本、关键对象（快照前 marker 存在/快照后 marker 不存在）、系统 pod。

## 结论

- R4 对旧封装：**FAIL（危险成功）**，已修复最严重的 no-op 短路。
- R4 对修复封装：**仍 FAIL（跨 minor/成员地址边界）**，不能宣称通用 restore 可用。
- `k3s-ops.sh restore -f` 在文档/CLI 上应标注为高风险实验性能力，使用前需隔离演练并确认版本/拓扑/快照兼容。

## 证据

- 隔离演练日志：`tmp/rollback-lab-r4/evidence/`（gitignored，本地保留）
- 关键失败日志：`r4b-restore-fixed.log`、journal 中 etcd member peer URL mismatch
