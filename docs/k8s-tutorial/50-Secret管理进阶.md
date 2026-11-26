# 50 Secret 管理进阶：SOPS、External Secrets 与 RBAC 边界

## 章节信息

| 项目 | 内容 |
|------|------|
| 适用平台 | Linux / macOS（标准路径）；Windows（ops VM 路径，在 ops VM 内执行 kubectl/helm/docker） |
| 前置章节 | 05/07/27/29/43/46 |
| 预计耗时 | 60-90 分钟 |
| 破坏性操作 | 中：会安装 External Secrets Operator（控制器 + webhook + CRD），并创建演示 namespace/Secret/RBAC。所有实验资源放在独立 namespace，章末可完整清理。 |
| 实测环境 | k3s v1.30.2+k3s2，双节点（server-1 2c/4GB + agent-1 2c/4GB），见 [00-README](00-README.md) |

## 本章目标

- 理解 Kubernetes Secret 的真实边界：base64 不是加密，RBAC 能控制“谁能读对象”，但不能只隐藏 Secret 里的某个字段。
- 掌握“Secret 安全进 Git”的一种轻量方案：**SOPS + age**，把敏感值加密后再入库。
- 掌握“应用从外部密钥系统取 Secret”的模式：用 **External Secrets Operator (ESO)** 从外部密钥源同步为 K8s Secret。
- 实测 RBAC 场景：能操作部分 K8s 资源的人，如果没有 `get/list/watch secrets` 权限，就看不到 Secret 明文。
- 能根据团队规模、合规要求和运维成本，在 SOPS / SealedSecrets / External Secrets / Vault 之间做选型。

---

## 1. 先把边界说清楚

很多人第一次用 Kubernetes Secret，会把它当成“保险箱”。实际上它更像“专门放敏感配置的对象”，安全性取决于你怎么管它。

| 问题 | 结论 |
|------|------|
| Secret 是加密的吗？ | 默认只是 **base64 编码**。拿到对象就能 `base64 -d` 解码。 |
| RBAC 能不能只让人看到 `username`，不让看 `password`？ | **不能**。Kubernetes RBAC 的授权粒度是 API 资源/动词/namespace（以及部分场景的 resourceName），不是 Secret 的某个 key 字段。能 `get` Secret 对象的人，就能看到其中的数据。 |
| etcd encryption at rest 有用吗？ | 有用，但它保护的是 **etcd 磁盘/备份落盘**。对已经通过 API 有读取权限的人，它不提供额外隐藏。 |
| `cluster-admin` 能被彻底屏蔽吗？ | 基本不能。`cluster-admin` 或等效高权限账户应视为可读取敏感数据的高信任角色，必须配合审计、双人审批、短期凭据和最小人数原则。 |
| 真正减少“集群里人看到明文”的办法是什么？ | **最小权限 RBAC + 审计 + 短期凭据 + 外部密钥系统/KMS + 不把明文放 Git + 需要时加密 etcd**。把明文留在外部系统，由控制器按需同步，是常见的信任边界调整方式，但不是银弹。 |

> 结论：不要追求“任何能操作 K8s 的人都绝对看不到 Secret”。要追求的是：**没必要看的人看不到；能看的人可审计、可轮换、权限最小、暴露面最小**。

---

## 2. 四种方案对比：SOPS / SealedSecrets / External Secrets / Vault

| 方案 | 核心概念 | 典型实现 | 优点 | 缺点/注意事项 | 适用环境 |
|------|----------|----------|------|---------------|----------|
| **SOPS** | 文件级加密；把 Secret/YAML/JSON/ENV 中的值加密后提交 Git | `sops` + `age`/PGP/KMS；CI 或部署时解密后 `kubectl apply` 或交给 Helmfile/Flux | 轻量、无常驻控制器；适合 GitOps；支持 age/云 KMS；审计简单 | 解密发生在客户端/CI，密钥管理仍是责任；不是运行时动态同步；多人协作要设计 key 分发与轮换 | 小团队、GitOps 入门、配置仓库需要密文存储、暂时不想上控制器 |
| **SealedSecrets** | 把普通 Secret 加密成集群可解密的 SealedSecret CR，安全进 Git | Bitnami Sealed Secrets Controller + `kubeseal`；控制器用集群内私钥解密生成 Secret | GitOps 体验好；密文只能被目标集群解开（按 scope）；集群内流程清晰 | 绑定集群/控制器密钥；密钥备份与轮换要规划；仍然会在集群内生成普通 Secret | 单集群或少量集群 GitOps；希望“加密 YAML 提交 Git，集群内自动还原” |
| **External Secrets (ESO)** | 不把明文 Secret 当真源；从外部密钥源同步到 K8s Secret | ESO Controller + `SecretStore/ClusterSecretStore` + `ExternalSecret`；后端可接 Vault/AWS/GCP/Azure/Kubernetes 等 | 真源在外部系统；支持轮换、集中审计、多集群复用；应用仍可用普通 Secret/env/volume 消费 | 需要常驻控制器；最终通常仍生成 K8s Secret；外部系统可用性和认证配置很关键 | 已有云 KMS/Secret Manager/Vault；多集群；需要集中轮换和审计 |
| **Vault** | 专门的密钥/凭据管理平台；可动态签发、租约、轮换、审计 | HashiCorp Vault + Auth Method + Policy + KV/数据库/PKI 引擎；可配 ESO、Vault Agent Injector、CSI Provider | 能力最强：动态凭据、租约、细粒度策略、审计、加密即服务；适合强合规 | 部署运维复杂；HA/存储/解封/备份/升级成本高；对小团队可能过重 | 中大型团队、强合规、需要动态凭据/集中审计/多系统统一密钥平台 |

### 怎么选

- **只想让 Secret 安全进 Git**：优先 SOPS 或 SealedSecrets。
- **已经有云厂商 Secret Manager/KMS/Vault**：优先 ESO，把它们作为真源。
- **需要动态数据库密码、证书签发、完整审计链**：考虑 Vault，但要接受运维成本。
- **当前集群资源紧张、先把模式跑通**：像本章一样，先用 SOPS（无控制器）+ ESO（轻量控制器）理解边界，再决定生产方案。

---

## 3. 常见外部密钥源（ESO 视角）

External Secrets Operator 的价值在于“对接外部真源”。常见来源包括：

| 类别 | 示例 | 典型场景 |
|------|------|----------|
| 云厂商 Secret/KMS | AWS Secrets Manager / Parameter Store、GCP Secret Manager、Azure Key Vault | 应用跑在云上，统一用云平台权限和审计 |
| 专用密钥平台 | HashiCorp Vault、CyberArk、1Password、Doppler | 多云/自建环境，集中管理凭据、动态凭据或企业密码库 |
| Kubernetes 作为中转源 | 另一个 namespace/集群中的 Secret（Kubernetes provider） | 迁移过渡、边界演示、集中源命名空间；**不是最终安全边界** |
| Git/CI 系统 | GitLab CI Variables、GitHub Actions Secrets（通常通过 CI 注入，不一定经 ESO） | 构建部署阶段注入，运行时不一定落 K8s Secret |
| 自定义/企业系统 | 内部 CMDB、凭据网关、HSM 封装 API | 通过 webhook/provider 扩展接入 |

> 本章实操用 **Kubernetes provider** 模拟“外部密钥源”：把 `secret-source` namespace 的 Secret 当作真源，同步到 `secret-lab`。这样不用引入云账号或 Vault，也能把 ESO 的 `SecretStore + ExternalSecret + RBAC` 链路跑通。生产中请替换为真正的外部密钥系统。

---

## 4. 实操 A：SOPS + age，让 Secret 安全进 Git

### 4.1 为什么它能解决“明文进 Git”

普通 Secret manifest：

```yaml
stringData:
  username: appuser
  password: S3cretP@ssw0rd!
```

这类文件一旦进 Git，仓库访问者、CI 日志、历史提交、备份都可能看到明文。SOPS 的做法是：**文件结构保留，敏感值加密**。评审者能看到 key 结构，拿不到 age 私钥就解不开值。

### 4.2 安装/准备工具

本章实测环境里宿主机没有 `sops`/`age`，从 GitHub 下载 `sops v3.12.2` amd64 二进制时出现执行异常；`age` 可正常下载。为了不阻塞实操，SOPS 使用官方容器镜像执行：

```bash
# age（本地解压后可用）
curl -sS -L -o /tmp/opencode/ch50/age-v1.3.1-linux-amd64.tar.gz \
  https://dl.filippo.io/age/latest?for=linux/amd64
tar -xzf /tmp/opencode/ch50/age-v1.3.1-linux-amd64.tar.gz -C /tmp/opencode/ch50

# sops（容器方式，实测可用）
docker run --rm ghcr.io/getsops/sops:v3.12.2-alpine --version
```

实测输出：

```text
sops 3.12.2
```

> 坑：不要把下载到一半或损坏的二进制直接覆盖执行；本章曾遇到 `Text file busy`/`Segmentation fault`。教学环境优先用包管理器或官方 release 校验；临时绕过可用容器镜像。

### 4.3 生成 age 密钥并编写 SOPS 规则

```bash
mkdir -p /tmp/opencode/ch50
/tmp/opencode/ch50/age/age-keygen -o /tmp/opencode/ch50/age-key.txt

cat > /tmp/opencode/ch50/.sops.yaml <<'YAML'
creation_rules:
  - path_regex: secret.*\.ya?ml$
    age: <你的 age public key>
YAML
```

注意：

- **`age-key.txt` 是私钥文件，绝不能进 Git**。应放密码管理器、KMS、CI Secret 或受控密钥存储。
- `.sops.yaml` 可以进 Git，但里面只放公钥/规则，不放私钥。

### 4.4 加密 Secret manifest

明文文件（仅实验用，真实项目不要提交）：

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
  namespace: lab
type: Opaque
stringData:
  username: appuser
  password: S3cretP@ssw0rd!
```

加密：

```bash
cp secret-plain.yaml secret-db.yaml
docker run --rm \
  -v /tmp/opencode/ch50:/work -w /work \
  -e SOPS_AGE_KEY_FILE=/work/age-key.txt \
  ghcr.io/getsops/sops:v3.12.2-alpine \
  --config /work/.sops.yaml encrypt --in-place /work/secret-db.yaml
```

加密后检查（示例，已截断）：

```yaml
stringData:
  username: ENC[AES256_GCM,data:...,type:str]
  password: ENC[AES256_GCM,data:...,type:str]
sops:
  age:
    - recipient: age1...
      enc: |
        -----BEGIN AGE ENCRYPTED FILE-----
        ...
        -----END AGE ENCRYPTED FILE-----
```

实测 `grep -c "ENC\[" secret-db-ok.yaml` 结果为 `8`，说明敏感字段和元数据已被加密封装。

### 4.5 解密验证

```bash
docker run --rm \
  -v /tmp/opencode/ch50:/work -w /work \
  -e SOPS_AGE_KEY_FILE=/work/age-key.txt \
  ghcr.io/getsops/sops:v3.12.2-alpine \
  decrypt /work/secret-db.yaml
```

实测语义等价校验：

```bash
python3 -c "import yaml; print(yaml.safe_load(open('secret-plain.yaml'))==yaml.safe_load(open('secret-db-decrypted.yaml')))"
# True
```

> 重点：SOPS 解决的是“Git 仓库里不要放明文”。它不自动给你运行时轮换、动态凭据、集中审计平台。解密权限仍需严格控制。

---

## 5. 实操 B：External Secrets Operator，从外部密钥源同步 Secret

### 5.1 实验拓扑

```text
secret-source namespace              secret-lab namespace
-----------------------              --------------------
Secret: db-source        --ESO-->    Secret: db-credentials
  username/appuser                   (由 ExternalSecret 创建)
  password/S3cretP@ssw0rd!

SecretStore(k8s-secret-source) 使用 bearer token 读取 secret-source
ExternalSecret(db-credentials) 定义要同步哪些 key
```

这里的 `secret-source` 模拟外部密钥系统。真实环境可替换为 Vault、AWS Secrets Manager、GCP Secret Manager、Azure Key Vault 等。

### 5.2 安装 ESO（轻量，钉到 agent-1）

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update external-secrets

cat > /tmp/opencode/ch50/eso-values.yaml <<'YAML'
installCRDs: true
replicaCount: 1
nodeSelector:
  kubernetes.io/hostname: k3s-demo-agent-1
resources:
  requests:
    cpu: 50m
    memory: 128Mi
  limits:
    cpu: 300m
    memory: 256Mi
webhook:
  replicaCount: 1
  nodeSelector:
    kubernetes.io/hostname: k3s-demo-agent-1
  resources:
    requests: {cpu: 20m, memory: 64Mi}
    limits: {cpu: 150m, memory: 128Mi}
certController:
  replicaCount: 1
  nodeSelector:
    kubernetes.io/hostname: k3s-demo-agent-1
  resources:
    requests: {cpu: 20m, memory: 64Mi}
    limits: {cpu: 150m, memory: 128Mi}
YAML

# GitHub release asset 直拉不稳时，可先下载 chart tgz
curl -sS -L -o /tmp/opencode/ch50/external-secrets-2.15.0.tgz \
  https://github.com/external-secrets/external-secrets/releases/download/helm-chart-2.15.0/external-secrets-2.15.0.tgz

KUBECONFIG=./kubeconfig helm upgrade --install external-secrets \
  /tmp/opencode/ch50/external-secrets-2.15.0.tgz \
  -n external-secrets --create-namespace \
  -f /tmp/opencode/ch50/eso-values.yaml \
  --wait --timeout 10m
```

实测关键输出：

```text
NAME: external-secrets
STATUS: deployed
REVISION: 1
```

Pod 状态：

```text
external-secrets-cdc9dd6d-p99g2                     1/1 Running  k3s-demo-agent-1
external-secrets-cert-controller-6999869b87-k68l2   1/1 Running  k3s-demo-agent-1
external-secrets-webhook-7b9b66b4d9-hpkjh           1/1 Running  k3s-demo-agent-1
```

> 实测坑：安装过程中曾出现 API Server 短暂 `ServiceUnavailable` / `connection refused`，约 20-30 秒后恢复，ESO Pod 最终正常。资源紧张集群上装 webhook 类组件要预留观察窗口，不要立刻判定失败。

### 5.3 准备“外部密钥源”和目标 namespace

```bash
kubectl create namespace secret-source
kubectl create namespace secret-lab

kubectl -n secret-source create secret generic db-source \
  --from-literal=username=appuser \
  --from-literal=password='S3cretP@ssw0rd!'
```

### 5.4 给 ESO 最小读取权限

ESO 访问 Kubernetes provider 时，需要凭据读取 `secret-source` 中的 Secret。演示使用最小 RBAC：只允许 `get/list/watch secrets` 和 `selfsubjectrulesreviews`。

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: eso-secret-reader
  namespace: secret-source
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: eso-secret-reader
  namespace: secret-source
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["authorization.k8s.io"]
    resources: ["selfsubjectrulesreviews"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: eso-secret-reader
  namespace: secret-source
subjects:
  - kind: ServiceAccount
    name: eso-secret-reader
    namespace: secret-source
roleRef:
  kind: Role
  name: eso-secret-reader
  apiGroup: rbac.authorization.k8s.io
```

Kubernetes provider 的 namespaced `SecretStore` 校验要求 token Secret 在同一 namespace，因此把 `secret-source` 的 SA token 复制一份到 `secret-lab` 供 SecretStore 使用（仅实验简化；生产中应使用专门的 provider 认证方式并做好轮换）：

```bash
kubectl -n secret-source get secret eso-secret-reader-token -o jsonpath='{.data.token}' | base64 -d > /tmp/opencode/ch50/eso-token.txt
kubectl -n secret-lab create secret generic eso-secret-reader-token --from-file=token=/tmp/opencode/ch50/eso-token.txt
```

### 5.5 创建 SecretStore 与 ExternalSecret

```yaml
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: k8s-secret-source
  namespace: secret-lab
spec:
  provider:
    kubernetes:
      remoteNamespace: secret-source
      server:
        caProvider:
          type: ConfigMap
          name: kube-root-ca.crt
          key: ca.crt
      auth:
        token:
          bearerToken:
            name: eso-secret-reader-token
            key: token
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: db-credentials
  namespace: secret-lab
spec:
  refreshInterval: 1m
  secretStoreRef:
    name: k8s-secret-source
    kind: SecretStore
  target:
    name: db-credentials
    creationPolicy: Owner
  data:
    - secretKey: username
      remoteRef:
        key: db-source
        property: username
    - secretKey: password
      remoteRef:
        key: db-source
        property: password
```

实测结果：

```text
$ kubectl -n secret-lab get secretstore k8s-secret-source
NAME                STATUS   CAPABILITIES   READY
k8s-secret-source   Valid    ReadWrite      True

$ kubectl -n secret-lab get externalsecret db-credentials
NAME             STORETYPE     STORE               REFRESH INTERVAL   STATUS         READY
db-credentials   SecretStore   k8s-secret-source   1m                 SecretSynced   True
```

同步出的 Secret：

```text
$ kubectl -n secret-lab get secret db-credentials -o jsonpath='{.data.username}' | base64 -d; echo
appuser
$ kubectl -n secret-lab get secret db-credentials -o jsonpath='{.data.password}' | base64 -d; echo
S3cretP@ssw0rd!
```

这说明应用仍然可以用标准 K8s Secret 消费凭据；区别是**真源不必是 Git 明文，也不必由人手工维护目标 Secret**。

---

## 6. 实操 C：RBAC 能挡住“看不到明文”，但有边界

### 6.1 创建一个只能看 Pod/ConfigMap 的审计账号

```bash
kubectl -n secret-lab create serviceaccount secret-auditor
kubectl -n secret-lab create role secret-auditor \
  --verb=get,list,watch --resource=pods,configmaps
kubectl -n secret-lab create rolebinding secret-auditor \
  --role=secret-auditor --serviceaccount=secret-lab:secret-auditor
```

权限检查：

```text
$ kubectl -n secret-lab auth can-i get pods --as=system:serviceaccount:secret-lab:secret-auditor
yes
$ kubectl -n secret-lab auth can-i get secrets --as=system:serviceaccount:secret-lab:secret-auditor
no
$ kubectl -n secret-lab auth can-i list secrets --as=system:serviceaccount:secret-lab:secret-auditor
no
```

实际读取 Secret：

```text
$ kubectl -n secret-lab get secret db-credentials --as=system:serviceaccount:secret-lab:secret-auditor
Error from server (Forbidden): secrets "db-credentials" is forbidden:
User "system:serviceaccount:secret-lab:secret-auditor" cannot get resource "secrets"
in API group "" in the namespace "secret-lab"
```

### 6.2 这能说明什么，不能说明什么

能说明：

- 没有 `secrets` 的 `get/list/watch` 权限，普通审计/运维账号就不能通过 API 直接读出 Secret 明文。
- 这是“最小权限”最直接的收益：能操作 Pod 不等于能读 Secret。

不能说明：

- **不能只隐藏 password 字段**。Kubernetes 没有“Secret.data.password 不可见但 username 可见”的原生 RBAC。
- **能 exec 进 Pod 的人可能间接拿到**。如果应用把 Secret 注入环境变量或挂载文件，能进入容器的人可以读取进程环境或文件。
- **能创建 Pod 的人可能绕过**。若允许在同 namespace 创建 Pod/Deployment，可以挂载目标 Secret 并读出来。
- **cluster-admin/等效权限不受此限制**。
- **etcd encryption at rest 不改变 API 授权结果**。

### 6.3 生产建议

- 把 `secrets` 权限单独审计，默认不授予开发者只读全集群 Secret。
- 把“能创建 Pod/exec/port-forward/读日志”的权限也纳入威胁模型。
- 对高敏凭据使用外部密钥系统、短期凭据、自动轮换。
- 开启审计日志，记录 Secret 读取和 RBAC 变更。
- 不要把 SOPS age 私钥、Vault token、云 AK/SK 放进 Git 或聊天记录。

---

## 7. 常见坑

1. **base64 当加密**：`kubectl get secret -o yaml` 拿到的 data 直接可解码。
2. **SOPS 私钥泄露**：密文进 Git 了，但私钥也一起进了，等于没加密。
3. **ESO SecretStore 认证命名空间**：namespaced SecretStore 引用 token/SA 时要注意 ESO 校验规则；本章用同 namespace token Secret 简化。
4. **ESO webhook/证书未就绪**：安装后前几十秒可能出现校验失败或 Pod 未 Ready，先看 `kubectl -n external-secrets get pods/events`。
5. **GitHub chart/二进制下载不稳**：先下载到本地 tgz/镜像，再安装；不要在受限网络下反复硬等在线拉取。
6. **把 Kubernetes provider 当最终安全边界**：它只是把一个 K8s Secret 同步到另一个地方，真源仍在集群内。

---

## 8. 动手练习

1. **SOPS 实操**：用 age 生成测试密钥，加密一个包含 `username/password` 的 Secret，确认 Git 中只有密文；再用 `sops -d` 验证解密结果。
2. **ESO 故障注入**：把 ExternalSecret 的 `remoteRef.key` 改错，观察 `status.conditions`/events 的报错，再恢复正确值确认 Secret 同步。
3. **RBAC 边界**：用只读账号验证 `get secrets` 被拒绝；再思考为什么“能 exec Pod / 创建 Pod 挂载 Secret / cluster-admin”仍可能拿到明文，并写出防护措施。

## 9. 清理

```bash
# 删除演示资源
kubectl --kubeconfig ./kubeconfig delete namespace secret-lab --ignore-not-found
kubectl --kubeconfig ./kubeconfig delete namespace secret-source --ignore-not-found

# 卸载 ESO
KUBECONFIG=./kubeconfig helm uninstall external-secrets -n external-secrets || true
kubectl --kubeconfig ./kubeconfig delete namespace external-secrets --ignore-not-found

# 可选：清理本地临时文件（包含私钥/令牌，仅本地实验目录）
rm -rf /tmp/opencode/ch50
```

如果你后续还要做 51 章，建议先清理 ESO，避免 webhook/控制器继续占用 agent-1 资源。

---

## 10. 小结

- **安全进 Git**：SOPS/SealedSecrets 解决“仓库里不要明文”；SOPS 更轻，SealedSecrets 更贴 GitOps 控制器模式。
- **外部密钥源**：ESO 把 Vault/云 Secret Manager/企业密钥系统作为真源同步进 K8s；应用仍可消费普通 Secret。
- **看不到明文**：RBAC 可以做到“无 secrets 读取权限就看不到”；但不能细粒度隐藏 Secret 内某个字段，也挡不住 `cluster-admin` 或通过 Pod 注入/exec 的间接读取路径。
- **生产选型**：小团队先 SOPS；已有外部密钥平台上 ESO；强合规/动态凭据再上 Vault。

## 11. 参考

- [Kubernetes Secrets](https://kubernetes.io/docs/concepts/configuration/secret/)
- [Kubernetes RBAC](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
- [Encrypting Confidential Data at Rest](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/)
- [SOPS](https://github.com/getsops/sops)
- [age](https://github.com/FiloSottile/age)
- [External Secrets Operator](https://external-secrets.io/)
- [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets)
- [HashiCorp Vault](https://developer.hashicorp.com/vault/docs)
