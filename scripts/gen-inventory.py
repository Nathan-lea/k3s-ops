#!/usr/bin/env python3
"""从 vagrant/nodes.yml 生成 Ansible inventory。

为什么需要它：Vagrant 的 ansible provisioner 在宿主机执行 playbook 时会隐式注入
ansible_user、私钥路径、node_role、node_ip、first_server_ip 等变量。当 Ansible
改为在一台独立工作机（role: ops）上运行时，这些注入不存在了，必须自己生成。

设计要点：
  * 只生成 group_vars 覆盖不到的变量。ansible/group_vars/all.yml 才是权威来源
    （例如 containerd_mirrors、k3s_download_url），在这里重复一份反而会用旧值覆盖它。
  * 同时生成 new_server / new_agent / target_node 三个组。k3s-add-server.yml、
    k3s-add-agent.yml、k3s-remove-node.yml 的 hosts: 就是这三个组名，而 Vagrant
    从不生成它们，所以 add-node/remove-node 此前一直是静默空跑。实际选中哪台
    由 k3s-ops.sh 传入的 -l <host> 决定。
  * 支持两种 SSH 私钥定位模式：
      - flat（默认）：<key-dir>/<full-hostname>，适合 Windows ops VM / 预分发 key
      - vagrant：<vagrant-dir>/machines/<full-hostname>/<provider>/private_key，
        适合 Linux/macOS 宿主机直接对 Vagrant VirtualBox VM 运行 Ansible

用法：
  scripts/gen-inventory.py                          # 写 ansible/inventory.yml
  scripts/gen-inventory.py --nodes win/nodes.windows.yml --stdout
  scripts/gen-inventory.py --key-dir ~/.ssh/k3s-ops --check
  scripts/gen-inventory.py --key-mode vagrant --vagrant-dir .vagrant --stdout
"""

import argparse
import os
import subprocess
import sys

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.stderr.write("ERROR: 需要 PyYAML（apt install python3-yaml 或 pip install pyyaml）\n")
    sys.exit(3)

PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_NODES = os.path.join(PROJECT_DIR, "vagrant", "nodes.yml")
DEFAULT_OUT = os.path.join(PROJECT_DIR, "ansible", "inventory.yml")
DEFAULT_KEY_DIR = "~/.ssh/k3s-ops"
DEFAULT_VAGRANT_DIR = os.path.join(PROJECT_DIR, ".vagrant")


def die(msg):
    sys.stderr.write("ERROR: %s\n" % msg)
    sys.exit(2)


def load_nodes(path):
    if not os.path.isfile(path):
        die("找不到拓扑文件: %s" % path)
    with open(path, encoding="utf-8") as fh:
        cfg = yaml.safe_load(fh) or {}
    nodes = [n for n in (cfg.get("nodes") or []) if isinstance(n, dict)]
    # 工作机（role: ops）不是集群节点，不参与 Ansible
    k8s = [n for n in nodes if n.get("role") in ("server", "agent")]
    if not k8s:
        die("%s 里没有 server/agent 节点" % path)
    servers = [n for n in k8s if n["role"] == "server"]
    if not servers:
        die("%s 里没有 role: server 的节点（k3s 需要至少一台）" % path)
    return cfg, k8s, servers[0]


def resolve_private_key(node, cluster_name, key_dir, key_mode, vagrant_dir, provider):
    host = "%s-%s" % (cluster_name, node["name"])
    if key_mode == "vagrant":
        return os.path.join(vagrant_dir, "machines", host, provider, "private_key")
    return os.path.join(key_dir, host)


def host_entry(node, cluster_name, key_dir, user, key_mode, vagrant_dir, provider):
    host = "%s-%s" % (cluster_name, node["name"])
    return host, {
        "ansible_host": node["ip"],
        "node_role": node["role"],
        "node_ip": node["ip"],
        "ansible_user": user,
        "ansible_ssh_private_key_file": resolve_private_key(
            node, cluster_name, key_dir, key_mode, vagrant_dir, provider
        ),
    }


def build(cfg, k8s, first_server, key_dir, user, key_mode, vagrant_dir, provider):
    cluster_name = cfg.get("cluster_name") or "k3s"
    host_map = dict(
        host_entry(n, cluster_name, key_dir, user, key_mode, vagrant_dir, provider)
        for n in k8s
    )

    all_vars = {
        "cluster_name": cluster_name,
        "first_server_ip": first_server["ip"],
        "first_server_host": "%s-%s" % (cluster_name, first_server["name"]),
        "ansible_ssh_common_args": "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null",
    }
    # 这三项 group_vars 里没有默认值（或必须以拓扑为准），必须显式透传
    for key in ("k3s_version", "k3s_config", "addons"):
        if cfg.get(key) is not None:
            all_vars[key] = cfg[key]

    def group(role):
        # dict(v) 复制一份：否则同一个 dict 被多个组引用，PyYAML 会输出
        # &id001 / *id001 锚点，可读性差且容易误改
        return {h: dict(v) for h, v in host_map.items() if v["node_role"] == role}

    children = {
        "server": {"hosts": group("server")},
        "agent": {"hosts": group("agent")},
        # 以下三个组只为了让 add-node / remove-node 的 hosts: 能匹配到主机，
        # 实际作用对象由 -l <host> 限定。
        "new_server": {"hosts": group("server")},
        "new_agent": {"hosts": group("agent")},
        "target_node": {"hosts": {h: dict(v) for h, v in host_map.items()}},
    }
    return {"all": {"vars": all_vars, "children": children}}


def write_inventory(data, out_path):
    text = yaml.safe_dump(data, sort_keys=False, allow_unicode=True, default_flow_style=False)
    header = "# 自动生成，请勿手工编辑。来源：scripts/gen-inventory.py\n"
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(header + text)
    return out_path


def self_check(out_path, expected_hosts, first_server_host, first_server_ip):
    """用 ansible-inventory 反解析一遍，防止生成出 Ansible 看不懂的文件。"""
    try:
        proc = subprocess.run(
            ["ansible-inventory", "-i", out_path, "--list"],
            capture_output=True, text=True, timeout=60,
        )
    except FileNotFoundError:
        sys.stderr.write("WARN: 找不到 ansible-inventory，跳过自检\n")
        return True
    except subprocess.TimeoutExpired:
        die("ansible-inventory 自检超时")
    if proc.returncode != 0:
        die("ansible-inventory 无法解析 %s:\n%s" % (out_path, proc.stderr.strip()))

    import json
    try:
        parsed = json.loads(proc.stdout)
    except json.JSONDecodeError:
        die("ansible-inventory 输出不是 JSON，无法自检")

    hosts = set(parsed.get("_meta", {}).get("hostvars", {}))
    # --list 有时不带 _meta.hostvars，退化为汇总各组 hosts
    if not hosts:
        for grp in parsed.values():
            if isinstance(grp, dict):
                hosts.update(grp.get("hosts") or [])
    missing = set(expected_hosts) - hosts
    if missing:
        die("自检失败，inventory 里缺少主机: %s" % ", ".join(sorted(missing)))

    # 注意：--list 不会输出 all.vars，组变量会被合并进每台主机的 hostvars，
    # 所以这里检查的是 first_server 这台主机解析出来的值（≈ 真实生效值）。
    hostvars = parsed.get("_meta", {}).get("hostvars", {})
    got = hostvars.get(first_server_host, {}).get("first_server_ip")
    if got != first_server_ip:
        die("自检失败，%s 的 first_server_ip 是 %r，期望 %s" % (first_server_host, got, first_server_ip))
    return True


def main(argv=None):
    ap = argparse.ArgumentParser(description="从 nodes.yml 生成 Ansible inventory")
    ap.add_argument("--nodes", default=DEFAULT_NODES, help="拓扑文件（默认 %(default)s）")
    ap.add_argument("--out", default=DEFAULT_OUT, help="输出文件（默认 %(default)s）")
    ap.add_argument("--key-dir", default=DEFAULT_KEY_DIR,
                    help="flat 模式下的私钥目录，文件名用完整主机名（默认 %(default)s）")
    ap.add_argument("--key-mode", choices=("flat", "vagrant"), default="flat",
                    help="私钥定位模式：flat=<key-dir>/<host>；vagrant=<vagrant-dir>/machines/<host>/<provider>/private_key")
    ap.add_argument("--vagrant-dir", default=DEFAULT_VAGRANT_DIR,
                    help="vagrant 模式下的 .vagrant 目录（默认 %(default)s）")
    ap.add_argument("--provider", default="virtualbox",
                    help="vagrant 模式下的 provider（默认 %(default)s）")
    ap.add_argument("--user", default="vagrant", help="SSH 用户（默认 %(default)s）")
    ap.add_argument("--stdout", action="store_true", help="打印到标准输出，不写文件")
    ap.add_argument("--check", action="store_true", help="写出后用 ansible-inventory 自检")
    args = ap.parse_args(argv)

    cfg, k8s, first_server = load_nodes(os.path.abspath(os.path.expanduser(args.nodes)))
    key_dir = os.path.abspath(os.path.expanduser(args.key_dir))
    vagrant_dir = os.path.abspath(os.path.expanduser(args.vagrant_dir))
    data = build(
        cfg, k8s, first_server, key_dir, args.user, args.key_mode, vagrant_dir, args.provider
    )

    if args.stdout:
        sys.stdout.write(yaml.safe_dump(data, sort_keys=False, allow_unicode=True))
        return 0

    out_path = write_inventory(data, os.path.abspath(os.path.expanduser(args.out)))
    hosts = ["%s-%s" % (cfg.get("cluster_name") or "k3s", n["name"]) for n in k8s]
    if args.check:
        self_check(out_path, hosts, "%s-%s" % (cfg.get("cluster_name") or "k3s", first_server["name"]),
                   first_server["ip"])

    print("inventory: %s" % out_path)
    print("hosts: %s" % ", ".join(hosts))
    print("first_server: %s (%s)" % (first_server["name"], first_server["ip"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
