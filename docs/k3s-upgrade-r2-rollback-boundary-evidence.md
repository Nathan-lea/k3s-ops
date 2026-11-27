# R2 跨 minor 回滚边界实操证据（隔离环境）

> 状态：**已实操**。  
> 日期：2026-11-27  
> 环境：`tmp/rollback-lab-r2`（gitignored，已销毁），`k3s-r2-lab`，`192.168.60.0/24`，1 server 2c/2G，bento/ubuntu-22.04，embedded etcd，`--node-ip 192.168.60.10 --flannel-iface eth1`。教学集群演练期间停机，演练后恢复。

## 目标

验证 R2：跨 minor 升级（`v1.30.14+k3s2 -> v1.31.14+k3s1`）后出现升级后状态变化时，**二进制回退**与**etcd 快照 restore**的边界。

## 基线

- 安装 `v1.30.14+k3s2`（embedded etcd）。
- 创建 `ns/rollback-demo`，`cm/baseline`，Deployment `web`（`nginx:1.27-alpine`）并 Ready。
- 保存快照：`r2-baseline-k3s-r2-lab-server-1-1795758418`。

## 升级后变化

- 升级到 `v1.31.14+k3s1` 成功，节点 Ready。
- 创建 `cm/after-upgrade`。
- 将 `web` 镜像更新为 `nginx:1.27.1-alpine`（演练中该 tag 拉取失败，回滚了 deployment 以保持集群可用；`after-upgrade` marker 保留作为状态变化样本）。

## 观察 1：二进制回退（PASS，但仅版本/进程）

将节点 k3s 二进制回装 `v1.30.14+k3s2` 并启动服务：

- 结果：节点重新 Ready，`kubectl get nodes` 显示 `v1.30.14+k3s2`。
- 但集群状态**未回滚**：`cm/after-upgrade` 仍存在。
- 结论：**二进制回退 != 集群状态回滚**。它适合“升级后进程/版本问题、尚未造成不可接受状态变化”的快速回退；若需要回到快照时点对象状态，必须用 etcd restore。

## 观察 2：受控 etcd restore（FAIL，peer URL 不兼容）

在二进制已回到 `v1.30.14+k3s2`、版本匹配的情况下，运行加固版 `k3s-restore.yml`（带 `expected_k3s_version` + marker 验收）：

- `cluster-reset --cluster-reset-restore-path=...` 执行完成，旧 db 被移到 `db.bak.restore-*`。
- 启动 k3s 失败循环，日志：

```text
Failed to test etcd connection: this server is a not a member of the etcd cluster.
Found [k3s-r2-lab-server-1-3a1b1527=https://10.0.2.15:2380], expect: k3s-r2-lab-server-1-3a1b1527=https://192.168.60.10:2380
```

- 检查恢复后的 snapshot db 文本可见 `https://10.0.2.15:2380`。该值与快照/历史成员信息相关，而当前节点以 `--node-ip 192.168.60.10 --flannel-iface eth1` 运行，成员 peer URL 期望不一致。
- 结论：**restore 成功与否不仅取决于 k3s 版本，还取决于节点身份/网络引导参数与快照内 etcd 成员信息的一致性**。版本 preflight 通过不足以保证 restore 可启动。

## R2 边界总结

| 场景 | 能力 | 边界 |
|---|---|---|
| 二进制回退 | 快速回退进程/节点版本 | 不回滚 etcd/K8s 对象状态；跨 minor 后若已有 schema/状态变更，仅回退二进制有风险 |
| etcd snapshot restore | 回滚集群对象状态到快照时点 | 破坏性；不回滚 PV；需要版本兼容、token/引导参数/peer URL 一致；可能受 `--node-ip`/advertise 地址变化影响 |
| 受控封装 restore | 已避免危险 no-op，能做 preflight/备份 db/marker 验收 | 仍不能宣称通用；遇到 peer URL mismatch 需专门单节点恢复 runbook（重建成员/受控引导参数）或在隔离环境先演练 |

## 对 runbook/封装的要求

1. restore 前记录：k3s 版本、`--node-ip`、`--advertise-address`、`--flannel-iface`、snapshot 来源节点/时间。
2. preflight 增加 peer/advertise URL 风险提示；单节点恢复需文档化处理方式（谨慎，单独演练）。
3. 恢复决策树：
   - 仅版本/进程异常且状态可接受 -> 二进制回退；
   - 需要对象状态回滚 -> etcd restore，必须同版本/兼容引导参数，先隔离演练；
   - peer URL/bootstrap 不兼容 -> 停止自动化，走人工恢复 runbook。
4. post-verify 必须包含：节点版本、Ready、关键对象 marker、系统 Pod、业务 smoke；记录 `db.bak.restore-*` 位置。

## 封装落地状态（2026-11-27）

- `ansible/playbooks/k3s-restore.yml` 已增加 snapshot peer URL preflight：从快照 db 提取 `https://<ip>:2380` 成员地址，与 `restore_node_ip`/`node_ip` 期望比较；不匹配默认 fail-fast，提示 R2 启动循环风险。
- `k3s-ops.sh restore` 新增 `-i restore_node_ip` 与 `-p`（`allow_peer_url_mismatch=true`，仅已演练人工单节点恢复）。
- 仍未自动修复 peer URL mismatch：该场景需专门单节点恢复 runbook/隔离演练，禁止静默继续。

## 证据

- 本地隔离日志：`tmp/rollback-lab-r2/evidence/`（gitignored）
- 关键文件：`baseline.log`、`after-upgrade.log`、`r2-binary-rollback.log`、`r2-controlled-restore.log`
