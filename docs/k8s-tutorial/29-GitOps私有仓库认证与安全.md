# 29 GitOps 私有仓库认证与安全

## 本章目标

- 理解 Fleet 的 Git 认证模型：**Secret + `clientSecretName`**，凭据**不进 Git**
- 掌握三种 Git 认证方式：**HTTP Basic / PAT**、**SSH 部署密钥**、**GitHub App**，以及各自的精确字段
- 通过**真实闭环**看懂认证：匿名 401 → 无认证 GitRepo 报错 → 加 Secret 成功 → Secret 名写错又失败
- 掌握 **自定义 CA / 跳过 TLS 校验**
- 分清 Git 认证与 **私有 Helm 仓库认证**（`helmSecretName` + `helmRepoURLRegex`）
- 了解 **OCI 仓库**、**多租户 Policy 约束**、**Rancher UI 操作**与**安全最佳实践**
- 能对照 ArgoCD 的仓库认证配置

> 前置：本章是 **第 26 章（GitOps：Fleet/ArgoCD）**、**第 27 章（仓库组织）**、**第 28 章（Fleet 用 Helm）** 的安全延伸。第 26~28 章用的都是 gitea **公开**仓库；生产里部署配置仓库几乎都是**私有**的，本章补齐这块。
> 环境（2026-10-09 真实执行）：本集群 Fleet **v0.15.1**，用 gitea 建一个**私有**仓库 `fleet-private`，完整演示"无认证失败 → 加认证成功"后清理。

---

## 1. 为什么必须私有 + Fleet 的认证模型

部署配置仓库里通常有集群拓扑、镜像地址、甚至占位密钥，**不能公开**。Fleet 的认证模型只有一句话：

> **在 GitRepo 的同一命名空间里建一个 Secret，然后在 GitRepo 上用 `clientSecretName` 引用它。**

```text
┌──────────────── 集群 (upstream) ────────────────┐
│  namespace: fleet-local                          │
│   ├── Secret/git-auth        ← 凭据 (username/password 或 ssh key) │
│   └── GitRepo/xxx            → clientSecretName: git-auth          │
│                                          │                            │
│                                          ▼ 用 Secret 去 clone         │
└──────────────────────────────────────────┼───────────────────────────┘
                                           │  HTTPS/SSH + 凭据
                                           ▼
                                  私有 Git 仓库 (远端)
```

三个要点：

1. **凭据只存在集群里**，不写进 Git、不写进 `fleet.yaml`。
2. **Secret 必须与 GitRepo 同命名空间**（`fleet-local` 或 `fleet-default` 等）。放错命名空间＝找不到＝当作匿名。
3. GitRepo 用 `clientSecretName` 引用；**Helm chart 仓库**的凭据是另一码事（用 `helmSecretName`，见第 5 节）。

---

## 2. 三种 Git 认证方式

Fleet 官方支持：**HTTP Basic Auth**、**SSH Auth Keys**、**GitHub App**。

### 2.1 HTTP Basic / PAT（推荐、最常用）

```bash
kubectl -n fleet-local create secret generic git-auth \
  --type=kubernetes.io/basic-auth \
  --from-literal=username="$GIT_USER" \
  --from-literal=password="$GIT_PAT"
```

```yaml
apiVersion: fleet.cattle.io/v1alpha1
kind: GitRepo
metadata:
  name: my-app
  namespace: fleet-local
spec:
  repo: https://git.example.com/org/deploy-repo.git
  branch: main
  clientSecretName: git-auth        # ← 引用 Secret
  paths:
  - apps/my-app/overlays/prod
```

- **password 建议填 PAT**（GitHub/GitLab/Gitea 都支持），最小权限、可随时吊销，比账号密码安全。
- **Bitbucket 访问令牌**：username 固定填 `x-token-auth`。
- 只读权限即可（部署只需要 clone）。

### 2.2 SSH 部署密钥

```bash
# 1) 生成密钥：必须 PEM 格式、且不能有 passphrase
ssh-keygen -t rsa -b 4096 -m pem -C "fleet" -f ./fleet_key -N ""

# 2) 把公钥加到 Git 服务端的 Deploy Key（只读）
cat ./fleet_key.pub

# 3) 建 Secret（含 known_hosts）
kubectl -n fleet-local create secret generic git-ssh-key \
  --type=kubernetes.io/ssh-auth \
  --from-file=ssh-privatekey=./fleet_key \
  --from-literal=known_hosts="$(ssh-keyscan -H github.com 2>/dev/null)"
```

```yaml
spec:
  repo: "ssh://git@<git-host>/org/deploy-repo.git"
  # 或 repo: "git@<git-host>:org/deploy-repo.git"
  clientSecretName: git-ssh-key
```
> `<git-host>` 替换成实际 Git 主机名（例如 GitHub 的 `github.com`）；示例里的 `ssh-keyscan -H github.com` 要换成同一主机。

**两个硬性要求**：

- 私钥必须是 **PEM**（`RSA PRIVATE KEY` / `EC PRIVATE KEY` / `PRIVATE KEY`），**不能有 passphrase**。
- **v0.13 起默认开启严格主机密钥校验**：Secret 里 `known_hosts` 没有匹配项就连不上。`known_hosts` 优先取自 GitRepo 引用的 Secret，其次全局 `gitcredential` Secret，最后 Fleet 安装时的 `known-hosts` ConfigMap（内置常见 Git 服务商）。可用 Helm chart 值 `insecureSkipHostKeyChecks` 关闭（不推荐）。

> SSH Secret 的键名是 `ssh-privatekey` 和 `known_hosts`。

### 2.3 GitHub App

不想用 PAT 时，可用 GitHub App（组织级、权限可控、自动续期）：

```bash
kubectl -n fleet-local create secret generic github-app-secret \
  --from-literal=github_app_id=<app-id> \
  --from-literal=github_app_installation_id=<installation-id> \
  --from-literal=github_app_private_key="<private-key>"
```

同样用 `clientSecretName` 引用。三个键：`github_app_id` / `github_app_installation_id` / `github_app_private_key`。

---

## 3. 实站：无认证 → 有认证（Fleet 真实执行）

### 3.1 建一个私有仓库

```bash
# gitea API 建私有仓库
curl -u admin:<PAT> -X POST http://localhost:3000/api/v1/user/repos \
  -H "Content-Type: application/json" \
  -d '{"name":"fleet-private","private":true,"auto_init":true}'
# → repo: admin/fleet-private | private: True
```

往里面推一个最小 kustomize 清单（ConfigMap 即可）。匿名访问被拒（真实）：

```text
匿名访问: HTTP 401
```

### 3.2 不带认证的 GitRepo（真实输出）

```yaml
spec:
  repo: http://10.0.2.2:3000/admin/fleet-private.git
  branch: main
  paths: ["."]
  targetNamespace: private-demo
```

等约 22 秒，GitRepo 状态（真实）：

```text
private-noauth   0/0
COND: GitPolling False | authentication required: Unauthorized
COND: Stalled    True  | authentication required: Unauthorized
```

**0 个 bundle、0 个资源**，错误直指**认证失败**。这正是"忘了配 Secret"时你会看到的报错。

### 3.3 建 Secret + 引用（真实成功）

```bash
kubectl -n fleet-local create secret generic git-basic-auth \
  --type=kubernetes.io/basic-auth \
  --from-literal=username=admin \
  --from-literal=password="$GIT_PAT"
```

```yaml
spec:
  repo: http://10.0.2.2:3000/admin/fleet-private.git
  branch: main
  clientSecretName: git-basic-auth      # ← 加上这一行
  paths: ["."]
  targetNamespace: private-demo
```

约 30 秒后（真实）：

```text
private-auth   ...c8982bce...   1/1
Bundle: private-auth            1/1

ConfigMap=private-demo
data.source=private git repo via clientSecretName
```

**资源成功落地**，证明认证生效。

### 3.4 Secret 名写错会怎样（真实）

把 `clientSecretName` 改成不存在的名字：

```text
COND: GitPolling False | authentication required: Unauthorized
COND: Stalled    True  | authentication required: Unauthorized
```

**又回到认证失败**。注意：Fleet 不会说"secret 不存在"，而是**静默当作匿名**去拉——排障时别被这个报错误导（见第 10 节）。

### 3.5 清理

```bash
kubectl -n fleet-local delete gitrepo private-noauth private-auth
kubectl -n fleet-local delete secret git-basic-auth
kubectl delete ns private-demo
# 删除 gitea 私有仓库
```

真实结果：GitRepo / Secret / 命名空间 / bundle 全部零残留。

---

## 4. 自定义 CA 与 TLS

私有 Git 服务常自签证书，此时：

```yaml
spec:
  repo: https://git.internal.example.com/org/repo.git
  clientSecretName: git-auth
  caBundle: <base64 编码的 CA 证书>      # 让 Fleet 信任该 CA
  # insecureSkipTLSVerify: true          # 仅临时排障, 不推荐
```

- `caBundle`：把自签 CA 装在 GitRepo 上（若 Rancher/Fleet 安装时已配置 CA，会优先复用）。
- `insecureSkipTLSVerify`：跳过校验，**只用于临时定位问题**，生产禁用。

---

## 5. 私有 Helm 仓库认证（别和 Git 认证混了）

Git 认证管的是**拉代码**；如果 chart 放在**外部私有 Helm 仓库/OCI**，用的是另一套：

```yaml
spec:
  helmSecretName: helm-auth                 # 拉 chart 的凭据
  helmRepoURLRegex: "https://charts\\.example\\.com/.*"   # ★ 必须匹配才转发凭据
```

Secret 支持这些键：

| 键 | 用途 |
|----|------|
| `username` / `password` | Helm HTTP 仓库的 basic auth |
| `cacerts` | 自定义 CA |
| `ssh-privatekey` | SSH 协议拉 chart |

**关键安全点**：凭据**只有 `helmRepoURLRegex` 匹配目标 URL 时才会转发**——这是一道防 SSRF/凭据外泄的闸门。**regex 要写具体**，别用 `.*` 放之四海。

**多路径不同凭据**：用 `helmSecretNameForPaths` 指向一个 Secret，其中固定放 `secrets-path.yaml`：

```yaml
# secrets-path.yaml
single-cluster/test-multipasswd/passwd:
  username: fleet-ci
  password: "$CHART_TOKEN"
path-two:
  username: user2
  password: "$CHART_TOKEN"
  caBundle: <base64>
  sshPrivateKey: <base64>
```

```bash
kubectl -n fleet-local create secret generic path-auth --from-file=secrets-path.yaml
```

```yaml
spec:
  helmSecretNameForPaths: path-auth
```
> 提供了 `helmSecretNameForPaths` 后，`helmSecretName` 会被忽略。若同时用 Rancher 备份，记得给 Secret 打 `resources.cattle.io/backup=true` 并加密备份。

**OCI 仓库**：用 `spec.ociRegistrySecret` 指向一个 `kubernetes.io/dockerconfigjson` 类型的 Secret。

---

## 6. Rancher UI 操作

在 Rancher **Continuous Delivery → Git Repos → Add Repository** 里，**Authentication** 区有三个选项：

- **Public**：公开仓库（第 26~28 章的做法）
- **Create a new secret** → `Username and password`：填用户名 + PAT，Rancher 自动创建 Secret 并帮你填好 `clientSecretName`
- **Create a new secret** → `SSH Private Key and Known Hosts`：粘贴私钥与 known_hosts

> UI 只是帮你**生成 Secret + 填 `clientSecretName`**，底层与命令行完全一致。

---

## 7. 多租户与 Policy 约束

Fleet 用 **`Policy`** 资源限制某命名空间（租户）能用什么：

- `repo` 白名单（只能拉指定仓库）
- 允许的 `clientSecretName` / `helmSecretName`
- 允许的 `serviceAccount`
- `targetNamespace` 限制由下游 RBAC 执行

违规时，**GitRepo 的状态条件会报出被拒的字段**——看到 `restricted` 类错误先查 Policy。

---

## 8. 安全最佳实践

- ✅ **凭据绝不进 Git**（包括 `fleet.yaml` 的 `values`）——敏感值用 `valuesFrom` 从下游 Secret/ConfigMap 读
- ✅ **用 PAT 而非账号密码**，权限最小化、可单独吊销
- ✅ **SSH 用部署密钥（只读）**，私钥无 passphrase、仅置于集群 Secret
- ✅ **namespace 隔离 + Policy 限定 `repo` 白名单**
- ✅ **helmRepoURLRegex 写具体**，绝不 `.*`（防凭据被转发到恶意仓库）
- ✅ 集群开启 **encryption at rest**，并把 `secrets`、`bundles.fleet.cattle.io`、`bundledeployments.fleet.cattle.io`、`contents.fleet.cattle.io` 纳入加密
- ✅ 备份含凭据的 Secret 时打 `resources.cattle.io/backup=true` 并加密
- ✅ `insecureSkipTLSVerify` / `insecureSkipHostKeyChecks` 仅排障用，生产关闭

---

## 9. 与 ArgoCD 对照

| 维度 | Fleet | ArgoCD |
|------|-------|--------|
| Git 认证载体 | GitRepo 同 namespace 的 Secret + `clientSecretName` | `argocd` namespace 的 Repository Secret |
| HTTP | `kubernetes.io/basic-auth`（username/password） | Secret `type: git`，键 `username`/`password` |
| SSH | `ssh-privatekey` + `known_hosts` | 键 `sshPrivateKey` |
| 快速添加 | Rancher UI 自动建 Secret | `argocd repo add <url> --username ... --password ...` |
| Helm 私有库 | `helmSecretName` + `helmRepoURLRegex` | 同一 Repository Secret（含 `enableOCI`） |

ArgoCD 的仓库 Secret 需带标签 `argocd.argoproj.io/secret-type: repository`，并用 `url`、`type: git` 等键描述。核心思路一致：**凭据进集群 Secret，不进 Git**。

---

## 10. 排障清单

| 现象 | 可能原因 | 处理 |
|------|---------|------|
| `authentication required: Unauthorized` 且**确实配了** Secret | Secret 与 GitRepo **不同命名空间**；或 `clientSecretName` 拼写错 | 确认同 namespace、名字一致 |
| 同上、Secret 名不存在 | Fleet 静默匿名拉取 | `kubectl -n <ns> get secret <name>` 核对 |
| PAT 失效 | 令牌过期/权限不足/被吊销 | 重新生成 PAT |
| SSH 连不上 | 私钥有 passphrase / 非 PEM / 缺 known_hosts（v0.13 起严格校验） | 用 `-m pem -N ""` 生成；补 `known_hosts` |
| 自签证书报 x509 | 未配 CA | 设 `caBundle`；临时可 `insecureSkipTLSVerify` |
| Helm chart 拉不到但 git 正常 | 只配了 `clientSecretName`，没配 `helmSecretName`/`regex` | 补 Helm 认证（第 5 节） |
| Bitbucket 认证失败 | username 应为 `x-token-auth` | 改 username |

---

## 11. 小结

1. **Fleet Git 认证 = 同命名空间 Secret + `clientSecretName`**；凭据不进 Git。
2. **三种方式**：HTTP Basic/PAT（推荐）、SSH 部署密钥（PEM、无 passphrase、配 `known_hosts`）、GitHub App。
3. **真实闭环**：匿名 401 → 无认证 GitRepo `authentication required`（0/0）→ 加 Secret `1/1` → Secret 名写错又失败；**Secret 找不到时 Fleet 静默按匿名处理**。
4. **CA/TLS**：`caBundle` 正规解法，`insecureSkipTLSVerify` 仅排障。
5. **Helm 私有库是另一套**：`helmSecretName` + **`helmRepoURLRegex`**（凭据只在 URL 匹配时转发）；多路径用 `secrets-path.yaml`；OCI 用 `ociRegistrySecret`。
6. **多租户**由 `Policy` 约束；**安全**上坚持"凭据进 Secret、PAT 最小权限、encryption at rest、备份加密"。

---

## 动手练习

1. **最小复现**：建一个私有 gitea 仓库，先不加认证的 GitRepo（观察 `authentication required`），再加 `clientSecretName`（观察成功）。
2. **命名空间陷阱**：把 Secret 建在 `default`，GitRepo 建在 `fleet-local`，观察是否仍失败，并解释原因。
3. **错误名对照**：把 `clientSecretName` 改成不存在的名字，确认错误信息与"完全没配"一致。
4. **SSH 路线**：本地生成 PEM 密钥、加到 Git 服务端 Deploy Key、建 `kubernetes.io/ssh-auth` Secret（含 known_hosts），跑通 SSH 克隆。
5. **CA 场景**：为自签 Git 服务配 `caBundle`，对比不配时的 x509 报错。
6. **Helm 对照**：用 `helmSecretName` + `helmRepoURLRegex` 拉一个私有 OCI chart，观察 regex 不匹配时凭据不转发导致失败。
7. **安全审查**：审计本仓库，确认没有任何 `values`/`valuesFiles` 里含明文密码，敏感项都走了 `valuesFrom`。
