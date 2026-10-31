<#
.SYNOPSIS
  删除 VM（磁盘文件一并删除，不可恢复）。

.DESCRIPTION
  删除后要重建，直接跑 .\win\up.ps1 -Install。
  只删某台时用 -Node。

.EXAMPLE
  .\win\destroy.ps1            # 全部删除（会二次确认）
  .\win\destroy.ps1 -Yes       # 跳过确认
  .\win\destroy.ps1 -Node ops  # 只删工作机
#>
[CmdletBinding()]
param(
    [string]$Node = "",
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$RepoRoot  = Split-Path -Parent $PSScriptRoot
$NodesFile = Join-Path $PSScriptRoot 'nodes.windows.yml'

function Info ($m) { Write-Host "[INFO]  $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "[WARN]  $m" -ForegroundColor Yellow }
function Fail ($m) { Write-Host "[ERROR] $m" -ForegroundColor Red; exit 1 }

$cluster = (Select-String -Path $NodesFile -Pattern '^\s*cluster_name:\s*(\S+)').Matches[0].Groups[1].Value

$target = ""
if ($Node) {
    $target = $Node
    if ($target -notlike "$cluster-*") { $target = "$cluster-$target" }
}

if (-not $Yes) {
    $what = '全部 VM'
    if ($target) { $what = $target }
    Warn "即将删除 $what，磁盘数据会丢失。"
    $answer = Read-Host "确认请输入 yes"
    if ($answer -ne 'yes') { Info "已取消"; exit 0 }
}

$env:K3S_OPS_NODES_FILE = $NodesFile

Push-Location $RepoRoot
try {
    if ($target) { & vagrant destroy -f $target } else { & vagrant destroy -f }
    if ($LASTEXITCODE -ne 0) { Fail "删除失败（退出码 $LASTEXITCODE）" }

    if (-not $target) {
        # vagrant destroy 不会清理 .vagrant 目录；留着旧 machine id 会让下次 up 犯迷糊
        $meta = Join-Path $RepoRoot '.vagrant'
        if (Test-Path $meta) {
            Remove-Item -Recurse -Force $meta
            Info "已清理 .vagrant 元数据"
        }
    }
} finally {
    Pop-Location
}
Info "完成。重建：.\win\up.ps1 -Install"
