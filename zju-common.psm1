# zju-common.psm1 — ZJU SSH 工具共享库（CLI / GUI 共用）
# 提供：TCP 探测、连接状态判定、配置读写（密码 DPAPI 加密）、统一输出。
# schemaVersion=2：工作站地址/端口/别名/RVPN 服务器等全部可配，缺失字段回落默认值，
# 因此 v1 老配置无需迁移即可用。

$script:ToolVersion = '1.3.1'

function Get-ToolVersion { return $script:ToolVersion }

$script:SchemaVersion = 3
$script:SocksHost = '127.0.0.1'
$script:SocksPort = 1080
# 注意：sshHost（工作站地址）没有默认值——必须由使用者在 init/界面/配置中提供
$script:Defaults = @{
    sshPort   = 22
    hostAlias = 'zju'
    server    = 'rvpn.zju.edu.cn'
    zjuPort   = 443
    zjuRepo   = 'Mythologyli/zju-connect'
    idFile    = '~/.ssh/id_ed25519'

    theme     = 'dark'
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
