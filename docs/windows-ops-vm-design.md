# 设计方案：Windows 学员用「独立工作机」跑 k3s-ops

- 日期：2026-10-30
- 状态：待审核（已过一轮 builder check，修订见 §13）
- 相关：`AGENTS.md`、`docs/architecture.md`、`docs/k8s-tutorial/00-README.md`

## 1. 背景

目标受众是**只有 Windows、没有 Linux 基础**的学员，要求能按 `docs/k8s-tutorial/`（46 章）从头做实验。

已确认的现实约束：

1. `k3s-ops.sh` 是 bash + GNU 工具，Windows 原生跑不了。
2. Ansible 控制节点官方只支持 POSIX；Vagrant 的 ansible provisioner 必须在**执行 vagrant 的那台机器**上找到 `ansible-playbook`。
3. VirtualBox 与 Hyper-V/WSL2 互斥（Vagrant 官方要求关闭 Hyper-V），所以不走 WSL2 路线。
4. VirtualBox 不支持嵌套 VT-x，**工作机里不能再跑 Vagrant 建 VM**。

结论：Vagrant 留在 Windows 宿主；Ansible 放进集群之外的第三台 VM（工作机 / bastion）。

## 2. 目标 / 非目标

### 目标

- Windows 学员只需 2 个命令级操作即可得到与教程环境表一致的集群。
- `install / add-node / remove-node / upgrade / backup / restore / deploy-* / status / ssh / kubeconfig` 全部在工作机内用**原样的 `k3s-ops.sh`** 执行。
- 拓扑、IP、NodePort、节点名与 `docs/k8s-tutorial/00-README.md` 的环境表**完全一致**。
- Linux 路径行为**保持不变**（默认值等价）。
- `kubectl` / `helm` 在工作机内可直接用，教程命令可原样粘贴。

### 非目标

- 不把 `k3s-ops.sh` 翻译成 PowerShell。
- 不支持 WSL2 / Hyper-V / Docker Desktop 路线。
- 不引入 k3d / kind / 云托管集群。
- 不改写教程章节正文（只在 `00-README.md` 增加一节环境准备）。
- 不在本期把 Linux 路径切到"生成 inventory"（§7.6 留作后续独立提交）。

### 反目标（做了就算失败）

- 改动 `k3s-ops.sh`、`lib/*.sh`、`scripts/*.sh` 的现有行为。
- Windows 用户需要理解 Ansible / Vagrant 概念才能跑起来。
- 让 Linux 用户多出任何一步。

## 3. 设计原则

1. **宿主只管机器，工作机只管集群。** Windows 只负责 `up / down / destroy`；工作机负责其余全部命令。
2. **平台差异全部收敛到「guest 副本」。** 仓库经 `/vagrant`（vboxsf）进入工作机后复制到 `~/k3s-ops`，**只改副本里的 3 个东西**：`vagrant/nodes.yml`、`ansible/inventory.yml`、PATH 上的 `vagrant`。仓库内原始文件一个字节不动，于是 `k3s-ops.sh` 可原样运行。
3. **对原仓库的改动必须「默认值等价」**（§6.1 的 gate 有明确边界）。
4. **可测逻辑放 bash/python，PowerShell 只做三件事**：检查前置条件、调 `vagrant`、调 `vagrant ssh -c`。

## 4. 拓扑与内存档位

| 节点 | IP | 角色 | 规格 | 说明 |
|---|---|---|---|---|
| k3s-demo-server-1 | 192.168.56.10 | server | 2c / 4096MB | 控制面，教程锚点不变 |
| k3s-demo-agent-1 | 192.168.56.20 | agent | 2c / **2048MB** | 8GB 机器默认档 |
| k3s-demo-ops | 192.168.56.5 | ops（不在集群） | 1c / 1024MB（16GB 宿主可调 2048MB） | 工作机：ansible + kubectl + helm |

合计 7GB（8GB 档）/ 8GB（16GB 档：agent 4096 + ops 2048）。`win/nodes.windows.yml` 用注释给出 16GB 档，切换只改两行。

工作机**不是集群节点**：`kubectl get nodes` 仍只有 2 条，教程措辞不受影响。

## 5. 新增文件（除 §6 外不改动任何现有文件）

```
win/                              # Windows 独有，Linux 不感知
├── README.md                     # 学员入口：2 步 + 故障排查
├── nodes.windows.yml             # Windows 拓扑（含 ops 节点）
├── up.ps1                        # 前置检查 → vagrant up → 引导工作机
├── down.ps1                      # halt / suspend
├── destroy.ps1                   # 全量或单节点 destroy
├── kubeconfig.ps1                # 可选：把 kubeconfig 拉到 Windows（UTF-8 无 BOM）
├── provision-ops.sh              # 工作机内引导（纯 bash，可在 Linux 上测）
└── guest/bin/vagrant             # shim：ssh → 直连节点；up/down/destroy → 提示回 Windows

scripts/gen-inventory.py          # 唯一一份，平台中性；provision-ops.sh 调用它
```

## 6. 对现有文件的改动（3 个文件）

### 6.1 `vagrant/Vagrantfile`（约 12 行）

```ruby
nodes_file   = ENV.fetch('K3S_OPS_NODES_FILE', File.join(__dir__, 'nodes.yml'))
nodes_config = YAML.load_file(nodes_file)
...
k8s_nodes    = nodes.reject { |n| n['role'] == 'ops' }
first_server = k8s_nodes.find { |n| n['role'] == 'server' } || k8s_nodes.first
```

- `ansible_groups` 由 `if/else` 改为 `if/elsif`，`ops` 不入任何组。
- provisioner 条件改为：
  ```ruby
  windows_mode = nodes.any? { |n| n['role'] == 'ops' }
  can_provision = !windows_mode || !Vagrant::Util::Which.which('ansible-playbook').nil?
  if idx == nodes.size - 1 && node['role'] != 'ops' && can_provision
  ```
  **gate 只在 Windows 模式（清单里有 ops 节点）生效**，Linux 保持"缺 ansible 就报错"，不会静默跳过。
- `extra_vars` 中 `nodes.first[...]` 改用 `first_server`。

### 6.2 `.gitattributes`（新增）

```
*.sh    text eol=lf
*.yml   text eol=lf
*.j2    text eol=lf
*.ps1   text eol=crlf
```

防止 Windows `core.autocrlf=true` 把 `k3s-ops.sh` 变成 CRLF 后报 `\r: command not found`。

### 6.3 `ansible/group_vars/all.yml`（1 行，推荐；也可不改）

```yaml
k3s_download_url: "https://rancher-mirror.rancher.cn/k3s/{{ k3s_version | replace('+', '-') }}/k3s"
```

理由见 §14：当前网络 `github.com` 完全不可达，而默认值正是 GitHub Releases。**不改的话，全新 Windows 机器执行 `install` 会在下载 k3s 时失败**；Linux 上重新 `vagrant provision` 同样会失败（今天能跑通是因为集群早已建好）。

如果坚持"零改动原仓库"，替代方案是让生成器把 `k3s_download_url` 写进每台主机的 host vars（实测 host vars > playbook `group_vars`，见 §14.2），但那样 Linux 路径仍然坏着。

### 6.4 文档

- `AGENTS.md`：改写"坑 2"一段，补 Windows 路径。
- `docs/k8s-tutorial/00-README.md`：新增「环境准备（Windows）」。
- `docs/architecture.md`：拓扑图补 ops 机（仅 Windows 路径）。

## 7. 关键机制

### 7.1 节点文件注入

`up.ps1` 设进程级环境变量 `K3S_OPS_NODES_FILE = win\nodes.windows.yml` 后再调 `vagrant up`。Linux 不设 → 读 `vagrant/nodes.yml`。

### 7.2 ops 节点

`role: ops`，排在最后（不影响 `first_server` 推导）；无 kubelet、不参与 k3s 安装；由 `up.ps1` 单独引导，不依赖 Vagrantfile 内的 provisioner。

### 7.3 工作机引导（`provision-ops.sh`，幂等，7 步）

1. `apt-get install -y ansible rsync python3-yaml`（Ubuntu 22.04 的 `ansible` 包已含 `community.general`、`kubernetes.core`），并用 `ansible-galaxy collection list` 自检，缺则明确报错。
2. `rsync -a --delete /vagrant/ ~/k3s-ops/`（排除 `.git`、`.vagrant`、`logs`、`tmp`）。
3. 用 `win/nodes.windows.yml` **去掉 ops 节点**后覆盖 `~/k3s-ops/vagrant/nodes.yml`。
4. 从 `/vagrant/.vagrant/machines/<node>/virtualbox/private_key` 复制私钥到 `~/.ssh/k3s-ops/<node>`，`chmod 600`（vboxsf 是 0777，SSH 会拒绝）。
5. 生成 `~/k3s-ops/ansible/inventory.yml`（§7.6）与 `~/.k3s-ops-shim.json`（节点 → IP/私钥）。
6. 安装工具链（§7.4）：`kubectl`、`helm`，并把 `helm` 分发到 server-1 / agent-1 的 `/usr/local/bin/`。
7. 安装 `win/guest/bin/vagrant` shim 到 `/usr/local/bin/vagrant`。

**为什么不直接在 `/vagrant` 跑**：vboxsf 是 0777，Ansible 判定工作目录 world-writable 会拒绝加载 `ansible.cfg`；私钥 600 权限也无法成立。

**`up.ps1` 每次都重跑该脚本**（幂等），保证学员改了 `nodes.windows.yml` 后 inventory / shim 映射及时更新。

### 7.4 工具链获取（三级回退，全部可脚本化）

| 工具 | 主路径 | 回退 1 | 回退 2 |
|---|---|---|---|
| k3s 二进制（在节点下载） | `rancher-mirror.rancher.cn`（§6.3） | GitHub Releases（默认值，本网络不可达） | `/vagrant/artifacts/k3s` |
| kubectl | `dl.k8s.io/release/v<k8s 版本>/bin/linux/amd64/kubectl` | apt（若可见） | 从 server-1 复制 `/usr/local/bin/k3s`，包装 `kubectl` → `k3s kubectl` |
| helm（工作机） | `get.helm.sh` | `/vagrant/artifacts/helm`（若存在） | 失败即中止并给出下载指引 |
| helm（集群节点） | 由工作机用私钥 `scp` 分发到 server-1 / agent-1 | — | — |

**为什么 helm 必须分发到节点**：`nginx-ingress-deploy.yml` / `rancher-deploy.yml` 的 `hosts: server[0]`，helm 命令在 server-1 上执行，且其 bootstrap 走 `raw.githubusercontent.com`（本环境不可达）。不预置 helm，第 31/32 章必挂。

### 7.5 guest 副本的三处改写（"原代码零改动"的关键）

| 文件 | 改写 | 原因 |
|---|---|---|
| `vagrant/nodes.yml` | 换成 Windows 拓扑（去 ops） | `lib/nodes.sh` / `read_nodes_yml` 读它 |
| `ansible/inventory.yml` | 生成真实清单 | `k3s-ops.sh` 里 `-i` 路径写死，不去改它 |
| `/usr/local/bin/vagrant` | shim | 工作机里没有 Vagrant |

### 7.6 inventory 生成器

**只生成 `group_vars` 覆盖不到的变量**，避免把 `vagrant/Vagrantfile` 里较旧的 `extra_vars` 复制过来覆盖掉 `ansible/group_vars/all.yml` 的较新内容（如 `registry.k8s.io` / `gcr.io` 镜像，第 31/37 章依赖）。

`all.vars` 输出：`cluster_name`、`k3s_version`、`k3s_config`、`addons`、`first_server_ip`、`first_server_host`、`ansible_user=vagrant`、`ansible_ssh_common_args`。

`children`：

| 组 | 成员 | 用途 |
|---|---|---|
| `server` | server 节点 | 正常安装 |
| `agent` | agent 节点 | 正常安装 |
| `new_server` | 同 `server` | `k3s-add-server.yml` 的 `hosts:`，靠 `-l <host>` 限定 |
| `new_agent` | 同 `agent` | `k3s-add-agent.yml` 的 `hosts:` |
| `target_node` | 全部集群节点 | `k3s-remove-node.yml` 的 `hosts:` |

> 现状：三个 playbook 的 `hosts:` 是 `new_agent` / `new_server` / `target_node`，而 Vagrant 从没生成过这些组 → 今天 `add-node` / `remove-node` 在 Linux 上也是静默空跑。生成这 5 个组即可修好，且**不需要改 playbook**。代价：对已入集群的节点重复执行 `add-node` 会重跑安装（幂等但会重启 k3s），在 README 里写明"add-node 只用于新起的空节点"。
>
> 主机变量：`ansible_host`、`node_role`、`node_ip`、`ansible_ssh_private_key_file`。
>
> 自检：生成后跑 `ansible-inventory --list`，解析失败即中止并打印路径。

### 7.7 vagrant shim

| 调用 | 行为 |
|---|---|
| `vagrant ssh <node>` | `ssh -t -i <key> ... vagrant@<ip>` |
| `vagrant ssh <node> -- <cmd>` / `-c <cmd>` | `ssh -i <key> ... vagrant@<ip> <cmd>` |
| `vagrant ssh <node> -- "sudo bash -s" < file` | 透传 stdin（`status` 用到） |
| `vagrant up/halt/suspend/destroy/reload/status` | 提示"请在 Windows PowerShell 执行 `win\up.ps1`"，退出码 2 |
| `vagrant ssh-config <node>` | 输出 Host/HostName/User/IdentityFile |
| 其他 | 同上提示，退出码 2 |

映射数据来自 `~/.k3s-ops-shim.json`。好处：`k3s-ops.sh` 里 5 处 `vagrant` 调用（`up/down/ssh/destroy/status`）一律不改。推荐用 Python 实现（JSON + TTY 更稳）。

### 7.8 PowerShell 入口

| 脚本 | 参数 | 行为 |
|---|---|---|
| `up.ps1` | `[-Node <name>] [-Install]` | 检查 `vagrant`/`VBoxManage`、管理员、`192.168.56.0/24` 冲突、物理内存；设 `K3S_OPS_NODES_FILE`；`vagrant up`；重跑 `provision-ops.sh`；`-Install` 时依次执行 `k3s-ops.sh install` → `k3s-ops.sh kubeconfig` → `kubectl get nodes` 自检 |
| `down.ps1` | `[-Force] [-Suspend] [-Node <name>]` | 对应 `vagrant halt/suspend` |
| `destroy.ps1` | `[-Node <name>] [-Yes]` | 二次确认 → `vagrant destroy -f [节点]` |
| `kubeconfig.ps1` | — | `[IO.File]::WriteAllText`（UTF-8 无 BOM，LF），避免 PS 5.1 的 UTF-16 毁文件 |

**kubeconfig 必须重写**：`install` 里的 `fetch`（`k3s-server/tasks/init.yml:21`）拉下来的是 `server: https://127.0.0.1:6443`，在工作机上不可用。`k3s-ops.sh kubeconfig` 会把它改成 `192.168.56.10` —— 这正是 `-Install` 必须链这一步的原因。

## 8. 学员侧流程

```powershell
powershell -ExecutionPolicy Bypass -File .\win\up.ps1 -Install   # 一次性
vagrant ssh k3s-demo-ops                                          # 之后都在这里
cd ~/k3s-ops && ./k3s-ops.sh status
```

关机 `.\win\down.ps1`；重建 `.\win\destroy.ps1` 后重跑 `up.ps1`。

## 9. 失败模式与回滚

| 失败 | 现象 | 处理 |
|---|---|---|
| host-only 网卡需管理员 | `vagrant up` permission denied | `up.ps1` 提前检测并自提权重启 |
| 192.168.56.0/24 被占 | 建网卡失败/路由冲突 | 提前检测 + 改 `nodes.windows.yml` 指引 |
| `.vagrant` 私钥缺失（旧 VM） | provision 找不到 key | 提示 `vagrant reload` |
| 已有同名 VirtualBox 虚拟机 | `machine already exists` | 报错并给出 `win\destroy.ps1` / 手工注册指引（README 同款） |
| helm/kubectl 下载失败 | 第 31/32 章挂 | 三级回退 + 明确报错，不静默 |
| 工作机被 destroy 连带删除 | 无（`/vagrant` 是宿主挂载） | 重跑 `up.ps1` 自动重建 |
| Vagrantfile 改动影响 Linux | Linux 冒烟失败 | 改动全走默认值 + gate 只在 Windows 模式生效 |

回滚：删除 `win/`、`.gitattributes`，还原 `vagrant/Vagrantfile`，无状态残留。

## 10. 验证策略

**本机（Linux）可验证：**

- `ruby -c vagrant/Vagrantfile`。
- `shellcheck win/provision-ops.sh win/guest/bin/vagrant`。
- shim：用 fake `ssh`、fake JSON 做单元测试（沿用 `tests/` 的 stub 风格）。
- `scripts/gen-inventory.py`：分别对两份 nodes 文件生成，跑 `ansible-inventory --list` + `ansible-playbook --syntax-check`（三个 playbook 各一次）。
- `.gitattributes`：`git check-attr eol k3s-ops.sh`。
- 幂等：在本地容器里连跑两次 provision 逻辑。

**只能 Windows 实机验证：**

- `up.ps1` 全流程、host-only 网卡、自提权。
- `vagrant ssh ops -c` 的 stdin/退出码。
- shim 交互式 TTY 与真 vagrant 的差异。
- Windows 侧访问 `http://192.168.56.10:30080`、`https://192.168.56.10:30443`。

## 11. 验收标准

1. 全新 Windows 机器，按 README 两步操作后 `kubectl get nodes` 返回 2 个 Ready，且 `kubeconfig` 中 `server:` 为 `https://192.168.56.10:6443`。
2. 工作机内以下命令全部可用，且仓库内 `.sh` **零改动**：`install`、`status`、`kubeconfig`、`deploy-ingress`、`backup`、`upgrade`、`add-node`、`remove-node`。
3. 教程 31 / 37 / 42 / 43 四章在 Windows 路径下可完成。
4. Linux 机器上 `vagrant up` 仍自动 provision；缺 ansible 时仍**报错**而非静默跳过。
5. `git diff`：现有 `.sh` 零改动；`vagrant/Vagrantfile` ≤ 20 行；`ansible/group_vars/all.yml` 1 行。

## 12. 留给实现者的决定

- `.ps1` 参数解析风格（`param()` 优先）。
- shim 用 Python（推荐）还是 bash。
- `up.ps1 -Install` 失败时是否自动收集诊断（`vagrant status` + provision 输出）。
- `win/README.md` 故障排查条目范围。

## 13. builder check 修订记录

| # | 反馈 | 处理 |
|---|---|---|
| 1 | kubectl/helm 来源、kubeconfig 的 `127.0.0.1` 无人改 | 新增 §7.4 三级回退；§7.8 明确 `-Install` 链 `kubeconfig`；helm 分发到集群节点 |
| 2 | 照抄 Vagrantfile 的 `extra_vars` 会覆盖掉 `group_vars` 里更新的镜像配置 | §7.6 改为只生成 group_vars 覆盖不到的变量 |
| 3 | `add-node` / `remove-node` 的 `hosts:` 组不存在，今天就是空跑 | §7.6 补 `new_server` / `new_agent` / `target_node` 兼容组，零 playbook 改动 |
| 4 | `ansible_available` 无条件 gate 会让 Linux 静默跳过 provision | §6.1 gate 只在 Windows 模式（含 ops 节点）生效 |
| 5 | 孤儿 VM（`.vagrant` 丢失）无处理 | §9 增加失败模式 + README 指引 |
| 6 | `k3s_download_url` 走 GitHub Releases，本网络不可达 | 新增 §6.3 一行改造 + §7.4 回退表 |
| 7 | 工作机内存档位 | §4 定为 1GB，16GB 宿主可调 2GB |

## 14. 网络连通性实测（2026-10-30）

测试点：本项目所在 Linux 宿主。工作机走 VirtualBox NAT，出口与宿主相同，结论可迁移（Windows 宿主若处在同一网络，结果一致）。

| 目标 | 结果 | 用途 |
|---|---|---|
| `https://dl.k8s.io/release/v1.30.2/bin/linux/amd64/kubectl` | ✅ 206 | 工作机 kubectl |
| `https://get.helm.sh/helm-v3.14.0-linux-amd64.tar.gz` | ✅ 206 | helm |
| `https://kubernetes.github.io/ingress-nginx/index.yaml` | ✅ 206 | 第 31 章 helm repo |
| `https://charts.jetstack.io/index.yaml` | ✅ 200 | cert-manager |
| `https://releases.rancher.com/server-charts/stable/index.yaml` | ✅ 200 | Rancher |
| `http://archive.ubuntu.com/ubuntu/...` / `https://mirrors.aliyun.com/...` | ✅ 206 | 工作机 apt |
| `https://pypi.org/simple/ansible-core/` | ✅ 206 | pip 备选 |
| `https://rancher-mirror.rancher.cn/k3s/v1.30.2-k3s2/k3s` | ✅ 206，`Content-Range: 0-1048575/66367640`，ELF | k3s 镜像源 |
| `https://raw.githubusercontent.com/...` | ❌ `Connection reset` | playbook 里的 helm bootstrap 依赖它 → 必须预置 helm |
| `https://github.com`（含 Releases 下载） | ❌ 8s 连接超时 | **`k3s_download_url` 默认值不可用** |

复现：

```bash
curl -sS -o /dev/null -w '%{http_code} %{time_total}s\n' --connect-timeout 5 --max-time 12 \
  -r 0-0 -L <url>
```

### 14.1 结论

1. 工作机所需的 kubectl / helm / apt / 三个 helm repo **全部可达**，§7.4 的主路径成立。
2. **k3s 二进制必须换源**，否则全新环境安装必失败（§6.3）。
3. `raw.githubusercontent.com` 不可达这一点与 `AGENTS.md` 记录一致，所以 helm 只能由工作机分发到节点，不能依赖 playbook 自带的 bootstrap。

### 14.2 变量优先级实测（ansible-core 2.21.5）

用 `localhost` 做的最小验证：

```
inventory 内联 host vars > group_vars/all/*.yml > group_vars/all.yml > inventory all.vars
```

因此 §6.3 的替代方案（不动仓库、把 `k3s_download_url` 写进每台主机的 host vars）可行，但只修 Windows 一侧。
