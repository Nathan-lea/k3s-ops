# macOS 教学环境方案 A 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让主项目教学/实验环境在 macOS（Intel + Apple Silicon）上可用，同时保持现有 Linux/Vagrant+VirtualBox 教学流程不变。

**Architecture:** 采用“宿主机 Ansible + 架构自适应”方案：Vagrantfile 负责 box/provider/架构自动检测与可选覆盖，Ansible 根据 `ansible_architecture` 选择 `k3s`/`k3s-arm64` 下载 URL，宿主机脚本修复 macOS BSD sed/bash 3.2 兼容问题。通过 `ansible/playbooks/group_vars` 符号链接确保 Vagrant provisioner 能加载 group_vars，从而安全移除 Vagrantfile 中硬编码的 amd64 URL 和重复 mirrors。

**Tech Stack:** Vagrant (Ruby Vagrantfile), VirtualBox, Ansible, Bash, YAML, k3s, Git

**Spec:** `docs/macos-teaching-env-design-a.md`（本计划的所有任务都应与该设计一致；执行者应同时阅读该设计与本计划）

## Global Constraints

- 保持现有教学流程命令不变：`./k3s-ops.sh init/up/install/status/kubeconfig/upgrade`。
- 默认 provider 仍为 `virtualbox`；非 virtualbox 仅为受控逃生口，不作为本次完整教学承诺。
- k3s 二进制架构必须按 **VM 架构**（`ansible_architecture`）决定，不按宿主机架构猜；install/add/upgrade 所有下载路径都必须架构感知。
- 不改动 `production/` 目录任何部署逻辑；production 保持物理独立。
- 不新增 ops VM 模式（方案 B）或双模式（方案 C）。
- 旧 `vagrant/nodes.yml`（无新字段）必须继续工作。
- Vagrantfile 移除 `k3s_download_url`/`containerd_mirrors` extra_vars 后，必须保证 group_vars 在 Vagrant provisioner 与 CLI 两条路径都可加载。
- `ansible/playbooks/group_vars` symlink 是 Vagrant provisioner 加载 group_vars 的必须项。**默认不添加** Vagrantfile `ansible.config_file`；仅在真实 Vagrant 环境完成 provisioner smoke test 并记录结果后才可添加，若出现 roles/inventory 解析回归立即移除。
- 宿主机脚本修复以 bash 3.2/macOS BSD 工具兼容为目标；shebang 保持 `#!/bin/bash`。
- 所有改动后 `bash -n` 通过；涉及 Ansible 的改动用 `ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook --syntax-check -i ansible/inventory.yml ...`（从 repo root）或等效方式通过；Vagrantfile 改动 `ruby -c`/`vagrant validate`（有 vagrant 时）通过。
- 不提交无关文件；不 push。

## Review Focus

1. **Vagrant provisioner 加载不到 group_vars**：移除 extra_vars 后，`k3s_download_url`/`containerd_mirrors` 在 Vagrant provisioner 运行时应仍有正确值；symlink 必须生效。默认不加 `ansible.config_file`，避免 `ansible.cfg` 相对路径/CWD 回归。
2. **Apple Silicon arm64 二进制选错**：`ansible_architecture=aarch64/arm64` 时 install/add/upgrade 都必须下载 `k3s-arm64`；`x86_64/amd64` 必须下载 `k3s`；未知架构应明确失败，而不是静默下载错误文件。
3. **macOS bash 3.2/BSD sed 不兼容**：`k3s-ops.sh` 的 `mapfile`、`scripts/get-kubeconfig.sh` 的 `sed -i` 在 macOS 默认环境不应报错；审计范围要包含 `ansible/files`。
4. **Vagrant extra_vars 覆盖回归**：Vagrantfile 仍可能残留硬编码 amd64 `k3s_download_url` 或旧 `containerd_mirrors`，导致 group_vars 架构逻辑被覆盖；需检查并验证。
5. **旧 nodes.yml/Windows 路径回归**：不含新字段的 `vagrant/nodes.yml` 和 `win/nodes.windows.yml` 在 Linux/Windows 路径下应保持原行为，`windows_mode`/ops 检测不受影响；symlink 不应影响 Windows ops 路径。

---

## File Structure

| 文件 | 责任 | 动作 |
|---|---|---|
| `vagrant/Vagrantfile` | VM 编排、provider/box/arch 检测、Ansible provisioner 参数 | 修改 |
| `vagrant/nodes.yml` | 默认教学拓扑；新增可选字段注释 | 修改 |
| `ansible/playbooks/group_vars` | 让 playbook 旁可发现 group_vars（Vagrant provisioner 兼容） | 创建 symlink |
| `ansible/group_vars/all.yml` | 全局 Ansible 变量；k3s URL 架构映射 | 修改 |
| `ansible/roles/k3s-common/tasks/main.yml` | common 预检；引入架构断言 | 修改 |
| `ansible/roles/k3s-common/tasks/assert-k3s-arch.yml` | k3s 支持架构断言（install/add/upgrade 复用） | 创建 |
| `ansible/roles/k3s-manage/tasks/upgrade.yml` | k3s 升级；当前硬编码 amd64/GitHub URL | 修改 |
| `scripts/get-kubeconfig.sh` | 拉取 kubeconfig，替换 server 地址 | 修改 |
| `k3s-ops.sh` | CLI 主入口；init 提示、bash3.2 兼容 | 修改 |
| `scripts/bootstrap.sh` | init 依赖检查；macOS/arch 提示 | 修改 |
| `lib/nodes.sh` | 节点名解析 | 审计，必要时修改 |
| `ansible/files/health-check.sh` | 节点内健康检查（由 status 调用） | 审计，必要时修改 |
| `README.md` | 用户入口文档 | 修改 |
| `docs/architecture.md` | 架构说明 | 修改 |
| `AGENTS.md` | 仓库约定 | 修改（简短约定） |

---

### Task 1: 建立 group_vars 加载兼容基线

**Files:**
- Create: `ansible/playbooks/group_vars` (symlink -> `../group_vars`)
- Modify: `vagrant/Vagrantfile`
- Test: shell 验证命令

**Interfaces:**
- Consumes: 现有 `ansible/group_vars/all.yml`、`ansible/playbooks/*.yml`、Vagrant ansible provisioner。
- Produces: Vagrant provisioner 与 CLI 都能加载 `ansible/group_vars/all.yml`；后续任务可安全移除 Vagrantfile extra_vars。

- [ ] **Step 1: 确认现状**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
ls -la ansible/playbooks/group_vars 2>&1 | tail -5; echo "---"; ls ansible/group_vars/
```
Expected: `ansible/playbooks/group_vars` 不存在；`ansible/group_vars/` 包含 `all.yml agent.yml server.yml`。

- [ ] **Step 2: 创建 playbook 旁 group_vars 符号链接**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
ln -s ../group_vars ansible/playbooks/group_vars
ls -la ansible/playbooks/group_vars
readlink ansible/playbooks/group_vars
test -L ansible/playbooks/group_vars && echo ok
```
Expected: symlink 存在，指向 `../group_vars`。

> 注意：Windows 宿主机不直接运行 Ansible（走 ops VM），该 symlink 主要被 Linux/macOS 宿主机和 Linux VM 使用。Windows checkout 若未启用 `core.symlinks` 可能有问题，但不影响 win/ops 路径；实现时如发现问题再评估替代方案。

- [ ] **Step 3: 验证 CLI 路径能加载 group_vars**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook --syntax-check -i ansible/inventory.yml ansible/playbooks/k3s-cluster.yml 2>&1 | tail -20
python3 -c "import yaml; print(yaml.safe_load(open('ansible/group_vars/all.yml'))['k3s_version'])"
```
Expected: syntax check 通过；group_vars 可读。注意 `ansible/inventory.yml` 是空占位清单（hosts 可能为 0），**不要**把 `ansible-inventory --graph` 对空清单的结果当作 Vagrant provisioner 加载 group_vars 的证据。

- [ ] **Step 4: 默认不设置 ansible.config_file（避免相对路径回归）**

**默认动作**：不在 `vagrant/Vagrantfile` 中添加 `ansible.config_file`。symlink（Step 2）已保证 Vagrant provisioner 能加载 group_vars；Vagrantfile 也已设置 `ENV['ANSIBLE_ROLES_PATH']`。

**仅在真实 Vagrant 环境可 smoke test 时才考虑添加**：

```ruby
# 仅 smoke test 通过后才启用
# ansible.config_file = File.join(__dir__, '..', 'ansible', 'ansible.cfg')
```

Smoke test 门槛（必须在 Vagrant-capable 环境执行并记录结果）：`cd vagrant && vagrant validate` 通过，且对一个可丢弃节点执行 `vagrant provision --provision-with ansible <node>` 无 roles/inventory 解析错误。若有任何解析问题，不添加/立即移除该行。

- [ ] **Step 5: 语法检查**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
ruby -c vagrant/Vagrantfile
ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook --syntax-check -i ansible/inventory.yml ansible/playbooks/k3s-cluster.yml 2>&1 | tail -20
```
Expected: `Syntax OK`；playbook syntax check 通过。

- [ ] **Step 6: Commit**

```bash
git add ansible/playbooks/group_vars vagrant/Vagrantfile
git commit -m "fix(ansible): 让 Vagrant provisioner 可加载 group_vars"
```

---

### Task 2: Vagrantfile 架构/provider 检测与硬编码移除

**Files:**
- Modify: `vagrant/Vagrantfile`
- Modify: `vagrant/nodes.yml`
- Test: `ruby -c`, `vagrant validate`（如有）

**Interfaces:**
- Consumes: `vagrant/nodes.yml` 的 `network.provider`、`network.box_architecture`（可选）；宿主机 `RbConfig::CONFIG['host_cpu']`。
- Produces: `resolved_box_arch`（`amd64`/`arm64`）用于 box 架构；不再向 Ansible 传硬编码 amd64 `k3s_download_url`；不再传重复 `containerd_mirrors`。

- [ ] **Step 1: 写一个最小验证脚本/命令检查当前硬编码**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
grep -n "k3s_download_url\|containerd_mirrors\|box_architecture\|provider" vagrant/Vagrantfile
```
Expected: 能看到 `k3s_download_url: .../k3s` 和 `containerd_mirrors` extra_vars；没有 `box_architecture`。

- [ ] **Step 2: 在 Vagrantfile 增加架构/provider 解析逻辑**

在文件顶部（`require 'yaml'` 后）加入：

```ruby
require 'rbconfig'
```

在 `network_cfg` 读取后加入（Ruby）：

```ruby
provider_name = network_cfg.fetch('provider', 'virtualbox').to_s
box_arch_cfg  = network_cfg.fetch('box_architecture', 'auto').to_s.downcase

def detect_host_arch
  arch = RbConfig::CONFIG['host_cpu'].to_s.downcase
  case arch
  when 'arm64', 'aarch64' then 'arm64'
  when 'x86_64', 'amd64' then 'amd64'
  else 'amd64'
  end
end

resolved_box_arch = case box_arch_cfg
when 'auto' then detect_host_arch
when 'amd64', 'x86_64' then 'amd64'
when 'arm64', 'aarch64' then 'arm64'
else
  abort "Unsupported box_architecture: #{box_arch_cfg}. Use auto|amd64|arm64."
end
```

- [ ] **Step 3: 设置 box_architecture（兼容保护）**

在 `config.vm.box = ...` 后加入：

```ruby
if config.vm.respond_to?(:box_architecture=)
  config.vm.box_architecture = resolved_box_arch
elsif resolved_box_arch != 'amd64'
  abort "Vagrant >= 2.4 is required for box_architecture=#{resolved_box_arch}. Please upgrade Vagrant."
end
```

仅对非 amd64 强制要求新 Vagrant；amd64 老环境尽量不破坏。

- [ ] **Step 4: 移除硬编码 k3s_download_url extra_var**

从 `ansible.extra_vars` 删除：

```ruby
k3s_download_url: "https://github.com/k3s-io/k3s/releases/download/#{nodes_config['k3s_version']}/k3s",
```

保留 `k3s_version`。不要在 Vagrantfile 中拼架构 URL（guest arch 在 provision 前未知）。

**行为变化（需记录）**：Vagrant provisioner 当前通过 extra_var 使用 GitHub releases；移除后将使用 `ansible/group_vars/all.yml` 的 rancher-mirror 架构感知 URL。这是有意变化（与现有国内教学网络策略一致），需在发布说明/验证中记录。

- [ ] **Step 5: 移除重复 containerd_mirrors extra_vars**

从 `ansible.extra_vars` 删除 `containerd_mirrors` 块。统一以 `ansible/group_vars/all.yml` 为准（Task 1 已确保 group_vars 可加载）。

**行为变化（需记录）**：Vagrantfile 当前传的是较小 mirror 集合；`ansible/group_vars/all.yml` 有更完整集合（含 registry.k8s.io/quay.io 的 daocloud 镜像）。移除后以 group_vars 为准，这是预期改进，但要在验证中确认关键 registry 都存在。注意 quay 端点也会变化（当前 Vagrantfile 用 `quay.mirrors.ustc.edu.cn`，group_vars 用 `quay.m.daocloud.io`），验证时一并确认。

- [ ] **Step 6: 更新 vagrant/nodes.yml 注释示例**

在 `network` 下添加注释（不改变默认行为）：

```yaml
network:
  subnet: 192.168.56.0/24
  box: bento/ubuntu-22.04
  # 可选：virtualbox（默认）| vmware_desktop | parallels
  # provider: virtualbox
  # 可选：auto（默认，按宿主机检测）| amd64 | arm64
  # box_architecture: auto
```

- [ ] **Step 7: 语法/校验**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
ruby -c vagrant/Vagrantfile
python3 -c "import yaml; yaml.safe_load(open('vagrant/nodes.yml')); print('ok')"
grep -n "k3s_download_url\|containerd_mirrors" vagrant/Vagrantfile || echo "no hardcoded url/mirrors"
```
Expected: Ruby syntax OK；YAML ok；Vagrantfile 不再包含硬编码 `k3s_download_url`/`containerd_mirrors` extra_vars。

- [ ] **Step 8: Commit**

```bash
git add vagrant/Vagrantfile vagrant/nodes.yml
git commit -m "feat(vagrant): 支持 box 架构自动检测并移除 amd64 硬编码"
```

---

### Task 3: Ansible k3s 下载 URL 架构自适应、断言与升级路径

**Files:**
- Modify: `ansible/group_vars/all.yml`
- Create: `ansible/roles/k3s-common/tasks/assert-k3s-arch.yml`
- Modify: `ansible/roles/k3s-common/tasks/main.yml`
- Modify: `ansible/roles/k3s-manage/tasks/upgrade.yml`
- Test: `ansible-playbook --syntax-check`, python/yaml check

**Interfaces:**
- Consumes: `ansible_architecture` fact（guest）、`k3s_version`、`k3s_upgrade_version`。
- Produces: `k3s_arch_suffix`、`k3s_download_url`（amd64=`k3s`，arm64=`k3s-arm64`）；install/add/upgrade 全路径架构感知；不支持架构时断言失败。

- [ ] **Step 1: 写失败检查（当前 URL/升级路径未架构感知）**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
grep -n "k3s_arch\|k3s-arm64" ansible/group_vars/all.yml || echo "missing"
grep -n "download/{{ k3s_upgrade_version }}/k3s\"" ansible/roles/k3s-manage/tasks/upgrade.yml
```
Expected: group_vars 缺少映射；upgrade.yml 仍有硬编码 `.../k3s"`。

- [ ] **Step 2: 修改 ansible/group_vars/all.yml**

将 k3s 下载地址段改为：

```yaml
# k3s 二进制架构映射（基于 VM 的 ansible_architecture，不是宿主机）
k3s_arch_map:
  x86_64: ""
  amd64: ""
  aarch64: "-arm64"
  arm64: "-arm64"

k3s_arch_suffix: "{{ k3s_arch_map[ansible_architecture | default('x86_64')] | default('__unsupported__') }}"

# k3s 下载地址（k3s 可执行文件，不是容器镜像）
# 默认走 Rancher 中国镜像：github.com 在部分网络不可达。
# 镜像路径用 - 而非 +：v1.30.2+k3s2 → v1.30.2-k3s2
# 文件名按架构：amd64=k3s，arm64=k3s-arm64（rancher-mirror/GitHub 已验证一致）
k3s_download_url: >-
  https://rancher-mirror.rancher.cn/k3s/{{ k3s_version | replace('+', '-') }}/k3s{{ k3s_arch_suffix }}
```

注意：`ansible_architecture` 在 facts 未收集时可能未定义；`default('x86_64')` 仅作为模板安全兜底。断言任务必须在安装/升级前检查真实架构。

- [ ] **Step 3: 创建共享架构断言并接入 install/add/upgrade 路径**

Create `ansible/roles/k3s-common/tasks/assert-k3s-arch.yml`：

```yaml
---
- name: Assert supported architecture for k3s binary
  assert:
    that:
      - ansible_architecture in ['x86_64', 'amd64', 'aarch64', 'arm64']
      - k3s_arch_suffix is defined
      - k3s_arch_suffix != '__unsupported__'
    fail_msg: >-
      Unsupported ansible_architecture={{ ansible_architecture | default('undefined') }}.
      Supported: x86_64/amd64 (k3s), aarch64/arm64 (k3s-arm64).
      Override k3s_download_url for install/add, or k3s_upgrade_download_url for upgrade.
```

在 `ansible/roles/k3s-common/tasks/main.yml` **作为第一条 task** include（覆盖 install/add 路径，在 hostname/swap/sysctl 前）：

```yaml
- name: Assert k3s architecture is supported
  include_tasks: assert-k3s-arch.yml
```

同时在 `ansible/roles/k3s-manage/tasks/upgrade.yml` 下载前通过 role 引用 include 同一断言（upgrade 不走 k3s-common）：

```yaml
- name: Assert k3s architecture is supported
  include_role:
    name: k3s-common
    tasks_from: assert-k3s-arch
```

- [ ] **Step 4: 修复 upgrade 路径为架构感知**

修改 `ansible/roles/k3s-manage/tasks/upgrade.yml`，将硬编码下载 URL 改为架构感知形式。推荐引入显式的 `k3s_upgrade_download_url`（便于覆盖），例如：

```yaml
- name: Set k3s upgrade download URL
  set_fact:
    k3s_upgrade_download_url: >-
      {{ k3s_upgrade_download_url | default('https://rancher-mirror.rancher.cn/k3s/' ~ (k3s_upgrade_version | replace('+', '-')) ~ '/k3s' ~ k3s_arch_suffix) }}

- name: Download new k3s binary
  get_url:
    url: "{{ k3s_upgrade_download_url }}"
    dest: "{{ k3s_server_bin }}"
    mode: '0755'
    force: yes
    timeout: 120
```

注意：`force: yes` 相比当前行为是有意变化（确保升级时覆盖旧二进制）；保持记录。不要复用基于 `k3s_version` 的 `k3s_download_url`，除非显式切换变量语义。

- [ ] **Step 5: 验证模板渲染与语法**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
python3 - <<'PY'
import yaml
d=yaml.safe_load(open('ansible/group_vars/all.yml'))
print('k3s_arch_map' in d, 'k3s_arch_suffix' in d, 'k3s_download_url' in d)
PY
ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook --syntax-check -i ansible/inventory.yml ansible/playbooks/k3s-cluster.yml 2>&1 | tail -20
ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook --syntax-check -i ansible/inventory.yml ansible/playbooks/k3s-upgrade.yml 2>&1 | tail -20
```
Expected: key 存在；cluster/upgrade syntax check 通过。

- [ ] **Step 6: 验证 URL 生成语义（离线模拟）**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
python3 - <<'PY'
m={'x86_64':'','amd64':'','aarch64':'-arm64','arm64':'-arm64'}
for ver in ['v1.30.2+k3s2','v1.31.0+k3s1']:
    v=ver.replace('+','-')
    for arch in ['x86_64','aarch64']:
        print(f"{ver} {arch}: .../{v}/k3s{m[arch]}")
PY
```
Expected: amd64 无后缀，arm64 为 `k3s-arm64`；upgrade 版本也正确替换 `+`。

- [ ] **Step 7: Commit**

```bash
git add ansible/group_vars/all.yml ansible/roles/k3s-common/tasks/main.yml ansible/roles/k3s-common/tasks/assert-k3s-arch.yml ansible/roles/k3s-manage/tasks/upgrade.yml
git commit -m "feat(ansible): k3s 安装与升级按 VM 架构自适应"
```

---

### Task 4: 宿主机脚本 macOS 兼容修复

**Files:**
- Modify: `scripts/get-kubeconfig.sh`
- Modify: `k3s-ops.sh`
- Modify: `scripts/bootstrap.sh` (可选小增强，若与 Task 5 合并则只做兼容)
- Audit: `lib/nodes.sh`, `lib/logging.sh`, `ansible/files/health-check.sh`, `scripts/*.sh`

**Interfaces:**
- Consumes: 现有 CLI 参数、vagrant ssh、kubeconfig 文件路径。
- Produces: macOS BSD sed/bash 3.2 可运行的主流程脚本。

- [ ] **Step 1: 复现/确认问题点**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
grep -n 'sed -i "' scripts/get-kubeconfig.sh
grep -n 'mapfile' k3s-ops.sh scripts/privacy-check.sh
```
Expected: 命中 get-kubeconfig.sh 的 GNU sed；命中 k3s-ops.sh 的 mapfile。`scripts/privacy-check.sh` 的 `mapfile` 为非主流程，可顺手修复但不阻塞方案 A。

- [ ] **Step 2: 修复 scripts/get-kubeconfig.sh 的 sed -i**

将：

```bash
sed -i "s/127.0.0.1/${SERVER_IP}/g" "$KUBECONFIG_DEST"
```

改为可移植写法：

```bash
tmp_kubeconfig="$(mktemp "${KUBECONFIG_DEST}.tmp.XXXXXX")"
sed "s/127.0.0.1/${SERVER_IP}/g" "$KUBECONFIG_DEST" > "$tmp_kubeconfig"
mv "$tmp_kubeconfig" "$KUBECONFIG_DEST"
```

- [ ] **Step 3: 修复 k3s-ops.sh 的 mapfile（bash 3.2 兼容）**

将 `_archive_vbox_logs` 中：

```bash
local -a stale=()
mapfile -t stale < <(ls -1t "${dest}"/*VBoxHeadless-*.log 2>/dev/null | tail -n "+$((keep + 1))")
if [ "${#stale[@]}" -gt 0 ]; then
  rm -f "${stale[@]}"
  log_debug "Pruned ${#stale[@]} old VirtualBox log(s) (keep latest ${keep})"
fi
```

改为：

```bash
local stale_count=0
while IFS= read -r stale_file; do
  [ -n "$stale_file" ] || continue
  rm -f "$stale_file"
  stale_count=$((stale_count + 1))
done < <(ls -1t "${dest}"/*VBoxHeadless-*.log 2>/dev/null | tail -n "+$((keep + 1))")
if [ "$stale_count" -gt 0 ]; then
  log_debug "Pruned ${stale_count} old VirtualBox log(s) (keep latest ${keep})"
fi
```

- [ ] **Step 4: 审计主流程脚本的 macOS 不兼容模式**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
grep -rn 'sed -i ' k3s-ops.sh lib scripts ansible/files | grep -v '.git'
grep -rnE 'mapfile|readarray' k3s-ops.sh lib scripts ansible/files | grep -v '.git'
grep -rnE 'readlink -f|realpath' k3s-ops.sh lib scripts ansible/files | grep -v '.git'
grep -rn 'date -d' k3s-ops.sh lib scripts ansible/files | grep -v '.git'
```

Expected: 主流程脚本无阻塞性 GNU-only 用法。`ansible/files/health-check.sh` 也在审计范围内（`k3s-ops.sh status` 会用到）。若发现非主流程（如 `scripts/privacy-check.sh` mapfile），可顺手修或记录，不阻塞 Task 完成。

- [ ] **Step 5: bash 语法检查**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
bash -n k3s-ops.sh
bash -n scripts/get-kubeconfig.sh
bash -n scripts/bootstrap.sh
bash -n lib/logging.sh lib/nodes.sh
bash -n ansible/files/health-check.sh
```
Expected: 全部 exit 0。

- [ ] **Step 6: Commit**

```bash
git add k3s-ops.sh scripts/get-kubeconfig.sh
# 如有其他审计修复一并 add
git commit -m "fix(scripts): 修复 macOS bash3.2/BSD sed 兼容问题"
```

---

### Task 5: init/bootstrap 前置检查增强（macOS 提示）

**Files:**
- Modify: `scripts/bootstrap.sh`
- Modify: `k3s-ops.sh` (可选，仅当需要在 init 输出中补充架构提示)
- Test: `bash -n`, 本地运行 `./k3s-ops.sh init`

**Interfaces:**
- Consumes: `uname -s`, `uname -m`, `vagrant --version`, `vboxmanage --version`。
- Produces: macOS/Apple Silicon 友好提示；不误伤 Linux；缺少必需命令仍失败。

- [ ] **Step 1: 确认现有 bootstrap 行为**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
bash -n scripts/bootstrap.sh
./k3s-ops.sh init 2>&1 | tail -20
```
Expected: 当前 init 可运行并输出依赖检查。

- [ ] **Step 2: 增加 OS/架构检测提示**

在 `scripts/bootstrap.sh` 的检查前或后加入：

```bash
OS_NAME="$(uname -s 2>/dev/null || echo unknown)"
OS_ARCH="$(uname -m 2>/dev/null || echo unknown)"
log_info "Host: ${OS_NAME} ${OS_ARCH}"

if [ "$OS_NAME" = "Darwin" ]; then
  if [ "$OS_ARCH" = "arm64" ] || [ "$OS_ARCH" = "aarch64" ]; then
    log_warn "Apple Silicon detected. Teaching environment requires VirtualBox >= 7.1 and Vagrant >= 2.4."
    log_warn "If VirtualBox ARM is unstable, set network.provider in vagrant/nodes.yml (vmware_desktop/parallels)."
  else
    log_info "macOS Intel detected. VirtualBox + Vagrant + Ansible are required."
  fi
fi
```

- [ ] **Step 3: 增加版本提示（非阻塞）**

对 vagrant/vboxmanage 提取版本号并在 Apple Silicon 时做非阻塞提示。不要因为版本解析失败而中断 init。

- [ ] **Step 4: 验证**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
bash -n scripts/bootstrap.sh
./k3s-ops.sh init 2>&1 | tail -30
```
Expected: init 通过；Linux 主机显示 Host 信息，不出现误导性 Apple Silicon 警告。

- [ ] **Step 5: Commit**

```bash
git add scripts/bootstrap.sh k3s-ops.sh
git commit -m "feat(init): 增加 macOS/Apple Silicon 前置提示"
```

---

### Task 6: 文档与仓库约定更新

**Files:**
- Modify: `README.md`
- Modify: `docs/architecture.md`
- Modify: `AGENTS.md`
- Modify: `vagrant/nodes.yml` (已有注释则确认一致)

**Interfaces:**
- Consumes: Task 1-5 的最终行为。
- Produces: 面向学员的 macOS 前置说明、排障、架构说明、仓库约定。

- [ ] **Step 1: 更新 README.md 环境要求**

将“环境要求”改为分平台表述，至少包含：

- Linux：VirtualBox >= 7.0, Vagrant >= 2.4（建议）, Ansible >= 2.15, Python3。
- macOS Intel：同上，补充 Homebrew 安装提示。
- macOS Apple Silicon：VirtualBox >= 7.1, Vagrant >= 2.4, Ansible >= 2.15；首次运行需允许 Oracle 扩展；说明 arm64 box/k3s-arm64 自动适配。
- 常见故障：box 架构不匹配、`exec format error`（k3s 二进制架构错）、BSD sed（已修复但提醒旧版本）、VirtualBox ARM 网络异常。

- [ ] **Step 2: 更新 docs/architecture.md**

补充：

- Vagrantfile `box_architecture` 自动检测与 `network.provider/box_architecture` 覆盖。
- k3s 下载 URL 由 `ansible/group_vars/all.yml` 按 `ansible_architecture` 生成。
- `ansible/playbooks/group_vars` symlink 的原因（Vagrant provisioner 临时 inventory）。
- Apple Silicon 容器镜像需 `linux/arm64` 的验证提醒。

- [ ] **Step 3: 更新 AGENTS.md 约定**

在合适位置添加简短约定（不要写长文）：

- k3s 二进制下载 URL 由 `ansible/group_vars/all.yml` 按 `ansible_architecture` 生成；Vagrantfile 不传硬编码 `k3s_download_url`。
- `ansible/playbooks/group_vars` 是指向 `../group_vars` 的 symlink，保证 Vagrant provisioner 加载 group_vars；不要删除。
- macOS 兼容：主流程脚本避免 GNU-only `sed -i`、bash4 `mapfile`。

- [ ] **Step 4: 文档一致性检查**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
grep -n "box_architecture\|k3s-arm64\|Apple Silicon" README.md docs/architecture.md AGENTS.md | head -20
```
Expected: 三个文档都有相关关键说明。

- [ ] **Step 5: Commit**

```bash
git add README.md docs/architecture.md AGENTS.md vagrant/nodes.yml
git commit -m "docs: 补充 macOS 教学环境支持说明与架构约定"
```

---

### Task 7: 全量验证与交付检查

**Files:**
- Test: 无新代码文件，执行验证命令
- Modify: 如发现问题，仅修复本方案范围内问题

**Interfaces:**
- Consumes: Task 1-6 全部改动。
- Produces: 可交付的验证结果，明确哪些在当前环境已验证、哪些需要 macOS 实机。

- [ ] **Step 1: 静态语法/格式检查**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
bash -n k3s-ops.sh lib/logging.sh lib/nodes.sh scripts/*.sh
ruby -c vagrant/Vagrantfile
python3 -c "import yaml; yaml.safe_load(open('vagrant/nodes.yml')); yaml.safe_load(open('win/nodes.windows.yml')); yaml.safe_load(open('ansible/group_vars/all.yml')); print('yaml ok')"
```
Expected: 全部通过，包括 Windows nodes 文件仍可解析。

- [ ] **Step 2: Ansible syntax-check（统一 ANSIBLE_CONFIG）**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
export ANSIBLE_CONFIG=ansible/ansible.cfg
ansible-playbook --syntax-check -i ansible/inventory.yml ansible/playbooks/k3s-cluster.yml 2>&1 | tail -20
ansible-playbook --syntax-check -i ansible/inventory.yml ansible/playbooks/k3s-add-agent.yml 2>&1 | tail -10
ansible-playbook --syntax-check -i ansible/inventory.yml ansible/playbooks/k3s-add-server.yml 2>&1 | tail -10
ansible-playbook --syntax-check -i ansible/inventory.yml ansible/playbooks/k3s-upgrade.yml 2>&1 | tail -10
```
Expected: 全部 syntax check 通过。

- [ ] **Step 3: 关键行为检查**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
# Vagrantfile 不应硬编码 amd64 k3s 下载 URL / containerd_mirrors extra_vars
! grep -n 'releases/download/.*/k3s"' vagrant/Vagrantfile
! grep -n 'k3s_download_url: "https://github.com/k3s-io/k3s/releases/download' vagrant/Vagrantfile
! grep -n 'containerd_mirrors:' vagrant/Vagrantfile

# group_vars 应有架构映射和 k3s-arm64
grep -n 'k3s_arch_map' ansible/group_vars/all.yml
grep -n 'k3s-arm64' ansible/group_vars/all.yml
grep -n 'k8s.m.daocloud.io\|quay.m.daocloud.io' ansible/group_vars/all.yml

# upgrade 路径不应硬编码 amd64 GitHub URL
! grep -n 'github.com/k3s-io/k3s/releases/download/{{ k3s_upgrade_version }}/k3s"' ansible/roles/k3s-manage/tasks/upgrade.yml

# 架构断言存在
test -f ansible/roles/k3s-common/tasks/assert-k3s-arch.yml
grep -n 'assert-k3s-arch' ansible/roles/k3s-common/tasks/main.yml

# symlink 存在且目标正确
test -L ansible/playbooks/group_vars
[ "$(readlink ansible/playbooks/group_vars)" = "../group_vars" ]

# vagrant validate（有 vagrant 时）
if command -v vagrant >/dev/null 2>&1; then (cd vagrant && vagrant validate); else echo "skip vagrant validate"; fi

# 隐私：新增文档不应包含本机绝对路径
! grep -rn '<repo-local-path>' docs/macos-teaching-env-design-a.md docs/macos-teaching-env-scheme-a-implementation-plan.md docs/macos-teaching-env-schemes.md
```
Expected: 全部符合；无硬编码 amd64 URL；upgrade 已架构感知；symlink 正确；无隐私路径泄漏。

- [ ] **Step 4: Linux init 冒烟**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
./k3s-ops.sh init 2>&1 | tail -30
```
Expected: 通过；显示 Host 信息；不因 macOS 检测逻辑误报错误。

- [ ] **Step 5: 记录验证结果**

在最终交付消息中列出：

- 已在当前 Linux 环境验证的命令及结果。
- 未验证项（macOS Intel/Apple Silicon 实机、VirtualBox ARM 启动、arm64 addon 镜像拉取）。
- 如有风险或待确认项，明确标注。

- [ ] **Step 6: Commit（如有修复）**

```bash
git status --short
# 若 Task 7 产生修复：
git add <fixed-files>
git commit -m "test: 修复方案 A 验证发现的问题"
```

---

## Final Review Checklist

- [ ] `vagrant/nodes.yml` 无新字段时行为不变；`win/nodes.windows.yml` 仍可解析，`windows_mode`/ops 路径不受影响。
- [ ] Vagrantfile 不再硬编码 amd64 `k3s_download_url`/重复 `containerd_mirrors`；group_vars 按 `ansible_architecture` 生成正确 URL。
- [ ] Vagrant provisioner 可加载 `ansible/group_vars/all.yml`（symlink 存在且指向 `../group_vars`）；默认不添加 `ansible.config_file`，仅真实 smoke test 通过后才考虑。
- [ ] install/add/upgrade 全路径架构感知；`ansible/roles/k3s-manage/tasks/upgrade.yml` 无硬编码 amd64/GitHub `.../k3s` URL；升级使用 `k3s_upgrade_download_url`（可覆盖）。
- [ ] 共享架构断言作为 `k3s-common` 第一条 task，并在 upgrade 下载前通过 `include_role tasks_from=assert-k3s-arch` 复用；不支持架构显式失败。
- [ ] Vagrant provisioner 下载源从 GitHub extra_var 切换为 rancher-mirror group_vars 属于有意行为变化，已在发布说明/验证中记录。
- [ ] `scripts/get-kubeconfig.sh` 无 GNU `sed -i`；`k3s-ops.sh` 无 bash4-only `mapfile`（主流程）；`ansible/files/health-check.sh` 已审计。
- [ ] README/architecture/AGENTS 已更新 macOS 说明和约定。
- [ ] Linux x86_64 主流程无回归（至少静态检查 + init 冒烟）；Ansible syntax-check 使用 `ANSIBLE_CONFIG=ansible/ansible.cfg`。
- [ ] Apple Silicon 实机验证项已明确标注为待实测（若本次无环境）。
- [ ] 新增文档无 `<repo-local-path>` 等本机绝对路径泄漏。
