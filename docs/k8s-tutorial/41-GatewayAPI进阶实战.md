# 41 Gateway API 进阶实战

## 本章目标

- 掌握 HTTPRoute 的**进阶匹配**：路径、方法、请求头、查询参数
- 掌握**流量权重切分**（金丝雀/蓝绿发布），并理解权重是**概率**行为——必须聚合验证
- 掌握 **Filters**：URL 重写（`URLRewrite`）、请求/响应头改写（`RequestHeaderModifier` / `ResponseHeaderModifier`）
- 了解 **超时**（`timeouts`）与 `backendRefs` 的失败语义，以及 **GRPCRoute / TLSRoute** 在本集群的现状
- 建立 **Ingress → Gateway API** 的能力迁移对照，为后续演进做准备
- 全部基于第 37 章已部署的 NGINX Gateway Fabric 真实实测

> 本章所有命令统一使用 `kubectl --kubeconfig ./kubeconfig`。文档中路径统一用 `~/k3s-ops` 表示。

---

## 1. 回顾与本章环境

第 37 章装了 **NGINX Gateway Fabric（NGF）2.4.2**，并创建了 Gateway（ns `gateway-demo`）与示例 HTTPRoute。本章直接复用它做进阶实验。

```bash
kubectl --kubeconfig ./kubeconfig -n gateway-demo get gateway,httproute,svc
kubectl --kubeconfig ./kubeconfig get gatewayclass
```

```text
NAME                                        CLASS   ADDRESS        PROGRAMMED
gateway.gateway.networking.k8s.io/gateway   nginx   10.43.132.95   True

NAME                   TYPE        CLUSTER-IP     PORT(S)
service/gateway-nginx   NodePort   10.43.132.95   80:30025/TCP

NAME    CONTROLLER                                   ACCEPTED
nginx   gateway.nginx.org/nginx-gateway-controller   True
```

关键约定：

- Gateway `gateway` 只有一个 listener `http`（端口 80，**不限定 hostname**），`allowedRoutes.namespaces.from: Same`——所以本章新路由都必须建在 `gateway-demo` 里；
- 数据面 Service `gateway-nginx` 是 **NodePort `80:30025`**，两个节点 IP（`192.168.56.10` / `192.168.56.20`）都可访问；
- 外部测试统一用 `curl -H 'Host: <hostname>' http://<节点IP>:30025/`。

> 本章新增路由各自用一个 hostname（`weight.local` / `header.local` / `rewrite.local`），互不干扰。

---

## 2. 准备两个"可区分"的后端

要做权重/路由实验，先要能一眼看出请求打到了哪个后端。下面用启动命令写入不同的首页内容（注意用 `exec nginx ...` 保持 PID 1 语义，且**每次重启都会重写**，比事后 `exec` 写文件更可复现）：

```yaml
# ~/k3s-ops/tmp/ch41-backends.yaml（示例，节选）
apiVersion: apps/v1
kind: Deployment
metadata: {name: web-v1, namespace: gateway-demo}
spec:
  replicas: 1
  selector: {matchLabels: {app: web-v1}}
  template:
    metadata: {labels: {app: web-v1}}
    spec:
      containers:
        - name: nginx
          image: nginx:latest
          command: ["/bin/sh", "-c"]
          args: ["echo V1 > /usr/share/nginx/html/index.html && exec nginx -g 'daemon off;'"]
          ports: [{containerPort: 80}]
---
# 另一个是 web-v2，内容为 V2，其余相同；再各配一个同名 Service（port 80）
```

```bash
kubectl --kubeconfig ./kubeconfig apply -f ~/k3s-ops/tmp/ch41-backends.yaml
kubectl --kubeconfig ./kubeconfig -n gateway-demo run curl --rm -i --restart=Never --image=busybox:1.36 -- \
  sh -c 'echo -n "web-v1: "; wget -qO- http://web-v1/; echo -n "web-v2: "; wget -qO- http://web-v2/'
# web-v1: V1
# web-v2: V2
```

---

## 3. 真实实测一：流量权重切分（金丝雀）

`backendRefs` 里给每个后端一个 `weight`，Gateway 按**权重比例**分发：

```yaml
# ~/k3s-ops/tmp/ch41-weights.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: route-weights, namespace: gateway-demo}
spec:
  parentRefs:
    - name: gateway
  hostnames:
    - weight.local
  rules:
    - backendRefs:
        - {name: web-v1, port: 80, weight: 90}
        - {name: web-v2, port: 80, weight: 10}
```

```bash
kubectl --kubeconfig ./kubeconfig apply -f ~/k3s-ops/tmp/ch41-weights.yaml
kubectl --kubeconfig ./kubeconfig -n gateway-demo get httproute route-weights \
  -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} {end}{"\n"}'
# Accepted=True ResolvedRefs=True
```

**关键：权重是概率的，单次请求说明不了任何问题。**

```bash
# 单次请求——可能恰好命中 V2，极具误导性
curl -s -H 'Host: weight.local' http://192.168.56.10:30025/
# V2

# 聚合 40 次才有意义
for i in $(seq 1 40); do curl -s -H 'Host: weight.local' http://192.168.56.10:30025/; done | sort | uniq -c
#      36 V1
#       4 V2
```

`36:4 = 90:10`，与配置吻合（样本越大概率越准）。这就是**金丝雀发布**的基础：先给新版本 10% 流量观察，稳定后再逐步调到 100%。

> 权重是**相对比例**，不要求加起来等于 100：`weight: 9` 与 `weight: 1` 的效果同样是 90/10。

---

## 4. 真实实测二：基于请求头的路由

`matches.headers` 可以按请求头精确匹配。规则**从上到下依次匹配、命中即止**，所以"特例规则"要放在前面：

```yaml
# ~/k3s-ops/tmp/ch41-header.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: route-header, namespace: gateway-demo}
spec:
  parentRefs:
    - name: gateway
  hostnames:
    - header.local
  rules:
    - matches:                                   # 规则 1：命中 header 的走 v2
        - headers:
            - {name: X-Canary, value: always}
      backendRefs:
        - {name: web-v2, port: 80}
    - backendRefs:                               # 规则 2：其余走 v1
        - {name: web-v1, port: 80}
```

```bash
kubectl --kubeconfig ./kubeconfig apply -f ~/k3s-ops/tmp/ch41-header.yaml

# 带 X-Canary: always
for i in $(seq 1 10); do curl -s -H 'Host: header.local' -H 'X-Canary: always' http://192.168.56.10:30025/; done | sort | uniq -c
#      10 V2
# 不带该头
for i in $(seq 1 10); do curl -s -H 'Host: header.local' http://192.168.56.10:30025/; done | sort | uniq -c
#      10 V1
```

与权重不同，**基于头的路由是确定性的**：满足 header 就 100% 命中 v2。生产上常用它做"内测用户全量试用新版本"（如按 `X-Beta: true` 或 Cookie 路由）。

除了 `headers`，`matches` 还支持（全部可组合）：

| 匹配维度 | 字段 | 示例 |
|---|---|---|
| 路径 | `path` | `PathPrefix: /api`、`Exact: /healthz` |
| 方法 | `method` | `GET` / `POST` |
| 请求头 | `headers` | `X-Canary: always` |
| 查询参数 | `queryParams` | `version=v2` |

---

## 5. 真实实测三：Filters（改写）

Filters 在**转发前/后**修改请求或响应。最常见的两类是路径重写和头改写：

```yaml
# ~/k3s-ops/tmp/ch41-filters.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: route-rewrite, namespace: gateway-demo}
spec:
  parentRefs:
    - name: gateway
  hostnames:
    - rewrite.local
  rules:
    - matches:
        - path: {type: PathPrefix, value: /api}
      filters:
        - type: URLRewrite                       # 把 /api 前缀改成 /
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /
        - type: ResponseHeaderModifier           # 给响应加一个头
          responseHeaderModifier:
            add:
              - {name: X-From-Gateway, value: ngf}
      backendRefs:
        - {name: web-v1, port: 80}
```

**验证一：URLRewrite 生效。** 后端 nginx 只认 `/`，不认 `/api`。经 Gateway 访问 `/api/` 却返回 200，说明前缀被重写掉了；而不带该 filter 的 host 访问 `/api/` 就是 404：

```bash
curl -s -o /dev/null -w 'rewrite.local/api/ -> %{http_code}\n' -H 'Host: rewrite.local' http://192.168.56.10:30025/api/
# rewrite.local/api/ -> 200

curl -s -o /dev/null -w 'weight.local/api/  -> %{http_code}\n' -H 'Host: weight.local' http://192.168.56.10:30025/api/
# weight.local/api/  -> 404        ← 没有 rewrite filter
```

最硬的证据在后端访问日志里——它看到的是**重写后的**路径：

```bash
kubectl --kubeconfig ./kubeconfig -n gateway-demo logs deploy/web-v1 --tail=3
# 10.42.0.100 - - [...] "GET / HTTP/1.1" 200 3 ...    ← 请求路径已是 /，不是 /api/
```

**验证二：ResponseHeaderModifier 生效。**

```bash
curl -s -D - -o /dev/null -H 'Host: rewrite.local' http://192.168.56.10:30025/api/ | grep -i 'x-from-gateway\|^HTTP'
# HTTP/1.1 200 OK
# X-From-Gateway: ngf
```

**常用 Filters 一览：**

| Filter | 作用 | 观测方式 |
|---|---|---|
| `URLRewrite` | 重写路径（`ReplacePrefixMatch` / `ReplaceFullPath`）或 hostname | 后端访问日志/返回码 |
| `RequestHeaderModifier` | 增/改/删**请求**头（`set`/`add`/`remove`） | 后端需回显请求头才可见 |
| `ResponseHeaderModifier` | 增/改/删**响应**头 | `curl -D -` 直接可见 |
| `RequestRedirect` | 重定向（301/302/…，可改 scheme/host/port） | `curl -D -` 看 `Location` |

> `RequestHeaderModifier` 客户端**看不见**（改的是发往后端的请求），要验证得让后端把收到的头回显出来。上文特意用可观测的 `ResponseHeaderModifier` 做演示。

---

## 6. 超时与 backendRefs 失败语义

`HTTPRouteRule.timeouts` 控制网关到后端的超时（Support: Extended，本集群 NGF 支持）：

```yaml
rules:
  - timeouts:
      request: 10s          # 整个客户端事务
      backendRequest: 3s    # 网关到单个后端的单次请求
    backendRefs:
      - {name: web-v1, port: 80}
```

- `request`：从网关收到请求到返回响应的**总**预算；
- `backendRequest`：网关到后端**单次**调用的预算（重试时每次单独计算）。

**失败语义**：若一个规则的所有 `backendRefs` 都无效且规则无 filter，则**所有**匹配流量收到 `503 / UNAVAILABLE`；部分后端无效时，无效者从负载均衡集合中剔除（并触发 `ResolvedRefs=False`）。

> ⚠️ 版本细节：本集群安装的 CRD 里 **没有 `retry` 字段**（`kubectl explain httproutes.gateway.networking.k8s.io.spec.rules.retry` 返回 `field "retry" does not exist`）；重试能力随 Gateway API 版本/实现演进，使用前请在**你的**集群用 `kubectl explain` 确认，别照抄网上配置。

---

## 7. GRPCRoute / TLSRoute 现状

本章环境已安装的 Gateway API CRD（v1）：

```bash
kubectl --kubeconfig ./kubeconfig api-resources | grep gateway.networking
# gatewayclasses / gateways / httproutes / grpcroutes / referencegrants / backendtlspolicies
```

- **GRPCRoute**：已安装（v1）。Gateway 的 listener 也声明支持：`supportedKinds: HTTPRoute, GRPCRoute`。匹配基于 gRPC 语义：

  ```bash
  kubectl --kubeconfig ./kubeconfig explain grpcroutes.gateway.networking.k8s.io.spec.rules.matches
  # matches: - method: {service: foo.bar, method: X} , headers: {...}
  ```

  即按 `service/method`（而非 URL 路径）路由，天然支持 gRPC 的流量切分/金丝雀。

- **TLSRoute**：本集群**未安装**对应 CRD（属于 Gateway API 的 **experimental 通道**，标准通道不含）。TCP/TLS 透传类需求要用它时需要额外安装 experimental CRD，且需数据面支持。
- **BackendTLSPolicy**：已安装，用于规定网关到**后端**的 TLS（如后端是 HTTPS 的场景）。

> 结论：HTTP/HTTPS 用 `HTTPRoute`，gRPC 用 `GRPCRoute`（都已具备）；纯 TCP/TLS 透传要评估 `TLSRoute`（当前未装）。

---

## 8. Ingress → Gateway API 迁移对照

Gateway API 本质是把 Ingress 时代"塞进注解"的能力**升级为一等字段**：

| 能力 | Ingress（注解） | Gateway API（原生字段） |
|---|---|---|
| 主机/路径路由 | `rules[].host` + `path` | `hostnames` + `matches.path` |
| 请求头/方法/查询匹配 | 依赖注解，各家实现不一 | `matches.headers/method/queryParams`（标准） |
| 多后端权重 | 注解（如 `canary-weight`） | `backendRefs[].weight`（标准） |
| 路径/头改写 | `rewrite-target` 等注解 | `filters: URLRewrite / *HeaderModifier`（标准） |
| 重定向 | 注解 | `filters: RequestRedirect` |
| 后端 TLS | 注解 | `BackendTLSPolicy` |
| 跨命名空间引用 | 隐式 | 显式 `ReferenceGrant` |
| 角色分离 | 无 | `GatewayClass` / `Gateway` / `HTTPRoute` 三层分权 |

**迁移思路**：先并存——保留现有 Ingress，用 Gateway 承载新流量；逐条把 Ingress 的"注解语义"翻译成 HTTPRoute 的字段；验证等价后再摘掉 Ingress。

---

## 9. 排障清单

| 现象 | 常见原因 | 排查命令 |
|---|---|---|
| 新路由 404 | hostname 不匹配 / 路由不在 `gateway-demo`（listener `allowedRoutes=Same`） | `kubectl --kubeconfig ./kubeconfig -n gateway-demo get httproute <r> -o yaml` 看 `status.parents` |
| 路由一直 `Accepted=False` | `parentRefs` 名字错 / 引用的 Gateway 不存在 | `kubectl --kubeconfig ./kubeconfig -n gateway-demo describe httproute <r>` |
| `ResolvedRefs=False` | `backendRefs` 指向的 Service 不存在或端口错 | 看 `status.parents[].conditions` 的 message |
| 权重"没生效" | 只测了一两次（概率） | 聚合几十次再统计 |
| 改写没生效 | filter 写在了错误的 rule / 路径没匹配 | 后端访问日志看实际收到路径 |
| 跨命名空间后端不通 | 缺 `ReferenceGrant` | `kubectl --kubeconfig ./kubeconfig get referencegrant -A` |
| 节点访问不通 | NodePort/防火墙/节点 IP 选错 | 分别用两个节点 IP 测 |

---

## 10. Rancher 界面对照

| 路径 | 对应 kubectl | 用途 |
|---|---|---|
| **集群 → More Resources → gateway.networking.k8s.io → Gateways** | `kubectl --kubeconfig ./kubeconfig -n gateway-demo get gateway` | 查看 Gateway 的 CLASS / ADDRESS / PROGRAMMED |
| **…→ HTTPRoutes** | `kubectl --kubeconfig ./kubeconfig -n gateway-demo get httproute` | 查看路由列表、hostnames、附加的父 Gateway |
| **HTTPRoute 详情 → YAML** | `kubectl --kubeconfig ./kubeconfig -n gateway-demo get httproute <r> -o yaml` | 查看 `rules/matches/filters/backendRefs` 与 `status.parents` 条件 |
| **集群 → Events** | `kubectl --kubeconfig ./kubeconfig get events -n gateway-demo` | 查看路由绑定/引用解析失败事件 |

> 注意：Gateway API 是"扩展资源"，入口在 Rancher 的 **More Resources**（Rancher 没有专门的 Gateway API 顶层菜单）；网关是否真正生效，最可靠的仍是 `status.parents[].conditions` 与 `curl` 实测。

---

## 动手练习

1. **权重换算**：把 `route-weights` 改成 `web-v1: 1`、`web-v2: 4`，预测 50 次请求的大致分布，再实测验证。
2. **为什么必须聚合**：解释"单次请求返回 V2"能不能说明权重失效，并给出正确的验证方法。
3. **header 匹配**：把 `route-header` 的匹配条件改成 `queryParams: version=v2`，验证 `?version=v2` 会打到哪个后端。
4. **URLRewrite 证据**：说明为什么"经 Gateway 访问 `/api/` 返回 200"能证明重写生效，并给出后端日志级别的证据。
5. **RequestHeaderModifier 验证**：用 `RequestHeaderModifier` 给请求加 `X-Tenant: demo`，设计一个能"看见"它的验证方法。
6. **timeouts**：给某条规则加 `backendRequest: 1s`，说明它和 `request` 的区别。
7. **迁移对照**：把一条带 `rewrite-target` 注解的 Ingress，改写成等价的 HTTPRoute（写出 yaml 骨架）。

<details>
<summary>参考答案</summary>

1. `1:4` 即 20%/80%。50 次大约 `10 V1 / 40 V2`（实测会有波动，样本越大越接近）。
2. 不能。权重是**概率**分发，单次命中 V2 完全正常。正确方法：发**几十次以上**请求并统计分布（如 `for ... | sort | uniq -c`），比例接近配置才算生效。
3. 把规则 1 的 `headers` 换成 `queryParams: [{name: version, value: v2}]`；请求 `curl -H 'Host: header.local' 'http://192.168.56.10:30025/?version=v2'` 会命中该规则 → 返回 `V2`，不带查询参数则走规则 2 → `V1`。
4. 因为后端 nginx **没有** `/api` 这个路径（直接访问会 404），而经 Gateway 却返回 200，唯一合理解释就是 filter 把 `/api` 重写成了 `/`。后端证据：`kubectl logs deploy/web-v1` 里出现的是 `"GET / HTTP/1.1"`。
5. `RequestHeaderModifier` 改的是"网关→后端"的请求头，客户端看不到。验证方法：让后端回显收到的请求头（如挂一个能 dump headers 的镜像/服务），再用 `curl` 经 Gateway 访问，检查回显里是否含 `X-Tenant: demo`。
6. `request` 是整个客户端事务的总超时；`backendRequest` 是网关到后端**单次**调用的超时（有重试时每次单独计）。后端较慢而重试较多时，可能 `request` 还没到就被多个 `backendRequest` 影响。
7. 骨架：

   ```yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: HTTPRoute
   metadata: {name: x, namespace: gateway-demo}
   spec:
     parentRefs: [{name: gateway}]
     hostnames: ["app.example.com"]
     rules:
       - matches: [{path: {type: PathPrefix, value: /api}}]
         filters:
           - type: URLRewrite
             urlRewrite: {path: {type: ReplacePrefixMatch, replacePrefixMatch: /}}
         backendRefs: [{name: svc, port: 80}]
   ```
   （`rewrite-target` 注解 → `URLRewrite` filter）。

</details>

---

## 附录：本章真实采集片段与清理

**采集环境**：第 37 章部署的 NGINX Gateway Fabric 2.4.2，Gateway `gateway`（ns `gateway-demo`），数据面 NodePort `30025`。

**1. 权重切分（`weight.local`）**：单次请求返回 `V2`；40 次聚合 **36 V1 / 4 V2**（≈90/10）。

**2. 头路由（`header.local`）**：带 `X-Canary: always` → 10/10 `V2`；不带 → 10/10 `V1`。

**3. 改写（`rewrite.local`）**：

```text
rewrite.local/api/ -> 200        # URLRewrite 生效
weight.local/api/  -> 404        # 无 filter 的对照
后端 web-v1 日志    -> "GET / HTTP/1.1" 200
响应头             -> X-From-Gateway: ngf
```

**4. 两节点可达性**：`192.168.56.10:30025` 与 `192.168.56.20:30025` 对上述 hostname 均返回 200。

**5. 资源现状**：`grpcroutes`（v1）已装；`TLSRoute` CRD 未装（experimental）；`spec.rules.retry` 字段不存在。

**本章创建的资源（ns `gateway-demo`）：**

- Deployment + Service：`web-v1`、`web-v2`（保留，供后续实验）
- HTTPRoute：`route-weights`、`route-header`、`route-rewrite`（保留）
- 第 37 章原有：`route-web`、`route-gold` 未改动

**清理命令：**

```bash
kubectl --kubeconfig ./kubeconfig -n gateway-demo delete httproute route-weights route-header route-rewrite
kubectl --kubeconfig ./kubeconfig -n gateway-demo delete deploy web-v1 web-v2
kubectl --kubeconfig ./kubeconfig -n gateway-demo delete svc web-v1 web-v2
```

> ⚠️ 权重/匹配都是**概率或顺序敏感**的行为：验证时务必聚合次数、并注意规则顺序（自上而下、命中即止）。
