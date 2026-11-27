# k3s 升级回滚/隔离演练证据（R1/R3 最小闭环）

> 状态：**已在隔离 Vagrant 环境实操（最小闭环）**，不影响当前教学集群。  
> 日期：2026-11-27  
> 对应设计：`docs/k3s-upgrade-rollback-rehearsal-design.md`

## 1. 环境与隔离

- 教学集群 VM 先执行 `./k3s-ops.sh down` 优雅关机；演练结束后已 `vagrant destroy -f` 隔离 VM，教学 VM 仍处于 poweroff（未自动恢复）。
- 隔离目录：`tmp/rollback-lab/`（gitignored），`cluster_name=k3s-rb-lab`，子网 `192.168.57.0/24`。
- 节点：`k3s-rb-lab-server-1` `192.168.57.10`，2c/2G，`bento/ubuntu-22.04`，VirtualBox。
- 基线安装：`INSTALL_K3S_VERSION=v1.30.14+k3s2`，`--cluster-init`（embedded etcd），`--disable traefik --disable servicelb --node-ip 192.168.57.10 --flannel-iface eth1`。
- 镜像拉取问题：docker.io 直连超时，配置 `/etc/rancher/k3s/registries.yaml` 使用 `docker.1panel.live`/DaoCloud 镜像后恢复。

## 2. R3：etcd 快照 restore（跨 minor 升级后回滚）

| 步骤 | 结果 | 证据要点 |
|---|---|---|
| 基线对象 | PASS | `ns/rollback-demo` + `cm/baseline state=before-upgrade,version=v1.30.14+k3s2` |
| etcd 快照 | PASS | `r3b-baseline-k3s-rb-lab-server-1-1795749924` 保存成功 |
| 升级 1.30.14 -> 1.31.14 | PASS | 节点 Ready，`v1.31.14+k3s1`，containerd `2.1.5-k3s1.32` |
| 升级后标记 | PASS | 创建 `cm/after-upgrade` |
| restore | PASS（有约束） | 停 k3s、清理 server db、放回快照文件、用 v1.30.14 二进制执行 `k3s server --cluster-reset --cluster-reset-restore-path=<file> --token rollback-lab-token ...`，再启动 k3s |
| 验收 | PASS | 节点回到 `v1.30.14+k3s2` Ready；`rollback-demo` 仅有 `baseline`、`kube-root-ca.crt`；`after-upgrade` 消失 |

**R3 结论**：嵌入式 etcd 快照 restore 可回滚集群对象状态；跨 minor 后 restore 需要明确的版本/token/data-dir 处理，不可当“一键无脑回退”。

## 3. R1：二进制回退

| 步骤 | 结果 | 证据要点 |
|---|---|---|
| 从 1.30.14 升级到 1.31.14 | PASS | 节点 Ready，版本 `v1.31.14+k3s1` |
| 二进制回退到 1.30.14 | PASS（短暂 NotReady） | 替换备份二进制并重启 k3s；短暂 NotReady 后恢复 Ready |
| 数据对象 | PASS | `rollback-demo` ConfigMap 保留 |

**R1 结论**：在该干净场景下二进制回退可行，但不能替代存在 schema/数据不兼容时的 etcd restore；回退后仍需全量验收。

## 4. 关键边界/失败样本

1. **缺少 `--cluster-init`**：默认 SQLite，`k3s etcd-snapshot save` 报 `etcd datastore disabled`。R3 必须 embedded etcd。
2. **`--cluster-reset-restore-path` 需要文件路径**：传快照名报 `snapshot path does not exist`。
3. **dirty data-dir 原地 restore 风险**：在 v1.31.14+k3s1 dirty 环境直接 reset 出现 `bootstrap data already found and encrypted with different token` / 成员不匹配症状；清理 db + 同版本/同 token + 快照文件路径恢复成功。
4. **对仓库封装的含义**：`ansible/playbooks/k3s-restore.yml` 中 `cluster-reset` 任务有 `args.creates: /var/lib/rancher/k3s/server/db/etcd`，在 dirty data-dir 场景可能跳过 restore；`k3s-ops.sh restore -f` 缺少快照路径/名称解析、版本/token 兼容检查、data-dir 策略和全量验收。R4 需专门隔离验证后再决定修复。

## 5. 未覆盖

- R2：跨 minor 升级后出现不兼容数据/schema 的回退边界。
- R4：`k3s-ops.sh restore -f` / `k3s-restore.yml` 封装端到端验证。
- 多 server/agent 拓扑 restore。
