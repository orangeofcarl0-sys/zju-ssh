# zju-common.psm1 — ZJU SSH 工具共享库（CLI / GUI 共用）
# 提供：TCP 探测、连接状态判定、配置读写（密码 DPAPI 加密）、统一输出。
# schemaVersion=2：工作站地址/端口/别名/RVPN 服务器等全部可配，缺失字段回落默认值，
# 因此 v1 老配置无需迁移即可用。

$script:ToolVersion = '1.5.1'

function Get-ToolVersion { return $script:ToolVersion }

$script:SchemaVersion = 3
$script:SocksHost = '127.0.0.1'
$script:SocksPort = 1080
# 注意：sshHost（工作站地址）没有默认值——必须由使用者在 init/界面/配置中提供
$script:Defaults = @{
    sshPort    = 22
    hostAlias  = 'zju'
    server     = 'rvpn.zju.edu.cn'
    zjuPort    = 443
    zjuRepo    = 'Mythologyli/zju-connect'
    idFile     = '~/.ssh/id_ed25519'

    theme      = 'dark'
    zjuChannel = 'nightly'   # nightly 含 aTrust 二次认证等修复；stable=正式 release
    zjuAssetDate = ''        # 内核资产 Last-Modified（nightly 为滚动构建，用它检测更新）
}

function Write-Ok([string]$msg)    { Write-Host "[✓] $msg" }
function Write-Warn2([string]$msg) { Write-Host "[!] $msg" }
function Write-Err2([string]$msg)  { Write-Host "[✗] $msg" }

function Get-CfgValue {
    # 从配置对象取字段，缺失/为空回落默认值
    param([object]$Cfg, [string]$Key)
    if ($Cfg -and $Cfg.PSObject.Properties[$Key] -and $null -ne $Cfg.$Key -and [string]$Cfg.$Key -ne '') {
        return [string]$Cfg.$Key
    }
    return [string]$script:Defaults[$Key]
}

function Test-TcpPort {
    param([string]$h, [int]$p, [int]$ms = 800)
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $c.BeginConnect($h, $p, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne($ms) -and $c.Connected) { return $true } else { return $false }
    } catch { return $false } finally { try { $c.Close() } catch {} }
}

function Test-SocksReady { Test-TcpPort -h $script:SocksHost -p $script:SocksPort -ms 250 }

function Get-ZjuProc { Get-Process zju-connect -ErrorAction SilentlyContinue }

# 隧道监督进程（zju-runner.ps1）：持有内核 stdin，负责把二次认证口令转发给内核
function Get-RunnerProc {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'zju-runner\.ps1' } |
        ForEach-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue }
}

# 内核二次认证提示原文（取自上游 client/authchallenge 与 atrust/auth）。
# 注意用"不含末尾冒号"的前缀：内核打印的是 "Please enter the SMS verification code: "，
# 若前缀带冒号，LastIndexOf 命中后剩余 ": " 会让"是否仍在等待"的判断失真。
function Get-ChallengeMarkers {
    return @(
        'Please enter the SMS verification code',
        'Please enter the TOTP token',
        'Please enter the RADIUS token',
        'Please enter the graph check code',
        'Please enter the callback url',
        'Please enter the callback URL'
    )
}

# 提交二次认证口令：写入"收件箱"，由 zju-runner.ps1 转发给内核 stdin。
# 直接落文件而非起子进程——GUI 在 up 运行期间有"已有任务在运行"的互斥，
# 若走子进程提交会与正在等待口令的 up 互锁（口令永远发不出去）。
function Send-ZjuCode {
    param([string]$LogDir, [string]$Code)
    if (-not $Code -or -not $Code.Trim()) { throw '验证码不能为空' }
    $dir = if ($LogDir) { $LogDir } else { Join-Path (Split-Path -Parent $PSScriptRoot) 'logs' }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Add-Content -LiteralPath (Join-Path $dir 'code-inbox.txt') -Value $Code.Trim() -Encoding UTF8
    return $Code.Trim().Length
}

# 浏览器图形验证码：aTrust 有时先要用户在弹出的网页里点选图片字符（graph check code），
# 通过后才发手机短信。内核会起一个本地 HTTP 服务并打印 "Captcha server started at http://127.0.0.1:PORT"。
# 返回该 URL（无则空串），供界面提示用户去浏览器完成。
function Get-ZjuCaptchaUrl {
    param([string]$LogFile)
    if (-not $LogFile -or -not (Test-Path $LogFile)) { return '' }
    $text = ''
    try {
        $fs = [System.IO.File]::Open($LogFile, 'Open', 'Read', 'ReadWrite')
        try {
            $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
            $text = $sr.ReadToEnd()
        } finally { $fs.Close() }
    } catch { return '' }
    $m = [regex]::Matches($text, 'Captcha server started at\s+(http://[0-9\.]+:\d+)')
    if ($m.Count -eq 0) { return '' }
    $url = $m[$m.Count - 1].Groups[1].Value
    # 若该 URL 之后内核已继续（出现新的登录/认证步骤），说明图形码阶段已过
    $i = $text.LastIndexOf($url)
    $after = $text.Substring($i + $url.Length)
    if ($after -match 'Perform POST /passport/v1/auth/psw|Phone number:|SMS message sent|Please enter the') { return '' }
    return $url
}

# 扫描内核日志，返回它当前正等待的口令提示（无则空串）。
# 判据：提示出现后到文件末尾没有其他非空内容 = 仍在等待；一旦有后续输出即视为已推进。
# 注意必须用 FileShare.ReadWrite 打开：内核（cmd 重定向）持有日志写句柄，独占读会 IOException
# 而被 catch 吞掉、恒返回空——这正是"提示明明在日志里却检测不到"的根因。
function Get-ZjuChallenge {
    param([string]$LogFile)
    if (-not $LogFile -or -not (Test-Path $LogFile)) { return '' }
    $text = ''
    try {
        $fs = [System.IO.File]::Open($LogFile, 'Open', 'Read', 'ReadWrite')
        try {
            $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
            $text = $sr.ReadToEnd()
        } finally { $fs.Close() }
    } catch { return '' }
    $best = ''
    foreach ($m in (Get-ChallengeMarkers)) {
        $i = $text.LastIndexOf($m)
        if ($i -lt 0) { continue }
        # 提示后只可能跟 ": "、空格、换行（内核 readLine 会给消息补一个空格）；
        # 把冒号与空白剥掉后仍为空 = 内核确实停在等待输入
        $after = $text.Substring($i + $m.Length).TrimStart(':', ' ', "`t", "`r", "`n")
        if ($after.Trim() -eq '') { if ($m.Length -gt $best.Length) { $best = $m } }
    }
    return $best
}

# 连接状态：zju(校内直连) / tunnel(SOCKS 就绪) / starting(进程在但未就绪) / off
function Get-ConnectionState {
    param([string]$SshHost, [int]$SshPort)
    if (-not $SshHost) { $SshHost = $script:Defaults.sshHost }
    if (-not $SshPort) { $SshPort = [int]$script:Defaults.sshPort }
    if (Test-TcpPort -h $SshHost -p $SshPort -ms 500) { return 'zju' }
    if (Test-SocksReady) { return 'tunnel' }
    if (Get-ZjuProc) { return 'starting' }
    return 'off'
}

# ---- 配置读写（vpnPassword 明文入参 → DPAPI 加密落盘；读取时解密还原）----
function Protect-Text([string]$plain) {
    if (-not $plain) { return '' }
    $sec = ConvertTo-SecureString $plain -AsPlainText -Force
    return ConvertFrom-SecureString $sec   # DPAPI（当前用户+本机可解）
}
function Unprotect-Text([string]$enc) {
    if (-not $enc) { return '' }
    try {
        $sec = ConvertTo-SecureString -String $enc
        $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        $t = [Runtime.InteropServices.Marshal]::PtrToStringAuto($b)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b)
        return $t
    } catch { return '' }   # 换用户/换机器后解不开：按未配置处理
}

function Get-ToolConfig {
    param([string]$LocalPath, [string]$ToolPath)
    $p = if (Test-Path $LocalPath) { $LocalPath } elseif (Test-Path $ToolPath) { $ToolPath } else { return $null }
    try { $o = Get-Content $p -Raw | ConvertFrom-Json } catch { return $null }
    # 迁移：补齐 v2 可配字段（缺失回落默认），并把 schema 升到当前版本
    foreach ($k in @($script:Defaults.Keys)) {
        if (-not ($o.PSObject.Properties.Name -contains $k) -or $null -eq $o.$k -or [string]$o.$k -eq '') {
            $o | Add-Member -NotePropertyName $k -NotePropertyValue ([string]$script:Defaults[$k]) -Force
        }
    }
    if ($o.vpnPasswordEnc) {
        $plain = Unprotect-Text $o.vpnPasswordEnc
        $o | Add-Member -NotePropertyName vpnPassword -NotePropertyValue $plain -Force
    } elseif (-not ($o.PSObject.Properties.Name -contains 'vpnPassword')) {
        $o | Add-Member -NotePropertyName vpnPassword -NotePropertyValue '' -Force
    }
    if (-not ($o.PSObject.Properties.Name -contains 'zjuVersion')) {
        $o | Add-Member -NotePropertyName zjuVersion -NotePropertyValue '' -Force
    }
    $o.schemaVersion = $script:SchemaVersion
    return $o
}

function Save-ToolConfig {
    param([object]$Cfg, [string]$Path)
    if ($Cfg.vpnPassword) {
        $Cfg | Add-Member -NotePropertyName vpnPasswordEnc -NotePropertyValue (Protect-Text $Cfg.vpnPassword) -Force
        $Cfg.vpnPassword = ''
    }
    $Cfg | Add-Member -NotePropertyName schemaVersion -NotePropertyValue $script:SchemaVersion -Force
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    $Cfg | ConvertTo-Json | Set-Content -Path $Path -Encoding UTF8
}

Export-ModuleMember -Function *
