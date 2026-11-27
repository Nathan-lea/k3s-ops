# R4 封装 restore 端到端验证（隔离环境）

> 状态：**已实操。旧封装危险成功已修复；通用跨 minor restore 仍未宣称支持。**  
> 日期：2026-11-27  
> 环境：隔离 `tmp/rollback-lab-r4`（gitignored），`k3s-r4-lab`，`192.168.58.0/24`，1 server 2c/2G，bento/ubuntu-22.04，embedded etcd。

## 目标

验证 `ansible/playbooks/k3s-restore.yml`（`k3s-ops.sh restore -f` 底层）在跨 minor 升级后回滚场景的端到端行为，并将其加固为受控 restore 流程。

## 场景

1. 基线：`v1.30.14+k3s2`，`--cluster-init`，创建 `ns/rollback-demo` + `cm/baseline`，保存 snapshot `r4b-baseline-k3s-r4-lab-server-1-1795752432`。
2. 升级：手动二进制升级到 `v1.31.14+k3s1`，节点 Ready，创建 `cm/after-upgrade`。
3. 执行封装 restore：`ansible-playbook ... k3s-restore.yml -e snapshot_file=<snapshot>`。

## 发现 1：旧 playbook 危险成功（FAIL，已修复）

旧实现 `args.creates: /var/lib/rancher/k3s/server/db/etcd`，dirty db 存在时跳过真实 restore；playbook 返回成功，但节点仍 `v1.31.14+k3s1`、`cm/after-upgrade` 仍存在。**危险成功假象**。

## 修复 1/2/3（已落地）

### 1) Preflight 合约

`k3s-restore.yml` 增加 preflight：
- 必须提供 `snapshot_file`，支持绝对路径或 `k3s_etcd_snapshot_dir/<name>`。
- 快照必须存在且为普通文件。
- 必须存在 `{{ k3s_data_dir }}/server/db/etcd`，否则 fail-fast（本流程仅支持 embedded etcd）。
- 读取当前 k3s 版本；若提供 `expected_k3s_version` 且不匹配，默认拒绝。
- 跨 minor 默认拒绝，除非显式提供 `restore_k3s_version=<compatible-version>`（受控重装）或 `allow_version_mismatch=true`（仅已演练手工场景）。

`k3s-ops.sh restore` 增加参数与强提示：
- `-v restore_k3s_version`：恢复前在所有 server/agent 重装指定 k3s（二进制安装，`INSTALL_K3S_SKIP_START=true`）。
- `-e expected_k3s_version`：期望版本护栏。
- `-c/-a/-n`：验收 ConfigMap 存在/不存在检查。
- `-m`：显式放宽版本护栏（危险，仅演练后使用）。

### 2) 受控恢复策略

playbook 流程调整为：
1. 停止所有 server、agent。
2. 可选：按 `restore_k3s_version` 重装所有节点 k3s 二进制（不启动）。
3. stage 快照到 `server/restore-staging`。
4. 将现有 `server/db` 移到 `db.bak.restore-*`（不再使用危险 `creates` 短路）。
5. 将快照放回 `k3s_etcd_snapshot_dir`，执行 `k3s server --cluster-reset --cluster-reset-restore-path=...`。
6. 启动 first server，等待 6443，`/readyz` 通过后启动其余 server/agent。

策略边界（文档化）：
- **支持方向**：embedded etcd 快照、同版本 restore、或“显式二进制回退 + restore”的受控流程。
- **不宣称支持**：跨 minor dirty-state 一键通用 restore；sqlite/external datastore；PV 数据回滚。
- **R4 发现的额外边界**：即使修复 no-op，仍可能遇到 etcd member peer URL 与当前节点 advertise/node-ip 不一致（R4 证据：Found `10.0.2.15:2380`, expect `192.168.58.10:2380`）。这类情况需专门单节点/HA 恢复 runbook，不应静默成功。

### 3) Post-verify

playbook 增加：
- `kubectl get --raw=/readyz` 重试通过。
- `kubectl get nodes -o wide`。
- 可选 `verify_configmap` 存在检查。
- 可选 `verify_absent_configmap` 不存在检查（用于“升级后 marker 应消失”验收）。
- summary 明确提示：旧 db 备份位置、etcd restore 不回滚 PV、需人工验证业务语义。

## 结论

- 旧封装危险成功：**已修复**。
- 修复后封装：**可阻止已知危险路径并执行受控流程**，但跨 minor/peer-URL/bootstrap 不兼容场景仍可能失败；因此 `restore` 仍是高风险操作，必须 preflight + 隔离演练 + post-verify。

## 证据

- 本地隔离日志：`tmp/rollback-lab-r4/evidence/`（gitignored）
- 关键失败样本：`r4b-restore-fixed.log`，etcd member peer URL mismatch
