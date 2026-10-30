# 公司自有域名 + 自有证书配置 Rancher（production）

本文档以示例域名说明如何在 `production/` 环境中为 Rancher 配置公司自有域名和自有证书，并说明证书自动续期的思路与操作方式。

> 示例：
> - 公司域名：`myweb.cn`
> - Rancher 域名：`rancher.myweb.cn`
> - 集群节点 IP：任意（nginx-ingress 采用 `hostNetwork: true`，监听节点 80/443）

## 1. 前置条件

- 已准备好公司证书：
  - 建议使用完整链：`fullchain.crt`（包含站点证书 + 中间证书）
  - 私钥：`privkey.key`
- 证书的 CN/SAN 必须包含 `rancher.myweb.cn`
- 如果使用公司内部 CA，需在客户端导入该 CA 根证书以避免浏览器不信任
- 控制机已安装 `kubectl`（bootstrap 完成后 `production/kubeconfig` 可用）

## 2. 配置 production 参数

编辑 `production/config/cluster.env`：

```bash
# Rancher 配置
RANCHER_ENABLED=true
RANCHER_HOSTNAME=rancher.myweb.cn
RANCHER_REPLICAS=1
# 建议将密码放到 production/config/cluster.env.local
RANCHER_BOOTSTRAP_PASSWORD=ChangeMeStrong!
RANCHER_TLS_SOURCE=secret        # 使用自有证书
RANCHER_CHART_VERSION=2.15.2
```

编辑 `production/config/cluster.env.local`（该文件已在 `.gitignore` 中排除，不会提交）：

```bash
# 敏感信息建议单独放这里
RANCHER_BOOTSTRAP_PASSWORD=你的强密码
```

> 说明：`RANCHER_TLS_SOURCE` 可选值为 `rancher` / `letsEncrypt` / `secret`
> - `rancher`：默认，自签（浏览器提示不信任）
> - `letsEncrypt`：需公网可访问 80 端口且域名公网解析（不适用纯内网域名）
> - `secret`：**推荐用于公司自有域名 + 自有证书**，且当此值时 `cert-manager` 并非强制依赖（校验逻辑已放行）

## 3. 创建 TLS Secret（cattle-system）

Rancher 的 Ingress 使用 `secretName: tls-rancher-ingress`，命名空间为 `cattle-system`。

在**集群已正常运行**（或在 `bootstrap.sh` 跑到 `20-k3s-cluster.yml` 后）时，在控制机上操作：

```bash
# 设置 kubeconfig
export KUBECONFIG=$(pwd)/production/kubeconfig

# 创建命名空间（如已存在可跳过）
kubectl create namespace cattle-system --dry-run=client -o yaml | kubectl apply -f -

# 用自有证书创建 TLS Secret
kubectl -n cattle-system create secret tls tls-rancher-ingress \
  --cert=./fullchain.crt \
  --key=./privkey.key
```

验证：

```bash
kubectl -n cattle-system get secret tls-rancher-ingress
kubectl -n cattle-system describe secret tls-rancher-ingress
```

## 4. 部署 Rancher

### 全新集群

```bash
cd production
./bootstrap.sh
```

`30-addons.yml` 会按 `RANCHER_TLS_SOURCE=secret` 渲染 Rancher values 并安装，Ingress 将使用上面创建的 Secret。

### 已有集群（切换到自有证书）

```bash
export KUBECONFIG=$(pwd)/production/kubeconfig
# 1) 创建 secret（步骤 3）
# 2) 更新配置后重新跑 addons
cd production
./bootstrap.sh --steps 30
```

## 5. DNS 解析

将 `rancher.myweb.cn` 解析到**任意一台集群节点的 IP**：

- **内网 DNS**：在公司内网 DNS 添加 A 记录 `rancher.myweb.cn -> <node-ip>`
- **本地测试**：修改 `/etc/hosts`（Linux/macOS）或 `C:\Windows\System32\drivers\etc\hosts`（Windows）：`<node-ip> rancher.myweb.cn`

由于 nginx-ingress 使用 `hostNetwork`，访问任意节点的 80/443 均可命中该 Ingress。

访问地址：`https://rancher.myweb.cn/`

## 6. 证书自动续期

自有证书的续期**不由 Rancher/cert-manager 自动完成**，需要由公司证书管理流程或运维人员处理。

### 方式 A：手动续期（最常用）

1. 从证书颁发机构/公司 CA 获取新证书（新 `fullchain.crt`、新 `privkey.key`）
2. 更新 Secret（推荐用 `kubectl create secret ... --dry-run=client -o yaml | kubectl apply -f -` 覆盖）：

```bash
export KUBECONFIG=$(pwd)/production/kubeconfig
kubectl -n cattle-system create secret tls tls-rancher-ingress \
  --cert=./new-fullchain.crt \
  --key=./new-privkey.key \
  --dry-run=client -o yaml | kubectl apply -f -
```

3. 重启相关 Ingress Controller（可选但常用，确保尽快加载新证书）：

```bash
kubectl -n ingress-nginx rollout restart daemonset/nginx-ingress-ingress-nginx-controller
# 或 deployment 视实际安装形态而定
kubectl -n ingress-nginx rollout status daemonset/nginx-ingress-ingress-nginx-controller
```

> 注意：nginx-ingress 一般会在 Secret 更新后自动热加载证书，但在某些环境下重启更保险。

### 方式 B：使用外部工具自动更新（推荐企业化场景）

如果公司有证书自动化平台（如 cert-manager 外部 Issuer、Vault PKI、ACME 客户端等），可以编写脚本定时拉取新证书并用上面的方式更新 Secret。也可以配合 `kubectl` + CI/CD 或 Ansible 定时任务实现。

### 方式 C：配合 cert-manager（进阶）

如果想将公司证书接入 cert-manager 管理：

- **公司自有 CA**：可用 `cert-manager` 的 `CA Issuer`/`Vault Issuer`，由 cert-manager 按 `Certificate` 资源自动续期并生成 Secret，再将 `secretName` 指向该 Secret（仍需确保 Rancher Ingress 用到该 Secret 名称）
- **外部 ACME**：若证书来自支持 ACME 的内部平台，也可通过对应 Issuer 接入

但目前 `production/` 的 Rancher values 固定使用 `secretName: tls-rancher-ingress`，直接用手动更新 Secret 是最简单且与现有模板最兼容的做法。

## 7. 常见问题排查

| 问题 | 排查 |
|---|---|
| 浏览器提示证书不匹配 | 检查证书 SAN 是否包含 `rancher.myweb.cn`；检查 DNS 是否解析到正确节点 IP |
| 浏览器提示不受信任（内部 CA） | 将公司 CA 根证书导入到操作系统/浏览器信任库 |
| 访问 443 连不上 | 检查节点防火墙/安全组是否放行 443；nginx-ingress 用 hostNetwork，需确认 443 未被其他进程占用（`ss -tlnp \| grep :443`） |
| Ingress 未生效 | 检查 `kubectl -n cattle-system get ingress`、`kubectl -n cattle-system describe ingress` 事件；确认 Secret 存在且类型为 `kubernetes.io/tls` |
| Secret 格式错误 | 确保 `--cert` 用完整链，`--key` 用对应私钥，且两者匹配（可用 `openssl x509 -in fullchain.crt -noout -modulus` 和 `openssl rsa -in privkey.key -noout -modulus` 对比） |

## 附录：相关文件

| 文件 | 说明 |
|---|---|
| `production/config/cluster.env` | Rancher 主配置（`RANCHER_HOSTNAME`、`RANCHER_TLS_SOURCE` 等） |
| `production/config/cluster.env.local` | 敏感信息（密码、凭据） |
| `production/addons/rancher/values.yaml.j2` | Rancher Helm values（`ingress.tls.source`、`ingress.tls.secretName`） |
| `production/ansible/playbooks/30-addons.yml` | addons 安装流程（cert-manager 先于 Rancher） |
| `production/lib/config.sh` | 配置校验（`RANCHER_TLS_SOURCE` 合法值及依赖校验） |
| `production/lib/inventory.sh` | 将配置传递给 playbook/values |
