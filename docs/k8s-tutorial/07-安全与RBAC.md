# 07 安全与 RBAC：谁有资格碰集群

## 本章目标

- 理解 K8s 安全四步：认证（你是谁）→ 授权（你能干啥）→ 准入（额外检查）
- 理解 ServiceAccount（Pod 的身份）
- 掌握 RBAC 四件套：Role / ClusterRole / RoleBinding / ClusterRoleBinding 及其区别
- 会用 `kubectl auth can-i` 验证权限、会用 `--as` 模拟他人权限

---

## 1. 安全模型总览

对 K8s 来说，每个请求都要过三道关：

```text
请求 (kubectl / Pod / 组件)
   │
   ▼
① 认证 Authentication：你是谁？
   ├─ 用户：X.509 证书 / token / 账号（本环境 kubeconfig 里的 client-certificate）
   └─ Pod 内进程：ServiceAccount token
   │
   ▼
② 授权 Authorization：你被允许干什么？（RBAC 规则判断）
   │
   ▼
③ 准入控制 Admission：额外策略（配额、安全上下文等）
   │
   ▼
写 etcd / 执行
```

**核心认知：Pod 不是「匿名」的** —— Pod 里的进程以 **ServiceAccount** 身份访问 API Server。每个命名空间自动有一个 `default` 账户；Pod 可以不指定 SA，那就用 default。

## 2. RBAC 核心概念

RBAC（Role-Based Access Control，基于角色的访问控制）用四个资源描述权限：

| 资源 | 作用域 | 作用 |
|------|--------|------|
| **Role** | 单个命名空间 | 定义「在这个 ns 里能对哪些资源做什么」 |
| **ClusterRole** | 全集群 | 定义集群级权限（节点、PV、所有 ns 的 pods）或跨 ns 复用 |
| **RoleBinding** | 单个命名空间 | 把 Role/ClusterRole 绑定给用户/SA（只在该 ns 生效） |
| **ClusterRoleBinding** | 全集群 | 把 ClusterRole 绑定给用户/SA（全集群生效） |

关系一句话：

```text
Role 说「能做什么」；Binding 说「谁能用」
```

权限描述的三要素（rules）：

```yaml
rules:
  - apiGroups: [""]                     # API 分组（"" = 核心组）
    resources: ["pods", "pods/log"]     # 资源
    verbs: ["get", "list", "watch"]     # 动作
```

**最小权限原则**：只给完成工作所需的权限（如只读日志就不给 delete）。

## 3. 本集群实站对照

### 3.1 查看已有的 ServiceAccount

```bash
kubectl -n lab get sa
```

预期输出（每个 ns 都自动有 default）：

```text
NAME      SECRETS   AGE
default   0         44m
```

### 3.2 创建 ServiceAccount 和 Role、RoleBinding

三步走：

```bash
kubectl -n lab create sa lab-user
```

```text
serviceaccount/lab-user created
```

```yaml
# role.yaml —— 只允许读 lab 命名空间的 Pod 和 Pod 日志
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader
  namespace: lab
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list", "watch"]
```

```bash
kubectl apply -f role.yaml
```

```text
role.rbac.authorization.k8s.io/pod-reader created
```

```yaml
# rolebinding.yaml —— 把 pod-reader 角色授予 lab-user 这个 SA
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: lab-user-read-pods
  namespace: lab
subjects:
  - kind: ServiceAccount
    name: lab-user
    namespace: lab
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f rolebinding.yaml
```

```text
rolebinding.rbac.authorization.k8s.io/lab-user-read-pods created
```

### 3.3 验证权限（kubectl auth can-i + --as 模拟身份）

`--as` 可以「冒充」某个身份测试权限，是排障和验证 RBAC 的利器：

```bash
# 用 lab-user 身份问：能在 lab ns 里 get pods 吗？
kubectl -n lab auth can-i get pods --as=system:serviceaccount:lab:lab-user
```

```text
yes
```

```bash
# 能删 pods 吗？（Role 里没有 delete → no）
kubectl -n lab auth can-i delete pods --as=system:serviceaccount:lab:lab-user
```

```text
no
```

```bash
# 能读 default 命名空间的 pods 吗？（Role 只限 lab → no）
kubectl auth can-i get pods --as=system:serviceaccount:lab:lab-user -n default
```

```text
no
```

三个结果完美展示了**命名空间隔离**和**最小权限**：读得到 lab 的 Pod、删不了、跨 namespace 也不行。

### 3.4 ClusterRole / ClusterRoleBinding：集群级只读

如果希望 lab-user 能读**所有命名空间**的 Pod，就需要集群级角色：

```yaml
# clusterrole.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cluster-pod-reader
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list", "watch"]
```

```bash
kubectl apply -f clusterrole.yaml
```

```yaml
# crb.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: lab-user-cluster-read
subjects:
  - kind: ServiceAccount
    name: lab-user
    namespace: lab
roleRef:
  kind: ClusterRole
  name: cluster-pod-reader
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f crb.yaml
```

再验证（现在跨 ns 可以了）：

```bash
kubectl auth can-i get pods --as=system:serviceaccount:lab:lab-user -n default
```

```text
yes
```

### 3.5 查看集群已有角色（理解「系统自己也在用 RBAC」）

```bash
kubectl get clusterrole | head -8
```

预期输出（节选，这一堆是 Rancher / Fleet / k3s 系统组件自己用的角色）：

```text
NAME                                    CREATED AT
admin                                   2026-05-25T10:17:52Z   ← kubeadm/k3s 内置的 admin
capi-aggregated-manager-role            2026-05-25T10:32:28Z
cattle-fleet-local-system-fleet-agent-role  2026-05-25T10:35:21Z   ← Rancher Fleet
cattle-globalrole-admin                 2026-05-25T10:16:32Z     ← Rancher 全局角色
```

这说明：**Rancher、Fleet 等组件都是通过 RBAC 管理权限的**，Rancher 界面里的「用户/角色」本质就是在操作这些 RBAC 对象。

```bash
kubectl -n lab get role,rolebinding
```

预期输出：

```text
NAME                                        CREATED AT
role.rbac.authorization.k8s.io/pod-reader   2026-10-03T01:07:48Z

NAME                                                       ROLE              AGE
rolebinding.rbac.authorization.k8s.io/lab-user-read-pods   Role/pod-reader   10s
```

### 3.6 用带授权身份的 kubeconfig 实际体验（进阶）

完整流程（可选实验）：为 SA 生成长期 token，构造受限 kubeconfig，体验「真账号登录后能做什么」。

```bash
# k8s v1.24+ 需要手动创建
kubectl -n lab create token lab-user --duration=1h > /tmp/lab-user.token
```

然后用该 token 替换 kubeconfig 的 token 字段，即可体验受限权限登录。

## 4. Rancher 界面对照

Rancher 的权限模型（全局角色/集群角色/项目角色）**映射到底层就是 RBAC**：
- Rancher → 右上角头像 → **Users & Authentication**：用户、全局权限
- 集群 → **Cluster → Members**：给用户分配集群角色（对应 ClusterRoleBinding）
- 集群 → **Projects/Namespaces** → 某项目的 **Members**：分配项目（ns）角色（对应 RoleBinding）
- **RBAC** 相关的原生对象也可在集群 → **RBAC** 页面看到

## 5. 小结

- 请求三关：认证（你是谁）→ 授权（能干啥）→ 准入（额外检查）
- Pod 的身份 = ServiceAccount；每个 ns 自动有 default
- Role 定权限、Binding 定归属；集群级用 ClusterRole + ClusterRoleBinding
- `kubectl auth can-i ... --as=<身份>` 是权限排障第一工具
- 最小权限原则永远适用

## 动手练习

1. 用 `--as` 验证 lab-user 能否 `get secrets`（预期 no）、能否 `list pods`（预期 yes）。
2. 新建另一个 SA `ops`，创建 ClusterRole `node-reader`（读 nodes）并绑定，验证跨集群资源的权限。
3. 删除 `pod-reader` 这个 Role 前先删绑定的 RoleBinding，观察删不掉的报错。
4. 用 `kubectl get rolebinding -A | head` 看集群里有多少现成的绑定时，找出 Rancher admin 相关的绑定。
5. 思考：为什么生产环境要给每个应用建独立 ServiceAccount 而不是都用 default？

<details>
<summary>参考答案</summary>

1. `kubectl -n lab auth can-i get secrets --as=system:serviceaccount:lab:lab-user` → no；`... list pods ...` → yes。
2. `kubectl create clusterrole node-reader --verb=get,list --resource=nodes`，再建 ClusterRoleBinding 绑定 ops，`kubectl auth can-i get nodes --as=system:serviceaccount:lab:ops` → yes。
3. Role 还被 RoleBinding 引用时 `kubectl delete role pod-reader` 会报 `...is referenced by RoleBinding...`（refused to delete），需先删 binding。
4. 示例 `kubectl get rolebinding -A | grep -i admin` 或看 cattle-* 的绑定。
5. 最小权限：default 通常权限未知/可能被集群策略放大；独立 SA + 专属 Role 可精确控制、可审计、可轮换，避免「一把钥匙开所有门」。
</details>