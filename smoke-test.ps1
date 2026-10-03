# smoke-test.ps1 — zju-ssh 一键冒烟回归（改动后必跑）
# 用法: powershell -File smoke-test.ps1 ；退出码 = 失败项数量
# 注：检查 2/4/5 在沙箱（TEMP 下的临时 USERPROFILE/LOCALAPPDATA）内进行，不会污染真实 ssh 配置。
$ErrorActionPreference = 'Continue'
$toolDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $toolDir 'zju-common.psm1') -Force -DisableNameChecking

$script:fail = 0
$script:warn = 0
function Check([string]$name, [bool]$ok, [bool]$critical = $true) {
    # 必须写 $script:fail：函数内裸 $fail++ 只作用于函数局部副本，脚本级计数恒为 0，
    # 导致冒烟永远 exit 0、监测门形同虚设（自 v1.3.0 起潜伏）。非关键项只记 WARN，不计入退出码。
    if ($ok) { Write-Host ("[✓ PASS] {0}" -f $name); return }
    if ($critical) { $script:fail++; Write-Host ("[✗ FAIL] {0}" -f $name) }
    else { $script:warn++; Write-Host ("[! WARN] {0}" -f $name) }
}

Write-Host '=== zju-ssh 冒烟回归 ==='

# 0. 关键脚本 BOM 与语法解析检查（无 BOM 会被按 GBK 解析成乱码；解析错误直接判 FAIL）
foreach ($f in @('zju-ssh.ps1', 'zju-ssh-gui.ps1', 'zju-common.psm1')) {
    $p = Join-Path $toolDir $f
    if (Test-Path $p) {
        $b = [System.IO.File]::ReadAllBytes($p)
        $hasBom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
        $dup = ($b.Length -ge 6 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF -and $b[3] -eq 0xEF)
        Check ("$f 单层 UTF-8 BOM") ($hasBom -and -not $dup)
        $errs = $null
        [void][System.Management.Automation.PSParser]::Tokenize([System.IO.File]::ReadAllText($p), [ref]$errs)
        Check ("$f 语法解析") ($null -ne $errs -and $errs.Count -eq 0)
    }
}

# 1. 共享模块
$moduleOk = $true
try { Test-TcpPort -h '127.0.0.1' -p 1 -ms 80 | Out-Null } catch { $moduleOk = $false }
Check '共享模块加载并可调用' $moduleOk

# 2-5. 沙箱内执行：init（编译+写配置）→ 产物与配置断言
$oldUP = $env:USERPROFILE
$oldLA = $env:LOCALAPPDATA
try {
    $sandbox = Join-Path $env:TEMP ('zju-ssh-smoke-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
    $env:USERPROFILE = $sandbox
    $env:LOCALAPPDATA = $sandbox

    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $toolDir 'zju-ssh.ps1') init -Mode socks -SshHost 192.0.2.10 -SshUser smoke -VpnUser 'smoke-vpn' -VpnPassword 'smoke-pass' -NoDownload 2>&1 | Out-Null
    Check 'init 子进程退出码 0' ($LASTEXITCODE -eq 0)
    Check 'sshpipe.exe 编译' (Test-Path (Join-Path $toolDir 'bin\sshpipe.exe'))
    $cfg = Get-ToolConfig -LocalPath (Join-Path $sandbox 'zju-ssh\config.json') -ToolPath (Join-Path $toolDir 'config.json')
    Check '沙箱 config.json 可解析（schemaVersion≥3）' ($null -ne $cfg -and [int]$cfg.schemaVersion -ge 3)
    $smokeUserOk = $false
    if ($cfg) { $smokeUserOk = ([string]$cfg.sshUser -eq 'smoke') }
    Check '沙箱 config.sshUser = smoke' $smokeUserOk
    $cfgText = if (Test-Path (Join-Path $sandbox '.ssh\config')) { Get-Content (Join-Path $sandbox '.ssh\config') -Raw } else { '' }
    Check '沙箱 ssh 配置含 zju 标记块' ($cfgText -and $cfgText.Contains('# >>> zju-ssh >>>'))
} finally {
    $env:USERPROFILE = $oldUP
    $env:LOCALAPPDATA = $oldLA
}

# 6. zju-connect（非关键：缺省可手动下载）
Check 'bin\zju-connect.exe 存在' (Test-Path (Join-Path $toolDir 'bin\zju-connect.exe')) $false

# 6b. 下载链静态回归（离线可跑）：v1.4.1/1.4.2 的零 API + nightly 通道必须两侧同源；
#     $direct 曾在 820c137 重构时丢失，导致"全部下载源失败"提示里的手动地址恒为空——用静态检查钉死。
$cliText = [System.IO.File]::ReadAllText((Join-Path $toolDir 'zju-ssh.ps1'))
$shText2 = [System.IO.File]::ReadAllText((Join-Path $toolDir 'zju-ssh.sh'))
Check 'CLI 下载链含 $direct 定义（手动地址不再为空）' ($cliText -match '\$direct\s*=\s*"https://github\.com/\$repo')
Check 'CLI 下载链零 API 依赖（不再查 api.github.com/releases）' ($cliText -notmatch 'api\.github\.com/repos/\$repo/releases')
Check 'CLI 下载链含 nightly 通道' ($cliText -match 'releases/download/nightly/')
Check 'CLI 下载链含镜像回退' (($cliText -match 'ghproxy\.cn') -and ($cliText -match 'gh-proxy\.com'))
Check 'sh 下载链零 API 依赖' ($shText2 -notmatch 'api\.github\.com/repos')
Check 'sh 下载链含 nightly 通道' ($shText2 -match 'releases/download/nightly/')
Check 'sh 下载链含镜像回退' (($shText2 -match 'ghproxy\.cn') -and ($shText2 -match 'gh-proxy\.com'))
Check 'CLI 无重复函数定义' ([regex]::Matches($cliText, '(?m)^function Invoke-Connect').Count -eq 1)
# 直链与镜像拼接必须分开：统一 base+"github.com/..." 会拼出 github.com/github.com/... 恒 404（v1.4.2 起直链从未生效）
Check 'CLI 直链未被拼成 github.com/github.com' ($cliText -notmatch 'https://github\.com/''\s*\+\s*"github\.com/')
Check 'sh 直链未被拼成 github.com/github.com' ($shText2 -notmatch '\$\{BASE\}github\.com/')

# 7. 直连探测（结果依赖所处网络，仅展示）
# 注：-p 必须先落变量——命令模式下 -p [int](...) 不求值，绑定失败会让整个检查项静默消失
$probeHost = Get-CfgValue -Cfg $cfg -Key 'sshHost'
$probePort = [int](Get-CfgValue -Cfg $cfg -Key 'sshPort')
$direct = $false
if ($probeHost) { $direct = Test-TcpPort -h $probeHost -p $probePort -ms 600 }
Check '直连工作站端口（校外环境预期失败，仅展示）' $direct $false

# 8. doctor 子进程退出码（真实环境）
$out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $toolDir 'zju-ssh.ps1') doctor 2>&1
Check 'doctor 退出码为 0' ($LASTEXITCODE -eq 0)

Write-Host ''
Write-Host ("=== 冒烟结果: 失败 {0} 项（另有 {1} 项环境相关警告）===" -f $script:fail, $script:warn)
exit $script:fail
