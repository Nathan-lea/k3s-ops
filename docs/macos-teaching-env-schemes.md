# macOS 教学/实验环境适配方案（A/B/C 对比）

> 状态：**待评审**（仅方案，不含代码实现）  
> 日期：2026-10-26  
> 适用范围：主项目教学/实验环境（`vagrant/` + `ansible/` + `k3s-ops.sh`）；**不改变** `production/` 物理独立部署路线

## 1. 背景与目标

### 1.1 背景

本项目主要用于教学。`production/` 只是给学员上公司级测试/生产环境的一条建议路线，不是教学主路径。当前教学/实验环境基于 **Vagrant + VirtualBox + Ansible**，默认在 Linux 宿主机上运行。

现实情况：

- 部分开发想转运维，其中**多数学员使用 macOS**。
- macOS 分为 Intel 和 Apple Silicon（M1/M2/M3/M4...），两者在虚拟化能力和 box 架构上有差异。
- Windows 已有专用路径（`win/` + ops VM），说明仓库已接受“按宿主机平台提供合适入口”的思路。

### 1.2 目标

- 让教学/实验环境能在 macOS 上跑起来，覆盖常见学员机器。
- **尽量保持现有教学流程**：`init -> up -> install -> status/kubeconfig`。
- 改动尽量小、影响目录尽量少、风险可控。
- 不破坏现有 Linux 路径；不把 `production/` 复杂度带入教学环境。

### 1.3 非目标

- 不把 `production/` 改成跨平台控制机工具（production 仍以 Linux 控制机/真实节点为主）。
- 不承诺 Windows 原生宿主机直接跑 Ansible（Windows 继续走 ops VM 现有思路）。
- 不在本次方案中实现代码；本文只做方案评审。

## 2. 当前现状（已核对）

### 2.1 教学主流程

| 组件 | 现状 | 关键文件 |
|---|---|---|
| VM 编排 | Vagrant + VirtualBox，box 固定 `bento/ubuntu-22.04` | `vagrant/Vagrantfile`, `vagrant/nodes.yml` |
| 配置管理 | 宿主机执行 Ansible provisioner | `vagrant/Vagrantfile` |
| k3s 安装 | Ansible 下载 `k3s_download_url` 指向的二进制 | `ansible/roles/k3s-server/tasks/install.yml`, `ansible/roles/k3s-agent/tasks/install.yml` |
| CLI | bash 入口 | `k3s-ops.sh`, `lib/*.sh`, `scripts/*.sh` |
| Windows 路径 | 单独 `win/`，通过 `role: ops` 工作机在 VM 内跑 Ansible | `win/*`, `vagrant/Vagrantfile` |

### 2.2 已确认的跨平台阻塞点

| 阻塞点 | 证据 | 影响 |
|---|---|---|
| k3s 下载 URL 写死 amd64 | `vagrant/Vagrantfile` 传入 `k3s_download_url: .../releases/download/${version}/k3s`；`ansible/group_vars/all.yml` 默认也为 `.../k3s` | Apple Silicon VM（aarch64）会拿到错误二进制，安装失败 |
| 未显式处理 box 架构 | `vagrant/nodes.yml` 只有 `box: bento/ubuntu-22.04`，Vagrantfile 未设置 `box_architecture` | Apple Silicon + VirtualBox 需要 arm64 box；自动选择可能不稳定或取决于 Vagrant 版本 |
| 宿主机脚本 GNU 兼容性 | `scripts/get-kubeconfig.sh` 使用 `sed -i "s/.../.../g"`（GNU 写法） | macOS BSD sed 报错，`kubeconfig` 命令失败 |
| macOS 前置说明缺失 | `README.md` 环境要求未区分 macOS/Apple Silicon | 学员按 Linux 经验安装易踩坑（VirtualBox 授权、Ansible 安装、架构问题） |

### 2.3 已确认的有利事实

| 事实 | 说明 |
|---|---|
| Bento box 有 arm64 VirtualBox 版本 | Vagrant Cloud 元数据显示 `bento/ubuntu-22.04` 202510.26.0 包含 `virtualbox` 的 `amd64` 与 `arm64` provider（2025-10-26 发布信息） |
| Vagrantfile 已有 ops 模式机制 | `windows_mode = nodes.any? { |n| n['role'] == 'ops' }`，有 ops 节点时跳过宿主机 Ansible provisioner；机制通用，命名偏 Windows |
| Windows 已有 ops VM 实现 | `win/provision-ops.sh`、`win/nodes.windows.yml`、`win/up.ps1` 等可作为 B 方案参考 |
| Ansible 安装任务已参数化 | server/agent 都使用 `{{ k3s_download_url }}` 下载，只要 URL/架构正确即可复用 |

## 3. 总体设计原则

1. **默认流程不变**：Linux 和 Intel Mac 的既有命令尽量保持不变。
2. **架构正确性优先**：k3s 二进制架构必须匹配 VM 架构，不按宿主机 OS 猜。
3. **最小侵入**：优先改配置生成逻辑，不重写教学 CLI。
4. **可回退**：新增字段/逻辑有默认值，旧 `nodes.yml` 不填新字段也能工作。
5. **教学友好**：文档明确前置条件、常见坑、验证命令。

## 4. 方案 A：宿主机 Ansible + 架构自适应（推荐基线）

### 4.1 思路

保持现有“宿主机装 Vagrant/VirtualBox/Ansible，宿主机驱动 Ansible 安装 k3s”的模式，只修复 macOS/ARM 不兼容点。

### 4.2 用户流程（目标）

```bash
# macOS（Intel / Apple Silicon）与 Linux 尽量一致
./k3s-ops.sh init
./k3s-ops.sh up
./k3s-ops.sh install
./k3s-ops.sh status
./k3s-ops.sh kubeconfig
```

### 4.3 关键设计

#### A1. k3s 二进制架构自适应

- **推荐落点**：`ansible/group_vars/all.yml` 根据 `ansible_architecture` 计算 `k3s_binary_name` / `k3s_download_url`。
- **映射规则**：

  | `ansible_architecture` | 二进制 |
  |---|---|
  | `x86_64`, `amd64` | `k3s` |
  | `aarch64`, `arm64` | `k3s-arm64` |
  | 其他 | 显式失败，提示不支持 |

- **Vagrantfile 调整**：不再硬编码 `.../k3s`；改为传递基础版本/镜像源或不覆盖 group_vars 默认 URL。避免 extra_vars 把 group_vars 的架构逻辑覆盖死。
- **下载源（k3s 二进制）**：这里指的是 **k3s 可执行文件**（`k3s` / `k3s-arm64`）的下载地址，不是 Rancher 或其他容器镜像。保留现有镜像源策略，但 URL 必须按架构拼出正确文件名。已实测确认：`rancher-mirror.rancher.cn` 与 GitHub release 均提供 `k3s-arm64`，命名一致。实现时仍应把下载源做成可配置项，并在下载失败时给出清晰报错，避免某个镜像源缺文件时静默失败。
- **容器镜像（另一层）**：k3s 自带系统镜像、nginx-ingress、cert-manager、Rancher 等**容器镜像**也必须有 `linux/arm64` 变体，才能在 Apple Silicon 的 arm64 VM 内正常拉取。这不属于 A1 的 URL 生成改动，但属于 Apple Silicon 验证矩阵：实现/测试时要实际验证主要组件镜像可拉取；文档需提醒学员“arm64 VM 上不能运行仅 amd64 的自定义镜像”。

#### A2. Vagrant box 架构与 provider 自适应

- `vagrant/nodes.yml` 新增可选字段（均有默认值）：

  ```yaml
  network:
    subnet: 192.168.56.0/24
    box: bento/ubuntu-22.04
    # 可选：virtualbox | vmware_desktop | parallels | utm
    provider: virtualbox
    # 可选：amd64 | arm64；不填则按宿主机自动检测
    box_architecture: auto
  ```

- `Vagrantfile` 逻辑：
  - 默认 provider 仍 `virtualbox`。
  - `box_architecture: auto` 时：Apple Silicon 宿主机默认 `arm64`，Intel 默认 `amd64`。
  - Vagrant >= 2.4 时设置 `config.vm.box_architecture`；低版本给出清晰报错/提示。
  - provider 非 virtualbox 时，仅设置对应 provider 配置块（受控逃生口），不改变默认教学命令。

#### A3. 宿主机脚本 macOS 兼容

- `scripts/get-kubeconfig.sh`：替换 `sed -i` 为可移植实现，例如：

  ```bash
  tmp="$(mktemp)"
  sed "s/127.0.0.1/${SERVER_IP}/g" "$KUBECONFIG_DEST" > "$tmp" && mv "$tmp" "$KUBECONFIG_DEST"
  ```

- 审计教学主流程涉及脚本：`k3s-ops.sh`、`lib/*.sh`、`scripts/*.sh` 中的 GNU 特有参数（`sed -i` 无备份后缀、`readlink -f`、`date -d`、`sha256sum`）。主流程优先修，非主流程记录。

#### A4. 文档与前置检查

- `README.md` / `docs/architecture.md` / 教程前置章节补充：
  - macOS Intel：VirtualBox + Vagrant + Ansible 安装方式。
  - macOS Apple Silicon：VirtualBox >= 7.1、Vagrant >= 2.4、首次运行需允许 Oracle 扩展、arm64 box 下载说明。
  - 常见故障：box 架构不匹配、k3s 二进制 exec format error、BSD sed、Ansible Python 依赖。

- `k3s-ops.sh init` 可选增强：检测 macOS、Vagrant/VirtualBox 版本、架构，给出提示（不强制阻塞所有场景）。

### 4.4 改动清单（预估）

| 文件/目录 | 改动 | 预估量 |
|---|---|---|
| `vagrant/Vagrantfile` | box_arch/provider 自动检测与覆盖；移除 amd64 硬编码 k3s URL | 中 |
| `vagrant/nodes.yml` | 增加可选字段注释示例 | 小 |
| `ansible/group_vars/all.yml` | 架构映射 + k3s_download_url 模板化 | 小-中 |
| `ansible/roles/k3s-server/tasks/install.yml` | 如需下载校验/日志优化 | 小 |
| `ansible/roles/k3s-agent/tasks/install.yml` | 同上 | 小 |
| `scripts/get-kubeconfig.sh` | `sed -i` 可移植化 | 小 |
| `k3s-ops.sh`, `lib/*.sh`, 其他 `scripts/*.sh` | macOS 兼容审计修复（按主流程） | 小-中 |
| `README.md`, `docs/architecture.md` | macOS 前置与排障 | 中 |
| 测试/验证记录 | 手测矩阵、文档说明 | 小 |

**预估影响**：约 **5-9 个文件**，主要集中在 `vagrant/`、`ansible/group_vars/`、`scripts/`、`docs/`。

### 4.5 优点

- 改动最少，最贴合“尽量保持现有流程”。
- 不引入额外 VM，不增加学员机器资源压力。
- Linux 现有行为基本不变。
- 是 B/C 方案的底层前置，做了不亏。

### 4.6 风险与缺点

- **Apple Silicon + VirtualBox 稳定性**受上游影响；项目只能做到“尽量兼容 + 明确前置条件 + 逃生口”。
- 学员仍需在宿主机安装 Ansible/Python；对部分 Mac 用户有门槛。
- 需要实机覆盖 Intel Mac 和 Apple Silicon Mac；仅 Linux CI 不够。

### 4.7 验证矩阵

| 环境 | 必测项 | 通过标准 |
|---|---|---|
| Linux x86_64（现有） | `init/up/install/status/kubeconfig` | 无回归 |
| macOS Intel + VirtualBox | 同上 | 集群 Ready，kubeconfig 可用 |
| macOS Apple Silicon + VirtualBox 7.1+ | 同上 | VM 为 arm64，k3s 使用 `k3s-arm64`，集群 Ready |
| macOS Apple Silicon（镜像兼容） | k3s 系统镜像 + nginx-ingress/cert-manager/Rancher 等附加组件 | 主要容器镜像均有 `linux/arm64`，可正常拉取；文档注明自定义镜像需自行支持 arm64 |
| macOS Apple Silicon（可选逃生口） | provider override | 文档流程可跑通或明确限制 |

## 5. 方案 B：照 Windows 思路的 ops VM 模式

### 5.1 思路

Mac 不在宿主机跑 Ansible，改为像 Windows 一样：Vagrant 起一台 `ops` 工作机，在 ops VM 内安装 Ansible/kubectl/helm，并在 ops VM 内执行 `k3s-ops.sh`/Ansible。

### 5.2 用户流程（目标）

```bash
# 宿主机（macOS）
./mac/up.sh --install        # 或类似入口
# 或 vagrant up 后进入 ops
vagrant ssh k3s-demo-ops
cd ~/k3s-ops && ./k3s-ops.sh status
```

### 5.3 关键设计

#### B1. 复用现有 ops 机制

- 复用 `Vagrantfile` 的 `role: ops` 检测：已有 `windows_mode = nodes.any? { |n| n['role'] == 'ops' }`。建议重命名为更通用的 `ops_mode`（保留兼容），或仅在文档说明。
- 复用 `win/provision-ops.sh` 的核心逻辑：安装 ansible、kubectl、helm、同步仓库、生成 inventory、设置环境。

#### B2. Mac 入口

两种子方案：

| 子方案 | 做法 | 评价 |
|---|---|---|
| B1. `mac/` 目录 | 新增 `mac/up.sh`、`mac/down.sh`、`mac/destroy.sh`、`mac/kubeconfig.sh`、`mac/nodes.mac.yml`、`mac/README.md` | 与 `win/` 对称，清晰，但新增文件多 |
| B2. 通用 `ops/` 目录 | 把 `win/` 抽象为 `ops/`，Windows 用 ps1 包装，Mac 用 bash 包装，共用 provision | 更优雅，但重构影响面大，不符合“改动少” |

在“改动少”前提下，只能选 **B1** 或最小复用 `win/provision-ops.sh`。

#### B3. 仍然需要 A 的底层修复

这是关键点：**B 不能替代 A 的核心修复**。

- ops VM 里跑 Ansible，guest 架构仍可能是 arm64（Apple Silicon VirtualBox arm64 guest）。
- `k3s_download_url` 仍不能写死 amd64。
- box 仍需 arm64/amd64 正确选择。
- `get-kubeconfig.sh` 在 Mac 宿主机侧如果还要用，也有 BSD sed 问题；即使不用，宿主机包装脚本也要考虑可移植性。

### 5.4 改动清单（预估）

| 文件/目录 | 改动 | 预估量 |
|---|---|---|
| A 的核心修复 | Vagrantfile/Ansible/group_vars/scripts/docs | 中 |
| `mac/`（新增） | `up.sh`、`down.sh`、`destroy.sh`、`kubeconfig.sh`、`nodes.mac.yml`、`README.md` | 中 |
| `win/provision-ops.sh` 或共享脚本 | 抽取/复用为 Mac 可调用；可能需处理路径、权限、ssh key | 中 |
| `vagrant/Vagrantfile` | `windows_mode` 命名泛化或兼容注释；ops 模式文案 | 小 |
| `README.md` / docs | Mac ops 模式说明、与 Linux/Windows 三套入口对比 | 中 |
| 教程 | 需要说明“Mac ops 模式下命令在 ops VM 内执行” | 中 |

**预估影响**：约 **10-15 个文件**，新增 `mac/` 目录；若抽象 `win/` 共用逻辑，影响更多。

### 5.5 优点

- 宿主机不需要安装 Ansible/Python，降低 Mac 学员门槛。
- 与 Windows 体验一致：宿主机只管“开 VM”，集群操作进 ops VM。
- 避免宿主机 Ansible 版本/Python 依赖差异带来的问题。

### 5.6 风险与缺点

- **不减少核心架构修复**，反而在 A 基础上加入口和维护面。
- 多一台 ops VM，占用额外 CPU/内存（参考 Windows：1C/1G；8G Mac 可能紧张）。
- 教学流程变化：学员要理解“宿主机”和“ops VM”两个执行位置，容易混淆。
- 需要维护 `win/`、`mac/`（或抽象层）两套宿主机入口的行为一致性。
- `k3s-ops.sh` 的部分命令（`vagrant ssh`、端口转发、kubeconfig 拉到宿主机）需要包装。

### 5.7 验证矩阵

| 环境 | 必测项 | 通过标准 |
|---|---|---|
| macOS Intel | `mac/up.sh --install`、ops 内 `k3s-ops.sh status` | 集群 Ready |
| macOS Apple Silicon | 同上 + arm64/镜像验证 | `k3s-arm64`、arm64 guest、主要组件镜像可拉取、集群 Ready |
| Windows amd64 | `win/up.ps1 -Install` 回归 | 不受 Mac 改动影响 |
| Linux | 现有流程回归 | 不受影响 |

## 6. 方案 C：A + B 双模式（兼容性最好，改动最多）

### 6.1 思路

保留 A 作为默认/轻量路径，同时提供 B 作为低门槛选项。让学员按自身环境选择。

### 6.2 用户流程

```bash
# 路径 A：宿主机 Ansible（熟悉 Linux/Ansible 的学员）
./k3s-ops.sh init && ./k3s-ops.sh up && ./k3s-ops.sh install

# 路径 B：ops VM（不想装 Ansible 的 Mac 学员）
./mac/up.sh --install
vagrant ssh k3s-demo-ops
cd ~/k3s-ops && ./k3s-ops.sh status
```

### 6.3 关键设计

- A 作为底层能力与默认文档路径。
- B 作为可选路径，共用 A 的所有底层修复。
- 文档必须清晰分流，避免学员混用：

  | 学员情况 | 推荐路径 |
  |---|---|
  | Linux / 已有 Ansible | A |
  | macOS Intel，愿意装 Ansible | A |
  | macOS Apple Silicon，想少装宿主机依赖 | B（或 A，视 VirtualBox 稳定性） |
  | Windows | 现有 `win/` ops VM |

- 需要统一术语：`ops_mode` / `host-ansible mode`。

### 6.4 改动清单（预估）

| 文件/目录 | 改动 | 预估量 |
|---|---|---|
| A 全部改动 | 核心修复 | 中 |
| B 全部改动 | Mac ops 入口/文档/复用 | 中 |
| 模式选择文档 | README、教程入口、FAQ | 中 |
| 测试矩阵 | A/B 两条路径都要测 | 中-大 |

**预估影响**：约 **12-18 个文件**，跨 `vagrant/`、`ansible/`、`scripts/`、`lib/`、`mac/`（新增）、`win/`（可能小改）、`docs/`、`README`。

### 6.5 优点

- 覆盖面最广，能适配不同学员机器和偏好。
- A 失败时有 B 兜底，B 觉得重时可用 A。
- 长期看最友好。

### 6.6 风险与缺点

- 改动最多，维护成本最高。
- 文档和教程容易写乱：两套入口、两个执行位置、三种宿主机 OS。
- 测试矩阵膨胀，发布前验证成本高。
- 如果没有足够维护精力，容易出现“一条路好用、另一条路烂尾”。

## 7. 方案对比

| 维度 | A. 宿主机 Ansible | B. Mac ops VM | C. A+B 双模式 |
|---|---|---:|---:|
| 是否满足“Mac 能跑” | 是（含架构修复后） | 是（含架构修复后） | 是 |
| 是否保持现有流程 | **最好** | 中（需进 ops VM） | A 路径保持，B 路径变化 |
| 宿主机依赖 | Vagrant+VirtualBox+Ansible | Vagrant+VirtualBox | 两者都有 |
| 额外 VM 资源 | 无 | +1 台 ops VM | B 路径 +1 台 |
| 核心架构修复 | 必须做 | 必须做（同 A） | 必须做（同 A） |
| 新增目录 | 无 | 通常新增 `mac/` | 新增 `mac/` |
| 预估改动文件数 | **5-9** | 10-15 | **12-18** |
| 维护成本 | **低** | 中 | 高 |
| 教学文档复杂度 | 低-中 | 中 | 高 |
| 对现有 Linux 用户影响 | 很小 | 小（若只加 Mac 路径） | 小-中（文档分流） |

## 8. 推荐路径

### 8.1 推荐结论

**推荐先做 A，作为正式基线；B 作为后续增量选项，C 只在确有维护资源时考虑。**

理由：

1. 你明确要求“尽量保持和现在一样的 Vagrant + VirtualBox 操作流程”——A 最符合。
2. 你关心“改动代码少、影响目录文件少”——A 最少。
3. A 的底层修复（arch-aware k3s URL、box_architecture、macOS 脚本兼容）是 B/C 的公共前置，不会浪费。
4. B 解决的是“宿主机安装 Ansible 门槛”问题，但会带来流程变化和资源开销；可以等 A 落地后，根据学员反馈再决定。

### 8.2 分阶段实施建议

| 阶段 | 内容 | 产出 | 是否影响现有流程 |
|---|---|---|---|
| Phase 1 | 实现 A：架构自适应 + macOS 兼容修复 + 文档 | Mac/Linux 可用的同一套教学流程 | 极小 |
| Phase 2（可选） | 实现 B：Mac ops VM 入口，复用 provision 逻辑 | `mac/` 低门槛入口 | 无（新增可选路径） |
| Phase 3（可选） | 整理为 C：统一文档分流、测试矩阵、术语 | 双模式正式支持 | 文档变化为主 |

## 9. 需要你确认的决策

在进入设计/实现前，建议确认以下问题：

1. **支持范围**：只支持 macOS（Intel + Apple Silicon），还是这次也把 Windows amd64 路径纳入回归范围？
2. **Apple Silicon 的默认 provider**：默认仍是 VirtualBox（接受上游成熟度风险），还是默认给 VMware/Parallels 建议？
3. **Ansible 安装门槛**：是否接受“Mac 学员需自行安装 Ansible”作为 A 方案前提？如果很多学员卡在这里，B 的优先级会上升。
4. **资源预算**：教学机最低配置是否能再多一台 1C/1G ops VM？这决定 B/C 是否现实。
5. **实施节奏**：先做 Phase 1（A）并验证，再决定 B/C；还是一次性把 A+B 文档和实现都做了？

## 10. 附录：关键证据与参考文件

### 10.1 仓库内证据

- `vagrant/Vagrantfile`：provider 固定 virtualbox；`k3s_download_url` 写死 amd64；`windows_mode` 由 `role: ops` 触发。
- `vagrant/nodes.yml`：`box: bento/ubuntu-22.04`，无架构/provider 覆盖字段。
- `ansible/group_vars/all.yml`：`k3s_download_url` 默认 `.../k3s`。
- `ansible/roles/k3s-server/tasks/install.yml`、`ansible/roles/k3s-agent/tasks/install.yml`：通过 `k3s_download_url` 下载。
- `scripts/get-kubeconfig.sh`：GNU `sed -i`。
- `win/nodes.windows.yml`、`win/provision-ops.sh`、`win/up.ps1`：现成 ops VM 参考实现。

### 10.2 外部事实（写方案时已核对）

- Bento `ubuntu-22.04` Vagrant box（202510.26.0）元数据包含 `virtualbox` arm64 与 amd64 provider。
- VirtualBox 7.1+ 开始提供 macOS/Apple Silicon 主机支持，但 ARM 客户机生态和稳定性仍弱于 Intel x86_64 场景；需要在文档中明确前置版本和风险。

> 注：外部平台版本与支持策略会变化，实现前应再次核对 VirtualBox/Vagrant/Bento 的最新发布说明。
