# 31 Ingress 深入实战与证书管理

## 本章目标

- 真正搞懂 Ingress 的请求路径：域名 → IngressController → Service → Pod，以及每一层各自"管什么"
- 掌握 ingress-nginx 最常用的注解家族：路径重写、CORS、限流、会话保持、金丝雀
- 用真实集群逐个验证（改前/改后对照），并踩出 4 个真实大坑（含金丝雀的连环坑）
- 用 cert-manager 从零签发一张证书：自签 ClusterIssuer → CA → CA Issuer → 叶证书 → Ingress TLS → HTTPS 实测 → 自动续期
- 学会读 ingress-nginx 的 nginx.conf 与控制器日志来定位问题

> 本章所有输出均来自本集群（k3s v1.30.2+k3s2、ingress-nginx v1.11.0、cert-manager v1.20.2）真实执行。

---

## 1. 前置盘点：本集群的 Ingress 现状

```bash
# 有哪些 IngressClass
kubectl --kubeconfig ./kubeconfig get ingressclass -A
# NAME    CONTROLLER             PARAMETERS   AGE
# nginx   k8s.io/ingress-nginx   <none>       137d

# 控制器暴露方式
kubectl -n ingress-nginx get svc
# NAME                                 TYPE        CLUSTER-IP     PORT(S)                      AGE
# service/ingress-nginx-controller     NodePort    10.43.197.40   80:30080/TCP,443:30444/TCP   137d
```

三条与本集群强相关的事实（后面都会用到）：

| 事实 | 说明 |
|---|---|
| **只有一个 IngressClass `nginx`** | 实现是 ingress-nginx（替代 k3s 默认 Traefik 的决定见 `docs/architecture.md`） |
| **IngressClass 没有默认标注** | `ingressclass.kubernetes.io/is-default-class` 为**空** → 每个 Ingress 必须显式写 `ingressClassName: nginx`，不写就没人接管它（静默 404） |
| **ADDRESS 字段 = Service ClusterIP** | 有 TLS/路由后你会发现 Ingress 的 `.status.loadBalancer.ingress[0].ip` 是 `10.43.197.40`（controller 的 Service IP）。这是因为控制器用 `--publish-service` 把 Service 地址发布上去——**它不代表可访问入口，别被误导** |

本集群 cert-manager 已装好（Rancher 依赖），版本 v1.20.2：

```bash
kubectl get clusterissuer,issuer -A
# NAMESPACE      NAME                             READY   AGE
# cattle-system   issuer.cert-manager.io/rancher   True    137d   # Rancher 自用的自签 issuer
```

我们自己一个证书都没有——正好从零做一个"私有 CA → 叶证书"。

---

## 2. 请求路径与各层职责（先建立心智模型）

```
客户端
  │  http://ing.lab.k3s.local:30080/order
  ▼
ingress-nginx controller  (NodePort 30080/30444, 运行在集群内)
  │  1) 按 Host + Path 匹配 Ingress 规则   ← Ingress 对象定义"哪条规则去哪个 Service"
  │  2) 套用该 Ingress 的注解(重写/限流/会话保持/金丝雀...)
  │  3) 按 IngressClass 挑选控制器        ← 本集群只有 nginx
  ▼
Service (ClusterIP 负载均衡, 只做端口转发 + 选后端)
  ▼
Pod (真正处理请求, 返回 200/404/503...)
```

关键理解：

1. **Ingress 不等于负载均衡器**。它只是"路由规则"（networking.k8s.io/v1 的 Ingress 对象）；真正干活的是 `IngressClass` 指向的控制器（这是唯一"带流量"的组件）。
2. **控制器默认只把路径原样转发**。`pathType: Prefix` 的 `/a` 会原样发给后端（后端没有 `/a` 就 404——本章 §4.2 会实踩这个坑）。要改路径必须显式加 `rewrite-target`。
3. **TLS 的终止发生在控制器**（443 解密 → 80 转发给后端），所以后端 Pod 收到的一律是明文 HTTP，除非配了 `proxy-ssl` 类注解做二次加密。

---

## 3. Ingress API 速览（v1 字段对照实测）

一个 Ingress 的骨架（本集群真实使用）：

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ing-basic
  namespace: ing-demo
spec:
  ingressClassName: nginx          # ← 必填（本集群无默认 class）
  tls:                             # ← 可选，证书段
    - hosts: [tls.lab.k3s.local]
      secretName: ing-tls
  rules:                           # ← 主机名 → 路径 → Service 表
    - host: ing.lab.k3s.local
      http:
        paths:
          - path: /                # 路径
            pathType: Prefix       # Prefix / Exact / ImplementationSpecific
            backend:
              service:
                name: app-a        # 只认 Service 名，不认端口名也行（number: 80）
                port: {number: 80}
```

`pathType` 三选一（实测补充）：

| 类型 | 匹配规则 | 说明 |
|---|---|---|
| `Prefix` | `/a` 匹配 `/a`、`/a/*` | 前缀匹配，**不剥前缀**（坑见 §4.2） |
| `Exact` | 必须完全相等 | 精确匹配，`/a` 不匹配 `/a/` |
| `ImplementationSpecific` | 交给控制器实现定义 | ingress-nginx 允许写正则，如 `/v1(/|$)(.*)`（§4.3） |

---

## 4. 实站：注解家族逐个验证（真实）

### 4.1 准备测试后端

用集群里已有的 `nginx:latest`（无需拉镜像），三个 ConfigMap 分别返回 `SERVICE-A/B/C` 以便区分后端：

```yaml
# ConfigMap app-a-www → index.html 内容: SERVICE-A
apiVersion: v1
kind: ConfigMap
metadata: {name: app-a-www, namespace: ing-demo}
data:
  index.html: |
    SERVICE-A
---
# Deployment app-a: nginx:latest 挂载该 ConfigMap 到 /usr/share/nginx/html
# Service app-a: 80 → 80
```

后续所有域名统一用 `.lab.k3s.local`（不存在的测试域名，配合 `curl -H Host:` 使用），入口即宿主机可达的 NodePort：

```bash
BASE=http://192.168.56.10:30080      # 宿主机直连 VM hostonly 网卡
```

### 4.2 基础路由 + 多路径 + 第一个真坑：pathType 不剥路径（改前/改后）

两个 Ingress：

- `ing-basic`：`ing.lab.k3s.local` `/` → app-a
- `ing-multipath`：`multi.lab.k3s.local` `/a` → app-a、`/b` → app-b

```bash
$ curl -s -H 'Host: ing.lab.k3s.local' $BASE/          # → SERVICE-A (HTTP 200)
$ curl -s -H 'Host: multi.lab.k3s.local' $BASE/a       # → 404 !!
$ curl -s -H 'Host: multi.lab.k3s.local' $BASE/b       # → 404 !!
```

**改前现象**：`/a`、`/b` 都返回 404，且 404 页面底部写着 `nginx/1.31.6`——这是**后端 nginx** 的错误页（后端没有 `/a` 这个文件）。

**为什么不生效**：`pathType: Prefix` 只负责"这条规则匹配哪些路径"，**匹配后转发给后端时路径原样不变**。后端收到 `/a`，在自己的文件系统里找不到，返回 404。控制器并没有做任何改写。

**改后**：给 `ing-multipath` 加一行注解把它修好：

```bash
$ kubectl -n ing-demo annotate ingress ing-multipath \
    nginx.ingress.kubernetes.io/rewrite-target=/
$ curl -s -H 'Host: multi.lab.k3s.local' $BASE/a        # → SERVICE-A (HTTP 200)
$ curl -s -H 'Host: multi.lab.k3s.local' $BASE/b        # → SERVICE-B (HTTP 200)
$ curl -s -H 'Host: multi.lab.k3s.local' $BASE/zzz      # → HTTP 404（无规则匹配）
```

> **排障口诀**：客户端返回的 404 要看"响应体是谁的"。页面带 `nginx/x.x.x` 字样 = 请求已到后端、后端自己 404（转发成功，问题在后端路径）；页面是 ingress-nginx 默认 404 = 控制器层面没匹配到规则。§4.8 会再对照一次。

### 4.3 正则重写：rewrite-target

`ImplementationSpecific` 路径类型允许写正则，配合 `rewrite-target` 捕获分组即可"把 `/v1/xxx` 变成 `/`"：

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$2
spec:
  rules:
    - host: rewrite.lab.k3s.local
      http:
        paths:
          - path: /v1(/|$)(.*)          # 分组1=/或空, 分组2=剩余路径
            pathType: ImplementationSpecific
            backend: {service: {name: app-b, port: {number: 80}}}
```

真实结果：

```bash
$ curl -s -H 'Host: rewrite.lab.k3s.local' $BASE/v1/    # → SERVICE-B (200)
$ curl -s -H 'Host: rewrite.lab.k3s.local' $BASE/v1     # → SERVICE-B (200)
$ curl -s -H 'Host: rewrite.lab.k3s.local' $BASE/v2/    # → HTTP 404（规则不匹配）
```

`/v1/` 和 `/v1` 都被重写成了 `/`，后端 app-b 的首页内容返回；而 `/v2/` 没有匹配规则，由控制器 404。

### 4.4 CORS

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/enable-cors: 'true'
    nginx.ingress.kubernetes.io/cors-allow-origin: https://docs.example.com
```

真实结果（**注意：ingress-nginx 对 Origin 是精确匹配，不是"回显任意 Origin"**）：

```bash
# 允许的 Origin → 返回 ACAO 头（含 httpOnly 无关，注意这组是响应头）
$ curl -si -H 'Host: cors.lab.k3s.local' -H 'Origin: https://docs.example.com' $BASE/ \
   | grep -iE "access-control"
# Access-Control-Allow-Origin: https://docs.example.com
# Access-Control-Allow-Credentials: true
# Access-Control-Allow-Methods: GET, PUT, POST, DELETE, PATCH, OPTIONS
# Access-Control-Max-Age: 1728000

# 不在白名单的 Origin → 响应头里没有任何 access-control-*
$ curl -si -H 'Host: cors.lab.k3s.local' -H 'Origin: https://evil.example.com' $BASE/ \
   | grep -icE "access-control"                       # → 0（没有任何 CORS 头）

# 预检 OPTIONS → 204，带 Allow-Methods 等
$ curl -si -X OPTIONS -H 'Host: cors.lab.k3s.local' -H 'Origin: https://docs.example.com' \
    -H 'Access-Control-Request-Method: GET' $BASE/ | grep -iE "^HTTP|access-control"
# HTTP/1.1 204 No Content
# Access-Control-Allow-Origin: https://docs.example.com
# ...
```

> 浏览器跨域失败时，先确认"**响应里 ACAO 头是否存在**"。没有 = 控制器没放行该 Origin（精确匹配）；有但值不对 = 多半是 `cors-allow-origin` 写错（可用逗号分隔多个）。

### 4.5 限流

ingress-nginx 的限流按**客户端 IP** 统计，核心注解 `limit-rps`（每秒请求数）+ `limit-burst-multiplier`（突发倍数，实际桶大小 = rps × 倍数）：

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/limit-rps: '2'
    nginx.ingress.kubernetes.io/limit-burst-multiplier: '2'
```

真实结果（连发 8 个请求）：

```bash
$ for i in $(seq 1 8); do curl -s -o /dev/null -w "%{http_code} " \
    -H 'Host: rate.lab.k3s.local' $BASE/; done; echo
# 200 200 200 200 200 503 503 503
```

前几个打满突发桶返回 200，桶空后直接 503 `Service Temporarily Unavailable`。配合 `limit-whitelist`（CIDR 白名单）可只对公网限流——排障时先确认你的测试 IP 在不在白名单里，白名单会**直接绕过限流**。

### 4.6 会话保持（cookie 亲和）

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/affinity: cookie
    nginx.ingress.kubernetes.io/session-cookie-name: LABSESS
```

真实结果（后端 app-c 是 2 副本）：

```bash
# 首次请求：服务器下发 Set-Cookie: LABSESS=...
$ curl -si -c /tmp/jar.txt -H 'Host: sess.lab.k3s.local' $BASE/ | grep -i set-cookie
# Set-Cookie: LABSESS=1791598816.003.186.830517|321dfb...; Path=/; HttpOnly

# 之后带同一个 cookie 连发 5 个 → 全部命中同一后端
$ for i in $(seq 1 5); do curl -s -b /tmp/jar.txt -H 'Host: sess.lab.k3s.local' $BASE/; echo; done
# SERVICE-C (×5)
```

> 无状态后端千万别开 cookie 亲和——它会让扩容后的新副本几乎接不到流量。判断依据是 Set-Cookie 里的 `LABSESS=...|321dfb...` 后面那段哈希（后端实例标识）。

### 4.7 金丝雀（本章最值钱的一节：4 个真实坑）

**概念**：金丝雀 Ingress 与主 Ingress 规则完全相同（同 host、同 path），靠注解把一部分流量"额外"导给新版本后端，用于灰度发布。三种模式：

| 模式 | 注解 | 触发条件 |
|---|---|---|
| 权重 | `canary-weight` | 0-100 的百分比随机分流（默认总权重 100） |
| 请求头 | `canary-by-header` + `canary-by-header-value` | 请求头等于指定值 → 走金丝雀 |
| Cookie | `canary-by-cookie` | Cookie 值 = `always` → 走金丝雀 |

先看**能工作的样子**（干净环境 canary-lab：主 → c-a，金丝雀 → c-b）：

```bash
# 请求头模式
$ curl -s -H 'Host: clean.lab.k3s.local' $BASE/                    # → CANARY-STABLE
$ curl -s -H 'Host: clean.lab.k3s.local' -H 'X-Canary: always' $BASE/   # → CANARY-NEW
$ curl -s -H 'Host: clean.lab.k3s.local' -H 'X-Canary: never'  $BASE/   # → CANARY-STABLE
# 权重模式 (canary-weight: 50) 发 24 个请求
$ for i in $(seq 1 24); do curl -s -H 'Host: clean.lab.k3s.local' $BASE/; echo; done \
   | sort | uniq -c
#      11 CANARY-NEW
#      13 CANARY-STABLE          ← ~50/50，纯随机，不存在"按 IP 固定"
```

#### 坑 1：创建时没带 canary 注解 → 直接被校验 webhook 拒绝

验证 webhook（`validate.nginx.ingress.kubernetes.io`）会拒绝"与已有 Ingress 相同的 host+path"——**除非**新 Ingress 带 `canary: "true"` 注解。真实报错：

```
admission webhook "validate.nginx.ingress.kubernetes.io" denied the request:
host "clean.lab.k3s.local" and path "/" is already defined in ingress canary-lab/main
```

结论：金丝雀 Ingress 必须在 **创建时** 就带上 `canary: "true"`，先建主再补注解是行不通的。

#### 坑 2（隐蔽）：金丝雀后端同时是别处的主后端 → 静默失效

最早我在 `ing-demo` 里做权重演示：app-b 当金丝雀后端，但 app-b **同时是 `ing-rewrite`、`ing-ratelimit` 的主后端**。结果发 20 个请求 **全部**命中主版本（20/0）：

```bash
$ for i in $(seq 1 20); do curl -s -H 'Host: canary.lab.k3s.local' $BASE/; echo; done | sort | uniq -c
#      20 SERVICE-A          ← 权重 50 却能 20/0，明显异常
```

控制器日志里只有一条不易察觉的 Warning：

```
W ... controller.go:1659] alternative upstream ing-demo-app-b-80 in Ingress ing-demo/ing-canary
  is primary upstream in Other Ingress for location canary.lab.k3s.local/!
```

**根因（读 v1.11.0 源码确认）**：控制器构建 upstream（上游后端）时，如果某个后端**已经被其他非金丝雀 Ingress 创建**（`createUpstreams` 里 `if _, ok := upstreams[name]; ok { continue }`），金丝雀分支（`NoServer=true` + `TrafficShapingPolicy`，即"流控策略"标记）就被跳过；进一步，`mergeAlternativeBackends` 在匹配到"该后端也是某 location 的主后端"时打 Warning 并中断合并。结果：金丝雀被合并为 alternative，却没有流控策略 → **请求永远走主版本**，且 HTTP 层无任何报错。

**修复**：金丝雀后端必须用**专属 Service**（不被任何其他 Ingress 当作主后端）。换成专属后端 app-aux 后立即生效（`X-Canary2: always` → SERVICE-AUX，无头 → SERVICE-A）。

> 判断技巧：发请求全走主版本时，先 `kubectl -n ingress-nginx logs deploy/ingress-nginx-controller | grep -i canary`。有 `alternative upstream ... is primary upstream in Other Ingress` 这条 Warning，就是共享后端踩坑了。

#### 坑 3：同一主后端挂多个金丝雀 → 只有第一个 alternative 生效

把坑 2 修好后，我在同一主后端 app-a 上又挂了一对金丝雀（app-b、app-aux 两个 alternative）。结果：第二个金丝雀（app-aux）**仍然失效**——因为第一个挂上去的 app-b 没有流控策略，Lua 平衡器按顺序取到它就直接判"无金丝雀策略"。删掉第一对后，第二对立即工作。**结论：一个主后端只挂一对金丝雀；多个灰度对象请各自用独立的主后端（或独立域名），不要共用一个主 Service。**

#### 坑 4：别用 nginx.conf 判金丝雀死活（v1.11 的假象）

ingress-nginx v1.11 的模板 `rootfs/etc/nginx/template/nginx.tmpl` 里 `proxy_alternative_upstream_name` 是**硬编码空字符串**——金丝雀决策是在运行期由 Lua 平衡器（`balancer.rewrite()`/`balance()`）读共享内存里的 `TrafficShapingPolicy` 完成的。所以查 `nginx.conf` 看不到任何 canary 痕迹，**不代表没生效**；正确观测方式是直接发请求看响应，或看控制器日志的 Warning/事件。

> 金丝雀排查清单：① 创建时带上 `canary: "true"`？② 金丝雀后端是否专属（没被别处当主后端）？③ 同一主后端是否已有别的 alternative？④ 直接 curl 测（别只看 nginx.conf）？

### 4.8 默认后端 404 与两种 404 的分辨

```bash
# 无任何规则匹配（host 不存在）→ 控制器默认 404
$ curl -si -H 'Host: nope.lab.k3s.local' $BASE/ | grep -iE "^HTTP"
# HTTP/1.1 404 Not Found

# 被转发但后端无此路径 → 后端 404（响应体带 nginx/x.x.x 字样）
$ curl -si -H 'Host: multi.lab.k3s.local' $BASE/zzz-notexist | grep -iE "^HTTP"
# HTTP/1.1 404 Not Found   (响应体是 <center><hr><center>nginx/1.31.6</center>)
```

工程上建议给控制器配**默认后端 Service**（`--default-backend-service`），统一返回自家 404 页面；否则默认 404 页就是 ingress-nginx 自带的裸页面。

### 4.9 TLS：cert-manager 证书全流程（从私有 CA 到 HTTPS）

目标：走完一条真实的证书链路——**自签 ClusterIssuer 产出 CA → 用自己的 CA 签叶证书 → Ingress 使用 → HTTPS 实测 → 看自动续期**。

四段式 YAML（`kubectl apply` 一次成型）：

```yaml
# 1) 自签 ClusterIssuer：只能签"信任来自自身"的证书（通常只用来产 CA 或用 Rancher 内部流转）
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: {name: lab-selfsigned}
spec:
  selfSigned: {}
---
# 2) 用自签 issuer 签一个 "是 CA" 的证书 → CA 私钥/公钥对落 Secret
#    注意：CA 证书放在 cert-manager 命名空间（ClusterIssuer 的 ca.secretName 只在本命名空间里找）
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: lab-ca, namespace: cert-manager}
spec:
  isCA: true
  commonName: lab-ca.k3s.local
  secretName: lab-ca-pair
  duration: 8760h
  issuerRef: {name: lab-selfsigned, kind: ClusterIssuer}
---
# 3) CA Issuer：签出去的证书都由这张 CA 背书
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: {name: lab-ca-issuer}
spec:
  ca:
    secretName: lab-ca-pair
---
# 4) 业务叶证书（放到业务命名空间，DNS 用测试域名）
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: tls-demo, namespace: ing-demo}
spec:
  dnsNames: [tls.lab.k3s.local]
  secretName: ing-tls
  duration: 2160h
  issuerRef: {name: lab-ca-issuer, kind: ClusterIssuer}
```

**真实结果（6 秒全部就绪）**：

```bash
$ kubectl get clusterissuer
# NAME              READY   AGE
# lab-ca-issuer     True    6s
# lab-selfsigned    True    6s

$ kubectl get certificate -A
# NAMESPACE      NAME       READY   SECRET        AGE
# cert-manager   lab-ca     True    lab-ca-pair   6s
# ing-demo       tls-demo   True    ing-tls       6s

$ kubectl get certificaterequest -A
# NAMESPACE      NAME         APPROVED   READY   ISSUER           REQUESTER
# cert-manager   lab-ca-1     True       True    lab-selfsigned   system:serviceaccount:cert-manager:cert-manager
# ing-demo       tls-demo-1   True       True    lab-ca-issuer    system:serviceaccount:cert-manager:cert-manager
```

**Leaf 证书内容与续期**：

```bash
$ kubectl get secret -n ing-demo ing-tls -o jsonpath='{.data.tls\.crt}' | base64 -d \
    | openssl x509 -noout -subject -issuer -ext subjectAltName -dates
# X509v3 Subject Alternative Name: critical
#     DNS:tls.lab.k3s.local          ← SAN 里是测试域名
# issuer=CN=lab-ca.k3s.local          ← 签发给它的是我们的私有 CA
# notBefore=Oct 10 02:55:03 2026 GMT
# notAfter=Jan  8 02:55:03 2027 GMT   ← 90 天（duration 2160h）

$ kubectl get certificate -n ing-demo tls-demo \
    -o jsonpath='spec.duration={.spec.duration} renewalTime={.status.renewalTime}'
# spec.duration=2160h renewalTime=2026-12-09T02:55:03Z   ← 2/3 生命周期时自动续期
```

`renewalTime` 是 cert-manager 内置的续期时间（默认在证书生命周期 2/3 处触发）。到期前它会在后台自动重新签发并更新 Secret，业务无感。

**HTTPS 实测（30444）**：

```bash
# 信任测试：-k 跳过校验 → 拿到 200
$ curl -sk -w 'HTTP %{http_code}\n' https://192.168.56.10:30444/ -H 'Host: tls.lab.k3s.local'
# SERVICE-A
# HTTP 200

# 不信任私有 CA：系统信任链校验失败（HTTP 000）。生产要装浏览器/系统 CA 仓库，或用 Let's Encrypt
$ curl -s -o /dev/null -w 'HTTP %{http_code}\n' https://192.168.56.10:30444/ \
    -H 'Host: tls.lab.k3s.local'
# HTTP 000

# 服务器实际下发的证书（openssl s_client 直连验证）
$ echo | openssl s_client -connect 192.168.56.10:30444 -servername tls.lab.k3s.local \
    2>/dev/null | openssl x509 -noout -issuer -dates
# issuer=CN=lab-ca.k3s.local
```

**同 Ingress 的 HTTP 会自动 308 跳 HTTPS**（真实结果）：

```bash
$ curl -si -H 'Host: tls.lab.k3s.local' http://192.168.56.10:30080/
# HTTP/1.1 308 Permanent Redirect
# Location: https://tls.lab.k3s.local
```

配置了 `spec.tls` 的 Ingress，访问其 HTTP 入口会被控制器自动 308 到 HTTPS（这就是为什么"改了 TLS 后原 HTTP 端口突然打不开了"）。

---

## 5. Rancher 界面对照

上面所有资源都能在 Rancher UI 看到（Rancher 自己的 `publicEndpoints` 注解也已自动加到每个 Ingress 上）：

| 资源 | Rancher 路径 |
|---|---|
| Ingress 列表 | 集群 → Service Discovery → **Ingress**（能看到 host/path/后端/注解） |
| 证书对象 | 集群 → 右上角 hamburger → **Imported and Custom Resources** → `cert-manager.io/Certificate` |
| IngressClass | 集群 → hamburger → `networking.k8s.io/IngressClass` |
| 控制器 Pod 日志 | 工作负载栏找 `ingress-nginx-controller` → 查看日志（排金丝雀坑 2 时在这看 Warning） |

---

## 6. 注解速查表（本章实测过的）

| 注解 | 作用 | 本章真实结果 |
|---|---|---|
| `rewrite-target` | 把匹配路径重写后再转发 | `/a`+rewrite=`/` → 后端 200；不写 → 后端 404 |
| `enable-cors` + `cors-allow-origin` | 跨域头（Origin 精确匹配） | 白名单 Origin 有 ACAO；陌生 Origin 无任何 CORS 头 |
| `limit-rps` + `limit-burst-multiplier` | 按 IP 限流 | burst 满后 → 503 |
| `affinity: cookie` + `session-cookie-name` | 会话保持 | 下发 LABSESS，同 cookie 5/5 同一后端 |
| `canary` + `canary-weight` / `canary-by-header` | 灰度分流 | 权重 50% ≈ 50/50；请求头 always/never 精确可控 |
| 无 | IngressClass 指定 | 本集群必须显式 `ingressClassName: nginx` |

---

## 7. 排障清单

1. **404 但规则明明写了**：先看响应体是谁的（`nginx/x.x.x` = 后端 404，说明转发成功、后端没这个路径 → 加 `rewrite-target`）。
2. **金丝雀全走主版本**：查控制器日志里的 `alternative upstream ... is primary upstream in Other Ingress` Warning → 金丝雀后端被别处共享了，换专属 Service。
3. **金丝雀创建失败**：`admission webhook ... denied` → 创建时没带 `canary: "true"`。
4. **同一个主后端挂两个金丝雀**：只有第一个 alternative 生效（Lua 顺序），需要把灰度对象拆开。
5. **改了 TLS 后 HTTP 打不开**：不是坏了，是 Ingress 自动 308 跳 HTTPS（看 Location 头确认）。
6. **限流没生效**：先看测试 IP 是否在 `limit-whitelist` 里。
7. **不要用 nginx.conf 判断金丝雀**：v1.11 的 alternative 变量恒为空，决策在 Lua 层。
8. **Ingress 没 ADDRESS**：检查 `ingressClassName` 是否与控制器 class 匹配（本集群唯一 class 是 `nginx`）。

---

## 动手练习

1. 建一个三后端（A/B/C）多路径 Ingress，让 `/api/*` 重写到根路径，验证 200 与后端 404 的区别。
2. 给自己服务的 Ingress 加 `limit-rps: 1`，用脚本连发 10 个请求观察 200/503 分布并解释桶大小。
3. 复现金丝雀坑 2：先让金丝雀后端兼作其他 Ingress 主后端，观察"20/0 全主版本 + 控制器 Warning"，再换成专属 Service 验证修复。
4. 用 cert-manager 重建本章 CA 链（帮你自己的测试域名出证书），把根证书导到 `curl -k` 场景外（`--cacert`）验证 HTTPS 校验成功。
5. 解释本章"HTTP 308 跳 HTTPS"发生的条件，并给出一种"HTTP/HTTPS 并存不跳转"的注解思路（提示：`ssl-redirect`/`force-ssl-redirect`）。
6. 通过 Rancher UI 找到 ing-demo 的所有 Ingress 与 cert-manager 证书对象，对照 §5 的路径。
7. 写出"金丝雀上线到回滚"的完整动作清单（含创建顺序、后端隔离、灰度验证、全量切换、删除金丝雀），并说明每一步对应的注解。