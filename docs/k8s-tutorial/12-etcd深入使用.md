# 12 etcd 深入使用：读取 / 查看 / 备份 / 恢复

## 本章目标

- 理解 etcd 在集群中的地位：唯一的状态存储，所有资源（含 Secret）都在这
- 掌握连接嵌入式 etcd 的方法（证书 + etcdctl）
- 学会用 etcdctl 读取键值、查看集群状态、做日常维护
- 掌握 k3s 的备份（快照）与恢复（cluster-reset）完整流程

> 前置：建议先完成第 08 章（监控与备份，已讲快照基础）。本章在其上深入 etcdctl 与恢复演练。
> 注意：本集群是 k3s **嵌入式 etcd**（单节点模式）。标准 K8s（独立 etcd 集群）连接方式思路相同，路径/服务名不同。

---

## 1. etcd 是什么

etcd 是**分布式强一致的 key-value 数据库**，K8s 把它当作「大脑的记忆」：

- 存什么：所有 API 对象的**期望状态 + 实际状态**（Pod、Deployment、Service、Secret、ConfigMap、RBAC……）
- 谁读写：**只有 kube-apiserver** 能访问 etcd；其他组件一律经 apiserver
- 为什么重要：**etcd 没了 = 集群失忆**。节点磁盘坏了可以重建，etcd 数据丢了集群配置全部丢失
- 术语：key-value 按 `/registry/<资源类型>/<ns>/<名字>` 分层；采用 **v3 API**

k3s 的特殊性：etcd 编译进 `k3s-server` 进程（嵌入式），数据目录 `/var/lib/rancher/k3s/server/db/etcd`，监听 2379（客户端）/2380（成员通信）。

## 2. 连接嵌入式 etcd

新版 k3s **不再内置 etcdctl**（v1.30 起），但节点可用 apt 安装：

```bash
vagrant ssh k3s-demo-server-1 -- "sudo apt-get install -y etcd-client"
```

验证：`/usr/bin/etcdctl`

连接需要三样东西：

| 项 | 路径（本集群） |
|----|---------------|
| CA 证书 | `/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt` |
| 客户端证书 | `/var/lib/rancher/k3s/server/tls/etcd/client.crt` |
| 客户端私钥 | `/var/lib/rancher/k3s/server/tls/etcd/client.key` |

**连接参数即三样证书 + 端点**。为简洁，在宿主机定义一个变量 `ETCD_ARGS`，后面所有命令都基于它（命令用双引号传给 `vagrant ssh`，变量会在宿主机展开）：

```bash
ETCD_ARGS="--cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt \
--cert=/var/lib/rancher/k3s/server/tls/etcd/client.crt \
--key=/var/lib/rancher/k3s/server/tls/etcd/client.key \
--endpoints=https://127.0.0.1:2379"
```

> 证书验证：`client.crt` / `client.key` 是 k3s 为 api-server↔etcd 通信签发的客户端凭证，etcdctl 复用同一套即可（`server-ca.crt` 是签发 CA）。命令统一形态：`vagrant ssh k3s-demo-server-1 -- "sudo ETCDCTL_API=3 etcdctl $ETCD_ARGS <子命令>"`。

## 3. 本集群实站对照

### 3.1 健康检查与版本

```bash
vagrant ssh k3s-demo-server-1 -- "sudo ETCDCTL_API=3 etcdctl $ETCD_ARGS endpoint health -w table 2>&1 | grep -v '^{'"
```

预期输出（真实）：

```text
https://127.0.0.1:2379 is healthy: successfully committed proposal: took = 5.869006ms
```

`endpoint health` 每 50 秒自动重试，健康即输出此消息。**这是判断 etcd 可用的第一命令**。

### 3.2 端点状态（版本 / 库大小 / 谁是 leader）

```bash
vagrant ssh k3s-demo-server-1 -- "sudo ETCDCTL_API=3 etcdctl $ETCD_ARGS endpoint status -w table"
```

预期输出（真实）：

```text
+------------------------+------------------+---------+---------+-----------+-----------+------------+
|        ENDPOINT        |        ID        | VERSION | DB SIZE | IS LEADER | RAFT TERM | RAFT INDEX |
+------------------------+------------------+---------+---------+-----------+-----------+------------+
| https://127.0.0.1:2379 | f0e4577804b51494 |  3.5.13 |   16 MB |      true |        21 |     330600 |
+------------------------+------------------+---------+---------+-----------+-----------+------------+
```

字段解读：

- **VERSION 3.5.13**：本集群 etcd 实际版本（k3s v1.30.2 内置）
- **DB SIZE 16 MB**：etcd 数据文件大小
- **IS LEADER true**：单节点必然是自己（HA 多节点时看谁是主）
- **RAFT TERM / INDEX**：Raft 共识协议术语（任期/日志索引），读者知道含义即可，运维时看是否有异常增长

### 3.3 成员信息

```bash
vagrant ssh k3s-demo-server-1 -- "sudo ETCDCTL_API=3 etcdctl $ETCD_ARGS member list -w table"
```

预期输出（真实，单节点 HA 需要扩容 server 才有多个成员）：

```text
+------------------+---------+----------------------------+----------------------------+----------------------------+
|        ID        | STATUS  |            NAME            |         PEER ADDRS         |        CLIENT ADDRS        |
+------------------+---------+----------------------------+----------------------------+----------------------------+
| f0e4577804b51494 | started | k3s-demo-server-1-18472064 | https://192.168.56.10:2380 | https://192.168.56.10:2379 |
+------------------+---------+----------------------------+----------------------------+----------------------------+
```

- 成员名 = `节点名-随机后缀`，由 k3s 生成
- **PEER ADDRS 2380**：成员之间通信端口（HA 时用到）
- **CLIENT ADDRS 2379**：客户端（apiserver/etcdctl）连接端口

### 3.4 读取键值：总览 /registry

```bash
vagrant ssh k3s-demo-server-1 -- "sudo ETCDCTL_API=3 etcdctl $ETCD_ARGS get /registry --prefix --keys-only 2>/dev/null | awk -F/ '{print \"/\"\$2}' | sort -u"
```

预期输出（根前缀，真实）：

```text
/
/bootstrap
/registry
```

集群资源都挂在 `/registry` 下，看有哪些资源类型：

```bash
vagrant ssh k3s-demo-server-1 -- "sudo ETCDCTL_API=3 etcdctl $ETCD_ARGS get /registry --prefix --keys-only 2>/dev/null | awk -F/ '{print \"/registry/\"\$3}' | sort -u | head -25"
```

预期输出（真实截选，前 25 个）：

```text
/registry/
/registry/apiextensions.k8s.io
/registry/apiregistration.k8s.io
/registry/catalog.cattle.io
/registry/cert-manager.io
/registry/clusterrolebindings
/registry/clusterroles
/registry/configmaps
/registry/cronjobs
/registry/deployments
/registry/endpointslices
/registry/events
/registry/flowschemas
/registry/horizontalpodautoscalers
/registry/ingress
/registry/ingressclasses
/registry/jobs
/registry/k3s.cattle.io
```

> 你会看到 `catalog.cattle.io`、`fleet.cattle.io` 等 Rancher 的 CRD —— 说明 **Rancher 的资源也存同一个 etcd**。这就是「整集群状态都在 etcd」的含义。

### 3.5 读取具体资源

```bash
# 列出 lab 命名空间的所有 Pod 键
vagrant ssh k3s-demo-server-1 -- "sudo ETCDCTL_API=3 etcdctl $ETCD_ARGS get /registry/pods/lab --prefix --keys-only 2>/dev/null | grep nginx-demo"
```

预期输出（真实）：

```text
/registry/pods/lab/nginx-demo-559f959666-59frr
/registry/pods/lab/nginx-demo-559f959666-kv4nv
/registry/pods/lab/nginx-demo-559f959666-pw68t
/registry/pods/lab/nginx-demo-559f959666-thbhv
```

```bash
# 读取一个 Service 的完整值
vagrant ssh k3s-demo-server-1 -- "sudo ETCDCTL_API=3 etcdctl $ETCD_ARGS get /registry/services/specs/lab/nginx-svc 2>/dev/null | head -c 400"
```

预期输出（真实，存储的是 **protobuf 二进制**，键名可读、值含 namespace/uid/注解等字段）：

```text
<空行=签名, 键名>
nginx-svc<...二进制...>lab"`$1226dd25-6a65-4392-892e-c0ccfabd6d652...
field.cattle.io/publicEndpoints [{"port":32062,"protocol":"TCP","serviceName":"lab:nginx-svc","allNodes":true}]
kubectl-expose  Update  v1 ...
```

**重要认知**：etcd 里的值大多是 protobuf 二进制，**不适合人类直接修改**。日常读资源用 kubectl（apiserver 翻译成人话），etcdctl 的价值在于：
1. 验证「kubectl 看到的就是 etcd 存的」
2. 数据恢复/迁移/审计
3. 排查「apiserver 缓存 vs 存储不一致」类问题

### 3.6 核对：kubectl 与 etcd 的一致性

```bash
kubectl -n lab get svc nginx-svc   # 与 3.5 的 etcd 值对照(ClusterIP/端口/selector 一致)
```

结论：`kubectl` 是 etcd 内容的「格式化输出接口」，两者必然一致 —— 这也是为什么「备份 etcd = 备份集群配置」。

### 3.7 日常维护命令

```bash
# 告警检查（无输出 = 无告警）
vagrant ssh k3s-demo-server-1 -- "sudo ETCDCTL_API=3 etcdctl $ETCD_ARGS alarm list"

# 压缩历史版本（DB 瘦身；对已 compact 的旧 revision 会报错——见下）
# 第 1 步：取当前 revision（输出 JSON，从中提取 revision 字段）
vagrant ssh k3s-demo-server-1 -- "sudo ETCDCTL_API=3 etcdctl $ETCD_ARGS endpoint status -w json 2>/dev/null | grep -oE '\"revision\":[0-9]+' | grep -oE '[0-9]+$'"
# 第 2 步：把第 1 步拿到的数字填进 compact（这里示例用 317165）
vagrant ssh k3s-demo-server-1 -- "sudo ETCDCTL_API=3 etcdctl $ETCD_ARGS compact 317165"
```

真实输出（同一次运行内取 revision 再压缩，数字自洽；集群持续写入时 revision 会略增）：

```text
317165
compacted revision 317165
```

**试错教学**：对 revision 0 执行 compact 会得到（真实报错）：

```text
{"level":"warn",... "error":"rpc error: code = OutOfRange desc = etcdserver: mvcc: required revision has been compacted"}
Error: etcdserver: mvcc: required revision has been compacted
```

含义：etcd 只保留当前版本及其后的历史，`revision 0` 太老已被压缩 —— 这解释了「为什么不建议手动乱 compact」。

### 3.8 数据目录一览

```bash
vagrant ssh k3s-demo-server-1 -- "sudo ls /var/lib/rancher/k3s/server/db/etcd/ && echo '---member---' && sudo ls /var/lib/rancher/k3s/server/db/etcd/member/"
```

预期输出：

```text
config
member
name                     ← 集群标识
---member---
snap                      ← Raft 快照（运行时状态）
wal                       ← 预写日志（WAL，崩溃恢复用）
```

## 4. 备份（快照）

> 完整原理与自动化见第 08 章；这里补真实命令细节。

```bash
# 手动快照
vagrant ssh k3s-demo-server-1 -- "sudo k3s etcd-snapshot save --name chapter12-demo 2>&1 | grep -v '^time='"
```

真实输出（截取关键行；前面的 `time=...` 是运行日志）：

```text
time="2026-10-04T01:28:02Z" level=warning msg="Unknown flag --kubelet-arg found in config.yaml, skipping\n"
time="2026-10-04T01:28:02Z" level=warning msg="Unknown flag --etcd-expose-metrics found in config.yaml, skipping\n"
time="2026-10-04T01:28:02Z" level=warning msg="Unknown flag --cluster-init found in config.yaml, skipping\n"
time="2026-10-04T01:28:02Z" level=warning msg="Unknown flag --flannel-iface found in config.yaml, skipping\n"
time="2026-10-04T01:28:02Z" level=info msg="Snapshot chapter12-demo-k3s-demo-server-1-1791077283 saved."
```

> 教学点：那些 `Unknown flag ... skipping` 是**无害噪音** —— k3s 的配置文件（`/etc/rancher/k3s/config.yaml`）里有些参数只对 `k3s server` 主进程生效，快照子命令不识别它们，直接跳过，不影响快照本身。看到 warning 不必慌，认准最后一行 `Snapshot ... saved.` 即可。

查看快照列表：

```bash
vagrant ssh k3s-demo-server-1 -- "sudo k3s etcd-snapshot list 2>/dev/null | grep -v '^time='"
```

真实输出：

```text
Name                                        Location                                                                                    Size     Created
manual-demo-k3s-demo-server-1-1790989734    file:///var/lib/rancher/k3s/server/db/snapshots/manual-demo-k3s-demo-server-1-1790989734    17469472 2026-10-03T01:08:54Z
chapter12-demo-k3s-demo-server-1-1791077283 file:///var/lib/rancher/k3s/server/db/snapshots/chapter12-demo-k3s-demo-server-1-1791077283 16990240 2026-10-04T01:28:03Z
```

快照文件即 etcd 数据的一致副本，位于 `/var/lib/rancher/k3s/server/db/snapshots/`（约 17MB）。**重要**：快照默认留在节点本机，异地容灾需拷走（scp / 对象存储）。

```bash
# 其他管理子命令（k3s etcd-snapshot --help 均支持）
sudo k3s etcd-snapshot delete <name>   # 删除
sudo k3s etcd-snapshot prune          # 按保留策略清理超量快照
sudo k3s etcd-snapshot list
```

## 5. 恢复（cluster-reset，破坏性）

恢复 = **用快照重建 etcd 并重启 k3s**。流程（在 server 节点执行，必须停机窗口）：

```bash
sudo systemctl stop k3s                     # 1. 停 k3s

# 2. 用快照恢复（把 <快照名> 换成实际名称）
sudo k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/<快照名>

sudo systemctl start k3s                     # 3. 重新启动
```

执行细节与观察点：

- 恢复过程中 k3s 会重建 `/var/lib/rancher/k3s/server/db/etcd`（原数据被替换为快照内容）
- 单节点（本环境）恢复后集群即恢复；**多节点 HA 需在所有 server 上做**，且恢复会要求加入该快照的集群
- 恢复后**检查关键资源**：

```bash
export KUBECONFIG=./kubeconfig
kubectl get nodes
kubectl get ns
kubectl -n lab get svc nginx-svc     # 应回到快照时点的状态
```

> ⚠️ 危险操作提醒：
> - 恢复**只覆盖 etcd**，PV 里的业务数据不包含在内（第 05 章讲过 local-path 是节点本地目录）
> - 快照时间点之后创建的**新资源会丢失**
> - 务必先备份当前状态再演练；确认快照可用性后再对生产执行
> - 恢复后 apiserver 客户端证书/服务账户 token 若时间点不一致，可能需要重启相关 Pod（kubelet 会逐渐自愈）

## 6. Rancher 界面对照

etcd 无 Rancher UI 页面（属集群基础设施）。对应查看方式：

- **集群 → Nodes**：节点角色含 `etcd` 标识
- **集群 → etcd**：Rancher 2.7+ 有 etcd 只读面板（备份/恢复入口在 Rancher 的集群管理），与 `k3s etcd-snapshot` 等价
- kubectl 看到的资源 = etcd 内容（第 3.6 节）

## 7. 常见问题

| 现象 | 排查命令 | 对策 |
|------|---------|------|
| apiserver 报 etcd 连接错误 | `endpoint health` | 证书/端口/防火墙检查；重启 k3s |
| DB SIZE 只增不减 | `endpoint status` 看 DB SIZE | 开启自动压缩 `--etcd-expose-metrics` 相关或定期 compact |
| etcdctl 无 version 命令 | — | 新版 etcdctl 移除 `version` 子命令，用 `etcdctl --version` 或 `endpoint status` 的 VERSION 列 |
| 恢复后部分资源不对 | `kubectl get ...` 逐个核对 | 确认快照时间点；必要时重放快照后变更 |

## 动手练习

1. 用 `endpoint status -w table` 记录当前 DB SIZE 和 raft index，一周后再对比（观察增长）。
2. 用 `etcdctl get /registry/pods/default --prefix --keys-only` 看看 default 命名空间有哪些 Pod 键。
3. 对照：`kubectl -n kube-system get configmap` 与 `etcdctl get /registry/configmaps/kube-system --prefix --keys-only` 的条目是否一致。
4. 打一个命名规范的备份 `lab-weekly-snapshot`，确认出现在 `k3s etcd-snapshot list` 中。
5. 思考题（不执行）：如果要把集群迁移到新机器，快照应该拷贝到哪里、恢复命令要改什么参数？

<details>
<summary>参考答案</summary>

1. `kubectl -n kube-system get sa` 看 `kube-apiserver` 的 ServiceAccount 与 etcd 里的 `/registry/serviceaccounts`。
2. default 下通常没有业务 Pod，会有系统级对象（如 kubernetes 服务相关）。
3. 应一致（同一来源）。
4. `sudo k3s etcd-snapshot save --name lab-weekly-snapshot`，list 中出现即可。
5. 快照文件（在 server 节点的 `/var/lib/rancher/k3s/server/db/snapshots/`）拷到新机器同路径，恢复命令路径参数保持一致（`--cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/<快照名>`）；单机迁移时新机用同一 server-token 启动。多节点迁移需按官方文档逐个成员处理。
</details>