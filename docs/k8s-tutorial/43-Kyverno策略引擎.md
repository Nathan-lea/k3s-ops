# 43 Kyverno 策略引擎

## 本章目标

- 说清第 39 章 PSA（Pod Security Admission）的**边界**：它只是一个粗粒度的"三档围栏"，表达不了"镜像不能带 `:latest`"这类规则。
- 看懂 Kyverno 的**架构**：它本身就是一个 Operator（admission / background / cleanup / reports 四个控制器 + 自家一堆 CRD），正好把第 42 章学的 CRD 与控制器串起来。
- 亲手实测 Kyverno 的**三类策略**：
  - `validate`：准入时校验（Enforce 拦截 / Audit 只记报告）；
  - `mutate`：准入时改写（自动补标签、补安全上下文）；
  - `generate`：按触发条件生成下游资源（给新命名空间自动配 NetworkPolicy）。
- 会看 **PolicyReport**（合规报告），会用 **Kyverno CLI 离线测试**（可进 CI）。
- 掌握**逃生与卸载**：策略把集群拦死了怎么办、怎么干净地卸掉 Kyverno。

> 本章沿用第 39 章的安全上下文、第 35 章的 NetworkPolicy、第 42 章的 CRD/Operator 知识。
> 演示命名空间是 `policy-demo`（与 42 章的 `operator-demo` 并列）。

---

## 1. 从 39 章 PSA 到 Kyverno：粗粒度围栏的边界

第 39 章我们用 **PSA**（`pod-security.kubernetes.io/enforce` 标签）给命名空间套了一层围栏：
`privileged` / `baseline` / `restricted` 三档，由 kube-apiserver **内置**执行。

它便宜、零依赖，但有三条硬边界：

| 边界 | 说明 | 例子（PSA 做不到） |
|---|---|---|
| **粒度粗** | 只能按"整档"开关，不能逐条开关 | "允许 privileged，但不许 `:latest`" |
| **只管 Pod 安全** | 规则固定在 k8s 内置的那几十条里 | "所有 Pod 必须有 `team` 标签" |
| **不能改写** | PSA 只会拒绝，不会帮你补字段 | "没写 resources 就自动补上限" |

一句话：**PSA 是"内置的一档围栏"，Kyverno 是"你能自己写规则、还能改写资源的策略引擎"。**

Kyverno 不是唯一选择（还有 OPA Gatekeeper / KubeArmor 等），但它的特点是**用 YAML 写策略**——
不需要学一门新语言（Rego）或写 Webhook 代码，所以最适合用来建立"策略即代码"的心智模型。

---

## 2. Kyverno 架构：它本身就是一个 Operator

第 42 章我们说：CRD 给 API Server 注册新类型，控制器（Operator）负责调谐。

**Kyverno 就是这套模式的产物**。它做两件事：

1. 注册一大堆自家 CRD：`ClusterPolicy`/`Policy`（策略）、`PolicyException`（豁免）、
   `UpdateRequest`（generate 的内部对象）、`PolicyReport`（报告）等——实测本章集群里 Kyverno **新增了 20 个 CRD**。
2. 跑若干个控制器，每个管一件事：

| 控制器 | 职责 | 本章会看到它 |
|---|---|---|
| **admission-controller** | 挂 **Mutating/Validating Webhook**，在"对象写入 etcd 之前"校验与改写 | validate、mutate |
| **background-controller** | 定时**扫描存量对象**，产出报告；处理 `generate` | Audit 报告、generate |
| **reports-controller** | 聚合 PolicyReport / ClusterPolicyReport | PolicyReport |
| **cleanup-controller** | 按 `CleanupPolicy` 定期清理资源 | 不在本章演示 |

所以等下你看到的每个 Pod（`kyverno-admission-controller` 等），
本质上和第 42 章你手写的 `webapp-operator` **是同一类东西**——只是它管的是"策略"。

> **前瞻提示（重要）**：从 Kyverno 1.14 起，经典的 `kyverno.io/v1` 类型
> （`ClusterPolicy`/`Policy` 等）已被标记为 **deprecated**，官方推荐迁移到
> `policies.kyverno.io` 下的 **CEL 版**类型（`ValidatingPolicy` / `MutatingPolicy` /
> `GeneratingPolicy` / `ImageValidatingPolicy`）。本章**仍用 `ClusterPolicy`**，因为它的
> `validate/mutate/generate` 语法最直白、最适合讲清三类策略的差别；但你在真实项目里落地新策略时，
> 应优先考虑 CEL 版。这个"API 会演进、用 CRD 承载的接口可以平滑迁移"的现象，正是第 42 章的主旨。

---

## 3. 安装 Kyverno

> **前置条件（宿主资源）**：Kyverno 的四个控制器加起来约占 1 个 CPU 核与数百 MB 内存，
> 且本教程把运行负载钉在工作节点上。请确保**宿主机至少空闲 4 核 CPU、4 GB 内存**，
> 否则 k3s 可能因资源饥饿被系统强制重启（表现为 `kubectl` 间歇性 `connection refused`）。
> 这不是 Kyverno 的 bug，而是"小机器上再叠一层"的常见现象。

### 3.1 安装前先看基线（避免"以为装了其实没装"）

```bash
kubectl --kubeconfig ./kubeconfig get crd | grep -i kyverno || echo "NO_KYVERNO_CRD"
```

实测输出：

```text
NO_KYVERNO_CRD
```

### 3.2 预拉镜像（本环境的镜像拉取策略）

本部署环境不能直连 Docker Hub/GCR，但 **`reg.kyverno.io` 可达**。Kyverno 控制器共 6 个镜像。
**先把镜像拉到工作节点**，可以避免 `helm install --wait` 卡在拉镜像上：

> **环境提示**：这一步是**为离线/受限网络环境**准备的。如果你的节点能直连
> `reg.kyverno.io`（或 `ghcr.io`），可以**跳过本节**，直接进入 3.3；拉镜像的工作
> 交给 `helm install` 即可。另外该循环是**顺序**执行，6 个镜像首次可能超过 15 分钟，别中断。

```bash
for img in kyverno kyvernopre background-controller cleanup-controller reports-controller readiness-checker; do
  vagrant ssh k3s-demo-agent-1 -- "sudo k3s ctr images pull reg.kyverno.io/kyverno/$img:v1.19.1"
done
```

> `vagrant` 命令必须在**仓库根目录 `~/k3s-ops`** 执行（Vagrantfile 在仓库根）。
> 首次拉取较慢（单个可超过 2 分钟），耐心等 `unpacking` 结束。

### 3.3 helm 安装（钉在 agent-1）

```bash
helm install kyverno kyverno/kyverno -n kyverno --create-namespace \
  --set global.nodeSelector."kubernetes\.io/hostname"=k3s-demo-agent-1 \
  --wait --timeout 10m
```

实测（节选）：

```text
Chart version: 3.9.1
Kyverno version: v1.19.1

The following components have been installed in your cluster:
- CRDs
- Admission controller
- Reports controller
- Cleanup controller
- Background controller

⚠️  WARNING: The legacy kyverno.io policy types are deprecated and will be removed in a future release.
    Migrate to their policies.kyverno.io replacements:
    - ClusterPolicy / Policy → ValidatingPolicy, MutatingPolicy, GeneratingPolicy, ImageValidatingPolicy
```

那条 warning 就是第 2 节说的迁移方向，**在安装时就会被明确警告**。

### 3.4 验证就绪

```bash
kubectl --kubeconfig ./kubeconfig get pods -n kyverno -o wide
kubectl --kubeconfig ./kubeconfig get crd | grep -ci kyverno
```

实测输出：

```text
NAME                                             READY   STATUS    RESTARTS   AGE   IP            NODE
kyverno-admission-controller-695bb65876-j47sd    1/1     Running   0          85s   10.42.1.195   k3s-demo-agent-1
kyverno-background-controller-754d5d8744-rlp4q   1/1     Running   0          85s   10.42.1.194   k3s-demo-agent-1
kyverno-cleanup-controller-5df7946f7-sctx7       1/1     Running   0          85s   10.42.1.193   k3s-demo-agent-1
kyverno-reports-controller-bbd7b5c48-d2tvj       1/1     Running   0          85s   10.42.1.192   k3s-demo-agent-1
20
```

四个 Pod 全部调度到 `k3s-demo-agent-1`（`nodeSelector` 生效），新增 **20 个 CRD**。

Kyverno 还装了一个 `kyverno-pre` **initContainer**（就是上面预拉的 `kyvernopre` 镜像），
以及一批 **Webhook 配置**（后面"排障"要用）：

```bash
kubectl --kubeconfig ./kubeconfig get validatingwebhookconfiguration,mutatingwebhookconfiguration | grep -i kyverno
```

```text
validatingwebhookconfiguration/kyverno-policy-validating-webhook-cfg          1
validatingwebhookconfiguration/kyverno-resource-validating-webhook-cfg        0
validatingwebhookconfiguration/kyverno-cleanup-validating-webhook-cfg         1
validatingwebhookconfiguration/kyverno-exception-validating-webhook-cfg       1
validatingwebhookconfiguration/kyverno-cel-exception-validating-webhook-cfg   1
validatingwebhookconfiguration/kyverno-global-context-validating-webhook-cfg  1
validatingwebhookconfiguration/kyverno-ttl-validating-webhook-cfg             1
mutatingwebhookconfiguration/kyverno-policy-mutating-webhook-cfg              1
mutatingwebhookconfiguration/kyverno-resource-mutating-webhook-cfg            0
mutatingwebhookconfiguration/kyverno-verify-mutating-webhook-cfg              1
```

> 那些 `0` 的是给 **CEL 版策略**（`ValidatingPolicy` 等）留的 webhook——因为你还没写这类策略，
> 所以规则数为 0。这从侧面印证了"新旧两套策略并存"。

---

## 4. validate 策略实测（Enforce）

先准备目录（**不要放进仓库**）。注意布局：**策略放 `policies/` 子目录，测试资源放外层**
（原因见第 8 节：官方 CLI 传给 `apply` 的目录里**只能有策略文件**）：

```bash
mkdir -p ~/kyverno-policies/policies
cd ~/kyverno-policies
```

### 4.1 策略一：Pod 必须带 `team` 标签（Enforce）

```yaml
# ~/kyverno-policies/policies/require-team-label.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-team-label
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: check-team-label
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - policy-demo
      validate:
        message: "Pod 必须带有非空的 team 标签（例如 team=platform）"
        pattern:
          metadata:
            labels:
              team: "?*"
```

要点：
- **`metadata.name`** = 策略名（cluster-scoped，注意别和别的策略重名）；
- **`match.any[].resources`** 决定"管谁"——这里限定命名空间 `policy-demo`，**避免误伤系统组件**；
- **`validationFailureAction: Enforce`** = 不合规直接拒绝；`pattern` 里 `"?*"` 表示"非空字符串"。

### 4.2 策略二：禁止 `:latest` 镜像（Enforce）

```yaml
# ~/kyverno-policies/policies/disallow-latest-tag.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-latest-tag
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: check-image-tag
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - policy-demo
      validate:
        message: "镜像不能使用 :latest 标签，请固定到具体版本（如 nginx:1.27）"
        pattern:
          spec:
            containers:
              - name: "*"
                image: "!*:latest"
```

要点：**取反匹配**用 `"!*:latest"`——"镜像不能匹配 `*:latest`"。
这正是 PSA 表达不了的规则（PSA 只管安全上下文，不管镜像标签）。

### 4.3 策略三：必须设 `requests` 与 `limits`（Audit）

```yaml
# ~/kyverno-policies/policies/require-resources-audit.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-resources
spec:
  validationFailureAction: Audit        # 注意：Audit，不是 Enforce
  background: true
  rules:
    - name: check-resources
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - policy-demo
      validate:
        message: "容器必须同时设置 resources.requests 与 resources.limits"
        pattern:
          spec:
            containers:
              - name: "*"
                resources:
                  requests: "*"   # 只要 requests 存在即可（内部键不限）
                  limits: "*"     # 只要 limits 存在即可
```

> **`Enforce` vs `Audit`**：`Enforce` 走 Webhook，不合规**写不进 etcd**；
> `Audit` 不拦，只在后台扫描后记进 PolicyReport。新策略上线一般**先 Audit 观察，再转 Enforce**。

### 4.4 应用并确认就绪

```bash
# 若命名空间已存在，kubectl 会报 AlreadyExists；末尾 `|| true` 吞掉非零退出，保证可重复执行
kubectl --kubeconfig ./kubeconfig create namespace policy-demo || true
kubectl --kubeconfig ./kubeconfig apply \
  -f ~/kyverno-policies/policies/require-team-label.yaml \
  -f ~/kyverno-policies/policies/disallow-latest-tag.yaml \
  -f ~/kyverno-policies/policies/require-resources-audit.yaml
kubectl --kubeconfig ./kubeconfig get clusterpolicy
```

实测输出：

```text
namespace/policy-demo created
clusterpolicy.kyverno.io/require-team-label created
clusterpolicy.kyverno.io/disallow-latest-tag created
clusterpolicy.kyverno.io/require-resources created

NAME                  ADMISSION   BACKGROUND   READY   AGE   MESSAGE
disallow-latest-tag   true        true         True    7s    Ready
require-resources     true        true         True    7s    Ready
require-team-label    true        true         True    8s    Ready
```

`ADMISSION=true`（准入生效）、`BACKGROUND=true`（能后台扫描）、`READY=True`（策略本身合法）。

### 4.5 验证 Enforce：拦截与放行

```bash
# 1) 不带 team 标签 → 期望被 require-team-label 拦
kubectl --kubeconfig ./kubeconfig -n policy-demo run bad-no-label \
  --image=nginx:1.27 --restart=Never --dry-run=server -o yaml

# 2) 带 team 标签但用 :latest → 期望被 disallow-latest-tag 拦
kubectl --kubeconfig ./kubeconfig -n policy-demo run bad-latest \
  --image=nginx:latest --labels=team=platform --restart=Never --dry-run=server -o yaml

# 3) 合规 → 期望创建成功
kubectl --kubeconfig ./kubeconfig -n policy-demo run good \
  --image=nginx:1.27 --labels=team=platform --restart=Never
```

实测输出（前两条报错，第三条成功）：

```text
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/policy-demo/bad-no-label was blocked due to the following policies

require-team-label:
  check-team-label: 'validation error: Pod 必须带有非空的 team 标签（例如 team=platform）. rule check-team-label failed at path /metadata/labels/team/'

Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/policy-demo/bad-latest was blocked due to the following policies

disallow-latest-tag:
  check-image-tag: 'validation error: 镜像不能使用 :latest 标签，请固定到具体版本（如 nginx:1.27）. rule check-image-tag failed at path /spec/containers/0/image/'

pod/good created
```

> `--dry-run=server` 会真的走一遍准入 Webhook（只是不落库），所以能精确复现"会不会被拦"，
> 非常适合放进 CI 或本地验证。

---

## 5. mutate 策略实测

`mutate` 在准入阶段**改写**对象。下面这条策略干两件事：
给 Pod 补 `managed-by=kyverno` 标签，并给未显式设置安全上下文的 Pod 补 `runAsNonRoot: true`（呼应第 39 章）。

```yaml
# ~/kyverno-policies/policies/add-managed-by-label.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-managed-by-label
spec:
  rules:
    - name: add-label-and-securitycontext
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - policy-demo
      mutate:
        patchStrategicMerge:
          metadata:
            labels:
              managed-by: kyverno
          spec:
            securityContext:
              runAsNonRoot: true
```

应用并建一个 Pod：

```bash
kubectl --kubeconfig ./kubeconfig apply -f ~/kyverno-policies/policies/add-managed-by-label.yaml
kubectl --kubeconfig ./kubeconfig -n policy-demo run mutated \
  --image=nginx:1.27 --labels=team=platform --restart=Never
kubectl --kubeconfig ./kubeconfig -n policy-demo get pod mutated -o jsonpath='{.metadata.labels.managed-by}{"\n"}'
kubectl --kubeconfig ./kubeconfig -n policy-demo get pod mutated -o jsonpath='{.spec.securityContext.runAsNonRoot}{"\n"}'
```

实测输出：

```text
clusterpolicy.kyverno.io/add-managed-by-label created
pod/mutated created
kyverno
true
```

也就是说，你**从没写过**这两个字段，但 Pod 上真的出现了它们——**mutate 生效了**。

### 5.1 真实踩坑：mutate 把 Pod "改坏了"

上面那个 `mutated` Pod 其实**起不来**。用 `nginx:1.27` 时它是这样的：

```text
$ kubectl --kubeconfig ./kubeconfig -n policy-demo describe pod mutated
  Warning  Failed  ...  kubelet  spec.containers{mutated}: Error: container has runAsNonRoot and image will run as root
```

Pod 卡在 `CreateContainerConfigError`。原因是：

- 策略注入了 `runAsNonRoot: true`；
- 但官方 `nginx:1.27` 镜像**默认以 root（UID 0）运行**；
- kubelet 一看"要求非 root，镜像却是 root"，直接拒绝启动。

**这不是策略写错了，而是 mutate 的威力与风险**：它会改写工作负载，可能和"本来不兼容的镜像"冲突。

修法二选一：

1. 换一个**本来就以非 root 运行**的镜像（推荐）；
2. 在策略/工作负载里额外指定 `runAsUser`，或干脆不放宽 `runAsNonRoot`。

我们换成 `nginxinc/nginx-unprivileged:1.27`（该镜像以 UID 101 运行、监听 8080，本章环境已有缓存）：

> **环境回退**：如果你的节点拉不到 `nginxinc/nginx-unprivileged`，可以任选其一：
> 换成其他**本身就是非 root** 的镜像；或仍用 `nginx:1.27` 但在 Pod 上显式加
> `spec.securityContext.runAsUser: 101` 配合 `runAsNonRoot: true`。
> 关键是"镜像的用户"和"`runAsNonRoot` 的要求"必须一致。

```bash
kubectl --kubeconfig ./kubeconfig -n policy-demo delete pod mutated
kubectl --kubeconfig ./kubeconfig -n policy-demo run mutated \
  --image=nginxinc/nginx-unprivileged:1.27 --labels=team=platform --restart=Never

kubectl --kubeconfig ./kubeconfig -n policy-demo get pod mutated -o jsonpath='{.spec.securityContext.runAsNonRoot}{"\n"}'
kubectl --kubeconfig ./kubeconfig -n policy-demo exec mutated -- id
```

实测输出：

```text
pod "mutated" deleted from policy-demo namespace
pod/mutated created
true
uid=101(nginx) gid=101(nginx) groups=101(nginx)
```

`uid=101` 证明确实以非 root 运行，`runAsNonRoot: true` 的注入也满足了。

---

## 6. generate 策略实测

`generate` 按触发条件**自动生成下游资源**。这里呼应第 35 章：
**新建一个命名空间，就自动给它配一条"默认拒绝"的 NetworkPolicy。**

```yaml
# ~/kyverno-policies/policies/generate-default-networkpolicy.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: generate-default-networkpolicy
spec:
  rules:
    - name: gen-default-deny
      match:
        any:
          - resources:
              kinds:
                - Namespace
              selector:
                matchLabels:
                  policy-demo: "true"
      generate:
        synchronize: true           # 策略改了/被删，下游跟着同步
        generateExisting: false     # 只对新对象生效，便于干净演示
        apiVersion: networking.k8s.io/v1
        kind: NetworkPolicy
        name: default-deny
        namespace: "{{ request.object.metadata.name }}"
        data:
          spec:
            podSelector: {}
            policyTypes:
              - Ingress
              - Egress
```

`match` 用**标签选择器**挑命名空间（而不是写死名字），所以"以后所有打了 `policy-demo=true` 的新命名空间"都会命中。

应用并演示"新建即生成"：

```bash
kubectl --kubeconfig ./kubeconfig apply -f ~/kyverno-policies/policies/generate-default-networkpolicy.yaml
kubectl --kubeconfig ./kubeconfig label namespace policy-demo policy-demo=true --overwrite
kubectl --kubeconfig ./kubeconfig create namespace policy-demo-gen || true
kubectl --kubeconfig ./kubeconfig label namespace policy-demo-gen policy-demo=true --overwrite
sleep 10
kubectl --kubeconfig ./kubeconfig -n policy-demo-gen get networkpolicy
```

实测输出：

```text
clusterpolicy.kyverno.io/generate-default-networkpolicy created
namespace/policy-demo labeled
namespace/policy-demo-gen created
namespace/policy-demo-gen labeled

NAME           POD-SELECTOR   AGE
default-deny   <none>         12s
```

**我们没写任何 NetworkPolicy，是 Kyverno 生成的。** 看它的元数据就知道出处：

```bash
kubectl --kubeconfig ./kubeconfig -n policy-demo-gen get networkpolicy -o yaml
```

实测输出（节选）：

```yaml
metadata:
  labels:
    app.kubernetes.io/managed-by: kyverno
    generate.kyverno.io/policy-name: generate-default-networkpolicy
    generate.kyverno.io/rule-name: gen-default-deny
    generate.kyverno.io/trigger-kind: Namespace
    generate.kyverno.io/trigger-uid: ee1a3a03-94d8-411a-9cc2-1fd96fbdb8c2
  name: default-deny
  namespace: policy-demo-gen
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
```

`generate.kyverno.io/*` 标签记录了"由哪个策略、哪条规则、被谁触发"——这就是**所有权**，
`synchronize: true` 时 Kyverno 会据此保持下游与策略一致。

---

## 7. Audit 模式与 PolicyReport

第 4 节的 `require-resources` 是 **Audit** 模式：它不拦 Pod，只把结果写进 **PolicyReport**。

`good` 这个 Pod（第 4 节创建）带了 `team` 标签、用 `nginx:1.27`，但**没设 resources**。
先看这个命名空间里的全部报告：

```bash
kubectl --kubeconfig ./kubeconfig -n policy-demo get policyreport
```

实测输出：

```text
NAME                                   KIND   NAME      PASS   FAIL   WARN   ERROR   SKIP   AGE
841c6e66-3802-4cf4-8eac-1ddb70502321   Pod    mutated   3      1      0      0       0      2m19s
98e07f6e-fd0e-4354-91a5-19c89bfdf15a   Pod    good      2      1      0      0       0      2m42s
```

`good` 是 `PASS=2`（过了标签与镜像两条）、`FAIL=1`（没过 resources）。
另一个 `mutated`（第 5 节创建）是 `PASS=3`——它比 `good` **多一条**，多出来的正是
`add-managed-by-label` 这条 **mutate** 策略记的 `pass`：**mutate 生效时也会在报告里留一条记录**。

> 为什么 `good` 没有那条 mutate 记录？因为 `good` 在 mutate 策略**应用之前**就创建了，
> 而报告记录的是"**对象写入时**匹配到的策略结果"；后台重扫间隔默认 **1 小时**
> （`--backgroundScanInterval=1h`），所以一节课的时间里 `good` 的报告不会变。

看 `good` 的细节：

```bash
kubectl --kubeconfig ./kubeconfig -n policy-demo get policyreport -o yaml
```

实测输出（节选 `good` 的结果）：

```yaml
results:
- message: validation rule 'check-image-tag' passed.
  policy: disallow-latest-tag
  result: pass
  rule: check-image-tag
- message: 'validation error: 容器必须同时设置 resources.requests 与 resources.limits.
    rule check-resources failed at path /spec/containers/0/resources/'
  policy: require-resources
  result: fail
  rule: check-resources
- message: validation rule 'check-team-label' passed.
  policy: require-team-label
  result: pass
  rule: check-team-label
summary:
  fail: 1
  pass: 2
```

每条结果都带 `policy`（策略名）、`rule`（规则名）、`result`、`message`，能直接定位"哪条规则、哪个字段"。

再对照一个**合规**的 Pod（有 requests+limits）：

```bash
kubectl --kubeconfig ./kubeconfig -n policy-demo run good-resources --image=nginx:1.27 \
  --labels=team=platform --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"good-resources","image":"nginx:1.27","resources":{"requests":{"cpu":"100m"},"limits":{"cpu":"200m"}}}]}}'
```

实测该 Pod 的报告是：

```yaml
scope:
  kind: Pod
  name: good-resources
summary:
  fail: 0
  pass: 4
```

`pass: 4` —— 四条全过（三个 validate 策略 + `add-managed-by-label` 的 mutate）。
**这就验证了 Audit 策略在两个方向上都正确**：缺 resources 记 `fail`，有 resources 记 `pass`。

> **报告的归属**：PolicyReport 是 namespaced 的（每条对应一个对象，名字是一串 UUID，**每次重建都不同**，
> 阅读时只需关注 `KIND`/`NAME` 列）；集群级对象（如 Namespace）的汇总报告是 `ClusterPolicyReport`。
> 报告由 reports-controller 聚合。

---

## 8. 用 Kyverno CLI 离线测试策略

策略改完总想先验证，但**不想把没验证的策略推到集群**。Kyverno 提供了官方 CLI，可以**完全离线**跑
`validate`/`mutate`，非常适合进 CI。

先写一个"故意多处违规"的测试资源：

```yaml
# ~/kyverno-policies/cli-resource.yaml
apiVersion: v1
kind: Pod
metadata:
  name: cli-test
  namespace: policy-demo
  labels:
    team: platform
spec:
  containers:
    - name: app
      image: nginx:latest      # 故意 :latest
                               # 故意不写 resources
```

用官方 CLI 容器跑（挂载整个 `~/kyverno-policies`，`apply` 指向**只含策略的** `policies/` 子目录）：

```bash
docker run --rm -v ~/kyverno-policies:/p \
  ghcr.io/kyverno/kyverno-cli:v1.19.1 \
  apply /p/policies --resource /p/cli-resource.yaml
```

实测输出（节选）：

```text
Applying 13 policy rule(s) to 1 resource(s)...

policy disallow-latest-tag -> resource policy-demo/Pod/cli-test failed:
1 - check-image-tag validation error: 镜像不能使用 :latest 标签，请固定到具体版本（如 nginx:1.27）. rule check-image-tag failed at path /spec/containers/0/image/
policy require-resources -> resource policy-demo/Pod/cli-test failed:
1 - check-resources validation error: 容器必须同时设置 resources.requests 与 resources.limits. rule check-resources failed at path /spec/containers/0/resources/

Mutation:
Mutation has been applied successfully.

pass: 2, fail: 2, warn: 0, error: 0, skip: 0
```

注意三件事：

1. **完全不连集群**：策略、资源都是本地文件，结果和集群内实测一致（`fail: 2`）。
2. **mutate 也会生效**：CLI 输出的资源里可以看到 `labels.managed-by: kyverno` 与
   `securityContext.runAsNonRoot: true`，说明 `mutate` 被离线模拟了。
3. **目录里只放策略**：官方 CLI 传给 `apply` 的目录若混入非策略文件，会报 `Applying 0 policy rule(s)`。
   所以本节的布局就是**策略放 `policies/` 子目录、测试资源放外层**：

```bash
# ~/kyverno-policies/policies/*.yaml   ← 只放策略
# ~/kyverno-policies/cli-resource.yaml ← 测试资源
docker run --rm -v ~/kyverno-policies:/p \
  ghcr.io/kyverno/kyverno-cli:v1.19.1 \
  apply /p/policies --resource /p/cli-resource.yaml
```

> CLI 对 legacy 策略会逐文件打印 deprecation warning；这是提示你迁移到 CEL 版，
> **不影响本次离线判定**。

---

## 9. 与 PSA 的分层与顺序、failurePolicy、常见坑

### 9.1 分层：PSA 和 Kyverno 各管一段

两者**不是替代关系，是叠加关系**，都在准入链上，但关注点不同：

| 维度 | PSA（第 39 章） | Kyverno |
|---|---|---|
| 执行者 | kube-apiserver **内置** | 外部 Webhook（Kyverno 控制器） |
| 规则来源 | 固定三档 | 你写的 YAML |
| 能力 | 只拒绝 | 拒绝（validate）+ 改写（mutate）+ 生成（generate） |
| 依赖 | 无（always-on） | 控制器不可用时受 `failurePolicy` 影响 |
| 适用 | 兜底安全基线 | 组织规范、合规、自动化 |

**推荐分层**：用 **PSA 做兜底基线**（比如整个集群 `baseline`，业务命名空间 `restricted`），
再用 **Kyverno 表达 PSA 表达不了的规范**（镜像来源、标签规范、必须 set resources、自动配 NetworkPolicy）。

### 9.2 顺序：mutate 先，validate 后

准入链里 **Mutating Webhook 先执行、Validating Webhook 后执行**。所以：

- Kyverno 的 `mutate` 会先改对象；
- 之后 `validate`（包括 PSA）看到的是**改过之后**的对象。

这解释了一个常见困惑："我的 mutate 补了 `team` 标签，为什么 require-team-label 还是不过？"——
如果两条策略的匹配范围/顺序没对上，或被别的东西覆盖，就可能出现"补了又不符合"。**策略要当成一个整体设计**。

### 9.3 failurePolicy：Kyverno 挂了会怎样

查看 webhook 的 `failurePolicy`：

```bash
kubectl --kubeconfig ./kubeconfig get validatingwebhookconfiguration kyverno-policy-validating-webhook-cfg \
  -o jsonpath='{range .webhooks[*]}{.name}{" failurePolicy="}{.failurePolicy}{"\n"}{end}'
```

实测输出：

```text
validate-policy.kyverno.svc failurePolicy=Fail
```

**`failurePolicy=Fail` 的含义**：如果 Kyverno 的准入服务**不可达**，
那么匹配到该 webhook 的请求**会被拒绝**（而不是放行）。这是"安全默认"，但也意味着：

- Kyverno 全挂 → 相关命名空间的 Pod/对象的**写入会被拦**；
- 本章把 4 个控制器都钉在**唯一的工作节点 agent-1**，单点风险更高。

生产建议：多副本 + 反亲和、`failurePolicy` 按策略重要性取舍、做好监控告警。

---

## 10. 排障清单（含逃生与卸载）

### 10.1 策略没生效

1. `kubectl get clusterpolicy` 看 `READY`——若 `False`，`MESSAGE` 会写原因（多半是 YAML 结构错）。
2. 看 `match` 是否真的命中：策略限定 `namespaces: [policy-demo]`，在别的命名空间测试当然不生效。
3. `Enforce` 才拦人；`Audit` 只写报告。确认 `validationFailureAction`。
4. 资源类型是否匹配：`kinds: [Pod]` 不匹配 `Deployment`（你要么改成 `Deployment`，要么给 Pod 模板加策略）。

### 10.2 PolicyReport 为空

1. `background: true` 才做后台扫描；关掉就只有准入时的即时结果。
2. 报告由 reports-controller 聚合，**给它几秒**。
3. 命名空间对不对：报告在**对象所在命名空间**里。

### 10.3 被 Kyverno 误拦（比如装东西装不进去）

先确认是谁拦的——错误信息里会写**策略名 + 规则名**。临时放行有三条路：

- **加 `PolicyException`**（推荐，可审计）：显式豁免某个对象，而不是关掉整条策略；
- 把该策略临时改成 `Audit`；
- 用下面的"逃生"彻底摘掉准入。

### 10.4 逃生：策略把集群拦死了怎么办（**已实测**）

> **关键陷阱**：Kyverno 的准入控制器会**自愈重建自己的 Webhook 配置**。
> 实测：只删 Webhook，15 秒内 7 个 validating + 3 个 mutating 全部重建、拦截立刻恢复。
> 所以**必须两步都做，且顺序不能反**。

```bash
# 第 1 步：先把会重建 Webhook 的控制器全部停掉（缩到 0）
kubectl --kubeconfig ./kubeconfig -n kyverno scale deploy --all --replicas=0

# 第 2 步：再删除 Kyverno 的 Webhook 配置（此时没人再重建它们）
kubectl --kubeconfig ./kubeconfig delete validatingwebhookconfiguration,mutatingwebhookconfiguration \
  -l webhook.kyverno.io/managed-by=kyverno
```

实测效果：Webhook 数变为 `0/0` 且不再重建；原本被拦的 Pod 现在**放行**：

```text
$ kubectl --kubeconfig ./kubeconfig -n policy-demo run escape-test --image=nginx:latest --restart=Never --dry-run=server -o yaml
apiVersion: v1
kind: Pod
metadata:
  name: escape-test
  namespace: policy-demo
...
  -> exit=0
```

**恢复**（放行完再放回去）：

```bash
kubectl --kubeconfig ./kubeconfig -n kyverno scale deploy --all --replicas=1
kubectl --kubeconfig ./kubeconfig -n kyverno rollout status deploy --timeout=180s
# 控制器起来后会自愈重建 Webhook：validate 回到 7 个、mutate 回到 3 个
kubectl --kubeconfig ./kubeconfig get validatingwebhookconfiguration | grep -ci kyverno   # 期望 7
kubectl --kubeconfig ./kubeconfig get mutatingwebhookconfiguration  | grep -ci kyverno   # 期望 3
```

> **顺序为什么不能反**：如果先删 Webhook、不缩控制器，会被立刻重建；如果只缩控制器、
> 不删 Webhook，则 Webhook 端点不可达，而 `failurePolicy=Fail` → **反而会拦下所有相关请求**。

### 10.5 完整卸载 Kyverno

```bash
# 1) 先删演示资源（可选）
kubectl --kubeconfig ./kubeconfig delete namespace policy-demo policy-demo-gen

# 2) 用 helm 卸载（会连带删除控制器、Webhook 配置，以及 Kyverno 的 CRD）
helm uninstall kyverno -n kyverno

# 3) 删掉命名空间
kubectl --kubeconfig ./kubeconfig delete namespace kyverno

# 4) 确认 CRD 也已清理（Kyverno 的 CRD 由 release 管理，正常会被一并删除）
kubectl --kubeconfig ./kubeconfig get crd | grep -i kyverno || echo "NO_KYVERNO_CRD"

# 5) 可选：清理节点上预拉的镜像
for img in kyverno kyvernopre background-controller cleanup-controller reports-controller readiness-checker; do
  vagrant ssh k3s-demo-agent-1 -- "sudo k3s ctr images rm reg.kyverno.io/kyverno/$img:v1.19.1"
done
```

> 卸载会**连带删除所有 `ClusterPolicy` 及其生成的资源**，请先确认没有别的负载依赖它们。

---

## 11. Rancher 界面对照

| 路径 | 对应 kubectl | 用途 |
|---|---|---|
| **集群 → More Resources → kyverno.io → ClusterPolicies** | `kubectl --kubeconfig ./kubeconfig get clusterpolicy` | 看全部策略与 `Ready` 状态 |
| **ClusterPolicy 详情 → YAML** | `kubectl --kubeconfig ./kubeconfig get clusterpolicy <n> -o yaml` | 查看 `spec.rules`（match / validate / mutate / generate） |
| **集群 → More Resources → wgpolicyk8s.io → PolicyReports** | `kubectl --kubeconfig ./kubeconfig -n policy-demo get policyreport` | 看合规报告（pass/fail 计数） |
| **PolicyReport 详情 → YAML** | `kubectl --kubeconfig ./kubeconfig -n policy-demo get policyreport <n> -o yaml` | 逐条查看 `results`（policy/rule/result/message） |
| **集群 → Workloads（命名空间 `kyverno`）** | `kubectl --kubeconfig ./kubeconfig -n kyverno get deploy,pods` | 看 Kyverno 四个控制器 |
| **集群 → CRDs** | `kubectl --kubeconfig ./kubeconfig get crd | grep -i kyverno` | 看 Kyverno 注册的 20 个 CRD |
| **集群 → Events** | `kubectl --kubeconfig ./kubeconfig -n policy-demo get events` | 看 `PolicyViolation` 事件 |

> 提示：Kyverno 的策略和报告都是 **CRD**，所以在 Rancher 里它们落在 **More Resources** 下
> （按 API 组分目录），和第 42 章你自建的 `WebApps` 出现在同一个地方——
> 这再一次说明"Kyverno = 一堆 CRD + 控制器"。

---

## 动手练习

1. **Enforce vs Audit**：把 `require-resources` 改成 `Enforce`，会有什么变化？再改回去。
2. **取反匹配**：写一条策略，禁止 Pod 使用 `registry.example.com/` 之外来源的镜像，说明怎么表达"取反"。
3. **mutate 补默认值**：写一条 mutate，给没有 `spec.replicas` 的 Deployment 补 `replicas: 2`。
4. **PolicyException**：给 `policy-demo` 里某个特定 Pod 开一个 `PolicyException`，让它绕过 `require-team-label`。
5. **generate 同步**：把 `generate` 策略里的 NetworkPolicy 规则改一下（比如加一条 `Ingress` 允许），观察已生成的 `default-deny` 会不会跟着变。
6. **逃生演练**：用第 10.4 节的两步法摘掉准入，建一个"违规" Pod，再恢复，确认拦截回来。
7. **CLI 进 CI**：设想如何把第 8 节的 `kyverno apply` 做成一条 CI 检查（提示：命令有 `fail` 时退出码非 0）。

<details>
<summary>参考答案</summary>

1. 改成 `Enforce` 后，**没有 resources 的 Pod 会被直接拒绝**（不再只是记报告）。你可以自己试：
   之前能创建的 `good` 现在会报 `require-resources: check-resources ... failed at path /spec/containers/0/resources/`。
   这演示了"先 Audit 观察、再 Enforce 收口"的落地节奏。
2. 用取反匹配：

   ```yaml
   validate:
     pattern:
       spec:
         containers:
           - name: "*"
             image: "!registry.example.com/*"
   ```
   `"!..."` 表示"不能匹配"。若要允许多个域名，可结合 `any` 多条规则。
3. ```yaml
   mutate:
     patchStrategicMerge:
       spec:
         replicas: 2
   ```
   注意默认值只在**字段缺失**时补；已有 `replicas` 时按 strategic-merge 语义处理（`patchStrategicMerge` 会合并而非覆盖已有标量以外的场景，必要时用 `+(replicas): 2` 的条件语法）。
4. ```yaml
   apiVersion: kyverno.io/v2
   kind: PolicyException
   metadata:
     name: allow-no-team
     namespace: policy-demo
   spec:
     exceptions:
       - policyName: require-team-label
         ruleNames:
           - check-team-label
     match:
       any:
         - resources:
             kinds:
               - Pod
             names:
               - special-pod
   ```
   `PolicyException` 默认是**关闭**的（安装时提示 `PolicyExceptions are disabled by default`），
   需在安装/升级时开启 `--set features.policyExceptions.enabled=true` 才生效。
5. 会变。`synchronize: true` 时 Kyverno 监听策略变更并**把下游改成与策略一致**；
   把它改成 `false` 则"生成后就不管了"。你可以改完 `sleep` 几秒再 `get networkpolicy -o yaml` 观察。
6. 见第 10.4 节。顺序要点：**先缩控制器、再删 Webhook**；恢复时**缩回控制器**即可。
7. 大致如下（有 fail 时 `kyverno apply` 退出码为 1，CI 据此判失败）：

   ```bash
   docker run --rm -v "$PWD/policies:/p" -v "$PWD/tests:/t" \
     ghcr.io/kyverno/kyverno-cli:v1.19.1 \
     apply /p --resource /t/example.yaml
   # 退出码 0 = 全部合规；非 0 = 有策略未通过或执行错误
   ```

</details>

---

## 附录：本章真实采集片段与清理

**采集环境**：k3s `v1.30.2+k3s2`，节点 `k3s-demo-server-1`（192.168.56.10）与
`k3s-demo-agent-1`（192.168.56.20）；kubectl `v1.37.1`。
Kyverno chart `3.9.1` / appVersion `v1.19.1`，命名空间 `kyverno`，四个控制器钉在 `k3s-demo-agent-1`，
镜像来自 `reg.kyverno.io`（6 个镜像已预拉）。

**1. 安装前**：无任何 kyverno CRD（`NO_KYVERNO_CRD`），CRD 总数 132。

**2. 安装后**：4 个 Deployment 均 `1/1`；新增 **20 个 Kyverno CRD**；
Webhook 配置 7 个 validating + 3 个 mutating；`failurePolicy=Fail`。

**3. 三类策略实测**：

```text
validate(Enforce)：bad-no-label → 拦（require-team-label）
                   bad-latest   → 拦（disallow-latest-tag）
                   good         → 放行
validate(Audit)  ：good（无 resources）        → PolicyReport pass:2 fail:1
                   good-resources（有 limits） → PolicyReport pass:4 fail:0
mutate           ：nginx:1.27 → CreateContainerConfigError（runAsNonRoot vs root 镜像）
                   nginx-unprivileged:1.27 → Running，uid=101，managed-by=kyverno
generate         ：新命名空间 policy-demo-gen 自动获得 default-deny NetworkPolicy
```

**4. CLI 离线测试**：`pass: 2, fail: 2`（与集群内一致），离线 mutation 生效。

**5. 逃生实测**：缩控制器 + 删 Webhook → 放行；缩回控制器 → Webhook 自愈（7/3）、拦截恢复。

**本章创建的资源：**

- 命名空间 `kyverno`：4 个控制器 Deployment + 20 个 CRD + Webhook 配置 + 各种 Service；
- `ClusterPolicy`：`require-team-label`、`disallow-latest-tag`、`require-resources`、
  `add-managed-by-label`、`generate-default-networkpolicy`；
- 命名空间 `policy-demo`：Pod `good` / `good-resources` / `mutated`；
- 命名空间 `policy-demo-gen`：由 generate 策略生成的 `default-deny` NetworkPolicy。

**清理（保留 Kyverno，只清理演示）：**

```bash
kubectl --kubeconfig ./kubeconfig delete namespace policy-demo policy-demo-gen
kubectl --kubeconfig ./kubeconfig delete clusterpolicy require-team-label disallow-latest-tag \
  require-resources add-managed-by-label generate-default-networkpolicy
```

**完整卸载 Kyverno：** 见第 10.5 节。

> Kyverno 属于本项目的常驻组件，已记入 `AGENTS.md`；本章策略以代码块形式给出，
> **不新增仓库目录**（演示文件放 `~/kyverno-policies/`）。
