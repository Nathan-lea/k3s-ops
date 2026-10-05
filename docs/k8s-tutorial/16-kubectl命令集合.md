# 16 kubectl 命令集合：语法、选项、子命令全景详解

## 本章目标

- 建立 kubectl 的**命令地图**：按"查询 / 操作 / 调试 / 发布 / 集群管理 / 配置"六大类记忆
- 掌握**语法总纲**：`kubectl [command] [TYPE] [NAME] [flags]`、资源速写、输出格式（衔接第 14 章）
- 学到**从先到后的操作链路**：get → describe → logs → exec → events → scale → rollout → delete 的排障/运维流程
- 每个命令配**本环境真实输出**，命令之间互相印证（关联性）
- 会用全局选项（`-n`/`-l`/`-o`/`--kubeconfig`）与 `kubectl options` 自助查帮助

> 前置：建议先完成 03（工作负载）、04（网络）、13（Label）、14（输出定制）、15（资源定义文件）。
> 本章全部输出均来自本集群真实执行（客户端 v1.37.1，服务端 v1.30.2+k3s2）。

---

## 1. 总纲：命令从哪来、长什么样

### 1.1 三条来源

1. **内置命令**：`kubectl --help` 列出（按用途分组，见下）
2. **CRD 扩展**：Rancher/cert-manager/fleet 等通过 CRD 注册的新资源，**自动获得** kubectl 支持（不用装插件）
3. **插件**：`kubectl plugin list`；本集群无第三方插件

### 1.2 语法总纲

```
kubectl [全局选项] 命令 [子命令] [资源类型] [资源名] [命令特有选项]
示例：kubectl  -n lab        get        pod        my-nginx     -o wide
      └─全局─┘  └─命名空间─┘ └─命令─┘  └─类型─┘   └──名字──┘    └─输出─┘
```

**资源类型支持速写**（`kubectl api-resources` 的 SHORTNAMES 列）：

```text
po=pod,deploy=deployment,rs=replicaset,sts=statefulset,ds=daemonset,
svc=service,ep=endpoints,ing=ingress,cm=configmap,ns=namespace,no=node,
pv, pvc, sa=serviceaccount, hpa, cj=cronjob, sc=storageclass, netpol=networkpolicy, crd, csr...
```

> 不记得速写？`kubectl api-resources | grep 你想查的关键字`，或 `kubectl get po --help` 里 `-A`/`-n` 等全部选项都能看。**kubectl 的 help 本身就是最好的速查表。**

### 1.3 命令总览（本地 `kubectl --help` 真实分类）

```text
Basic Commands (Beginner):
  create / expose / run / set
Basic Commands (Intermediate):
  explain / get / edit / delete
Deploy Commands:
  rollout / scale / autoscale
Cluster Management Commands:
  certificate / cluster-info / top / cordon / uncordon / drain / taint
Troubleshooting and Debugging Commands:
  describe / logs / attach / exec / port-forward / proxy / cp / auth / debug / events
Advanced Commands:
  diff / apply / patch / replace / wait / kustomize
Settings Commands:
  label / annotate / completion
Other Commands:
  api-resources / api-versions / config / kuberc / plugin / version
```

### 1.4 全局选项（任何命令都能用，`kubectl options` 看全量）

本环境 `kubectl options`（节选，客户端 v1.37.1）：

```text
--as=''                        # 模拟某个用户（RBAC 测试）
--as-group=[]                  # 模拟用户组
--context=''                   # 用 kubeconfig 里的哪个 context
--kubeconfig=''                # 指定 kubeconfig 文件路径
--cluster='' / --user=''       # 指定 kubeconfig 里某个 cluster/user
--certificate-authority=''     # CA 证书路径
--insecure-skip-tls-verify=false  # 跳过 TLS 校验（仅测试用，危险）
--namespace=''                 # 简写 -n，操作哪个命名空间
--request-timeout='0'          # 单请求超时
--server=''                    # 直连 API server 地址
--token=''                     # 认证令牌
```

**最常用组合**（贯穿本章）：
`-n <ns>`（命名空间）、`-A`/`--all-namespaces`（全部 NS）、`-l <label>`（按标签筛）、`-o <format>`（输出格式）、`--kubeconfig`（指定配置文件）、`--context`、`--dry-run`（预演）。

> 本项目约定：`export KUBECONFIG=./kubeconfig` 使用集群根目录的 kubeconfig（k3s-ops.sh kubeconfig 自动拉取）。

---

## 2. 查询类命令（最常用）

### 2.1 get：查看资源

```bash
kubectl get <type> [-n ns] [-l selector] [-o format] [-A]
kubectl get all -n lab            # 一次看 NS 内常见资源
kubectl get nodes -o wide         # 节点 + IP/OS/运行时
kubectl get svc,ep -n lab         # 多资源一次查
kubectl get pod my-pod -o yaml    # 完整定义（第 15 章）
```

本环境真实输出（`kubectl -n lab get pods -o wide`，注意 READY/STATUS/RESTARTS/IP/NODE 列）：

```text
NAME                          READY   STATUS    RESTARTS      AGE   IP           NODE                NOMINATED NODE   READINESS GATES
nginx-demo-7fb649d588-6m4xl   1/1     Running   0             4m    10.42.0.28   k3s-demo-server-1   <none>           <none>
nginx-demo-7fb649d588-gdprq   1/1     Running   0             4m    10.42.0.31   k3s-demo-server-1   <none>           <none>
```

**`-o` 六种主要格式**（第 14 章专述，这里给一句话结论）：`wide` 多列、`name` 类型/名字、`yaml|json` 完整定义、`jsonpath` 精确取数、`custom-columns` 自定义表。

**`--sort-by` 与 `--no-headers`**：

```bash
kubectl get nodes --sort-by=.metadata.creationTimestamp   # 按字段排序
kubectl get pods -n lab --no-headers | wc -l              # 去表头再数行
```

### 2.2 describe：看详细状态 + **Events**（排障第一招）

```bash
kubectl describe <type> <name> [-n ns]
kubectl describe node k3s-demo-server-1     # 节点容量/条件/污点/其上 Pod
kubectl describe pod my-nginx -n lab        # 容器状态 + 最近 Events
```

本环境真实输出（`kubectl -n lab describe pod nginx-demo-7fb649d588-6m4xl` 头部与容器段）：

```text
Name:             nginx-demo-7fb649d588-6m4xl
Namespace:        lab
Priority:         0
Service Account:  default
Node:             k3s-demo-server-1/192.168.56.10
Start Time:       Sat, 03 Oct 2026 09:01:56 +0800
Labels:           app=nginx-demo
                  pod-template-hash=7fb649d588
Annotations:      kubectl.kubernetes.io/restartedAt: 2026-10-03T09:01:57+08:00
Status:           Running
IP:               10.42.0.28
Controlled By:  ReplicaSet/nginx-demo-7fb649d588      ← 归属链（第 15 章 §6.1）
Containers:
  nginx:
    Container ID:   containerd://12485c1eaf...
    Image:          nginx:latest
    Image ID:       docker.io/library/nginx@sha256:abe47724...
    Port:           80/TCP
    Host Port:      0/TCP
    State:          Running
      Started:      Mon, 05 Oct 2026 09:06:11 +0800
    Last State:     Terminated
      Reason:       Unknown
      Exit Code:    255
    Ready:          True
    Restart Count:  2
```

> **describe 的 Events 段是排障金矿**：`kubectl describe pod x` 末尾的
> `Events:  ... ImagePullBackOff / BackOff / FailedScheduling ...` 直接告诉你失败原因。
> get 只看"状态"，describe 看"为什么"。

### 2.3 explain：字段字典（配合第 14 章）

```bash
kubectl explain pod                        # 顶层字段
kubectl explain pod.spec.containers        # 逐级下钻
kubectl explain svc.spec.ports.nodePort    # 直接查叶子字段
```

本环境真实输出（`kubectl explain pod.spec.containers` 头部）：

```text
KIND:       Pod
VERSION:    v1

FIELD: containers <[]Container>

DESCRIPTION:
    List of containers belonging to the pod. Containers cannot currently be
    added or removed. There must be at least one container in a Pod. Cannot be
    updated.
    A single application container that you want to run within a pod.

FIELDS:
  image	<string>
    Container image name.
  ...
```

### 2.4 api-resources / api-versions：资源地图

```bash
kubectl api-resources                  # 所有资源类型（含 116 个 CRD）
kubectl api-resources --namespaced=false   # 只看集群级
kubectl api-versions                    # 所有 API 组/版本
kubectl api-resources --verbs=list | head   # 只看能 list 的
```

本环境真实输出（api-resources 前几行）：

```text
NAME                                         SHORTNAMES   APIVERSION                            NAMESPACED   KIND
bindings                                                  v1                                    true         Binding
componentstatuses                            cs           v1                                    false        ComponentStatus
configmaps                                   cm           v1                                    true         ConfigMap
...
customresourcedefinitions                    crd,crds     apiextensions.k8s.io/v1               false        CustomResourceDefinition
clusters                                     cl           cluster.x-k8s.io/v1beta2              true         Cluster
certificates                                 cert,certs    cert-manager.io/v1                    true         Certificate
projects                                     -            management.cattle.io/v3               true         Project
```

### 2.5 events：直接看事件

```bash
kubectl get events -n lab                  # 命名空间事件（含过去 1h）
kubectl get events --sort-by=.lastTimestamp -A   # 全集群按时间排
kubectl get events --field-selector reason=FailedScheduling   # 过滤某种事件
```

本环境真实输出（rollout restart 触发的滚动更新事件链——`get` 与 `describe` 的 Events 同源）：

```text
LAST SEEN   TYPE     REASON              OBJECT                    MESSAGE
2s          Normal   ScalingReplicaSet   deployment/nginx-demo     Scaled up replica set nginx-demo-7fb649d588 to 5 from 4
2s          Normal   Killing             pod/nginx-demo-559f...    Stopping container nginx
2s          Normal   SuccessfulDelete    replicaset/nginx-demo-559f959666   Deleted pod: nginx-demo-559f959666-59frr
```

---

## 3. 操作类命令（创建 / 修改 / 删除）

### 3.1 create：命令式创建（生成 YAML 的好工具）

```bash
kubectl create deployment <name> --image=img --replicas=N
kubectl create configmap <name> --from-literal=key=val
kubectl create secret generic <name> --from-literal=pass=abc
kubectl create service nodeport <name> --tcp=80:80
kubectl create ns <name>
kubectl create -f file.yaml          # 从文件创建（与 apply 不同：非幂等，重复会报已存在）
```

**配合 `--dry-run=client -o yaml` 白嫖一份标准 YAML**（本项目常用套路）：

```bash
kubectl -n lab create deployment demo-web --image=nginx:latest --replicas=2 --dry-run=client -o yaml
```

本环境真实输出（节选，这直接就是第 15 章讲的 Deployment 骨架）：

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: demo-web
  name: demo-web
  namespace: lab
spec:
  replicas: 2
  selector:
    matchLabels:
      app: demo-web
  template:
    metadata:
      labels:
        app: demo-web
    spec:
      containers:
      - image: nginx:latest
        name: nginx
        resources: {}
status: {}
```

同为 dry-run 的 configmap / secret 生成结果（**注意 secret 的 data 是 base64**）：

```yaml
# kubectl create configmap demo-cm --from-literal=k=v --dry-run=client -o yaml
apiVersion: v1
data:
  k: v
kind: ConfigMap
metadata:
  name: demo-cm
  namespace: lab

# kubectl create secret generic demo-secret --from-literal=password=abc --dry-run=client -o yaml
apiVersion: v1
data:
  password: YWJj          # base64("abc")
kind: Secret
metadata:
  name: demo-secret
  namespace: lab
```

### 3.2 run：跑一个 Pod（临时/测试）

```bash
kubectl run <name> --image=img [--command -- cmd args] [--dry-run=client -o yaml]
kubectl -n lab run demo-pod --image=nginx:latest --dry-run=client -o yaml   # 真实输出见上节 create 的 pod 版
```

### 3.3 expose：把已部署的东西暴露成 Service

```bash
kubectl expose deploy nginx-demo --port=80 --target-port=80 --type=NodePort --name=demo-svc
```

本环境 dry-run 真实输出（注意 selector 自动用上 Deployment 的 label）：

```yaml
apiVersion: v1
kind: Service
metadata:
  name: demo-svc
  namespace: lab
spec:
  ports:
  - port: 80
    protocol: TCP
    targetPort: 80
  selector:
    app: nginx-demo          # ★ 自动匹配
  type: NodePort
```

### 3.4 apply：声明式应用（第 15 章 §5.1，幂等）

```bash
kubectl apply -f deploy.yaml
kubectl apply -f ./manifests/          # 目录
kubectl apply -f -                     # stdin
kubectl apply --dry-run=client -f x.yaml  # 预演
```

本环境实测（同一 ConfigMap 文件 apply 两次）：

```text
configmap/chapter16-demo created      ← 首次
configmap/chapter16-demo unchanged    ← 无变化（幂等）
```

### 3.5 edit / patch / set：三种"改"（第 15 章 §5.2-5.4）

```bash
kubectl edit deploy nginx-demo                 # 打开编辑器改完整 YAML
kubectl patch cm app-config -p '{"data":{"k":"v"}}'          # 只改指定字段
kubectl set image deploy/nginx-demo nginx=nginx:1.27         # 改镜像（触发滚动）
kubectl set resources deploy/sched-demo --limits=cpu=200m,memory=256Mi
kubectl set env deploy/nginx-demo FOO=bar
```

本环境实测（patch ConfigMap + set resources + 验证）：

```text
configmap/chapter16-demo patched
deployment.apps/sched-demo resource requirements updated
```

```bash
kubectl -n lab get deploy sched-demo -o jsonpath='{.spec.template.spec.containers[0].resources}'
# 输出: {"limits":{"cpu":"200m","memory":"256Mi"},"requests":{"cpu":"100m","memory":"128Mi"}}
```

### 3.6 label / annotate：改标签与注释

```bash
kubectl label <type> <name> key=value [--overwrite]
kubectl label <type> <name> key-        # 删除标签
kubectl annotate <type> <name> key=value
```

本环境实测：

```text
configmap/chapter16-demo labeled       # kubectl label cm chapter16-demo team=ops
configmap/chapter16-demo annotated     # kubectl annotate cm chapter16-demo note=demo
```

### 3.7 delete：删除

```bash
kubectl delete -f file.yaml            # 删文件里全部
kubectl delete deploy nginx-demo       # 按名字（级联删 RS/Pod）
kubectl delete pod -l app=nginx-demo   # 按标签
kubectl delete ns lab                  # 删整个 NS
kubectl delete <type> <name> --dry-run=client   # 预演会删什么
```

本环境实测（预演按标签删 + 真删一个临时 CM）：

```text
pod "nginx-demo-7fb649d588-6m4xl" deleted from lab namespace (dry run)   ← 预演，未真删
configmap "chapter16-demo" deleted from lab namespace                     ← 真删
```

### 3.8 replace / diff / wait（进阶）

```bash
kubectl replace -f file.yaml        # 整体替换（非幂等；与 apply 不同）
kubectl diff -f file.yaml           # 本地文件 vs 集群现状 的差异（第 15 章 §5 常用）
kubectl wait --for=condition=Ready pod -l app=nginx-demo --timeout=60s
kubectl wait --for=delete pod my-nginx --timeout=30s
```

本环境实测（diff：文件里 demo 值从 1 改成 2，与集群现状比较）：

```text
diff -u -N /tmp/LIVE-.../v1.ConfigMap.lab.chapter16-demo /tmp/MERGED-.../v1.ConfigMap.lab.chapter16-demo
--- LIVE  2026-10-05 09:12:18  (集群当前)
+++ MERGED 2026-10-05 09:12:18 (你本地文件将产生的效果)
@@ -0,0 +1,9 @@
+apiVersion: v1
+data:
+  demo: "2"
+kind: ConfigMap
...
```

> **wait 的使用场景**：脚本里"等 Deployment 就绪再继续"，比 sleep 优雅一万倍。

---

## 4. 调试类命令

### 4.1 logs：看容器日志

```bash
kubectl logs <pod> [-c 容器名] [--tail=N] [-f]
kubectl logs deploy/nginx-demo --tail=3        # Deployment 会自动挑一个 Pod
kubectl logs pod/x -p                          # 上一个崩溃实例的日志
kubectl logs deploy/x --previous               # 崩溃前日志
kubectl logs -f deploy/x                       # 跟踪
```

本环境实测（`kubectl -n lab logs deploy/nginx-demo --tail=3`，多副本自动选一个且提示）：

```text
Found 5 pods, using pod/nginx-demo-7fb649d588-6m4xl
2026/10/05 01:06:11 [notice] 1#1: start worker processes
2026/10/05 01:06:11 [notice] 1#1: start worker process 28
2026/10/05 01:06:11 [notice] 1#1: start worker process 29
```

### 4.2 exec：进容器执行命令

```bash
kubectl exec -it <pod> -- /bin/sh
kubectl exec deploy/nginx-demo -- curl -s -w '%{http_code}' http://127.0.0.1/
```

本环境实测（curl 容器自身返回 200）：

```text
200
```

> nginx 镜像没有 bash，用 `sh`；`-it` 交互；`--` 后是容器内命令。

### 4.3 attach：挂到容器主进程

```bash
kubectl attach -it <pod> [-c 容器]
```

> 适用于"容器进程把日志打到 stdout 且你想交互"的场景（如 `mysql` 容器）。详情 `kubectl attach --help`。

### 4.4 cp：容器与本地拷文件

```bash
kubectl cp <ns>/<pod>:<容器内路径> <本地路径>     # 拷出
kubectl cp <本地路径> <ns>/<pod>:<容器内路径>     # 拷入
```

> 要求容器内有 `tar` 二进制（`kubectl cp --help` 明确提示）。nginx 镜像自带 tar，可试。

### 4.5 port-forward：本地端口转进集群

```bash
kubectl port-forward svc/nginx-svc 18080:80
kubectl port-forward pod/x 8080:80 [-n ns]
```

本环境实测（Ctrl-C 前的输出）：

```text
Forwarding from 127.0.0.1:18080 -> 80
Forwarding from [::1]:18080 -> 80
```

> 之后 `curl http://127.0.0.1:18080/` 就能从宿主机直达集群内 Service——**不用 NodePort 也能本地调试**。

### 4.6 top：看资源占用（需 metrics-server，本集群已装）

```bash
kubectl top nodes
kubectl top pods -n lab
```

本环境实测：

```text
NAME                CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
k3s-demo-agent-1    31m          1%       384Mi           9%
k3s-demo-server-1   793m         39%      2390Mi          61%

NAME                          CPU(cores)   MEMORY(bytes)
nginx-demo-7fb649d588-gdprq   0m           4Mi
nginx-demo-7fb649d588-vm5vt   0m           3Mi
```

> HPA 的 TARGETS 数据就来自 metrics-server；`top` 配合 HPA 调试是黄金组合。

### 4.7 describe（排障已见 §2.2）/ events（§2.5）/ auth（见 §5.4）/ debug / proxy

```bash
kubectl proxy --port=8001        # 浏览器访问 http://127.0.0.1:8001/api/v1/... 调 API
kubectl debug node/x -it --image=busybox   # 临时调试容器（k8s 1.30+，本客户端支持）
```

---

## 5. 发布 / 集群管理 / 配置类命令

### 5.1 scale：扩缩容

```bash
kubectl scale deploy/nginx-demo --replicas=6
kubectl scale deploy/x --replicas=3 --current-replicas=5   # 带校验
kubectl autoscale deploy/x --min=2 --max=6 --cpu-percent=50   # 建 HPA
```

本环境实测（第 13 章已演示端点联动，这里看命令输出）：

```text
deployment.apps/nginx-demo scaled
deployment.apps/nginx-demo autoscaled   # 对应上面的 HPA 创建（本集群 sched-demo 已有 HPA）
```

### 5.2 rollout：滚动更新管理（配合 3.5 set image 触发）

```bash
kubectl rollout status deploy/nginx-demo          # 等完成
kubectl rollout history deploy/nginx-demo         # 更新历史
kubectl rollout restart deploy/nginx-demo         # 不换镜像强制滚动（如重读 CM）
kubectl rollout undo deploy/nginx-demo            # 回滚到上一个版本
kubectl rollout undo deploy/x --to-revision=1     # 回滚到指定版本
kubectl rollout pause deploy/x ; kubectl rollout resume deploy/x   # 暂停/恢复
```

本环境实测（restart 触发一次滚动更新；history 显示两个 REVISION）：

```text
deployment.apps/nginx-demo restarted           # rollout restart 的输出
deployment "nginx-demo" successfully rolled out   # rollout status 的输出

deployment.apps/nginx-demo                     # rollout history 的输出
REVISION  CHANGE-CAUSE
1         <none>
2         <none>
```

> `CHANGE-CAUSE` 默认 `<none>`：因为不是通过 `kubectl set image/apply --record` 触发的。（`--record` 已弃用，v1.30+ 建议用注解 `kubernetes.io/change-cause` 记录变更原因。）

### 5.3 集群管理：cordon / uncordon / drain / taint / cluster-info / certificate

```bash
kubectl cluster-info                          # API server / 核心服务地址
kubectl cordon <node>                         # 标记不可调度（已有 Pod 不动）
kubectl uncordon <node>                       # 恢复可调度
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data   # 驱逐 Pod 准备维护
kubectl taint node <n> key=value:NoSchedule   # 加污点（第 06 章）
kubectl certificate approve|deny <csr>        # 审批证书签名请求
```

本环境实测（cluster-info；节点当前无污点）：

```text
Kubernetes control plane is running at https://192.168.56.10:6443
CoreDNS is running at https://192.168.56.10:6443/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy
Metrics-server is running at https://192.168.56.10:6443/api/v1/namespaces/kube-system/services/https:metrics-server:https/proxy
To further debug and diagnose cluster problems, use 'kubectl cluster-info dump'.

# kubectl describe node ... | grep -A1 Taints
Taints:             <none>      ← 本集群 server/agent 都无污点（设计如此）
Unschedulable:      false
```

> **drain 会驱逐节点上的 Pod**（除非容忍/DS/PVC 保护），执行前想清楚；`--ignore-daemonsets` 必须给（DS 无法被驱逐）。

### 5.4 auth：权限自检

```bash
kubectl auth can-i create pods -n lab
kubectl auth can-i delete nodes
kubectl auth can-i list deployments --as=system:serviceaccount:lab:lab-user   # 模拟身份
kubectl auth whoami      # 我是谁（新版，v1.28+）
```

本环境实测：

```text
kubectl auth can-i create pods -n lab
yes
kubectl auth can-i delete nodes
yes                      # 当前 kubeconfig 是 admin 权限
```

### 5.5 config：kubeconfig 管理

```bash
kubectl config current-context      # 当前 context
kubectl config get-contexts         # 全部 context
kubectl config view --minify        # 当前有效配置
kubectl config use-context <名>     # 切换 context
kubectl config set-context x --namespace=lab
```

本环境实测：

```text
kubectl config current-context
default
```

> 本项目 kubeconfig 就是 `k3s-ops.sh kubeconfig` 从 server-1 拉回来的那个文件；`--kubeconfig` 或 `KUBECONFIG` 环境变量都可指定。

### 5.6 version / completion / kustomize / kuberc / plugin

```bash
kubectl version                 # 客户端/服务端版本（含 kustomize 版本）
kubectl completion bash         # 生成 bash 补全（source 后 tab 补全）
kubectl kustomize <dir>         # 渲染 kustomization（本地离线渲染，比 apply -k 更可控）
kubectl plugin list             # 已装插件
```

本环境实测（version——注意客户端与服务端版本差，排障时先确认版本兼容）：

```text
Client Version: v1.37.1
Kustomize Version: v5.8.1
Server Version: v1.30.2+k3s2
Warning: version difference between client (1.37) and server (1.30) exceeds the supported minor version skew of +/-1
```

> 这条 Warning 很常见：客户端比服务端新太多会提示；日常小版本差（±1）官方支持，功能可能受限。**先 `kubectl version` 再排障**是基本素养。

---

## 6. 从先到后：一条真实的运维/排障链路（关联性）

把上面命令串成一条**可复用的工作流**（结合本环境 nginx-demo 真实事件）：

```text
① 定位范围     kubectl get pods -n lab
② 看关键信息   kubectl get pods -n lab -o wide              # IP/NODE/状态
③ 深挖详情     kubectl describe pod <name> -n lab           # 容器状态 + Events
④ 看日志       kubectl logs <name> -n lab --tail=100
⑤ 进容器       kubectl exec -it <name> -n lab -- sh
⑥ 看事件       kubectl get events -n lab --sort-by=.lastTimestamp
⑦ 看依赖       kubectl get svc,ep,cm,pvc -n lab            # Service/CM/PVC 是否就位
⑧ 改配置       kubectl set env / set image / kubectl edit deploy
⑨ 等滚动       kubectl rollout status deploy/nginx-demo
⑩ 回滚         kubectl rollout undo deploy/nginx-demo
⑪ 访问验证     kubectl port-forward svc/nginx-svc 18080:80  →  curl 127.0.0.1:18080
⑫ 清理         kubectl delete deploy/pod/... / kubectl delete ns lab
```

**命令 ↔ 资源关联表**（哪些命令对哪些资源"有意思"）：

| 命令 | 适用资源 | 备注 |
|------|---------|------|
| get / describe / delete | 几乎所有 | 通吃 |
| rollout | **deploy / daemonset / statefulset** | 三者的更新管理 |
| scale | deploy / rs / rc / **sts** | HPA 也会动它 |
| autoscale | deploy / rs / sts | 生成 HPA |
| logs / exec / cp / port-forward / attach | **pod**（logs 可省写到 deploy/rs/job） | 以 Pod 为中心 |
| top | nodes / pods | 依赖 metrics-server |
| cordon / uncordon / drain / taint | **node** | 节点运维 |
| certificate | csr | 集群证书 |
| auth can-i | 任意资源 | RBAC 自检 |
| explain | 任意资源 | 字段字典 |

> 一张图记住"哪个命令管哪个对象"，就是本节表格。**排障顺序永远：get（现象）→ describe（原因）→ logs/events（证据）→ 改 → rollout（验证）→ undo（后悔药）。**

---

## 7. `kubectl options` / `--help` 自助查询（融会贯通）

- `kubectl --help`：命令分类总览（本节 §1.3）
- `kubectl <命令> --help`：某命令的语法/示例/选项（每段帮助里都有 **Examples**，比文档还直观）
- `kubectl options`：全局选项（§1.4）
- `kubectl explain <资源>.<字段>`：资源字段字典（§2.3）
- `kubectl api-resources`：资源速写表（§2.4）

> 判断"这命令支持哪些选项"的万能姿势：`kubectl get -h` / `kubectl rollout -h`，绝不会错。

## 8. Rancher 界面对照

| kubectl | Rancher UI 等效 |
|---------|----------------|
| `get pods -n lab` | Cluster → Discover → Pods（或项目内工作负载） |
| `describe pod x` / `get events` | 工作负载详情页的事件与状态标签页 |
| `logs` | 工作负载右上角 **View Logs** |
| `exec` | 工作负载 → **Execute Shell**（弹容器终端） |
| `edit / patch / set` | **Edit Config / Edit YAML** |
| `scale` | 工作负载列表 **⋮ → Scale** |
| `rollout undo` | 工作负载 → **Redeploy / Revision** 历史 |
| `cordon` | 节点页面 **Cordon** 按钮 |
| `top` | 节点/工作负载的监控图表（Rancher 有 metrics 图表） |
| `port-forward` | UI 无直接等效（CLI 优势）；可用 Rancher 的 **Launch kubectl** 在浏览器里跑 |
| `auth can-i` | Rancher RBAC 页面（Roles/RoleBindings 可视化，底层是同一套） |

> Rancher 的 **Launch kubectl**（集群页面右上角）等于在浏览器里给你一个 kubectl shell——本章命令全部能跑。

## 9. 小结

- **语法**：`kubectl [全局] 命令 [子命令] [资源] [名字] [选项]`；速写、`-n/-A/-l/-o` 四大件
- **六大类命令**：查询（get/describe/explain/api-resources/events）、操作（create/apply/edit/patch/set/label/annotate/delete/diff/wait）、调试（logs/exec/attach/cp/port-forward/top/debug）、发布（rollout/scale/autoscale）、集群（cordon/drain/taint/cluster-info/certificate）、配置（config/version/completion/kustomize）
- **排障链路**：get → describe → logs → events → 改 → rollout status → undo（后悔药）
- **关联性**：命令按"资源类型"分组记忆；与第 13/14/15 章（label/-o/定义文件）组合是完整兵器库
- **自助**：`--help` / `kubectl options` / `explain` / `api-resources` 四件套，不懂就查

## 动手练习

1. 用 `kubectl api-resources` 找出：本集群支持的所有带 `SHORTNAME=cj` 的资源是什么？它属于哪个 API 组？
2. 用 `kubectl create deployment --dry-run=client -o yaml` 生成一个副本数为 3 的 Deployment YAML，保存后 `kubectl apply -f` 部署到 lab，再用 `kubectl rollout status` 等就绪，最后 `kubectl delete -f` 清理（体验"生成→部署→清理"闭环）。
3. 用 `kubectl top nodes` 观察两个节点的 CPU/Memory 百分比；再 `kubectl top pods -n lab` 找出当前最"肥"的 Pod（结合第 06 章 HPA 知识解释为什么 sched-demo 的 TARGETS 是 0%）。
4. 对 lab 里任意 Deployment 执行 `kubectl rollout restart`，然后立刻 `kubectl get events -n lab --sort-by=.lastTimestamp`，观察事件链（Scaled up → 新 RS → Killing 旧 Pod → Deleted pod）。完成后可回滚。
5. 深度题：`kubectl get pod -o name`、`kubectl get pod -o jsonpath='{.items[*].metadata.name}'`、`kubectl get pod -o custom-columns=NAME:.metadata.name` 三条命令输出差异是什么？各自最佳使用场景？（提示：回顾第 14 章）

<details>
<summary>参考答案</summary>

1. `kubectl api-resources | grep -w cj` → `cronjobs  cj  batch/v1  true  CronJob`。短名 `cj` 是 cronjob 的速写。
2. 完整闭环：`kubectl create deployment demo-c3 --image=nginx:latest --replicas=3 --dry-run=client -o yaml > /tmp/c3.yaml` → `kubectl apply -f /tmp/c3.yaml`（输出 `deployment.apps/demo-c3 created`）→ `kubectl rollout status deploy/demo-c3`（`successfully rolled out`）→ `kubectl delete -f /tmp/c3.yaml`。
3. `TARGETS cpu: 0%/50%` 表示当前 CPU 平均利用率为 0%（nginx 空转），远低于 50% 阈值，所以保持 MINPODS=2、不扩容。`top` 与 HPA 都用 metrics-server 的数据。
4. 事件链应包含：`ScaledUpReplicaSet`（新 RS 拉副本）→ `ScalingReplicaSet` → 旧 RS `SuccessfulDelete`/`Killing`→ 新 Pod `Started`——**这正是第 15 章"Deployment→RS→Pod 归属链"在事件层的可见证明**。
5. `-o name` 输出 `pod/xxx` 前缀（脚本好用，可继续 `| xargs kubectl delete`）；`jsonpath` 纯名字无表头（机器用）；`custom-columns` 带表头表格（人读报表）。场景：循环脚本用 `-o name` 或 jsonpath，给人看用 custom-columns/wide。
</details>