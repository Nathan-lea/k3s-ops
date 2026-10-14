# 40 StatefulSet 与有状态应用实战

## 本章目标

- 理解 StatefulSet 与 Deployment 的本质差异：**稳定网络标识、有序部署、独立存储**
- 掌握 **Headless Service** 的作用，以及 `<pod>.<service>.<ns>` 这类稳定 DNS 名称
- 掌握 `volumeClaimTemplates`（卷申领模板）如何为每个副本**自动生成独立 PVC**
- 在本集群（k3s v1.30.2+k3s2）真实实测：有序创建/缩容、Pod 重建复用同名同卷、`partition` 灰度滚动
- 理解 StatefulSet 的"身份"在整个生命周期中如何保持，以及**删除 StatefulSet 不会回收 PVC** 这一常见坑

> 本章所有命令统一使用 `kubectl --kubeconfig ./kubeconfig`。文档中路径统一用 `~/k3s-ops` 表示。

---

## 1. StatefulSet vs Deployment：差在哪

Deployment 里的 Pod 是**可互换的**：名字随机（`web-7c9f8d-abcde`）、共享一块存储、随便调度到哪都行。StatefulSet 里的 Pod 却带"身份"：

| 维度 | Deployment | StatefulSet |
|---|---|---|
| Pod 名称 | 随机后缀（`app-<hash>-<rand>`） | **固定序号**（`app-0`、`app-1`、`app-2`） |
| 网络标识 | 无稳定名字，靠 Service 负载均衡 | 每个 Pod 有稳定 DNS：`<pod>.<svc>.<ns>` |
| 存储 | 多个副本通常共享一个 PVC（或无状态） | 每个 Pod **独立 PVC**（`volumeClaimTemplates`） |
| 创建/删除 | 并行，无序 | **有序**：创建 0→1→2，删除 2→1→0 |
| 滚动更新 | 无序号，按批次 | 按序号逆序，可用 `partition` 做灰度 |
| 典型场景 | 无状态 Web/API | 数据库、消息队列、ZooKeeper/etcd 等需要"身份"的集群 |

一句话：**StatefulSet 保证"这个 Pod 换了，但它还是它"**——同样的名字、同样的网络名、同样的存储卷。

---

## 2. Headless Service 与稳定 DNS

StatefulSet 必须配一个 **Headless Service**（`clusterIP: None`）。普通 Service 会给所有 Pod 一个**虚拟 IP 做负载均衡**；Headless 不做 VIP，而是让 DNS **直接返回每个 Pod 的 IP**，从而支持按名字精确访问某个副本。

```yaml
# Headless Service 的关键特征
spec:
  clusterIP: None     # 关键：不分配 ClusterIP
  selector:
    app: web
```

有了它，StatefulSet 中每个 Pod 都会获得稳定 DNS（`<pod-name>.<service-name>.<namespace>.svc.cluster.local`），例如：

- `web-0.web-headless.sts-demo.svc.cluster.local`
- `web-1.web-headless.sts-demo.svc.cluster.local`

主从复制类应用正是靠这个：`web-0` 当主、`web-1/2` 连 `web-0.web-headless...` 做从——**Pod 重建后名字不变，主从关系不用改**。

---

## 3. volumeClaimTemplates：每个副本一块独立盘

`volumeClaimTemplates` 是一个 **PVC 模板**。StatefulSet 会为每个副本实例化一个 PVC，命名规则固定为 `<模板名>-<statefulset名>-<序号>`：

```yaml
volumeClaimTemplates:
  - metadata:
      name: www                       # PVC 会变成 www-web-0 / www-web-1 / www-web-2
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: local-path
      resources:
        requests:
          storage: 100Mi
```

与 `volumes:` 的差别：`volumes` 里的 `emptyDir` 随 Pod 生命周期消失；`volumeClaimTemplates` 生成的 PVC **独立于 Pod 存在**——Pod 删了，PVC 还在（后面 §7 会实测这个"坑"）。

---

## 4. 真实实测一：有序创建与独立 PVC

先确认默认 StorageClass（本章用 k3s 自带的 `local-path`）：

```bash
kubectl --kubeconfig ./kubeconfig get storageclass
# NAME                   PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      AGE
# local-path (default)   rancher.io/local-path   Delete          WaitForFirstConsumer   141d
```

创建命名空间并部署 `web-headless`（Headless Service）+ `web`（3 副本 StatefulSet）：

```bash
kubectl --kubeconfig ./kubeconfig create ns sts-demo
kubectl --kubeconfig ./kubeconfig apply -f ~/k3s-ops/tmp/ch40-sts.yaml
kubectl --kubeconfig ./kubeconfig -n sts-demo get pod -o wide
```

**观察有序创建**（逐个副本依次 Ready，绝不并行）：

```text
web-0=Pending/
web-0=Pending/false
web-0=Running/true web-1=Pending/false        ← web-0 就绪后 web-1 才开始
web-0=Running/true web-1=Running/true web-2=Pending/
web-0=Running/true web-1=Running/true web-2=Running/true
```

最终状态（每个 Pod 一块独立盘，PVC 名严格对应序号）：

```bash
kubectl --kubeconfig ./kubeconfig -n sts-demo get pod,svc,pvc -o wide
```

```text
NAME        READY   STATUS    IP            NODE
pod/web-0   1/1     Running   10.42.1.169   k3s-demo-agent-1
pod/web-1   1/1     Running   10.42.0.119   k3s-demo-server-1
pod/web-2   1/1     Running   10.42.1.171   k3s-demo-agent-1

NAME                   TYPE        CLUSTER-IP   PORT(S)   SELECTOR
service/web-headless   ClusterIP   None         80/TCP    app=web

NAME                              STATUS   VOLUME       STORAGECLASS
persistentvolumeclaim/www-web-0   Bound    pvc-c9418e2b...   local-path
persistentvolumeclaim/www-web-1   Bound    pvc-40a1f675...   local-path
persistentvolumeclaim/www-web-2   Bound    pvc-14e72e89...   local-path
```

> 注意 Pod 分散到了两个节点（`web-0/2` 在 agent-1，`web-1` 在 server-1）——`local-path` 的 `WaitForFirstConsumer` 会等 Pod 调度后再在各节点本地创建卷。所以 `web-1` 的卷落在 server-1。

---

## 5. 真实实测二：稳定 DNS 名称

用一次性 Pod 解析名字：

```bash
kubectl --kubeconfig ./kubeconfig -n sts-demo run dnstest --rm -i --restart=Never --image=busybox:1.36 -- \
  sh -c 'nslookup web-0.web-headless.sts-demo.svc.cluster.local; \
         echo "--- headless 汇总 ---"; \
         nslookup web-headless.sts-demo.svc.cluster.local'
```

```text
Name:	web-0.web-headless.sts-demo.svc.cluster.local
Address: 10.42.1.169                      ← 精确解析到 web-0 自己

Name:	web-headless.sts-demo.svc.cluster.local
Address: 10.42.1.169                      ← Headless：返回所有 Pod 的 IP
Address: 10.42.1.171
Address: 10.42.0.119
```

对比：普通（非 Headless）Service 只会解析出**一个 VIP**，而 Headless 返回**每个 Pod 的 IP**，这正是"按名字访问指定副本"的基础。

---

## 6. 真实实测三：身份与存储的"不变性"

最关键的一条：删掉某个 Pod，StatefulSet 会用**同样的名字**把它重建，并且**复用同一块 PVC**。

```bash
# 删除前
kubectl --kubeconfig ./kubeconfig -n sts-demo get pod web-1 \
  -o jsonpath='{.metadata.name} {.spec.nodeName} ip={.status.podIP} uid={.metadata.uid}{"\n"}'
kubectl --kubeconfig ./kubeconfig -n sts-demo get pvc www-web-1 \
  -o jsonpath='pvc={.metadata.name} vol={.spec.volumeName} phase={.status.phase}{"\n"}'

kubectl --kubeconfig ./kubeconfig -n sts-demo delete pod web-1
```

```text
# 删除前
web-1 k3s-demo-server-1 ip=10.42.0.119 uid=2ad31d01-363f-4068-afb8-c2947b3fef05
pvc=www-web-1 vol=pvc-40a1f675-a49e-4cfa-a9d3-7463795abbd6 phase=Bound

# 重建后
web-1 k3s-demo-server-1 ip=10.42.0.120 uid=e4a4bff6-bc0e-4e66-a9ee-987052f15d0f
pvc=www-web-1 vol=pvc-40a1f675-a49e-4cfa-a9d3-7463795abbd6 phase=Bound
```

解读：
- **名字不变**：`web-1` 还是 `web-1`（Deployment 会换一个新随机名）；
- **UID 变了**：`2ad31d01…` → `e4a4bff6…`（确实是个新 Pod，不是同一个对象）；
- **PVC / PV 完全不变**：还是 `www-web-1`，卷还是 `pvc-40a1f675…`。

**数据持久化实证**——写入文件、删 Pod、重建后读回：

```bash
kubectl --kubeconfig ./kubeconfig -n sts-demo exec web-1 -- \
  sh -c 'echo hello-from-web-1 > /usr/share/nginx/html/persist.txt && cat /usr/share/nginx/html/persist.txt'
# hello-from-web-1

kubectl --kubeconfig ./kubeconfig -n sts-demo delete pod web-1
# 等待重建后：
kubectl --kubeconfig ./kubeconfig -n sts-demo exec web-1 -- cat /usr/share/nginx/html/persist.txt
# hello-from-web-1        ← 数据仍在
```

---

## 7. 真实实测四：有序缩容与 partition 灰度滚动

**有序缩容**——副本从 3 减到 1，删除顺序是**逆序**（2→1→0）：

```bash
kubectl --kubeconfig ./kubeconfig -n sts-demo scale sts web --replicas=1
```

```text
[t+1s] web-0:Running web-1:Running web-2:Terminating     ← 先删 web-2
[t+2s] web-0:Running web-1:Terminating                   ← 再删 web-1
[t+3s] web-0:Running                                     ← 保留 web-0
```

缩容**不会删 PVC**（`www-web-0/1/2` 全部保留 `Bound`），所以再扩回 3 副本时，`web-1`/`web-2` 会**拿回原来的卷**，数据不丢。

**partition 灰度滚动**——`partition: 2` 表示"序号 ≥ 2 的副本才更新"，即只有 `web-2` 先滚，用来做金丝雀：

```bash
kubectl --kubeconfig ./kubeconfig -n sts-demo patch sts web --type=merge \
  -p '{"spec":{"updateStrategy":{"type":"RollingUpdate","rollingUpdate":{"partition":2}}}}'
# 触发一次变更（这里加环境变量，避免重新拉镜像）
kubectl --kubeconfig ./kubeconfig -n sts-demo patch sts web --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/env","value":[{"name":"DEMO","value":"partition-test"}]}]'
kubectl --kubeconfig ./kubeconfig -n sts-demo get pod -L controller-revision-hash
```

```text
NAME    READY   STATUS    CONTROLLER-REVISION-HASH
web-0   1/1     Running   web-c54bbc97f          ← 旧版本，未动
web-1   1/1     Running   web-c54bbc97f          ← 旧版本，未动
web-2   1/1     Running   web-8695b9fdb6        ← 只更新了 web-2
```

验证没问题后把 `partition` 调小（如 `0`），后续副本才会继续滚动——这就是"有状态应用的灰度发布"。

> **父级与 Owner 关系**：StatefulSet 通过 `ownerReference` 管理这些 Pod 和 PVC。`kubectl delete sts web` 会级联删除 Pod，但**默认不会删 PVC**（见 §8）。

---

## 8. 真实实测五：删除 StatefulSet 不回收 PVC（常见坑）

用一个一次性的小 StatefulSet 验证：删掉 StatefulSet 后，PVC **依然存在**（`Bound`）：

```bash
kubectl --kubeconfig ./kubeconfig -n sts-demo delete sts tmp
# statefulset.apps "tmp" deleted from sts-demo namespace

kubectl --kubeconfig ./kubeconfig -n sts-demo get sts tmp
# Error from server (NotFound): statefulsets.apps "tmp" not found

kubectl --kubeconfig ./kubeconfig -n sts-demo get pvc data-tmp-0
# NAME         STATUS   VOLUME               CAPACITY   STORAGECLASS
# data-tmp-0   Bound    pvc-33fa67f3-aff4... 50Mi       local-path      ← 还在！
```

**为什么这么设计？** 出于数据安全——Kubernetes 不想因为一次 `delete sts` 就把数据库数据卷一起删掉。代价是：**你可能以为"删干净了"，其实卷还在占用存储**。清理必须显式删 PVC：

```bash
kubectl --kubeconfig ./kubeconfig -n sts-demo delete pvc --all
```

---

## 9. 与 PDB、节点维护的关系

StatefulSet 的**有序性**会让节点维护（第 38 章 `drain`）更敏感：

- 驱逐 `web-0`（主）时，StatefulSet 要等它完全终止、再在原节点以外的位置重建，**中间会出现"该序号缺失"的窗口**；
- 若配了 PDB（第 38 章）且 `minAvailable` 较高，`drain` 可能被卡住；
- 对有状态集群（如 etcd/MySQL 主从），**务必逐副本手动维护**，不要一次性 drain 掉多个成员。

实践建议：数据库类 StatefulSet 用 `PodDisruptionBudget` 保护到"任意时刻至少 N-1 可用"，节点维护前先确认复制同步状态。

---

## 10. 排障清单

| 现象 | 常见原因 | 排查命令 |
|---|---|---|
| Pod 一直 Pending | `volumeClaimTemplates` 指定的 `storageClassName` 不存在；或 `WaitForFirstConsumer` 等调度 | `kubectl --kubeconfig ./kubeconfig -n <ns> describe pvc <pvc>` |
| 创建卡在 `web-0` 不动 | 前一个副本未 Ready（探针失败/镜像拉取失败）——有序性导致阻塞 | `kubectl --kubeconfig ./kubeconfig -n <ns> describe pod web-0` |
| DNS 解析不到 Pod | Service 不是 Headless（有 ClusterIP）；名字写错（注意是 `<pod>.<svc>.<ns>`） | `kubectl --kubeconfig ./kubeconfig -n <ns> get svc` 看 `CLUSTER-IP` 是否为 None |
| 扩缩容后数据"丢"了 | 删了 PVC，或 `storageClassName` 换了 | `kubectl --kubeconfig ./kubeconfig -n <ns> get pvc` |
| 删除 StatefulSet 后存储仍占用 | PVC 默认不回收（设计如此） | `kubectl --kubeconfig ./kubeconfig -n <ns> get pvc` 后手动删 |
| 滚动更新不动 | `partition` 设得比副本数还大 | `kubectl --kubeconfig ./kubeconfig -n <ns> get sts <name> -o jsonpath='{.spec.updateStrategy}'` |

---

## 11. Rancher 界面对照

| 路径 | 对应 kubectl | 用途 |
|---|---|---|
| **集群 → Workloads → StatefulSets** | `kubectl --kubeconfig ./kubeconfig -n <ns> get sts` | 查看 StatefulSet 列表、副本状态、`Service Name` |
| **StatefulSet 详情 → Pods** | `kubectl --kubeconfig ./kubeconfig -n <ns> get pod -l app=web` | 看到 `web-0/1/2` 固定序号名 |
| **StatefulSet 详情 → Volumes** | `kubectl --kubeconfig ./kubeconfig -n <ns> get pvc` | 查看每个副本对应的 `volumeClaimTemplates` PVC 与绑定情况 |
| **集群 → Storage → PersistentVolumes / PVCs** | `kubectl --kubeconfig ./kubeconfig get pv,pvc -A` | 观察 PVC 与 PV 的绑定，以及"删 STS 后 PVC 残留" |

> Rancher UI 里 StatefulSet 的 **Service Name** 字段直接对应 `spec.serviceName`（本章为 `web-headless`）；扩容/缩容可在 UI 里直接操作，效果与 `kubectl scale` 一致。

---

## 动手练习

1. **命名规则**：一个 StatefulSet 名为 `db`、`volumeClaimTemplates` 名为 `data`、3 副本。写出三个 PVC 的名字。
2. **有序性**：把 `web` 扩到 5 副本，观察创建顺序；再缩回 2，观察删除顺序，用一句话总结规律。
3. **Headless 对比**：临时把 `web-headless` 改成普通 Service（去掉 `clusterIP: None`），再解析 `web-0.web-headless...`，解释结果差异，然后改回。
4. **数据不丢**：往 `web-2` 的卷里写一个文件，`delete pod web-2`，重建后读回，证明数据仍在。
5. **partition 灰度**：把 `partition` 设为 `1`，触发一次变更，说明哪些副本会更新、哪些不会。
6. **清理坑**：解释 `kubectl delete sts web` 之后，`www-web-0/1/2` 为什么还在，以及正确的清理命令。
7. **PDB 联动（进阶）**：给 `web` 配一个 `minAvailable: 2` 的 PDB，思考 `drain` 某个节点时会发生什么。

<details>
<summary>参考答案</summary>

1. `data-db-0`、`data-db-1`、`data-db-2`（规则：`<模板名>-<StatefulSet名>-<序号>`）。
2. 扩容 3→5：依次创建 `web-3`、`web-4`（升序）；缩容 5→2：依次删除 `web-4`、`web-3`、`web-2`（**降序**）。规律：**扩容升序、缩容降序，逐个（一次只处理一个序号）直至目标状态**。
3. 若 `web-headless` 变成普通 Service（有 ClusterIP），`web-0.web-headless...` 这个"按 Pod 名"的 DNS **不再存在**（解析失败），因为普通 Service 只提供统一 VIP；只有 Headless Service 才会把每个 Pod 的名字/地址注册进 DNS。改回 `clusterIP: None` 后恢复。
4. `kubectl exec web-2 -- sh -c 'echo x > /usr/share/nginx/html/f'`，`delete pod web-2`，重建后 `exec web-2 -- cat /usr/share/nginx/html/f` 仍输出 `x`——因为 PVC `www-web-2` 未变。
5. `partition: 1` 时，**序号 ≥ 1** 的副本（`web-1`、`web-2`）更新到新版本，`web-0` 保持旧版本。
6. 因为 StatefulSet 默认**不回收 PVC**（数据安全设计）；正确清理：`kubectl --kubeconfig ./kubeconfig -n sts-demo delete pvc --all`（或逐个 `delete pvc www-web-0 ...`）。
7. PDB `minAvailable: 2` 时，StatefulSet 在 drain 过程中若可用副本会跌破 2，Eviction 被拒（`429`），`drain` 会卡住重试直到超时——需要先缩容策略/调整 PDB 或分批维护。

</details>

---

## 附录：本章真实采集片段与清理

**采集环境**：k3s v1.30.2+k3s2，StorageClass `local-path`。

**1. 有序创建**：`web-0=Pending` → `web-0=Running/true web-1=Pending/false` → … → 三者全 Ready（严格串行）。

**2. 稳定身份 + 复用同卷**（删 `web-1`）：

```text
before: web-1 ip=10.42.0.119 uid=2ad31d01-...  pvc=www-web-1 vol=pvc-40a1f675-... Bound
after : web-1 ip=10.42.0.120 uid=e4a4bff6-...  pvc=www-web-1 vol=pvc-40a1f675-... Bound
```

**3. 数据持久化**：`hello-from-web-1` 在 Pod 重建后仍可读回。

**4. 有序缩容**：`web-2:Terminating` → `web-1:Terminating` → 只剩 `web-0`；PVC 全部保留。

**5. partition 灰度**：`web-2` → `web-8695b9fdb6`；`web-0`/`web-1` 仍 `web-c54bbc97f`。

**6. 删 STS 不删 PVC**：`sts tmp` 删除后 `pvc/data-tmp-0` 仍 `Bound`。

**本章创建的资源：**

- 命名空间 `sts-demo`：Headless Service `web-headless` + StatefulSet `web`（3 副本，保留）
- 3 个 PVC：`www-web-0/1/2`（保留）
- 演示用 StatefulSet `tmp` 及其 PVC `data-tmp-0` —— 已清理

**清理命令：**

```bash
# StatefulSet 不会自动删 PVC，必须显式删除
kubectl --kubeconfig ./kubeconfig delete ns sts-demo
# 或只删数据：
kubectl --kubeconfig ./kubeconfig -n sts-demo delete pvc --all
```

> ⚠️ 记住这一章反复出现的坑：**删了 StatefulSet ≠ 删了数据**。`www-web-0/1/2` 会一直占着存储，直到你显式删除 PVC。
