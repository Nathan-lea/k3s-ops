# 集群关机和重启

## 关机

```bash
cd ~/k3s-ops

# 优雅关闭所有 VM（保存状态，下次快速启动）
vagrant halt

# 或者逐个关闭
vagrant halt k3s-demo-server-1
```

**说明**: `vagrant halt` 会在 VM 内执行 `shutdown -h now`，k3s systemd 服务会自动随系统停止，etcd 数据完整保留。

> 不需要执行 `kubectl drain` 或手动停 k3s，Vagrant 会发送 ACPI 关机信号，systemd 按依赖顺序停止服务。

## 重启（开机）

```bash
cd ~/k3s-ops

# 启动所有 VM
vagrant up

# 或者逐个启动
vagrant up k3s-demo-server-1

# 等待 k3s 就绪后，验证集群
export KUBECONFIG=~/k3s-ops/kubeconfig
kubectl get nodes
kubectl get pods -A
```

**说明**: VM 启动后 k3s systemd 服务自动跟随启动，无需手动执行任何安装步骤。之前的集群状态（etcd 数据、Pod、Service 等）全部保留。

## 其他选项

```bash
# 挂起/恢复（比 halt 更快，但占用磁盘空间保存内存状态）
vagrant suspend          # 挂起
vagrant resume           # 恢复

# 彻底销毁（删除 VM，下次需要重新 vagrant up + 安装）
vagrant destroy
```

## 总结

| 操作 | 命令 | 状态保留 |
|------|------|----------|
| 关机 | `vagrant halt` | ✅ 磁盘数据全保留 |
| 开机 | `vagrant up` | ✅ k3s 自动启动 |
| 挂起 | `vagrant suspend` | ✅ 含内存状态 |
| 恢复 | `vagrant resume` | ✅ 秒级恢复 |
| 销毁 | `vagrant destroy` | ❌ 全部删除 |
