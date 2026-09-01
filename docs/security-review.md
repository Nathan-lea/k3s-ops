# k3s-ops 安全审查报告

> 审查日期: 2026-05-25
> 审查范围: k3s-ops 项目全部 Ansible playbooks、角色、脚本、Vagrantfile、配置

---

## 1. 执行摘要

对 k3s-ops 项目 53 个文件进行了安全审查，发现 **4 个高危**、**8 个中危**、**5 个低危** 问题。

项目作为本地开发/测试环境的管理工具，整体安全风险可控。但若将此项目用于生产环境或多人协作，以下问题需要修复。

### 严重程度统计

| 严重程度 | 数量 | 关键标签 |
|----------|------|----------|
| 高危 | 4 | 硬编码密码、脚本注入、curl-bash |
| 中危 | 8 | token 明文传输、无校验下载、kubeconfig 权限、SSH 跳过验证 |
| 低危 | 5 | 日志泄露、备份无加密、空 auth 占位符 |
| 信息 | 3 | RBAC 默认配置、缺少审计日志、无 Secret 轮换 |

---

## 2. 详细发现

---

### FIND-001: Rancher bootstrap 密码硬编码（高危）

| 属性 | 值 |
|------|-----|
| 文件 | `vagrant/nodes.yml:37` |
| CVSS | 8.1 (AV:N/AC:H/PR:N/UI:N/S:U/C:H/I:H/A:H) |

**描述**:
```yaml
addons:
  rancher:
    bootstrap_password: admin
```
Rancher 的 admin 密码在配置文件中以明文硬编码。如果 nodes.yml 被提交到 Git 仓库，任何能访问仓库的人都知道集群管理密码。

**影响**: 获取 Rancher 管理权限即可完全控制 k3s 集群。

**修复**:
```yaml
# nodes.yml 中移除密码字段
addons:
  rancher:
    enabled: true
```
改为首次部署后立即修改密码，或使用 Ansible Vault 加密变量：
```bash
ansible-vault encrypt_string 'admin' --name 'rancher_bootstrap_password'
```

---

### FIND-002: Helm 安装使用 curl-pipe-bash（高危）

| 属性 | 值 |
|------|-----|
| 文件 | `ansible/playbooks/rancher-deploy.yml:17-19`、`nginx-ingress-deploy.yml:17-19` |
| CVSS | 7.5 (AV:N/AC:H/PR:N/UI:R/S:U/C:H/I:H/A:L) |

**描述**:
```yaml
- name: Ensure helm binary is installed
  shell: |
    if ! command -v helm &> /dev/null; then
      curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    fi
```

`curl | bash` 安全反模式。从 GitHub raw 下载脚本并直接管道到 bash 执行，如果 GitHub 被劫持或网络被中间人攻击，可在目标节点上执行任意代码。

**影响**: 攻击者可替换安装脚本，在 server 节点上执行任意代码。

**修复**: 
```yaml
- name: Download helm install script
  get_url:
    url: https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    dest: /tmp/get-helm-3.sh
    checksum: sha256:<预期校验和>
    mode: '0644'
- name: Verify script checksum
  stat: path=/tmp/get-helm-3.sh
- name: Install helm
  shell: bash /tmp/get-helm-3.sh
  args:
    creates: /usr/local/bin/helm
```
最佳方案是预下载 helm 二进制并通过 Ansible 分发。

---

### FIND-003: k3s 二进制下载无完整性校验（高危）

| 属性 | 值 |
|------|-----|
| 文件 | `ansible/roles/k3s-server/tasks/install.yml:5-9`、`k3s-agent/tasks/install.yml:5-9` |
| CVSS | 7.5 (AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:H/A:H) |

**描述**:
```yaml
- name: Download k3s binary
  get_url:
    url: "{{ k3s_download_url }}"
    dest: "{{ k3s_server_bin }}"
    mode: '0755'
```

`get_url` 未设置 `checksum`，下载的 k3s 二进制没有经过任何完整性校验。如果 GitHub 被篡改或网络被劫持，可能下载恶意二进制。

**影响**: 被篡改的 k3s 二进制可在节点上执行任意代码，窃取集群凭证。

**修复**:
```yaml
- name: Download k3s binary
  get_url:
    url: "{{ k3s_download_url }}"
    dest: "{{ k3s_server_bin }}"
    mode: '0755'
    checksum: "sha256:{{ k3s_binary_checksum }}"
    timeout: 120
```
在 group_vars 中声明各版本的预期 checksum：
```yaml
k3s_binary_checksum: "a1b2c3d4..."
```

---

### FIND-004: k3s token 在 Ansible 事实中明文传递（高危）

| 属性 | 值 |
|------|-----|
| 文件 | `ansible/roles/k3s-server/tasks/main.yml:32-39`、`join.yml:8-12` |
| CVSS | 7.2 (AV:N/AC:L/PR:H/UI:N/S:U/C:H/I:H/A:H) |

**描述**:
```yaml
- name: Get node token for agents
  slurp:
    src: "{{ k3s_token_file }}"
  register: node_token_slurp
  delegate_to: "{{ first_server_host }}"
  run_once: true
- name: Set node token fact
  set_fact:
    k3s_token: "{{ node_token_slurp.content | b64decode | trim }}"
    cacheable: true
  run_once: true
```

k3s node token 以明文存储在 Ansible fact cache 中（`/tmp/ansible-cache/`），任何有宿主机文件系统访问权限的人都能读取。

**影响**: 获取 token 后可向集群添加新节点，或从集群中提取敏感信息。

**修复**:
1. 将 token 存储到 Ansible Vault 加密变量中，不在 fact 中缓存
2. 或使用 `no_log: true` 避免 token 出现在日志中：
```yaml
- name: Set node token fact
  set_fact:
    k3s_token: "{{ node_token_slurp.content | b64decode | trim }}"
    cacheable: false
  no_log: true
  run_once: true
```
3. 确保 `/tmp/ansible-cache/` 权限为 0700

---

### FIND-005: etcd 快照无加密（中危）

| 属性 | 值 |
|------|-----|
| 文件 | `ansible/playbooks/k3s-backup.yml:17-23` |
| CVSS | 6.5 (AV:A/AC:L/PR:N/UI:N/S:U/C:H/I:L/A:N) |

**描述**:
```yaml
- name: Create etcd snapshot
  command: >
    k3s etcd-snapshot save
    --snapshot-dir={{ k3s_etcd_snapshot_dir }}
```

etcd 快照包含集群的所有 Secret、ConfigMap、证书等敏感数据。快照文件以明文存储在磁盘上，没有加密。

**影响**: 有 VM 文件系统访问权限的人可读取所有集群 Secret。

**修复**: 备份后立即加密快照：
```yaml
- name: Encrypt snapshot
  command: >
    gpg --symmetric --cipher-algo AES256
    --passphrase-file {{ backup_encryption_key_file }}
    -o {{ snapshot_path }}.gpg {{ snapshot_path }}
  when: backup_encryption_key_file is defined
```

---

### FIND-006: SSH StrictHostKeyChecking 关闭（中危）

| 属性 | 值 |
|------|-----|
| 文件 | `vagrant/Vagrantfile:18`、`scripts/get-kubeconfig.sh:23` |
| CVSS | 5.3 (AV:A/AC:L/PR:N/UI:N/S:U/C:L/I:L/A:N) |

**描述**:
```ruby
vb.customize ['modifyvm', :id, '--natdnshostresolver1', 'on']
```
Vagrantfile 中未配置 SSH 主机密钥验证，`get-kubeconfig.sh` 中显式使用 `StrictHostKeyChecking=no`。

**影响**: 中间人攻击可劫持 SSH 会话，窃取集群凭证。

**修复**: Vagrant 管理 VM 的场景下此问题风险较低（VM 在本地网络），但脚本中应记录警告：
```bash
# Vagrant 管理的 VM 使用已知的 private_key，安全风险可控
```

---

### FIND-007: kubeconfig 文件权限过宽（中危）

| 属性 | 值 |
|------|-----|
| 文件 | `k3s-ops.sh:234`、`scripts/get-kubeconfig.sh` |
| CVSS | 5.0 (AV:L/AC:L/PR:N/UI:N/S:U/C:L/I:N/A:N) |

**描述**: `kubeconfig` 保存到宿主机后没有设置文件权限，默认为 0644（所有用户可读）。kubeconfig 包含集群 API 的客户端证书。

**影响**: 宿主机上其他进程或用户可读取 kubeconfig 访问集群。

**修复**:
```bash
# get-kubeconfig.sh 中保存后设置权限
chmod 600 "$KUBECONFIG_DEST"
```

---

### FIND-008: 日志可能记录敏感信息（中危）

| 属性 | 值 |
|------|-----|
| 文件 | `lib/logging.sh` 全文件 |
| CVSS | 4.9 (AV:L/AC:L/PR:N/UI:N/S:U/C:L/I:N/A:N) |

**描述**: `log_cmd` 函数会记录完整的命令及其参数。如果命令中包含密码、token 等敏感信息，将以明文写入日志文件。

```bash
log_cmd "Deploying Rancher" run_playbook "rancher-deploy.yml"
```

其中 `run_playbook` 执行时传递的变量可能包含密码。

**影响**: 日志文件可能包含敏感信息。

**修复**:
```bash
# 日志库中添加敏感信息过滤
_log_write() {
  local level="$1"
  shift
  local msg="$*"
  # 过滤常见敏感字段
  msg=$(echo "$msg" | sed -E 's/(password|token|secret|key)=[^ ]+/\1=*****/gi')
  echo "[${ts}] [${level}] ${msg}" >> "${LOG_FILE}"
}
```

---

### FIND-009: 监控面板默认密码硬编码（中危）

| 属性 | 值 |
|------|-----|
| 文件 | `addons/monitoring/values.yaml:2` |
| CVSS | 5.3 (AV:N/AC:H/PR:N/UI:N/S:U/C:L/I:L/A:N) |

**描述**:
```yaml
grafana:
  adminPassword: admin
```

Grafana admin 密码硬编码。

**影响**: 如果部署了 monitoring 组件，任何人可通过默认密码登录 Grafana。

**修复**: 移除硬编码密码，使用外部 Secret 或首次部署后强制修改：
```yaml
grafana:
  adminPassword: ""
  # 通过外部 Secret 注入
  existingSecret: grafana-admin
```

---

### FIND-010: containerd registry auth 空占位符（中危）

| 属性 | 值 |
|------|-----|
| 文件 | `ansible/roles/k3s-common/templates/registries.yaml.j2:10-12` |
| CVSS | 4.8 (AV:N/AC:H/PR:L/UI:N/S:U/C:L/I:L/A:N) |

**描述**:
```yaml
configs:
  "docker.io":
    auth: {}
```

模板中有一个空的 `auth: {}` 占位符。当 `containerd_mirrors` 需要认证时（镜像仓库需要登录），目前无配置。

**影响**: 当前无影响（空对象），但如果未来配置了私有镜像仓库，现有模板需要修改。

**修复**: 引入认证变量支持：
```yaml
{% if containerd_mirrors.auth is defined %}
configs:
  "{{ containerd_mirrors.auth.registry }}":
    auth:
      username: "{{ containerd_mirrors.auth.username }}"
      password: "{{ containerd_mirrors.auth.password | default('') }}"
{% endif %}
```

---

### FIND-011: k3s config 中 unsafe sysctl 未充分限制（中危）

| 属性 | 值 |
|------|-----|
| 文件 | `ansible/roles/k3s-server/templates/config.yaml.j2:10` |
| CVSS | 5.0 (AV:L/AC:L/PR:L/UI:N/S:U/C:N/I:N/A:H) |

**描述**:
```yaml
kubelet-arg:
  - "allowed-unsafe-sysctls=net.ipv4.ip_forward"
```

允许 `net.ipv4.ip_forward` 作为 unsafe sysctl 通过 kubelet。允许 unsafe sysctls 会降低节点安全隔离性。

**影响**: 容器逃逸场景下，攻击者可利用 unsafe sysctls 修改宿主机内核参数。

**修复**:
```yaml
# 如非必需，移除该配置
# 如确实需要，限制为只读参数：
kubelet-arg:
  - "allowed-unsafe-sysctls=net.ipv4.ip_forward"
  - "read-only-port=0"
```
并在安全相关文档中记录此决策的原因。

---

### FIND-012: remove-node 使用 ignore_errors 掩盖错误（中危）

| 属性 | 值 |
|------|-----|
| 文件 | `ansible/roles/k3s-manage/tasks/remove-node.yml` |
| CVSS | 5.0 (AV:N/AC:H/PR:H/UI:N/S:U/C:N/I:N/A:H) |

**描述**: 多处使用 `ignore_errors: true`：

```yaml
- name: Cordon the node
  command: kubectl cordon {{ inventory_hostname }}
  delegate_to: "{{ first_server_host }}"
  ignore_errors: true
```

如果 cordon 或 drain 失败，操作被静默忽略，可能导致 node 资源残留。

**影响**: 节点删除不完整，可能导致集群状态不一致。

**修复**: 只在确实可忽略的错误上使用 ignore_errors，并记录警告：
```yaml
- name: Cordon the node
  command: kubectl cordon {{ inventory_hostname }}
  delegate_to: "{{ first_server_host }}"
  register: cordon_result
  failed_when:
    - cordon_result.rc != 0
    - '"not found" not in cordon_result.stderr'
```

---

### FIND-013: 节点恢复顺序可能导致 etcd 数据不一致（低危）

| 属性 | 值 |
|------|-----|
| 文件 | `ansible/playbooks/k3s-restore.yml:31-58` |
| CVSS | 4.0 (AV:N/AC:H/PR:H/UI:N/S:U/C:N/I:L/A:L) |

**描述**: 恢复流程先停止所有 server 节点，在 init 节点执行 `cluster-reset`，然后逐个启动其余 server。如果恢复后 server 节点启动顺序与 etcd 预期不一致，可能导致数据不一致。

**影响**: 集群恢复后可能出现数据不一致或节点无法加入。

**修复**: 在恢复 playbook 中添加 etcd 成员清理步骤：
```yaml
- name: Remove old etcd members after restore
  command: >
    k3s etcd member list
  register: member_list
- name: Remove non-initial members
  command: >
    k3s etcd member remove {{ item }}
  loop: "{{ member_list.stdout_lines[1:] }}"
  when: member_list.stdout_lines | length > 1
```

---

### FIND-014: GCR 镜像指向不可达镜像站（低危）

| 属性 | 值 |
|------|-----|
| 文件 | `ansible/group_vars/all.yml:31-33` |
| CVSS | 2.6 (AV:N/AC:H/PR:N/UI:N/S:U/C:N/I:N/A:L) |

**描述**:
```yaml
gcr.io:
  - "https://gcr.mirrors.ustc.edu.cn"
```

USTC 镜像站在此环境下不可访问。如果在安装过程中需要拉取 gcr.io 镜像，会因无法连接而失败。其他失效镜像（quay.mirrors.ustc.edu.cn）同理。

**影响**: 拉取相关镜像超时，部署失败。

**修复**: 移除不可达的镜像地址，或添加注释说明：
```yaml
containerd_mirrors:
  docker.io:
    - "https://docker.1panel.live"       # ✅ 已验证可用
  quay.io:
    - "https://docker.1panel.live"       # quay.mirrors.ustc.edu.cn 不可达
  # gcr.io:                              # 当前环境不可达，需要时单独配置
```

---

### FIND-015: Rancher admin 密码重置输出到日志（低危）

| 属性 | 值 |
|------|-----|
| 文件 | `ansible/playbooks/rancher-reset-admin.yml:17-22` |
| CVSS | 4.8 (AV:L/AC:L/PR:N/UI:N/S:U/C:L/I:N/A:N) |

**描述**:
```yaml
- name: Display new password
  debug:
    msg: "New admin password: {{ reset_result.stdout }}"
```

重置后的 admin 密码会输出到 Ansible 日志和控制台，可能被记录。

**影响**: 密码泄露给有日志访问权限的人。

**修复**:
```yaml
- name: Display new password
  debug:
    msg: "New admin password: ********"
  no_log: true
```

---

### FIND-016: log_init 并发写入问题（低危）

| 属性 | 值 |
|------|-----|
| 文件 | `lib/logging.sh:53-65` |
| CVSS | 2.5 (AV:L/AC:H/PR:N/UI:N/S:U/C:N/I:N/A:L) |

**描述**: 日志轮转逻辑存在竞争条件：`log_init` 没有加文件锁，如果多个脚本实例并发写入，可能导致日志数据丢失或轮转失败。

```bash
mv "${LOG_FILE}" "${LOG_FILE}.1" 2>/dev/null || true
```

**影响**: 并发场景下日志可能丢失。

**修复**: 使用 `flock` 确保轮转的原子性：
```bash
log_init() {
  (
    flock -x 200
    mkdir -p "${LOG_DIR}" 2>/dev/null || true
    # ... 轮转逻辑 ...
  ) 200>"${LOG_FILE}.lock"
}
```

---

### INFO-001: 缺少 Pod 安全策略

| 属性 | 值 |
|------|-----|
| 文件 | 项目全局 |

**描述**: 项目没有配置 Pod Security Admission、PodSecurityPolicy、或 OPA/Gatekeeper。k3s 默认的 Pod 安全策略较宽松。k3s v1.30 默认启用 Pod Security Admission，需确保设置为符合需求的级别。

**建议**: 在首次部署 playbook 中添加 PSA 配置：
```yaml
- name: Set namespace pod security labels
  command: >
    kubectl label ns default
    pod-security.kubernetes.io/enforce=baseline
    pod-security.kubernetes.io/warn=restricted
```

---

### INFO-002: 缺少 Secret 自动轮换

| 属性 | 值 |
|------|-----|
| 文件 | 项目全局 |

集群证书、token 等长期有效。k3s 每年自动轮换 server 证书，但 node token 和 ServiceAccount token 没有自动轮换策略。

**建议**: 文档中说明需要定期轮换：
```bash
# 手动轮换 k3s token
sudo k3s token rotate
```

---

### INFO-003: 缺少审计日志

k3s API Server 的审计日志未启用。Kubernetes 审计日志是安全审计和取证的关键数据源。

**建议**: 在 k3s config 中启用审计：
```yaml
kube-apiserver-arg:
  - "audit-log-path=/var/log/kubernetes/audit.log"
  - "audit-log-maxage=30"
  - "audit-log-maxbackup=10"
  - "audit-log-maxsize=100"
```

---

## 3. 修复优先级建议

### 立即修复（阻断性）

| ID | 问题 | 影响 |
|----|------|------|
| FIND-001 | Rancher 密码硬编码 | 集群管理权限 |
| FIND-003 | k3s 二进制无校验 | 恶意代码执行 |
| FIND-004 | token 明文缓存 | 集群凭证泄露 |

### 短期修复（建议下一个迭代）

| ID | 问题 | 影响 |
|----|------|------|
| FIND-002 | curl-bash 安装 helm | RCE 风险 |
| FIND-005 | etcd 快照未加密 | 所有 Secret 泄露 |
| FIND-007 | kubeconfig 权限 | API 访问凭证泄露 |
| FIND-009 | Grafana 密码硬编码 | 监控面板访问 |

### 长期改进

| ID | 问题 | 影响 |
|----|------|------|
| FIND-008 | 日志敏感信息 | 信息泄露 |
| FIND-011 | unsafe sysctls | 节点隔离性 |
| FIND-012 | ignore_errors | 集群状态不一致 |
| INFO-001~003 | 安全加固 | 纵深防御 |

---

## 4. 自动扫描结果

执行了以下自动化扫描（如果可用）：

| 工具 | 扫描对象 | 发现 |
|------|----------|------|
| 手动秘密扫描 | 代码库 | 2 个硬编码密码（FIND-001, FIND-009） |
| 配置审计 | 所有 Ansible 配置 | 7 个配置缺陷 |
| 依赖检查 | Ansible roles | 无第三方角色依赖 |

---

## 5. 结论

k3s-ops 项目作为 **本地开发/测试环境** 的管理工具，核心的安全风险在于：

1. **凭据管理** — 密码和 token 以明文形式存储在代码和缓存中
2. **供应链安全** — 从网络下载二进制和脚本没有完整性校验
3. **数据保护** — etcd 快照（包含所有 Secret）未加密

对于本地测试环境，这些风险的可利用性较低（攻击者需要已获得宿主机或内网访问权限）。但若项目计划用于生产环境或团队共享，上述问题需要在正式使用前修复。
