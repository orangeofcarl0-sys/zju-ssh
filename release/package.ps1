# package.ps1 — 从当前工作树打发布包（Windows / macOS 两个 zip + SHA256SUMS.txt）
# 用法: powershell -NoProfile -File release\package.ps1 [-Version 1.3.0] [-OutDir dist]
# 注: 版本号缺省时从 zju-common.psm1 读取；产物落在 dist/（已 gitignore），绝不入库。
param(
    [string]$Version,
    [string]$OutDir
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

if (-not $Version) {
    $commonText = [System.IO.File]::ReadAllText((Join-Path $repo 'zju-common.psm1'))
    if ($commonText -match '\$script:ToolVersion\s*=\s*''([^'']+)''') { $Version = $Matches[1] }
    else { throw '无法从 zju-common.psm1 读到 ToolVersion，请用 -Version 指定' }
}
if (-not $OutDir) { $OutDir = Join-Path $repo 'dist' }
$tag = "v$Version"
Write-Host "打包 zju-ssh $tag -> $OutDir"

$dirty = & git -C $repo status --porcelain
if ($dirty) { Write-Warning '工作树不干净：打包内容=当前磁盘内容，先跑 release-gate.ps1 更稳' }

$winFiles = @('README.md', 'LICENSE', 'config.example.json', 'Start-GUI.bat',
    'zju-ssh.ps1', 'zju-ssh-gui.ps1', 'zju-common.psm1', 'sshpipe.cs', 'monitor/ssh-log.ps1')
$macFiles = @('README.md', 'LICENSE', 'config.example.json', 'zju-ssh.sh')

if (Test-Path $OutDir) { Remove-Item $OutDir -Recurse -Force }
$stageWin = Join-Path $OutDir "zju-ssh-$Version-windows"
$stageMac = Join-Path $OutDir "zju-ssh-$Version-macos"
New-Item $stageWin -ItemType Directory -Force | Out-Null
New-Item $stageMac -ItemType Directory -Force | Out-Null

function Copy-Flat([string[]]$files, [string]$dst) {
    foreach ($f in $files) {
        $src = Join-Path $repo ($f -replace '/', '\')
        $target = Join-Path $dst ($f -replace '/', '\')
        $targetDir = Split-Path -Parent $target
        if (-not (Test-Path $targetDir)) { New-Item $targetDir -ItemType Directory -Force | Out-Null }
        Copy-Item $src $target -Force
    }
}
Copy-Flat $winFiles $stageWin
Copy-Flat $macFiles $stageMac

# sh 强制 LF（即使工作树被意外转成 CRLF，包内也必须是 LF）
$shTarget = Join-Path $stageMac 'zju-ssh.sh'
$shText = [System.IO.File]::ReadAllText($shTarget).Replace("`r`n", "`n")
[System.IO.File]::WriteAllText($shTarget, $shText, (New-Object System.Text.UTF8Encoding($false)))

$zipWin = Join-Path $OutDir "zju-ssh-$tag-windows.zip"
$zipMac = Join-Path $OutDir "zju-ssh-$tag-macos.zip"
Compress-Archive -Path (Join-Path $stageWin '*') -DestinationPath $zipWin -Force
Compress-Archive -Path (Join-Path $stageMac '*') -DestinationPath $zipMac -Force
Remove-Item $stageWin -Recurse -Force
Remove-Item $stageMac -Recurse -Force

$sums = @()
foreach ($zip in @($zipWin, $zipMac)) {
    $h = Get-FileHash $zip -Algorithm SHA256
    $sums += ('{0}  {1}' -f $h.Hash.ToLower(), (Split-Path -Leaf $zip))
}
$sumsPath = Join-Path $OutDir 'SHA256SUMS.txt'
[System.IO.File]::WriteAllLines($sumsPath, $sums, (New-Object System.Text.UTF8Encoding($false)))

Write-Host '完成:'
Get-ChildItem $OutDir -File | ForEach-Object { Write-Host ("  {0}  {1:N0} bytes" -f $_.Name, $_.Length) }
