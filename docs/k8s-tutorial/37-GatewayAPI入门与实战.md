# 37 Gateway API 入门与实战

## 本章目标

- 理解 Gateway API 的分层模型：GatewayClass / Gateway / HTTPRoute / ReferenceGrant
- 掌握 Gateway API 与 Ingress（第 31 章）的定位差异与选型思路
- 在本集群（k3s v1.30.2+k3s2）真实安装 Gateway API CRD 与 NGINX Gateway Fabric，完成 HTTPRoute 路由实测
- 用 ReferenceGrant 实测跨命名空间引用：无授权 → `RefNotPermitted`（500），加授权 → 恢复访问
- 建立基于 Gateway Status Conditions（Accepted / Programmed / ResolvedRefs）的排障思路

> 本章所有命令统一使用 `kubectl --kubeconfig ./kubeconfig`。文档中路径统一用 `~/k3s-ops` 表示。

---

## 1. 前置盘点：本集群 Ingress 现状与 Gateway API 引入动机

第 31 章我们已经部署并用熟了 nginx-ingress（IngressClass `nginx`，控制器以 NodePort `30080/30444` 暴露）。它的优点是简单、成熟，缺点也明显：

| Ingress 的问题 | 说明 |
|---|---|
| 能力分散在注解里 | 重写、限流、CORS、金丝雀……全靠 `nginx.ingress.kubernetes.io/*` 注解，学习成本高、跨实现不通用 |
| 标准能力弱 | Ingress v1 只关心 host/path 转发，四层、跨命名空间、路由级高级策略都进不了规范 |
| 绑定实现 | 注解写死 nginx 语义，换 Ingress Controller 就要重写 |
| 无显式"网关实例"概念 | Gateway 是集群资源模型里的"基础设施"，Ingress 只是"路由" |

**Gateway API** 是 Kubernetes SIG-Network 力推的下一代七层/四层流量 API，把"基础设施（GatewayClass/Gateway）"和"应用路由（HTTPRoute/GRPCRoute）"分层建模：

```text
GatewayClass  （集群级：选择实现，如 nginx/istio/cilium/envoy……）
    │  实例化
Gateway       （命名空间级：一台"网关"、监听端口）
    │  绑定（parentRefs）
HTTPRoute     （命名空间级：host + path 匹配 → 后端转发）
    │  可选跨命名空间
ReferenceGrant（授权：A 命名空间的 Route 引用 B 命名空间的 Service）
```

核心收益：**API 标准化、实现可替换、权限分离（平台团队管 Gateway，应用团队管 Route）**。

---

## 2. Gateway API 核心 API 速览

| 资源 | 作用域 | 作用 | 常用字段 |
|---|---|---|---|
| `GatewayClass` | 集群级 | 声明"使用哪个控制器实现"（类似 IngressClass） | `spec.controllerName` |
| `Gateway` | 命名空间级 | 声明一个具体的网关实例（监听端口、可绑定的 Route） | `spec.gatewayClassName`、`spec.listeners[]`（protocol/port/hostname） |
| `HTTPRoute` | 命名空间级 | 定义 host/path 匹配与转发规则，`parentRefs` 绑定 Gateway | `spec.parentRefs[]`、`spec.hostnames[]`、`spec.rules[].matches[].path`、`rules[].backendRefs[]` |
| `ReferenceGrant` | 命名空间级 | 授权"其他命名空间的 Route 引用本命名空间的 Service" | `spec.from[]`（谁引用）、`spec.to[]`（引到什么）、`spec.namespace`（授权方） |

**版本细节（真实验证）：** 在 Gateway API `v1.4.1` 标准渠道中：

```bash
$ kubectl --kubeconfig ./kubeconfig api-resources 2>/dev/null | grep -E "gatewayclasses|gateways|httproutes|referencegrants|grpcroutes|backendtlspolicies"
backendtlspolicies                           btlspolicy    gateway.networking.k8s.io/v1        true   BackendTLSPolicy
gatewayclasses                              gc            gateway.networking.k8s.io/v1        false  GatewayClass
gateways                                    gtw           gateway.networking.k8s.io/v1        true   Gateway
grpcroutes                                  -             gateway.networking.k8s.io/v1        true   GRPCRoute
httproutes                                  -             gateway.networking.k8s.io/v1        true   HTTPRoute
referencegrants                             refgrant      gateway.networking.k8s.io/v1beta1   true   ReferenceGrant
```

> **要点：** `GatewayClass` 是**集群级**（`NAMESPACED false`），其余均为命名空间级；`ReferenceGrant` 在标准渠道仍是 **v1beta1**（其余已 GA 到 v1）。写清单时 `ReferenceGrant` 必须用 `apiVersion: gateway.networking.k8s.io/v1beta1`，否则 `kubectl apply` 会报 `no matches for kind` —— 这是真实踩过的坑。

---

## 3. 真实集群实测：安装 Gateway API CRD 与 NGINX Gateway Fabric

### 3.1 兼容性确认（先决策再动手）

网关实现选择 NGINX Gateway Fabric（NGF，NGINX 官方的 Gateway API 实现）。**必须先核对版本兼容**：本集群是 `k3s v1.30.2+k3s2`，而 NGF 较新小版本提高了 Kubernetes 版本门槛：

| NGF 版本 | 配套 Gateway API | 最低 Kubernetes 版本 |
|---|---|---|
| 2.4.2 | 1.4.1 | 1.25+ |
| 2.5.1 | 1.5.1 | 1.31+ |
| 2.6.x | 1.5.1 | 1.31+ |

所以本集群选用 **NGF 2.4.2 + Gateway API v1.4.1**（1.30 落在 2.4.x 支持区间）。版本不匹配的典型症状是控制器无法识别新版 CRD 字段或拒认 GatewayClass，**安装前务必查官方兼容矩阵**。

### 3.2 安装 Gateway API CRD（标准渠道 v1.4.1）

```bash
$ kubectl --kubeconfig ./kubeconfig apply -f standard-install-v1.4.1.yaml
customresourcedefinition.apiextensions.k8s.io/backendtlspolicies.gateway.networking.k8s.io created
customresourcedefinition.apiextensions.k8s.io/gatewayclasses.gateway.networking.k8s.io created
customresourcedefinition.apiextensions.k8s.io/gateways.gateway.networking.k8s.io created
customresourcedefinition.apiextensions.k8s.io/grpcroutes.gateway.networking.k8s.io created
customresourcedefinition.apiextensions.k8s.io/httproutes.gateway.networking.k8s.io created
customresourcedefinition.apiextensions.k8s.io/referencegrants.gateway.networking.k8s.io created

$ kubectl --kubeconfig ./kubeconfig get crd | grep gateway.networking
backendtlspolicies.gateway.networking.k8s.io     2026-10-13T05:27:32Z
gatewayclasses.gateway.networking.k8s.io         2026-10-13T05:27:32Z
gateways.gateway.networking.k8s.io               2026-10-13T05:27:33Z
grpcroutes.gateway.networking.k8s.io             2026-10-13T05:27:33Z
httproutes.gateway.networking.k8s.io             2026-10-13T05:27:33Z
referencegrants.gateway.networking.k8s.io        2026-10-13T05:27:34Z
```

> 环境提示：本沙箱环境无法直接访问 GitHub（`raw.githubusercontent.com` / release 下载均超时），官方文档通常让 `kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/standard-install.yaml`，此处改为经可达的代理下载后 apply；效果一致。CRD 顶层注释确认版本：`gateway.networking.k8s.io/bundle-version: v1.4.1`、`channel: standard`。

### 3.3 安装 NGINX Gateway Fabric（Helm，NodePort 暴露）

NGF 无云 LB 时用 NodePort 暴露数据面。我们用 chart：NGINX 官方 OCI 仓库 `oci://ghcr.io/nginx/charts/nginx-gateway-fabric`：

```bash
$ helm pull oci://ghcr.io/nginx/charts/nginx-gateway-fabric --version 2.4.2 --untar
Pulled: ghcr.io/nginx/charts/nginx-gateway-fabric:2.4.2
Digest: sha256:dc86ff2fad1f5f000cab6bf0d953f7a3c1347550834c41249798c670414ecc1a

$ export KUBECONFIG=$HOME/k3s-ops/kubeconfig
$ helm install ngf nginx-gateway-fabric -n nginx-gateway --create-namespace \
    --set nginx.service.type=NodePort \
    --set nginx.service.nodePorts[0].port=30025 \
    --set nginx.service.nodePorts[0].listenerPort=80
NAME: ngf
LAST DEPLOYED: Tue Oct 13 13:27:49 2026
NAMESPACE: nginx-gateway
STATUS: deployed
REVISION: 1
TEST SUITE: None
```

部署后 NGF 控制面 Pod 启动，并**自动创建默认 GatewayClass `nginx`**：

```bash
$ kubectl --kubeconfig ./kubeconfig -n nginx-gateway get pods -o wide
NAME                                            READY   STATUS      RESTARTS   AGE   IP            NODE               READINESS GATES
ngf-nginx-gateway-fabric-85cf4fdd69-l9bxj       1/1     Running     0          24s   10.42.1.136   k3s-demo-agent-1   <none>
ngf-nginx-gateway-fabric-cert-generator-j4djs   0/1     Completed   0          39s   10.42.1.135   k3s-demo-agent-1   <none>

$ kubectl --kubeconfig ./kubeconfig get gatewayclass
NAME    CONTROLLER                                   ACCEPTED   AGE
nginx   gateway.nginx.org/nginx-gateway-controller   True       25s
```

- `CONTROLLER = gateway.nginx.org/nginx-gateway-controller`：GatewayClass 认领控制器；
- `ACCEPTED=True`：控制器接受并已就绪处理该类网关。

---

## 4. 第一个 HTTPRoute 实测

### 4.1 部署示例应用

```yaml
# ~/k3s-ops/tmp/gateway-demo.yaml（示例）
apiVersion: v1
kind: Namespace
metadata:
  name: gateway-demo
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: gateway-demo
spec:
  replicas: 2
  selector:
    matchLabels: {app: web}
  template:
    metadata:
      labels: {app: web}
    spec:
      containers:
        - name: web
          image: nginx:latest
          ports: [{containerPort: 80}]
---
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: gateway-demo
spec:
  ports: [{port: 80, targetPort: 80}]
  selector: {app: web}
```

### 4.2 Gateway + HTTPRoute 清单

```yaml
# ~/k3s-ops/tmp/gateway-demo.yaml（续）—— Gateway 与 HTTPRoute
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: gateway
  namespace: gateway-demo
spec:
  gatewayClassName: nginx
  listeners:
    - name: http
      protocol: HTTP
      port: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: route-web
  namespace: gateway-demo
spec:
  parentRefs:
    - name: gateway
  hostnames:
    - "gateway-demo.local"
  rules:
    - matches:
        - path: {type: PathPrefix, value: /}
      backendRefs:
        - name: web
          port: 80
```

apply 后观察 Gateway 进入 `Programmed=True`，并自动生成数据面 Pod 与 NodePort Service：

```bash
$ kubectl --kubeconfig ./kubeconfig -n gateway-demo get gateway,httproute
NAME                              CLASS   ADDRESS         PROGRAMMED   AGE
gateway.gateway.networking.k8s.io/gateway   nginx   10.43.132.95   True         26s

NAME                                          HOSTNAMES                AGE
httproute.gateway.networking.k8s.io/route-web   ["gateway-demo.local"]   25s

$ kubectl --kubeconfig ./kubeconfig -n gateway-demo get svc,pods -o wide
NAME                 TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)        AGE
service/gateway-nginx   NodePort    10.43.132.95   <none>        80:30025/TCP   26s
service/web            ClusterIP   10.43.56.251   <none>        80/TCP         27s

NAME                             READY   STATUS    RESTARTS   AGE   IP            NODE
gateway-nginx-777b97cd7f-fwkp2   1/1     Running   0          45s   10.42.1.138   k3s-demo-agent-1
web-6487b8c5c8-gkc2w             1/1     Running   0          26s   10.42.1.137   k3s-demo-agent-1
```

- 数据面 Pod `gateway-nginx-*` 由 NGF 根据 Gateway 自动创建（NGINX 实例）；
- Service `gateway-nginx` 的 NodePort `30025` 即外部入口（与 nginx-ingress 的 30080/30444 并存，互不冲突）。

### 4.3 访问验证（Host 头路由）

```bash
$ curl -s -m 8 -H "Host: gateway-demo.local" http://192.168.56.10:30025/ | head -4
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
```

**真实踩坑（externalTrafficPolicy）：** 首次部署后只有 agent-1（数据面 Pod 所在节点）能返回页面，server-1 访问超时：

```bash
$ kubectl --kubeconfig ./kubeconfig -n gateway-demo get svc gateway-nginx -o jsonpath='{.spec.externalTrafficPolicy}'
Local
```

NGF 默认 `externalTrafficPolicy: Local`（保留客户端源 IP、少一跳 SNAT，但**只有数据面 Pod 所在节点会应答**）。改回 `Cluster` 后双节点均可访问：

```bash
$ helm upgrade ngf nginx-gateway-fabric -n nginx-gateway \
    --set nginx.service.type=NodePort \
    --set nginx.service.externalTrafficPolicy=Cluster \
    --set nginx.service.nodePorts[0].port=30025 --set nginx.service.nodePorts[0].listenerPort=80

$ curl -s -m 6 -H "Host: gateway-demo.local" http://192.168.56.10:30025/ | head -3
<!DOCTYPE html>
<html>
$ curl -s -m 6 -H "Host: gateway-demo.local" http://192.168.56.20:30025/ | head -3
<!DOCTYPE html>
<html>
```

HTTPRoute 状态（真实采集，`Accepted=True` + `ResolvedRefs=True` 双绿）：

```bash
$ kubectl --kubeconfig ./kubeconfig -n gateway-demo describe httproute route-web | grep -A14 "^Status:"
Status:
  Parents:
    Conditions:
      Last Transition Time:  2026-10-13T05:28:47Z
      Message:               The Route is accepted
      Observed Generation:   1
      Reason:                Accepted
      Status:                True
      Type:                  Accepted
      Last Transition Time:  2026-10-13T05:28:47Z
      Message:               All references are resolved
      Observed Generation:   1
      Reason:                ResolvedRefs
      Status:                True
      Type:                  ResolvedRefs
```

---

## 5. ReferenceGrant：跨命名空间引用的安全边界

Ingress 时代"跨命名空间后端的非标准做法"（`externalName` 或注解 hack）在 Gateway API 中被收编为标准能力：HTTPRoute 可以通过 `backendRefs[].namespace` 引用其他命名空间的 Service，但**必须先在目标命名空间创建 ReferenceGrant 显式授权**。这是零信任的默认策略：不授权 = 不可引用。

### 5.1 场景：gold 命名空间的后端

```yaml
# ~/k3s-ops/tmp/gold-backend.yaml（示例）
apiVersion: v1
kind: Namespace
metadata:
  name: gold
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: gold
spec:
  replicas: 1
  selector:
    matchLabels: {app: backend}
  template:
    metadata:
      labels: {app: backend}
    spec:
      containers:
        - name: httpd
          image: docker.1panel.live/library/httpd:2.4-alpine
          command: ["/bin/sh", "-c", "echo 'GOLD-BACKEND' > /usr/local/apache2/htdocs/index.html && httpd-foreground"]
          ports: [{containerPort: 80}]
---
apiVersion: v1
kind: Service
metadata:
  name: backend
  namespace: gold
spec:
  ports: [{port: 80, targetPort: 80}]
  selector: {app: backend}
```

### 5.2 无 ReferenceGrant：`RefNotPermitted` + 500

在 `gateway-demo` 建一条引用 `gold/backend` 的 HTTPRoute（**不建** ReferenceGrant）：

```yaml
# ~/k3s-ops/tmp/route-gold.yaml（示例）
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: route-gold
  namespace: gateway-demo
spec:
  parentRefs:
    - name: gateway
  hostnames:
    - "gold-ref.local"
  rules:
    - backendRefs:
        - name: backend
          namespace: gold
          port: 80
```

路由被接受（`Accepted=True`），但 `ResolvedRefs=False`：

```bash
$ kubectl --kubeconfig ./kubeconfig -n gateway-demo describe httproute route-gold | grep -E "Reason:|Type:|Message:" | head -8
      Message:               The Route is accepted
      Reason:                Accepted
      Type:                  Accepted
      Message:               spec.rules[0].backendRefs[0].namespace: Forbidden: Backend ref to Service gold/backend not permitted by any ReferenceGrant
      Reason:                RefNotPermitted
      Status:                False
      Type:                  ResolvedRefs
```

实际访问：数据面拒绝转发，返回 **500**：

```bash
$ curl -s -m 6 -H "Host: gold-ref.local" http://192.168.56.20:30025/ | head -5
<html>
<head><title>500 Internal Server Error</title></head>
<body>
<center><h1>500 Internal Server Error</h1></center>
<hr><center>nginx</center>
```

### 5.3 添加 ReferenceGrant：恢复访问

```yaml
# ~/k3s-ops/tmp/refgrant-gold.yaml（示例，注意 v1beta1）
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-gateway-demo
  namespace: gold
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: gateway-demo
  to:
    - group: ""
      kind: Service
```

```bash
$ kubectl --kubeconfig ./kubeconfig apply -f refgrant-gold.yaml
referencegrant.gateway.networking.k8s.io/allow-gateway-demo created

$ kubectl --kubeconfig ./kubeconfig -n gateway-demo describe httproute route-gold | grep -E "Reason:|Type:" | head -6
      Reason:                Accepted
      Type:                  Accepted
      Message:               All references are resolved
      Reason:                ResolvedRefs
      Type:                  ResolvedRefs

$ curl -s -m 6 -H "Host: gold-ref.local" http://192.168.56.20:30025/ | head -3
GOLD-BACKEND
```

**改前/改后对照：**

| 阶段 | `ResolvedRefs` | 访问结果 |
|---|---|---|
| 无 ReferenceGrant | False（`RefNotPermitted`） | `500 Internal Server Error` |
| 添加 ReferenceGrant | True（`ResolvedRefs`） | 返回 `GOLD-BACKEND` |

> **语义要点：** ReferenceGrant 是"**被引用方（gold）**"创建的对象，声明"允许 gateway-demo 命名空间里的 HTTPRoute 引用我的 Service"。它只影响 Gateway API 资源的解析合法性，不影响普通 Service→Pod 流量。

---

## 6. Gateway API 与 Ingress 对照总结

| 对照点 | Ingress（第 31 章 nginx-ingress） | Gateway API（本章 NGF） |
|---|---|---|
| API 模型 | 单资源 `Ingress` | 分层：`GatewayClass`/`Gateway`/`HTTPRoute`(+`ReferenceGrant`) |
| 集群级与租户级分离 | 无（全在 Ingress 对象上） | `GatewayClass` 集群级；`Gateway`/Route 命名空间级 |
| 高级策略 | 非标准注解（rewrite/CORS/限流/金丝雀） | 标准 API（`BackendTLSPolicy` 等，NGF 还有 `NginxGateway` 扩展） |
| 跨命名空间 | 无标准能力（依赖实现 hack） | `backendRefs.namespace` + `ReferenceGrant` 授权 |
| 四层 | 需独立实现 | Listener 可声明 TCP/UDP/TLS/Hostname |
| 状态反馈 | 通常只看 ing 的 ADDRESS / 404 探路 | `Accepted`/`Programmed`/`ResolvedRefs` 显式条件，排障友好 |
| 成熟度 | 最成熟稳定 | 仍在演进（v1 核心资源 GA，ReferenceGrant 尚 v1beta1） |
| 适用 | 现有集群、追求简单稳定 | 新项目、多团队权限分离、实现可替换 |

> **选型建议：** 单一实现、求稳用 Ingress；多团队/多实现/需要标准四层与跨命名空间策略时迁移 Gateway API。NGF 与 nginx-ingress 可**并存**（`GatewayClass` 与 `IngressClass` 互不干扰），可平滑渐进迁移。

---

## 7. 排障清单

1. **GatewayClass 不 `Accepted`** → 检查 `spec.controllerName` 是否与控制器一致；确认控制器版本支持当前集群 Kubernetes 版本（本环境 NGF 2.4.2 ↔ k3s 1.30）。
2. **Gateway 不 `Programmed`** → `kubectl --kubeconfig ./kubeconfig describe gateway <name> -n <ns>` 看 Listener Conditions；检查 `gatewayClassName`、端口冲突、`externalTrafficPolicy=Local` 时仅数据面所在节点可达（见 §4.3）。
3. **HTTPRoute `ResolvedRefs=False / RefNotPermitted`** → 目标命名空间缺 `ReferenceGrant`；补授权（§5.3）。注意 `ReferenceGrant` 用 `v1beta1`。
4. **跨命名空间引用配置正确但报错** → 确认 `backendRefs[].namespace` 显式写上；同一命名空间引用可不写 namespace。
5. **路由 Accepted 但访问 404** → hostname 不匹配（HTTPRoute 的 `hostnames` 与请求 Host 必须一致，Gateway Listener 的 `hostname` 若设置则必须覆盖）；path 规则优先级。
6. **NodePort 只部分节点可达** → `externalTrafficPolicy` 为 `Local`（§4.3 真实案例）。
7. **`no matches for kind "ReferenceGrant"`** → CRD 安装后 kubectl discovery 缓存过期：`rm -rf ~/.kube/cache/discovery` 重试；或 apiVersion 写错（应 `v1beta1`）。

---

## 8. Rancher 界面对照

Rancher UI 对 Gateway API 的支持有限（跟随上游版本），对照思路如下：

| 路径 | 对应 kubectl | 用途 |
|---|---|---|
| **集群 → Service Discovery → Ingresses**（已支持） | `kubectl --kubeconfig ./kubeconfig get ing -A` | 现有 Ingress 一览（Gateway 迁移前的存量） |
| **集群 → Explorer → Custom Resources → gateway.networking.k8s.io**（CRD 已注册） | `kubectl --kubeconfig ./kubeconfig get gatewayclass,gateway,httproute,referencegrant -A` | 按 CRD 分组查看 Gateway API 资源 |
| **Workload → Pods → nginx-gateway / gateway-demo** | `kubectl --kubeconfig ./kubeconfig -n nginx-gateway get pods` | 查看 NGF 控制面与数据面 Pod |
| **Service Discovery → Services → gateway-nginx** | `kubectl --kubeconfig ./kubeconfig -n gateway-demo get svc gateway-nginx` | 查看 NodePort 30025 映射 |

> 提示：Rancher 对 CRD 的管理依赖其在当前集群发现到的 API；`gateway.networking.k8s.io` 6 个 CRD 注册后即可在 UI 中浏览（列表视图按 CRD 呈现）。

---

## 动手练习

1. **模型复述**：用一句话分别解释 GatewayClass、Gateway、HTTPRoute、ReferenceGrant 的职责与作用域（集群级/命名空间级）。
2. **版本核对**：执行 `kubectl --kubeconfig ./kubeconfig api-resources | grep gateway.networking`，说出哪些资源是 v1、哪个仍是 v1beta1，为什么。
3. **路由验证**：在 `gateway-demo` 新增第二个 HTTPRoute `route-v2`（hostname `v2.local`，路径 `/api` 前缀）转发到 `web`，用 curl 分别验证 `v2.local/` 与 `v2.local/api` 的行为差异。
4. **ReferenceGrant 反向验证**：删除 `gold` 里的 ReferenceGrant，观察 `route-gold` 的 `ResolvedRefs` 变化与访问结果（做完整套：删授权 → 验证 → 恢复授权）。
5. **改 serviceType 实验**：若把 NGF 改为 `ClusterIP`（去掉 nodePorts）再创建 Gateway，观察 Service 类型变化与可达性，理解 Listener 与 Service 的联动。
6. **Ingress 对照**：在第 31 章 Ingress 上实现同样的 host 路由，对比两套 YAML 的复杂度与"状态反馈"差异（`kubectl describe` 看两类资源的状态字段）。
7. **清理演练**：按附录清理命令卸载 NGF 与演示命名空间，验证 6 个 CRD 删除后 `gatewayclass` 查询为空。

<details>
<summary>参考答案</summary>

1. **GatewayClass**（集群级，绑定某个控制器实现）；**Gateway**（命名空间级，定义监听器与外部入口）；**HTTPRoute**（命名空间级，定义主机/路径路由规则）；**ReferenceGrant**（命名空间级，授权**跨命名空间**的对象引用）。
2. `kubectl api-resources | grep gateway.networking`：`gatewayclasses/gateways/httproutes/grpcroutes/backendtlspolicies` 为 **v1**；`referencegrants` 仍为 **v1beta1**（standard 通道中它尚未升到 v1，属于演进较慢的 API）。
3. 新建 `route-v2`（`hostnames: [v2.local]`、`path: /api` 前缀 → `web`），`curl -H "Host: v2.local" http://<node>:30025/api` → 200；`curl -H "Host: v2.local" http://<node>:30025/` → 404（不匹配 `/api` 前缀）。
4. 删除 `gold` 的 ReferenceGrant → `route-gold` 的 `ResolvedRefs` 变为 `RefNotPermitted`、访问返回 500；恢复 ReferenceGrant → 变回 `Resolved`、返回后端内容。
5. 把 NGF 改为 `ClusterIP`（去掉 nodePorts）重建 Gateway → 生成的 Service 变为 `ClusterIP`，**集群外不可达**，只能集群内访问。说明 Listener 的暴露方式由 NGF 的 Service 类型决定。
6. Ingress host 路由 vs HTTPRoute：HTTPRoute 支持更细的匹配（方法/头/查询/权重）与更丰富的状态反馈（`status.parents` 的 `conditions`）；Ingress 依赖注解拼装、状态字段少。
7. 清理：`helm uninstall ngf -n nginx-gateway` + 删除三个命名空间 + 删除 6 个 CRD，之后 `kubectl get gatewayclass` 为空。

</details>

---

## 附录：本章真实采集片段与清理

**安装/卸载命令：**

```bash
# 卸载 NGF（Helm release 与命名空间）
helm uninstall ngf -n nginx-gateway
kubectl --kubeconfig ./kubeconfig delete ns nginx-gateway gateway-demo gold

# 删除 Gateway API CRD（⚠️ 会级联删除所有 gateway 类资源）
kubectl --kubeconfig ./kubeconfig delete crd \
  backendtlspolicies.gateway.networking.k8s.io \
  gatewayclasses.gateway.networking.k8s.io \
  gateways.gateway.networking.k8s.io \
  grpcroutes.gateway.networking.k8s.io \
  httproutes.gateway.networking.k8s.io \
  referencegrants.gateway.networking.k8s.io
```

**本章留存证据清单：**

- 6 个 Gateway API CRD（v1.4.1 standard）已安装：`gatewayclasses/gateways/httproutes/grpcroutes/backendtlspolicies/referencegrants`
- NGF 2.4.2：控制面 Deployment `ngf-nginx-gateway-fabric`、默认 GatewayClass `nginx`（`gateway.nginx.org/nginx-gateway-controller`）
- 演示对象：`gateway-demo`（web 应用 + Gateway `gateway` + HTTPRoute `route-web`/`route-gold`）、`gold`（backend + ReferenceGrant）
- 外部入口：NodePort `30025`（HTTP 80 / listener），`externalTrafficPolicy: Cluster`
- NGF 自研扩展 CRD `NginxGateway`（`gateway.nginx.org/v1alpha1`）随 chart 自动安装，用于控制面全局配置

> 本章完成实测后，`gateway-demo` 与 `gold` 命名空间、NGF 控制面/数据面均保留在集群中，方便后续章节与练习直接使用；如需彻底清理按上文卸载即可。