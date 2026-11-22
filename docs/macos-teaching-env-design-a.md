# 方案 A 详细设计：宿主机 Ansible + 架构自适应（macOS 教学环境）

> 状态：**待评审**（可实施设计，未实现）  
> 日期：2026-10-26  
> 关联方案：`docs/macos-teaching-env-schemes.md` 中的方案 A  
> 范围：主项目教学/实验环境（`vagrant/` + `ansible/` + `k3s-ops.sh`），不涉及 `production/`

## 1. 目标与非目标

### 1.1 目标

在尽量保持现有教学流程不变的前提下，让主项目教学/实验环境可在 macOS 上运行：

```bash
./k3s-ops.sh init
./k3s-ops.sh up
./k3s-ops.sh install
./k3s-ops.sh status
./k3s-ops.sh kubeconfig
```

覆盖：

- macOS Intel + VirtualBox（主目标，稳定性预期高）
- macOS Apple Silicon + VirtualBox 7.1+（主目标，best-effort；受上游 VirtualBox ARM 成熟度影响）
- Linux x86_64 现有路径（必须无回归）

### 1.2 非目标

- 不实现 ops VM 模式（方案 B）或双模式（方案 C）。
- 不改变 `production/` 目录、配置、脚本或文档的部署模型。
- 不承诺 Windows 原生宿主机 Ansible 路径；Windows 继续使用 `win/` + ops VM。
- 不处理“学员自定义镜像不支持 arm64”的问题，只在文档和验证矩阵中提醒。
- 不在本次实现中大规模重构 `k3s-ops.sh` CLI 结构。

## 2. 现状与问题

### 2.1 关键现状

| 位置 | 现状 | 问题 |
|---|---|---|
| `vagrant/Vagrantfile` | `config.vm.box = network_cfg['box']`；provider 固定 `virtualbox`；extra_vars 传入硬编码 `k3s_download_url: .../k3s` | Apple Silicon arm64 VM 会下载 amd64 k3s 二进制；未显式设置 box 架构 |
| `ansible/group_vars/all.yml` | `k3s_download_url` 默认 `https://rancher-mirror.rancher.cn/k3s/{{ k3s_version \| replace('+','-') }}/k3s` | 默认也是 amd64 文件名；但 Vagrantfile extra_vars 当前会覆盖它 |
| `ansible/roles/k3s-server/tasks/install.yml` | `get_url: url={{ k3s_download_url }}` | 逻辑可复用，只要 URL 正确 |
| `ansible/roles/k3s-agent/tasks/install.yml` | 同上 | 同上 |
| `scripts/get-kubeconfig.sh` | `sed -i "s/127.0.0.1/${SERVER_IP}/g" ...` | macOS BSD sed 不兼容 |
| `scripts/bootstrap.sh` | 检查 vagrant/vboxmanage/ansible/python3 | 未提示 macOS/Apple Silicon 前置条件和版本 |
| `k3s-ops.sh` | bash 脚本，`mapfile`（bash4+）在 `_archive_vbox_logs` 使用 | macOS 默认 `/bin/bash` 3.2 不支持 `mapfile` |
| `README.md` | 环境要求只有 Linux 风格通用描述 | 缺 macOS 安装、VirtualBox 授权、Apple Silicon 注意事项 |

### 2.2 已确认事实

- Bento `ubuntu-22.04` 202510.26.0 在 Vagrant Cloud 元数据中包含 `virtualbox` 的 `amd64` 和 `arm64` box。
- `rancher-mirror.rancher.cn/k3s/v1.30.2-k3s2/k3s-arm64` 实测返回 HTTP 200；GitHub release 也提供 `k3s-arm64`。k3s 二进制命名在两者一致。
- Vagrantfile 已有 `role: ops` 检测机制（`windows_mode`），说明多入口/多模式已有先例；本次 A 不扩展该模式，只保持兼容。
- Vagrant extra_vars 优先级高于 group_vars。因此不能只改 `group_vars/all.yml`，必须同时处理 Vagrantfile 传参。

## 3. 设计原则

1. **VM 架构优先**：k3s 二进制按 `ansible_architecture`（VM 内）决定，不按宿主机架构猜。
2. **默认值兼容**：不填新字段时行为与旧版一致（Linux/Intel 默认）。
3. **显式失败**：不支持的架构、缺失的下载源、低版本 Vagrant 给出清晰错误。
4. **最小改动**：优先改现有文件，不新增目录；不引入 ops VM。
5. **可验证**：每个改动点有验收标准。

## 4. 详细改动设计

### 4.1 `vagrant/nodes.yml` — 新增可选配置

#### 变更

在 `network` 下新增可选字段，默认不影响现有配置：

```yaml
network:
  subnet: 192.168.56.0/24
  box: bento/ubuntu-22.04
  # 可选：VM 提供商，默认 virtualbox。教学主流程只保证 virtualbox。
  # 可选值：virtualbox | vmware_desktop | parallels
  # provider: virtualbox
  # 可选：box 架构。auto=按宿主机自动检测；也可显式写 amd64/arm64。
  # Apple Silicon 建议 arm64；Intel 建议 amd64。
  # box_architecture: auto
```

#### 规则

| 字段 | 默认 | 说明 |
|---|---|---|
| `network.provider` | `virtualbox` | 仅 `virtualbox` 为正式支持；其他值作为受控逃生口，不承诺完整教学文档覆盖 |
| `network.box_architecture` | `auto` | `auto` 时由 Vagrantfile 检测宿主机；`amd64`/`arm64` 时显式指定 |
| `network.box` | 现有值 | 保持不变；允许用户覆盖为兼容 box |

#### 兼容性

- 旧 `nodes.yml` 无这些字段：读取时使用默认值。
- `win/nodes.windows.yml`：同样受益，可后续按需添加注释；本次不强制修改。

### 4.2 `vagrant/Vagrantfile` — 架构/provider 自适应

#### 4.2.1 读取新配置

在现有 `network_cfg` 读取后增加：

```ruby
provider_name = network_cfg.fetch('provider', 'virtualbox')
box_arch      = network_cfg.fetch('box_architecture', 'auto')
```

#### 4.2.2 宿主机架构检测

```ruby
def detect_host_arch
  arch = RbConfig::CONFIG['host_cpu'].to_s.downcase
  case arch
  when 'arm64', 'aarch64'
    'arm64'
  when 'x86_64', 'amd64'
    'amd64'
  else
    'amd64' # 保守默认，后续由 Vagrant/box 报错暴露
  end
end
```

`box_arch == 'auto'` 时使用检测结果；否则使用用户显式值（规范化为 `amd64`/`arm64`）。

#### 4.2.3 box 架构设置

Vagrant 2.4+ 支持 `config.vm.box_architecture`。设计：

```ruby
if Vagrant.respond_to?(:require_version)
  # 不强制阻塞所有版本，只在需要 arm64/显式架构时提示
end
config.vm.box_architecture = resolved_box_arch
```

注意：`box_architecture` 是较新属性；实现时需做兼容保护：

```ruby
if config.vm.respond_to?(:box_architecture=)
  config.vm.box_architecture = resolved_box_arch
elsif resolved_box_arch != 'amd64'
  abort "Vagrant >= 2.4 is required for box_architecture=#{resolved_box_arch}. Please upgrade Vagrant."
end
```

对默认 amd64 + 老 Vagrant 保持尽量兼容；对 arm64 显式要求 Vagrant >= 2.4。

#### 4.2.4 provider 配置

默认仍为 VirtualBox：

```ruby
config.vm.provider 'virtualbox' do |vb|
  vb.gui = false
  vb.customize ['modifyvm', :id, '--natdnshostresolver1', 'on']
  vb.customize ['modifyvm', :id, '--ioapic', 'on']
end
```

当 `provider_name != 'virtualbox'` 时：

- 仍允许设置 `config.vm.box`；由用户确保 box 支持该 provider。
- 只为已知 provider 添加最小必要配置块（vmware_desktop/parallels），避免过度设计。
- 在 `k3s-ops.sh init`/文档中标注“非 virtualbox 为逃生口，教学主流程官方支持 virtualbox”。

#### 4.2.5 移除硬编码 amd64 k3s 下载 URL

当前 Vagrantfile 在 ansible extra_vars 中传：

```ruby
k3s_download_url: "https://github.com/k3s-io/k3s/releases/download/#{nodes_config['k3s_version']}/k3s",
```

这是 Apple Silicon 的直接阻塞。方案：

- **删除** Vagrantfile 中的 `k3s_download_url` extra_var。
- 改为传递 `k3s_version`（已有）和可选 `k3s_download_base_url`/`k3s_mirror`（可选，本次不必新增）。
- 让 `ansible/group_vars/all.yml` 基于 `ansible_architecture` 计算正确 URL。

同时审视其他 extra_vars：`k3s_install_dir` 等与 group_vars 重复，但无害；本次不清理，避免扩大变更。

#### 4.2.6 containerd_mirrors

Vagrantfile 当前也传了 `containerd_mirrors` extra_vars（只有 docker.io/quay.io）。`group_vars/all.yml` 有更完整的 mirrors（含 registry.k8s.io、k8s.m.daocloud.io 等）。extra_vars 会覆盖 group_vars，导致 group_vars 的更新不生效。

本次设计建议：**移除 Vagrantfile 中的 `containerd_mirrors` extra_vars**，统一以 `ansible/group_vars/all.yml` 为准。这样避免两处维护，且与“最小惊讶”一致。需在验收中确认现有 Linux 路径镜像行为不变。

> 这是一个行为收敛变更：当前 Vagrantfile 传的 mirrors 更少，但 group_vars 有更新的 daocloud 镜像。统一到 group_vars 是更好的状态，但需要在发布说明中说明。

#### 4.2.7 确保 group_vars 在 Vagrant provisioner 中可加载

**问题**：当前 `ansible/group_vars/` 位于 `ansible/` 根目录，playbooks 位于 `ansible/playbooks/`。CLI 运行（`ansible-playbook -i ansible/inventory.yml ansible/playbooks/...`）可通过 inventory 相邻目录找到 group_vars；但 Vagrant ansible provisioner 使用自动生成的临时 inventory，**不会**找到 `ansible/group_vars/`。这也是 Vagrantfile 目前大量通过 extra_vars 传参的原因。

如果 4.2.5/4.2.6 移除了 `k3s_download_url`/`containerd_mirrors` extra_vars，就必须保证 group_vars 能被加载。

**方案**：创建 `ansible/playbooks/group_vars` -> `../group_vars` 的符号链接。

- Ansible 会在 playbook 目录旁查找 `group_vars/`，对 Vagrant provisioner 和 CLI 都生效。
- 现有 `ansible/group_vars/` 仍是唯一真实来源，不重复维护。
- 同时在 Vagrantfile 中设置 `ansible.config_file = File.join(__dir__, '..', 'ansible', 'ansible.cfg')`（可选增强），让 roles_path/timeout 等配置一致；但 ansible.cfg 内相对路径需验证不受 CWD 影响。
- Windows 宿主机不直接运行 Ansible（走 ops VM），该 symlink 主要被 Linux/macOS 宿主机和 Linux VM 使用；如需兼容 Windows Git checkout 的 symlink 问题，可在实现时评估改为真实目录+同步脚本，但优先保持简单。

**验收**：

- `ansible-playbook -i ... ansible/playbooks/k3s-cluster.yml --list-tasks` 可看到 group_vars 变量生效。
- Vagrant provisioner 运行时，`k3s_download_url` 能被正确解析为含架构后缀的 URL。

### 4.3 `ansible/group_vars/all.yml` — k3s URL 架构自适应

#### 变更

将固定的 `k3s_download_url` 改为按架构计算：

```yaml
# k3s 二进制架构映射（VM 架构，不是宿主机架构）
k3s_arch_map:
  x86_64: ""
  amd64: ""
  aarch64: "-arm64"
  arm64: "-arm64"

k3s_arch_suffix: "{{ k3s_arch_map[ansible_architecture] | default('__unsupported__') }}"

# k3s 下载地址（k3s 二进制，不是容器镜像）
# 默认走 Rancher 中国镜像。文件名按架构拼接：amd64=k3s，arm64=k3s-arm64。
k3s_download_url: >-
  https://rancher-mirror.rancher.cn/k3s/{{ k3s_version | replace('+', '-') }}/k3s{{ k3s_arch_suffix }}
```

#### 不支持架构处理

Ansible 在使用 `k3s_download_url` 前应失败得清晰。可在 `k3s-server`/`k3s-agent` install 任务前加断言：

```yaml
- name: Assert supported k3s architecture
  assert:
    that:
      - k3s_arch_suffix != '__unsupported__'
    fail_msg: >-
      Unsupported architecture: {{ ansible_architecture }}.
      Supported: x86_64/amd64, aarch64/arm64.
```

该断言可放在 `roles/k3s-common/tasks/main.yml` 或公共 preflight，避免 server/agent 重复。

#### 下载源策略

- 默认仍为 Rancher 中国镜像（保持现状，国内教学网络友好）。
- 已验证 rancher-mirror 与 GitHub release 均有 `k3s-arm64`。
- 不在本次硬编码多源 fallback（Ansible get_url 不适合复杂 fallback）；但把 URL 保持为单变量，用户可通过 `-e k3s_download_url=...` 覆盖。
- 文档中说明覆盖方式。

### 4.4 Ansible roles — 安装任务兼容

#### `roles/k3s-server/tasks/install.yml`

现状：

```yaml
- name: Download k3s binary
  get_url:
    url: "{{ k3s_download_url }}"
    dest: "{{ k3s_server_bin }}"
    mode: '0755'
    timeout: 120
  register: k3s_download
```

改动：无需改下载逻辑。可选增强：

- 在下载前增加架构断言（如果未放公共位置）。
- 下载失败时提示检查网络/镜像源/架构。

#### `roles/k3s-agent/tasks/install.yml`

现状使用 `{{ k3s_server_bin }}` 作为 dest（变量名有历史包袱，但值正确）。本次不改名，避免扩大影响。

#### `roles/k3s-common`

如放架构断言，放在 common 的早期任务中，server/agent 都会执行。

### 4.5 宿主机脚本 macOS 兼容

#### 4.5.1 `scripts/get-kubeconfig.sh`

问题：`sed -i "s/127.0.0.1/${SERVER_IP}/g" "$KUBECONFIG_DEST"` 在 macOS BSD sed 上失败。

修复：使用可移植临时文件方式：

```bash
tmp_kubeconfig="$(mktemp "${KUBECONFIG_DEST}.tmp.XXXXXX")"
sed "s/127.0.0.1/${SERVER_IP}/g" "$KUBECONFIG_DEST" > "$tmp_kubeconfig"
mv "$tmp_kubeconfig" "$KUBECONFIG_DEST"
```

验收：Linux GNU sed、macOS BSD sed 都能正常替换。

#### 4.5.2 `k3s-ops.sh` bash 3.2 兼容

问题：`_archive_vbox_logs` 使用 `mapfile -t stale < <(...)`。macOS `/bin/bash` 3.2 不支持 `mapfile`。

修复：替换为 bash 3.2 兼容写法：

```bash
local stale=()
while IFS= read -r line; do
  stale+=("$line")
done < <(ls -1t "${dest}"/*VBoxHeadless-*.log 2>/dev/null | tail -n "+$((keep + 1))")
```

或者更简单地直接用循环删除，无需数组。

#### 4.5.3 兼容性审计范围

本次审计并修复**教学主流程**触达的脚本：

| 文件 | 主流程触达 | 已知问题 | 动作 |
|---|---|---|---|
| `k3s-ops.sh` | 是 | `mapfile` (bash4) | 修复 |
| `lib/logging.sh` | 是 | 无已知阻塞（stat 已兼容） | 保持 |
| `lib/nodes.sh` | 是 | 需检查 | 审计 |
| `scripts/bootstrap.sh` | 是（init） | 无已知阻塞 | 保持，可增强提示 |
| `scripts/get-kubeconfig.sh` | 是（kubeconfig） | GNU `sed -i` | 修复 |
| `scripts/health-check.sh` | 是（status 间接） | 需审计 | 审计 |
| `scripts/privacy-check.sh` | 非主流程 | `mapfile` | 可顺手修，不阻塞 |
| `scripts/fetch-kubeconfig.sh` 等 | 按需 | 需审计 | 记录/顺手修 |

不在本次范围：`production/` 脚本（已有自己的兼容处理）。

#### 4.5.4 shebang 策略

保持 `#!/bin/bash`。修复 bash 3.2 不兼容写法，比要求用户安装 brew bash 更教学友好。文档中可说明“支持 macOS 自带 bash 3.2”。

### 4.6 `k3s-ops.sh init` / `scripts/bootstrap.sh` — 前置检查增强

#### 增强项

| 检查 | 条件 | 行为 |
|---|---|---|
| Vagrant 版本 | `vagrant --version` | 提示版本；Apple Silicon/arm64 时建议 >= 2.4 |
| VirtualBox 版本 | `vboxmanage --version` | 提示版本；Apple Silicon 时建议 >= 7.1 |
| 宿主机 OS/架构 | `uname -s`, `uname -m` | macOS arm64 时输出 Apple Silicon 提示 |
| Ansible | 已有 | 保持 |
| Python3 | 已有 | 保持 |

输出示例（macOS Apple Silicon）：

```text
[INFO] Host: Darwin arm64 (Apple Silicon)
[INFO] vagrant: Vagrant 2.4.x
[INFO] vboxmanage: 7.1.x
[WARN] Apple Silicon + VirtualBox: 需要 VirtualBox >= 7.1、Vagrant >= 2.4，且已在“系统设置 > 隐私与安全性”中允许 Oracle 扩展。
[WARN] 若 VirtualBox ARM 遇到稳定性问题，可在 vagrant/nodes.yml 设置 network.provider 为 vmware_desktop/parallels（需对应 Vagrant provider 插件）。
```

不阻塞安装（warn），除非缺少必需命令。

### 4.7 文档更新

#### `README.md`

- 环境要求按平台分组：Linux / macOS Intel / macOS Apple Silicon。
- 补充 macOS 安装命令示例（Homebrew）。
- 补充 Apple Silicon 注意事项。
- 增加常见故障条目。

#### `docs/architecture.md`

- 说明 Vagrantfile 的 `box_architecture` 自动检测逻辑。
- 说明 k3s 下载 URL 按 `ansible_architecture` 生成。
- 更新“环境要求”部分。

#### `vagrant/nodes.yml` 注释

- 新增 `provider`、`box_architecture` 可选字段注释。

## 5. 兼容性与风险

### 5.1 兼容性矩阵

| 场景 | 预期 |
|---|---|
| 现有 Linux x86_64 + VirtualBox | 无回归；`box_architecture` auto 检测为 amd64，URL 仍为 `k3s` |
| 现有 Windows `win/` 路径 | Vagrantfile 变更不应破坏 `windows_mode`；win/nodes.windows.yml 无新字段时走默认值 |
| macOS Intel + VirtualBox | amd64 路径，主要验证 BSD sed/bash3.2 修复 |
| macOS Apple Silicon + VirtualBox 7.1+ | arm64 box + `k3s-arm64`；主要风险在上游 VirtualBox ARM 稳定性 |
| 老 Vagrant (<2.4) + amd64 | 尽量兼容，不设置 `box_architecture` 或设置后无影响 |
| 老 Vagrant (<2.4) + arm64 | 明确报错，提示升级 |

### 5.2 风险

| 风险 | 等级 | 缓解 |
|---|---|---|
| VirtualBox ARM 上游不稳定（网络、Guest Additions、启动失败） | 中 | 文档标注 best-effort；提供 provider 逃生口；不承诺完全等同 Intel 体验 |
| Vagrant extra_vars 移除 `k3s_download_url`/`containerd_mirrors` 导致行为变化 | 中 | 验收 Linux 回归；发布说明写明；containerd_mirrors 统一到 group_vars 是改进 |
| bash 3.2 兼容修复遗漏 | 低 | 审计主流程脚本；在 macOS 上实际跑通 |
| rancher-mirror arm64 某版本缺包 | 低 | URL 可配置覆盖；报错信息包含手动覆盖示例 |
| 容器镜像无 arm64 变体 | 低-中 | 验证矩阵覆盖主要组件；文档提醒自定义镜像 |

### 5.3 回滚策略

- 所有改动在单独提交/PR 中，Linux 回归失败可整体回退。
- 新增 `nodes.yml` 字段均可选，删除不影响旧行为。
- `k3s_download_url` 仍可通过 Ansible `-e` 覆盖。

## 6. 验收标准

### 6.1 必须通过

- Linux x86_64：`./k3s-ops.sh init/up/install/status/kubeconfig` 全流程无回归。
- `vagrant validate` 通过（Linux、macOS 环境如有）。
- Ansible playbook syntax-check 通过：`ansible-playbook --syntax-check` 覆盖主要 playbook。
- `bash -n` 通过所有修改的 shell 脚本。
- `scripts/get-kubeconfig.sh` 在 macOS BSD sed 环境可用（或用可移植实现验证）。
- Vagrant provisioner 与 CLI（`ansible-playbook -i ansible/inventory.yml ansible/playbooks/...`）都能加载 `ansible/group_vars/all.yml`；移除 Vagrantfile 中 `k3s_download_url`/`containerd_mirrors` extra_vars 后行为正确。
- Apple Silicon 逻辑验证：`ansible_architecture=aarch64` 时生成 `k3s-arm64` URL；`box_architecture` 自动检测为 `arm64`。

### 6.2 有条件通过（需要对应环境）

- macOS Intel + VirtualBox：完整教学流程跑通。
- macOS Apple Silicon + VirtualBox >= 7.1：完整教学流程跑通，`kubectl get nodes` 显示 arm64 节点正常 Ready，主要 addon 镜像可拉取。

### 6.3 不作为本次阻塞

- 非 virtualbox provider 的完整教学文档。
- Windows 原生路径改造。
- 所有历史脚本的 bash 3.2 兼容（仅主流程必须）。

## 7. 实施顺序建议

1. **Vagrantfile + nodes.yml + group_vars 加载**：box_architecture/provider 检测；移除硬编码 amd64 `k3s_download_url` 和重复 `containerd_mirrors`；设置 `ansible.config_file`（可选但推荐）；新增 `ansible/playbooks/group_vars -> ../group_vars` 符号链接，确保 Vagrant provisioner 能加载 group_vars。
2. **ansible/group_vars/all.yml + 架构断言**：架构映射、URL 生成、不支持架构显式失败；确认 Vagrant provisioner/CLI 两条路径都能拿到正确 URL。
3. **宿主机脚本兼容**：`get-kubeconfig.sh` sed、`k3s-ops.sh` mapfile、主流程审计。
4. **init/bootstrap 提示增强**：macOS/Apple Silicon 检测与版本提示。
5. **文档**：README、architecture、nodes.yml 注释。
6. **验证**：Linux 回归；macOS 环境按可用性实测。

## 8. 实施后需同步的文档/检查

- `README.md`：环境要求、macOS 安装说明、常见故障。
- `docs/architecture.md`：架构自适应说明。
- `vagrant/nodes.yml`：字段注释。
- `AGENTS.md`：如有新的关键约定（例如 k3s URL 由 group_vars 按架构生成、Vagrantfile 不再传 download URL、`ansible/playbooks/group_vars` 为指向 `../group_vars` 的 symlink），补充一条简短约定。
- `scripts/privacy-check.sh`：如新增示例 IP/域名无需调整；确认无敏感信息。

## 9. 待确认问题

1. **containerd_mirrors 统一**：是否同意移除 Vagrantfile 中的 `containerd_mirrors` extra_vars，统一以 `ansible/group_vars/all.yml` 为准？（推荐同意，可减少双维护）
2. **非 virtualbox provider**：本次只做“配置可覆盖 + 文档提示”，还是完全不暴露 provider 字段？（推荐前者，成本低）
3. **Apple Silicon 实测环境**：你是否有 Apple Silicon Mac 可用于实测？如果没有，验收标准需要调整为“逻辑验证 + Intel/Linux 回归 + 文档标注待实测”。
4. **k3s 下载源**：默认仍用 rancher-mirror.cn，是否保持？（推荐保持，符合现有国内教学网络现实）
5. **Vagrant 最低版本**：是否把文档/检查中的建议版本提升到 Vagrant >= 2.4、VirtualBox >= 7.1？（推荐提升说明，但对 amd64 老环境尽量不硬阻塞）