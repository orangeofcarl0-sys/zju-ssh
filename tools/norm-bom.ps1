# tools/norm-bom.ps1 — 统一 UTF-8 BOM：剥掉所有重复 BOM，保证恰好一个
# 用法: powershell -File tools\norm-bom.ps1 -Path <文件>
param([Parameter(Mandatory = $true)][string]$Path)
$bytes = [System.IO.File]::ReadAllBytes($Path)
$i = 0
while ($i + 2 -lt $bytes.Length -and $bytes[$i] -eq 0xEF -and $bytes[$i + 1] -eq 0xBB -and $bytes[$i + 2] -eq 0xBF) { $i += 3 }
$new = New-Object byte[] (3 + $bytes.Length - $i)
$new[0] = 0xEF; $new[1] = 0xBB; $new[2] = 0xBF
[Array]::Copy($bytes, $i, $new, 3, $bytes.Length - $i)
[System.IO.File]::WriteAllBytes($Path, $new)
Write-Output ("normalized: " + $Path)
