# 32 Rancher 多租户与 RBAC

## 本章目标

- 理解 Rancher 的多租户模型：**Global / Cluster / Project** 三个层级的权限边界
- 熟悉核心 CR：`Users`、`GlobalRoleBindings`、`ClusterRoleTemplateBindings`、`Projects`、`ProjectRoleTemplateBindings`、`RoleTemplates`
- 用 `kubectl` 直接读写 Rancher 管理对象，识别本集群现状（谁是全局管理员、各 Project 下有哪些 Namespace、谁拥有哪个 Project）
- 演示：新建用户 → 绑定到 Project（project-owner/project-member/project-readonly）→ 验证 Namespace 可见性
- 演示：用户加为集群级（cluster-owner/cluster-member）
- 掌握"命名空间归属"的判定方式（`field.cattle.io/projectId` 标签）与排障清单

> 本章所有输出均来自本集群（`kubectl --kubeconfig ./kubeconfig`）真实采集。

---

## 1. Rancher 多租户概念总览

Rancher 在纯 K8s RBAC 之上抽象出三类权限范围：

| 范围 | 说明 | 对应 CR |
|---|---|---|
| **Global（全局）** | 集群管理平台层面的权限（创建集群、管理用户、启用特性等） | `GlobalRoles`、`GlobalRoleBindings` |
| **Cluster（集群）** | 针对某个集群的集群级权限（节点管理、集群资源、查看集群等） | `ClusterRoleTemplateBindings`（绑定到 `RoleTemplate`） |
| **Project（项目）** | 将多个 Namespace 组织成一个"项目"，按项目做细粒度授权 | `Projects`、`ProjectRoleTemplateBindings` |

**RoleTemplate（角色模板）** 是 Rancher 定义的可复用权限模板，常用项目级：`project-owner`、`project-member`、`project-readonly`；集群级：`cluster-owner`、`cluster-member`、`cluster-admin`；全局：`admin`、`user` 等。

**Namespace 隶属**：Rancher 通过 Namespace 的标签 `field.cattle.io/projectId` 标记其归属项目（格式如 `p-2wztg`）。删除/移动 Namespace 的项目归属本质是改这个标签。

---

## 2. 本集群实站现状（真实采集）

### 2.1 Users（用户）

```bash
$ kubectl get users.management.cattle.io -o custom-columns='NAME:.metadata.name,USERNAME:.username,UID:.metadata.uid'
NAME           USERNAME   UID
u-b4qkhsnliz   <none>     8bcc6d48-d62c-4834-bdb4-51b8c02deb97
u-mo773yttt4   <none>     8e8647af-ef46-46f5-815a-13739489daa8
user-2j98p     admin      1e5e629f-de62-4ba6-b717-cb0bc2450a87
```

结论：当前集群中存在 3 个用户对象。其中 `user-2j98p` 的 `username` 为 `admin`。

### 2.2 GlobalRoleBindings（全局角色绑定）

```bash
$ kubectl get globalrolebindings.management.cattle.io -o custom-columns='NAME:.metadata.name,USER:.userName,ROLE:.globalRoleName'
NAME                      USER           ROLE
globalrolebinding-nzqrf   user-2j98p     admin
grb-nhtz2                 u-b4qkhsnliz   user
```

结论：`user-2j98p` 绑定全局角色 `admin`（平台全局管理员）。`u-b4qkhsnliz` 绑定全局角色 `user`（普通平台用户）。

### 2.3 Projects（项目）

```bash
$ kubectl get projects.management.cattle.io -A -o custom-columns='NAME:.metadata.name,NS:.metadata.namespace,BN:.status.backingNamespace,DESC:.spec.displayName'
NAME      NS      BN              DESC
p-2wztg   local   local-p-2wztg   My Project
p-8fd6k   local   p-8fd6k         Default
p-fr6vf   local   p-fr6vf         System
```

三个项目：
- `p-fr6vf`（System）：承载大多数系统命名空间（cattle-*、cert-manager、ingress-nginx、kube-* 等）
- `p-8fd6k`（Default）：`default` 命名空间所在项目
- `p-2wztg`（My Project）：用户自建项目，背后 backing Namespace 为 `local-p-2wztg`

### 2.4 Namespace 与 Project 归属（最关键）

用 `field.cattle.io/projectId` 判断归属：

```bash
$ kubectl get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.field\.cattle\.io/projectId}{"\n"}{end}' | sort | head -15
cattle-fleet-clusters-system	p-fr6vf
cattle-system	p-fr6vf
cert-manager	p-fr6vf
default	p-8fd6k
fleet-default	p-fr6vf
ingress-nginx	p-fr6vf
kube-system	p-fr6vf
mytest	p-2wztg
...
```

**真实结论**：`mytest` 命名空间归属于 `p-2wztg`（My Project）。系统类命名空间绝大多数归 `p-fr6vf`（System）。`default` 归 `p-8fd6k`（Default）。

也可以反查：`p-2wztg` 下实际有哪些 Namespace：

```bash
$ kubectl get ns -l field.cattle.io/projectId=p-2wztg
NAME     STATUS   AGE
mytest   Active   137d
```

### 2.5 ProjectRoleTemplateBindings（项目内 RBAC）

```bash
$ kubectl get projectroletemplatebindings.management.cattle.io -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,USER:.userName,ROLE:.roleTemplateName,PRJ:.projectName'
NS              NAME                    USER         ROLE            PRJ
local-p-2wztg   creator-project-owner   user-2j98p   project-owner   local:p-2wztg
```

只有一条绑定：`user-2j98p` 以 `project-owner` 身份绑定到项目 `local:p-2wztg`（即 `p-2wztg`）。

### 2.6 ClusterRoleTemplateBindings（集群级 RBAC）

```bash
$ kubectl get clusterroletemplatebindings.management.cattle.io -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,USER:.userName,ROLE:.roleTemplateName,CLUSTER:.clusterName'
NS      NAME                      USER           ROLE            CLUSTER
local   local-fleet-local-owner   u-mo773yttt4   cluster-owner   local
local   u-b4qkhsnliz-admin        u-b4qkhsnliz   cluster-owner   local
```

两个集群级绑定：
- `u-mo773yttt4` → `cluster-owner`（对集群 `local` 拥有集群所有者权限）
- `u-b4qkhsnliz` → `cluster-owner`（对集群 `local` 拥有集群所有者权限）

注意：`user-2j98p` 虽是全局 `admin`，但本表中并未列出其 `clusterroletemplatebindings`（全局 admin 已隐含集群最高权限）。

### 2.7 常用 RoleTemplate（速览）

```bash
$ kubectl get roletemplates.management.cattle.io --no-headers | grep -E "project-|cluster-" | head -6
admin                                137d
cluster-admin                        137d
cluster-member                       137d
cluster-owner                        137d
project-member                       137d
project-owner                        137d
```

项目级最常用：`project-owner`（读写+授权）、`project-member`（读写但通常不能授权他人）、`project-readonly`（只读）。集群级：`cluster-owner` > `cluster-member`。

---

## 3. 演示：创建用户并绑定到 Project（真实操作）

下面用最小 CR 演示"多租户授权"全流程。

### 3.1 创建新用户（演示用）

创建一个演示用户 `demo-user32`：

```yaml
# demo-user32.yaml
apiVersion: management.cattle.io/v3
kind: User
metadata:
  name: demo-user32
spec:
  description: "演示用用户（第32章）"
  displayName: demo-user32
  enabled: true
  username: demo-user32
```

应用：

```bash
$ kubectl --kubeconfig ./kubeconfig apply -f demo-user32.yaml
user.management.cattle.io/demo-user32 created
```

验证：

```bash
$ kubectl get users.management.cattle.io demo-user32 -o custom-columns='NAME:.metadata.name,USERNAME:.username,ENABLED:.spec.enabled'
NAME          USERNAME      ENABLED
demo-user32   demo-user32   true
```

> 注：此处仅创建 Rancher User 对象。若要实际登录 Rancher UI，还需配置认证方式（本地密码/外部认证）。本章聚焦 RBAC 绑定关系，不涉及登录凭据配置。

### 3.2 将用户绑定到 Project（ProjectRoleTemplateBinding）

目标：把 `demo-user32` 以 `project-member` 身份绑定到 `p-2wztg`（My Project）。

ProjectRoleTemplateBinding 必须创建在**项目的 backing Namespace** 中。查 `p-2wztg` 的 backing Namespace：

```bash
$ kubectl get projects.management.cattle.io -n local p-2wztg -o jsonpath='{.status.backingNamespace}{"\n"}'
local-p-2wztg
```

因此在 `local-p-2wztg` 命名空间创建 PRTB：

```yaml
# prtb-demo-member.yaml
apiVersion: management.cattle.io/v3
kind: ProjectRoleTemplateBinding
metadata:
  name: prtb-demo-member
  namespace: local-p-2wztg
spec:
  projectName: local:p-2wztg  # 格式：<cluster-id>:<project-name>，本集群 cluster-id 通常是 local
  roleTemplateName: project-member
  userName: demo-user32
  userPrincipalName: local://demo-user32  # 可选但常用（标识认证源）
```

应用：

```bash
$ kubectl --kubeconfig ./kubeconfig apply -f prtb-demo-member.yaml
projectroletemplatebinding.management.cattle.io/prtb-demo-member created
```

验证：

```bash
$ kubectl get projectroletemplatebindings.management.cattle.io -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,USER:.userName,ROLE:.roleTemplateName,PRJ:.projectName' | grep demo
local-p-2wztg   prtb-demo-member        demo-user32   project-member   local:p-2wztg
```

**改前/改后对照（项目级权限）**：
- 改前：`p-2wztg` 仅 `user-2j98p`（project-owner）
- 改后：新增 `demo-user32`（project-member）

此时 `demo-user32` 在 `p-2wztg` 项目范围内拥有 `project-member` 对应的权限（可读写项目内资源，但受项目边界限制）。

### 3.3 验证 Namespace 可见性（项目边界）

`p-2wztg` 下目前只有 `mytest`：

```bash
$ kubectl get ns -l field.cattle.io/projectId=p-2wztg
NAME     STATUS   AGE
mytest   Active   137d
```

若想让新用户能操作另一个 Namespace，也需将该 Namespace 的 `field.cattle.io/projectId` 改为 `p-2wztg`，或在项目内新建 Namespace。Rancher UI 新建 Namespace 时会自动归属到当前选中的 Project。

> 提示：直接改标签是最简单的验证方式：`kubectl label ns <ns> field.cattle.io/projectId=p-2wztg --overwrite`。但请谨慎操作生产环境。

### 3.4 演示：加为集群级（ClusterRoleTemplateBinding）

也可直接赋予集群级权限。CRTB 创建在集群命名空间（本集群通常是 `local`）：

```yaml
# crtb-demo-cluster-member.yaml
apiVersion: management.cattle.io/v3
kind: ClusterRoleTemplateBinding
metadata:
  name: crtb-demo-cluster-member
  namespace: local
spec:
  clusterName: local
  roleTemplateName: cluster-member
  userName: demo-user32
  userPrincipalName: local://demo-user32
```

应用：

```bash
$ kubectl --kubeconfig ./kubeconfig apply -f crtb-demo-cluster-member.yaml
clusterroletemplatebinding.management.cattle.io/crtb-demo-cluster-member created
```

验证：

```bash
$ kubectl get clusterroletemplatebindings.management.cattle.io -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,USER:.userName,ROLE:.roleTemplateName,CLUSTER:.clusterName' | grep demo
local   crtb-demo-cluster-member   demo-user32   cluster-member   local
```

**改前/改后对照（集群级权限）**：
- 改前：`demo-user32` 仅项目级 `project-member`
- 改后：额外获得集群级 `cluster-member`（可在集群范围内查看资源，但受 `cluster-member` 权限模板约束）

### 3.5 清理演示资源（可选但推荐）

演示完毕后清理临时对象，避免污染真实环境：

```bash
$ kubectl --kubeconfig ./kubeconfig delete projectroletemplatebinding -n local-p-2wztg prtb-demo-member
$ kubectl --kubeconfig ./kubeconfig delete clusterroletemplatebinding -n local crtb-demo-cluster-member
$ kubectl --kubeconfig ./kubeconfig delete user demo-user32
```

验证清理：

```bash
$ kubectl get users.management.cattle.io demo-user32 2>&1 | tail -1
Error from server (NotFound): users.management.cattle.io "demo-user32" not found
```

---

## 4. Rancher UI 对照

上述 CR 对应 Rancher 界面的位置：

| 对象 | Rancher 路径 | 说明 |
|---|---|---|
| Users | 用户 & 认证 → Users（或 Users & Authentication） | 平台用户列表（含启用/禁用状态） |
| GlobalRoleBindings | （隐含于 Users 详情页） | 用户详情页可看到"Global Permissions" |
| Projects | 集群 → Projects/Namespaces | 项目列表、项目内 Namespace 管理 |
| ProjectRoleTemplateBindings | 项目详情页 → Members | 项目成员及角色（project-owner/member/readonly） |
| ClusterRoleTemplateBindings | 集群 → Cluster Members | 集群成员及角色（cluster-owner/member） |
| RoleTemplates | 用户 & 认证 → Role Templates | 查看各角色模板定义的权限点（仅管理员可见） |

> 边敲 `kubectl` 边看 UI：Rancher UI 几乎就是对这些管理 CR 的可视化编辑器。

---

## 5. 排障清单

| 场景 | 排查思路 |
|---|---|
| **用户看不到某个 Namespace** | 检查 Namespace 的 `field.cattle.io/projectId` 标签是否指向该用户有权限的 Project。若标签错了，改成正确的 projectId 即可。 |
| **PRTB 创建失败（NotFound/backing ns）** | 确认 PRTB 创建在**项目 backing Namespace**（`kubectl get projects.management.cattle.io -n local <p> -o jsonpath='{.status.backingNamespace}'`）。别建在业务 Namespace。 |
| **CRTB 创建失败** | CRTB 必须建在集群命名空间（本集群 `local`）。`clusterName` 字段需与实际集群 ID 一致（通常 `local`）。 |
| **用户无法登录但 CR 已建好** | Rancher User CR 仅是"平台账号对象"，是否能登录取决于认证提供方（local auth 是否开启、密码/SSO 配置）。本章不涉及认证细节。 |
| **绑定后权限没生效** | 等 Rancher 控制器同步（通常秒级）。也可检查 PRTB/CRTB 的 `.status` 条件（若有）。 |
| **想查某用户拥有哪些项目权限** | `kubectl get projectroletemplatebindings.management.cattle.io -A -o custom-columns='NS:.metadata.namespace,USER:.userName,ROLE:.roleTemplateName,PRJ:.projectName' | grep <username>` |
| **想查某用户拥有哪些集群权限** | `kubectl get clusterroletemplatebindings.management.cattle.io -A -o custom-columns='USER:.userName,ROLE:.roleTemplateName,CLUSTER:.clusterName' | grep <username>` |
| **全局管理员 vs 集群所有者** | `globalRole=admin` 拥有平台全局能力（用户管理、特性开关等）。`cluster-owner` 是集群内最高权限但不一定能管理平台全局配置。 |

---

## 6. 附录：最小 CR 模板

**创建用户**
```yaml
apiVersion: management.cattle.io/v3
kind: User
metadata: {name: <user-id>}
spec: {username: <login-name>, enabled: true, displayName: <display>}
```

**ProjectRoleTemplateBinding（项目内授权）**
```yaml
apiVersion: management.cattle.io/v3
kind: ProjectRoleTemplateBinding
metadata: {name: <prtb-name>, namespace: <project-backing-ns>}
spec:
  projectName: local:<project-name>
  roleTemplateName: project-member  # 或 project-owner/project-readonly
  userName: <user-id>
```

**ClusterRoleTemplateBinding（集群级授权）**
```yaml
apiVersion: management.cattle.io/v3
kind: ClusterRoleTemplateBinding
metadata: {name: <crtb-name>, namespace: local}
spec:
  clusterName: local
  roleTemplateName: cluster-member  # 或 cluster-owner
  userName: <user-id>
```

---

## 动手练习

1. **盘点现状**：用本章 §2 的方式，列出本集群全部 Projects、每个 Project 下的 Namespace、以及每个用户的项目/集群绑定关系。
2. **实操授权**：按 §3 步骤，新建用户 `lab32-tester`，绑定到 `p-2wztg` 且角色为 `project-readonly`，验证 PRTB 已创建后再清理。
3. **项目边界**：新建一个临时 Namespace `lab32-ns`，尝试将其归属到 `p-2wztg`（改 `field.cattle.io/projectId`），再改回原来的 projectId，体会"命名空间隶属"的含义。
4. **集群级 vs 项目级**：对比 `cluster-member` 和 `project-member` 的适用场景，说明各自能做什么、不能做什么（结合 RoleTemplates 列表思考）。
5. **CR 对照 UI**：在 Rancher UI 找到对应页面（Projects/Members/Cluster Members/Users），逐一核对你用 `kubectl` 查到的同名对象。
6. **故障模拟**：故意把 PRTB 建到错误的 Namespace（业务 ns 而非 backing ns），观察报错并总结原因。
7. **全局视角**：根据 `globalrolebindings` 判断谁是平台全局管理员，并说明全局管理员与 `cluster-owner` 的区别。
