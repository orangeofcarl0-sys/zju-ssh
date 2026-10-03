# release-gate.ps1 — zju-ssh 发布监测门（质量门 + 隐私门 + 监测门/冒烟）
# 用法: powershell -NoProfile -File release\release-gate.ps1 [-ReleaseTag v1.3.0] [-SkipSmoke]
# 约定: 任何一项 FAIL → 退出码 1；全绿 → 0。发布（push/tag）前必须全绿。
# 注: 规则正则以本文件为唯一事实源；RELEASE.md 只描述不复制，避免文档漂移与本文件自命中。
param(
    [string]$ReleaseTag,
    [switch]$SkipSmoke
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$inCI = [bool]$env:GITHUB_ACTIONS
$script:fail = 0
$script:pass = 0

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

function Add-Fail([string]$msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:fail++ }
function Add-Pass([string]$msg) { Write-Host "  [ok]   $msg" -ForegroundColor DarkGray; $script:pass++ }
function Add-Warn2([string]$msg) { Write-Host "  [warn] $msg" -ForegroundColor Yellow }

function Section([string]$title) {
    Write-Host ''
    Write-Host "== $title ==" -ForegroundColor Cyan
}

function Get-Trimmed([string]$s) {
    $t = $s.Trim()
    if ($t.Length -gt 72) { $t = $t.Substring(0, 72) + '…' }
    return $t
}

# ---------------------------------------------------------------- §1 质量门 · 文件与语法
Section '§1 质量门 · 文件齐套 / BOM / 语法 / 工作树'

$required = @(
    'README.md', 'LICENSE', '.gitignore', '.gitattributes', 'RELEASE.md',
    'config.example.json', 'Start-GUI.bat',
    'zju-ssh.ps1', 'zju-ssh-gui.ps1', 'zju-common.psm1', 'sshpipe.cs', 'zju-ssh.sh',
    'monitor/ssh-log.ps1', 'smoke-test.ps1', 'tools/norm-bom.ps1',
    'release/release-gate.ps1', 'release/package.ps1', 'release/notes-template.md',
    '.github/workflows/ci.yml', '.github/workflows/release.yml'
)
foreach ($f in $required) {
    if (Test-Path (Join-Path $repo $f)) { Add-Pass "文件存在 $f" }
    else { Add-Fail "缺少文件 $f" }
}

$dirty = & git -C $repo status --porcelain
if ($dirty) { Add-Fail '工作树不干净（先提交再过门）'; $dirty | ForEach-Object { Write-Host "         $_" -ForegroundColor DarkYellow } }
else { Add-Pass 'git 工作树干净' }

# 敏感/本机文件绝不入库
$tracked = @(& git -C $repo ls-files)
$sensitiveHit = $tracked | Where-Object { $_ -match '(?:^|/)config\.json$|\.(?:pem|ppk|pfx|key)$|(?:^|/)id_(?:rsa|ed25519|ecdsa)(?:\.pub)?$|test\-accounts\-credential[s]|^dist/' }
if ($sensitiveHit) { Add-Fail "敏感文件被跟踪: $($sensitiveHit -join ', ')" }
else { Add-Pass '无敏感/本机文件入库（config.json、密钥、dist 等）' }
# check-ignore 对不存在的裸目录名不生效，探测 dist 下虚拟文件路径；-q 无输出，必须读退出码而非输出
& git -C $repo check-ignore -q dist/x.probe
if ($LASTEXITCODE -eq 0) { Add-Pass '.gitignore 覆盖 dist/' }
else { Add-Fail '.gitignore 未覆盖 dist/' }

# ps1/psm1: 单层 UTF-8 BOM + 语法可解析
$psFiles = Get-ChildItem $repo -Recurse -Include *.ps1, *.psm1 | Where-Object { $_.FullName -notmatch '\\\.git\\' }
foreach ($pf in $psFiles) {
    $rel = $pf.FullName.Substring($repo.Length + 1)
    $b = [System.IO.File]::ReadAllBytes($pf.FullName)
    $bom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    $dup = ($b.Length -ge 6 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF -and $b[3] -eq 0xEF)
    if ($bom -and -not $dup) { Add-Pass "BOM 单层 $rel" }
    else { Add-Fail "BOM 异常（需恰好一层 UTF-8 BOM）: $rel" }
    $errs = $null
    [void][System.Management.Automation.PSParser]::Tokenize([System.IO.File]::ReadAllText($pf.FullName), [ref]$errs)
    if ($errs -and $errs.Count -gt 0) { Add-Fail "PS 语法错误 ${rel}: $($errs[0].Message)" }
    else { Add-Pass "语法 OK  $rel" }
}

# sh: 必须 LF（macOS bash 见 \r 即炸），有 bash 时顺带 bash -n
$shPath = Join-Path $repo 'zju-ssh.sh'
$shBytes = [System.IO.File]::ReadAllBytes($shPath)
$hasCR = $false
for ($i = 0; $i -lt $shBytes.Length; $i++) { if ($shBytes[$i] -eq 13) { $hasCR = $true; break } }
if ($hasCR) { Add-Fail 'zju-ssh.sh 含 CRLF（必须 LF）' }
else { Add-Pass 'zju-ssh.sh 为 LF 行尾' }
$bash = Get-Command bash -ErrorAction SilentlyContinue
if ($bash) {
    $shFwd = $shPath -replace '\\', '/'
    & bash -n $shFwd 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Add-Pass 'bash -n 语法 OK (zju-ssh.sh)' }
    else { Add-Fail 'bash -n 语法错误 (zju-ssh.sh)' }
}

# config.example.json 可解析且不含真实密码
try {
    $ex = Get-Content (Join-Path $repo 'config.example.json') -Raw | ConvertFrom-Json
    if ($ex.vpnPassword) { Add-Fail 'config.example.json 含非空 vpnPassword' }
    else { Add-Pass 'config.example.json 可解析且无凭据' }
} catch { Add-Fail "config.example.json 解析失败: $($_.Exception.Message)" }

# ---------------------------------------------------------------- §2 质量门 · 版本一致性
Section '§2 质量门 · 版本一致性（四处 + tag）'

$commonText = [System.IO.File]::ReadAllText((Join-Path $repo 'zju-common.psm1'))
$shText = [System.IO.File]::ReadAllText($shPath)
$readmeText = [System.IO.File]::ReadAllText((Join-Path $repo 'README.md'))
$guiText = [System.IO.File]::ReadAllText((Join-Path $repo 'zju-ssh-gui.ps1'))

$vers = @()
if ($commonText -match '(?m)^\s*\$script:ToolVersion\s*=\s*''([^'']+)''') { $vers += @{ loc = 'zju-common.psm1 $script:ToolVersion'; val = $Matches[1] } }
if ($shText -match '(?m)^TOOL_VERSION="([^"]+)"') { $vers += @{ loc = 'zju-ssh.sh TOOL_VERSION'; val = $Matches[1] } }
if ($readmeText -match '(?m)^>\s*v(\d+\.\d+\.\d+)\s') { $vers += @{ loc = 'README.md 版本徽标'; val = $Matches[1] } }
if ($guiText -match 'x:Name="verText"[^>]*Text="v(\d+\.\d+\.\d+)"') { $vers += @{ loc = 'GUI XAML verText 占位'; val = $Matches[1] } }

if ($vers.Count -lt 4) { Add-Fail "版本声明不足 4 处（找到 $($vers.Count) 处）" }
# 注：@() 包住管道结果——Select-Object -Unique 单元素时会被展开成标量字符串，$uniq[0] 会取到第一个字符
$uniq = @($vers | ForEach-Object { $_.val } | Select-Object -Unique)
if ($uniq.Count -ne 1) { Add-Fail ("版本号不一致: " + (($vers | ForEach-Object { "$($_.loc)=$($_.val)" }) -join '; ')) }
else {
    $ver = $uniq[0]
    foreach ($v in $vers) { Add-Pass "$($v.loc) = $($v.val)" }
    if ($ReleaseTag) {
        if ($ReleaseTag -eq "v$ver") { Add-Pass "-ReleaseTag 与版本一致 ($ReleaseTag)" }
        else { Add-Fail "-ReleaseTag ($ReleaseTag) 与版本号 (v$ver) 不一致" }
        if (-not $inCI) {
            & git -C $repo rev-parse -q --verify "refs/tags/$ReleaseTag" | Out-Null
            if ($LASTEXITCODE -eq 0) { Add-Pass "本地 tag 存在: $ReleaseTag" }
            else { Add-Fail "本地 tag 不存在: $ReleaseTag" }
        }
    }
}

# ---------------------------------------------------------------- §3 隐私门 · 敏感信息扫描
Section '§3 隐私门 · 敏感信息扫描（全部跟踪文件，逐行）'

# 规则即事实源。文档（RELEASE.md/README）不复制规则，避免自命中。
$privacyRules = @(
    @{ Name = '工作站固定地址'; Pattern = '10\.98\.32\.158' },
    @{ Name = '私网地址 10.x'; Pattern = '(?<!\d)10\.\d{1,3}\.\d{1,3}\.\d{1,3}(?!\d)' },
    @{ Name = '私网地址 192.168.x'; Pattern = '(?<!\d)192\.168\.\d{1,3}\.\d{1,3}(?!\d)' },
    @{ Name = '私网地址 172.16-31.x'; Pattern = '(?<!\d)172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}(?!\d)' },
    @{ Name = '电子邮箱'; Pattern = '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+' },
    @{ Name = '私钥材料'; Pattern = '-----BEGIN [A-Z ]*PRIVATE KEY-----' },
    @{ Name = 'SSH 公钥体'; Pattern = '(?:ssh-(?:ed25519|rsa|dss)|ecdsa-sha2-[a-z0-9-]+) AAAA[0-9A-Za-z+/=]{20,}' },
    @{ Name = '密码字面量'; Pattern = '(?i)(?:vpnpassword|password|passwd)\s*[=:]\s*["''][^"'']{3,}["'']' },
    @{ Name = '内部账号名'; Pattern = '\b(?:labadmi[n]|labtes[t])\b' },
    @{ Name = '机器/工作组名'; Pattern = '\bCYDLA[B]\b|\bDESKTOP-[A-Z0-9]{4,}\b' },
    @{ Name = '个人 Windows 路径'; Pattern = '[A-Za-z]:[\\/]+Data and cod[e]|C:[\\/]+Users[\\/]+(?!Public\b|Default\b)[A-Za-z][A-Za-z0-9_.-]*' },
    @{ Name = '疑似凭据长 base64'; Pattern = '[A-Za-z0-9+/]{80,}={0,2}' },
    @{ Name = '内部凭据文件引用'; Pattern = 'test\-accounts\-credential[s]|\btest\-key[s]\b' }
)

$privacyFiles = 0
foreach ($f in $tracked) {
    $full = Join-Path $repo ($f -replace '/', '\')
    if (-not (Test-Path $full)) { continue }
    $b = [System.IO.File]::ReadAllBytes($full)
    $binary = $false
    for ($i = 0; $i -lt [Math]::Min($b.Length, 8000); $i++) { if ($b[$i] -eq 0) { $binary = $true; break } }
    if ($binary) { continue }
    $privacyFiles++
    $text = [System.IO.File]::ReadAllText($full)
    $lines = $text -split "`r?`n"
    for ($li = 0; $li -lt $lines.Count; $li++) {
        foreach ($rule in $privacyRules) {
            if ($lines[$li] -match $rule.Pattern) {
                Add-Fail ("隐私门 [{0}] {1}:{2}: {3}" -f $rule.Name, $f, ($li + 1), (Get-Trimmed $lines[$li]))
            }
        }
    }
}
Add-Pass "隐私扫描完成: $privacyFiles 个文本文件 × $($privacyRules.Count) 条规则"
if ($script:fail -eq 0) { Add-Pass '隐私门机器扫描零命中' }

# ---------------------------------------------------------------- §4 监测门 · 冒烟回归
Section '§4 监测门 · 冒烟回归 (smoke-test.ps1)'
if ($SkipSmoke) {
    Add-Warn2 '-SkipSmoke 指定：跳过冒烟（仅允许本地快速迭代，正式发布与 CI 一律不跳）'
} else {
    $smokeOut = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'smoke-test.ps1') 2>&1
    $smokeCode = $LASTEXITCODE
    $smokeOut | Select-Object -Last 10 | ForEach-Object { Write-Host "         $_" -ForegroundColor DarkGray }
    if ($smokeCode -eq 0) { Add-Pass 'smoke-test 全部通过 (exit 0)' }
    else { Add-Fail "smoke-test 失败 (exit $smokeCode)" }
}

# ---------------------------------------------------------------- 结果
Section '人工确认清单（发布者逐条心证，脚本无法代查）'
Write-Host '         1. 全库无真实姓名/学号/工号/宿舍房间号/群号/内部文档截图' -ForegroundColor Yellow
Write-Host '         2. 公开仓库历史 = 发布树的单提交 orphan 历史；archive/private-history 只留在本地，绝不 push' -ForegroundColor Yellow
Write-Host '         3. 任何情况下不得 git push --mirror / --all --tags 到公开远端' -ForegroundColor Yellow
Write-Host '         4. prerelease 转正前：两平台包解压可用 + 校内外实测 ssh zju + Actions 全绿' -ForegroundColor Yellow

Write-Host ''
if ($script:fail -gt 0) {
    Write-Host "=== 监测门结果: FAIL（$($script:fail) 项失败 / $($script:pass) 项通过）===" -ForegroundColor Red
    exit 1
} else {
    Write-Host "=== 监测门结果: ALL GREEN（$($script:pass) 项通过，0 失败）===" -ForegroundColor Green
    exit 0
}
