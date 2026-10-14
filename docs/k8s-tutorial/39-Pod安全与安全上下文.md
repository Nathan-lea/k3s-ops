# 39 Pod 安全与安全上下文

## 本章目标

- 理解"容器不是沙箱"：为什么 `privileged`、`hostNetwork`、root 运行是高风险配置
- 掌握 `securityContext` 的字段体系（Pod 级 vs 容器级），以及每个字段实际约束了什么
- 掌握 **Pod Security Admission（PSA）** 的三档标准（`privileged` / `baseline` / `restricted`）与命名空间标签（`enforce` / `warn` / `audit`）
- 在本集群（k3s v1.30.2+k3s2）真实实测：默认放行特权 Pod → 开启 `restricted` 后拦截 → 合规改造使其重新运行
- 掌握 seccomp 与 AppArmor 的启用方式，并理解 `PodSecurityPolicy`（PSP）被移除后如何迁移

> 本章所有命令统一使用 `kubectl --kubeconfig ./kubeconfig`。文档中路径统一用 `~/k3s-ops` 表示。

---

## 1. 为什么要"管住" Pod 的权限

容器共享宿主机内核，所谓"隔离"靠的是 **namespace（隔离视图）+ cgroup（限制资源）+ capabilities（切分 root 权限）**。一旦某个维度被放开，隔离就出现缺口：

| 危险配置 | 实际后果 |
|---|---|
| `privileged: true` | 容器拿到全部 capabilities 与宿主设备，基本等同宿主 root（可挂载宿主磁盘、改内核参数） |
| `hostNetwork / hostPID / hostIPC: true` | 直接共享宿主 network / PID / IPC namespace，可抓包、可见宿主进程、可发信号 |
| 以 **root（uid 0）** 运行 | 配合内核漏洞极易提权；容器内文件属主也是 root |
| 未限制 **capabilities** | 默认就带 `CHOWN`、`NET_RAW`、`SETUID` 等一票能力 |
| 可写根文件系统 | 被入侵后可写入恶意二进制、篡改应用文件、留下后门 |
| 未启用 **seccomp** | 系统调用面完全暴露（如 `ptrace`、`keyctl`） |

安全的核心原则是**最小权限（least privilege）**：默认什么都不给，用多少给多少。本章接下来的三件武器分别作用于不同阶段：

- `securityContext`：**声明**一个 Pod 需要什么权限（开发/发布侧）；
- **PSA（Pod Security Admission）**：**准入时强制**命名空间内的 Pod 必须满足某档标准（集群管理侧）；
- **seccomp / AppArmor**：**运行时收窄**系统调用与文件访问面（内核侧）。

---

## 2. securityContext：字段体系

`securityContext` 有两层：**Pod 级**（`spec.securityContext`）作用于所有容器并管卷的属组；**容器级**（`spec.containers[].securityContext`）覆盖单个容器、可覆盖 Pod 级设置。

| 字段 | 级别 | 作用 |
|---|---|---|
| `runAsUser` / `runAsGroup` | Pod / Container | 指定进程 UID / GID |
| `runAsNonRoot` | Pod / Container | 拒绝以 uid 0 启动（镜像 USER 为 root 又没设 runAsUser 时会直接失败） |
| `fsGroup` | Pod | 挂在卷的文件属组 |
| `privileged` | Container | 特权容器（危险） |
| `allowPrivilegeEscalation` | Container | 是否允许通过 setuid/setgid 等提权 |
| `readOnlyRootFilesystem` | Container | 容器根文件系统只读 |
| `capabilities.add` / `.drop` | Container | 增删 Linux capabilities |
| `seccompProfile.type` | Pod / Container | `RuntimeDefault` / `Localhost` / `Unconfined` |
| `appArmorProfile.type` | Pod / Container | `RuntimeDefault` / `Localhost` / `Unconfined`（v1.30 起为字段，旧版用注解） |
| `procMount` | Container | 默认 `Default`；`Unmasked` 会暴露 `/proc` 敏感项（危险） |

一个"较安全"的容器级配置长这样：

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 101
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
  seccompProfile:
    type: RuntimeDefault
```

> 只读根文件系统（`readOnlyRootFilesystem: true`）通常要配合 `emptyDir` 把必须可写的目录（如 nginx 的 `/var/cache/nginx`、`/var/run`、`/tmp`）单独挂出来，否则应用会因写不进去而启动失败——见 §7。

---

## 3. Pod Security Admission（PSA）

PSA 是 **Kubernetes 内置的准入控制器**（自 v1.25 起稳定，取代已移除的 PSP）。它不属于某个插件，k3s 的 kube-apiserver 默认就启用了它：

```text
# 来自 k3s 服务日志（本集群真实截取）
Loaded 13 validating admission controller(s) successfully in the following order:
LimitRanger,ServiceAccount,PodSecurity,Priority,...
```

**三档标准：**

| 档位 | 定位 | 典型限制 |
|---|---|---|
| `privileged` | 不限制 | 等同未启用 PSA（默认就是它） |
| `baseline` | 阻止已知提权 | 禁 `privileged`、`hostNetwork/PID/IPC`、多数危险 capabilities、危险 hostPath 等 |
| `restricted` | 安全最佳实践（最严） | baseline + 必须 `runAsNonRoot`、`allowPrivilegeEscalation=false`、`drop: [ALL]`、`seccompProfile=RuntimeDefault` 等 |

**通过命名空间标签启用**，三个"模式"可独立设置：

| 标签 | 模式 | 行为 |
|---|---|---|
| `pod-security.kubernetes.io/enforce` | 强制 | 不满足则**拒绝创建**（返回 `Forbidden`） |
| `pod-security.kubernetes.io/warn` | 警告 | 允许创建，但返回 `Warning:` 提示 |
| `pod-security.kubernetes.io/audit` | 审计 | 允许创建，仅写入审计日志 |

```bash
# 典型用法：enforce 拦截 + warn 提示 + audit 记录
kubectl --kubeconfig ./kubeconfig label ns <ns> \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted --overwrite
```

> 还可以用 `pod-security.kubernetes.io/enforce-version=v1.30` 把标准"钉"在某个 K8s 版本上，避免升级后校验规则悄悄变严导致线上 Pod 重建失败。不设置则跟随控制面版本（latest）。

**要点：PSA 只作用于命名空间，没有"单 Pod 豁免"**。要豁免（如系统组件）只能通过 apiserver 的准入配置（k3s 里是 `--kube-apiserver-arg` 传 `--admission-control-config-file`）按 namespace/用户名/运行时类做例外。

---

## 4. 真实实测一：默认放行，特权 Pod 照跑

先建一个演示命名空间：

```bash
kubectl --kubeconfig ./kubeconfig create ns podsec-demo
kubectl --kubeconfig ./kubeconfig get ns podsec-demo --show-labels
# NAME          STATUS   AGE   LABELS
# podsec-demo   Active   1s    kubernetes.io/metadata.name=podsec-demo
```

默认**没有任何** `pod-security.kubernetes.io/*` 标签，即 `privileged` 档。我们故意创建一个"危险到极点"的 Pod——特权 + 宿主网络：

```yaml
# ~/k3s-ops/tmp/ch39-privileged.yaml（示例）
apiVersion: v1
kind: Pod
metadata:
  name: privileged
  namespace: podsec-demo
spec:
  hostNetwork: true
  containers:
    - name: c
      image: busybox:1.36
      command: ["sleep", "3600"]
      securityContext:
        privileged: true
```

```bash
kubectl --kubeconfig ./kubeconfig apply -f ~/k3s-ops/tmp/ch39-privileged.yaml
kubectl --kubeconfig ./kubeconfig -n podsec-demo get pod privileged -o wide
# NAME         READY   STATUS    RESTARTS   AGE   IP              NODE
# privileged   1/1     Running   0          3s    192.168.56.20   k3s-demo-agent-1

kubectl --kubeconfig ./kubeconfig -n podsec-demo get pod privileged \
  -o jsonpath='{.spec.containers[0].securityContext.privileged}{" hostNetwork="}{.spec.hostNetwork}{"\n"}'
# true hostNetwork=true
```

**结论**：默认配置下，Pod 拿到了 `privileged` 与 `hostNetwork` 却毫无阻拦——这正是需要 PSA 的原因。

---

## 5. 真实实测二：enforce=restricted 拦截（真实报错）

删掉特权 Pod，给命名空间打上 `restricted` 三件套，再创建同一个清单：

```bash
kubectl --kubeconfig ./kubeconfig -n podsec-demo delete pod privileged --ignore-not-found
kubectl --kubeconfig ./kubeconfig label ns podsec-demo \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted --overwrite

kubectl --kubeconfig ./kubeconfig apply -f ~/k3s-ops/tmp/ch39-privileged.yaml
```

真实输出（本集群逐条 violations）：

```text
Error from server (Forbidden): error when creating ".../ch39-privileged.yaml":
pods "privileged" is forbidden: violates PodSecurity "restricted:latest":
  host namespaces (hostNetwork=true),
  privileged (container "c" must not set securityContext.privileged=true),
  allowPrivilegeEscalation != false (container "c" must set securityContext.allowPrivilegeEscalation=false),
  unrestricted capabilities (container "c" must set securityContext.capabilities.drop=["ALL"]),
  runAsNonRoot != true (pod or container "c" must set securityContext.runAsNonRoot=true),
  seccompProfile (pod or container "c" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

要点：

- 报错**一次性列出全部违规项**，非常适合直接抄成修复清单；
- 拦截发生在**准入阶段**，Pod 根本不会进入 etcd；
- 报错里的 `restricted:latest` 表示 `enforce-version` 未固定，跟随控制面版本。

---

## 6. 真实实测三：warn / audit 与 enforce 的差异

把 `enforce` 标签去掉，**只留** `warn` + `audit`，再创建一次：

```bash
kubectl --kubeconfig ./kubeconfig label ns podsec-demo pod-security.kubernetes.io/enforce- --overwrite
kubectl --kubeconfig ./kubeconfig apply -f ~/k3s-ops/tmp/ch39-privileged.yaml
```

```text
Warning: would violate PodSecurity "restricted:latest": host namespaces (hostNetwork=true), privileged (...), ...
pod/privileged created
```

**同一个 Pod，只因为模式不同，结果天差地别：**

| 模式 | 结果 | 适用场景 |
|---|---|---|
| `enforce` | 拒绝（`Forbidden`） | 生产命名空间，硬约束 |
| `warn` | **创建成功**，仅 CLI 警告 | 灰度：先观察谁会踩线，不阻断 |
| `audit` | 创建成功，静默写审计 | 合规审计、事后统计 |

> 这正是把 `warn` 误当成"保护"的常见坑：`warn` **不拦截**。安全的灰度顺序是 `audit → warn → enforce`。

顺手清理并恢复强制模式：

```bash
kubectl --kubeconfig ./kubeconfig -n podsec-demo delete pod privileged --ignore-not-found
kubectl --kubeconfig ./kubeconfig label ns podsec-demo pod-security.kubernetes.io/enforce=restricted --overwrite
```

---

## 7. 真实实测四：restricted 合规改造

要让 nginx 在 `restricted` 下跑起来，必须满足：非 root、`drop: [ALL]`、`allowPrivilegeEscalation: false`、`seccompProfile: RuntimeDefault`，并且因为根文件系统只读，要把需要写的目录用 `emptyDir` 挂出来：

```yaml
# ~/k3s-ops/tmp/ch39-restricted-deploy.yaml（示例）
apiVersion: apps/v1
kind: Deployment
metadata:
  name: podsec-web
  namespace: podsec-demo
spec:
  replicas: 1
  selector:
    matchLabels: {app: podsec-web}
  template:
    metadata:
      labels: {app: podsec-web}
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 101
        runAsGroup: 101
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: web
          image: nginx:latest
          ports:
            - containerPort: 80
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - {name: cache, mountPath: /var/cache/nginx}
            - {name: run, mountPath: /var/run}
            - {name: tmp, mountPath: /tmp}
      volumes:
        - {name: cache, emptyDir: {}}
        - {name: run, emptyDir: {}}
        - {name: tmp, emptyDir: {}}
```

```bash
kubectl --kubeconfig ./kubeconfig apply -f ~/k3s-ops/tmp/ch39-restricted-deploy.yaml
kubectl --kubeconfig ./kubeconfig -n podsec-demo get pod -l app=podsec-web -o wide
# NAME                          READY   STATUS    IP            NODE
# podsec-web-ddf47cc67-shntv    1/1     Running   10.42.1.167   k3s-demo-agent-1
```

逐项验证安全设置**确实生效**：

```bash
POD=$(kubectl --kubeconfig ./kubeconfig -n podsec-demo get pod -l app=podsec-web --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')

kubectl --kubeconfig ./kubeconfig -n podsec-demo exec $POD -- id
# uid=101(nginx) gid=101(nginx) groups=101(nginx)          ← 非 root

kubectl --kubeconfig ./kubeconfig -n podsec-demo exec $POD -- grep -E '^CapEff' /proc/1/status
# CapEff:	0000000000000000                                  ← drop ALL，零有效 capability

kubectl --kubeconfig ./kubeconfig -n podsec-demo exec $POD -- touch /x
# touch: cannot touch '/x': Read-only file system           ← 只读根文件系统

kubectl --kubeconfig ./kubeconfig -n podsec-demo exec $POD -- grep Seccomp /proc/self/status
# Seccomp:	2                                                ← SECCOMP_MODE_FILTER（RuntimeDefault 生效）
```

**真实细节：非 root 为什么还能绑 80？** 直觉上绑 <1024 端口需要 `CAP_NET_BIND_SERVICE`，而这里 `CapEff` 明明是 0。原因是**容器运行时**在创建 Pod **网络命名空间**时会把它里面的 `net.ipv4.ip_unprivileged_port_start` 置为 `0`——本集群 k3s 自带的 containerd 显式开启了该行为（Kubernetes 自 v1.22 起只是把该 sysctl 标记为"安全 sysctl"，允许但不强制设置）：

```bash
# 节点上 k3s 生成的 containerd 配置（真实截取）
vagrant ssh k3s-demo-server-1 -c "sudo grep -i unprivileged /var/lib/rancher/k3s/agent/etc/containerd/config.toml"
#   enable_unprivileged_ports = true
#   enable_unprivileged_icmp = true
```

于是 Pod 内非特权用户也能绑任意端口：

```bash
# Pod 内（netns 内）
kubectl --kubeconfig ./kubeconfig -n podsec-demo exec $POD -- cat /proc/sys/net/ipv4/ip_unprivileged_port_start
# 0

# 节点上（netns 外）仍是 1024
vagrant ssh k3s-demo-agent-1 -c "sudo sysctl net.ipv4.ip_unprivileged_port_start"
# net.ipv4.ip_unprivileged_port_start = 1024
```

而 nginx 也确实在监听 80（`/proc/net/tcp` 里 `00000000:0050` 即 `0.0.0.0:80`）。

```bash
kubectl --kubeconfig ./kubeconfig -n podsec-demo exec $POD -- sh -c 'cat /proc/net/tcp | awk "NR>1{print \$2}" | head -2'
# 00000000:0050
```

> 所以在现代 K8s 上，非 root 绑 80 是**默认可行**的。若你的环境不是这样（较老版本，或自行关闭了该行为），再按 restricted 允许的方式显式加回**唯一许可**的 capability：`capabilities: {drop: ["ALL"], add: ["NET_BIND_SERVICE"]}`——restricted 档只允许加回 `NET_BIND_SERVICE` 这一个。

---

## 8. seccomp 与 AppArmor

`restricted` 档只强制 `seccompProfile: RuntimeDefault`（收窄系统调用面）。AppArmor 需按需启用。

**节点内核支持情况（本集群实测）：**

```bash
vagrant ssh k3s-demo-server-1 -c "cat /proc/sys/kernel/seccomp/actions_avail"
# kill_process kill_thread trap errno user_notif trace log allow

vagrant ssh k3s-demo-server-1 -c "sudo aa-status | head -3"
# apparmor module is loaded.
# 41 profiles are loaded.
# 41 profiles are in enforce mode.
```

**Pod 里默认使用的 AppArmor profile**（containerd 默认给容器套上 `cri-containerd.apparmor.d`）：

```bash
kubectl --kubeconfig ./kubeconfig -n podsec-demo exec $POD -- cat /proc/self/attr/current
# cri-containerd.apparmor.d (enforce)
```

- **seccomp**：`RuntimeDefault` 走容器运行时自带的过滤白名单；要更严可用 `Localhost` 指向节点上预加载的自定义 profile。
- **AppArmor**：v1.30 起可用 `securityContext.appArmorProfile.type`（`kubectl explain pod.spec.containers.securityContext.appArmorProfile` 可见枚举 `Localhost/RuntimeDefault/Unconfined`）；更早版本用注解 `container.apparmor.security.beta.kubernetes.io/<container>`。

```bash
kubectl --kubeconfig ./kubeconfig explain pod.spec.containers.securityContext.appArmorProfile
# ENUM: Localhost, RuntimeDefault, Unconfined
```

---

## 9. PSP 已移除：从 PodSecurityPolicy 迁移

| 项 | PodSecurityPolicy（PSP） | Pod Security Admission（PSA） |
|---|---|---|
| 状态 | v1.21 起废弃，**v1.25 移除** | v1.25 起稳定，内置 |
| 粒度 | 绑定 RBAC，可对不同用户给不同策略 | 仅**命名空间**级，三档标准 |
| 维护 | 需自行编写/维护一组 PSP 对象 | 内置三档，无需额外对象 |
| 豁免 | RBAC 天然支持 | 需 apiserver 准入配置 |

迁移映射（常见 PSP 字段 → PSA 档位 / `securityContext`）：

| PSP 字段 | 迁移目标 |
|---|---|
| `privileged: false` | baseline/restricted 档自动启用 |
| `hostNetwork/hostPID/hostIPC: false` | baseline/restricted 档自动启用 |
| `runAsNonRoot: true` | restricted 档要求 → 写进 `securityContext` |
| `readOnlyRootFilesystem: true` | 无档位覆盖，需**逐 Pod** 写 `securityContext` |
| `allowedCapabilities` | restricted → `drop: [ALL]`（仅允许加回 `NET_BIND_SERVICE`） |
| `seLinux` / `seccomp` | 由 `securityContext` 字段表达 |

> PSA 是"粗粒度围栏"，管不到 `readOnlyRootFilesystem` 这类细节；要"细粒度强制"（如禁止 `:latest`、强制 requests）需要**策略引擎**（Kyverno / Gatekeeper / 校验准入策略 ValidatingAdmissionPolicy）。

---

## 10. 排障清单

| 现象 | 常见原因 | 排查命令 |
|---|---|---|
| Pod 被拒：`violates PodSecurity` | 命名空间 `enforce` 门槛高于 Pod 配置 | 看报错列出的 violations，逐条补齐 `securityContext` |
| 只有 `Warning:` 但明明应该被拦 | 命名空间只设了 `warn`/`audit`，没设 `enforce` | `kubectl --kubeconfig ./kubeconfig get ns <ns> --show-labels` |
| 通过校验但容器起不来 | `runAsNonRoot` 与镜像默认 root 冲突；只读根文件系统导致写盘失败 | `kubectl --kubeconfig ./kubeconfig -n <ns> describe pod <p>` 看事件与退出码 |
| nginx 类应用 CrashLoop | `readOnlyRootFilesystem: true` 但没挂可写目录 | 补 `emptyDir` 到 `/var/cache/nginx`、`/var/run`、`/tmp` |
| 非 root 绑 80 失败 | 环境未把 pod netns 的 `ip_unprivileged_port_start` 置 0 | 加回 `NET_BIND_SERVICE`，或改用 >1024 端口 |
| 想临时放行调试 | 需要放宽该命名空间门槛 | 降级为 `baseline`，或临时摘掉 `enforce` 标签（记得复原） |

---

## 11. Rancher 界面对照

| 路径 | 对应 kubectl | 用途 |
|---|---|---|
| **集群 → Projects/Namespaces → 命名空间 → Edit → Labels & Annotations** | `kubectl --kubeconfig ./kubeconfig label ns <ns> pod-security.kubernetes.io/enforce=...` | 给命名空间加 PSA 标签（Rancher 无专门的"安全档位"下拉，PSA 就是普通标签） |
| **集群 → More Resources → core → Namespaces** | `kubectl --kubeconfig ./kubeconfig get ns --show-labels` | 查看各命名空间当前的安全档位 |
| **工作负载详情 → Pod → 容器详情** | `kubectl --kubeconfig ./kubeconfig -n <ns> get pod <p> -o yaml` | 查看 `securityContext`（Rancher UI 会展示 runAsUser 等字段） |
| **集群 → Events** | `kubectl --kubeconfig ./kubeconfig get events -A --sort-by=.metadata.creationTimestamp` | 查看 `FailedCreate`/`Forbidden` 准入拒绝事件 |

> Rancher 本身没有"策略编辑器"，PSA 在它眼里就是命名空间上的**标签**；更细的策略（Kyverno/Gatekeeper）需另装。这也是为什么理解 PSA 标签比记 UI 位置更重要。

---

## 动手练习

1. **档位对照**：分别给一个测试命名空间设 `enforce=baseline` 与 `enforce=restricted`，用同一个"非 root 但不 drop capabilities"的 Pod 测试，记录两次结果差异，并解释原因。
2. **warn 与 enforce**：用本章 §6 的方法，说明为什么"只设 `warn`"上线会在某次 Pod 重建时才炸——写出触发条件。
3. **合规改造**：把一个以 root 运行的 nginx 改造成 `restricted` 可接受（提示：`runAsNonRoot` + `drop: [ALL]` + `readOnlyRootFilesystem` + 三个 `emptyDir`）。
4. **只读根文件系统**：解释 `readOnlyRootFilesystem: true` 下 nginx 为什么还需要写磁盘，以及如何用 `emptyDir` 满足。
5. **绑 80 之谜**：在 Pod 内执行 `cat /proc/sys/net/ipv4/ip_unprivileged_port_start`，对照节点上的值，解释非 root 为什么能监听 80。
6. **seccomp 证据**：在合规 Pod 内执行 `grep Seccomp /proc/self/status` 与 `cat /proc/self/status | grep -i seccomp`，说明 `Seccomp: 2` 的含义。
7. **迁移口径**：写出 `readOnlyRootFilesystem: true` 在 PSP→PSA 迁移里为什么"不能靠档位解决"。

<details>
<summary>参考答案</summary>

1. `baseline` 只拦已知提权项（privileged、hostNetwork、危险 capabilities 等），"非 root 但不 drop capabilities"**可以通过**；`restricted` 还额外要求 `runAsNonRoot`、`drop: [ALL]`、`allowPrivilegeEscalation=false`、`seccompProfile=RuntimeDefault`，因此同一 Pod 在 `restricted` 下会被拒（报 `unrestricted capabilities` 等）。
2. 只设 `warn`/`audit` 时 Pod **能被创建**，所以"当前跑着"不代表合规。触发条件是**Pod 重建**（滚动更新、节点驱逐、副本扩缩、`kubectl delete pod`）——此时携带违规配置的新 Pod 若命名空间已改为 `enforce`，就会失败。因此灰度应 `audit → warn → enforce`，且在切 `enforce` 前先用 `warn` 覆盖全部待重建路径。
3. 关键四件套：容器级 `runAsNonRoot`（或 Pod 级）、`capabilities.drop: [ALL]`、`allowPrivilegeEscalation: false`、`readOnlyRootFilesystem: true`，并给 `/var/cache/nginx`、`/var/run`、`/tmp` 挂 `emptyDir`；`securityContext.seccompProfile.type: RuntimeDefault`（Pod 或容器级均可）。
4. nginx 主进程要写 `pid` 文件（`/var/run/nginx.pid`）、临时缓存（`/var/cache/nginx/*_temp`）。根文件系统只读后这些路径写不了，启动即失败。用 `emptyDir` 把这三个目录挂成可写卷即可，既不破坏"根只读"的安全收益，又满足运行时需要。
5. Pod netns 内 `ip_unprivileged_port_start = 0`，节点上为 `1024`。该值由**容器运行时**在创建 Pod 网络命名空间时置 0（本集群 k3s 自带 containerd 的 `enable_unprivileged_ports = true`；Kubernetes 只将其标记为 safe sysctl，并不强制设置），所以非特权 UID 也能绑 <1024 端口，无需 `CAP_NET_BIND_SERVICE`（因此 `CapEff` 为 0 也能监听 80）。
6. `Seccomp: 2` 即 `SECCOMP_MODE_FILTER`，表示已加载 seccomp 过滤器（`RuntimeDefault` 生效）；`0` 为 `SECCOMP_MODE_DISABLED`，`1` 为 `SECCOMP_MODE_STRICT`。
7. PSA 三档只覆盖"已知提权项"这一类，`readOnlyRootFilesystem` 属于**对单个应用的运行时偏好**，没有对应档位；PSP 时代靠 PSP 对象逐条声明，PSA 时代必须**逐 Pod 写进 `securityContext`**，或用策略引擎强制。

</details>

---

## 附录：本章真实采集片段与清理

**采集环境**：k3s v1.30.2+k3s2，节点 `k3s-demo-server-1` / `k3s-demo-agent-1`。

**1. 默认放行特权 Pod：**

```text
privileged   1/1   Running   ...   192.168.56.20   k3s-demo-agent-1
spec: privileged=true hostNetwork=true
```

**2. `enforce=restricted` 拒绝（完整 violations）：** 见 §5 的 `Forbidden` 原文。

**3. `warn` 只警告不拦截：**

```text
Warning: would violate PodSecurity "restricted:latest": ...
pod/privileged created
```

**4. 合规工作负载实测：**

```text
podsec-web-ddf47cc67-shntv   1/1   Running   10.42.1.167   k3s-demo-agent-1
runAsNonRoot=true runAsUser=101 seccomp=RuntimeDefault
$ id                          → uid=101(nginx) gid=101(nginx) groups=101(nginx)
$ grep CapEff /proc/1/status  → CapEff:	0000000000000000
$ cat /proc/net/tcp           → 00000000:0050   (0.0.0.0:80 LISTEN)
$ touch /x                    → touch: cannot touch '/x': Read-only file system
$ grep Seccomp /proc/self/status → Seccomp:	2
```

**5. 内核侧证据：**

```text
# pod netns 内
ip_unprivileged_port_start = 0
# 节点上
net.ipv4.ip_unprivileged_port_start = 1024
# 该行为的来源（节点上 k3s 生成的 containerd 配置）
enable_unprivileged_ports = true
enable_unprivileged_icmp = true
# seccomp
actions_avail: kill_process kill_thread trap errno user_notif trace log allow
# apparmor
apparmor module is loaded. 41 profiles are in enforce mode.
容器内 /proc/self/attr/current → cri-containerd.apparmor.d (enforce)
```

**6. 准入控制器（PSA 内置的证据）：**

```bash
vagrant ssh k3s-demo-server-1 -c "sudo journalctl -u k3s | grep -i 'admission controller' | tail -1"
# Loaded 13 validating admission controller(s) successfully in the following order:
# LimitRanger,ServiceAccount,PodSecurity,Priority,...
```

**本章创建的资源：**

- 命名空间 `podsec-demo`：Deployment `podsec-web`（restricted 合规，保留）；命名空间保留了 `enforce/warn/audit=restricted` 标签
- 临时特权 Pod `privileged` —— 已删除

**清理命令：**

```bash
kubectl --kubeconfig ./kubeconfig delete ns podsec-demo
```

> ⚠️ `podsec-demo` 命名空间带着 `enforce=restricted` 标签，若你想继续在其中做实验，任何不满足 restricted 的 Pod 都会被拒——这是预期行为。
