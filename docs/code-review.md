# k3s-ops 代码审查报告

> 审查日期: 2026-05-25
> 审查方式: 手动审查 + 静态分析
> 审查范围: 全部 Ansible playbooks / roles / templates / CLI 入口 / shell 脚本 / Vagrantfile

---

## 1. Summary

k3s-ops 是一个基于 Vagrant + Ansible 的 k3s 全生命周期管理项目。核心设计是通过一份 `nodes.yml` 定义集群拓扑，用统一 CLI 完成部署、扩容、升级、备份恢复。项目整体结构清晰，职责划分合理，但存在若干安全实践和代码健壮性方面的不足。

**总体评估**: 63/100 — 功能完整，适用于本地测试，但若计划维护或扩展开源使用，需要先解决关键安全和可维护性问题。

---

## 2. Critical（必须修复）

### CRIT-001: `curl | bash` 安装 Helm — 供应链风险

**文件**: `ansible/playbooks/rancher-deploy.yml:17-19`, `nginx-ingress-deploy.yml:17-19`

```yaml
- name: Ensure helm binary is installed
  shell: |
    if ! command -v helm &> /dev/null; then
      curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    fi
```

**问题**: `curl | bash` 没有任何完整性校验。网络劫持或上游被攻陷可在 server 节点执行任意代码。

**修复**:
```yaml
- name: Download helm installer
  get_url:
    url: https://get.helm.sh/helm-v3.21.0-linux-amd64.tar.gz
    dest: /tmp/helm.tar.gz
    checksum: "sha256:<预期值>"
- name: Install helm binary
  unarchive:
    src: /tmp/helm.tar.gz
    dest: /usr/local/bin
    remote_src: yes
    include: linux-amd64/helm
    extra_opts: ["--strip-components=1"]
```

或者预下载 helm 到项目仓库，通过 Ansible 直接分发预置二进制。

---

### CRIT-002: k3s 二进制下载无完整性校验

**文件**: `ansible/roles/k3s-server/tasks/install.yml:5-9`, `k3s-agent/tasks/install.yml:5-9`

```yaml
- name: Download k3s binary
  get_url:
    url: "{{ k3s_download_url }}"
    dest: "{{ k3s_server_bin }}"
    mode: '0755'
```

**问题**: `get_url` 没有设置 `checksum`，下载的二进制可能被篡改却不被察觉。

**修复**: 在 `group_vars/all.yml` 中加入 checksum 映射表：
```yaml
k3s_checksums:
  v1.30.2+k3s2: "sha256:a1b2c3d4e5..."
```
```yaml
- name: Download k3s binary
  get_url:
    url: "{{ k3s_download_url }}"
    dest: "{{ k3s_server_bin }}"
    checksum: "{{ k3s_checksums[k3s_version] }}"
    mode: '0755'
```

---

### CRIT-003: kubectl exec 密码重置缺少 pod 存在性检查

**文件**: `ansible/playbooks/rancher-reset-admin.yml:7-12`

```yaml
- name: Get rancher pod name
  command: >
    kubectl get pods -n cattle-system
    -l app=rancher
    -o jsonpath='{.items[0].metadata.name}'
  register: rancher_pod
- name: Reset admin password
  command: >
    kubectl exec -n cattle-system {{ rancher_pod.stdout }} --
    rancher reset-admin
```

**问题**: 第一行取 pod 名未判空。如果 Rancher 未部署或 pod 未 Running，`rancher_pod.stdout` 为空字符串，`kubectl exec "" --` 会执行不明命令。

**修复**:
```yaml
- name: Get rancher pod name
  command: >
    kubectl get pods -n cattle-system
    -l app=rancher
    -o jsonpath='{.items[0].metadata.name}'
  register: rancher_pod
  failed_when: rancher_pod.stdout == ""
```

---

### CRIT-004: 敏感命令/变量未使用 `no_log`

**文件**: `ansible/roles/k3s-server/tasks/main.yml:38`, `join.yml:10`, `rancher-deploy.yml` 多处

Token 和密码在 Ansible 输出和日志中明文可见。虽然 shell 脚本层面已有日志库，但 Ansible 自身也会记录输出到 `ansible-playbook` 的 stdout。

**修复**:
```yaml
- name: Set node token fact
  set_fact:
    k3s_token: "{{ node_token_slurp.content | b64decode | trim }}"
    cacheable: false
  no_log: true
```

---

## 3. Major（建议修复）

### MAJ-01: Ansible fact cache 权限过松

**文件**: `ansible/ansible.cfg:6-7`

```ini
fact_caching = jsonfile
fact_caching_connection = /tmp/ansible-cache
```

`/tmp` 默认 1777 权限，所有用户可读写该目录。k3s token 缓存在此目录中。

**修复**:
```ini
fact_caching_connection = ${PROJECT_DIR}/.ansible-cache
```
并在 `.gitignore` 中添加 `.ansible-cache/`。

---

### MAJ-02: remove-node 用 ignore_errors 掩盖删除失败

**文件**: `ansible/roles/k3s-manage/tasks/remove-node.yml`

```yaml
- name: Cordon the node
  command: kubectl cordon {{ inventory_hostname }}
  delegate_to: "{{ first_server_host }}"
  ignore_errors: true
```

**问题**: cordon、drain、delete node 全部 `ignore_errors: true`，任何失败都不会中断流程。节点资源可能残留，下次 add-node 同名时会出问题。

**修复**: 只在"节点已不存在"这种预期错误上跳过：
```yaml
- name: Delete the node from cluster
  command: kubectl delete node {{ inventory_hostname }}
  delegate_to: "{{ first_server_host }}"
  register: delete_result
  failed_when:
    - delete_result.rc != 0
    - '"not found" not in delete_result.stderr'
```

---

### MAJ-03: Vagrantfile 和 group_vars 的镜像配置重复

**文件**: `vagrant/Vagrantfile:80-91` vs `ansible/group_vars/all.yml:26-34`

两处各自定义了 `containerd_mirrors`，且值不一致（Vagrantfile 中少一个 gcr.io）。修改一处忘了另一处就会产生 diff。

**修复**: 只保留 `group_vars/all.yml` 中的定义，Vagrantfile 的 extra_vars 中移除 `containerd_mirrors`，让 Vagrant 的 Ansible 自动从 group_vars 加载。

---

### MAJ-04: 升级 playbook 缺少版本校验

**文件**: `ansible/roles/k3s-manage/tasks/upgrade.yml`

```yaml
- name: Download new k3s binary
  get_url:
    url: "https://github.com/k3s-io/k3s/releases/download/{{ k3s_upgrade_version }}/k3s"
```

**问题**: `k3s_upgrade_version` 没有校验格式。如果传入了 `v1.30.1` 但该版本不存在（或少写了 `+k3s1`），会下载失败或下载到错误的文件。

**修复**:
```yaml
- name: Validate version format
  assert:
    that:
      - k3s_upgrade_version is match('v\d+\.\d+\.\d+\+k3s\d+')
    fail_msg: "Version must be in format vX.Y.Z+k3sN (e.g. v1.31.0+k3s1)"
```

---

### MAJ-05: get-kubeconfig.sh IP 替换不精确

**文件**: `scripts/get-kubeconfig.sh:27`

```bash
sed -i "s/127.0.0.1/${SERVER_IP}/g" "$KUBECONFIG_DEST"
```

**问题**: 全量替换 `127.0.0.1`，如果 kubeconfig 中的其他字段（如证书、cluster 名以外的地址）也包含 `127.0.0.1`，会被误替换。且缺少 `SERVER_IP` 为空时的回退。

**修复**:
```bash
# 只替换 server 字段的 127.0.0.1
if [ -n "$SERVER_IP" ]; then
  sed -i "s|server: https://127.0.0.1:6443|server: https://${SERVER_IP}:6443|" "$KUBECONFIG_DEST"
  chmod 600 "$KUBECONFIG_DEST"
else
  log_warn "Could not determine server IP; kubeconfig may need manual fix"
fi
```

---

### MAJ-06: restore playbook 缺少 etcd 成员清理

**文件**: `ansible/playbooks/k3s-restore.yml`

从快照恢复后，旧 etcd 成员仍会留在 etcd 的成员列表中。当启动其他 server 节点时，它们可能试图连接旧成员而非新恢复的节点，导致加入失败。

**修复**: 在恢复完成后添加 etcd 成员清理步骤：
```yaml
- name: List etcd members after restore
  command: k3s etcd member list
  register: member_list
  changed_when: false

- name: Remove non-initial etcd members
  command: k3s etcd member remove {{ item.split(',')[0] }}
  loop: "{{ member_list.stdout_lines[1:] }}"
  when: member_list.stdout_lines | length > 1
```

---

## 4. Minor（优化建议）

### MIN-01: Ansible 模板缺少 trim

**文件**: `ansible/roles/k3s-agent/templates/config.yaml.j2`

```yaml
token: {{ k3s_token }}
```

如果 token 两边有换行或空格，会导致配置格式错误。

**修复**:
```yaml
token: {{ k3s_token | trim }}
```

---

### MIN-02: containerd 模板只有 docker.io 的空认证块

**文件**: `ansible/roles/k3s-common/templates/registries.yaml.j2:10-12`

```yaml
configs:
  "docker.io":
    auth: {}
```

YAML 中的空 `auth: {}` 在 containerd 解析时会生成一个空认证块，可能对某些 registry 配置产生意外行为。

**修复**: 加条件判断，只在有认证信息时才渲染：
```yaml
{% if containerd_mirrors.auth is defined %}
configs:
  ...
{% endif %}
```

---

### MIN-03: log_init 日志轮转有并发竞争

**文件**: `lib/logging.sh:53-65`

```bash
mv "${LOG_FILE}" "${LOG_FILE}.1" 2>/dev/null || true
```

没有文件锁，两个并发的脚本实例同时触发轮转时可能丢日志。

**修复**:
```bash
log_init() {
  (
    flock -x 200
    # ... 原轮转逻辑 ...
  ) 200>"${LOG_DIR}/.rotate.lock"
}
```

---

### MIN-04: 脚本路径依赖 `source` 的调用位置

**文件**: `lib/logging.sh:7`

```bash
PROJECT_DIR="$(cd "${LIB_DIR}/.." && pwd 2>/dev/null || echo '.')"
```

`PROJECT_DIR` 的推断基于 `BASH_SOURCE` 的相对路径，如果 `lib/logging.sh` 被软链接或移动到其他位置导入，路径会出错。

**修复**: 由调用方显式传入项目根路径：
```bash
export PROJECT_DIR="~/k3s-ops"
```

---

### MIN-05: nodes.yml bootstrap_password 字段未在 CLI 中使用

**文件**: `vagrant/nodes.yml:39`

```yaml
addons:
  rancher:
    bootstrap_password: admin
```

`k3s-ops.sh` 和 Ansible playbook 中都没有引用 `addons.rancher.bootstrap_password` 这个变量。Rancher 部署时用的是 Helm 命令中硬编码的 `admin`。

**修复**: 要么统一从 nodes.yml 读取该值并传递，要么从 nodes.yml 中移除该冗余字段。

---

### MIN-06: 缺少 Ansible playbook 的 `--check` 兼容性

大部分 playbook 使用了 `command` 模块（如 `kubectl`, `k3s`），这些模块在 `--check` 模式下不会执行。用户无法通过 `ansible-playbook --check` 预览变更。

**修复**: 在关键步骤（如 backup, remove-node）中添加 `check_mode: no` 并打印警告。

---

## 5. Positive（值得肯定的设计）

### 👍 统一的 CLI 入口

`k3s-ops.sh` 通过子命令模式组织所有操作，`read_nodes_yml()` 用 Python 解析 YAML 避免 bash 的脆弱性。`log_cmd` 包裹命令自动计时 + 记录退出码，提高了可观测性。

---

### 👍 日志库设计完整

`lib/logging.sh` 实现了颜色输出、自动轮转、多级别、命令包裹。`log_cmd` 记录了命令的 PID、耗时、退出码，对运维排错非常有价值。

---

### 👍 配置驱动而非代码驱动

所有集群拓扑在 `nodes.yml` 中定义，Vagrantfile 和 Ansible 都从这里读取，没有把 IP、规格等硬编码在多个地方。这是一个好的 IaC 实践。

---

### 👍 安全使用 `serial: 1`

在集群安装和升级 playbook 中使用 `serial: 1` 避免一次性操作所有节点导致集群不可用，这对于 etcd 集群尤其重要。

---

### 👍 `set -euo pipefail` 全面使用

所有 shell 脚本都启用了严格模式（包括 `k3s-ops.sh`, `scripts/*.sh`, `ansible/files/*.sh`），这在 bash 项目中是良好的安全实践。

---

### 👍 日志文件有自动轮转

10MB 上限 + 5 个归档的轮转策略，避免了日志文件无限膨胀。

---

## 6. Questions（向作者确认）

1. **容灾恢复**: `k3s-restore.yml` 的流程是否在生产环境验证过？特别是"停所有 server → 恢复单节点 → 逐个启动"这个顺序，是否会导致 etcd quorum 问题？

2. **关于 nodes.yml**: `bootstrap_password` 字段当前未被实际使用，是预留字段还是历史遗留？

3. **主机名冲突**: Ansible 通过 `hostname` 模块设置主机名，但 Vagrant 也在 VM 创建时设置了 hostname。两者是否会冲突？

4. **Token 发现**: `k3s_token` 通过 `delegate_to` + `slurp` 从首个 server 获取。在 multi-server HA 场景下，如果首个 server 挂掉，add-node 是否还有 fallback？

5. **特性版本锁定**: addons 中的 Rancher `version: 2.9.x` 和 ingress `version: 4.11.x` 是一种 semver range 表达，但 Ansible 的 `chart_version` 要求精确字符串，这个匹配逻辑是否处理过？

---

## 7. Verdict

**Comment（需要改进后再合并到主线）**

项目整体架构清晰、职责划分合理，`nodes.yml` + CLI 的设计模式适合从单节点到多集群的扩展。但存在几个关键安全问题和健壮性问题（`curl | bash`、二进制无校验、密码硬编码），在对外发布或团队成员协作之前需要修复。

建议优先修复 **CRIT-001 至 CRIT-004**，然后是 **MAJ-01 至 MAJ-06**。修复后项目可以进入 alpha 质量级别，适合个人使用和小团队协作。
