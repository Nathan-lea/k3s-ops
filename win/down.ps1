<#
.SYNOPSIS
  关闭 VM，释放宿主机内存。

.DESCRIPTION
  运维操作（install/status/...）在工作机里做，本脚本只管虚拟机的开关。

  -Suspend  挂起到磁盘（恢复最快，占用磁盘）
  -Force    强制断电（等于拔电源，可能丢数据）
  -Node     只操作某台（短名或完整名）

.EXAMPLE
  .\win\down.ps1              # 优雅关机（vagrant halt）
  .\win\down.ps1 -Suspend     # 挂起
  .\win\down.ps1 -Force       # 强制关机
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$Suspend,
    [string]$Node = ""
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$RepoRoot  = Split-Path -Parent $PSScriptRoot
$NodesFile = Join-Path $PSScriptRoot 'nodes.windows.yml'

function Info ($m) { Write-Host "[INFO]  $m" -ForegroundColor Green }
function Fail ($m) { Write-Host "[ERROR] $m" -ForegroundColor Red; exit 1 }

$env:K3S_OPS_NODES_FILE = $NodesFile

Push-Location $RepoRoot
try {
    if ($Node) {
        $cluster = (Select-String -Path $NodesFile -Pattern '^\s*cluster_name:\s*(\S+)').Matches[0].Groups[1].Value
        $target = $Node
        if ($target -notlike "$cluster-*") { $target = "$cluster-$target" }
        $targets = @($target)
    } else {
        $targets = @()
    }

    if ($Suspend) {
        Info "挂起 VM"
        if ($targets.Count) { & vagrant suspend $targets[0] } else { & vagrant suspend }
    } elseif ($Force) {
        Info "强制关机"
        if ($targets.Count) { & vagrant halt -f $targets[0] } else { & vagrant halt -f }
    } else {
        Info "优雅关机"
        if ($targets.Count) { & vagrant halt $targets[0] } else { & vagrant halt }
    }
    if ($LASTEXITCODE -ne 0) { Fail "操作失败（退出码 $LASTEXITCODE）" }
} finally {
    Pop-Location
}
