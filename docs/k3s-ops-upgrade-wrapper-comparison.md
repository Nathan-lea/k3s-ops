# k3s-ops.sh upgrade -v 封装对照（L1，不动集群）

> 状态：**L1 静态/测试证据，不改集群**。  
> 日期：2026-11-27  
> 目标：回答 `k3s-ops.sh upgrade -v <version>` 到底做了什么、没做什么，以及它与第 57 章标准升级流程的差距。

## 1. 调用链（代码事实）

```text
k3s-ops.sh upgrade -v <version>
  -> cmd_upgrade()                      # k3s-ops.sh:302-318
  -> run_playbook(k3s-upgrade.yml, -e k3s_upgrade_version=...)
      -> ensure_inventory()             # k3s-ops.sh:74-97, 100-109
      -> export ANSIBLE_CONFIG
      -> ansible-playbook -i <runtime inventory> ansible/playbooks/k3s-upgrade.yml -e k3s_upgrade_version=...
          -> play: hosts=all, gather_facts=true, serial=1, k3s_action=upgrade
          -> role k3s-manage/tasks/main.yml includes tasks/upgrade.yml
              -> k3s-common/tasks/assert-k3s-arch.yml
              -> set_fact k3s_upgrade_download_url (default rancher-mirror)
              -> get_url download k3s binary -> {{ k3s_server_bin }}
              -> systemd restart k3s / k3s-agent
              -> kubectl wait --for=condition=Ready node/{{ inventory_hostname }} --timeout=120s (delegate_to first_server_host)
```

关键文件：

| 文件 | 作用 | 关键行为 |
|---|---|---|
| `k3s-ops.sh` | CLI 入口 | 解析 `-v`，生成运行时 inventory，设置 `ANSIBLE_CONFIG`，调用 `k3s-upgrade.yml` |
| `ansible/playbooks/k3s-upgrade.yml` | 升级 playbook | `hosts: all`, `serial: 1`, `gather_facts: true`, `k3s_action: upgrade` |
| `ansible/roles/k3s-manage/tasks/main.yml` | 动作分发 | `include_tasks: "{{ k3s_action }}.yml"` |
| `ansible/roles/k3s-manage/tasks/upgrade.yml` | 实际升级 | 下载二进制、重启 service、等待 Ready |
| `ansible/roles/k3s-common/tasks/assert-k3s-arch.yml` | 架构检查 | 仅支持 x86_64/amd64/aarch64/arm64；提示可覆盖 `k3s_upgrade_download_url` |
| `ansible/group_vars/all.yml` | 默认变量 | `k3s_version`/下载镜像/架构映射；**upgrade 默认 URL 由 upgrade.yml 自己计算** |

## 2. 封装实际能保证什么

基于代码与现有测试，可认为封装**能提供**：

| 能力 | 证据 | 说明 |
|---|---|---|
| 参数传递 | `k3s-ops.sh:313-318`；`tests/test-k3s-ops-inventory.sh` 断言 `k3s-upgrade.yml.*k3s_upgrade_version=v1.31.0+k3s1` | CLI 要求 `-v`，并通过 `-e k3s_upgrade_version=...` 传入 |
| 运行时 inventory 生成 | `k3s-ops.sh:74-109`；`tests/test-k3s-ops-inventory.sh` A/B/C | 避免依赖 tracked placeholder inventory；支持 `K3S_OPS_INVENTORY` 覆盖 |
| 显式 Ansible 配置 | `k3s-ops.sh:107`；`test-k3s-ops-inventory.sh` 断言 `ANSIBLE_CONFIG=.../ansible/ansible.cfg` | 减少 cwd/环境导致的 Ansible 配置漂移 |
| 架构检查 | `k3s-common/tasks/assert-k3s-arch.yml` | 非支持架构直接失败，避免误下错二进制名 |
| 下载 URL 可覆盖 | `upgrade.yml:7-10` | 默认 Rancher mirror；可通过 `k3s_upgrade_download_url` 覆盖 |
| 逐节点串行 | `k3s-upgrade.yml: serial: 1` | 不会同时重启所有节点 |
| 升级后单节点 Ready 等待 | `upgrade.yml:27-30` | 每节点重启后 `kubectl wait --for=condition=Ready ... --timeout=120s` |

## 3. 封装不保证/不做什么（与 57 章标准流程对照）

| 57 章标准流程要求 | `k3s-ops.sh upgrade -v` | 结论 |
|---|---|---|
| 升级前版本评估/兼容矩阵 | **不做**。只接受版本字符串 | 需人工先查 k3s/K8s/组件兼容性 |
| 升级前 etcd 快照 | **不做**。`k3s-backup.yml` 存在但 upgrade 不调用 | 必须手工先备份 |
| 旧二进制备份 | **不做**。`get_url force=yes` 直接覆盖 | 无本地快速回退副本 |
| 升级前健康门禁（节点 Ready、etcd、磁盘、异常 Pod 基线） | **不做** | 可能把旧问题带入升级窗口 |
| server/agent 角色顺序策略 | **部分**。`hosts: all, serial: 1`，但未显式按 server->agent 排序 | 依赖 inventory/执行顺序；应显式约束 |
| drain/cordon/PDB 保护 | **不做** | agent 上有状态/单副本业务可能中断 |
| 组件兼容性暂停（Rancher/Kyverno webhook 等） | **不做** | Kyverno agent 单点 + `failurePolicy=Fail` 风险需人工处理 |
| 升级后全量验收（pods/events/helm/ingress/API/关键业务） | **不做**。仅单节点 Ready wait | “节点 Ready”不等于“业务健康” |
| 失败止损/回滚自动化 | **不做** | 失败后需人工判断：修复、恢复二进制、或 etcd restore |
| 版本基线回写（nodes.yml/group_vars/docs） | **不做** | 容易出现“集群已升级、配置未更新”漂移 |
| 审计记录/证据落盘 | **部分**。有日志库，但无升级报告产物 | 需要人工记录命令、输出、快照名、验收 |

## 4. 测试覆盖现状

已覆盖（L1）：

- `tests/test-k3s-ops-inventory.sh`：`upgrade -v` 退出码 0、调用 `k3s-upgrade.yml`、传递 `k3s_upgrade_version`、使用运行时 inventory、导出 `ANSIBLE_CONFIG`。**stubbed ansible-playbook，不执行真实升级。**
- `tests/test-gen-inventory.sh`：运行时 inventory 生成、key mode、结构。
- `bash -n k3s-ops.sh ...`：shell 语法检查。

未覆盖（需要 L2/L3 才能证明）：

- 真实 `ansible-playbook --check` / diff 行为（需要 Ansible+目标主机语义环境）。
- 对真实节点执行升级的行为（下载、替换、重启、Ready）。
- 失败路径：下载失败、重启失败、Ready 超时、部分节点已升级部分未升级。
- server-first 顺序在多 server/混合拓扑下的保证。
- 升级前快照/门禁缺失造成的实际后果（应由文档和后续方案明确，而不是靠封装假装安全）。

## 5. L1 结论

`k3s-ops.sh upgrade -v` 是**薄封装**：它解决了“用生成的 inventory 调 upgrade playbook”的便利性问题，但**不是完整升级流程**。它适合作为受控环境的执行器，不应被表述为“安全升级命令”。

对本仓库的明确建议：

1. 文档中继续将标准命令作为主流程，`k3s-ops.sh upgrade -v` 仅作便利入口。
2. 若后续增强封装，优先补：升级前快照钩子/提示、显式 server->agent 顺序、升级前健康检查、升级后全量验收、失败止损提示。
3. 在增强前，不要在跨 minor 场景直接依赖该封装。

## 6. 证据命令（本次执行）

```bash
# 静态检查
bash -n k3s-ops.sh
rg -n "upgrade|k3s_upgrade" k3s-ops.sh ansible tests docs/k8s-tutorial/57-集群升级实战.md
sed -n '302,340p' k3s-ops.sh
sed -n '1,220p' ansible/playbooks/k3s-upgrade.yml
sed -n '1,220p' ansible/roles/k3s-manage/tasks/upgrade.yml

# 现有 stub 测试
bash tests/test-k3s-ops-inventory.sh   # 24 passed
bash tests/test-gen-inventory.sh        # 27 passed
```
