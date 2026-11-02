# k3s-ops 测试

本地测试套件，**随仓库一起维护**：不依赖真实 VM，`bash tests/run-all.sh` 一条命令跑完。

## 运行

```bash
bash tests/run-all.sh              # 全部
bash tests/run-all.sh node-names   # 只跑名字匹配的
```

退出码 0 = 全部通过。

## 结构

```
tests/
├── README.md               # 本文
├── run-all.sh              # 统一入口（自动发现 test-*.sh）
├── lib/harness.sh          # 脚手架：stub 隔离、断言、仓库指纹保护
├── stubs/                  # 假外部命令（vagrant / ansible-playbook / kubectl）
├── test-gen-inventory.sh   # Ansible inventory 生成（含 Windows role: ops）
├── test-node-names.sh      # 节点名解析 + down 子命令 + kubeconfig + status
└── test-vbox-archive.sh    # VirtualBox 日志归档
```

新增测试：写一个 `test-xxx.sh`，`source lib/harness.sh`，用 `check` / `ok` / `bad` 断言，
结尾调 `finish "测试名"`。`run-all.sh` 会自动发现。

## 覆盖范围

**test-node-names.sh（44 例）**

| 组 | 内容 |
|----|------|
| A | `up` / `down` / `ssh` / `add-node` / `remove-node` 对短名与完整主机名的解析一致 |
| B | `add-node` 按 nodes.yml 里的角色选对 playbook（server / agent） |
| C | 节点不存在时报错退出，且完全不调用 vagrant |
| D | `down` 的选项：`-f` / `-s` / 长选项 / 顺序颠倒 / 互斥 / 未知选项 / 参数过多 |
| E | `kubeconfig` 节点名解析 + **产物必须是合法 YAML 且未混入日志** |
| F | 集群名不再硬编码（换 `cluster_name` 后主机名随之变化） |
| F2 | 拉取失败、拉到非 kubeconfig 内容时报错而非静默产出坏文件 |
| G | `status` 在宿主机非 root 下可执行，`/var/log` 不可写时自动降级 |
| H | 仓库敏感文件（`kubeconfig`、`logs/k3s-ops.log`）未被测试改动 |

**test-gen-inventory.sh（24 例）**

| 组 | 内容 |
|----|------|
| A | 默认拓扑生成：`first_server_ip` 取自拓扑、hostvars 含 `ansible_host`/`node_role`、私钥路径按完整主机名、不输出 YAML 锚点 |
| B | Windows 拓扑：`role: ops` 的工作机不进入 inventory，`target_node` 仍只含集群节点 |
| C | 缺 server 时报错退出，而不是生成一份不可用的 inventory |
| D | `--stdout` 只打印、不落盘 |
| E | 幂等：重复生成结果一致 |
| F | `--check` 自检 |
| G | 仓库敏感文件未被测试改动 |

**test-vbox-archive.sh（7 例）**

归档行为、按时间保留 N 个、非 VBox 文件不被误移动、`up`/`destroy` 也触发、
`destroy` 取消时零副作用、无文件时静默返回。

## 隔离原则（踩过的坑，务必保持）

1. **stub 外部命令，并用 `guard_stubs` 确认 stub 真的生效。**
   这是最危险的一个坑：bash 查命令时会**跳过不可执行文件继续搜索 PATH**。
   stub 一旦丢了可执行位（我重写文件后就发生过），`vagrant` 会静默命中真实 vagrant，
   测试就变成了真的启停/销毁 VM。`guard_stubs` 检测到就直接 `exit 99` 拒绝运行。

2. **`LOG_DIR` 指向临时目录。** 否则测试日志会混进 `logs/k3s-ops.log`。

3. **有文件副作用的命令在临时 CWD 中执行。** `kubeconfig` 默认写到 `./kubeconfig`，
   在仓库根直接跑会**覆盖真实的 kubeconfig**（我发生过一次，文件变成两行日志）。
   跑之前先 `cd` 到临时目录。

4. **计数用 bash 数组 + 显式 `nullglob`。** 两个反向陷阱：
   - 不开 `nullglob`，glob 无匹配时**模式字符串本身**被当作 1 个元素 → "空目录"报成 1
   - `ls -1 <无匹配的 glob>` 会退化成"列出当前目录" → 返回莫名其妙的数字
     （我的测试目录正好 3 个文件，于是凭空多出"3"这个数字，污染了 4 个用例）

5. **不要用 `log_cmd` 包裹"输出被重定向到文件"的命令。**
   `log_cmd` 自身的 `echo "=== ... ==="` 也会被 `>` 捕获，一起写进目标文件。
   `get-kubeconfig.sh` 正是因此产出过"第 2 行起就不是 YAML"的坏 kubeconfig。

## 局限（stub 测不出来的东西）

stub 只能验证**参数拼装和控制流**，以下必须在真实环境验证：

- **远端文件权限**。`get-kubeconfig.sh` 缺 `sudo` 读不到 `0600` 的 `k3s.yaml`，
  stub 永远返回成功，这个 bug 是在真实 VM 上才暴露的。
- **vagrant 的真实行为**（幂等性、状态转换、启动耗时）。
- **k3s API 可用性**、Pod 是否真的起来。

所以：改完跑一遍 `bash tests/run-all.sh`，再在真实环境 `./k3s-ops.sh up && ./k3s-ops.sh status` 验证一遍。

## 安全边界

测试**不会**碰真实 VM：所有 `vagrant` / `ansible-playbook` / `kubectl` 调用都被 stub 拦截，
`guard_stubs` 会在 stub 失效时中止。唯一会真实写入的位置是 `logs/vbox/`（gitignored），
且 `test-vbox-archive.sh` 退出时会把根目录原有的 VBox 日志原样还原。

> 教训：写清理逻辑时**先恢复再删备份**。我曾把 `rm -rf 备份目录` 写在恢复之前，
> 导致 12 个真实的 VirtualBox 日志被测试清理掉且无法恢复。
