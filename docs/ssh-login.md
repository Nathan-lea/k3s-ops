# SSH 登录节点服务器

## 方式一：vagrant ssh（推荐）

```bash
cd ~/k3s-ops
vagrant ssh k3s-demo-server-1
```

Vagrant 自动管理密钥和端口转发，无需记忆任何参数。

## 方式二：原生 SSH（端口转发）

Vagrant 默认将 VM 的 22 端口转发到宿主机的 2222 端口：

```bash
ssh -p 2222 \
  -i .vagrant/machines/k3s-demo-server-1/virtualbox/private_key \
  -o StrictHostKeyChecking=no \
  vagrant@127.0.0.1
```

## 方式三：原生 SSH（内网直连）

如果宿主机与 VM 在同一内网（192.168.56.0/24），可直接通过内网 IP 连接：

```bash
ssh -i .vagrant/machines/k3s-demo-server-1/virtualbox/private_key \
  -o StrictHostKeyChecking=no \
  vagrant@192.168.56.10
```

## 关于 root 用户

Vagrant 管理的 Ubuntu box 默认：
- 用户 **vagrant**（sudo NOPASSWD），密钥认证
- root 密码被锁定（`sudo passwd -l root`），无法直接 ssh 登录

需要 root 权限时在 vagrant 用户下使用 `sudo` 即可：

```bash
sudo -i                                               # 切换到 root shell
sudo /usr/local/bin/k3s crictl images                 # 单条命令
sudo journalctl -u k3s --no-pager                     # 查看 k3s 日志
sudo cat /var/lib/rancher/k3s/server/node-token       # 查看节点 token
```

## 其他节点

若后续添加了更多节点，Vagrant 会为每个节点分配不同的 SSH 端口转发：

```bash
# 查看所有 VM 的 SSH 配置
vagrant ssh-config

# 连接第二个节点（端口递增）
ssh -p 2200 \
  -i .vagrant/machines/k3s-demo-server-2/virtualbox/private_key \
  vagrant@127.0.0.1
```
