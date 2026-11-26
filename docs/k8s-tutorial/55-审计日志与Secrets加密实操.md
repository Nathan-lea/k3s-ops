# 55 审计日志与 Secrets 加密实操：启用、验证与回滚

## 章节信息

| 项目 | 内容 |
|------|------|
| 适用平台 | Linux / macOS（标准路径）；Windows（ops VM 路径，在 ops VM 内执行 kubectl，节点配置通过 `vagrant ssh`） |
| 前置章节 | 07/12/36/46/50/53 |
| 预计耗时 | 60-120 分钟 |
| 破坏性操作 | **中高**：修改 `/etc/rancher/k3s/config.yaml` 并重启 k3s 会导致 API Server 短暂不可用；secrets encryption 回滚步骤错误可能导致 Secret 解密异常。必须先备份配置、快照/备份关键数据，并在维护窗口执行。 |
| 实测环境 | k3s v1.30.2+k3s2，双节点（server-1 192.168.56.10，agent-1 192.168.56.20），见 [00-README](00-README.md) |

## 本章目标

- 理解 Kubernetes Audit Log 与 k3s secrets encryption 的不同职责。
- 在现有 k3s 集群上实际启用审计日志和 secrets encryption，并验证生效。
- 掌握 secrets encryption 的回滚流程：disable → restart → reencrypt --force --skip → 恢复配置 → restart。
- 形成“验证后可回滚”的实操证据链，避免把实验配置残留在集群里。

> 本章是实操记录，不是生产变更模板。生产环境应结合 K3s 版本、HA 拓扑、审计存储、备份策略和变更审批单独设计。

---

## 1. 两个能力，两个层次

| 能力 | 解决什么问题 | 不解决什么问题 |
|---|---|---|
| **Audit Log** | 记录谁在何时通过 API 做了什么（谁读了 Secret、谁改了 ConfigMap） | 不加密 etcd 数据，不阻止已授权访问 |
| **Secrets Encryption** | 让 Secret 在 etcd 落盘时加密存储（at-rest） | 不阻止有 RBAC 权限的人通过 API 读取 Secret 明文；不等于 Git 加密 |

第 50 章已经说明：Secret 在 API 层默认是 base64 编码，不是加密。本章补的是控制面落盘保护和访问审计。

---

## 2. 实操前准备

```bash
export KUBECONFIG=./kubeconfig
kubectl get nodes -o wide
vagrant ssh k3s-demo-server-1 -c "sudo cp /etc/rancher/k3s/config.yaml /etc/rancher/k3s/config.yaml.bak.ch55"
vagrant ssh k3s-demo-server-1 -c "sudo k3s secrets-encrypt status"
```

实测初始状态：

```text
Encryption Status: Disabled, no configuration file found
```

备份文件：

```text
/etc/rancher/k3s/config.yaml.bak.ch55
```

---

## 3. 启用 Secrets Encryption

### 3.1 写入配置并重启

在 server 配置中加入：

```yaml
secrets-encryption: true
```

重启 k3s：

```bash
vagrant ssh k3s-demo-server-1 -c "sudo systemctl restart k3s"
kubectl --kubeconfig ./kubeconfig get nodes
```

### 3.2 验证状态

```bash
vagrant ssh k3s-demo-server-1 -c "sudo k3s secrets-encrypt status"
```

实测输出：

```text
Encryption Status: Enabled
Current Rotation Stage: start
Server Encryption Hashes: All hashes match

Active  Key Type  Name
------  --------  ----
 *      AES-CBC   aescbckey
```

生成的加密配置：

```bash
vagrant ssh k3s-demo-server-1 -c "sudo head -1 /var/lib/rancher/k3s/server/cred/encryption-config.json"
```

实测可见 `EncryptionConfiguration`、`resources=["secrets"]`、`aescbc` key、以及 `identity` provider。

### 3.3 验证“不是明文落盘”

创建测试 Secret：

```bash
kubectl --kubeconfig ./kubeconfig create ns ch55-audit-demo
kubectl --kubeconfig ./kubeconfig -n ch55-audit-demo create secret generic ch55-secret --from-literal=password='${DEMO_SECRET}'
```

在 etcd 数据库文件中检查：

```bash
vagrant ssh k3s-demo-server-1 -c "sudo grep -a '${DEMO_SECRET}' /var/lib/rancher/k3s/server/db/etcd/member/snap/db | wc -l; sudo grep -a 'ch55-secret' /var/lib/rancher/k3s/server/db/etcd/member/snap/db | wc -l"
```

实测：

```text
0   # 明文密码未命中
1   # Secret 名称/对象元数据仍可在存储中定位
```

这说明：Secret 内容已不再以明文形式直接落在 etcd 快照文件中；但对象本身仍存在，且 API 有权限的用户仍可读取 Secret 明文。

---

## 4. 启用 Audit Log

### 4.1 审计策略

`/var/lib/rancher/k3s/server/audit-policy.yaml`：

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets"]
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["configmaps"]
    namespaces: ["ch55-audit-demo"]
  - level: Metadata
    omitStages:
      - RequestReceived
```

策略意图：Secret 只记 Metadata（避免把 Secret 内容写进审计日志）；demo namespace 的 ConfigMap 记录 RequestResponse，便于验证。

### 4.2 配置 kube-apiserver 参数

在 `/etc/rancher/k3s/config.yaml` 增加：

```yaml
kube-apiserver-arg:
  - "audit-log-path=/var/lib/rancher/k3s/server/logs/audit.log"
  - "audit-log-maxage=1"
  - "audit-log-maxbackup=1"
  - "audit-log-maxsize=10"
  - "audit-policy-file=/var/lib/rancher/k3s/server/audit-policy.yaml"
```

重启 k3s 后检查日志文件：

```bash
vagrant ssh k3s-demo-server-1 -c "sudo ls -l /var/lib/rancher/k3s/server/logs/audit.log"
```

实测看到 audit.log 已生成（约 6.5MB，包含系统组件产生的审计事件）。

### 4.3 验证命中

创建测试 ConfigMap：

```bash
kubectl --kubeconfig ./kubeconfig -n ch55-audit-demo create configmap ch55-audit-cm --from-literal=hello=world
```

在 audit.log 中检索：

```bash
sudo grep 'ch55-audit-cm' /var/lib/rancher/k3s/server/logs/audit.log | tail -n 1 | python3 -m json.tool
```

实测关键字段：

```json
{
  "kind": "Event",
  "level": "RequestResponse",
  "verb": "create",
  "user": {"username": "system:admin"},
  "objectRef": {
    "resource": "configmaps",
    "namespace": "ch55-audit-demo",
    "name": "ch55-audit-cm"
  },
  "responseStatus": {"code": 201},
  "requestObject": {"data": {"hello": "world"}}
}
```

这证明审计策略已生效，并能看到“谁在何时对哪个对象做了什么”。

---

## 5. 回滚：恢复到实验前状态

本章目标是“验证后回滚”。回滚顺序很重要。

### 5.1 关闭 Secrets Encryption

```bash
vagrant ssh k3s-demo-server-1 -c "sudo k3s secrets-encrypt disable"
vagrant ssh k3s-demo-server-1 -c "sudo systemctl restart k3s"
vagrant ssh k3s-demo-server-1 -c "sudo k3s secrets-encrypt status"
```

实测出现中间态：

```text
Encryption Status: Disabled
Current Rotation Stage: reencrypt_active
```

执行强制重加密，确保现有 Secret 使用 identity/禁用加密后的预期状态：

```bash
vagrant ssh k3s-demo-server-1 -c "sudo k3s secrets-encrypt reencrypt --force --skip"
```

等待状态变为：

```text
Encryption Status: Disabled
Current Rotation Stage: start
Server Encryption Hashes: All hashes match
```

> 实测中 API 在重启和 reencryption 期间出现短暂 EOF/connection refused，等待后恢复正常。

### 5.2 恢复原配置

恢复备份配置，移除 `secrets-encryption: true` 和 `kube-apiserver-arg` 审计参数：

```bash
vagrant ssh k3s-demo-server-1 -c "sudo cp /etc/rancher/k3s/config.yaml.bak.ch55 /etc/rancher/k3s/config.yaml"
vagrant ssh k3s-demo-server-1 -c "sudo systemctl restart k3s"
```

### 5.3 清理实验资源

```bash
kubectl --kubeconfig ./kubeconfig delete ns ch55-audit-demo --ignore-not-found
vagrant ssh k3s-demo-server-1 -c "sudo rm -f /var/lib/rancher/k3s/server/audit-policy.yaml /etc/rancher/k3s/config.yaml.bak.ch55; sudo rm -rf /var/lib/rancher/k3s/server/logs"
```

### 5.4 最终验证

回滚后应确认：

- `k3s secrets-encrypt status` 返回 `Encryption Status: Disabled, no configuration file found`（或版本对应的 disabled 状态，且配置已移除）。
- `/etc/rancher/k3s/config.yaml` 恢复为实验前内容，无 audit/secrets-encryption 参数。
- `kubectl get nodes` 全部 Ready。
- `ch55-audit-demo` namespace 已删除。

---

## 6. 常见坑与排障

| 现象 | 原因 | 处理 |
|------|------|------|
| 重启后 API 报 `identity transformer tried to read encrypted data` | 先去掉 `secrets-encryption` 配置重启，但对象仍是加密状态/`encryption-config.json` 残留 | 临时恢复 `secrets-encryption: true` 并重启；执行 `sudo k3s secrets-encrypt reencrypt --force --skip`，确认 `Disabled/start`；再移除配置重启 |
| `k3s secrets-encrypt status` 显示 Disabled，但 `cred/encryption-config.json` 仍存在 | 回滚残留文件 | 确认 status Disabled、集群正常；备份后在维护窗口删除，重启 k3s 验证 nodes Ready 和 Secret 可读 |
| `/var/lib/rancher/k3s/server/logs/audit.log` 无记录 | 策略路径/权限错误、`kube-apiserver-arg` 未生效或未重启 | 检查策略文件与 config.yaml 参数；`systemctl restart k3s`；再执行触发请求 |
| 审计日志记录了 Secret 明文 | secrets 规则用了 `Request`/`RequestResponse` | secrets 规则固定 `Metadata`；轮转/清理受影响日志，评估泄露范围并轮换 Secret |

## 7. 动手练习

1. **策略最小化**：写一个只记录 `kube-system` 中 Secret `get/list/watch` Metadata 事件的 Audit Policy，并说明为什么不能记录 Request body。
2. **回滚演练（沙箱）**：复现“未 reencrypt 完成就移除 secrets-encryption 配置”的故障，按正确顺序恢复并记录验收命令。
3. **Runbook 证据**：为 36 章补一条“Secret 异常访问”场景，给出 audit log grep 命令，并标注哪些字段必须脱敏。

## 8. 清理

> 本章已包含回滚；清理以“无实验残留、集群恢复基线”为准。

```bash
# 删除实验 namespace（如仍存在）
kubectl --kubeconfig ./kubeconfig delete ns ch55-audit-demo --ignore-not-found

# server 节点清理实验文件（确认不再需要）
vagrant ssh k3s-demo-server-1 -c "sudo rm -f /var/lib/rancher/k3s/server/audit-policy.yaml /etc/rancher/k3s/config.yaml.bak.ch55 && sudo rm -rf /var/lib/rancher/k3s/server/logs && sudo mkdir -p /var/lib/rancher/k3s/server/logs"

# 确认 config.yaml 无实验参数
vagrant ssh k3s-demo-server-1 -c "sudo grep -n 'secrets-encryption\|audit-log\|audit-policy' /etc/rancher/k3s/config.yaml || echo no-audit-secrets-config"

# 最终验证
kubectl --kubeconfig ./kubeconfig get nodes
vagrant ssh k3s-demo-server-1 -c "sudo k3s secrets-encrypt status 2>&1 | tail -5"
```

若存在回滚遗留备份（如 server-1 root 用户家目录下的 `encryption-config.json.bak.ch55`），观察一段时间无异常后再删除；删除前确认 status 为 Disabled 且重启验证通过。

## 9. 小结

- Audit Log 回答“谁做了什么”；Secrets Encryption 回答“etcd 落盘是否加密”。
- 在 k3s v1.30.2+k3s2 单 server 实测中，启用 `secrets-encryption: true` 并重启后可看到加密配置和 `Enabled` 状态；测试 Secret 明文未在 etcd db 文件中命中。
- Audit policy + kube-apiserver-arg 可快速启用审计日志；策略应避免记录 Secret 明文。
- 回滚必须包含 disable、reencrypt、恢复配置、重启、清理和最终验证。

## 参考

- [K3s Secrets Encryption](https://docs.k3s.io/security/secrets-encryption)
- [K3s secrets-encrypt CLI](https://docs.k3s.io/cli/secrets-encrypt)
- [Kubernetes Auditing](https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/)
- [Kubernetes Encrypting Confidential Data at Rest](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/)
