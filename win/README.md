# Windows 学员快速入口

目标：只需 **2 步**，在没有 Linux 基础的 Windows 机器上，得到与教程环境一致的 k3s 集群，并能完成第 31、32、37、43 章的实验。

## 第 1 步：启动并引导工作机

```powershell
powershell -ExecutionPolicy Bypass -File .\win\up.ps1 -Install
```

执行后：
- Windows 宿主启动 3 台 VirtualBox（server-1、agent-1、ops 工作机）
- 工作机里装好 Ansible、kubectl、helm，集群已安装
- kubeconfig 里 server 已改写成 192.168.56.10:6443
- 命令行提示：

```
完成。进入工作机：
    vagrant ssh k3s-demo-ops
    cd ~/k3s-ops && ./k3s-ops.sh status
```

关机：`.\win\down.ps1`；重建：`.\win\destroy.ps1` 后重跑 `up.ps1 -Install`。

## 第 2 步：验证并开始实验

```powershell
kubectl get nodes
```

应返回 2 个 `Ready` 的节点。可直接按 `docs/k8s-tutorial/` 章节的命令行操作。

## 常见问题

| 问题 | 处理 |
|---|---|
| `vagrant up` 报 `Host-only adapter` 权限不足 | 右键『以管理员身份运行』PowerShell 后重试 |
| 报 `IP 192.168.56.* 被占用` | 检查是否有非 VirtualBox 网卡占用该段；或在 `win\nodes.windows.yml` 里调整 subnet |
| helm 下载超时 | 第 31 章 helm repo 已固定为 `get.helm.sh`（国际），若网络不可达请参考三级回退手动下载后放到 `~/.local/bin/helm` |
| kubeconfig 打不开 | 确认已运行 `.\\win\\up.ps1 -Install`；如有问题执行 `.\win\\kubeconfig.ps1` |
| helm 章节报错说 raw.githubusercontent.com 不可达 | 本网络已确认 `raw.githubusercontent.com` 不可达（Connection reset），helm 已由工作机分发到节点，不会卡在 bootstrap 阶段 |

## 故障排查

- `status` 报错：确认工作机已引导（运行 `.\win\\up.ps1 -Install`），且 vagrant shim 已生效（`vagrant ssh k3s-demo-ops` 可用）。
- 私钥文件缺失：重跑 `.\win\\up.ps1`（它会完整初始化）。
- 需要在 Windows 上手动运行 `kubectl`/`helm`：它们已预装在 `C:\Users\<用户名>\.local\bin\`（由 provision-ops.sh 完成）。
- 若想在 Windows PowerShell 里直接用 kubectl：设 `$env:KUBECONFIG` 为 `~/Desktop/kubeconfig` 后即可直接用 `kubectl get nodes`。

## 作者

由 OpenCode 生成，依据 `docs/superpowers/specs/2026-10-30-windows-ops-vm-design.md`。