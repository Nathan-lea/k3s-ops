# k3s 跨 minor `1.30 -> 1.31` Runbook 隔离彩排证据

> 日期：2026-11-27  
> 环境：隔离 Vagrant lab `tmp/rollback-lab-rehearsal`（gitignored），`bento/ubuntu-22.04`，1 server（2c/2G，192.168.61.10），k3s embedded etcd。  
> 目标：按 `docs/k3s-cross-minor-1.30-1.31-runbook.md` 验证可执行性，重点覆盖升级后受控 etcd restore。

## 结果摘要

| 步骤 | 结果 | 说明 |
|---|---|---|
| 基线准备 | PASS | `v1.30.14+k3s2` Ready，系统 Pod Running/Completed；保存 `reh-baseline-*` 快照；创建 `rollback-demo/baseline`。 |
| 升级 1.30→1.31 | PASS | 手工替换 k3s 二进制到 `v1.31.14+k3s1`，`systemctl restart k3s` 后节点 Ready；创建 `after-upgrade` marker。 |
| 加固 restore 首跑 | **FAIL（已修复）** | playbook preflight/peer URL guard 通过，cluster-reset 执行后 systemd 启动 k3s 失败：`this server is a not a member of the etcd cluster. Found [...]=https://10.0.2.15:2380, expect: ...=https://192.168.61.10:2380`。 |
| 手工受控恢复 | PASS | `k3s server --cluster-reset --cluster-reset-restore-path=... --node-ip=192.168.61.10 --flannel-iface=eth1 --token=...` 后启动成功；版本回到 `v1.30.14+k3s2`，节点 Ready，etcd peer URL 为 `192.168.61.10:2380`。 |
| 修复后 playbook 重跑 | PASS | 修复 cluster-reset 参数注入与备份目录唯一性后，`k3s-restore.yml` 受控恢复 PASS：`ok=29 changed=6 failed=0`，post-verify 通过，`baseline` 存在、`after-upgrade` 缺失。 |

## 关键发现

1. **cluster-reset 必须携带节点引导参数**。未传 `--node-ip/--flannel-iface/--advertise-address` 时，k3s 可能按默认网卡选 peer URL（本 lab 为 NAT `10.0.2.15:2380`），与实际服务参数 `192.168.61.10` 冲突，导致 R2 同类启动循环。
2. **快照内容 preflight 不足**。快照中 peer URL 为 `192.168.61.10:2380`，preflight 通过，但 restore 过程仍可写入错误 peer URL。修复后 playbook 从 systemd service 提取参数，并在 `/readyz` 后校验 etcd db peer URL。
3. **备份目录需唯一**。`db.bak.restore-<timestamp>` 在同秒重试/预创建冲突时可导致 `mv` 失败；修复为追加 epoch。

## 代码修复

- `ansible/playbooks/k3s-restore.yml`
  - `k3s_restore_db_backup` 增加 epoch 后缀，避免重试冲突。
  - cluster-reset 前检测 `/etc/systemd/system/k3s.service` 的 `--node-ip/--advertise-address/--flannel-iface/...`，与显式 `restore_node_ip`/extra args 合并后传入 `k3s server --cluster-reset`。
  - `/readyz` 后增加 etcd member peer URL post-check，实际 peer URL 与期望 node-ip 不一致则失败。

## 仍未覆盖 / 阻塞

- **ingress-nginx 1.31 处置仍是 NO-GO**（本次明确跳过）。
- 未在真实多节点/多 server 拓扑彩排；多 server restore 仍需单独演练。
- 未覆盖 PV/业务语义回滚；仅验证 etcd 对象状态 marker。
- `k3s-ops.sh` 便利封装未端到端跑通本次 lab（首次受控 restore 受 install script 下载失败影响）；标准命令与 playbook 主路径已验证。

## 结论

Runbook 的升级与受控 restore 主路径在**单 server embedded etcd 隔离 lab** 上可执行，但必须带节点引导参数并做 peer URL post-check。ingress-nginx 处置完成前，不得进入实际 `1.30->1.31` 窗口。