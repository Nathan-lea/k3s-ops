# webapp-operator —— 第 42 章示例控制器

一个最小的 Kubernetes 控制器（Operator）：监听自定义资源 `WebApp`（`demo.example.com/v1`），
为每个 `WebApp` 维护一个同名 Deployment，并把 Deployment 的可用副本数回写到 CR 的 `status`。

删除被管的 Deployment，控制器会自动重建它——这就是"调谐（reconcile）"。

## 文件结构

```
examples/webapp-operator/
├── api/v1/                            # CRD 的 Go 类型
│   ├── groupversion_info.go
│   ├── webapp_types.go
│   └── zz_generated.deepcopy.go       # 由 controller-gen 生成
├── internal/controller/
│   └── webapp_controller.go           # Reconcile 调谐逻辑
├── config/
│   ├── crd/webapp.yaml                # 手写的 CRD（教学主角）
│   ├── crd/generated/                 # controller-gen 产物，用于对比
│   ├── rbac/                          # ServiceAccount / Role / RoleBinding
│   ├── manager/deployment.yaml         # 控制器自身的 Deployment
│   └── samples/demo-webapp.yaml        # 演示用 WebApp
├── main.go                             # manager 装配
├── Dockerfile
└── README.md
```

## 1. 编译

```bash
cd ~/k3s-ops/examples/webapp-operator
go build ./...
# -s -w 去掉调试符号，二进制从约 58MB 降到约 40MB
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o bin/webapp-operator .
```

## 2. 打成镜像（宿主机 Docker）

控制器用 `FROM scratch` 打包（只放静态二进制 + CA 证书），并以非 root 用户运行：

```bash
cd ~/k3s-ops/examples/webapp-operator
docker build -t webapp-operator:v0.1.0 .
docker save -o /tmp/webapp-operator-v0.1.0.tar webapp-operator:v0.1.0
```

集群没有内网 registry，所以直接把镜像文件传到节点并导入 containerd（`vagrant` 命令在仓库根目录 `~/k3s-ops` 下执行）：

```bash
cd ~/k3s-ops
vagrant upload /tmp/webapp-operator-v0.1.0.tar /tmp/webapp-operator-v0.1.0.tar k3s-demo-agent-1
vagrant ssh k3s-demo-agent-1 -- "sudo k3s ctr images import /tmp/webapp-operator-v0.1.0.tar"
vagrant ssh k3s-demo-agent-1 -- "sudo k3s ctr images ls -q | grep webapp-operator"
```

## 3. 部署（注意顺序）

```bash
cd ~/k3s-ops
kubectl --kubeconfig ./kubeconfig create namespace operator-demo
kubectl --kubeconfig ./kubeconfig apply -f examples/webapp-operator/config/crd/webapp.yaml
kubectl --kubeconfig ./kubeconfig apply -f examples/webapp-operator/config/rbac
kubectl --kubeconfig ./kubeconfig apply -f examples/webapp-operator/config/manager/deployment.yaml
```

## 4. 验证调谐

```bash
kubectl --kubeconfig ./kubeconfig apply -f examples/webapp-operator/config/samples/demo-webapp.yaml
kubectl --kubeconfig ./kubeconfig -n operator-demo get webapps -o wide
kubectl --kubeconfig ./kubeconfig -n operator-demo get deploy,po

# 删掉被管对象，观察控制器自动重建
kubectl --kubeconfig ./kubeconfig -n operator-demo delete deploy demo-webapp
sleep 8
kubectl --kubeconfig ./kubeconfig -n operator-demo get deploy demo-webapp

# 改 CR，观察下游跟随
kubectl --kubeconfig ./kubeconfig -n operator-demo patch webapp demo-webapp --type=merge -p '{"spec":{"replicas":3}}'
kubectl --kubeconfig ./kubeconfig -n operator-demo get webapp demo-webapp -o jsonpath='{.status.readyReplicas}{"\n"}'
```

## 5. 设计要点：为什么这里能只用命名空间级 Role

`controller-runtime` 的 informer 默认在**集群级别** `list`/`watch`，哪怕控制器只关心一个命名空间。
如果只给命名空间级 `Role`，Pod 会处于 `Running`，但日志里会持续刷：

```
deployments.apps is forbidden: User "system:serviceaccount:operator-demo:webapp-operator"
cannot list resource "deployments" in API group "apps" at the cluster scope
```

两种做法二选一：

1. 用 `ClusterRole` + `ClusterRoleBinding`（权限放大到整个集群）；
2. 把 manager 的缓存限定到命名空间，命名空间级 `Role` 就够用（本示例采用的做法）：

```go
Cache: cache.Options{
    DefaultNamespaces: map[string]cache.Config{watchNamespace: {}},
},
```

这就是"命名空间级 Operator"的最小权限形态。

## 6. 重新生成 CRD 与 deepcopy（可选）

```bash
go install sigs.k8s.io/controller-tools/cmd/controller-gen@v0.17.0
controller-gen object paths="./api/..."
controller-gen crd paths="./api/..." output:crd:dir=config/crd/generated
```

## 清理

```bash
kubectl --kubeconfig ./kubeconfig delete namespace operator-demo
kubectl --kubeconfig ./kubeconfig delete crd webapps.demo.example.com
```
