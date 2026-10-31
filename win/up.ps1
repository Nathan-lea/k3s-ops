<#
.SYNOPSIS
  Windows 学员入口：创建/启动 3 台 VM（server-1、agent-1、ops）并引导工作机。

.DESCRIPTION
  Windows 宿主机只负责"造机器"，集群操作全部在 ops 工作机里做。

  第 1 步  检查前置条件（vagrant / VirtualBox / 管理员 / 网段 / 内存）
  第 2 步  vagrant up（读 win\nodes.windows.yml，不读 vagrant\nodes.yml）
  第 3 步  引导工作机（win\provision-ops.sh：ansible、kubectl、helm、inventory）
  第 4 步  -Install 时安装 k3s 并拉取 kubeconfig

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\win\up.ps1 -Install

.EXAMPLE
  .\win\up.ps1                 # 只启动 + 引导，不装集群
  .\win\up.ps1 -Node agent-1   # 只启动某台
#>
[CmdletBinding()]
param(
    [string]$Node = "",
    [switch]$Install,
    [switch]$SkipProvision
)

$ErrorActionPreference = 'Stop'

# 让中文输出不乱码（Windows PowerShell 5.1 默认 GBK）
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$RepoRoot  = Split-Path -Parent $PSScriptRoot
$NodesFile = Join-Path $PSScriptRoot 'nodes.windows.yml'
$Vagrantfile = Join-Path $RepoRoot 'Vagrantfile'

function Info  ($m) { Write-Host "[INFO]  $m" -ForegroundColor Green }
function Warn  ($m) { Write-Host "[WARN]  $m" -ForegroundColor Yellow }
function Fail  ($m) { Write-Host "[ERROR] $m" -ForegroundColor Red; exit 1 }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ClusterName {
    if (-not (Test-Path $NodesFile)) { Fail "找不到 $NodesFile" }
    foreach ($line in Get-Content -Path $NodesFile -Encoding UTF8) {
        if ($line -match '^\s*cluster_name:\s*(\S+)') { return $Matches[1] }
    }
    Fail "$NodesFile 里没有 cluster_name"
}

# ---- 0. 自提权 ------------------------------------------------------------
# Vagrant 在 Windows 上创建 host-only 网卡需要管理员权限
if (-not (Test-Admin)) {
    Warn "当前不是管理员，正在以管理员身份重新启动本脚本..."
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Node)    { $argList += @('-Node', $Node) }
    if ($Install) { $argList += '-Install' }
    if ($SkipProvision) { $argList += '-SkipProvision' }
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs | Out-Null
    } catch {
        Fail "自动提权失败，请右键『以管理员身份运行』PowerShell 后重试"
    }
    exit 0
}

# ---- 1. 前置检查 ----------------------------------------------------------
Info "检查前置条件"
foreach ($cmd in @('vagrant', 'VBoxManage')) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Fail "找不到 $cmd。请先安装 VirtualBox 7.x 和 Vagrant 2.4+，并重新打开 PowerShell"
    }
}
Info ("vagrant: " + ((& vagrant --version) 2>&1))
Info ("VBoxManage: " + (& VBoxManage --version))

if (-not (Test-Path $Vagrantfile)) { Fail "找不到 $Vagrantfile（请在仓库目录内运行）" }

$ClusterName = Get-ClusterName
$OpsHost = "$ClusterName-ops"

# 内存：3 台合计约 7GB
$totalGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
if ($totalGB -lt 7.5) {
    Warn "物理内存 ${totalGB}GB，3 台 VM 合计约 7GB，可能卡顿。"
    Warn "可把 win\nodes.windows.yml 里 agent-1 改到 1536、ops 改到 768"
} else {
    Info "物理内存 ${totalGB}GB"
}

# 网段冲突：只提示，不阻断（VirtualBox 自己的 host-only 网卡占 192.168.56.1 属正常）
$conflicts = @()
try {
    $conflicts = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object {
            $_.IPAddress -like '192.168.56.*' -and
            $_.InterfaceAlias -notlike '*VirtualBox*'
        }
} catch { }
if ($conflicts.Count -gt 0) {
    Warn "检测到非 VirtualBox 网卡占用了 192.168.56.0/24："
    $conflicts | ForEach-Object { Warn ("  " + $_.InterfaceAlias + " -> " + $_.IPAddress) }
    Warn "如果 vagrant up 报网络错误，请改 win\nodes.windows.yml 里的 subnet/ip 段"
} else {
    Info "192.168.56.0/24 未被占用"
}

# ---- 2. vagrant up --------------------------------------------------------
# 关键：只对本次进程生效，Linux 路径不设这个变量 → 仍读 vagrant\nodes.yml
$env:K3S_OPS_NODES_FILE = $NodesFile
Info "拓扑文件: $NodesFile"

Push-Location $RepoRoot
try {
    if ($Node) {
        $target = $Node
        if ($target -notlike "$ClusterName-*") { $target = "$ClusterName-$target" }
        Info "启动 $target"
        & vagrant up $target
    } else {
        Info "启动全部 VM（首次需要下载 box，约 1-3GB）"
        & vagrant up
    }
    if ($LASTEXITCODE -ne 0) { Fail "vagrant up 失败（退出码 $LASTEXITCODE）" }

    # ---- 3. 引导工作机 ----------------------------------------------------
    if ($SkipProvision) {
        Warn "跳过工作机引导（-SkipProvision）"
    } else {
        Info "引导工作机（装 ansible/kubectl/helm，首次约 5-10 分钟）"
        & vagrant ssh $OpsHost -c "bash /vagrant/win/guest/bin/run-in-guest.sh provision"
        if ($LASTEXITCODE -ne 0) {
            Fail "工作机引导失败。排查：vagrant ssh $OpsHost -c 'bash /vagrant/win/guest/bin/run-in-guest.sh provision'"
        }

        # ---- 4. 安装集群 --------------------------------------------------
        if ($Install) {
            Info "安装 k3s（约 5-10 分钟）"
            & vagrant ssh $OpsHost -c "bash /vagrant/win/guest/bin/run-in-guest.sh install"
            if ($LASTEXITCODE -ne 0) { Fail "k3s 安装失败（看上面的 ansible 输出）" }

            # install 拉下来的 kubeconfig 里 server 是 127.0.0.1，必须改写
            Info "改写 kubeconfig 的 server 地址"
            & vagrant ssh $OpsHost -c "bash /vagrant/win/guest/bin/run-in-guest.sh kubeconfig"
            if ($LASTEXITCODE -ne 0) { Fail "kubeconfig 改写失败" }

            Info "集群自检"
            & vagrant ssh $OpsHost -c "bash /vagrant/win/guest/bin/run-in-guest.sh status"
        }
    }
} finally {
    Pop-Location
}

Write-Host ""
Info "完成。进入工作机："
Write-Host "    vagrant ssh $OpsHost"
Write-Host "    cd ~/k3s-ops && ./k3s-ops.sh status"
if (-not $Install) {
    Write-Host ""
    Write-Host "还没装集群？在仓库根目录执行："
    Write-Host "    .\win\up.ps1 -Install"
}
