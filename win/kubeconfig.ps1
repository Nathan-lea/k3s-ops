<#
.SYNOPSIS
  把工作机上的 kubeconfig 拉到 Windows 宿主机（UTF-8，无 BOM，LF）。

.DESCRIPTION
  因为 .gitattributes 规定 *.md LF、PowerShell 5.1 写入 UTF-8 BOM 会毁掉
  bash 脚本，所以这里用 [IO.File]::WriteAllText + UTF8Encoding($false)。
  同时自动改写 server 地址为宿主机可达的 192.168.56.10。

.EXAMPLE
  .\win\kubeconfig.ps1        # 输出到 $HOME\.kube\config
  .\win\kubeconfig.ps1 -Out . # 输出到当前目录 kubeconfig
#>
[CmdletBinding()]
param(
    [string]$Out = "",
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
    $cluster = (Select-String -Path $NodesFile -Pattern '^\s*cluster_name:\s*(\S+)').Matches[0].Groups[1].Value
    $opsHost = "$cluster-ops"

    Info "从 $opsHost 拉取 kubeconfig"
    $raw = & vagrant ssh $opsHost -c "cat ~/k3s-ops/kubeconfig"
    if ($LASTEXITCODE -ne 0) {
        Fail "拉取失败。确认 clusters 已安装：vagrant ssh $opsHost -c 'bash /vagrant/win/guest/bin/run-in-guest.sh status'"
    }
    if ([string]::IsNullOrWhiteSpace($raw)) { Fail "kubeconfig 为空，请先在工作机里跑 install + kubeconfig" }

    $text = $raw -join "`n"
    if (-not ($text.EndsWith("`n"))) { $text += "`n" }

    # 把 127.0.0.1 改写成宿主机能访问的 server IP，顺便兼容已改写的情况
    $text = $text -replace 'server: https://127\.0\.0\.1:6443', 'server: https://192.168.56.10:6443'
    # 如果 install 时没运行 kubeconfig 改写，这一步兜底
    $hasLocal = $text -match 'server: https://192\.168\.56\.10:6443'

    $dest = $Out
    if (-not $dest) {
        if ($Node) {
            # Windows 的 .kube/config 不常用；这里默认放桌面下的 kubeconfig
            $dest = Join-Path $env:USERPROFILE "Desktop/kubeconfig"
        } else {
            $dest = Join-Path $env:USERPROFILE ".kube\config"
        }
    }
    $destDir = Split-Path -Parent $dest
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }

    # UTF-8 无 BOM，换行 LF
    [IO.File]::WriteAllText($dest, $text, [System.Text.Encoding]::UTF8)
    # 统一换行为 LF（PS 5.1 读取时可能带 \r\n；Windows 的 kubectl/grep 都能接受 LF）
    $bytes = [System.IO.File]::ReadAllBytes($dest)
    if ($bytes -ccontains [byte[]](13,10)) {
        $text2 = [System.Text.Encoding]::UTF8.GetString($bytes) -replace "`r`n", "`n"
        [IO.File]::WriteAllText($dest, $text2, [System.Text.Encoding]::UTF8)
    }

    Info "kubeconfig 已保存: $dest"
    if (-not $hasLocal) {
        Fail "kubeconfig 里仍有 127.0.0.1，说明工作机没改写。回工作机跑：bash /vagrant/win/guest/bin/run-in-guest.sh kubeconfig"
    }
    Write-Host "  server: https://192.168.56.10:6443  (已校正)"
    Write-Host "  在 Windows 可直接用：  kubectl --kubeconfig `"$dest`" get nodes"
} finally {
    Pop-Location
}
